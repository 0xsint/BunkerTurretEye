# Detection Alert (Helldivers 2)

Shows an on-screen "DETECTED" / "HIDDEN" indicator (and drives a turret-eye glow) from a
combat-activity heuristic, and splits that activity into **enemies on you** and **enemies on your
squad**. Built for [Bingus Shared Loader](https://github.com/CowboyBingus/BingusSharedLoader) v21+.

## Detection sources

In priority order:

1. **AggroCounter**, when it exposes numeric `me` and `team` counts during a session. These are real
   per-player enemy counts and are authoritative. It needs LuaJIT FFI to read game memory, so it is
   off on current builds (`aggro=n/a` in the heartbeat).
2. **Wwise audio-state heuristic** (`WwiseFlowCallbacks` / `WwiseVisualization`), matching combat/calm
   keywords in state, switch and trigger-event names. Loader v21 removed these callbacks, so they are
   nil on current builds and this path is idle.
3. **Enemy sampler**, below. This is the live source on current Steam builds.

The `basis=` and `mode=` fields in each `attribution` line say which path is driving the verdict.

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
`Vector3.distance_squared`). A full pass takes about 5 s, spread over frames, at most 400 units per
frame, from a fresh snapshot of the unit list each pass. **Nothing in it writes game state.**

Two independent measures come out of each pass, per bucket:

- **`changed`** — units whose animation state differs from the previous sample. Immediate, but noisy.
- **`alerted`** — units sitting in an animation state their resource is not normally seen in. Per unit
  resource the sampler learns the states its units occupy during quiet passes (the *calm model*), then
  counts anything outside that set. More stable, but it reads 0 until a resource has
  `CFG.calm_min_samples` quiet observations, so it warms up over the first minute of a mission.

Your own player units are anchors, never activity: your running and shooting cannot trigger your own
detection. `CFG.ambient_hashes` excludes resources that change state every pass regardless.

Animation states come back as integers and resource ids as 64-bit hashes (`IdString64`), not names, so
both are counted as they are.

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

They have **not** been validated against labelled fights. Press **F9** when a fight starts and **F10**
when it ends to record ground truth; the analyzer reports whether a log carries any.

## On-screen indicator (HUD)

Drawn on the left of the screen, in the same column as P2P-Ping's list and just above it:

```
(O) DETECTED     red     enemies are active around you
(o) SEARCHING    yellow  lower activity tier
( ) HIDDEN       green   nothing near you
ON YOU 7                 enemies near you outside their calm states
ON TEAM 3!               the same around your squadmates; "!" means the squad tier fired
ON TEAM ?                you cannot be told apart from your squad (basis=assumed)
ACTIVE 12                this pass's `changed` count for you, for tuning
```

It is drawn the way P2P-Ping draws, with only the calls that mod runs on this build: a screen gui on
the main world, then `Gui.resolution`, `Gui.text`, `Gui.destroy_text` and `Gui.set_visible`. No
rectangles or other draw calls. Text is rebuilt only when a line or its position changes, and the gui
is not touched while no game session is active. Press **F11** to hide or show it. If the draw calls
fail, the HUD logs one `hud …` line and detection and logging carry on; five errors in a row disarm
just the HUD.

Position, size and which lines appear are the `CFG.hud` fields near the top of
[detection_alert.lua](mods/vixenhunny/detection_alert.lua).

## Desktop overlay

The mod writes its live eye state to
`%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\DetectionAlertStatus.log` (one throttled line every
0.5 s). [tools/overlay/DetectionAlertOverlay.ps1](tools/overlay/DetectionAlertOverlay.ps1) is a small
always-on-top window (PowerShell + WinForms, no extra install) that tails it:

```
powershell -ExecutionPolicy Bypass -File tools\overlay\DetectionAlertOverlay.ps1
```

Drag with the left mouse button to reposition; right-click to exit. The status line's field order and
names are a contract with this script — changing them breaks it.

## Keys

| key | does |
| --- | --- |
| **F7** | team probe: dumps what this build exposes, reports how far apart the squad is, and tries **one** untried local-player getter. Does nothing until pressed. |
| **F9** / **F10** | mark a fight's start / end in the log, for validating the tiers |
| **F11** | show/hide the HUD |

## Logs and troubleshooting

Every run writes to `%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\`:

- **`DetectionAlert.log`** (truncated at each game start). Per pass it writes a `pass` line (unit,
  animated and per-bucket counts, the resulting flags, and the sampler's CPU time), an `attribution`
  line (each scope's verdict, anchor count, `mode`, `basis`, squad spread), and `changes` /
  `transitions` lines naming the resource hashes that moved. A `heartbeat` lands every 5 s and a
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
- `spread=` staying small: your squad is standing together, so there is little for the split to
  separate. Note also that the client appears to animate only units near you (17,000 units in the
  world, ~400 animated), so enemies fighting a distant teammate may never reach the sampler at all.
- `wwise_calls=0`: no Wwise callback reached the mod — expected on loader v21+.
- `status_bytes=0`, or the status log empty: look for `status file: first write ok`.
- `ERROR #n in <where>`: a handler failed; the message names the file and line.

## Developing

Three tools, none of which need the game running:

```
python tools/analysis/check_lua51.py mods/vixenhunny/detection_alert.lua
python tools/analysis/simulate.py
python tools/analysis/analyze_log.py "%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\DetectionAlert.log"
```

- **`check_lua51.py`** compiles the mod against a real Lua 5.1 runtime, counts the locals the main
  chunk holds open, and loads it under a fake game to catch any global it leaks. Current builds run
  plain Lua 5.1.4: a chunk may hold **at most 200 locals**, and `_G` is shared with every other Bingus
  mod, so both matter. (The pre-revamp file was over that limit, which is why 35 of its declarations
  had their `local` stripped and leaked names like `tick` and `heartbeat` into `_G`.)
- **`simulate.py`** loads the real mod source into `harness.lua`'s fake Helldivers 2 and drives
  scripted squad scenarios — a fight on you, a fight on a squadmate 300 m away, both at once, and a
  build with no local-player getter — asserting on the mod's own `pass` lines.
- **`analyze_log.py`** reads either log format and reports the per-tier distributions, how well each
  metric separates fights from quiet, how activity was attributed, and a replay of the shipped tiers
  against the verdicts a captured session recorded. Keep `SHIPPED` in it in step with `CFG` in the mod.

Both gates must pass before shipping.

## Build

```
python .\tools\build_addon.py --name mods/vixenhunny/detection_alert --entry .\mods\vixenhunny\detection_alert.lua --guid 2b06f66a-6f03-4ca4-8b67-6fc2a153e19a --display-name "Detection Alert" --output .\dist\Detection-Alert.zip
```

Reuse that GUID for every update. Distribute the ZIP alongside a requirement on Bingus Shared Loader
v21+; players enable both in Arsenal/HD2MM (loader placed last in load order) and deploy.
