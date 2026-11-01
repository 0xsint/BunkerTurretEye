-- HD2-Addon: mods/vixenhunny/detection_alert

-- Detection Alert: drives the eye alert from whichever detection source is live, and splits
-- "enemies are on me" from "enemies are on my squad".
--
-- Sources, in priority order:
--   1. Enemy sampler: a read-only walk over the main world's units that counts animation-state changes
--      and units sitting outside their learned calm states. This is the live source on current builds.
--   2. Wwise audio-state heuristic, on builds that still have WwiseFlowCallbacks (gone on current builds).
--
-- What counts as an enemy. The engine hands out resource hashes, not names, so the sampler used to treat
-- every animated unit as a possible enemy and lean on a learned calm model to tell churn from combat. It
-- no longer does: the ENEMY table below is an explicit whitelist of enemy resource hashes, taken from the
-- EnemyData project, and a unit whose hash is not in it is ignored outright. Hellpods, sentries,
-- exosuits, Guard Dogs, SEAF troopers, civilians, structures and the world's ~17000 props therefore
-- cannot reach any count, and the counts the mod publishes are real enemy counts rather than an
-- activity proxy. That is what replaced the AggroCounter dependency, which needed LuaJIT FFI to read
-- game memory and has been off on every current build.
--
-- Attribution. Every Helldiver shares one unit resource hash, so "which of these four is me" cannot be
-- answered from the resource alone. The sampler keeps every player unit it finds as an ANCHOR, picks one
-- as you (see resolve_me), and attributes each enemy to the anchor it is nearest:
--   me    enemy within CFG.me_radius of your anchor          -> drives is_detected and the eye
--   mate  enemy within CFG.team_radius of a squadmate's      -> drives team_detected, status only
--   loose enemy near nobody                                   -> ignored, logged for tuning
-- When you cannot be identified, every anchor counts as you and basis= says so, so the eye keeps working
-- exactly as it did before rather than going dark.
--
-- Targets plain Lua 5.1.4 (current builds have no LuaJIT): no 5.2+ syntax or library calls, and the main
-- chunk must stay under 200 locals, which is why the constants and state below live in grouped tables.
-- tools/analysis/check_lua51.py enforces both, plus that this file leaks no globals into the environment
-- it shares with every other Bingus mod.
--
-- Diagnostics: DetectionAlert.log (in %LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs) records the startup
-- checks, a capability probe, every state change, errors, one line per sampler pass, and a heartbeat.

local DetectionAlert = {
	is_detected = false,
	eye_intensity = 0, -- 0 = idle ember glow, 1 = full alert red
	eye_color = nil, -- set below from CFG.eye.idle
	enemies_searching = false, -- status-only: alert-tier audio/activity, short of full detection
	-- search_count/detect_count are REAL enemy counts, which the hash whitelist makes possible: how many
	-- enemies the last completed pass found alive in the sampled world, and how many of those were within
	-- CFG.me_radius of you. Both read -1 until a pass completes, so an overlay can tell "none nearby"
	-- from "nothing measured yet". Neither says whether those enemies have noticed you -- that is what
	-- the activity counts below (active_units, alerted_units, team_alerted) are for.
	search_count = -1,
	detect_count = -1,
	active_units = 0,
	count_source = "none", -- "hashes" once a pass has completed, otherwise "none"
	alerted_units = 0,
	team_alerted = 0,
	team_detected = false,
	team_mode = "off", -- see resolve_me: "me", "assumed", "squad", "unknown" or "off"
}

-- Everything tunable lives here. One local instead of sixty, which is what keeps the chunk under the
-- Lua 5.1 limit; the thresholds are the part worth touching.
local CFG = {
	-- "alert"/"aggro"/"detect" read as the AI noticing, short of confirmed combat; "combat"/"engage"/
	-- "hostile"/"battle" read as full engagement and drive is_detected.
	search_keywords = { "alert", "aggro", "detect" },
	combat_keywords = { "combat", "engage", "hostile", "battle" },
	alert_off_keywords = { "calm", "stealth", "idle", "explore", "ambient", "patrol", "hidden", "quiet" },

	-- Cannon-turret-style eye glow: dim ember red when idle, bright red when detected.
	eye = {
		idle = { r = 0.35, g = 0.02, b = 0.02 },
		alert = { r = 1.0, g = 0.05, b = 0.05 },
		ramp_up = 3.0, -- snaps to alert quickly
		ramp_down = 1.0, -- fades out slower
	},

	log_dir_suffix = "\\CowboyBingus\\Helldivers2\\Logs\\",
	log_file = "DetectionAlert.log",
	status_file = "DetectionAlertStatus.log",
	status_max_bytes = 64 * 1024, -- the overlay re-reads this file every tick, so keep it small
	status_interval = 0.5,
	heartbeat_interval = 5,
	wwise_detail_limit = 40, -- full argument dumps per Wwise callback
	wwise_sync_interval = 5,
	probe_times = { 60 }, -- re-probe here, because mods that load after this one only appear later

	-- Sampler walk. A full pass covers every unit in the main world, spread over frames.
	pass_seconds = 5,
	max_units_per_frame = 4000,
	detail_interval = 30,
	top_count = 8,
	min_animated = 20, -- fewer animated units than this is a loading screen, not a mission
	stale_seconds = 15, -- no pass finished for this long: stop trusting the last one

	-- Detection tiers, with hysteresis so the eye does not flicker. Two independent inputs per scope:
	-- "changed" (animation-state transitions this pass) and "alerted" (units outside their calm states).
	-- Values come from tools/analysis/analyze_log.py over a 1290-pass session: on mission passes, quiet
	-- passes sit at changed p90=1 / alerted p90=4, fights at changed p25=6 / alerted p25=11.
	-- That session predates the ENEMY whitelist, and was measured with every animated unit feeding the
	-- counts. The whitelist can only remove contributions, never add any, so these thresholds now read
	-- slightly conservative; retune them against a fresh capture rather than by eye.
	detect = { enter = 6, pair = 3, exit_at = 1, exit_passes = 2 },
	alert_detect = { enter = 8, exit_at = 3 },
	search = { enter = 3, exit_at = 1, exit_passes = 2 },

	-- Alerted-enemy count. Per enemy resource the sampler learns which animation states its units sit in
	-- during quiet passes; a unit outside that set is "alerted" (noticing, chasing, fighting, hit, dying).
	alert_count = true,
	calm_min_samples = 40, -- quiet-pass observations a hash needs before its units are counted at all
	calm_min_share = 0.02, -- a state seen in at least this share of a hash's quiet observations is calm
	calm_quiet_max = 2, -- a pass is quiet at or below this activity while nothing is searching
	calm_max_total = 6000, -- a hash's counts are halved above this, so old missions fade out

	-- Attribution.
	team_split = true,
	me_radius = 35, -- enemies this close to you are yours, even if a squadmate is nearer
	team_radius = 60, -- enemies this close to a squadmate are theirs; further than this is "loose"
	max_anchors = 8, -- player units tracked at once (a squad is 4; the spare room absorbs respawn copies)
	anchor_grace = 3, -- passes an anchor may go unseen before it is dropped, so one thin pass is survivable

	-- Unit resources. Every Helldiver uses the same one, so these identify "a player", not "you". It is
	-- the "Player Clone (Avatar)" entry of the same EnemyData table the ENEMY whitelist comes from.
	me_hashes = { ["4d1c334d294dfa97"] = true },
	player_hashes = {}, -- extra player-character resources, if a build ever uses more than one
	-- Escape hatch for a WHITELISTED enemy resource that changes animation state every pass whether or
	-- not anything is happening: its changes are counted as ambient and drive nothing. Take hashes from
	-- the "changes" lines -- one that shows up as =1 in almost every pass, calm or busy, belongs here.
	-- Empty since the whitelist landed: the ship/lobby resource that used to need this (685337c9ccf0e45c)
	-- is not an enemy, so it no longer reaches the counts at all.
	ambient_hashes = {},

	-- Finding you. There is no local-player API on this build: the F7 probe's dump of build 26088801
	-- (loader v21) shows no Player table and no Managers table at all, so the only route is a camera —
	-- on a client, only your own unit carries the viewport camera.
	--
	-- A native call that asserts kills the process outright; pcall cannot catch it. So an untried getter
	-- is NEVER called on its own: only pressing F7 tries one, one candidate per press. The outcome is
	-- appended to probe_state_file BEFORE the call and completed after it, so a getter that never
	-- returns is recorded as fatal and is never tried again on any later run. A getter recorded "ok"
	-- is then used automatically from the next run onward.
	--
	-- Set probe_local_player = true to let the mod try untried getters by itself. That is how the crash
	-- below happened; leave it false unless you are deliberately probing.
	probe_local_player = false,
	probe_state_file = "DetectionAlertProbe.txt",
	me_getters = {
		-- Unit.num_cameras(unit) -> how many cameras are attached. One argument, so it cannot hit the
		-- missing-argument assert that killed Unit.has_camera.
		{ name = "unit_num_cameras", space = "Unit", member = "num_cameras", kind = "unit_count" },
		-- World.debug_camera_pose(world) -> the active camera's pose; you are the anchor nearest it.
		{ name = "world_debug_camera_pose", space = "World", member = "debug_camera_pose", kind = "camera_pose" },
	},
	-- KNOWN FATAL, do not re-add: Unit.has_camera(unit) hard-crashed Helldivers 2 build 26088801 on
	-- 2026-10-29. Stingray's has_camera takes a camera name or index as a second argument, and the
	-- one-argument form asserts inside the engine. Unit.num_cameras above is the safe equivalent.
	-- Tables the probe lists members of, so the log says what this build actually exposes. Names and
	-- types only, never a call.
	probe_tables = { "Player", "Camera", "Viewport", "Window", "World", "Unit", "Network", "Application", "Managers" },

	keys = { marker_start = "f9", marker_end = "f10", probe = "f7", hud_toggle = "f11" },
	probe_max_units = 4000,

	-- On-screen panel. Everything it draws is plain ASCII in fixed-width columns: the draw path is
	-- Gui.text with the engine's monospace debug font, which is the only font this build is known to
	-- survive, so box-drawing glyphs are not safe to assume and are not used.
	hud = {
		enabled = true,
		x_fraction = 0.0375, -- from the left edge, same column as P2P-Ping's list
		y_fraction = 0.60, -- from the bottom, above P2P-Ping's list
		font = "core/performance_hud/debug",
		-- Three sizes, so the verdict carries from across the room while the detail stays out of the way.
		font_size = 26, -- the state line
		title_size = 15,
		meter_size = 18,
		rule_size = 14,
		count_size = 21,
		line_gap = 6,
		show_title = true,
		show_meter = true, -- "[####......]", the eye's own glow ramp made visible
		show_alerted = true,
		show_team = true,
		show_active = true,
		show_near = true, -- "NEAR n": known enemies within me_radius of you, whether or not they are active
		meter_cells = 10,
		rule_width = 13, -- the width of a count row: 8-wide label + 3-wide value + a 2-wide flag
		-- When each row turns amber, then red. The activity rows are wired to the detection tiers just
		-- below the table, so ON YOU and ACTIVE change colour exactly when the tiers they mirror would
		-- fire, and retuning the tiers retunes them. NEAR has no tier behind it -- a crowd of unaware
		-- enemies is not a fight -- so its thresholds are a display choice and nothing else depends on
		-- them. Red on NEAR beside a green HIDDEN is meant to read as "that is a lot of them", not as
		-- an alarm.
		counts = {
			near = { warn = 8, hot = 20 },
			alerted = nil, -- set from CFG.alert_detect below
			team = nil,
			active = nil, -- set from CFG.search / CFG.detect below
		},
		max_faults = 5,
		retry_seconds = 2,
		look = {
			detected = { text = "(O) DETECTED", r = 255, g = 112, b = 105 },
			searching = { text = "(o) SEARCHING", r = 250, g = 207, b = 96 },
			hidden = { text = "( ) HIDDEN", r = 112, g = 226, b = 145 },
			title = { r = 118, g = 132, b = 148 },
			rule = { r = 68, g = 80, b = 94 },
			-- A row's resting colour, used while its count is below counts.warn.
			alerted = { r = 255, g = 170, b = 80 },
			team = { r = 140, g = 190, b = 255 },
			near = { r = 200, g = 200, b = 210 },
			info = { r = 238, g = 243, b = 235 },
			-- The two escalation colours, matching the searching/detected state colours above.
			warn = { r = 250, g = 207, b = 96 },
			hot = { r = 255, g = 112, b = 105 },
			shadow = { r = 12, g = 15, b = 18 },
		},
	},
}

