-- HD2-Addon: mods/vixenhunny/detection_alert

-- Detection Alert: drives the eye alert from whichever detection source is live.
--   1. Wwise audio-state heuristic: only works on builds that still have WwiseFlowCallbacks.
--   2. Enemy sampler: a read-only walk over the main world's units that counts animation-state changes
--      per pass. Current Steam builds have no Wwise callbacks, so this is the live source there.
-- Requires Bingus Shared Loader v15+ (https://github.com/CowboyBingus/BingusSharedLoader).
-- Targets plain Lua 5.1.4 (current builds have no LuaJIT): no 5.2+ syntax or library calls.
--
-- The Wwise heuristic is a practical proxy for "are we in a fight", not a direct AI-perception query.
-- The sampler is the same kind of proxy: it measures how much enemy animation is changing, not what the
-- AI perceives. Its thresholds (DETECT_*/SEARCH_* below) are starting values, tune them against the
-- "pass" lines in DetectionAlert.log, which show active=, detected= and searching= for every pass.
--
-- enemies_searching is an extra status-only signal (reported in the log/overlay) that does not drive the
-- eye's is_detected/eye_color behavior: the Wwise "alert" keywords, or any combat keyword, or the
-- sampler's lower activity tier, without requiring full is_detected.
--
-- Diagnostics: DetectionAlert.log (in %LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs) records the
-- startup checks, the first few calls to each hooked Wwise callback, every state change, errors,
-- and a heartbeat every 5 s.

local DetectionAlert = {
	is_detected = false,
	eye_intensity = 0, -- 0 = idle ember glow, 1 = full alert red
	eye_color = nil, -- set below from EYE_COLOR_IDLE
	enemies_searching = false, -- status-only: alert-tier audio/activity or combat keywords, short of full detection
	-- Counts for the overlay. search_count/detect_count are REAL numbers, taken from AggroCounter (search / me)
	-- when it is running, and -1 when it is not (it is off on plain Lua 5.1 builds). The sampler cannot tell
	-- searching from detecting per enemy, so it only supplies active_units: units whose animation state
	-- changed in the last pass (ambient units excluded). That is activity, not a count of enemies that saw you.
	search_count = -1,
	detect_count = -1,
	active_units = 0,
	count_source = "none", -- "aggro" or "none"
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
-- reach a file goes to the console.
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

-- Used while no file is open: the console.
local function emit_fallback(text)
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

local function log_error(where, err)
	error_count = error_count + 1
	if error_count <= 20 or error_count % 100 == 0 then
		log(string.format("[DetectionAlert] ERROR #%d in %s: %s", error_count, where, tostring(err)))
	end
end

-- Detection sources. is_detected / enemies_searching are the OR of every live source (Wwise audio keywords,
-- sampler activity). Each source only sets its own flag; these functions combine them. They sit here, ahead
-- of the sampler, because the sampler's pass logging calls them.
local wwise_detected = false
local wwise_searching = false
local sampler_detected = false
local sampler_searching = false

-- Compare before writing, so both directions (DETECTED and HIDDEN) are applied and logged once.
local function set_detected(value, source)
	if DetectionAlert.is_detected == value then
		return
	end
	DetectionAlert.is_detected = value
	log(string.format("[DetectionAlert] t=%.2f %s via %s", elapsed_time, value and "DETECTED" or "HIDDEN", source))
end

local function recompute_detection(source)
	set_detected(wwise_detected or sampler_detected, source)
end

-- Status-only "enemies_searching": the Wwise alert-tier keywords (combat keywords set it too) or the
-- sampler's lower activity tier. Does not touch is_detected/eye_color, only DetectionAlert.enemies_searching
-- for the log/overlay.
local function set_searching(value, source)
	if DetectionAlert.enemies_searching == value then
		return
	end
	DetectionAlert.enemies_searching = value
	log(string.format("[DetectionAlert] t=%.2f enemies_searching=%s via %s", elapsed_time, tostring(value), source))
end

local function recompute_searching(source)
	set_searching(wwise_searching or sampler_searching, source)
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

-- Enemy sampler (read-only). While a game session is active it walks the main world's units with engine
-- getters only and counts them by resource name and animation state. It changes no game state. Each
-- completed pass also feeds the sampler detector below, which drives is_detected / enemies_searching.
-- A full pass takes about SAMPLE_PASS_SECONDS, spread over frames, with at most SAMPLE_MAX_UNITS_PER_FRAME
-- units in one frame.
local SAMPLE_PASS_SECONDS = 5
local SAMPLE_MAX_UNITS_PER_FRAME = 100
local SAMPLE_DETAIL_INTERVAL_SECONDS = 30
local SAMPLE_TOP_COUNT = 8

-- Sampler detection. A pass's "active" value is its animation-state changes minus the ones from
-- AMBIENT_HASHES. Detection is tiered, with hysteresis so the eye does not flicker:
--   DETECTED  (drives the eye): active >= DETECT_ENTER in one pass, or >= DETECT_ENTER_PAIR in two passes
--             in a row. Ends after DETECT_EXIT_PASSES passes in a row at or below DETECT_EXIT_AT_OR_BELOW.
--   SEARCHING (status only):    active >= SEARCH_ENTER. Ends after SEARCH_EXIT_PASSES passes in a row at
--             or below SEARCH_EXIT_AT_OR_BELOW. Always on while DETECTED.
-- These are starting values from one logged session (one pass = SAMPLE_PASS_SECONDS), not tuned numbers.
local SAMPLER_DETECTION = true -- false = the sampler only logs, as before
local AMBIENT_HASHES = {
	-- Unit resources that change state about once per pass whether or not anything is happening. Take hashes
	-- from the "changes" lines in the log: one that shows up as =1 in almost every pass, calm or busy, belongs here.
	["4d1c334d294dfa97"] = true,
	-- Bursts in the ship/lobby only (4 changes in one pass, seen in both logs, never once a mission is running);
	-- without this it turned "searching" on in the ship.
	["685337c9ccf0e45c"] = true,
}
local DETECT_ENTER = 8
local DETECT_ENTER_PAIR = 4 -- low on purpose: small skirmishes count as detection
local DETECT_EXIT_AT_OR_BELOW = 3
local DETECT_EXIT_PASSES = 3
local SEARCH_ENTER = 5
local SEARCH_EXIT_AT_OR_BELOW = 2
local SEARCH_EXIT_PASSES = 2
local MIN_ANIMATED_FOR_DETECTION = 20 -- fewer animated units than this is a loading screen, not a mission

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
-- Changed units counted by resource hash for the current pass, written to the changes line.
local pass_change_keys = {}
-- The same changes as "hash:from>to" (animation-state numbers), to work out what the states mean.
local pass_transitions = {}
-- Counts since the last detail line, written every SAMPLE_DETAIL_INTERVAL_SECONDS.
local detail_units, detail_animated, detail_changed = 0, 0, 0
local detail_states, detail_resources = {}, {}

-- Sampler detector state.
local last_active = 0 -- "active" value of the previous completed pass (the pass being scored is not in it yet)
local detect_low_passes = 0
local search_low_passes = 0

-- Turns one completed pass into the sampler's detection tiers.
local function update_sampler_detection(active, animated)
	if not SAMPLER_DETECTION then
		return
	end
	if animated < MIN_ANIMATED_FOR_DETECTION then
		active = 0
	end

	if not sampler_detected then
		if active >= DETECT_ENTER or (active >= DETECT_ENTER_PAIR and last_active >= DETECT_ENTER_PAIR) then
			sampler_detected = true
			detect_low_passes = 0
		end
	elseif active <= DETECT_EXIT_AT_OR_BELOW then
		detect_low_passes = detect_low_passes + 1
		if detect_low_passes >= DETECT_EXIT_PASSES then
			sampler_detected = false
		end
	else
		detect_low_passes = 0
	end

	if sampler_detected then
		sampler_searching = true
		search_low_passes = 0
	elseif not sampler_searching then
		if active >= SEARCH_ENTER then
			sampler_searching = true
			search_low_passes = 0
		end
	elseif active <= SEARCH_EXIT_AT_OR_BELOW then
		search_low_passes = search_low_passes + 1
		if search_low_passes >= SEARCH_EXIT_PASSES then
			sampler_searching = false
		end
	else
		search_low_passes = 0
	end

	last_active = active
	recompute_detection("sampler")
	recompute_searching("sampler")
end

-- Clears the sampler's tiers when no game session is active, so a finished mission cannot leave the eye lit.
local function reset_sampler_detection()
	if pass_units > 0 then
		pass_units, pass_animated, pass_changed, pass_cost = 0, 0, 0, 0
		pass_change_keys = {}
		pass_transitions = {}
	end
	sampler_detected, sampler_searching = false, false
	last_active = 0
	detect_low_passes, search_low_passes = 0, 0
	recompute_detection("sampler (no session)")
	recompute_searching("sampler (no session)")
end

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

local function top_counts(counts, limit)
	local list = {}
	for key, value in pairs(counts) do
		list[#list + 1] = { key = key, value = value }
	end
	table.sort(list, function(a, b)
		if a.value ~= b.value then return a.value > b.value end
		return a.key < b.key
	end)
	local parts = {}
	for index = 1, math.min(#list, limit or SAMPLE_TOP_COUNT) do
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

-- Resource ids are shortened to their 16-digit hash, so changed units can be matched to hash lists.
local function short_resource_key(key)
	return key:match("%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x") or (key:gsub("%s", "_"))
end

local function cpu_time()
	if type(os) == "table" and type(os.clock) == "function" then
		return os.clock()
	end
	return 0
end

-- Writes one line per completed pass and feeds the pass to the detector. cost is the CPU time the sampler
-- used during that pass; active is changed minus the AMBIENT_HASHES changes.
local function log_pass(total)
	local ambient = 0
	for key, count in pairs(pass_change_keys) do
		if AMBIENT_HASHES[key] then
			ambient = ambient + count
		end
	end
	local active = pass_changed - ambient
	local ok, err = pcall(update_sampler_detection, active, pass_animated)
	if not ok then
		log_error("update_sampler_detection", err)
	end

	log(string.format("[DetectionAlert] pass t=%.1f wall=%s units=%d animated=%d changed=%d active=%d detected=%d searching=%d cost=%.1fms",
		elapsed_time, wall_clock(), pass_units, pass_animated, pass_changed, active,
		DetectionAlert.is_detected and 1 or 0, DetectionAlert.enemies_searching and 1 or 0, pass_cost * 1000))
	if pass_changed > 0 then
		log(string.format("[DetectionAlert] changes t=%.1f %s", elapsed_time, top_counts(pass_change_keys, math.huge)))
		log(string.format("[DetectionAlert] transitions t=%.1f %s", elapsed_time, top_counts(pass_transitions, 16)))
	end
	last_pass = { total = total, units = pass_units, animated = pass_animated, changed = pass_changed }
	pass_units, pass_animated, pass_changed, pass_cost = 0, 0, 0, 0
	pass_change_keys = {}
	pass_transitions = {}
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
			local hash = "unkeyed"
			if resource ~= nil and resource_mode ~= nil then
				hash = short_resource_key(resource_key(resource, resource_mode))
			end
			count_into(pass_change_keys, hash)
			count_into(pass_transitions, hash .. ":" .. previous .. ">" .. state)
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

-- Marker keys, for checking the detector against what you see in game: press MARKER_START_KEY when a fight
-- starts and MARKER_END_KEY when it stops. They are two separate keys, so one missed press cannot turn every
-- later START into an END the way the old single toggle key did. Each marker line carries the detector's
-- state at that moment, and the pass lines before and after show how it got there.
local MARKER_START_KEY = "f9"
local MARKER_END_KEY = "f10"
local marker_keys_ready = false
local marker_keys = {
	{ name = MARKER_START_KEY, label = "START MARKER", id = nil, down = false },
	{ name = MARKER_END_KEY, label = "END MARKER", id = nil, down = false },
}

local function poll_marker_keys()
	if not marker_keys_ready and elapsed_time >= 1 then
		marker_keys_ready = true
		for _, key in ipairs(marker_keys) do
			key.id = sample_call("Keyboard", "button_id", key.name)
			log(string.format("[DetectionAlert] marker key %s id=%s (%s)", key.name, tostring(key.id), key.label))
		end
	end
	for _, key in ipairs(marker_keys) do
		if key.id ~= nil then
			local pressed = sample_call("Keyboard", "pressed", key.id) == true
			if pressed and not key.down then
				log(string.format("[DetectionAlert] %s t=%.1f wall=%s last_active=%d detected=%d searching=%d",
					key.label, elapsed_time, wall_clock(), last_active,
					DetectionAlert.is_detected and 1 or 0, DetectionAlert.enemies_searching and 1 or 0))
			end
			key.down = pressed
		end
	end
end

-- On-screen indicator. It is drawn the way P2P-Ping draws its list, with only the calls that mod runs on this
-- build: World.create_screen_gui on the main world, then Gui.resolution, Gui.text, Gui.destroy_text and
-- Gui.set_visible. No other draw call is used, because a bad native call cannot be caught by pcall. Text is only
-- rebuilt when the state, the lines or the screen position change, and the gui is not touched while no game
-- session is active (its world may be gone). It shows DETECTED / SEARCHING / HIDDEN from the same flags the
-- status file carries, plus the sampler's last "active" value for tuning.
local HUD_ENABLED = true
local HUD_TOGGLE_KEY = "f11" -- shows/hides the indicator, like F8 does for P2P-Ping
local HUD_X_FRACTION = 0.0375 -- from the left edge, as a share of the screen width (same column as P2P-Ping)
local HUD_Y_FRACTION = 0.56 -- from the bottom, above P2P-Ping's list, which starts at 0.48
local HUD_FONT = "core/performance_hud/debug"
local HUD_FONT_SIZE = 26
local HUD_SHOW_ACTIVE = true
local HUD_MAX_FAULTS = 5
local HUD_RETRY_SECONDS = 2

local HUD_LOOK = {
	detected = { text = "(O) DETECTED", r = 255, g = 112, b = 105 },
	searching = { text = "(o) SEARCHING", r = 250, g = 207, b = 96 },
	hidden = { text = "( ) HIDDEN", r = 112, g = 226, b = 145 },
	info = { r = 238, g = 243, b = 235 },
	shadow = { r = 12, g = 15, b = 18 },
}

local hud = {
	visible = true,
	faulted = false,
	faults = 0,
	gui = nil,
	gui_world = nil,
	ids = {}, -- line index -> { shadow = id, main = id }
	cache = {}, -- line index -> what was last drawn, so unchanged lines are left alone
	colors = {},
	logged = {},
	retry_at = 0,
	toggle_ready = false,
	toggle_id = nil,
	toggle_down = false,
}

local function hud_log_once(key, text)
	if not hud.logged[key] then
		hud.logged[key] = true
		log("[DetectionAlert] hud " .. text)
	end
end

local function hud_engine(name)
	local engine = rawget(_G, "stingray")
	return type(engine) == "table" and rawget(engine, name) or nil
end

local function hud_color(name, look)
	local cached = hud.colors[name]
	if cached ~= nil then
		return cached
	end
	local make = hud_engine("Color")
	if make == nil then
		return nil
	end
	local ok, made = pcall(make, 255, look.r, look.g, look.b)
	if ok and made ~= nil then
		hud.colors[name] = made
		return made
	end
	return nil
end

local function hud_forget_text()
	hud.ids, hud.cache = {}, {}
end

local function hud_clear_text(target_gui)
	local destroy = sample_fn("Gui", "destroy_text")
	if destroy and target_gui ~= nil then
		for _, pair in pairs(hud.ids) do
			if pair.shadow ~= nil then
				pcall(destroy, target_gui, pair.shadow)
			end
			if pair.main ~= nil then
				pcall(destroy, target_gui, pair.main)
			end
		end
	end
	hud_forget_text()
end

-- True only if the engine still lists the world, so a gui on a destroyed world is never touched.
local function hud_world_is_live(world)
	local worlds_fn = sample_fn("Application", "worlds")
	if not worlds_fn or world == nil then
		return false
	end
	local ok, worlds = pcall(worlds_fn)
	if not ok or type(worlds) ~= "table" then
		return false
	end
	for index = 1, #worlds do
		if worlds[index] == world then
			return true
		end
	end
	return false
end

local function hud_get_gui(game_world)
	if hud.gui ~= nil and hud.gui_world == game_world then
		return hud.gui
	end
	if hud.gui ~= nil then
		if hud_world_is_live(hud.gui_world) then
			hud_clear_text(hud.gui)
			local destroy_gui = sample_fn("World", "destroy_gui")
			if destroy_gui then
				pcall(destroy_gui, hud.gui_world, hud.gui)
			end
		end
		hud.gui, hud.gui_world = nil, nil
		hud_forget_text()
	end
	local create = sample_fn("World", "create_screen_gui")
	if not create then
		hud_log_once("no_screen_gui", "World.create_screen_gui is missing")
		return nil
	end
	local ok, made = pcall(create, game_world, "scale", 1, 1)
	if not ok or made == nil then
		hud_log_once("gui_failed", "screen gui create failed: " .. tostring(made))
		return nil
	end
	hud.gui, hud.gui_world = made, game_world
	hud_log_once("gui_created", "screen gui created on the main world")
	return made
end

local function hud_lines()
	local state = DetectionAlert.is_detected and "detected" or (DetectionAlert.enemies_searching and "searching" or "hidden")
	local look = HUD_LOOK[state]
	local lines = { { text = look.text, key = state, look = look } }
	if HUD_SHOW_ACTIVE then
		lines[2] = { text = "ACTIVE " .. tostring(last_active), key = "info", look = HUD_LOOK.info }
	end
	return lines
end

local function hud_draw()
	local resolution = sample_fn("Gui", "resolution")
	local text_fn = sample_fn("Gui", "text")
	local Vector2 = hud_engine("Vector2")
	if not resolution or not text_fn or Vector2 == nil then
		hud_log_once("api_missing", string.format("draw api missing: resolution=%s text=%s vector2=%s",
			tostring(resolution ~= nil), tostring(text_fn ~= nil), tostring(Vector2 ~= nil)))
		return
	end
	if elapsed_time < hud.retry_at then
		return
	end
	local game_world = sample_call("Application", "main_world")
	if game_world == nil then
		return
	end
	local target_gui = hud_get_gui(game_world)
	if target_gui == nil then
		hud.retry_at = elapsed_time + HUD_RETRY_SECONDS
		return
	end
	local set_visible = sample_fn("Gui", "set_visible")
	if set_visible then
		pcall(set_visible, target_gui, true)
	end
	local ok, width, height = pcall(resolution)
	if not ok or type(width) ~= "number" or type(height) ~= "number" or width <= 0 or height <= 0 then
		hud_log_once("resolution", "resolution unavailable")
		return
	end
	hud_log_once("resolution", string.format("resolution=%dx%d", width, height))

	local x = math.floor(math.max(24, width * HUD_X_FRACTION) + 0.5)
	local y = math.floor(height * HUD_Y_FRACTION + 0.5)
	local destroy = sample_fn("Gui", "destroy_text")
	local lines = hud_lines()
	for index, line in ipairs(lines) do
		local py = y - (index - 1) * (HUD_FONT_SIZE + 6)
		local cached = hud.cache[index]
		local pair = hud.ids[index] or {}
		if cached == nil or cached.text ~= line.text or cached.key ~= line.key or cached.x ~= x or cached.y ~= py
			or pair.shadow == nil or pair.main == nil then
			if destroy then
				if pair.shadow ~= nil then
					pcall(destroy, target_gui, pair.shadow)
				end
				if pair.main ~= nil then
					pcall(destroy, target_gui, pair.main)
				end
			end
			local ok_shadow, shadow_pos = pcall(Vector2, x + 1, py - 1)
			local ok_main, main_pos = pcall(Vector2, x, py)
			local shadow_color = hud_color("shadow", HUD_LOOK.shadow)
			local main_color = hud_color(line.key, line.look)
			pair = {}
			if ok_shadow and shadow_pos ~= nil and shadow_color ~= nil then
				local drawn, id = pcall(text_fn, target_gui, line.text, HUD_FONT, HUD_FONT_SIZE, HUD_FONT, shadow_pos, shadow_color)
				if drawn then
					pair.shadow = id
				else
					hud_log_once("text_failed", "text call failed: " .. tostring(id))
				end
			end
			if ok_main and main_pos ~= nil and main_color ~= nil then
				local drawn, id = pcall(text_fn, target_gui, line.text, HUD_FONT, HUD_FONT_SIZE, HUD_FONT, main_pos, main_color)
				if drawn then
					pair.main = id
					hud_log_once("text_ok", "text call ok")
				else
					hud_log_once("text_failed", "text call failed: " .. tostring(id))
				end
			end
			hud.ids[index] = pair
			hud.cache[index] = { text = line.text, key = line.key, x = x, y = py }
		end
	end
	for index in pairs(hud.ids) do
		if type(index) == "number" and index > #lines then
			local pair = hud.ids[index]
			if destroy then
				if pair.shadow ~= nil then
					pcall(destroy, target_gui, pair.shadow)
				end
				if pair.main ~= nil then
					pcall(destroy, target_gui, pair.main)
				end
			end
			hud.ids[index], hud.cache[index] = nil, nil
		end
	end
end

local function hud_poll_toggle()
	if not hud.toggle_ready and elapsed_time >= 1 then
		hud.toggle_ready = true
		hud.toggle_id = sample_call("Keyboard", "button_id", HUD_TOGGLE_KEY)
		log(string.format("[DetectionAlert] hud toggle key %s id=%s", HUD_TOGGLE_KEY, tostring(hud.toggle_id)))
	end
	if hud.toggle_id == nil then
		return
	end
	local pressed = sample_call("Keyboard", "pressed", hud.toggle_id) == true
	if pressed and not hud.toggle_down then
		hud.visible = not hud.visible
		if not hud.visible and hud.gui ~= nil and game_session_active then
			hud_clear_text(hud.gui)
			local set_visible = sample_fn("Gui", "set_visible")
			if set_visible then
				pcall(set_visible, hud.gui, false)
			end
		end
		log(string.format("[DetectionAlert] hud visible=%s (toggle key %s)", tostring(hud.visible), HUD_TOGGLE_KEY))
	end
	hud.toggle_down = pressed
end

local function hud_tick()
	hud_poll_toggle()
	if game_session_active and hud.visible then
		hud_draw()
	end
end

-- A fault drops our references (the gui is rebuilt on the next draw); too many in a row disarms the indicator.
local function hud_guarded_tick()
	local ok, err = pcall(hud_tick)
	if ok then
		hud.faults = 0
		return
	end
	hud.faults = hud.faults + 1
	log_error("hud", err)
	hud.gui, hud.gui_world = nil, nil
	hud_forget_text()
	if hud.faults >= HUD_MAX_FAULTS then
		hud.faulted = true
		log("[DetectionAlert] hud disarmed after repeated errors; detection and logging are unaffected")
	end
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
	log(string.format("[DetectionAlert] %s: wrapped %d function(s), %d detection-signal; members: %s",
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
				log("[DetectionAlert] " .. table_name .. " not found yet; retrying every " .. WWISE_SYNC_INTERVAL_SECONDS .. " s")
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

-- Fills the public counts. AggroCounter's own numbers are used only when it is live; otherwise -1 says "not available"
-- (not zero, so an overlay does not show "0 enemies searching" while nothing is being counted).
local function refresh_counts()
	local counts = aggro_counts()
	if counts and type(counts.search) == "number" and type(counts.me) == "number" then
		DetectionAlert.search_count = math.floor(counts.search)
		DetectionAlert.detect_count = math.floor(counts.me)
		DetectionAlert.count_source = "aggro"
	else
		DetectionAlert.search_count = -1
		DetectionAlert.detect_count = -1
		DetectionAlert.count_source = "none"
	end
	DetectionAlert.active_units = last_active
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

	local ok_counts, counts_err = pcall(refresh_counts)
	if not ok_counts then
		log_error("refresh_counts", counts_err)
	end
	local c = DetectionAlert.eye_color or EYE_COLOR_IDLE
	local line = string.format(
		"t=%.2f detected=%d intensity=%.3f r=%.3f g=%.3f b=%.3f searching=%d search_count=%d detect_count=%d active_units=%d count_source=%s",
		elapsed_time,
		DetectionAlert.is_detected and 1 or 0,
		DetectionAlert.eye_intensity,
		c.r, c.g, c.b,
		DetectionAlert.enemies_searching and 1 or 0,
		DetectionAlert.search_count,
		DetectionAlert.detect_count,
		DetectionAlert.active_units,
		DetectionAlert.count_source
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

local next_wwise_sync = 0
local next_heartbeat = HEARTBEAT_INTERVAL_SECONDS

local function heartbeat()
	log(string.format(
		"[DetectionAlert] t=%.1f heartbeat detected=%s searching=%s wwise_calls=%d wwise_signal_calls=%d wwise_matches=%d errors=%d aggro=%s sample=%s active=%d status_bytes=%d",
		elapsed_time,
		tostring(DetectionAlert.is_detected),
		tostring(DetectionAlert.enemies_searching),
		wwise_total_calls,
		wwise_signal_calls,
		wwise_signal_matches,
		error_count,
		aggro_summary(),
		sample_summary(),
		last_active,
		status_bytes
	))
end

local function tick(dt)
	elapsed_time = elapsed_time + dt
	update_eye_glow(dt)
	-- Pending: once a real turret light/material draw call is confirmed, call it here
	-- with DetectionAlert.eye_color / DetectionAlert.eye_intensity.

	if elapsed_time - last_status_write >= STATUS_WRITE_INTERVAL_SECONDS then
		last_status_write = elapsed_time
		write_status()
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

	local marker_ok, marker_err = pcall(poll_marker_keys)
	if not marker_ok then
		log_error("poll_marker_keys", marker_err)
	end

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
		local ok, err = pcall(reset_sampler_detection)
		if not ok then
			log_error("reset_sampler_detection", err)
		end
	else
		local started = cpu_time()
		local ok, err = pcall(sample_enemies, dt)
		pass_cost = pass_cost + (cpu_time() - started)
		if not ok then
			log_error("sampler", err)
		end
	end

	if HUD_ENABLED and not hud.faulted then
		hud_guarded_tick()
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
	log("[DetectionAlert] update hook installed; previous update() " .. (previous_update and "chained" or "absent"))
end

local function report_environment()
	local function kind(name)
		return type(rawget(_G, name))
	end
	local loader = rawget(_G, "CowboyBingusModLoader")
	log(string.format("[DetectionAlert] start: %s, t=%.2f", tostring(_VERSION), elapsed_time))
	log(string.format(
		"[DetectionAlert] env: CowboyBingusModLoader=%s open_log=%s WwiseFlowCallbacks=%s WwiseVisualization=%s update=%s io=%s os.getenv=%s",
		kind("CowboyBingusModLoader"),
		type(loader) == "table" and type(loader.open_log) or "n/a",
		kind("WwiseFlowCallbacks"),
		kind("WwiseVisualization"),
		kind("update"),
		kind("io"),
		(type(os) == "table" and type(os.getenv)) or "n/a"
	))
	log("[DetectionAlert] log file: " .. tostring(log_target))
	log(string.format(
		"[DetectionAlert] sampler detection=%s detect_enter=%d/%d detect_exit=%d x%d search_enter=%d search_exit=%d x%d markers: %s=start %s=end",
		tostring(SAMPLER_DETECTION), DETECT_ENTER, DETECT_ENTER_PAIR, DETECT_EXIT_AT_OR_BELOW, DETECT_EXIT_PASSES,
		SEARCH_ENTER, SEARCH_EXIT_AT_OR_BELOW, SEARCH_EXIT_PASSES, MARKER_START_KEY, MARKER_END_KEY
	))
	log(string.format("[DetectionAlert] hud enabled=%s toggle=%s x=%.4f y=%.2f size=%d show_active=%s",
		tostring(HUD_ENABLED), HUD_TOGGLE_KEY, HUD_X_FRACTION, HUD_Y_FRACTION, HUD_FONT_SIZE, tostring(HUD_SHOW_ACTIVE)))
end

report_environment()
install_update_hook()

local wwise_ok, wwise_error = pcall(sync_wwise_hooks)
if not wwise_ok then
	log_error("sync_wwise_hooks", wwise_error)
end

log(string.format("[DetectionAlert] startup done: status every %.1f s, heartbeat every %d s", STATUS_WRITE_INTERVAL_SECONDS, HEARTBEAT_INTERVAL_SECONDS))

return DetectionAlert
