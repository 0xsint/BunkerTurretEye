"""Lua 5.1 gate for the mod: compiles it, counts the locals the main chunk holds open,
loads it under the fake game in tools/analysis/harness.lua, and reports every global
it leaks into the environment it shares with the other Bingus mods.

Helldivers 2's current builds run plain Lua 5.1.4: a chunk may hold at most 200 locals,
there is no 5.2+ syntax, and _G is shared, so all three of these matter before shipping.

Usage: python tools/analysis/check_lua51.py mods/vixenhunny/detection_alert.lua
"""
import os
import re
import sys

from lupa import lua51

HERE = os.path.dirname(os.path.abspath(__file__))

# Globals the mod is expected to define or replace: `update` is the game's tick hook it
# chains, and the mod table itself is returned rather than assigned.
ALLOWED_GLOBALS = {"update"}


def count_top_level_locals(source):
    """Locals the main chunk holds open, which is what the 200 cap applies to."""
    count = 0
    for line in source.splitlines():
        if re.match(r"^local\s+function\s", line):
            count += 1
            continue
        m = re.match(r"^local\s+([A-Za-z_][\w,\s]*?)\s*(?:=|$)", line)
        if m:
            count += len([x for x in m.group(1).split(",") if x.strip()])
    return count


def main(path):
    with open(path, "r", encoding="utf-8") as fh:
        source = fh.read()
    with open(os.path.join(HERE, "harness.lua"), "r", encoding="utf-8") as fh:
        harness_source = fh.read()

    failures = []
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)

    compile_check = lua.eval("function(src, name) local f, e = loadstring(src, name) return f ~= nil, e end")
    compiled, compile_error = compile_check(source, "@" + path)
    if not compiled:
        print(f"FAIL  Lua 5.1 compile error: {compile_error}")
        return 1
    print("ok    compiles under Lua 5.1")

    used = count_top_level_locals(source)
    headroom = 200 - used
    label = "ok   " if headroom > 20 else ("WARN " if headroom >= 0 else "FAIL ")
    print(f"{label} top-level locals: {used}/200 (headroom {headroom})")
    if headroom < 0:
        failures.append("over the Lua 5.1 200-local limit")

    harness = lua.execute(harness_source)
    world = lua.table_from({"units": lua.table(), "session": "fake-session"})
    loaded = harness.load(source, path, world)
    session, load_error = loaded if isinstance(loaded, tuple) else (loaded, None)
    if session is None:
        print(f"FAIL  mod failed to load under the fake game: {load_error}")
        return 1
    print("ok    loads and runs its startup block under a fake game environment")

    leaked = sorted(
        f"{name} ({kind})"
        for name, kind in session.globals.items()
        if name not in ALLOWED_GLOBALS and not str(name).startswith("_")
    )
    if leaked:
        print(f"FAIL  {len(leaked)} global(s) leak into the shared environment:")
        for item in leaked:
            print(f"        {item}")
        failures.append(f"{len(leaked)} leaked globals")
    else:
        print("ok    defines no globals beyond the update() hook it must chain")

    if failures:
        print("\nFAILED: " + "; ".join(failures))
        return 1
    print("\nPASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