-- Enemy resource hashes: the mod's whole definition of "enemy". A world unit is counted only when its
-- resource hash is a key here; everything else is ignored, which is why the counts below are real enemy
-- counts and not an activity proxy over all 17000 units in the world. The names are for the log only.
--
-- Generated from the EnemyData project -- its data/game_names.lua (which unit names are enemies) crossed
-- with its hash -> name table. Regenerate after a patch adds units:
--   python tools/gen_enemy_hashes.py --enemy-data <path to EnemyData>
-- Do not hand-edit between the BEGIN/END markers; that tool rewrites the whole block.
local ENEMY = {
	-- BEGIN generated enemy hashes
	-- 114 enemy resources: automatons 59, illuminate 14, terminids 41
	["53d8919d7b8abd67"] = "Annihilator Tank", -- automatons
	["31bae74d2f064d8d"] = "Annihilator Tank MK2", -- automatons
	["63df3d07b7424588"] = "Barrager Tank", -- automatons
	["a6a68d8af177f3a1"] = "Berserker", -- automatons
	["54e107dacf6929cb"] = "Berserker MK2", -- automatons
	["b056f8fc74aba02d"] = "Cannon Trooper", -- automatons
	["a71aafd82c6ebc92"] = "Commissar", -- automatons
	["e0353177f1329573"] = "Conflagration Devastator", -- automatons
	["c626d2bb495a202d"] = "Devastator", -- automatons
	["fc8dec78be8ab47d"] = "Devastator MK2 Spawn", -- automatons
	["ae63e525853d7044"] = "Devastator MK3", -- automatons
	["98152772a72f7838"] = "Dropship", -- automatons
	["d37e8d120d2836e3"] = "Factory Strider", -- automatons
	["282eb766c1ffa6a1"] = "Gunship", -- automatons
	["f8b5a81a86d5d4eb"] = "Heavy Devastator", -- automatons
	["b92435fbf60f0748"] = "Heavy Devastator MK2", -- automatons
	["91ebd77931110afc"] = "Heavy Devastator MK3", -- automatons
	["96ba14c9ebb49ce1"] = "Hulk", -- automatons
	["137988cea16458f7"] = "Hulk Bruiser", -- automatons
	["6dab2eadf5d8b692"] = "Hulk Firebomber", -- automatons
	["1e66ee1f6f7fd00e"] = "Hulk Obliterator", -- automatons
	["3e0537d606438fea"] = "Hulk Scorcher", -- automatons
	["1897bdd32105d2dc"] = "Hulk Scorcher MK2", -- automatons
	["b5dbc0c240c921ad"] = "Incendiary Berserker", -- automatons
	["1b5b9ac4f96b36e5"] = "Incendiary Commissar", -- automatons
	["57eed0eac346cd9d"] = "Incendiary Devastator", -- automatons
	["58b2b86c11369241"] = "Incendiary MG Devastator", -- automatons
	["089833d2880d9e06"] = "Incendiary MG Raider", -- automatons
	["e683d2ca5618d74a"] = "Incendiary Raider", -- automatons
	["c9bcccb0a54a82a4"] = "Incendiary Rocket Devastator", -- automatons
	["09dfb04b2e578bc3"] = "Incendiary Rocket Trooper", -- automatons
	["30f2dee2333f227a"] = "Jammer Factory Strider", -- automatons
	["d5792f6856b06ba4"] = "Jet Brigade Berserker", -- automatons
	["215ce160a17be4cd"] = "Jet Brigade Commissar", -- automatons
	["be743b2faa3a6e26"] = "Jet Brigade Devastator", -- automatons
	["32cdeada234fb8df"] = "Jet Brigade Hulk Bruiser", -- automatons
	["e44ec9f9b3fe1d2a"] = "Jet Brigade Hulk Scorcher", -- automatons
	["a4552f97033392f4"] = "Jet Brigade MG Raider", -- automatons
	["856e9710e45e760f"] = "Jet Brigade Raider", -- automatons
	["af0f9b3a163787a5"] = "Jet Brigade Trooper", -- automatons
	["b4ed319b39f5457b"] = "MG Raider", -- automatons
	["0002ba767df856f3"] = "Marauder", -- automatons
	["82a87ad8d595b2ba"] = "Pyro Trooper", -- automatons
	["64ba5f030b114ec1"] = "Raider", -- automatons
	["9076eeed17fcee35"] = "Reinforced Scout Strider", -- automatons
	["9647b00cc3a9d36f"] = "Rocket Devastator", -- automatons
	["f66d0bad8693779a"] = "Rocket Devastator MK2", -- automatons
	["2a12104f2853ae16"] = "Rocket Raider", -- automatons
	["30cf04b2ec8c9bd4"] = "Scout Raider", -- automatons
	["f8131632aa867107"] = "Scout Strider", -- automatons
	["257d805caa7e10c0"] = "Shotgun Trooper", -- automatons
	["c6449ffd9ea3779c"] = "Shredder Tank", -- automatons
	["9f57782f00e6ed20"] = "Trooper", -- automatons
	["fb9937035d652c43"] = "Trooper", -- automatons
	["7ece5304f868f6b3"] = "Trooper (No Package)", -- automatons
	["7b48cacdbacb3881"] = "Trooper MK2", -- automatons
	["ae57fcdb49f74e98"] = "Trooper MK2 MG", -- automatons
	["4019623142351cb6"] = "Trooper MK3", -- automatons
	["ef570293245a17c2"] = "War Strider", -- automatons
	["e8f19a0aa958e46d"] = "Crescent Overseer", -- illuminate
	["604a794ec45bb820"] = "Elevated Overseer", -- illuminate
	["67dc32dca4f02d33"] = "Fleshmob", -- illuminate
	["965eae5a51acdd4a"] = "Harvester", -- illuminate
	["d63fcbff0851b7af"] = "Harvester MK2", -- illuminate
	["f22d027b37bef107"] = "Leviathan", -- illuminate
	["da40bb347c7447f2"] = "Overseer", -- illuminate
	["f1610ac48cdc5240"] = "Overseer (No Package)", -- illuminate
	["08e6ffc2474287bd"] = "Overseer MK2", -- illuminate
	["19e18b46ec55d94a"] = "Stingray", -- illuminate
	["44458a2c52b002fb"] = "Voteless Heavy", -- illuminate
	["78e1497571012c47"] = "Voteless Light", -- illuminate
	["0adc9f9173ad8e1d"] = "Voteless Medium", -- illuminate
	["ac60e78435098c9d"] = "Watcher", -- illuminate
	["f79cd8bb654397df"] = "Alpha Commander", -- terminids
	["36aa99cce5e60146"] = "Bile Spewer", -- terminids
	["ccae5264acd591b7"] = "Bile Spewer MK2", -- terminids
	["72a83e49ced6db3d"] = "Bile Spitter", -- terminids
	["9e2e17f2ccccafdd"] = "Bile Titan", -- terminids
	["10081acef6163ef6"] = "Bile Warrior", -- terminids
	["d522fd4748d443a5"] = "Brood Commander", -- terminids
	["1a7fcdff98c664b0"] = "Charger", -- terminids
	["3aff5fd7d5450b99"] = "Charger Behemoth", -- terminids
	["a05bd1ec67b3ac4c"] = "Charger Behemoth MK2", -- terminids
	["960b48a421a3faaa"] = "Dragonroach", -- terminids
	["a1f37bf2a40fbde4"] = "Hive Guard", -- terminids
	["d465d9c7f77a07cb"] = "Hivelord", -- terminids
	["d9511e9f6bd62e3f"] = "Hunter", -- terminids
	["3d0e03e2d574e1ca"] = "Hunter MK2", -- terminids
	["5ca832447445c0ba"] = "Hunter MK3", -- terminids
	["dcf8e74212fbee3b"] = "Impaler", -- terminids
	["6021e22338333d88"] = "Nursing Spewer", -- terminids
	["cc7022fdd172089b"] = "Nursing Spewer MK2", -- terminids
	["aab438596f5e8fd9"] = "Pouncer", -- terminids
	["883401af2a98a5f6"] = "Predator Hunter", -- terminids
	["d1e990baf22d5a52"] = "Predator Stalker", -- terminids
	["0ab7b92b131c228c"] = "Rupture Charger", -- terminids
	["a381a11c07d3eb94"] = "Rupture Spewer", -- terminids
	["a35207c6f2150806"] = "Rupture Warrior", -- terminids
	["8ff0a839830a7692"] = "Scavenger", -- terminids
	["51eea86bf6997e4e"] = "Scavenger MK2", -- terminids
	["9a8a3aae287b230c"] = "Scavenger MK3", -- terminids
	["64090088502435dd"] = "Shrieker", -- terminids
	["ef04cb84d097a497"] = "Spore Burst Bile Titan", -- terminids
	["1f0a91729c0004e0"] = "Spore Burst Hunter", -- terminids
	["db964631be1cf501"] = "Spore Burst Scavenger", -- terminids
	["728421351d440ebc"] = "Spore Burst Warrior", -- terminids
	["6b202392f4ab605e"] = "Spore Charger", -- terminids
	["aa28caf964d05500"] = "Spore Spewer", -- terminids
	["e02e6bd34b606a85"] = "Spore Spewer MK2", -- terminids
	["f540ca9d9d4a422e"] = "Stalker", -- terminids
	["eacee39fa017b495"] = "Warrior", -- terminids
	["be39e313a1e46bb9"] = "Warrior MK2", -- terminids
	["32541fc4ec7c9cdc"] = "Warrior MK3", -- terminids
	["b2a6fa1e4284c7e6"] = "Warrior(Spawned)", -- terminids
	-- END generated enemy hashes
}

-- How many resources the whitelist holds, reported at startup so a build running a stale or truncated
-- table is obvious from the first line of the log.
local ENEMY_COUNT = 0
for _ in pairs(ENEMY) do
	ENEMY_COUNT = ENEMY_COUNT + 1
