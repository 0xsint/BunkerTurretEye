# Detection Alert (Helldivers 2)

Shows an on-screen "DETECTED" / "HIDDEN" indicator (and drives a turret-eye glow) from a
combat-activity heuristic, and splits that activity into **enemies on you** and **enemies on your
squad**. Built for [Chef Shared Loader](https://github.com/Th3chef/Chef-Shared-Loader) 1.5.0+.

## Detection sources

In priority order:

1. **Enemy sampler**, below. This is the live source on current Steam builds.
2. **Wwise audio-state heuristic** (`WwiseFlowCallbacks` / `WwiseVisualization`), matching combat/calm
   keywords in state, switch and trigger-event names. Loader v21 removed these callbacks, so they are
   nil on current builds and this path is idle.

The `basis=` and `mode=` fields in each `attribution` line say which path is driving the verdict.

> Earlier versions took per-player counts from **AggroCounter** when it was running. That dependency is
> gone: it needed LuaJIT FFI to read game memory and has been off on every current build, and the enemy
> hash whitelist below now supplies real enemy counts without it. Nothing here reads another mod.

## What counts as an enemy

The engine hands out resource hashes, not names. The mod carries an explicit whitelist of **114 enemy
resource hashes** (59 Automaton, 41 Terminid, 14 Illuminate) in the `ENEMY` table at the top of
[detection_alert.lua](mods/vixenhunny/detection_alert.lua), and **a unit whose hash is not in it is
ignored outright** — it reaches no scope, no calm model and no published count. Hellpods, sentries,
exosuits, Guard Dogs, SEAF troopers, civilians, structures and the world's ~17,000 props therefore
cannot move the eye at all. The player resource (`4d1c334d294dfa97`) comes from the same table and is
matched separately, as an anchor.

The table is generated from the [EnemyData](https://github.com/) project — its `data/game_names.lua`
(which in-game unit names are enemies) crossed with its assembled hash → name table. Only hashes whose
name is listed as an enemy survive the crossing. Regenerate it after a game patch adds units:

```
python tools/gen_enemy_hashes.py --enemy-data <path to an EnemyData checkout>
```

EnemyData builds its hash → name table from the **Enemy HP** mod's table, which is that author's work.
Ask them before publishing a build that embeds it.

When a patch adds a unit type the whitelist does not know, it is silently not counted. The 30-second
detail block's `unlisted animated:` line is the place to catch that: a hash climbing it during fights
is a missing enemy, and belongs in EnemyData's `game_names.lua` before the table is regenerated here.

## How activity is attributed to you or your squad

There is no direct enemy-AI-perception API reachable from a mod, and every Helldiver shares one unit
resource hash (`4d1c334d294dfa97`), so "which of these four units is me" cannot be answered from the
resource alone. The sampler therefore keeps every player unit it finds as an **anchor**, decides which
anchor is you, and attributes each active enemy by distance:

| bucket | rule | drives |
| --- | --- | --- |
| `me` | within `CFG.me_radius` (35 m) of your anchor | `is_detected`, the eye, the HUD state line |
| `mate` | within `CFG.team_radius` (60 m) of a squadmate's anchor | `team_detected`, the HUD `ON TEAM` line |
| `loose` | near nobody | nothing; logged for tuning |
| `unplaced` | no usable position | nothing; logged for tuning |

An enemy inside `me_radius` of you counts as yours even when a squadmate is standing closer, because
the question the eye answers is "is anything near *me*", not "whose kill is this".

### Deciding which anchor is you

`resolve_me` tries three stages, and the `basis=` field reports which one is in force:

- **`api`** — a getter that names the local player's unit. See the safety rules below.
- **`continuity`** — the anchor you were last pass, while its unit is alive. This is what stops the
  choice drifting between squadmates when a pass happens not to re-sight your unit.
- **`assumed`** — no getter is confirmed, so the first anchor is used and **every anchor counts as
  you**. The eye then behaves exactly as it did before the split existed, the HUD shows `ON TEAM ?`,
  and nothing claims to know whose fight it is. Continuity never upgrades an assumed pick to a
  confirmed one.

### Probing for a local-player getter, safely

A native engine call that asserts **kills the process outright — `pcall` cannot catch it**. On
2026-10-29, probing `Unit.has_camera(unit)` hard-crashed build 26088801: Stingray's `has_camera` takes
a camera name or index as a second argument, and the one-argument form asserts inside the engine. It
is permanently blacklisted in `CFG`; `Unit.num_cameras(unit)` is the safe single-argument equivalent.

So the rule is: **an untried getter is never called on its own.**

- Pressing **F7** tries exactly **one** untried candidate per press.
- The outcome is appended to `DetectionAlertProbe.txt` *before* the call and completed after it. A
  `try` line with no result after it means the call never returned, so the getter is recorded as
  **fatal and never attempted again on any later run**. That file lives beside the logs and is not
  truncated at game start, because this knowledge has to outlive a crash.
- A getter recorded `ok` is used automatically from then on, with no further prompting.
- `CFG.probe_local_player = true` lets the mod try untried candidates by itself. It defaults to
  **false**. Leave it there unless you are deliberately probing.

The candidates, in order, both derived from the F7 dump of this build:

| candidate | call | how it finds you |
| --- | --- | --- |
| `unit_num_cameras` | `Unit.num_cameras(unit)` | on a client only your unit carries the viewport camera |
| `world_debug_camera_pose` | `World.debug_camera_pose(world)` + `Matrix4x4.translation` | you are the anchor nearest the active camera |

> **Current status on build 26088801:** the F7 dump shows **no `Player` table and no `Managers` table
> at all**, so there is no direct local-player API — a camera is the only route. Neither candidate has
> been confirmed yet. Until one is, the mod runs in `assumed` mode: your own detection is as accurate
> as it ever was, and the squad split reads `?` rather than guessing.

## The enemy sampler

A **read-only** walk over the main world's units, running only while a game session is active. It uses
engine getters only (`World.units`, `Unit.alive`, `Unit.resource_name`,
`Unit.has_animation_state_machine`, `Unit.animation_get_state`, `Unit.world_position`,
`Vector3.distance_squared`). A full pass takes about 5 s, spread over frames, capped at
`CFG.max_units_per_frame` units per frame, from a fresh snapshot of the unit list each pass. **Nothing
in it writes game state.**

Every unit is counted into `units` / `animated` (the loading-screen gate), then everything outside the
`ENEMY` whitelist is dropped. What survives produces two kinds of figure:

**Counts** — how many enemies are *there*, whether or not any of them has noticed you:

| field | meaning |
| --- | --- |
| `enemies` | whitelisted enemies alive in the pass |
| `near_me` | of those, within `CFG.me_radius` (35 m) of you — the HUD's `NEAR` line |
| `near_mate` | of those, within `CFG.team_radius` (60 m) of a squadmate |

**Activity**, which is what actually drives the eye, per bucket:

- **`changed`** — enemies whose animation state differs from the previous sample. Immediate, but noisy.
- **`alerted`** — enemies sitting in an animation state their resource is not normally seen in. Per
  enemy resource the sampler learns the states its units occupy during quiet passes (the *calm model*),
  then counts anything outside that set. More stable, but it reads 0 until a resource has
  `CFG.calm_min_samples` quiet observations, so it warms up over the first minute of a mission.

Enemies being nearby is deliberately **not** detection: standing next to an unaware patrol is the whole
point of stealth, so `near_me` is reported and never scored.

Your own player units are anchors, never activity: your running and shooting cannot trigger your own
detection. `CFG.ambient_hashes` is an escape hatch for a whitelisted enemy resource that churns
regardless; it is empty, because the resource that used to need it is not an enemy and no longer
reaches the counts.

Animation states come back as integers and resource ids as 64-bit hashes (`IdString64`), not names, so
states are counted as they are; hashes are shown by their enemy name in the log.

## Detection tiers

Each of the `me` and `mate` buckets runs the same hysteretic state machine:

- **DETECTED** — `changed >= 6` in one pass, or `>= 3` in two passes in a row, or `alerted >= 8`.
  Ends after 2 passes at or below `changed <= 1` *and* `alerted <= 3`.
- **SEARCHING** (status only) — `changed >= 3`. Ends after 2 passes at or below 1. Always on while
  DETECTED.

Passes with fewer than `CFG.min_animated` (20) animated units are a loading screen, not a mission, and
score zero. A pass that never finishes for 15 s clears every tier rather than leaving a stale verdict.

These numbers come from `tools/analysis/analyze_log.py` over a captured 1024-mission-pass session,
where quiet passes sat at `changed` p90 = 1 / `alerted` p90 = 4 and fights at `changed` p25 = 6 /
`alerted` p25 = 11. Replayed against that session they fire on 43.8% of passes versus the previous
tiers' 38.0%, with 14 state transitions instead of 22 — more sensitive to small skirmishes, and less
flicker.

That session **predates the `ENEMY` whitelist** and was measured with every animated unit feeding the
counts. The whitelist can only remove contributions, never add any, so the thresholds now read slightly
conservative. They have also **not** been validated against labelled fights. Press **F9** when a fight
starts and **F10** when it ends to record ground truth, then retune against a fresh capture; the
analyzer reports whether a log carries any markers.

## On-screen indicator (HUD)

Drawn on the left of the screen, in the same column as P2P-Ping's list and just above it:

```
DETECTION ALERT          dim header, small
(O) DETECTED             the verdict, largest row: red / amber / green
[####......]             the eye's own glow ramp, in the state's colour
-------------
NEAR      12             known enemies within 35 m, aware of you or not ("-" before the first pass)
ON YOU     7             enemies near you outside their calm states
ON TEAM    3 !           the same around your squadmates; "!" means the squad tier fired
ON TEAM    ?             you cannot be told apart from your squad (basis=assumed)
ACTIVE    12             this pass's `changed` count for you, for tuning
```

The rows are everything the mod knows, ranked: the verdict reads from across the room, the counts sit
underneath in fixed-width columns, and the header and rule are dim enough to disappear. Each count row
rests in its own colour and **escalates to amber then red with its value**, so a fight is readable
without reading the numbers.

Where those escalation points come from matters, because only some of them mean anything:

| row | amber at | red at | basis |
| --- | --- | --- | --- |
| `ON YOU` / `ON TEAM` | `alert_detect.exit_at` (3) | `alert_detect.enter` (8) | the alerted tier it mirrors |
| `ACTIVE` | `search.enter` (3) | `detect.enter` (6) | the changed tiers it mirrors |
| `NEAR` | 8 | 20 | **a display choice only** — no tier reads it |

The first two are wired to `CFG` at load, so retuning the tiers retunes the colours with them. `NEAR`
has no tier behind it: a crowd of unaware enemies is not a fight, so red there means "that is a lot of
them", not an alarm, and it can sit red beside a green `HIDDEN` quite legitimately.

Everything it draws is **plain ASCII in fixed-width columns**. The draw path is the one P2P-Ping uses
on this build — a screen gui on the main world, then `Gui.resolution`, `Gui.text`, `Gui.destroy_text`
and `Gui.set_visible`, with no rectangles or other draw calls — and the only font it is known to
survive is the engine's monospace debug font, so box-drawing glyphs are not assumed and the columns do
the framing instead. Each row is drawn twice, a shadow under the text, and is rebuilt only when its
text, colour, position or size changes; the meter is quantised to its ten cells so a fade redraws ten
times rather than once a frame. The gui is not touched while no game session is active. Press **F11**
to hide or show it. If the draw calls fail, the HUD logs one `hud …` line and detection and logging
carry on; five errors in a row disarm just the HUD.

Position, sizes, colours, escalation points and which rows appear are the `CFG.hud` fields near the top
of [detection_alert.lua](mods/vixenhunny/detection_alert.lua). `python tools/analysis/simulate.py
--show` prints the panel for a quiet world, a crowd, and fights on you and on your squad, so a change
can be eyeballed without launching the game.

## Desktop overlay

The mod writes its live eye state to
`%APPDATA%\Arrowhead\Helldivers2\DetectionAlertStatus.log` (one throttled line every
0.5 s). [tools/overlay/DetectionAlertOverlay.ps1](tools/overlay/DetectionAlertOverlay.ps1) is a small
always-on-top window (PowerShell + WinForms, no extra install) that tails it:

```
powershell -ExecutionPolicy Bypass -File tools\overlay\DetectionAlertOverlay.ps1
```

Drag with the left mouse button to reposition; right-click to exit. The status line's field order and
names are a contract with this script — changing them breaks it. Two of those names now carry different
numbers than they used to: `search_count` is the enemies the last pass found alive and `detect_count`
is how many of those were within `me_radius` of you, with `count_source=hashes` instead of the old
`aggro`. Both read `-1` until the first pass of a mission completes.

## Keys

| key | does |
| --- | --- |
| **F7** | team probe: dumps what this build exposes, reports how far apart the squad is, and tries **one** untried local-player getter. Does nothing until pressed. |
| **F9** / **F10** | mark a fight's start / end in the log, for validating the tiers |
| **F11** | show/hide the HUD |

Chef Shared Loader opens its options menu on **F9** by default, the same key as the START MARKER. While that menu is
open these keys read nothing, but the press that opens the menu may still log a START MARKER. Rebind either one to
avoid it; this mod's keys are `CFG.keys` in `detection_alert.lua`.

## Logs and troubleshooting

Every run writes to `%APPDATA%\Arrowhead\Helldivers2\` (Chef Shared Loader's folder for mod logs):

- **`DetectionAlert.log`** (truncated at each game start). Per pass it writes a `pass` line (unit,
  animated, enemy and per-bucket counts, the resulting flags, and the sampler's CPU time), an
  `attribution` line (each scope's verdict, anchor count, `mode`, `basis`, squad spread), and
  `changes` / `transitions` lines naming the enemies that moved. A `heartbeat` lands every 5 s and a
  `sample` detail block every 30 s.
- **`DetectionAlertStatus.log`**: one line per 0.5 s for the overlay. Capped at 64 KB.
- **`DetectionAlertProbe.txt`**: which local-player getters have been tried and how they ended. Not
  truncated at game start, so a getter that crashed the game stays known. Delete it to re-probe
  everything from scratch — including anything previously recorded as fatal.

Where to look when it misbehaves:

- `mode=assumed` in `attribution`: no local-player getter is confirmed, so the squad split is off and
  `ON TEAM` reads `?`. Press F7 once to try the next candidate.
- **The game hard-crashed and the log ends on `me: about to call X`**: that call is fatal on your
  build. Nothing more is needed — the probe file already recorded it as fatal before the call, so it
  will not be tried again. Report the name so it can be blacklisted in `CFG` for everyone.
- `anchors=0`: no player units found, so `CFG.me_hashes` is wrong for this build. The F7 probe says so
  outright.
- `enemies=0` in every `pass` line during a fight: the whitelist does not recognise this build's
  enemies. Check `enemy whitelist: N resource hashes` at startup, then the `unlisted animated:` line in
  the 30-second detail block — the hashes topping it are what should have been counted.
- `spread=` staying small: your squad is standing together, so there is little for the split to
  separate. Note also that the client appears to animate only units near you (17,000 units in the
  world, ~400 animated), so enemies fighting a distant teammate may never reach the sampler at all.
- `wwise_calls=0`: no Wwise callback reached the mod — expected on current builds.
- `status_bytes=0`, or the status log empty: look for `status file: first write ok`.
- `ERROR #n in <where>`: a handler failed; the message names the file and line.

## Developing

Four tools, none of which need the game running:

```
python tools/analysis/check_lua51.py mods/vixenhunny/detection_alert.lua
python tools/analysis/simulate.py
python tools/analysis/analyze_log.py "%APPDATA%\Arrowhead\Helldivers2\DetectionAlert.log"
python tools/gen_enemy_hashes.py --enemy-data <path to an EnemyData checkout>
```

- **`check_lua51.py`** compiles the mod against a real Lua 5.1 runtime, counts the locals the main
  chunk holds open, and loads it under a fake game to catch any global it leaks. Current builds run
  plain Lua 5.1.4: a chunk may hold **at most 200 locals**, and it should define no globals beyond
  `update`, so both matter. (The pre-revamp file was over that limit, which is why 35 of its declarations
  had their `local` stripped and leaked names like `tick` and `heartbeat` into `_G`.)
- **`simulate.py`** loads the real mod source into `harness.lua`'s fake Helldivers 2 and drives
  scripted squad scenarios — a fight on you, a fight on a squadmate 300 m away, both at once, idle
  enemies that must be counted without lighting the eye, 60 unlisted resources churning on top of you
  that must be ignored entirely, and a build with no local-player getter — asserting on the mod's own
  `pass` lines, status output and the rows its HUD draws. `--show` prints those rows.
- **`analyze_log.py`** reads every log format the mod has written and reports the per-tier
  distributions, the enemy counts, how well each metric separates fights from quiet, how activity was
  attributed, and a replay of the shipped tiers against the verdicts a captured session recorded. Keep
  `SHIPPED` in it in step with `CFG` in the mod.
- **`gen_enemy_hashes.py`** rewrites the `ENEMY` whitelist from an EnemyData checkout. Re-run it after
  a game patch adds units, then re-run the two gates.

Both gates must pass before shipping.

## Build

```
python .\tools\build_addon.py --name mods/vixenhunny/detection_alert --entry .\mods\vixenhunny\detection_alert.lua --guid 2b06f66a-6f03-4ca4-8b67-6fc2a153e19a --display-name "Detection Alert" --output .\dist\Detection-Alert.zip
```

Reuse that GUID for every update. Distribute the ZIP alongside a requirement on Chef Shared Loader
1.5.0+; players enable both in Arsenal/HD2MM and deploy. Chef asks to be kept at the highest priority.
