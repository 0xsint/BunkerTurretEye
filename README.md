# Detection Alert (Helldivers 2)

Shows an on-screen "DETECTED" / "HIDDEN" indicator based on enemy AI awareness of you.
Built for [Bingus Shared Loader](https://github.com/CowboyBingus/BingusSharedLoader) v15+.

## Status: gameplay hook needs confirmation

The loader only provides shared startup + discovery for a Lua entry script — it does not
expose a detection API itself. Two spots in
[mods/bunkerturreteye/detection_alert.lua](mods/bunkerturreteye/detection_alert.lua) are
placeholders pending the real Helldivers 2 Lua names:

1. `poll_detected()` — the actual extension/manager that exposes enemy-AI awareness of the
   local player.
2. The per-frame hook and UI draw call — the loader gives you a boot-time entry point only,
   so a real `update` hook and draw call must be wired in (see the `TODO` comments).

## Build

From a checkout of BingusSharedLoader:

```
python -B scripts/build_addon.py --name mods/bunkerturreteye/detection_alert --entry path/to/detection_alert.lua --guid YOUR-STABLE-UUID --display-name "Detection Alert" --output Detection-Alert.zip
```

Generate the GUID once with `python -c "import uuid; print(uuid.uuid4())"` and reuse it for
every update. Distribute the resulting ZIP alongside a requirement on Bingus Shared Loader
v15+; players enable both in Arsenal/HD2MM (loader placed last in load order) and deploy.