end

DetectionAlert.eye_color = { r = CFG.eye.idle.r, g = CFG.eye.idle.g, b = CFG.eye.idle.b }

-- The HUD's escalation points for the rows that mirror a detection tier, filled in here because a Lua
-- table literal cannot refer to itself. ON YOU and ON TEAM follow the alerted tier, ACTIVE follows the
-- changed tiers, so each row turns amber as its tier approaches and red as the tier fires.
CFG.hud.counts.alerted = { warn = CFG.alert_detect.exit_at, hot = CFG.alert_detect.enter }
CFG.hud.counts.team = CFG.hud.counts.alerted
CFG.hud.counts.active = { warn = CFG.search.enter, hot = CFG.detect.enter }

local elapsed_time = 0

-- Logging: both files are opened through the loader's open_log when it offers one, otherwise directly in
-- the loader's log folder. A line that cannot reach a file goes to the console.
local LOG = { file = nil, target = "not opened yet", errors = 0 } -- file: nil = not tried, false = unavailable

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
			local path = base .. CFG.log_dir_suffix .. file_name
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

local function log(text)
	if LOG.file == nil then
		local handle, target = open_log_file(CFG.log_file)
		LOG.file = handle or false
		LOG.target = handle and target or ("unavailable: " .. target)
	end
	if LOG.file then
		if pcall(write_line, LOG.file, text) then
			return
		end
		LOG.file = false
		LOG.target = "unavailable: write failed"
	end
	if type(print) == "function" then
		print(text)
	end
end

local function log_error(where, err)
	LOG.errors = LOG.errors + 1
	if LOG.errors <= 20 or LOG.errors % 100 == 0 then
		log(string.format("[DetectionAlert] ERROR #%d in %s: %s", LOG.errors, where, tostring(err)))
	end
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

-- Engine access. Every call to the game goes through here: the function is resolved once, called under
-- pcall, and the first failure of each API is logged with its message. A missing API is logged once and
-- then returns nil forever, so a build without it degrades instead of spamming.
local E = { fns = {}, failed = {} }

local function engine_table(name)
	local engine = rawget(_G, "stingray")
	return type(engine) == "table" and rawget(engine, name) or nil
end

local function engine_fn(space_name, member)
	local key = space_name .. "." .. member
	local fn = E.fns[key]
	if fn == nil then
		local space = engine_table(space_name)
		fn = type(space) == "table" and rawget(space, member) or nil
		if type(fn) ~= "function" then
			fn = false
		end
		E.fns[key] = fn
	end
	return fn or nil
end

local function engine_call(space_name, member, ...)
	local key = space_name .. "." .. member
	local fn = engine_fn(space_name, member)
	if fn == nil then
		if not E.failed[key] then
			E.failed[key] = true
			log("[DetectionAlert] sampler " .. key .. " unavailable")
		end
		return nil
	end
	local ok, result = pcall(fn, ...)
	if ok then
		return result
	end
	if not E.failed[key] then
		E.failed[key] = true
		log("[DetectionAlert] sampler " .. key .. " failed: " .. tostring(result))
	end
	return nil
end

-- Detection scopes. Each is one hysteretic state machine over a pass's two scores, so "on me", "on my
-- squad" and "anywhere" all share the same tier logic instead of three near-copies of it.
--   DETECTED  changed >= detect.enter in one pass, or >= detect.pair in two in a row, or alerted >=
--             alert_detect.enter. Ends after detect.exit_passes passes at or below both exit values.
--   SEARCHING changed >= search.enter. Ends after search.exit_passes passes at or below search.exit_at.
--             Always on while DETECTED.
local function new_scope(name)
	return { name = name, detected = false, searching = false,
		low_detect = 0, low_search = 0, changed = 0, alerted = 0, last_changed = 0 }
end

local SC = { me = new_scope("me"), mate = new_scope("mate") }

local function score_scope(scope, changed, alerted)
	local d, a, s = CFG.detect, CFG.alert_detect, CFG.search
	if not scope.detected then
		if changed >= d.enter or alerted >= a.enter
			or (changed >= d.pair and scope.last_changed >= d.pair) then
			scope.detected = true
			scope.low_detect = 0
		end
	elseif changed <= d.exit_at and alerted <= a.exit_at then
		scope.low_detect = scope.low_detect + 1
		if scope.low_detect >= d.exit_passes then
			scope.detected = false
		end
	else
		scope.low_detect = 0
	end

	if scope.detected then
		scope.searching = true
		scope.low_search = 0
	elseif not scope.searching then
		if changed >= s.enter then
			scope.searching = true
			scope.low_search = 0
		end
	elseif changed <= s.exit_at then
		scope.low_search = scope.low_search + 1
		if scope.low_search >= s.exit_passes then
			scope.searching = false
		end
	else
		scope.low_search = 0
	end

	scope.last_changed = changed
	scope.changed = changed
	scope.alerted = alerted
end

local function clear_scope(scope)
	scope.detected, scope.searching = false, false
	scope.low_detect, scope.low_search = 0, 0
	scope.changed, scope.alerted, scope.last_changed = 0, 0, 0
end

-- Wwise's own verdict, kept separate because it cannot be attributed to a player at all.
local WW = { detected = false, searching = false, calls = 0, signal_calls = 0, matches = 0,
	wrappers = setmetatable({}, { __mode = "k" }), counts = {}, missing = {} }

-- Compare before writing, so both directions are applied and logged once.
local function set_flag(key, value, label, source)
	if DetectionAlert[key] == value then
		return
	end
	DetectionAlert[key] = value
	log(string.format("[DetectionAlert] t=%.2f %s via %s", elapsed_time, string.format(label, tostring(value)), source))
end

-- is_detected is "enemies are on ME": the me scope, or Wwise. When you cannot be told
-- apart from your squad the me scope already holds every anchor's activity, so this never goes quiet
-- just because the identification failed. is_detected reads better as DETECTED/HIDDEN than true/false,
-- so it is logged by hand rather than through set_flag.
local function recompute_detection(source)
	local want = WW.detected or SC.me.detected
	if DetectionAlert.is_detected ~= want then
		DetectionAlert.is_detected = want
		log(string.format("[DetectionAlert] t=%.2f %s via %s", elapsed_time, want and "DETECTED" or "HIDDEN", source))
	end
	set_flag("enemies_searching", WW.searching or SC.me.searching, "enemies_searching=%s", source)
	set_flag("team_detected", SC.mate.detected, "team_detected=%s", source)
end

-- Advances eye_intensity/eye_color toward the current detection state.
-- NOTE: there is no confirmed in-world draw/material/light API reachable from this sandboxed entry point.
-- This keeps eye_intensity/eye_color ready to feed a real light-set or material call the moment one is
-- confirmed; wire that call in where noted in tick().
local function update_eye_glow(dt)
	local target = DetectionAlert.is_detected and 1 or 0
	local rate = target > DetectionAlert.eye_intensity and CFG.eye.ramp_up or CFG.eye.ramp_down
	if DetectionAlert.eye_intensity < target then
		DetectionAlert.eye_intensity = math.min(target, DetectionAlert.eye_intensity + rate * dt)
	else
		DetectionAlert.eye_intensity = math.max(target, DetectionAlert.eye_intensity - rate * dt)
	end
	local t = DetectionAlert.eye_intensity
	local idle, alert = CFG.eye.idle, CFG.eye.alert
	DetectionAlert.eye_color.r = idle.r + (alert.r - idle.r) * t
	DetectionAlert.eye_color.g = idle.g + (alert.g - idle.g) * t
	DetectionAlert.eye_color.b = idle.b + (alert.b - idle.b) * t
end

-- Sampler state. One table, because the chunk cannot afford thirty more locals.
local S = {
	session_active = false,
	next_session_check = 1,
	session_probe_done = false,
	probe_index = 1,
	next_detail = nil,
	last_pass = nil,
	last_pass_at = 0,
	stale_logged = false,
	-- Animation states are integers on this build, so each unit's last state is kept (weakly) to count
	-- transitions between samples. Resource ids come back as 64-bit hashes, so how to turn one into text
	-- is picked from the first sample: "string", "idstring64", "hex" or "type".
	last_state = setmetatable({}, { __mode = "k" }),
	resource_mode = nil,
	diagnostics_logged = false,
	changes_total = 0,
	-- A pass walks a snapshot of World.units taken when the pass starts; the cursor and the fractional
	-- unit budget carry over between frames, and counts are logged when the walk wraps.
	units = nil,
	cursor = 1,
	credit = 0,
	cost = 0,
	calm = {}, -- hash -> { total = observations, states = { [state] = observations } }; kept across missions
	-- Anchors: player-character units currently known, one of which is you.
	anchors = {},
	me = nil, -- the anchor table that is you, or nil
	me_basis = "none", -- how resolve_me chose it: "api", "continuity", "assumed" or "none"
	me_confirmed = false, -- true only once a getter named your unit; continuity never upgrades this
	mode = "off",
	pass = nil, -- per-pass tallies, built by reset_pass
}

local function reset_pass()
	S.pass = {
		units = 0, animated = 0, enemies = 0, changed = 0, ambient = 0,
		near_me = 0, near_mate = 0,
		me_changed = 0, me_alerted = 0, mate_changed = 0, mate_alerted = 0,
		loose = 0, unplaced = 0, unanchored = 0,
		change_keys = {}, -- changed enemies by name, for the changes line
		transitions = {}, -- the same as "name:from>to", to work out what the state numbers mean
		hash_states = {}, -- hash -> { [state] = units }, the calm model's input
	}
end
reset_pass()

-- Counts since the last detail line. `unknown` holds animated resources that are in neither ENEMY nor
-- CFG.me_hashes: after a patch adds a unit type, its hash shows up there and belongs in ENEMY.
local DT = { units = 0, animated = 0, changed = 0, states = {}, resources = {}, unknown = {} }

