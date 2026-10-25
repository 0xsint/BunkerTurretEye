-- HD2-Addon: mods/bunkerturreteye/detection_alert

-- Detection Alert: uses Wwise audio state, switch, and event callbacks as a
-- Lua-native heuristic for whether nearby enemies have entered combat.
-- Requires Bingus Shared Loader v15+ (https://github.com/CowboyBingus/BingusSharedLoader).
--
-- This is not a direct AI-perception query. It reports combat-audio state,
-- which is a practical proxy for being detected and can be tuned from the log.

local DetectionAlert = {
	is_detected = false,
	eye_intensity = 0, -- 0 = idle ember glow, 1 = full alert red
	eye_color = nil, -- set below from EYE_COLOR_IDLE
}

local ALERT_ON_KEYWORDS = { "combat", "alert", "detect", "aggro", "engage", "hostile", "battle" }
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
-- material call the moment one is confirmed; wire that call in where noted in hook_update().
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

local log_file
local elapsed_time = 0

local function log(line)
	if log_file == nil and rawget(_G, "CowboyBingusModLoader") and CowboyBingusModLoader.open_log then
		log_file = CowboyBingusModLoader.open_log("DetectionAlert.log") or false
	end

	if log_file then
		log_file:write(line .. "\n")
		log_file:flush()
	end
end

local function on_detection_changed(detected, source)
	DetectionAlert.is_detected = detected
	log(string.format(
		"[DetectionAlert] %s via %s",
		detected and "DETECTED" or "HIDDEN",
		source
	))
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

local function detect_from_wwise(label, ...)
	local detail = describe_arguments(...)
	local normalized = detail:lower()
	log(string.format("[DetectionAlert] t=%.2f call=%s %s", elapsed_time, label, detail))

	local is_detection_signal = label:find("wwise_set_state", 1, true)
		or label:find("wwise_set_switch", 1, true)
		or label:find("wwise_trigger_event", 1, true)
		or label:find("wwise_post_trigger", 1, true)

	if not is_detection_signal then
		return
	end

	if contains_any(normalized, ALERT_OFF_KEYWORDS) then
		if DetectionAlert.is_detected then
			on_detection_changed(false, label)
		end
	elseif contains_any(normalized, ALERT_ON_KEYWORDS) and not DetectionAlert.is_detected then
		on_detection_changed(true, label)
	end
end

local function hook_callback(table_name, callbacks, method_name)
	local original = callbacks[method_name]
	if type(original) ~= "function" then
		return false
	end

	local label = table_name .. "." .. method_name
	callbacks[method_name] = function(...)
		log(string.format("[DetectionAlert] t=%.2f invoke %s : %s", elapsed_time, label, describe_value(original)))
		pcall(detect_from_wwise, label, ...)
		return original(...)
	end
	return true
end

local hooked_tables = {}

local function hook_wwise_table(table_name)
	if hooked_tables[table_name] then
		return
	end

	local callbacks = rawget(_G, table_name)
	if type(callbacks) ~= "table" then
		log("[DetectionAlert] " .. table_name .. " unavailable")
		return
	end

	local hooked = 0
	for method_name, callback in pairs(callbacks) do
		log(string.format("[DetectionAlert] %s.%s : %s", table_name, tostring(method_name), describe_value(callback)))
		if type(callback) == "function" and hook_callback(table_name, callbacks, method_name) then
			hooked = hooked + 1
		end
	end
	hooked_tables[table_name] = hooked > 0
    log("[DetectionAlert] hooked_tables[" .. table_name .. "] = " .. tostring(hooked_tables[table_name]))
	log("[DetectionAlert] hooked " .. tostring(hooked) .. " callbacks under " .. table_name)
end

local function hook_wwise_callbacks()
	hook_wwise_table("WwiseFlowCallbacks")
	hook_wwise_table("WwiseVisualization")
end

-- Confirmed pattern per loader docs: gameplay mods wrap the global `update`
-- (the overlay module "wraps and forwards update and shutdown"). Chain to any
-- existing `update` so we never break other mods' ticks.
local RESCAN_AFTER_SECONDS = 10
local time_since_start = 0
local has_rescanned = false

local function hook_update()
	local original_update = rawget(_G, "update")
	_G.update = function(dt, ...)
		if original_update then
			original_update(dt, ...)
		end

		elapsed_time = elapsed_time + (tonumber(dt) or 0)
		update_eye_glow(tonumber(dt) or 0)
		-- Pending: once a real turret light/material draw call is confirmed, call it here
		-- with DetectionAlert.eye_color / DetectionAlert.eye_intensity.

		-- Retry once in case Wwise callbacks are installed after the loader entry.
		time_since_start = time_since_start + (tonumber(dt) or 0)
		if not has_rescanned and time_since_start >= RESCAN_AFTER_SECONDS then
			has_rescanned = true
			hook_wwise_callbacks()
		end
	end
end

hook_wwise_callbacks()
hook_update()

return DetectionAlert
