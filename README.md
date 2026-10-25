# Detection Alert (Helldivers 2)

Shows an on-screen "DETECTED" / "HIDDEN" indicator (and drives a turret-eye glow) based on
a combat-activity heuristic. Built for
[Bingus Shared Loader](https://github.com/CowboyBingus/BingusSharedLoader) v15+.

## Current status: sampler detection

Current Helldivers 2 Steam builds (25988413 and 26088801 onward) run statically linked Lua 5.1.4
with no LuaJIT, and the loader v21 README says they removed the Wwise flow callbacks. That leaves
one live source:

- **Wwise callbacks** (`WwiseFlowCallbacks` / `WwiseVisualization`) are nil, so that heuristic is idle.
- **Enemy sampler** (below) is the live source: it drives `is_detected` / `enemies_searching`, the status
  file and the on-screen indicator. It measures how much enemy animation is changing, not what the AI
  perceives, and its thresholds (the `DETECT_*` / `SEARCH_*` constants at the top of the sampler section)
  are starting values that have not been validated against labeled calm and fight periods.

The `probe` lines in `DetectionAlert.log` (once a game session starts, and at 60 s) show what the runtime
exposes.

The **read-only enemy sampler** runs while a game session is active. It walks every
unit in the main world with engine getters only (`World.units`, `Unit.alive`, `Unit.resource_name`,
`Unit.has_animation_state_machine`, `Unit.animation_get_state`). A full pass takes about 5 seconds, spread
over frames, with at most 100 units sampled per frame. Each pass starts from a fresh snapshot of the unit
list. The result goes to the heartbeat as `sample=total=N/units=N/animated=N/changed=N`, taken from the last
completed pass: `total` is every unit in the world, `units` the live ones, `animated` those with an animation
state machine, and `changed` how many of them changed animation state since they were last sampled. Each
completed pass writes a `pass` line with the unit, animated, changed and `active` counts, the resulting
`detected` / `searching` flags, and the CPU time the sampler used (`cost`). A `sample` detail line with
wall-clock time and the top animation states and resource ids is written every 30 s, covering the units seen
since the previous detail line. Animation states come back as integers, and resource ids come back as 64-bit
hashes (`IdString64`), not names, so the sampler counts both as they are. When a pass has changes, a
`changes t=…` line lists each changed resource hash with its count (`unkeyed` for changes whose id could not
be read). Nothing in the sampler writes game state.

## How detection is derived

There is no direct enemy-AI-perception API exposed to mods, so
[mods/vixenhunny/detection_alert.lua](mods/vixenhunny/detection_alert.lua) drives the
alert from the Wwise audio-state heuristic (always active): it hooks `WwiseFlowCallbacks` /
`WwiseVisualization` and matches combat/calm keywords in state, switch and trigger-event names.

It's a practical proxy for "are we currently in a fight," not raw AI detection, and it's tunable
from the `DetectionAlert.log` output.

## On-screen indicator (HUD)

While a game session is active, the mod draws a small indicator on the left of the screen, in the same
column as P2P-Ping's list and just above it:

```
(O) DETECTED     red     the sampler (or Wwise) says enemies are engaged
(o) SEARCHING    yellow  lower activity tier
( ) HIDDEN       green   nothing detected
ACTIVE 12                the sampler's last "active" value, for tuning
```

It is drawn the way P2P-Ping draws, with only the calls that mod runs on this build: a screen gui on the main
world, then `Gui.resolution`, `Gui.text`, `Gui.destroy_text` and `Gui.set_visible`. No rectangles or other draw
calls are used. Text is rebuilt only when the state, the lines or the screen position change, and the gui is
not touched while no game session is active. Press **F11** to hide or show it. If the draw calls are missing
or fail, the HUD logs one `hud …` line and detection and logging carry on; five errors in a row disarm just
the HUD.

Its position, size, key and the `ACTIVE` line are the `HUD_*` constants at the top of the HUD section in
[detection_alert.lua](mods/vixenhunny/detection_alert.lua). The `hud …` lines in `DetectionAlert.log` report
whether the gui and text calls worked on your build.

## Status-only signal: enemies searching

`enemies_searching` is reported alongside the main `is_detected` state, but does **not** drive the
eye color/glow — it appears in the status log/overlay and as the yellow SEARCHING line of the HUD. It is true on the lighter Wwise
"alert"/"aggro"/"detect" keywords, or whenever a Wwise combat keyword (`combat`/`engage`/`hostile`/`battle`)
is active, since full combat implies awareness too, or while the sampler's lower activity tier is on. It resets alongside `is_detected` on calm/stealth keywords.

## Desktop overlay

Separately from the in-game indicator, the mod writes its live eye state to
`%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\DetectionAlertStatus.log` (one throttled line
every 0.1s: `t=`, `detected=`, `intensity=`, `r=`/`g=`/`b=`, `searching=`).

[tools/overlay/DetectionAlertOverlay.ps1](tools/overlay/DetectionAlertOverlay.ps1) is a
small always-on-top desktop window (PowerShell + WinForms, no extra install) that tails
that file and shows the turret eye glow outside the game window:

```
powershell -ExecutionPolicy Bypass -File tools\overlay\DetectionAlertOverlay.ps1
```

Drag with the left mouse button to reposition; right-click to exit.

## Logs and troubleshooting

Every run writes to `%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\`:

- **`DetectionAlert.log`** (truncated at each game start): start here. The `env:` line lists the
  globals the mod depends on (`CowboyBingusModLoader`, `WwiseFlowCallbacks`, `WwiseVisualization`,
  `update`, `io`). The `WwiseFlowCallbacks: wrapped N function(s)` line
  lists every callback hooked. After that, `call <label> #n` shows the first 40 arguments each Wwise
  callback received, `DETECTED`/`HIDDEN` and `enemies_searching` lines mark state changes, and a
  `heartbeat` line every 5 s gives running counts, the AggroCounter counts when present, and the status
  file's byte count (`status_bytes`).
- **`DetectionAlertStatus.log`**: one line per 0.1 s for the overlay. Capped at 64 KB.

The `probe` section is short: `_VERSION` and whether `jit`, `ffi` and `bit` exist; the loader's members and
`jit` state; `AggroCounter` and its `counts`; and one `stingray` line with the member and table counts. It no
longer dumps every engine name or global, so the detection lines stand out. The probe body never calls a game or
loader function; its only call is a read-only session check (`Network.game_session`, as P2P-Ping uses).

Marker keys: press **F9** when a fight starts and **F10** when it stops. They are two separate keys, so one
missed press can't flip every later one. F9 writes a `START MARKER t=… wall=…` line to `DetectionAlert.log` and
F10 an `END MARKER` line, each carrying the detector's state at that moment, so you don't have to rely on
memory for the fight times.

Where to look when it misbehaves:

- `wwise_calls=0` in the heartbeat: no Wwise callback reached the mod. Compare the member names in the
  `wrapped` line with what the game actually calls.
- `wwise_calls` rising but `wwise_matches=0`: the callbacks fire, but the argument strings contain no
  keyword from the lists at the top of [detection_alert.lua](mods/vixenhunny/detection_alert.lua).
  The `call` lines show exactly what's being matched.
- `status_bytes=0` in the heartbeat, or `DetectionAlertStatus.log` empty: look for `status file: first
  write ok`. If that line is present but the file is still empty, the write reached the loader's handle
  but not the disk, and that is worth reporting.
- `ERROR #n in <where>`: a handler failed; the message names the file and line.

## Build

```
python .\tools\build_addon.py --name mods/vixenhunny/detection_alert --entry .\mods\vixenhunny\detection_alert.lua --guid YOUR-STABLE-UUID --display-name "Detection Alert" --output .\dist\Detection-Alert.zip
```

Generate the GUID once with `python -c "import uuid; print(uuid.uuid4())"` and reuse it for
every update. Distribute the resulting ZIP alongside a requirement on Bingus Shared Loader
v15+; players enable both in Arsenal/HD2MM (loader placed last in load order) and deploy.