local function is_player_hash(hash)
	return CFG.me_hashes[hash] == true or CFG.player_hashes[hash] == true
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
	for index = 1, math.min(#list, limit or CFG.top_count) do
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

local function cpu_time()
	if type(os) == "table" and type(os.clock) == "function" then
		return os.clock()
	end
	return 0
end

-- Picks how resource ids are turned into text, from the first non-string value the engine returns.
local function choose_resource_mode(value)
	if type(value) == "string" then
		return "string"
	end
	if type(engine_call("IdString64", "to_string", value)) == "string" then
		return "idstring64"
	end
	if type(engine_call("IdString64", "to_hex", value)) == "string" then
		return "hex"
	end
	return "type"
end

local function resource_key(value, mode)
	if mode == "string" and type(value) == "string" then
		return value:sub(1, 80)
	end
	if mode == "idstring64" then
		local text = engine_call("IdString64", "to_string", value)
		if type(text) == "string" then
			return text:sub(1, 80)
		end
	elseif mode == "hex" then
		local hex = engine_call("IdString64", "to_hex", value)
		if type(hex) == "string" then
			return "hex:" .. hex
		end
	end
	return type(value)
end

-- Resource ids are shortened to their 16-digit hash, so units can be matched against ENEMY. The hash is
-- lower-cased because ENEMY's keys are, and the engine's text form has been seen either way.
local function short_resource_key(key)
	local hash = key:match("%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x")
	if hash ~= nil then
		return hash:lower()
	end
	return (key:gsub("%s", "_"))
end

local function unit_hash(resource)
	if resource == nil or S.resource_mode == nil then
		return "unkeyed"
	end
	return short_resource_key(resource_key(resource, S.resource_mode))
end

-- A changed enemy's log key: its name with spaces squeezed out, so the space-separated "changes" and
-- "transitions" lines stay parseable while being readable (Heavy_Devastator=4, not a bare hash).
local function enemy_label(hash)
	local name = ENEMY[hash]
	if name == nil then
		return hash
	end
	return (name:gsub("%s", "_"))
end

-- Distance between two positions, or nil when either is missing or the engine returns nonsense.
-- NaN and infinity are rejected rather than compared, so bad data never reads as "far away".
local function distance_squared(a, b)
	if a == nil or b == nil then
		return nil
	end
	local d2 = engine_call("Vector3", "distance_squared", a, b)
	if type(d2) ~= "number" or d2 ~= d2 or d2 < 0 or d2 == math.huge then
		return nil
	end
	return d2
end

-- Finding you among the anchors.
--
-- Stage 1 (api): a getter that names the local player's unit outright. CFG.me_getters lists the candidates;
-- each is checked for existence, then called once behind a flushed log line, so if a build makes one of them
-- fatal the last line in the log names it. The first that works is remembered for the session.
-- Stage 2 (continuity): the anchor you were last pass, while its unit is still alive. This is what stops the
-- choice jumping between squadmates whenever a pass happens not to re-sight your unit.
-- Stage 3 (assumed): the first anchor. Reported as basis=assumed, and every anchor is then treated as you,
-- so the eye behaves as it did before rather than reporting a squadmate's fight as yours.
--
-- Probe bookkeeping lives in a tiny side file (CFG.probe_state_file) rather than the log, because the log
-- is truncated at every game start and this knowledge has to outlive a crash. Each trial appends "try
-- <name>", closes the file, makes the call, then appends the result. A "try" with no result after it means
-- the call never returned: the getter is fatal on this build and is never attempted again.
local PROBE = { status = {}, loaded = false, path = nil }

local function probe_state_path()
	if type(os) ~= "table" or type(os.getenv) ~= "function" then
		return nil
	end
	local base = os.getenv("LOCALAPPDATA")
	return base and (base .. CFG.log_dir_suffix .. CFG.probe_state_file) or nil
end

local function load_probe_state()
	if PROBE.loaded then
		return
	end
	PROBE.loaded = true
	PROBE.path = probe_state_path()
	local handle = nil
	if PROBE.path ~= nil and type(io) == "table" and type(io.open) == "function" then
		local ok, opened = pcall(io.open, PROBE.path, "r")
		handle = ok and opened or nil
	end
	if handle ~= nil then
		pcall(function()
			for line in handle:lines() do
				local verb, name = line:match("^(%a+)%s+(%S+)")
				if verb == "try" then
					PROBE.status[name] = "fatal" -- overwritten by the result line, if there is one
				elseif verb == "ok" or verb == "no" then
					PROBE.status[name] = verb
				end
			end
		end)
		pcall(handle.close, handle)
	end

	local parts = {}
	for _, getter in ipairs(CFG.me_getters) do
		parts[#parts + 1] = getter.name .. "=" .. (PROBE.status[getter.name] or "untried")
	end
	log("[DetectionAlert] me: probe state " .. table.concat(parts, " "))
end

-- Written with open/write/close rather than a kept handle, so the line is on disk before the call that
-- may not return.
local function record_probe(verb, name)
	PROBE.status[name] = (verb == "try") and "fatal" or verb
	if PROBE.path == nil or type(io) ~= "table" or type(io.open) ~= "function" then
		return
	end
	local ok, handle = pcall(io.open, PROBE.path, "a")
	if not ok or handle == nil then
		return
	end
	pcall(function()
		handle:write(verb, " ", name, "\n")
	end)
	pcall(handle.close, handle)
end

local function camera_position()
	local world = engine_call("Application", "main_world")
	if world == nil then
		return nil
	end
	local pose = engine_call("World", "debug_camera_pose", world)
	if pose == nil then
		return nil
	end
	return engine_call("Matrix4x4", "translation", pose)
end

-- Calls one untried getter, bracketed by the probe file. Returns true if it survived and is usable.
local function try_getter(getter, anchors)
	if engine_fn(getter.space, getter.member) == nil then
		record_probe("no", getter.name)
		log(string.format("[DetectionAlert] me: %s.%s is missing on this build", getter.space, getter.member))
		return false
	end
	record_probe("try", getter.name)
	log(string.format("[DetectionAlert] me: about to call %s.%s -- if this is the last line in the log, that call killed the game and it will never be tried again",
		getter.space, getter.member))

	local worked = false
	if getter.kind == "unit_count" then
		worked = anchors[1] ~= nil
			and type(engine_call(getter.space, getter.member, anchors[1].unit)) == "number"
	elseif getter.kind == "camera_pose" then
		worked = camera_position() ~= nil
	end

	record_probe(worked and "ok" or "no", getter.name)
	log(string.format("[DetectionAlert] me: %s.%s survived, usable=%s", getter.space, getter.member, tostring(worked)))
	return worked
end

local function confirmed_getter()
	for _, getter in ipairs(CFG.me_getters) do
		if PROBE.status[getter.name] == "ok" then
			return getter
		end
	end
	return nil
end

local function next_untried_getter()
	for _, getter in ipairs(CFG.me_getters) do
		if PROBE.status[getter.name] == nil then
			return getter
		end
	end
	return nil
end

local function me_api_unit(anchors)
	load_probe_state()
	local getter = confirmed_getter()
	if getter == nil then
		-- Only opt-in auto-probing reaches a getter that has never been called on this machine.
		if CFG.probe_local_player then
			local candidate = next_untried_getter()
			if candidate ~= nil then
				try_getter(candidate, anchors)
				getter = confirmed_getter()
			end
		end
		if getter == nil then
			return nil
		end
	end

	if getter.kind == "unit_count" then
		for _, anchor in ipairs(anchors) do
			local cameras = engine_call(getter.space, getter.member, anchor.unit)
			if type(cameras) == "number" and cameras > 0 then
				return anchor.unit
			end
		end
		return nil
	end

	if getter.kind == "camera_pose" then
		local eye = camera_position()
		if eye == nil then
			return nil
		end
		local best_unit, best_d2 = nil, nil
		for _, anchor in ipairs(anchors) do
			local d2 = distance_squared(anchor.pos, eye)
			if d2 ~= nil and (best_d2 == nil or d2 < best_d2) then
				best_unit, best_d2 = anchor.unit, d2
			end
		end
		return best_unit
	end

	return nil
end

local function resolve_me()
	local anchors = S.anchors
	if not CFG.team_split or #anchors == 0 then
		S.me, S.me_basis, S.me_confirmed = nil, "none", false
		return
	end

	local api_unit = me_api_unit(anchors)
	if api_unit ~= nil then
		for _, anchor in ipairs(anchors) do
			if anchor.unit == api_unit then
				S.me, S.me_basis, S.me_confirmed = anchor, "api", true
				return
			end
		end
	end

	-- Continuity keeps the same unit, but it cannot upgrade the reason it was picked: carrying an
	-- arbitrary first-anchor guess forward as though it were confirmed is exactly what made the old
	-- split report a squadmate's fight as yours.
	if S.me ~= nil then
		for _, anchor in ipairs(anchors) do
			if anchor.unit == S.me.unit then
				S.me = anchor
				S.me_basis = S.me_confirmed and "continuity" or "assumed"
				return
			end
		end
	end

	S.me, S.me_basis, S.me_confirmed = anchors[1], "assumed", false
end

-- Attributes one enemy to a scope by distance. Returns "me", "mate", "loose" or "unplaced".
--
-- An enemy within me_radius of you is yours even when a squadmate is standing closer, because the
-- question the eye answers is "is anything near ME", not "whose kill is this". Everything else falls to
-- the nearest squadmate within team_radius, then to "loose" (near nobody) and "unplaced" (the unit's own
-- position could not be read, so it is left out rather than guessed at).
local function attribute(unit)
	local anchors = S.anchors
	-- No player unit found at all: nothing can be placed, so every enemy counts as yours. That is what
	-- the mod did before the split existed, and it keeps the eye working through the stretches where no
	-- anchor is in the sampled snapshot instead of going dark for them. `unanchored` counts the enemies
	-- this happened to, so the log says how much of a pass was attributed blind.
	if #anchors == 0 then
		S.pass.unanchored = S.pass.unanchored + 1
		return "me"
	end
	local pos = engine_call("Unit", "world_position", unit, 0)
	if pos == nil then
		return "unplaced"
	end

	-- Until you are positively identified, every anchor counts as you: the squad's activity and yours
	-- cannot be separated, so reporting a squadmate's fight as "not yours" would be a guess dressed up
	-- as a fact. This is the pre-split behaviour, and basis=assumed in the log says it is in force.
	local me_only = not S.me_confirmed or S.me == nil
	local me_limit = CFG.me_radius * CFG.me_radius
	local team_limit = CFG.team_radius * CFG.team_radius
	local best_mate = nil
	for index = 1, #anchors do
		local anchor = anchors[index]
		local d2 = distance_squared(anchor.pos, pos)
		if d2 ~= nil then
			local is_me = me_only or anchor == S.me
			if is_me then
				if d2 <= me_limit then
					return "me"
				end
			elseif best_mate == nil or d2 < best_mate then
				best_mate = d2
			end
		end
	end
	if best_mate ~= nil and best_mate <= team_limit then
		return "mate"
	end
	return "loose"
end

-- Anchors are refreshed every frame so attribution uses live positions, and pruned at the end of a pass.
-- An anchor survives CFG.anchor_grace unseen passes, because a pass that happens not to walk your unit
-- used to drop you entirely and force a fresh arbitrary pick on the next one.
local function refresh_anchor_positions()
	if not CFG.team_split then
		return
	end
	local anchors = S.anchors
	for index = #anchors, 1, -1 do
		local anchor = anchors[index]
		if engine_call("Unit", "alive", anchor.unit) ~= true then
			table.remove(anchors, index)
			if S.me == anchor then
				S.me, S.me_confirmed = nil, false
			end
		else
			anchor.pos = engine_call("Unit", "world_position", anchor.unit, 0)
		end
	end
end

local function note_anchor(unit, hash)
	local anchors = S.anchors
	for _, anchor in ipairs(anchors) do
		if anchor.unit == unit then
			anchor.seen = true
			return
		end
	end
	if #anchors >= CFG.max_anchors then
		return
	end
	anchors[#anchors + 1] = { unit = unit, hash = hash, pos = nil, seen = true, unseen_passes = 0 }
end

-- Largest distance between any two anchors, which says whether the squad is together. When this stays
-- small the whole squad shares one engagement and the me/mate split has little to separate.
local function anchor_spread()
	local anchors = S.anchors
	local worst = nil
	for i = 1, #anchors do
		for j = i + 1, #anchors do
			local d2 = distance_squared(anchors[i].pos, anchors[j].pos)
			if d2 ~= nil and (worst == nil or d2 > worst) then
				worst = d2
			end
		end
	end
	return worst and math.sqrt(worst) or nil
end

local function prune_anchors()
	local anchors = S.anchors
	for index = #anchors, 1, -1 do
		local anchor = anchors[index]
		if anchor.seen then
			anchor.unseen_passes = 0
		else
			anchor.unseen_passes = anchor.unseen_passes + 1
			if anchor.unseen_passes > CFG.anchor_grace then
				table.remove(anchors, index)
				if S.me == anchor then
					S.me, S.me_confirmed = nil, false
				end
			end
		end
		anchor.seen = false
	end
end

local function update_anchors()
	prune_anchors()
	local previous_mode, previous_me = S.mode, S.me
	resolve_me()
	if not CFG.team_split then
		S.mode = "off"
	elseif #S.anchors == 0 then
		S.mode = "unknown"
	elseif S.me_confirmed then
		S.mode = "me"
	else
		S.mode = "assumed"
	end
	if S.mode ~= previous_mode or S.me ~= previous_me then
		local spread = anchor_spread()
		log(string.format("[DetectionAlert] anchors t=%.1f count=%d mode=%s basis=%s spread=%s",
			elapsed_time, #S.anchors, S.mode, S.me_basis,
			spread and string.format("%.0fm", spread) or "?"))
	end
end

-- Scores a completed pass's calm model: when the pass was quiet, every enemy's state counts as normal
-- behaviour for its resource. Only whitelisted enemies ever reach hash_states, so the model is now one
-- entry per enemy type. A hash without enough quiet observations is never counted alerted.
local function learn_calm(quiet)
	if not CFG.alert_count or not quiet then
		return
	end
	for hash, states in pairs(S.pass.hash_states) do
		local model = S.calm[hash]
		if model == nil then
			model = { total = 0, states = {} }
			S.calm[hash] = model
		end
		for state, units in pairs(states) do
			model.states[state] = (model.states[state] or 0) + units
			model.total = model.total + units
		end
		if model.total > CFG.calm_max_total then
			for state, seen in pairs(model.states) do
				model.states[state] = seen / 2
			end
			model.total = model.total / 2
		end
	end
end

-- True when this enemy's animation state is one its resource is not normally seen in.
local function is_alerted(hash, state)
	if not CFG.alert_count or CFG.ambient_hashes[hash] then
		return false
	end
	local model = S.calm[hash]
	if model == nil or model.total < CFG.calm_min_samples then
		return false
	end
	local seen = model.states[state]
	return seen == nil or seen / model.total < CFG.calm_min_share
end

-- One line for the detail log: the biggest enemy types and their calm states, so the model can be
-- checked by eye.
local function calm_model_summary()
	local list = {}
	for hash, model in pairs(S.calm) do
		list[#list + 1] = { hash = hash, model = model }
	end
	table.sort(list, function(a, b)
		if a.model.total ~= b.model.total then return a.model.total > b.model.total end
		return a.hash < b.hash
	end)
	local parts = {}
	for index = 1, math.min(#list, 8) do
		local entry = list[index]
		local calm = {}
		for state, seen in pairs(entry.model.states) do
			if seen / entry.model.total >= CFG.calm_min_share then
				calm[#calm + 1] = state
			end
		end
		table.sort(calm, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
		parts[#parts + 1] = string.format("%s(n=%d):%s", enemy_label(entry.hash), math.floor(entry.model.total),
			table.concat(calm, ",", 1, math.min(#calm, 12)))
	end
	return #parts > 0 and table.concat(parts, " ") or "none"
end

-- Writes one line per completed pass and feeds the pass to the three scopes. cost is the CPU time the
-- sampler used during that pass.
local function log_pass(total)
	S.last_pass_at = elapsed_time
	S.stale_logged = false
	local p = S.pass
	local mission = p.animated >= CFG.min_animated
	local me_changed = mission and p.me_changed or 0
	local me_alerted = mission and p.me_alerted or 0
	local mate_changed = mission and p.mate_changed or 0
	local mate_alerted = mission and p.mate_alerted or 0
	local world_changed = me_changed + mate_changed + (mission and p.loose or 0)

	local ok, err = pcall(function()
		score_scope(SC.me, me_changed, me_alerted)
		score_scope(SC.mate, mate_changed, mate_alerted)
	end)
	if not ok then
		log_error("score_scope", err)
	end
	recompute_detection("sampler")

	local ok_calm, calm_err = pcall(learn_calm,
		world_changed <= CFG.calm_quiet_max and not DetectionAlert.enemies_searching)
	if not ok_calm then
		log_error("learn_calm", calm_err)
	end
	local ok_anchor, anchor_err = pcall(update_anchors)
	if not ok_anchor then
		log_error("update_anchors", anchor_err)
	end

	log(string.format("[DetectionAlert] pass t=%.1f wall=%s units=%d animated=%d enemies=%d near_me=%d near_mate=%d changed=%d ambient=%d me=%d mate=%d loose=%d unplaced=%d unanchored=%d alerted_me=%d alerted_mate=%d detected=%d searching=%d team=%d cost=%.1fms",
		elapsed_time, wall_clock(), p.units, p.animated, p.enemies, p.near_me, p.near_mate, p.changed, p.ambient,
		me_changed, mate_changed, p.loose, p.unplaced, p.unanchored, me_alerted, mate_alerted,
		DetectionAlert.is_detected and 1 or 0, DetectionAlert.enemies_searching and 1 or 0,
		DetectionAlert.team_detected and 1 or 0, S.cost * 1000))
	local spread = anchor_spread()
	log(string.format("[DetectionAlert] attribution t=%.1f overall=%s player=%s team=%s wwise=%s anchors=%d mode=%s basis=%s spread=%s me_radius=%dm team_radius=%dm",
		elapsed_time, DetectionAlert.is_detected and "DETECTED" or "hidden",
		SC.me.detected and "DETECTED" or "hidden", SC.mate.detected and "DETECTED" or "hidden",
		WW.detected and "DETECTED" or "hidden", #S.anchors, S.mode, S.me_basis,
		spread and string.format("%.0f", spread) or "?",
		CFG.me_radius, CFG.team_radius))
	if p.changed > 0 then
		log(string.format("[DetectionAlert] changes t=%.1f %s", elapsed_time, top_counts(p.change_keys, math.huge)))
		log(string.format("[DetectionAlert] transitions t=%.1f %s", elapsed_time, top_counts(p.transitions, 16)))
	end

	S.last_pass = { total = total, units = p.units, animated = p.animated, changed = p.changed,
		enemies = p.enemies, near_me = p.near_me, near_mate = p.near_mate }
	S.cost = 0
	reset_pass()
end

-- Samples one unit: counts it into the pass and detail totals, and -- for a unit whose resource is in
-- ENEMY -- records its animation-state change and attributes it to you, a squadmate or nobody. A unit
-- that is neither a player nor a known enemy is counted in the totals and then dropped: it can reach no
-- scope, no calm model and no published count.
local function sample_unit(unit)
	if engine_call("Unit", "alive", unit) ~= true then
		return
	end
	local p = S.pass
	p.units = p.units + 1
	DT.units = DT.units + 1

	local resource = engine_call("Unit", "resource_name", unit)
	if resource ~= nil and S.resource_mode == nil then
		S.resource_mode = choose_resource_mode(resource)
		log(string.format("[DetectionAlert]   resource sample: type=%s value=%s mode=%s",
			type(resource), describe_state(resource), S.resource_mode))
	end
	if resource ~= nil and S.resource_mode ~= nil then
		count_into(DT.resources, resource_key(resource, S.resource_mode))
	end
	if not S.diagnostics_logged then
		S.diagnostics_logged = true
		log("[DetectionAlert]   debug_name sample: " .. describe_state(engine_call("Unit", "debug_name", unit)))
	end

	-- animated is still every animated unit, player and prop included: it is the loading-screen gate
	-- (CFG.min_animated), not an enemy count.
	if engine_call("Unit", "has_animation_state_machine", unit) ~= true then
		return
	end
	local state = describe_state(engine_call("Unit", "animation_get_state", unit))
	count_into(DT.states, state)
	p.animated = p.animated + 1
	DT.animated = DT.animated + 1

	local hash = unit_hash(resource)
	if is_player_hash(hash) then
		-- Player units are anchors, never activity: your own running and shooting is not a detection.
		if CFG.team_split then
			note_anchor(unit, hash)
		end
		S.last_state[unit] = state
		return
	end

	-- The whitelist. Anything not named in ENEMY stops here; its hash is logged in the detail block so a
	-- unit type a patch added can be spotted and added to the table.
	if ENEMY[hash] == nil then
		count_into(DT.unknown, hash)
		return
	end
	p.enemies = p.enemies + 1

	if CFG.alert_count then
		local per_hash = p.hash_states[hash]
		if per_hash == nil then
			per_hash = {}
			p.hash_states[hash] = per_hash
		end
		per_hash[state] = (per_hash[state] or 0) + 1
	end

	local previous = S.last_state[unit]
	local changed = previous ~= nil and previous ~= state
	local alerted = is_alerted(hash, state)
	S.last_state[unit] = state

	if changed then
		p.changed = p.changed + 1
		DT.changed = DT.changed + 1
		S.changes_total = S.changes_total + 1
		local label = enemy_label(hash)
		count_into(p.change_keys, label)
		count_into(p.transitions, label .. ":" .. previous .. ">" .. state)
	end
	if CFG.ambient_hashes[hash] then
		if changed then
			p.ambient = p.ambient + 1
		end
		return
	end

	-- One position lookup per enemy. Every enemy is placed, not just the active ones, because near_me
	-- and near_mate are counts of enemies around you rather than of activity: that is what the whitelist
	-- bought, and it is cheap because the pass reaches at most a few dozen enemies among 17000 units.
	local bucket = attribute(unit)
	if bucket == "me" then
		p.near_me = p.near_me + 1
		if changed then p.me_changed = p.me_changed + 1 end
		if alerted then p.me_alerted = p.me_alerted + 1 end
	elseif bucket == "mate" then
		p.near_mate = p.near_mate + 1
		if changed then p.mate_changed = p.mate_changed + 1 end
		if alerted then p.mate_alerted = p.mate_alerted + 1 end
	elseif bucket == "loose" then
		if changed then p.loose = p.loose + 1 end
	else
		if changed then p.unplaced = p.unplaced + 1 end
	end
end

-- Runs once per frame while a session is active. A pass takes a snapshot of World.units at its start and
-- samples the share of units due this frame, so a full pass spans CFG.pass_seconds. The per-frame cap
-- keeps one frame short even when a frame is long.
local function sample_enemies(dt)
	if S.next_detail == nil then
		S.next_detail = elapsed_time + CFG.detail_interval
	end
	if S.units == nil then
		local world = engine_call("Application", "main_world")
		local units = world ~= nil and engine_call("World", "units", world) or nil
		if type(units) ~= "table" or #units == 0 then
			S.credit = 0
			return
		end
		S.units = units
		S.cursor = 1
	end

	refresh_anchor_positions()
	local total = #S.units
	S.credit = math.min(S.credit + total * dt / CFG.pass_seconds, CFG.max_units_per_frame)
	local count = math.floor(S.credit)
	S.credit = S.credit - count
	for _ = 1, count do
		sample_unit(S.units[S.cursor])
		S.cursor = S.cursor + 1
		if S.cursor > total then
			log_pass(total)
			S.units = nil
			break
		end
	end

	if elapsed_time >= S.next_detail then
		S.next_detail = elapsed_time + CFG.detail_interval
		log(string.format("[DetectionAlert] sample t=%.1f wall=%s total=%d units=%d animated=%d changed=%d changed_total=%d",
			elapsed_time, wall_clock(), total, DT.units, DT.animated, DT.changed, S.changes_total))
		log("[DetectionAlert]   states: " .. top_counts(DT.states))
		log("[DetectionAlert]   resources: " .. top_counts(DT.resources))
		-- Animated units that are neither a player nor in ENEMY. Mostly props, sentries and hellpods, but
		-- a hash climbing this list after a game patch is a new enemy type missing from the whitelist.
		log("[DetectionAlert]   unlisted animated: " .. top_counts(DT.unknown))
		log("[DetectionAlert]   calm model: " .. calm_model_summary())
		local spread = anchor_spread()
		log(string.format("[DetectionAlert]   team: mode=%s basis=%s anchors=%d spread=%s me_radius=%d team_radius=%d alerted_mate=%d",
			S.mode, S.me_basis, #S.anchors,
			spread and string.format("%.0fm", spread) or "?",
			CFG.me_radius, CFG.team_radius, SC.mate.alerted))
		DT.units, DT.animated, DT.changed = 0, 0, 0
		DT.states, DT.resources, DT.unknown = {}, {}, {}
	end
end

-- Clears every tier when no game session is active, so a finished mission cannot leave the eye lit.
local function reset_sampler()
	if S.pass.units > 0 then
		reset_pass()
	end
	clear_scope(SC.me)
	clear_scope(SC.mate)
	S.anchors, S.me, S.me_basis, S.me_confirmed, S.mode = {}, nil, "none", false, "off"
	S.last_pass_at = elapsed_time
	S.stale_logged = false
	recompute_detection("sampler (no session)")
end

-- A pass that never finishes (slow frames, a world change) must not leave the last verdict standing.
local function check_stall()
	if S.stale_logged or elapsed_time - S.last_pass_at <= CFG.stale_seconds then
		return
	end
	S.stale_logged = true
	log(string.format("[DetectionAlert] t=%.1f sampler stalled: no pass finished for %d s, detection cleared until one does",
		elapsed_time, CFG.stale_seconds))
	clear_scope(SC.me)
	clear_scope(SC.mate)
	recompute_detection("sampler stalled")
end

local function sample_summary()
	local s = S.last_pass
	if not s then
		return "n/a"
	end
	return string.format("total=%d/units=%d/animated=%d/enemies=%d/near_me=%d/changed=%d",
		s.total, s.units, s.animated, s.enemies, s.near_me, s.changed)
end

-- Probe: a read-only inventory of what this runtime exposes. It records names and types and only reads
-- plain values, so the body itself never calls a game or loader function.
local PROBE_NAMES_PER_LINE = 15

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

local function run_probe()
	log(string.format("[DetectionAlert] probe t=%.1f", elapsed_time))
	local jit_table = rawget(_G, "jit")
	log(string.format("[DetectionAlert]   runtime: _VERSION=%s jit=%s ffi=%s bit=%s",
		tostring(_VERSION), type(jit_table), type(rawget(_G, "ffi")), type(rawget(_G, "bit"))))

	local loader = rawget(_G, "CowboyBingusModLoader")
	if type(loader) == "table" then
		log("[DetectionAlert]   loader: " .. scalar_fields(loader))
		if type(loader.jit) == "table" then
			log("[DetectionAlert]   loader.jit: " .. scalar_fields(loader.jit))
		end
	else
		log("[DetectionAlert]   CowboyBingusModLoader=" .. type(loader))
	end

	log(string.format("[DetectionAlert]   enemy whitelist: %d resource hashes", ENEMY_COUNT))

	local engine = rawget(_G, "stingray")
	if type(engine) ~= "table" then
		log("[DetectionAlert]   stingray=" .. type(engine))
		return
	end
	-- The member names, not just the count: this is what tells us whether a build exposes a direct
	-- local-player getter, which is the one thing that would make the me/mate split exact.
	log_list("stingray members", typed_entries(engine), 200)
	for _, name in ipairs(CFG.probe_tables) do
		local space = rawget(engine, name) or rawget(_G, name)
		if type(space) == "table" then
			log_list("stingray." .. name, typed_entries(space), 120)
		end
	end
end

-- Same read-only getter that P2P-Ping polls; the probe body itself calls nothing.
local function in_game_session()
	local network = engine_table("Network")
	if type(network) ~= "table" or type(rawget(network, "game_session")) ~= "function" then
		return false
	end
	local ok, session = pcall(network.game_session)
	return ok and session ~= nil
end

-- Keys. One table drives all four: two fight markers for checking the detector against what you saw,
-- the HUD toggle, and the team probe. Each entry's handler runs on the press edge only.
local KEYS = { ready = false, list = {} }

local function key_entry(name, label, handler)
	KEYS.list[#KEYS.list + 1] = { name = name, label = label, handler = handler, id = nil, down = false }
end

local function poll_keys()
	if not KEYS.ready and elapsed_time >= 1 then
		KEYS.ready = true
		for _, key in ipairs(KEYS.list) do
			key.id = engine_call("Keyboard", "button_id", key.name)
			log(string.format("[DetectionAlert] key %s id=%s (%s)", key.name, tostring(key.id), key.label))
		end
	end
	for _, key in ipairs(KEYS.list) do
		if key.id ~= nil then
			local pressed = engine_call("Keyboard", "pressed", key.id) == true
			if pressed and not key.down then
				local ok, err = pcall(key.handler)
				if not ok then
					log_error("key " .. key.name, err)
				end
			end
			key.down = pressed
		end
	end
end

local function log_marker(label)
	log(string.format("[DetectionAlert] %s t=%.1f wall=%s me_changed=%d me_alerted=%d mate_changed=%d mate_alerted=%d detected=%d searching=%d team=%d mode=%s",
		label, elapsed_time, wall_clock(), SC.me.changed, SC.me.alerted, SC.mate.changed, SC.mate.alerted,
		DetectionAlert.is_detected and 1 or 0, DetectionAlert.enemies_searching and 1 or 0,
		DetectionAlert.team_detected and 1 or 0, S.mode))
end

-- Team probe, one key press in a level with your squad. It lists the animated player units, reads each
-- one's position and reports how far apart the squad is, then measures a sample of other animated units
-- against you. Every call is preceded by its own flushed log line, so if the game dies the last line
-- names the unit. Nothing here runs until the key is pressed.
local function team_probe_run()
	local session = engine_call("Network", "game_session")
	log("[DetectionAlert] team probe: Network.game_session returned " .. type(session))
	if type(session) == "userdata" and type(getmetatable) == "function" then
		local ok, metatable = pcall(getmetatable, session)
		if ok and type(metatable) == "table" and type(rawget(metatable, "__index")) == "table" then
			log_list("team probe game-session members", typed_entries(rawget(metatable, "__index")), 40)
		end
	end

	local world = engine_call("Application", "main_world")
	local units = world ~= nil and engine_call("World", "units", world) or nil
	if type(units) ~= "table" then
		log("[DetectionAlert] team probe: no world units yet, press again once the level has loaded")
		return
	end
	local mine, others = {}, {}
	for index = 1, #units do
		local unit = units[index]
		if engine_call("Unit", "alive", unit) == true and engine_call("Unit", "has_animation_state_machine", unit) == true then
			local hash = unit_hash(engine_call("Unit", "resource_name", unit))
			if is_player_hash(hash) then
				mine[#mine + 1] = { unit = unit, hash = hash }
			elseif ENEMY[hash] ~= nil and #others < CFG.probe_max_units then
				-- Only whitelisted enemies are measured; before the whitelist this listed every animated
				-- prop in the level, which drowned the useful lines.
				others[#others + 1] = { unit = unit, hash = hash }
			end
		end
	end
	log(string.format("[DetectionAlert] team probe: %d animated player unit(s), %d enemy unit(s) to measure, tracked anchors=%d mode=%s basis=%s",
		#mine, #others, #S.anchors, S.mode, S.me_basis))
	if #mine == 0 then
		log("[DetectionAlert] team probe: no player unit found, so CFG.me_hashes is wrong for this build")
		return
	end

	-- Does this build let us name the local player outright? This is the decisive question for the split,
	-- and the only place an untried getter is ever called: one candidate per press, so a fatal one costs
	-- a single press and is recorded as fatal before the call so it is never retried.
	load_probe_state()
	for _, getter in ipairs(CFG.me_getters) do
		log(string.format("[DetectionAlert] team probe: %s.%s is %s, probe state %s", getter.space, getter.member,
			engine_fn(getter.space, getter.member) ~= nil and "present" or "missing",
			PROBE.status[getter.name] or "untried"))
	end
	local candidate = next_untried_getter()
	if confirmed_getter() ~= nil then
		log("[DetectionAlert] team probe: a local-player getter is already confirmed; nothing left to try")
	elseif candidate == nil then
		log("[DetectionAlert] team probe: every candidate has been tried; the split stays in assumed mode")
	else
		local anchors = #S.anchors > 0 and S.anchors or { { unit = mine[1].unit, hash = mine[1].hash } }
		if try_getter(candidate, anchors) then
			log("[DetectionAlert] team probe: confirmed; it will be used automatically from now on")
		else
			log("[DetectionAlert] team probe: press F7 again to try the next candidate")
		end
	end

	log(string.format("[DetectionAlert] team probe: about to call Unit.world_position on player unit 1/%d", #mine))
	local origin = engine_call("Unit", "world_position", mine[1].unit, 0)
	log("[DetectionAlert] team probe: player unit 1 survived, position is a " .. type(origin))
	if origin == nil then
		return
	end
	for index = 2, #mine do
		local pos = engine_call("Unit", "world_position", mine[index].unit, 0)
		local d2 = distance_squared(origin, pos)
		log(string.format("[DetectionAlert] team probe: player unit %d is %s m from player unit 1", index,
			d2 and string.format("%.1f", math.sqrt(d2)) or "?"))
	end
	for index, entry in ipairs(others) do
		local pos = engine_call("Unit", "world_position", entry.unit, 0)
		local d2 = distance_squared(origin, pos)
		log(string.format("[DetectionAlert] team probe: enemy %d %s (%s) is %s m from player unit 1", index,
			ENEMY[entry.hash] or "?", entry.hash,
			d2 and string.format("%.1f", math.sqrt(d2)) or "?"))
	end
	log("[DetectionAlert] team probe: finished, no crash")
end

-- On-screen indicator. Drawn the way P2P-Ping draws its list, with only the calls that mod runs on this
-- build: World.create_screen_gui on the main world, then Gui.resolution, Gui.text, Gui.destroy_text and
-- Gui.set_visible. No other draw call is used, because a bad native call cannot be caught by pcall. Text
-- is rebuilt only when a line or its position changes, and the gui is not touched while no game session
-- is active, because its world may be gone.
local HUD = {
	visible = true, faulted = false, faults = 0,
	gui = nil, gui_world = nil,
	ids = {}, -- line index -> { shadow = id, main = id }
	cache = {}, -- line index -> what was last drawn, so unchanged lines are left alone
	colors = {}, logged = {}, retry_at = 0,
}

local function hud_log_once(key, text)
	if not HUD.logged[key] then
		HUD.logged[key] = true
		log("[DetectionAlert] hud " .. text)
	end
end

local function hud_color(name, look)
	local cached = HUD.colors[name]
	if cached ~= nil then
		return cached
	end
	local make = engine_table("Color")
	if make == nil then
		return nil
	end
	local ok, made = pcall(make, 255, look.r, look.g, look.b)
	if ok and made ~= nil then
		HUD.colors[name] = made
		return made
	end
	return nil
end

local function hud_destroy_pair(target_gui, pair, destroy)
	if not destroy or pair == nil then
		return
	end
	if pair.shadow ~= nil then
		pcall(destroy, target_gui, pair.shadow)
	end
	if pair.main ~= nil then
		pcall(destroy, target_gui, pair.main)
	end
end

local function hud_clear_text(target_gui)
	local destroy = engine_fn("Gui", "destroy_text")
	if destroy and target_gui ~= nil then
		for _, pair in pairs(HUD.ids) do
			hud_destroy_pair(target_gui, pair, destroy)
		end
	end
	HUD.ids, HUD.cache = {}, {}
end

-- True only if the engine still lists the world, so a gui on a destroyed world is never touched.
local function hud_world_is_live(world)
	local worlds_fn = engine_fn("Application", "worlds")
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
	if HUD.gui ~= nil and HUD.gui_world == game_world then
		return HUD.gui
	end
	if HUD.gui ~= nil then
		if hud_world_is_live(HUD.gui_world) then
			hud_clear_text(HUD.gui)
			local destroy_gui = engine_fn("World", "destroy_gui")
			if destroy_gui then
				pcall(destroy_gui, HUD.gui_world, HUD.gui)
			end
		end
		HUD.gui, HUD.gui_world = nil, nil
		HUD.ids, HUD.cache = {}, {}
	end
	local create = engine_fn("World", "create_screen_gui")
	if not create then
		hud_log_once("no_screen_gui", "World.create_screen_gui is missing")
		return nil
	end
	local ok, made = pcall(create, game_world, "scale", 1, 1)
	if not ok or made == nil then
		hud_log_once("gui_failed", "screen gui create failed: " .. tostring(made))
		return nil
	end
	HUD.gui, HUD.gui_world = made, game_world
	hud_log_once("gui_created", "screen gui created on the main world")
	return made
end

-- One count row: "ON TEAM      3 !", padded into the fixed-width columns the rule line is measured
-- against. A row rests in its own colour and escalates to amber then red with its count, so a glance
-- at the colours says as much as reading the numbers.
--
-- `key` is both the colour-cache key and the redraw key, so the tier is baked into it: a row that
-- changes colour without changing key would keep the stale cached colour AND be judged unchanged.
local function hud_count_row(key, label, value, flag, resting)
	local tiers, look = CFG.hud.counts[key], CFG.hud.look
	local tier, shown = "calm", resting
	if tiers ~= nil and type(value) == "number" then
		if value >= tiers.hot then
			tier, shown = "hot", look.hot
		elseif value >= tiers.warn then
			tier, shown = "warn", look.warn
		end
	end
	-- A flag is only ever set when that row's tier has fired, so it carries colour too: "ON TEAM 0 !"
	-- in resting blue would say the squad is clear in the same breath as saying it is not.
	if flag ~= nil and tier == "calm" then
		tier, shown = "warn", look.warn
	end
	return {
		text = string.format("%-8s%3s%s", label, tostring(value), flag or ""),
		key = key .. ":" .. tier,
		look = shown,
		size = CFG.hud.count_size,
	}
end

local function hud_lines()
	local hud, look = CFG.hud, CFG.hud.look
	local state = DetectionAlert.is_detected and "detected"
		or (DetectionAlert.enemies_searching and "searching" or "hidden")
	local state_look = look[state]
	local lines = {}
	if hud.show_title then
		lines[#lines + 1] = { text = "DETECTION ALERT", key = "title", look = look.title, size = hud.title_size }
	end
	lines[#lines + 1] = { text = state_look.text, key = state, look = state_look, size = hud.font_size }
	if hud.show_meter then
		-- The eye's own glow ramp, which until now only ever reached the status file. Quantised to the
		-- cells it can actually show, so a fade redraws meter_cells times instead of once a frame.
		local cells = math.floor(DetectionAlert.eye_intensity * hud.meter_cells + 0.5)
		cells = math.max(0, math.min(hud.meter_cells, cells))
		lines[#lines + 1] = {
			text = "[" .. string.rep("#", cells) .. string.rep(".", hud.meter_cells - cells) .. "]",
			key = "meter:" .. state, look = state_look, size = hud.meter_size,
		}
	end

	local counts = {}
	if hud.show_near then
		-- A real count, not an activity figure: known enemy resources standing within me_radius of you,
		-- whether or not any of them has noticed you. "-" until the first pass finishes.
		local last = S.last_pass
		counts[#counts + 1] = hud_count_row("near", "NEAR", last and last.near_me or "-", nil, look.near)
	end
	if hud.show_alerted then
		counts[#counts + 1] = hud_count_row("alerted", "ON YOU", SC.me.alerted, nil, look.alerted)
	end
	if hud.show_team and CFG.team_split then
		-- "?" while nobody can be told apart from you: a number there would be a guess.
		local known = S.mode == "me"
		counts[#counts + 1] = hud_count_row("team", "ON TEAM", known and SC.mate.alerted or "?",
			(known and DetectionAlert.team_detected) and " !" or nil, look.team)
	end
	if hud.show_active then
		counts[#counts + 1] = hud_count_row("active", "ACTIVE", SC.me.changed, nil, look.info)
	end
	if #counts > 0 then
		lines[#lines + 1] = { text = string.rep("-", hud.rule_width), key = "rule",
			look = look.rule, size = hud.rule_size }
		for _, row in ipairs(counts) do
			lines[#lines + 1] = row
		end
	end
	return lines
end

local function hud_draw()
	local resolution = engine_fn("Gui", "resolution")
	local text_fn = engine_fn("Gui", "text")
	local Vector2 = engine_table("Vector2")
	if not resolution or not text_fn or Vector2 == nil then
		hud_log_once("api_missing", string.format("draw api missing: resolution=%s text=%s vector2=%s",
			tostring(resolution ~= nil), tostring(text_fn ~= nil), tostring(Vector2 ~= nil)))
		return
	end
	if elapsed_time < HUD.retry_at then
		return
	end
	local game_world = engine_call("Application", "main_world")
	if game_world == nil then
		return
	end
	local target_gui = hud_get_gui(game_world)
	if target_gui == nil then
		HUD.retry_at = elapsed_time + CFG.hud.retry_seconds
		return
	end
	local set_visible = engine_fn("Gui", "set_visible")
	if set_visible then
		pcall(set_visible, target_gui, true)
	end
	local ok, width, height = pcall(resolution)
	if not ok or type(width) ~= "number" or type(height) ~= "number" or width <= 0 or height <= 0 then
		hud_log_once("resolution", "resolution unavailable")
		return
	end
	hud_log_once("resolution", string.format("resolution=%dx%d", width, height))

	local x = math.floor(math.max(24, width * CFG.hud.x_fraction) + 0.5)
	local py = math.floor(height * CFG.hud.y_fraction + 0.5)
	local destroy = engine_fn("Gui", "destroy_text")
	local lines = hud_lines()
	-- Rows are different sizes, so each steps down by the PREVIOUS row's height rather than by a fixed
	-- stride, and `size` joins the cache key: a row that changed only its size would otherwise be
	-- judged unchanged and keep the old glyphs.
	local previous_size = nil
	for index, line in ipairs(lines) do
		local size = line.size or CFG.hud.font_size
		if previous_size ~= nil then
			py = py - (previous_size + CFG.hud.line_gap)
		end
		previous_size = size
		local cached = HUD.cache[index]
		local pair = HUD.ids[index] or {}
		if cached == nil or cached.text ~= line.text or cached.key ~= line.key or cached.x ~= x
			or cached.y ~= py or cached.size ~= size or pair.shadow == nil or pair.main == nil then
			hud_destroy_pair(target_gui, pair, destroy)
			local ok_shadow, shadow_pos = pcall(Vector2, x + 1, py - 1)
			local ok_main, main_pos = pcall(Vector2, x, py)
			local shadow_color = hud_color("shadow", CFG.hud.look.shadow)
			local main_color = hud_color(line.key, line.look)
			pair = {}
			if ok_shadow and shadow_pos ~= nil and shadow_color ~= nil then
				local drawn, id = pcall(text_fn, target_gui, line.text, CFG.hud.font, size, CFG.hud.font, shadow_pos, shadow_color)
				if drawn then
					pair.shadow = id
				else
					hud_log_once("text_failed", "text call failed: " .. tostring(id))
				end
			end
			if ok_main and main_pos ~= nil and main_color ~= nil then
				local drawn, id = pcall(text_fn, target_gui, line.text, CFG.hud.font, size, CFG.hud.font, main_pos, main_color)
				if drawn then
					pair.main = id
					hud_log_once("text_ok", "text call ok")
				else
					hud_log_once("text_failed", "text call failed: " .. tostring(id))
				end
			end
			HUD.ids[index] = pair
			HUD.cache[index] = { text = line.text, key = line.key, x = x, y = py, size = size }
		end
	end
	for index in pairs(HUD.ids) do
		if type(index) == "number" and index > #lines then
			hud_destroy_pair(target_gui, HUD.ids[index], destroy)
			HUD.ids[index], HUD.cache[index] = nil, nil
		end
	end
end

local function hud_toggle()
	HUD.visible = not HUD.visible
	if not HUD.visible and HUD.gui ~= nil and S.session_active then
		hud_clear_text(HUD.gui)
		local set_visible = engine_fn("Gui", "set_visible")
		if set_visible then
			pcall(set_visible, HUD.gui, false)
		end
	end
	log(string.format("[DetectionAlert] hud visible=%s", tostring(HUD.visible)))
end

-- A fault drops our references (the gui is rebuilt on the next draw); too many in a row disarms the HUD
-- only, leaving detection and logging running.
local function hud_guarded_tick()
	if not S.session_active or not HUD.visible then
		return
	end
	local ok, err = pcall(hud_draw)
	if ok then
		HUD.faults = 0
		return
	end
	HUD.faults = HUD.faults + 1
	log_error("hud", err)
	HUD.gui, HUD.gui_world = nil, nil
	HUD.ids, HUD.cache = {}, {}
	if HUD.faults >= CFG.hud.max_faults then
		HUD.faulted = true
		log("[DetectionAlert] hud disarmed after repeated errors; detection and logging are unaffected")
	end
end

-- Best-effort class name for table/userdata values via common metatable conventions.
local function describe_value(value)
	local mt = getmetatable(value)
	local class_name = nil
	if type(mt) == "table" then
		class_name = mt.__name or mt.class_name or (type(mt.__index) == "table" and mt.__index.__name) or nil
	end
	return string.format("%s%s=%s", type(value), class_name and (":" .. class_name) or "", tostring(value))
end

local function describe_arguments(...)
	local values = {}
	for i = 1, select("#", ...) do
		values[i] = string.format("arg%d[%s]", i, describe_value((select(i, ...))))
	end
	return table.concat(values, ", ")
end

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
	if contains_any(normalized, CFG.alert_off_keywords) then
		WW.detected, WW.searching = false, false
	elseif contains_any(normalized, CFG.combat_keywords) then
		WW.detected, WW.searching = true, true
	elseif contains_any(normalized, CFG.search_keywords) then
		WW.searching = true
	else
		return
	end
	WW.matches = WW.matches + 1
	recompute_detection(label)
end

local function on_wwise_call(label, signal, count, ...)
	if signal then
		WW.signal_calls = WW.signal_calls + 1
	elseif count > CFG.wwise_detail_limit then
		return
	end
	local detail = describe_arguments(...)
	if count <= CFG.wwise_detail_limit then
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
		WW.calls = WW.calls + 1
		local count = (WW.counts[label] or 0) + 1
		WW.counts[label] = count
		local ok, err = pcall(on_wwise_call, label, signal, count, ...)
		if not ok then
			log_error("wwise " .. label, err)
		end
		return original(...)
	end
	WW.wrappers[wrapper] = true
	return wrapper
end

local function hook_wwise_table(table_name, callbacks)
	local hooked, signals, names = 0, 0, {}
	for method_name, value in pairs(callbacks) do
		if type(value) == "function" and not WW.wrappers[value] then
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

-- Runs at startup and every CFG.wwise_sync_interval: hooks tables that appeared later and re-hooks any
-- table whose functions were replaced.
local function sync_wwise_hooks()
	for _, table_name in ipairs({ "WwiseFlowCallbacks", "WwiseVisualization" }) do
		local callbacks = rawget(_G, table_name)
		if type(callbacks) ~= "table" then
			if not WW.missing[table_name] then
				WW.missing[table_name] = true
				log("[DetectionAlert] " .. table_name .. " not found yet; retrying every " .. CFG.wwise_sync_interval .. " s")
			end
		else
			local unhooked = false
			for _, value in pairs(callbacks) do
				if type(value) == "function" and not WW.wrappers[value] then
					unhooked = true
					break
				end
			end
			if unhooked then
				hook_wwise_table(table_name, callbacks)
			end
		end
	end
end

-- No in-game HUD/draw API exists in either loader for the eye itself, so the state is exposed here for an
-- external overlay to read: one throttled line per tick. The file is truncated at session start and again
-- whenever it passes status_max_bytes. tools/overlay/DetectionAlertOverlay.ps1 polls its tail, and parses
-- these fields positionally, so their order and names must not change.
local ST = { file = nil, bytes = 0, announced = false, last_write = -math.huge }

local function open_status_file()
	local handle, target = open_log_file(CFG.status_file)
	ST.file = handle or false
	ST.bytes = 0
	if not ST.announced then
		ST.announced = true
		log("[DetectionAlert] status file: " .. (handle and target or ("unavailable: " .. target)))
	end
end

-- Fills the public counts from the last completed pass. Until one completes -- and whenever a mission
-- ends, which clears S.last_pass -- the two enemy counts read -1 rather than 0, so an overlay can tell
-- "no enemies around" from "nothing measured yet".
local function refresh_counts()
	local last = S.last_pass
	if last then
		DetectionAlert.search_count = last.enemies
		DetectionAlert.detect_count = last.near_me
		DetectionAlert.count_source = "hashes"
	else
		DetectionAlert.search_count = -1
		DetectionAlert.detect_count = -1
		DetectionAlert.count_source = "none"
	end
	DetectionAlert.active_units = SC.me.changed
	DetectionAlert.alerted_units = SC.me.alerted
	DetectionAlert.team_alerted = SC.mate.alerted
	DetectionAlert.team_mode = S.mode
end

local function write_status()
	if ST.file == nil then
		open_status_file()
	elseif ST.file and ST.bytes > CFG.status_max_bytes then
		pcall(ST.file.close, ST.file)
		open_status_file()
	end
	if not ST.file then
		return
	end
	local ok_counts, counts_err = pcall(refresh_counts)
	if not ok_counts then
		log_error("refresh_counts", counts_err)
	end
	local c = DetectionAlert.eye_color or CFG.eye.idle
	local line = string.format(
		"t=%.2f detected=%d intensity=%.3f r=%.3f g=%.3f b=%.3f searching=%d search_count=%d detect_count=%d active_units=%d count_source=%s alerted_units=%d team_alerted=%d team_mode=%s",
		elapsed_time, DetectionAlert.is_detected and 1 or 0, DetectionAlert.eye_intensity,
		c.r, c.g, c.b, DetectionAlert.enemies_searching and 1 or 0,
		DetectionAlert.search_count, DetectionAlert.detect_count, DetectionAlert.active_units,
		DetectionAlert.count_source, DetectionAlert.alerted_units, DetectionAlert.team_alerted,
		DetectionAlert.team_mode)
	local ok, err = pcall(write_line, ST.file, line)
	if ok then
		if ST.bytes == 0 then
			log("[DetectionAlert] status file: first write ok")
		end
		ST.bytes = ST.bytes + #line + 1
	else
		ST.file = false
		log_error("write_status", err)
	end
end

local TIMERS = { wwise_sync = 0, heartbeat = CFG.heartbeat_interval }

local function heartbeat()
	log(string.format(
		"[DetectionAlert] t=%.1f heartbeat detected=%s searching=%s team=%s wwise_calls=%d wwise_signal_calls=%d wwise_matches=%d errors=%d sample=%s me=%d/%d mate=%d/%d anchors=%d mode=%s status_bytes=%d",
		elapsed_time, tostring(DetectionAlert.is_detected), tostring(DetectionAlert.enemies_searching),
		tostring(DetectionAlert.team_detected), WW.calls, WW.signal_calls, WW.matches, LOG.errors,
		sample_summary(), SC.me.changed, SC.me.alerted, SC.mate.changed, SC.mate.alerted,
		#S.anchors, S.mode, ST.bytes))
end

local function tick(dt)
	elapsed_time = elapsed_time + dt
	update_eye_glow(dt)
	-- Pending: once a real turret light/material draw call is confirmed, call it here with
	-- DetectionAlert.eye_color / DetectionAlert.eye_intensity.

	if elapsed_time - ST.last_write >= CFG.status_interval then
		ST.last_write = elapsed_time
		write_status()
	end

	if elapsed_time >= TIMERS.wwise_sync then
		TIMERS.wwise_sync = elapsed_time + CFG.wwise_sync_interval
		local ok, err = pcall(sync_wwise_hooks)
		if not ok then
			log_error("sync_wwise_hooks", err)
		end
	end

	if elapsed_time >= TIMERS.heartbeat then
		TIMERS.heartbeat = elapsed_time + CFG.heartbeat_interval
		heartbeat()
	end

	local keys_ok, keys_err = pcall(poll_keys)
	if not keys_ok then
		log_error("poll_keys", keys_err)
	end

	if elapsed_time >= S.next_session_check then
		S.next_session_check = elapsed_time + 1
		S.session_active = in_game_session()
		if S.session_active and not S.session_probe_done then
			S.session_probe_done = true
			log(string.format("[DetectionAlert] game session detected at t=%.1f", elapsed_time))
			local ok, err = pcall(run_probe)
			if not ok then
				log_error("probe", err)
			end
		end
	end

	if not S.session_active then
		S.last_pass = nil
		S.units = nil
		S.credit = 0
		local ok, err = pcall(reset_sampler)
		if not ok then
			log_error("reset_sampler", err)
		end
	else
		local started = cpu_time()
		local ok, err = pcall(sample_enemies, dt)
		S.cost = S.cost + (cpu_time() - started)
		if not ok then
			log_error("sampler", err)
		end
		local stall_ok, stall_err = pcall(check_stall)
		if not stall_ok then
			log_error("check_stall", stall_err)
		end
	end

	if CFG.hud.enabled and not HUD.faulted then
		hud_guarded_tick()
	end

	if S.probe_index <= #CFG.probe_times and elapsed_time >= CFG.probe_times[S.probe_index] then
		S.probe_index = S.probe_index + 1
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
	local loader = rawget(_G, "CowboyBingusModLoader")
	log(string.format("[DetectionAlert] start: %s, t=%.2f", tostring(_VERSION), elapsed_time))
	log(string.format(
		"[DetectionAlert] env: CowboyBingusModLoader=%s open_log=%s WwiseFlowCallbacks=%s WwiseVisualization=%s update=%s io=%s os.getenv=%s",
		type(loader), type(loader) == "table" and type(loader.open_log) or "n/a",
		type(rawget(_G, "WwiseFlowCallbacks")), type(rawget(_G, "WwiseVisualization")),
		type(rawget(_G, "update")), type(rawget(_G, "io")),
		(type(os) == "table" and type(os.getenv)) or "n/a"))
	log("[DetectionAlert] log file: " .. tostring(LOG.target))
	log(string.format("[DetectionAlert] enemies: %d whitelisted resource hashes; units outside the list are never counted",
		ENEMY_COUNT))
	log(string.format("[DetectionAlert] tiers: detect_enter=%d/%d exit<=%d x%d alerted_enter=%d exit<=%d search_enter=%d exit<=%d x%d min_animated=%d",
		CFG.detect.enter, CFG.detect.pair, CFG.detect.exit_at, CFG.detect.exit_passes,
		CFG.alert_detect.enter, CFG.alert_detect.exit_at,
		CFG.search.enter, CFG.search.exit_at, CFG.search.exit_passes, CFG.min_animated))
	log(string.format("[DetectionAlert] attribution: enabled=%s me_radius=%d team_radius=%d max_anchors=%d anchor_grace=%d auto_probe=%s",
		tostring(CFG.team_split), CFG.me_radius, CFG.team_radius, CFG.max_anchors, CFG.anchor_grace,
		tostring(CFG.probe_local_player)))
	load_probe_state()
	log(string.format("[DetectionAlert] hud enabled=%s toggle=%s x=%.4f y=%.2f size=%d",
		tostring(CFG.hud.enabled), CFG.keys.hud_toggle, CFG.hud.x_fraction, CFG.hud.y_fraction, CFG.hud.font_size))
	log(string.format("[DetectionAlert] keys: %s=fight start, %s=fight end, %s=team probe, %s=hud",
		CFG.keys.marker_start, CFG.keys.marker_end, CFG.keys.probe, CFG.keys.hud_toggle))
end

key_entry(CFG.keys.marker_start, "START MARKER", function() log_marker("START MARKER") end)
key_entry(CFG.keys.marker_end, "END MARKER", function() log_marker("END MARKER") end)
key_entry(CFG.keys.hud_toggle, "hud toggle", hud_toggle)
key_entry(CFG.keys.probe, "team probe", function()
	if S.session_active then
		team_probe_run()
	else
		log("[DetectionAlert] team probe: press it while a level is running")
	end
end)

report_environment()
install_update_hook()

log(string.format("[DetectionAlert] startup done: status every %.1f s, heartbeat every %d s",
	CFG.status_interval, CFG.heartbeat_interval))

return DetectionAlert
