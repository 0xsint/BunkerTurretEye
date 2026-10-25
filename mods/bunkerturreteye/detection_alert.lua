-- HD2-Addon: mods/bunkerturreteye/detection_alert

-- Detection Alert: combines a Wwise audio-state heuristic with HD2Runtime's proven
-- combat events (player_damaged / entity_damaged / entity_killed) as two independent
-- "are we in a fight" signals, OR'd together.
-- Requires Bingus Shared Loader v15+ (https://github.com/CowboyBingus/BingusSharedLoader).
-- HD2Runtime (https://github.com/SkyeShade/HD2Runtime) is an optional soft dependency:
-- if it is not installed, the mod falls back to the Wwise heuristic alone.
-- Targets plain Lua 5.1.4 (current builds have no LuaJIT): no 5.2+ syntax or library calls.
--
-- Current Steam builds remove HD2Runtime's memory access and the Wwise callbacks, so no detection
-- source is live there. The mod then runs in probe mode: it logs what the runtime exposes (the
-- "probe" lines in DetectionAlert.log), logs AggroCounter.counts when AggroCounter is running, and
-- samples enemy animation states read-only (shadow mode: logged only, not used for detection yet).
--
-- Neither source is a direct AI-perception query -- HD2Runtime's event catalog has no
-- "enemy spotted you" event yet -- so this remains a practical proxy, not raw detection.
--
-- enemies_nearby / enemies_searching below are extra status-only signals (reported in the
-- log/overlay) that do not drive the eye's is_detected/eye_color behavior:
--   enemies_nearby   -- HD2Runtime-only: any tracked hostile entity within range of the player.
--   enemies_searching -- Wwise's lighter "alert" keywords, or any combat-tier signal (which
--                        implies awareness too), without requiring full is_detected.
--
-- Diagnostics: DetectionAlert.log (in %LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs) records the
-- startup checks, the first few calls to each hooked Wwise callback, every state change, errors,
-- and a heartbeat every 5 s. Startup and error lines are also copied to HD2Runtime.log.

local MOD_ID = "mods/bunkerturreteye/detection_alert"

local require_ok, hd2_module = pcall(require, "mods/skyeshade/hd2runtime")
local hd2_ok = require_ok and type(hd2_module) == "table"
local hd2 = hd2_ok and hd2_module or nil
local hd2_load_error = nil
if not hd2_ok then
	hd2_load_error = require_ok and ("require returned " .. type(hd2_module)) or tostring(hd2_module)
end

-- The HD2Runtime mod context: its log() writes to HD2Runtime.log, and it owns our subscriptions.
local hd2_mod = nil
local hd2_mod_error = nil
if hd2_ok then
	local mod_ok, context = pcall(hd2.mod, MOD_ID)
	if mod_ok and context then
		hd2_mod = context
	else
		hd2_mod_error = tostring(context)
	end
end

local DetectionAlert = {
	is_detected = false,
	eye_intensity = 0, -- 0 = idle ember glow, 1 = full alert red
	eye_color = nil, -- set below from EYE_COLOR_IDLE
	enemies_nearby = false, -- status-only: HD2Runtime hostile entity within HD2_ENEMY_NEARBY_RANGE_METERS
	enemies_searching = false, -- status-only: alert-tier audio or active combat, short of full detection
}

-- "alert"/"aggro"/"detect" read as the AI noticing/searching, short of confirmed combat;
-- "combat"/"engage"/"hostile"/"battle" read as full engagement (drives is_detected).
local SEARCH_KEYWORDS = { "alert", "aggro", "detect" }
local COMBAT_KEYWORDS = { "combat", "engage", "hostile", "battle" }
local ALERT_OFF_KEYWORDS = { "calm", "stealth", "idle", "explore", "ambient", "patrol", "hidden", "quiet" }

-- Cannon-turret-style eye glow: dim ember red when idle, bright red when detected.
local EYE_COLOR_IDLE = { r = 0.35, g = 0.02, b = 0.02 }
local EYE_COLOR_ALERT = { r = 1.0, g = 0.05, b = 0.05 }
local EYE_RAMP_UP_PER_SECOND = 3.0 -- snaps to alert quickly
local EYE_RAMP_DOWN_PER_SECOND = 1.0 -- fades out slower

DetectionAlert.eye_color = { r = EYE_COLOR_IDLE.r, g = EYE_COLOR_IDLE.g, b = EYE_COLOR_IDLE.b }

-- Advances eye_intensity/eye_color toward the current detection state.
-- NOTE: there is no confirmed in-world draw/material/light API reachable from this
-- sandboxed entry point (only WwiseFlowCallbacks/WwiseVisualization are real globals here).
-- This keeps DetectionAlert.eye_intensity/eye_color ready to feed a real light-set or
-- material call the moment one is confirmed; wire that call in where noted in tick().
local function update_eye_glow(dt)
	local target = DetectionAlert.is_detected and 1 or 0
	local rate = target > DetectionAlert.eye_intensity and EYE_RAMP_UP_PER_SECOND or EYE_RAMP_DOWN_PER_SECOND

	if DetectionAlert.eye_intensity < target then
		DetectionAlert.eye_intensity = math.min(target, DetectionAlert.eye_intensity + rate * dt)
	else
		DetectionAlert.eye_intensity = math.max(target, DetectionAlert.eye_intensity - rate * dt)
	end

	local t = DetectionAlert.eye_intensity
	DetectionAlert.eye_color.r = EYE_COLOR_IDLE.r + (EYE_COLOR_ALERT.r - EYE_COLOR_IDLE.r) * t
	DetectionAlert.eye_color.g = EYE_COLOR_IDLE.g + (EYE_COLOR_ALERT.g - EYE_COLOR_IDLE.g) * t
	DetectionAlert.eye_color.b = EYE_COLOR_IDLE.b + (EYE_COLOR_ALERT.b - EYE_COLOR_IDLE.b) * t
end

-- Instantly snaps the eye to full alert red, bypassing the ramp (used for the
-- near-turret damage flash, which should read as a startle, not a fade-in).
local function flash_eye_now()
	DetectionAlert.eye_intensity = 1
	DetectionAlert.eye_color.r = EYE_COLOR_ALERT.r
	DetectionAlert.eye_color.g = EYE_COLOR_ALERT.g
	DetectionAlert.eye_color.b = EYE_COLOR_ALERT.b
end

-- Lua patterns have no alternation operator, so check a keyword list plainly.
local function contains_any(haystack, keywords)
	for _, keyword in ipairs(keywords) do
		if haystack:find(keyword, 1, true) then
			return true
		end
	end
	return false
end

-- Logging: DetectionAlert.log and DetectionAlertStatus.log are opened through the loader's
-- open_log when it offers one, otherwise directly in the loader's log folder. A line that can't
-- reach a file goes to HD2Runtime.log (via hd2.mod), or the console as a last resort.
local LOG_DIR_SUFFIX = "\\CowboyBingus\\Helldivers2\\Logs\\"
local LOG_FILE_NAME = "DetectionAlert.log"
local STATUS_FILE_NAME = "DetectionAlertStatus.log"
local STATUS_MAX_BYTES = 64 * 1024 -- the overlay re-reads this file every tick, so keep it small
local WWISE_DETAIL_LIMIT = 40 -- full argument dumps per Wwise callback
local HEARTBEAT_INTERVAL_SECONDS = 5

local elapsed_time = 0
local log_file = nil -- nil = not opened yet, false = unavailable
local log_target = "not opened yet"
local error_count = 0

-- Returns an open file handle and where it points, or nil and the reason it could not open.
local function open_log_file(file_name)
	local loader = rawget(_G, "CowboyBingusModLoader")
	if type(loader) == "table" and type(loader.open_log) == "function" then
		local ok, handle = pcall(loader.open_log, file_name)
		if ok and handle then
			return handle, "CowboyBingusModLoader.open_log(" .. file_name .. ")"
		end
	end
	if type(os) == "table" and type(os.getenv) == "function" and type(io) == "table" and type(io.open) == "function" then
		local base = os.getenv("LOCALAPPDATA")
		if base then
			local path = base .. LOG_DIR_SUFFIX .. file_name
			local handle = io.open(path, "w")
			if handle then
				return handle, path
			end
			return nil, "io.open failed for " .. path
		end
	end
	return nil, "no loader open_log, and no io/os access to LOCALAPPDATA"
end

local function write_line(handle, text)
	handle:write(text, "\n")
	handle:flush()
end

-- Used while no file is open: HD2Runtime.log first, then the console.
local function emit_fallback(text)
	if hd2_mod and pcall(hd2_mod.log, hd2_mod, text) then
		return
	end
	if type(print) == "function" then
		print(text)
	end
end

local function log(text)
	if log_file == nil then
		local handle, target = open_log_file(LOG_FILE_NAME)
		log_file = handle or false
		log_target = handle and target or ("unavailable: " .. target)
	end
	if log_file then
		if pcall(write_line, log_file, text) then
			return
		end
		log_file = false
		log_target = "unavailable: write failed"
	end
	emit_fallback(text)
end

-- Like log(), and also copied to HD2Runtime.log / console so startup and failures show up there too.
local function log_important(text)
	log(text)
	if log_file then
		emit_fallback(text)
	end
end

local function log_error(where, err)
	error_count = error_count + 1
	if error_count <= 20 or error_count % 100 == 0 then
		log_important(string.format("[DetectionAlert] ERROR #%d in %s: %s", error_count, where, tostring(err)))
	end
end

-- Probe: a read-only inventory of what this runtime exposes. It records names and types and
-- only reads plain values, so it never calls game or loader functions. It runs once when a game
-- session starts and at PROBE_TIMES (seconds), because mods that load after this one only appear later.
local PROBE_TIMES = { 60 }
local session_probe_done = false
local next_session_check = 1
local PROBE_NAMES_PER_LINE = 15
local probe_index = 1

local function typed_entries(tbl)
	local entries = {}
	for key, value in pairs(tbl) do
		entries[#entries + 1] = tostring(key) .. "=" .. type(value)
	end
	table.sort(entries)
	return entries
end

local function log_list(label, entries, limit)
	log(string.format("[DetectionAlert]   %s (%d):", label, #entries))
	local shown = math.min(#entries, limit)
	for first = 1, shown, PROBE_NAMES_PER_LINE do
		local last = math.min(first + PROBE_NAMES_PER_LINE - 1, shown)
		log("[DetectionAlert]     " .. table.concat(entries, " ", first, last))
	end
	if #entries > shown then
		log(string.format("[DetectionAlert]     ... %d more", #entries - shown))
	end
end

-- Only string, number and boolean fields: printing them cannot run any user code.
local function scalar_fields(tbl)
	local parts = {}
	for key, value in pairs(tbl) do
		local kind = type(value)
		if kind == "string" or kind == "number" or kind == "boolean" then
			parts[#parts + 1] = tostring(key) .. "=" .. tostring(value)
		end
	end
	table.sort(parts)
	return table.concat(parts, " ")
end

local function aggro_counts()
	local ac = rawget(_G, "AggroCounter")
	if type(ac) ~= "table" or type(ac.counts) ~= "table" then
		return nil
	end
	return ac.counts
end

local function aggro_summary()
	local counts = aggro_counts()
	if not counts then
		return "n/a"
	end
	return string.format("near=%s/search=%s/me=%s/team=%s",
		tostring(counts.near), tostring(counts.search), tostring(counts.me), tostring(counts.team))
end

local function probe_runtime()
	local jit_table = rawget(_G, "jit")
	log(string.format("[DetectionAlert]   runtime: _VERSION=%s jit=%s ffi=%s bit=%s",
		tostring(_VERSION), type(jit_table), type(rawget(_G, "ffi")), type(rawget(_G, "bit"))))
	if type(jit_table) == "table" then
		log("[DetectionAlert]   jit: " .. scalar_fields(jit_table))
	end

	local loader = rawget(_G, "CowboyBingusModLoader")
	if type(loader) == "table" then
		log("[DetectionAlert]   loader: " .. scalar_fields(loader))
		log_list("loader members", typed_entries(loader), 60)
		if type(loader.jit) == "table" then
			log("[DetectionAlert]   loader.jit: " .. scalar_fields(loader.jit))
		end
	else
		log("[DetectionAlert]   CowboyBingusModLoader=" .. type(loader))
	end

	local ac = rawget(_G, "AggroCounter")
	if type(ac) == "table" then
		log(string.format("[DetectionAlert]   AggroCounter: api=%s version=%s status=%s counts=%s",
			tostring(ac.api), tostring(ac.version), tostring(ac.status), aggro_summary()))
	else
		log("[DetectionAlert]   AggroCounter=" .. type(ac))
	end

	local engine = rawget(_G, "stingray")
	if type(engine) ~= "table" then
		log("[DetectionAlert]   stingray=" .. type(engine))
		return
	end
	local members, tables = 0, 0
	for _, value in pairs(engine) do
		members = members + 1
		if type(value) == "table" then
			tables = tables + 1
		end
	end
	log(string.format("[DetectionAlert]   stingray: members=%d tables=%d", members, tables))
end

local function run_probe()
	log(string.format("[DetectionAlert] probe t=%.1f", elapsed_time))
	probe_runtime()
end

-- Same read-only getter that P2P-Ping polls (Network.game_session); the probe body itself calls nothing.
local function in_game_session()
	local engine = rawget(_G, "stingray")
	local network = type(engine) == "table" and rawget(engine, "Network") or nil
	if type(network) ~= "table" or type(rawget(network, "game_session")) ~= "function" then
		return false
	end
	local ok, session = pcall(network.game_session)
	return ok and session ~= nil
end

-- Enemy sampler (read-only, shadow mode). While a game session is active it walks the main world's
-- units with engine getters only and counts them by resource name and animation state. It changes no
-- game state and does not drive the eye: the counts go to the heartbeat and a detail line every 30 s,
-- so the state names can be checked in game before anything depends on them. A full pass takes about
-- SAMPLE_PASS_SECONDS, spread over frames, with at most SAMPLE_MAX_UNITS_PER_FRAME units in one frame.
local SAMPLE_PASS_SECONDS = 5
local SAMPLE_MAX_UNITS_PER_FRAME = 100
local SAMPLE_DETAIL_INTERVAL_SECONDS = 30
local SAMPLE_TOP_COUNT = 8
local game_session_active = false
local next_sample_detail = nil
local last_pass = nil
local sample_fns = {}
local sample_failed = {}
-- Animation states are integers in this build, so the last state of each unit is kept (weakly) to
-- count transitions between samples. How the engine hands back resource ids is picked from the
-- first sample: "string", "idstring64" (via IdString64.to_string), "hex", or "type".
local last_state = setmetatable({}, { __mode = "k" })
local sample_changes_total = 0
local resource_mode = nil
local sample_diagnostics_logged = false
-- A pass walks a snapshot of World.units taken when the pass starts. The cursor and the fractional
-- unit budget carry over between frames. Pass counts are logged when the walk wraps.
local sample_units = nil
local sample_cursor = 1
local sample_credit = 0
local pass_units, pass_animated, pass_changed = 0, 0, 0
local pass_cost = 0
-- Counts since the last detail line, written every SAMPLE_DETAIL_INTERVAL_SECONDS.
local detail_units, detail_animated, detail_changed = 0, 0, 0
local detail_states, detail_resources = {}, {}

-- Resolves stingray.<space>.<member> once; false marks a missing function.
local function sample_fn(space_name, member)
	local key = space_name .. "." .. member
	local fn = sample_fns[key]
	if fn == nil then
		local engine = rawget(_G, "stingray")
		local space = type(engine) == "table" and rawget(engine, space_name) or nil
		fn = type(space) == "table" and rawget(space, member) or nil
		if type(fn) ~= "function" then
			fn = false
		end
		sample_fns[key] = fn
	end
	return fn or nil
end

-- Calls one engine getter under pcall. The first failure of each API is logged with its message.
local function sample_call(space_name, member, ...)
	local key = space_name .. "." .. member
	local fn = sample_fn(space_name, member)
	if fn == nil then
		if not sample_failed[key] then
			sample_failed[key] = true
			log("[DetectionAlert] sampler " .. key .. " unavailable")
		end
		return nil
	end
	local ok, result = pcall(fn, ...)
	if ok then
		return result
	end
	if not sample_failed[key] then
		sample_failed[key] = true
		log("[DetectionAlert] sampler " .. key .. " failed: " .. tostring(result))
	end
	return nil
end

local function count_into(counts, key)
	counts[key] = (counts[key] or 0) + 1
end

local function top_counts(counts)
	local list = {}
	for key, value in pairs(counts) do
		list[#list + 1] = { key = key, value = value }
	end
	table.sort(list, function(a, b)
		if a.value ~= b.value then return a.value > b.value end
		return a.key < b.key
	end)
	local parts = {}
	for index = 1, math.min(#list, SAMPLE_TOP_COUNT) do
		parts[#parts + 1] = list[index].key .. "=" .. list[index].value
	end
	return #parts > 0 and table.concat(parts, " ") or "none"
end

-- Strings and numbers are shown as they are; anything else is shown by its type only.
local function describe_state(state)
	local kind = type(state)
	if kind == "string" or kind == "number" or kind == "boolean" then
		return tostring(state)
	end
	return kind
end

local function wall_clock()
	if type(os) ~= "table" or type(os.date) ~= "function" then
		return "?"
	end
	local ok, stamp = pcall(os.date, "%H:%M:%S")
	return ok and stamp or "?"
end

-- Picks how resource ids are turned into text, from the first non-string value the engine returns.
local function choose_resource_mode(value)
	if type(value) == "string" then
		return "string"
	end
	if type(sample_call("IdString64", "to_string", value)) == "string" then
		return "idstring64"
	end
	if type(sample_call("IdString64", "to_hex", value)) == "string" then
		return "hex"
	end
	return "type"
end

local function resource_key(value, mode)
	if mode == "string" and type(value) == "string" then
		return value:sub(1, 80)
	end
	if mode == "idstring64" then
		local text = sample_call("IdString64", "to_string", value)
		if type(text) == "string" then
			return text:sub(1, 80)
		end
	elseif mode == "hex" then
		local hex = sample_call("IdString64", "to_hex", value)
		if type(hex) == "string" then
			return "hex:" .. hex
		end
	end
	return type(value)
end

local function cpu_time()
	if type(os) == "table" and type(os.clock) == "function" then
		return os.clock()
	end
	return 0
end

-- Writes one line per completed pass; cost is the CPU time the sampler used during that pass.
local function log_pass(total)

	log(string.format("[DetectionAlert] pass t=%.1f wall=%s units=%d animated=%d changed=%d cost=%.1fms",
		elapsed_time, wall_clock(), pass_units, pass_animated, pass_changed, pass_cost * 1000))
	last_pass = { total = total, units = pass_units, animated = pass_animated, changed = pass_changed }
	pass_units, pass_animated, pass_changed, pass_cost = 0, 0, 0, 0
end

-- Samples one unit: counts it into the pass and detail totals and records animation-state changes.
local function sample_unit(unit)
	if sample_call("Unit", "alive", unit) ~= true then
		return
	end
	pass_units = pass_units + 1
	detail_units = detail_units + 1
	local resource = sample_call("Unit", "resource_name", unit)
	if resource ~= nil and resource_mode == nil then
		resource_mode = choose_resource_mode(resource)
		log(string.format("[DetectionAlert]   resource sample: type=%s value=%s mode=%s",
			type(resource), describe_state(resource), resource_mode))
	end
	if resource ~= nil and resource_mode ~= nil then
		count_into(detail_resources, resource_key(resource, resource_mode))
	end
	if not sample_diagnostics_logged then
		sample_diagnostics_logged = true
		log("[DetectionAlert]   debug_name sample: " .. describe_state(sample_call("Unit", "debug_name", unit)))
	end
	if sample_call("Unit", "has_animation_state_machine", unit) == true then
		local state = describe_state(sample_call("Unit", "animation_get_state", unit))
		count_into(detail_states, state)
		pass_animated = pass_animated + 1
		detail_animated = detail_animated + 1
		local previous = last_state[unit]
		if previous ~= nil and previous ~= state then
			pass_changed = pass_changed + 1
			detail_changed = detail_changed + 1
			sample_changes_total = sample_changes_total + 1
		end
		last_state[unit] = state
	end
end

-- Runs once per frame while a session is active. A pass takes a snapshot of World.units at its start
-- and samples the share of units due this frame, so a full pass spans SAMPLE_PASS_SECONDS. The per-frame
-- cap keeps one frame short even when a frame is long.
local function sample_enemies(dt)
	if next_sample_detail == nil then
		next_sample_detail = elapsed_time + SAMPLE_DETAIL_INTERVAL_SECONDS
	end
	if sample_units == nil then
		local world = sample_call("Application", "main_world")
		local units = world ~= nil and sample_call("World", "units", world) or nil
		if type(units) ~= "table" or #units == 0 then
			sample_credit = 0
			return
		end
		sample_units = units
		sample_cursor = 1
	end

	local total = #sample_units
	sample_credit = math.min(sample_credit + total * dt / SAMPLE_PASS_SECONDS, SAMPLE_MAX_UNITS_PER_FRAME)
	local count = math.floor(sample_credit)
	sample_credit = sample_credit - count
	for _ = 1, count do
		sample_unit(sample_units[sample_cursor])
		sample_cursor = sample_cursor + 1
		if sample_cursor > total then
			log_pass(total)
			sample_units = nil
			break
		end
	end

	if elapsed_time >= next_sample_detail then
		next_sample_detail = elapsed_time + SAMPLE_DETAIL_INTERVAL_SECONDS
		log(string.format("[DetectionAlert] sample t=%.1f wall=%s total=%d units=%d animated=%d changed=%d changed_total=%d",
			elapsed_time, wall_clock(), total, detail_units, detail_animated, detail_changed, sample_changes_total))
		log("[DetectionAlert]   states: " .. top_counts(detail_states))
		log("[DetectionAlert]   resources: " .. top_counts(detail_resources))
		detail_units, detail_animated, detail_changed = 0, 0, 0
		detail_states, detail_resources = {}, {}
	end
end

local function sample_summary()
	local s = last_pass
	if not s then
		return "n/a"
	end
	return string.format("total=%d/units=%d/animated=%d/changed=%d", s.total, s.units, s.animated, s.changed)
end

-- Marker key: press F9 when a fight starts and again when it stops. Each press writes one MARKER line
-- with the wall clock, so the pass lines can be matched to the fight without relying on memory.
local MARKER_KEY = "f9"
local marker_key_id = nil
local marker_key_ready = false
local marker_key_down = false
local active_marker = false
local function log_marker_key_state()
	log(string.format("[DetectionAlert] marker_key_ready=%s marker_key_down=%s", tostring(marker_key_ready), tostring(marker_key_down)))
end
local function poll_marker_key()
	if not marker_key_ready and elapsed_time >= 1 then
		marker_key_ready = true
		marker_key_id = sample_call("Keyboard", "button_id", MARKER_KEY)
		log(string.format("[DetectionAlert] marker key %s id=%s", MARKER_KEY, tostring(marker_key_id)))
	end
	if marker_key_id == nil then
		return
	end
	local pressed = sample_call("Keyboard", "pressed", marker_key_id) == true
	if pressed and not marker_key_down then
		log_marker_key_state()
		if not active_marker then
			active_marker = true
			log(string.format("[DetectionAlert] START MARKER t=%.1f wall=%s", elapsed_time, wall_clock()))
		else
			active_marker = false
			log(string.format("[DetectionAlert] END MARKER t=%.1f wall=%s", elapsed_time, wall_clock()))
		end
	end
	marker_key_down = pressed
end

-- Two independent signals OR'd together: Wwise combat-audio keywords, and (when
-- HD2Runtime is installed) real combat events. Either one can drive the eye alert.
local wwise_detected = false
local wwise_searching = false
local hd2_combat_active = false

-- Compare before writing, so both directions (DETECTED and HIDDEN) are applied and logged once.
local function set_detected(value, source)
	if DetectionAlert.is_detected == value then
		return
	end
	DetectionAlert.is_detected = value
	log_important(string.format("[DetectionAlert] t=%.2f %s via %s", elapsed_time, value and "DETECTED" or "HIDDEN", source))
end

local function recompute_detection(source)
	set_detected(wwise_detected or hd2_combat_active, source)
end

-- Status-only "enemies_searching": the lighter Wwise alert-tier keywords, or anything
-- that already implies full combat (which implies awareness too). Does not touch
-- is_detected/eye_color, only DetectionAlert.enemies_searching for the log/overlay.
local function set_searching(value, source)
	if DetectionAlert.enemies_searching == value then
		return
	end
	DetectionAlert.enemies_searching = value
	log(string.format("[DetectionAlert] t=%.2f enemies_searching=%s via %s", elapsed_time, tostring(value), source))
end

local function recompute_searching(source)
	set_searching(wwise_searching or hd2_combat_active, source)
end

-- Best-effort class name for table/userdata values via common metatable conventions.
local function class_name_of(value)
	local mt = getmetatable(value)
	if type(mt) ~= "table" then
		return nil
	end
	return mt.__name or mt.class_name or (type(mt.__index) == "table" and mt.__index.__name) or nil
end

local function describe_value(value)
	local class_name = class_name_of(value)
	return string.format(
		"%s%s=%s",
		type(value),
		class_name and (":" .. class_name) or "",
		tostring(value)
	)
end

local function describe_arguments(...)
	local values = {}
	for i = 1, select("#", ...) do
		local value = select(i, ...)
		values[i] = string.format("arg%d[%s]", i, describe_value(value))
	end
	return table.concat(values, ", ")
end

local WWISE_TABLES = { "WwiseFlowCallbacks", "WwiseVisualization" }
local WWISE_SYNC_INTERVAL_SECONDS = 5
local wwise_wrappers = setmetatable({}, { __mode = "k" }) -- our wrappers, so a re-scan never wraps one
local wwise_call_counts = {} -- label -> calls seen
local wwise_total_calls = 0
local wwise_signal_calls = 0
local wwise_signal_matches = 0
local wwise_missing_logged = {}

-- Only these callback labels can change detection; the rest are logged (first calls) and ignored.
local function is_signal_label(label)
	local lower = label:lower()
	return lower:find("wwise_set_state", 1, true)
		or lower:find("wwise_set_switch", 1, true)
		or lower:find("wwise_trigger_event", 1, true)
		or lower:find("wwise_post_trigger", 1, true)
end

local function apply_wwise_detail(label, detail)
	local normalized = detail:lower()
	if contains_any(normalized, ALERT_OFF_KEYWORDS) then
		wwise_detected = false
		wwise_searching = false
	elseif contains_any(normalized, COMBAT_KEYWORDS) then
		wwise_detected = true
		wwise_searching = true
	elseif contains_any(normalized, SEARCH_KEYWORDS) then
		wwise_searching = true
	else
		return
	end
	wwise_signal_matches = wwise_signal_matches + 1
	recompute_detection(label)
	recompute_searching(label)
end

local function on_wwise_call(label, signal, count, ...)
	if signal then
		wwise_signal_calls = wwise_signal_calls + 1
	elseif count > WWISE_DETAIL_LIMIT then
		return
	end

	local detail = describe_arguments(...)
	if count <= WWISE_DETAIL_LIMIT then
		log(string.format("[DetectionAlert] t=%.2f call %s #%d: %s", elapsed_time, label, count, detail))
	end
	if signal then
		apply_wwise_detail(label, detail)
	end
end

local function wrap_wwise_callback(table_name, method_name, original)
	local label = table_name .. "." .. tostring(method_name)
	local signal = is_signal_label(label)
	local wrapper = function(...)
		wwise_total_calls = wwise_total_calls + 1
		local count = (wwise_call_counts[label] or 0) + 1
		wwise_call_counts[label] = count
		local ok, err = pcall(on_wwise_call, label, signal, count, ...)
		if not ok then
			log_error("wwise " .. label, err)
		end
		return original(...)
	end
	wwise_wrappers[wrapper] = true
	return wrapper
end

local function has_unhooked_callbacks(callbacks)
	for _, value in pairs(callbacks) do
		if type(value) == "function" and not wwise_wrappers[value] then
			return true
		end
	end
	return false
end

local function hook_wwise_table(table_name, callbacks)
	local hooked, signals, names = 0, 0, {}
	for method_name, value in pairs(callbacks) do
		if type(value) == "function" and not wwise_wrappers[value] then
			callbacks[method_name] = wrap_wwise_callback(table_name, method_name, value)
			hooked = hooked + 1
		end
		names[#names + 1] = tostring(method_name)
		if is_signal_label(table_name .. "." .. tostring(method_name)) then
			signals = signals + 1
		end
	end
	table.sort(names)
	log_important(string.format("[DetectionAlert] %s: wrapped %d function(s), %d detection-signal; members: %s",
		table_name, hooked, signals, table.concat(names, ", ")))
end

-- Runs at startup and every WWISE_SYNC_INTERVAL_SECONDS: hooks tables that appeared later and
-- re-hooks any table whose functions were replaced.
local function sync_wwise_hooks()
	for _, table_name in ipairs(WWISE_TABLES) do
		local callbacks = rawget(_G, table_name)
		if type(callbacks) ~= "table" then
			if not wwise_missing_logged[table_name] then
				wwise_missing_logged[table_name] = true
				log_important("[DetectionAlert] " .. table_name .. " not found yet; retrying every " .. WWISE_SYNC_INTERVAL_SECONDS .. " s")
			end
		elseif has_unhooked_callbacks(callbacks) then
			hook_wwise_table(table_name, callbacks)
		end
	end
end

-- No in-game HUD/draw API exists in either loader, so the eye state is exposed here for an
-- external overlay app to read instead: one line per tick (throttled). The file is truncated at
-- session start and again whenever it passes STATUS_MAX_BYTES. tools/overlay/DetectionAlertOverlay.ps1
-- polls this file's tail.
local STATUS_WRITE_INTERVAL_SECONDS = 0.1
local status_file = nil -- nil = not opened yet, false = unavailable
local status_bytes = 0
local status_announced = false
local last_status_write = -math.huge

local function open_status_file()
	local handle, target = open_log_file(STATUS_FILE_NAME)
	status_file = handle or false
	status_bytes = 0
	if not status_announced then
		status_announced = true
		log("[DetectionAlert] status file: " .. (handle and target or ("unavailable: " .. target)))
	end
end

local function write_status()
	if status_file == nil then
		open_status_file()
	elseif status_file and status_bytes > STATUS_MAX_BYTES then
		pcall(status_file.close, status_file)
		open_status_file()
	end
	if not status_file then
		return
	end

	local c = DetectionAlert.eye_color or EYE_COLOR_IDLE
	local line = string.format(
		"t=%.2f detected=%d intensity=%.3f r=%.3f g=%.3f b=%.3f nearby=%d searching=%d",
		elapsed_time,
		DetectionAlert.is_detected and 1 or 0,
		DetectionAlert.eye_intensity,
		c.r, c.g, c.b,
		DetectionAlert.enemies_nearby and 1 or 0,
		DetectionAlert.enemies_searching and 1 or 0
	)
	local ok, err = pcall(write_line, status_file, line)
	if ok then
		if status_bytes == 0 then
			log("[DetectionAlert] status file: first write ok")
		end
		status_bytes = status_bytes + #line + 1
	else
		status_file = false
		log_error("write_status", err)
	end
end

-- A combat event resets the decay timer and flips hd2_combat_active on immediately;
-- tick() below decays it back off after HD2_COMBAT_TIMEOUT_SECONDS of quiet.
local HD2_COMBAT_TIMEOUT_SECONDS = 8
local hd2_last_combat_time = -math.huge

local function mark_hd2_combat(label)
	hd2_last_combat_time = elapsed_time
	if not hd2_combat_active then
		hd2_combat_active = true
		recompute_detection(label)
	end
	recompute_searching(label)
end

-- HD2Runtime has no pre-fire event (it patches no game code) and no attacker identity
-- for NPC-caused damage (only player-credited hits carry a creditor). So "an Automaton
-- turret is about to fire" can't be detected or attributed directly. This instead
-- flashes when the player takes damage with no identifiable player attacker while a
-- tracked Automaton turret structure is within range: a reactive, approximate proxy.
local HD2_TURRET_RANGE_METERS = 60 -- heuristic guess, not a published engagement range
local hd2_nearby_turrets = {} -- entity_id -> HD2EntityHandle

-- Status-only "enemies_nearby": any tracked hostile entity (any faction, event.enemy ==
-- true) within range of the player. Separate from the turret tracking above, which
-- exists for the near-turret damage flash, not for this status.
local HD2_ENEMY_NEARBY_RANGE_METERS = 30 -- heuristic guess, not a published aggro range
local hd2_nearby_enemies = {} -- entity_id -> HD2EntityHandle

local function is_turret_structure(event)
	if event.faction ~= "automatons" then
		return false
	end
	local haystack = ((event.name or "") .. " " .. (event.semantic_id or "")):lower()
	return haystack:find("turret", 1, true) ~= nil
end

-- Shared proximity check: true if any valid, tracked entity in `entities` is within
-- `range_meters` of the local player. Prunes entries that are no longer valid.
local function player_near_any(entities, range_meters)
	if not hd2_ok then
		return false
	end
	local player = hd2.local_player()
	local here = player and player:position()
	if not here then
		return false
	end

	for entity_id, entity in pairs(entities) do
		if entity:is_valid() then
			local there = entity:position()
			if there and here:distance(there) <= range_meters then
				return true
			end
		else
			entities[entity_id] = nil
		end
	end
	return false
end

local function player_near_any_turret()
	return player_near_any(hd2_nearby_turrets, HD2_TURRET_RANGE_METERS)
end

local function player_near_any_enemy()
	return player_near_any(hd2_nearby_enemies, HD2_ENEMY_NEARBY_RANGE_METERS)
end

local last_flash_log = -math.huge

-- Every HD2 handler runs through guarded(): an error is logged under the event's name and
-- cannot stop the other subscriptions.
local function guarded(label, handler)
	return function(event)
		local ok, err = pcall(handler, event)
		if not ok then
			log_error(label, err)
		end
	end
end

local function on_player_damaged(event)
	mark_hd2_combat("hd2:player_damaged")
	if not event.local_attacker and player_near_any_turret() then
		flash_eye_now()
		if elapsed_time - last_flash_log >= 1 then
			last_flash_log = elapsed_time
			log(string.format("[DetectionAlert] t=%.2f near-turret damage flash", elapsed_time))
		end
	end
end

local function on_entity_damaged(event)
	if event.local_attacker then
		mark_hd2_combat("hd2:entity_damaged")
	end
end

local function on_entity_killed(event)
	if event.local_killer then
		mark_hd2_combat("hd2:entity_killed")
	end
end

local function on_entity_spawned(event)
	if event.entity_id == nil or event.entity == nil then
		return
	end
	if is_turret_structure(event) then
		hd2_nearby_turrets[event.entity_id] = event.entity
		log(string.format("[DetectionAlert] t=%.2f tracking turret %s (id %s)", elapsed_time, tostring(event.semantic_id), tostring(event.entity_id)))
	end
	if event.enemy then
		hd2_nearby_enemies[event.entity_id] = event.entity
	end
end

local function on_entity_died(event)
	if event.entity_id ~= nil then
		hd2_nearby_turrets[event.entity_id] = nil
		hd2_nearby_enemies[event.entity_id] = nil
	end
end

local function on_mission_ended()
	hd2_combat_active = false
	hd2_last_combat_time = -math.huge
	hd2_nearby_turrets = {}
	hd2_nearby_enemies = {}
	wwise_detected = false
	wwise_searching = false
	DetectionAlert.enemies_nearby = false
	log_important(string.format("[DetectionAlert] t=%.2f mission ended: clearing combat state", elapsed_time))
	recompute_detection("hd2:mission_ended")
	recompute_searching("hd2:mission_ended")
end

-- Subscribes through the mod context, so the handler is attributed to this mod. The returned
-- state (active, or rejected/failed with a reason) is logged so a refused event is visible.
local function subscribe(name, handler)
	local ok, sub = pcall(hd2_mod.on, hd2_mod, name, guarded(name, handler), { id = "detection_alert_" .. name })
	if not ok then
		log_important(string.format("[DetectionAlert] subscribe %s FAILED: %s", name, tostring(sub)))
		return false
	end
	local state = type(sub) == "table" and sub.state or "unknown"
	local reason = type(sub) == "table" and sub.reason or nil
	log_important(string.format("[DetectionAlert] subscribed %s: state=%s%s", name, tostring(state),
		reason and (" reason=" .. tostring(reason)) or ""))
	return true
end

local function hook_hd2_events()
	if not hd2_ok then
		log_important("[DetectionAlert] HD2Runtime not available (" .. tostring(hd2_load_error) .. "); Wwise heuristic only")
		return false
	end
	if not hd2_mod then
		log_important("[DetectionAlert] HD2Runtime loaded but hd2.mod(MOD_ID) failed: " .. tostring(hd2_mod_error))
		return false
	end

	local subscriptions = {
		{ "player_damaged", on_player_damaged },
		{ "entity_damaged", on_entity_damaged },
		{ "entity_killed", on_entity_killed },
		{ "entity_spawned", on_entity_spawned },
		{ "entity_died", on_entity_died },
		{ "mission_ended", on_mission_ended },
	}
	local all_ok = true
	for _, entry in ipairs(subscriptions) do
		if not subscribe(entry[1], entry[2]) then
			all_ok = false
		end
	end
	return all_ok
end

local NEARBY_CHECK_INTERVAL_SECONDS = 0.25
local last_nearby_check = -math.huge
local next_wwise_sync = 0
local next_heartbeat = HEARTBEAT_INTERVAL_SECONDS

local function count_entries(entries)
	local n = 0
	for _ in pairs(entries) do
		n = n + 1
	end
	return n
end

local function heartbeat()
	local game_state = "n/a"
	if hd2_ok then
		local ok, state = pcall(hd2.game_state)
		if ok and type(state) == "table" then
			game_state = tostring(state.name)
		end
	end
	log(string.format(
		"[DetectionAlert] t=%.1f heartbeat detected=%s searching=%s nearby=%s hd2_combat=%s game_state=%s turrets=%d enemies=%d wwise_calls=%d wwise_signal_calls=%d wwise_matches=%d errors=%d aggro=%s sample=%s status_bytes=%d",
		elapsed_time,
		tostring(DetectionAlert.is_detected),
		tostring(DetectionAlert.enemies_searching),
		tostring(DetectionAlert.enemies_nearby),
		tostring(hd2_combat_active),
		game_state,
		count_entries(hd2_nearby_turrets),
		count_entries(hd2_nearby_enemies),
		wwise_total_calls,
		wwise_signal_calls,
		wwise_signal_matches,
		error_count,
		aggro_summary(),
		sample_summary(),
		status_bytes
	))
end

local function tick(dt)
	elapsed_time = elapsed_time + dt
	update_eye_glow(dt)
	-- Pending: once a real turret light/material draw call is confirmed, call it here
	-- with DetectionAlert.eye_color / DetectionAlert.eye_intensity.

	-- enemies_nearby needs live positions, so it has its own throttle instead of running per event.
	if hd2_ok and elapsed_time - last_nearby_check >= NEARBY_CHECK_INTERVAL_SECONDS then
		last_nearby_check = elapsed_time
		local ok, nearby = pcall(player_near_any_enemy)
		if ok then
			DetectionAlert.enemies_nearby = nearby
		else
			log_error("enemies_nearby", nearby)
		end
	end

	if elapsed_time - last_status_write >= STATUS_WRITE_INTERVAL_SECONDS then
		last_status_write = elapsed_time
		write_status()
	end

	if hd2_combat_active and (elapsed_time - hd2_last_combat_time) >= HD2_COMBAT_TIMEOUT_SECONDS then
		hd2_combat_active = false
		recompute_detection("hd2:timeout")
		recompute_searching("hd2:timeout")
	end

	if elapsed_time >= next_wwise_sync then
		next_wwise_sync = elapsed_time + WWISE_SYNC_INTERVAL_SECONDS
		local ok, err = pcall(sync_wwise_hooks)
		if not ok then
			log_error("sync_wwise_hooks", err)
		end
	end

	if elapsed_time >= next_heartbeat then
		next_heartbeat = elapsed_time + HEARTBEAT_INTERVAL_SECONDS
		heartbeat()
	end

	poll_marker_key()

	if elapsed_time >= next_session_check then
		next_session_check = elapsed_time + 1
		game_session_active = in_game_session()
		if game_session_active and not session_probe_done then
			session_probe_done = true
			log(string.format("[DetectionAlert] game session detected at t=%.1f", elapsed_time))
			local ok, err = pcall(run_probe)
			if not ok then
				log_error("probe", err)
			end
		end
	end

	if not game_session_active then
		last_pass = nil
		sample_units = nil
		sample_credit = 0
	else
		local started = cpu_time()
		local ok, err = pcall(sample_enemies, dt)
		pass_cost = pass_cost + (cpu_time() - started)
		if not ok then
			log_error("sampler", err)
		end
	end

	if probe_index <= #PROBE_TIMES and elapsed_time >= PROBE_TIMES[probe_index] then
		probe_index = probe_index + 1
		local ok, err = pcall(run_probe)
		if not ok then
			log_error("probe", err)
		end
	end
end

-- Gameplay mods wrap the global `update` (the loader's overlay module does the same). Chain to any
-- existing `update` so other mods' ticks keep running, and keep our own errors out of the game's tick.
local function install_update_hook()
	local previous_update = rawget(_G, "update")
	_G.update = function(dt, ...)
		if previous_update then
			previous_update(dt, ...)
		end
		local ok, err = pcall(tick, tonumber(dt) or 0)
		if not ok then
			log_error("update tick", err)
		end
	end
	log_important("[DetectionAlert] update hook installed; previous update() " .. (previous_update and "chained" or "absent"))
end

local function report_environment()
	local function kind(name)
		return type(rawget(_G, name))
	end
	local loader = rawget(_G, "CowboyBingusModLoader")
	log_important(string.format("[DetectionAlert] start: %s, t=%.2f", tostring(_VERSION), elapsed_time))
	log_important(string.format(
		"[DetectionAlert] env: CowboyBingusModLoader=%s open_log=%s WwiseFlowCallbacks=%s WwiseVisualization=%s update=%s io=%s os.getenv=%s",
		kind("CowboyBingusModLoader"),
		type(loader) == "table" and type(loader.open_log) or "n/a",
		kind("WwiseFlowCallbacks"),
		kind("WwiseVisualization"),
		kind("update"),
		kind("io"),
		(type(os) == "table" and type(os.getenv)) or "n/a"
	))
	if hd2_ok then
		log_important("[DetectionAlert] HD2Runtime: loaded; hd2.mod context " .. (hd2_mod and "ready" or ("failed: " .. tostring(hd2_mod_error))))
	else
		log_important("[DetectionAlert] HD2Runtime: not loaded (" .. tostring(hd2_load_error) .. ")")
	end
	log_important("[DetectionAlert] log file: " .. tostring(log_target))
end

report_environment()
install_update_hook()

local hd2_ok_hooks, hd2_hook_error = pcall(hook_hd2_events)
if not hd2_ok_hooks then
	log_error("hook_hd2_events", hd2_hook_error)
end

local wwise_ok, wwise_error = pcall(sync_wwise_hooks)
if not wwise_ok then
	log_error("sync_wwise_hooks", wwise_error)
end

log_important(string.format("[DetectionAlert] startup done: status every %.1f s, heartbeat every %d s", STATUS_WRITE_INTERVAL_SECONDS, HEARTBEAT_INTERVAL_SECONDS))

return DetectionAlert
