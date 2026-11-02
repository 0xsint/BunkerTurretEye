-- Headless harness: loads the mod under a fake Helldivers 2 environment so the
-- detection logic can be exercised on a desktop, with no game and no files touched.
--
-- It gives the mod a sandboxed _G, records every global the mod writes (anything it
-- writes is a global the mod should not leave behind), fakes the stingray engine
-- tables the sampler uses, and drives update(dt) over a scripted scenario.
--
-- Scenario format (see simulate.lua): a list of phases, each naming how many enemies
-- near the local player and near each teammate are changing animation state.

local harness = {}

-- Stands in for the root of the Chef loader's folder (%APPDATA%\Arrowhead\Helldivers2) inside the sandbox.
harness.sandbox_root = "<sandbox>"
harness.log_directory = harness.sandbox_root .. "\\Arrowhead\\Helldivers2"
-- Where the loader kept mod files before it moved them to log_directory: chef.previous_directory.
harness.previous_directory = harness.sandbox_root .. "\\Local"

-- A log sink that keeps lines in memory instead of writing to disk.
local function make_log_handle(sink)
	return {
		write = function(self, ...)
			local parts = { ... }
			sink[#sink + 1] = table.concat(parts, ""):gsub("\n$", "")
		end,
		flush = function() end,
		close = function() end,
	}
end

-- An in-memory stand-in for `io`, so the mod's probe-state file never touches the real
-- Chef's log folder. `files` maps a path to its contents; a scenario can seed it to replay what a
-- previous run (or a run that crashed mid-probe) left behind, and read it back afterwards.
local function make_io(files, sinks)
	local function handle_for(path, append)
		if not append then
			files[path] = ""
		end
		return {
			write = function(self, ...)
				files[path] = (files[path] or "") .. table.concat({ ... }, "")
			end,
			flush = function() end,
			close = function() end,
		}
	end
	return {
		open = function(path, mode)
			mode = mode or "r"
			if sinks[path] then
				return make_log_handle(sinks[path])
			end
			if mode:find("r", 1, true) then
				local body = files[path]
				if body == nil then
					return nil, path .. ": no such file"
				end
				local cursor = 1
				return {
					lines = function()
						return function()
							if cursor > #body then
								return nil
							end
							local stop = body:find("\n", cursor, true)
							local line
							if stop then
								line, cursor = body:sub(cursor, stop - 1), stop + 1
							else
								line, cursor = body:sub(cursor), #body + 1
							end
							return line
						end
					end,
					read = function() return body end,
					close = function() end,
				}
			end
			return handle_for(path, mode:find("a", 1, true) ~= nil)
		end,
	}
end

-- Units are plain tables in the fake world; the engine getters below read their fields.
local function make_unit(resource, state, x, y, z)
	return { resource = resource, state = state, pos = { x or 0, y or 0, z or 0 }, alive = true, animated = true }
end
harness.make_unit = make_unit

-- Builds the fake `stingray` table. Only the getters the mod actually calls are provided,
-- so a call the mod adds without this harness knowing shows up as "unavailable" in its log.
local function make_stingray(world)
	local function vec(x, y, z) return { x, y, z } end

	local stingray
	stingray = {
		Application = {
			main_world = function() return world end,
			worlds = function() return { world } end,
		},
		World = {
			units = function(w) return w.units end,
			-- A screen gui that records what was drawn, so the HUD layout can be asserted. Set
			-- world.gui_api = false for a build where the draw path is missing.
			create_screen_gui = function(w)
				if w.gui_api == false then
					return nil
				end
				w.gui = w.gui or { texts = {}, next_id = 0 }
				return w.gui
			end,
			destroy_gui = function(w) w.gui = nil end,
		},
		-- The five Gui calls the mod is willing to make, and nothing else.
		Gui = {
			resolution = function() return world.screen_width or 1920, world.screen_height or 1080 end,
			text = function(gui, text, font, size, material, position, color)
				gui.next_id = gui.next_id + 1
				gui.texts[gui.next_id] = { text = text, font = font, size = size,
					x = position[1], y = position[2], color = color }
				return gui.next_id
			end,
			destroy_text = function(gui, id) gui.texts[id] = nil end,
			set_visible = function() end,
		},
		Vector2 = function(x, y) return { x, y } end,
		Color = function(a, r, g, b) return { a = a, r = r, g = g, b = b } end,
		Unit = {
			alive = function(u) return type(u) == "table" and u.alive == true end,
			resource_name = function(u) return u.resource end,
			has_animation_state_machine = function(u) return u.animated == true end,
			animation_get_state = function(u) return u.state end,
			world_position = function(u) return vec(u.pos[1], u.pos[2], u.pos[3]) end,
			debug_name = function(u) return u.resource end,
			-- Present only when the scenario asks for it, so both branches of resolve_me can be tested:
			-- a build that can name the local player, and one that cannot. `fatal_camera_api` models the
			-- real failure: a native call that never returns, which is what Unit.has_camera did.
			num_cameras = world.camera_api and function(u)
				if world.fatal_camera_api then error("HARNESS: this call would have killed the game", 0) end
				return u.is_local and 1 or 0
			end or nil,
		},
		Vector3 = {
			distance_squared = function(a, b)
				local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
				return dx * dx + dy * dy + dz * dz
			end,
		},
		IdString64 = {
			to_string = function(v) return tostring(v) end,
		},
		Network = {
			game_session = function() return world.session end,
		},
	}
	return stingray
end

-- Loads the mod source with its own _G. Returns the mod table, the captured log lines,
-- the fake world, and the set of globals the mod created.
function harness.load(source, chunk_name, world)
	local log_lines, status_lines = {}, {}
	local written_globals = {}
	local status_path = harness.log_directory .. "\\DetectionAlertStatus.log"

	local env = {}
	local real = _G
	env._G = env
	-- The fake game is installed with rawset, before the recorder below is attached, so it does not
	-- show up as something the mod created.
	rawset(env, "stingray", make_stingray(world))
	-- Chef Shared Loader's helper table, as an addon gets it: its own log file (own_log) and the key reads
	-- (key_known, key_pressed). Only what the mod calls is here.
	local chef = {
		loader = "Chef Shared Loader",
		loader_version = "1.5.0",
		api = 1,
		log_directory = harness.log_directory,
		log_file = nil,
		previous_directory = harness.previous_directory,
		own_log = function(name)
			chef.log_file = harness.log_directory .. "\\" .. name .. ".log"
			return true
		end,
		log = function(fmt, ...)
			log_lines[#log_lines + 1] = string.format(fmt, ...)
		end,
		key_known = function() return true end,
		key_pressed = function(name) return world.pressed_key == name end,
	}
	rawset(env, "chef", chef)
	local files = world.files or {}
	rawset(env, "io", make_io(files, { [status_path] = status_lines }))
	-- Reads fall through to the real standard library; writes are recorded and kept inside the sandbox,
	-- so the mod can never touch the harness's own globals.
	setmetatable(env, {
		__index = function(_, key) return real[key] end,
		__newindex = function(_, key, value)
			written_globals[key] = type(value)
			rawset(env, key, value)
		end,
	})

	local chunk, err = loadstring(source, "@" .. chunk_name)
	if chunk == nil then
		return nil, err
	end
	setfenv(chunk, env)
	local ok, mod = pcall(chunk)
	if not ok then
		return nil, mod
	end

	return {
		mod = mod,
		env = env,
		files = files,
		log = log_lines,
		status = status_lines,
		globals = written_globals,
		world = world,
		update = rawget(env, "update"),
	}
end

-- Advances the mod by `seconds` in `dt`-sized steps, calling the scenario's step hook
-- before each tick so the world can move between frames.
function harness.run(session, seconds, dt, on_step)
	local steps = math.floor(seconds / dt + 0.5)
	for step = 1, steps do
		if on_step then on_step(step * dt, session.world) end
		local ok, err = pcall(session.update, dt)
		if not ok then
			return false, err
		end
	end
	return true
end

-- Every log line containing `needle`, newest last.
function harness.grep(session, needle)
	local hits = {}
	for _, line in ipairs(session.log) do
		if line:find(needle, 1, true) then hits[#hits + 1] = line end
	end
	return hits
end

return harness
