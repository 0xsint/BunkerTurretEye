"""Regenerates the ENEMY table in mods/vixenhunny/detection_alert.lua.

The mod counts a world unit as an enemy only when its resource hash is in that table, so the
table is the mod's whole definition of "enemy". It is derived from the EnemyData project
(https://github.com/.../EnemyData, or a local checkout):

    data/game_names.lua        which in-game unit names are enemies
    dist/enemy_intel.lua       the assembled hash -> unit-name table

Only hashes whose name appears in game_names.lua survive the crossing, so hellpods, sentries,
exosuits, Guard Dogs, SEAF troopers, civilians, structures and props are left out.

    python tools/gen_enemy_hashes.py --enemy-data "C:\\path\\to\\EnemyData"          # rewrite in place
    python tools/gen_enemy_hashes.py --enemy-data "..." --print                      # just show the block

The hash -> name table in EnemyData is generated from the Enemy HP mod's table and is that
author's work. Ask them before publishing a build that embeds it.
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = os.path.join(ROOT, "mods", "vixenhunny", "detection_alert.lua")

BEGIN = "\t-- BEGIN generated enemy hashes"
END = "\t-- END generated enemy hashes"

HASH_RE = re.compile(r'\["([0-9a-fA-F]{16})"\]\s*=\s*"([^"]*)"')
NAME_RE = re.compile(r'\s*\["([^"]*)"\]\s*=')
FACTION_RE = re.compile(r"\s*-+\s*([A-Z]+)\s*$")


def read(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def hash_names(enemy_data):
    """hash -> in-game unit name, from EnemyData's assembled mod."""
    source = read(os.path.join(enemy_data, "dist", "enemy_intel.lua"))
    start = source.index('BUNDLE["generated.hash_names"]')
    block = source[start:source.index("\nend\n", start)]
    return dict(HASH_RE.findall(block))


def enemy_names(enemy_data):
    """in-game unit name -> faction, from EnemyData's hand-written map."""
    names, faction = {}, None
    for line in read(os.path.join(enemy_data, "data", "game_names.lua")).splitlines():
        heading = FACTION_RE.match(line)
        if heading:
            faction = heading.group(1).lower()
        entry = NAME_RE.match(line)
        if entry:
            names[entry.group(1)] = faction
    return names


def build_block(enemy_data):
    names = enemy_names(enemy_data)
    found = {h.lower(): (n, names[n]) for h, n in hash_names(enemy_data).items() if n in names}
    missing = sorted(set(names) - set(hash_names(enemy_data).values()))
    lines = [BEGIN, "\t-- %d enemy resources: %s" % (
        len(found),
        ", ".join("%s %d" % (f, sum(1 for v in found.values() if v[1] == f))
                  for f in sorted({v[1] for v in found.values()})))]
    for h, (name, faction) in sorted(found.items(), key=lambda kv: (kv[1][1], kv[1][0], kv[0])):
        lines.append('\t["%s"] = "%s", -- %s' % (h, name, faction))
    lines.append(END)
    return "\n".join(lines), len(found), missing


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--enemy-data", required=True, help="path to an EnemyData checkout")
    parser.add_argument("--mod", default=MOD, help="the mod file to rewrite")
    parser.add_argument("--print", dest="show", action="store_true", help="print the block, do not rewrite")
    args = parser.parse_args()

    block, count, missing = build_block(args.enemy_data)
    if missing:
        print("warning: %d enemy name(s) in game_names.lua have no hash: %s"
              % (len(missing), ", ".join(missing)), file=sys.stderr)
    if args.show:
        print(block)
        return 0

    source = read(args.mod)
    start, stop = source.index(BEGIN), source.index(END) + len(END)
    with open(args.mod, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(source[:start] + block + source[stop:])
    print("wrote %d enemy hashes into %s" % (count, args.mod))
    return 0


if __name__ == "__main__":
    sys.exit(main())
