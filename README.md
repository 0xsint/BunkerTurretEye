# Detection Alert (Helldivers 2)

Shows an on-screen "DETECTED" / "HIDDEN" indicator (and drives a turret-eye glow) based on
a combat-activity heuristic. Built for
[Bingus Shared Loader](https://github.com/CowboyBingus/BingusSharedLoader) v15+.

## Current status: probe mode

Current Helldivers 2 Steam builds (25988413 and 26088801 onward) run statically linked Lua 5.1.4
with no LuaJIT, and the loader v21 README says they removed the Wwise flow callbacks. That leaves
neither detection source live:

- **HD2Runtime** needs LuaJIT for its memory reads, and no installed copy loads.
- **Wwise callbacks** (`WwiseFlowCallbacks` / `WwiseVisualization`) are nil.

So the detector runs in **probe mode**. It logs what the runtime exposes and adds no detection
source yet. The `probe` lines in `DetectionAlert.log` (once a game session starts, and at 60 s)
are the output to check.

It also runs a **read-only enemy sampler** in shadow mode. While a game session is active, it walks every
unit in the main world with engine getters only (`World.units`, `Unit.alive`, `Unit.resource_name`,
`Unit.has_animation_state_machine`, `Unit.animation_get_state`). A full pass takes about 5 seconds, spread
over frames, with at most 100 units sampled per frame. Each pass starts from a fresh snapshot of the unit
list. The result goes to the heartbeat as `sample=total=N/units=N/animated=N/changed=N`, taken from the last
completed pass: `total` is every unit in the world, `units` the live ones, `animated` those with an animation
state machine, and `changed` how many of them changed animation state since they were last sampled. Each
completed pass writes a `pass` line with the unit, animated and changed counts and the CPU time the sampler
used (`cost`). A `sample` detail line with wall-clock time and the top animation states and resource ids is
written every 30 s, covering the units seen since the previous detail line. Animation states come back as
integers, and resource ids come back as 64-bit hashes (`IdString64`), not names, so the sampler counts both
as they are. Nothing in the sampler writes game state, and it does not drive the eye yet.

## How detection is derived

There is no direct enemy-AI-perception API exposed to mods, so
[mods/bunkerturreteye/detection_alert.lua](mods/bunkerturreteye/detection_alert.lua) OR's
together two independent signals, either of which can flip the alert on:

1. **Wwise audio-state heuristic** (always active): hooks `WwiseFlowCallbacks` /
   `WwiseVisualization` and matches combat/calm keywords in state, switch and trigger-event
   names.
2. **HD2Runtime combat events** (optional soft dependency — used automatically if
   [HD2Runtime](https://github.com/SkyeShade/HD2Runtime) is installed): subscribes to
   `player_damaged`, `entity_damaged` (local attacker) and `entity_killed` (local killer),
   and decays back to "hidden" after 8 seconds of no combat events. See HD2Runtime's
   [event-scripting.md](https://github.com/SkyeShade/HD2Runtime/blob/master/docs/event-scripting.md)
   for the event API this uses.

Neither source is raw AI detection — it's a practical proxy for "are we currently in a
fight," tunable from the `DetectionAlert.log` output.

## Status-only signals: enemies nearby / enemies searching

Two additional signals are reported alongside the main `is_detected` state, but do **not**
drive the eye color/glow — they only appear in the status log/overlay:

- **`enemies_nearby`** (HD2Runtime only): true while any tracked hostile entity (any
  faction) is within `HD2_ENEMY_NEARBY_RANGE_METERS` (30 m, a tunable guess) of the player.
  Always `false` if HD2Runtime isn't installed.
- **`enemies_searching`**: true on the lighter Wwise "alert"/"aggro"/"detect" keywords, or
  whenever full combat is active (`combat`/`engage`/`hostile`/`battle` keywords, or the
  HD2Runtime combat events) — full combat implies awareness too. Resets alongside
  `is_detected` on calm/stealth keywords or the 8-second combat timeout.

## Near-turret damage flash

HD2Runtime has no pre-fire event (it patches no game code — see
[events.md](https://github.com/SkyeShade/HD2Runtime/blob/master/docs/events.md)) and no
attacker identity for NPC-caused damage, so "an Automaton turret is about to fire" can't be
detected or attributed directly. As the closest honest approximation, the mod flashes the
eye to full red the instant the player takes damage with **no identifiable player
attacker**, while a tracked Automaton turret-type structure is within
`HD2_TURRET_RANGE_METERS` (60 m, a tunable guess, not a published engagement range). This is
reactive, not predictive, and can false-positive on other unattributed damage near a turret.

## Desktop overlay (no in-game HUD API exists)

Neither Bingus Shared Loader nor HD2Runtime expose a safe in-game draw/HUD API (both
deliberately avoid raw rendering hooks, given HD2's GameGuard anti-cheat). Instead, the mod
writes its live eye state to
`%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\DetectionAlertStatus.log` (one throttled line
every 0.1s: `t=`, `detected=`, `intensity=`, `r=`/`g=`/`b=`, `nearby=`, `searching=`).

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
  `update`, `io`). `HD2Runtime:` says whether HD2Runtime loaded, and each `subscribed <event>: state=...`
  line shows whether the game accepted that event. The `WwiseFlowCallbacks: wrapped N function(s)` line
  lists every callback hooked. After that, `call <label> #n` shows the first 40 arguments each Wwise
  callback received, `DETECTED`/`HIDDEN` and `enemies_searching` lines mark state changes, and a
  `heartbeat` line every 5 s gives running counts, the AggroCounter counts when present, and the status
  file's byte count (`status_bytes`).
- **`DetectionAlertStatus.log`**: one line per 0.1 s for the overlay. Capped at 64 KB.
- **`HD2Runtime.log`**: startup and error lines are copied here as well, so they're visible even if
  `DetectionAlert.log` can't be opened.

The `probe` section is short: `_VERSION` and whether `jit`, `ffi` and `bit` exist; the loader's members and
`jit` state; `AggroCounter` and its `counts`; and one `stingray` line with the member and table counts. It no
longer dumps every engine name or global, so the detection lines stand out. The probe body never calls a game or
loader function; its only call is a read-only session check (`Network.game_session`, as P2P-Ping uses).

Marker key: press **F9** when a fight starts and again when it stops. Each press writes one
`MARKER t=… wall=…` line to `DetectionAlert.log`, so you don't have to rely on memory for the fight times.

Where to look when it misbehaves:

- `wwise_calls=0` in the heartbeat: no Wwise callback reached the mod. Compare the member names in the
  `wrapped` line with what the game actually calls.
- `wwise_calls` rising but `wwise_matches=0`: the callbacks fire, but the argument strings contain no
  keyword from the lists at the top of [detection_alert.lua](mods/bunkerturreteye/detection_alert.lua).
  The `call` lines show exactly what's being matched.
- `status_bytes=0` in the heartbeat, or `DetectionAlertStatus.log` empty: look for `status file: first
  write ok`. If that line is present but the file is still empty, the write reached the loader's handle
  but not the disk, and that is worth reporting.
- `subscribe <event> FAILED` or `state=rejected`: HD2Runtime refused that event (see its reason).
- `ERROR #n in <where>`: a handler failed; the message names the file and line.

## Build

```
python .\tools\build_addon.py --name mods/bunkerturreteye/detection_alert --entry .\mods\bunkerturreteye\detection_alert.lua --guid YOUR-STABLE-UUID --display-name "Detection Alert" --output .\dist\Detection-Alert.zip
```

Generate the GUID once with `python -c "import uuid; print(uuid.uuid4())"` and reuse it for
every update. Distribute the resulting ZIP alongside a requirement on Bingus Shared Loader
v15+; players enable both in Arsenal/HD2MM (loader placed last in load order) and deploy.
HD2Runtime is optional — install it too for the combat-event signal, or skip it to run on
the Wwise heuristic alone.

