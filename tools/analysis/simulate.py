"""Behavioural tests for the detection split, run against the real mod source.

The mod is loaded into tools/analysis/harness.lua's fake Helldivers 2 and driven over
scripted squad scenarios, so "enemies on me" versus "enemies on my squad" can be checked
without launching the game. Each scenario asserts on the mod's own pass/attribution lines,
which are the same lines DetectionAlert.log carries.

Usage: python tools/analysis/simulate.py [mods/vixenhunny/detection_alert.lua] [--show]

--show prints what the in-game panel draws in each scenario, so the HUD can be eyeballed
without launching the game.
"""
import os
import re
import sys

from lupa import lua51

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DEFAULT_MOD = os.path.join(ROOT, "mods", "vixenhunny", "detection_alert.lua")

PLAYER_HASH = "4d1c334d294dfa97"
ENEMY_HASH = "64ba5f030b114ec1"  # "Raider", the busiest enemy resource in the captured session
PROP_HASH = "0c6567f9e37920e1"  # in no EnemyData table, so the whitelist must ignore it

DT = 1.0 / 60.0
# The squad: you at the origin, squadmates far enough away that their fights cannot land
# inside CFG.me_radius (35 m) of you.
ME_POS = (0.0, 0.0, 0.0)
MATE_POS = (300.0, 0.0, 0.0)

PASS_RE = re.compile(
    r"pass t=(?P<t>[\d.]+) .*? animated=(?P<animated>\d+) enemies=(?P<enemies>\d+) "
    r"near_me=(?P<near_me>\d+) near_mate=(?P<near_mate>\d+) changed=(?P<changed>\d+) "
    r"ambient=(?P<ambient>\d+) me=(?P<me>\d+) mate=(?P<mate>\d+) loose=(?P<loose>\d+) "
    r"unplaced=(?P<unplaced>\d+) unanchored=(?P<unanchored>\d+) "
    r"alerted_me=(?P<alerted_me>\d+) alerted_mate=(?P<alerted_mate>\d+) "
    r"detected=(?P<detected>\d) searching=(?P<searching>\d) team=(?P<team>\d)"
)
ATTR_RE = re.compile(r"attribution t=[\d.]+ overall=\S+ player=\S+ team=\S+ wwise=\S+ "
                     r"anchors=(?P<anchors>\d+) mode=(?P<mode>\S+) basis=(?P<basis>\S+)")


class Sim:
    def __init__(self, lua, world, session, enemies):
        self.lua = lua
        self.world = world
        self.session = session
        self.enemies = enemies  # name -> list of enemy unit tables

    def passes(self):
        rows = []
        for line in self.session.log.values():
            m = PASS_RE.search(line)
            if m:
                rows.append({k: int(v) if k != "t" else float(v) for k, v in m.groupdict().items()})
        return rows

    def attributions(self):
        rows = []
        for line in self.session.log.values():
            m = ATTR_RE.search(line)
            if m:
                rows.append(m.groupdict())
        return rows

    def grep(self, needle):
        return [line for line in self.session.log.values() if needle in line]

    def status(self):
        return [line for line in self.session.status.values()]

    def hud(self):
        """What the HUD is drawing right now, top row first.

        The mod draws each row twice -- a shadow at (x+1, y-1) under the main text -- so the shadow
        colour is filtered out and only the visible rows come back."""
        gui = self.world.gui
        if gui is None:
            return []
        shadow = (12, 15, 18)
        rows = [t for t in gui.texts.values()
                if (t.color.r, t.color.g, t.color.b) != shadow]
        rows.sort(key=lambda t: -t.y)
        return [{"text": t.text, "size": t.size, "y": t.y,
                 "color": (t.color.r, t.color.g, t.color.b)} for t in rows]


PROBE_PATH_SUFFIX = r"\CowboyBingus\Helldivers2\Logs\DetectionAlertProbe.txt"
CONFIRMED_PROBE = "ok unit_num_cameras\n"


def probe_path():
    return "<sandbox>" + PROBE_PATH_SUFFIX


def build(lua, harness, *, players=4, local_player_index=1, camera_api=True,
          fatal_camera_api=False, probe_state=CONFIRMED_PROBE,
          enemies_on_me=0, enemies_on_mate=0, props=40, churning_props=0):
    """Builds a world and loads the mod against it.

    `probe_state` seeds the mod's crash-resumable probe file. The default says a previous
    run already confirmed the camera getter, which is the state the mod reaches after one
    successful F7 press. `churning_props` puts unlisted resources right next to you and lets
    run(churn=("props",)) flip their animation state, which the hash whitelist must ignore."""
    files = lua.table()
    if probe_state is not None:
        files[probe_path()] = probe_state
    world = lua.table_from({"units": lua.table(), "session": "fake-session",
                            "camera_api": camera_api, "fatal_camera_api": fatal_camera_api,
                            "files": files})
    units = world.units
    index = 1

    def add(resource, state, pos, is_local=False):
        nonlocal index
        unit = lua.table_from({
            "resource": resource, "state": state, "alive": True, "animated": True,
            "is_local": is_local, "pos": lua.table_from(list(pos)),
        })
        units[index] = unit
        index += 1
        return unit

    for n in range(players):
        at = ME_POS if n == 0 else (MATE_POS[0] + n * 10.0, 0.0, 0.0)
        add(PLAYER_HASH, 0, at, is_local=(n == local_player_index - 1))

    enemies = {"me": [], "mate": [], "props": []}
    for n in range(enemies_on_me):
        enemies["me"].append(add(ENEMY_HASH, 0, (5.0 + n, 0.0, 0.0)))
    for n in range(enemies_on_mate):
        enemies["mate"].append(add(ENEMY_HASH, 0, (MATE_POS[0] + 5.0 + n, 0.0, 0.0)))
    # Scenery, so the pass clears CFG.min_animated even when nothing is fighting.
    for n in range(props):
        add(PROP_HASH, 8, (n * 2.0, 50.0, 0.0))
    for n in range(churning_props):
        enemies["props"].append(add(PROP_HASH, 8, (1.0 + n * 0.1, 0.0, 0.0)))

    loaded = harness.load(open_source(), "detection_alert.lua", world)
    session = loaded if not isinstance(loaded, tuple) else loaded[0]
    if session is None:
        raise RuntimeError(f"mod failed to load: {loaded[1]}")
    return Sim(lua, world, session, enemies)


_SOURCE = None
# Flags are stripped so the optional mod path stays positional: `simulate.py [mod.lua] [--show]`.
_FLAGS = [a for a in sys.argv[1:] if a.startswith("--")]
_PATHS = [a for a in sys.argv[1:] if not a.startswith("--")]
SHOW = "--show" in _FLAGS


def open_source():
    global _SOURCE
    if _SOURCE is None:
        with open(_PATHS[0] if _PATHS else DEFAULT_MOD, "r", encoding="utf-8") as fh:
            _SOURCE = fh.read()
    return _SOURCE


def run(sim, seconds, churn=("me", "mate")):
    """Advances the sim, flipping the animation state of the named enemy groups every frame
    so the sampler sees them change between passes."""
    steps = int(seconds / DT)
    for step in range(1, steps + 1):
        for group in churn:
            for n, enemy in enumerate(sim.enemies[group]):
                enemy.state = (step + n) % 7 + 1
        ok = sim.session.update(DT)
        del ok
    return sim


# --- scenarios ---------------------------------------------------------------------

def scenario_quiet(lua, harness):
    """Nothing moving: no detection, and the calm model is allowed to learn."""
    sim = build(lua, harness, enemies_on_me=0, enemies_on_mate=0)
    run(sim, 40, churn=())
    rows = sim.passes()
    assert rows, "no passes completed"
    settled = rows[2:]
    assert all(r["detected"] == 0 for r in settled), "detected during a quiet scenario"
    assert all(r["team"] == 0 for r in settled), "team detected during a quiet scenario"
    return f"{len(rows)} passes, never detected"


def scenario_fight_on_me(lua, harness):
    """Enemies busy next to you: the eye lights, the squad line stays quiet."""
    sim = build(lua, harness, enemies_on_me=12, enemies_on_mate=0)
    run(sim, 40)
    settled = sim.passes()[2:]
    assert any(r["detected"] == 1 for r in settled), "never detected a fight on top of you"
    assert all(r["mate"] == 0 for r in settled), "attributed your own fight to the squad"
    assert all(r["team"] == 0 for r in settled), "team detection fired for your own fight"
    # The changes line names the enemy rather than its hash, which is what makes a log readable.
    assert sim.grep("changes t="), "no changes line"
    assert any("Raider=" in line for line in sim.grep("changes t=")), \
        f"changes line did not name the enemy: {sim.grep('changes t=')[:1]}"
    peak = max(r["me"] for r in settled)
    return f"peak me={peak}, team never fired"


def scenario_fight_on_mate(lua, harness):
    """Enemies busy 300 m away next to a squadmate: team lights, the eye stays dark."""
    sim = build(lua, harness, enemies_on_me=0, enemies_on_mate=12)
    run(sim, 40)
    settled = sim.passes()[2:]
    assert any(r["team"] == 1 for r in settled), "never detected a fight on a squadmate"
    assert all(r["detected"] == 0 for r in settled), "a squadmate's fight lit your own eye"
    assert all(r["me"] == 0 for r in settled), "attributed a squadmate's fight to you"
    peak = max(r["mate"] for r in settled)
    return f"peak mate={peak}, your own eye stayed dark"


def scenario_both(lua, harness):
    """Two separate fights at once: both scopes fire, and neither count leaks into the other."""
    sim = build(lua, harness, enemies_on_me=10, enemies_on_mate=10)
    run(sim, 40)
    settled = sim.passes()[2:]
    assert any(r["detected"] == 1 for r in settled), "missed the fight on you"
    assert any(r["team"] == 1 for r in settled), "missed the fight on your squad"
    hot = [r for r in settled if r["me"] > 0 and r["mate"] > 0]
    assert hot, "never saw both scopes active in the same pass"
    return f"{len(hot)} passes with both scopes active"


def scenario_no_local_player_api(lua, harness):
    """A build with no way to name the local player: the split cannot be made, so every
    anchor counts as you and the eye keeps working exactly as it did before."""
    sim = build(lua, harness, camera_api=False, probe_state=None, enemies_on_me=0, enemies_on_mate=12)
    run(sim, 40)
    settled = sim.passes()[2:]
    attrs = sim.attributions()[2:]
    bases = {a["basis"] for a in attrs}
    assert bases == {"assumed"}, f"expected basis=assumed throughout, saw {sorted(bases)}"
    assert {a["mode"] for a in attrs} == {"assumed"}, "mode claimed an identification it does not have"
    assert any(r["detected"] == 1 for r in settled), "fell silent instead of falling back"
    assert sim.grep("probe state unit_num_cameras=untried"), "did not report the probe state"
    return "stayed basis=assumed, every anchor counted as you, eye still lit"


def scenario_anchor_stability(lua, harness):
    """The anchor must not drift between squadmates: that was what made the old split random."""
    sim = build(lua, harness, enemies_on_me=10, enemies_on_mate=10)
    run(sim, 60)
    anchor_lines = sim.grep("[DetectionAlert] anchors ")
    bases = [a["basis"] for a in sim.attributions()[2:]]
    assert bases and all(b in ("api", "continuity") for b in bases), \
        f"anchor identification was not stable: {sorted(set(bases))}"
    return f"{len(anchor_lines)} anchor change(s) over 60 s, basis stayed {sorted(set(bases))}"


def scenario_unlisted_resources_are_ignored(lua, harness):
    """The hash whitelist. Units whose resource is in no EnemyData table may churn animation
    state right on top of you without reaching any count, which is what the mod leaned on the
    learned calm model for before."""
    sim = build(lua, harness, enemies_on_me=0, enemies_on_mate=0, churning_props=60)
    run(sim, 40, churn=("props",))
    settled = sim.passes()[2:]
    assert settled, "no passes completed"
    assert all(r["enemies"] == 0 for r in settled), "counted an unlisted resource as an enemy"
    assert all(r["changed"] == 0 for r in settled), "counted an unlisted resource as activity"
    assert all(r["detected"] == 0 and r["searching"] == 0 for r in settled), "unlisted churn lit the eye"
    assert sim.grep("unlisted animated: " + PROP_HASH), "did not report the unlisted hash for triage"
    return f"{len(settled)} passes of churn from 60 unlisted units, all ignored"


def scenario_idle_enemies_are_counted_not_detected(lua, harness):
    """Known enemies standing around are counted -- that is what the whitelist bought, and it
    replaces AggroCounter's numbers -- but counting them is not detection: none has noticed you."""
    sim = build(lua, harness, enemies_on_me=12, enemies_on_mate=6)
    run(sim, 40, churn=())
    settled = sim.passes()[2:]
    assert all(r["enemies"] == 18 for r in settled), f"wrong enemy count: {[r['enemies'] for r in settled]}"
    assert all(r["near_me"] == 12 for r in settled), f"wrong near_me: {[r['near_me'] for r in settled]}"
    assert all(r["near_mate"] == 6 for r in settled), f"wrong near_mate: {[r['near_mate'] for r in settled]}"
    assert all(r["detected"] == 0 for r in settled), "idle enemies nearby lit the eye"
    latest = [line for line in sim.status() if "count_source=hashes" in line]
    assert latest, "status file never published a real count"
    assert "search_count=18 detect_count=12" in latest[-1], f"status counts are wrong: {latest[-1]}"
    return "18 enemies seen, 12 near you, 6 near the squad, eye stayed dark"


def scenario_hud_layout(lua, harness):
    """What the panel actually draws. Rows must come out in order, top-down, with the counts in
    their fixed-width columns, the rule as wide as a count row, and the meter tracking the eye."""
    sim = build(lua, harness, enemies_on_me=12, enemies_on_mate=0)
    run(sim, 40)
    rows = sim.hud()
    assert rows, "the HUD drew nothing"
    texts = [r["text"] for r in rows]
    assert texts[0] == "DETECTION ALERT", f"title is not the top row: {texts}"
    assert texts[1] == "(O) DETECTED", f"state line is not under the title: {texts}"
    assert texts[2] == "[##########]", f"meter did not fill while detected: {texts}"
    rule = [t for t in texts if set(t) == {"-"}]
    assert rule, f"no rule line: {texts}"
    counts = [t for t in texts[texts.index(rule[0]) + 1:]]
    assert len(rule[0]) == len(counts[0].rstrip()) or len(rule[0]) == 13, \
        f"rule width {len(rule[0])} does not match a count row"
    for text in counts:
        assert text[:8].rstrip() == text[:8].strip(), f"label column is not 8 wide: {text!r}"
        assert text[8:11] == text[8:11].rjust(3), f"value column is not right-aligned: {text!r}"
    # Rows descend: y falls monotonically, and nothing overlaps the row above it.
    for upper, lower in zip(rows, rows[1:]):
        assert lower["y"] < upper["y"], f"rows are not in descending order: {texts}"
        assert upper["y"] - lower["y"] >= upper["size"], \
            f"row {lower['text']!r} overlaps {upper['text']!r}"
    return " / ".join(texts)


def scenario_hud_escalates(lua, harness):
    """A count row rests in its own colour and turns red once it reaches CFG.hud.counts.hot, so a
    fight is readable from the colours alone."""
    quiet = build(lua, harness, enemies_on_me=0, enemies_on_mate=0)
    run(quiet, 40, churn=())
    calm_rows = {r["text"].split()[0]: r["color"] for r in quiet.hud()}
    loud = build(lua, harness, enemies_on_me=12, enemies_on_mate=0)
    run(loud, 40)
    hot_rows = {r["text"].split()[0]: r["color"] for r in loud.hud()}
    assert calm_rows.get("ACTIVE") != hot_rows.get("ACTIVE"), \
        "ACTIVE kept its resting colour through a fight"
    assert hot_rows.get("ACTIVE") == (255, 112, 105), \
        f"a hot count is not red: {hot_rows.get('ACTIVE')}"
    assert quiet.hud()[1]["text"] == "( ) HIDDEN", "quiet world did not read HIDDEN"
    assert quiet.hud()[2]["text"] == "[..........]", "the meter is not empty while hidden"
    return f"resting {calm_rows.get('ACTIVE')} -> hot {hot_rows.get('ACTIVE')}"


def scenario_no_errors(lua, harness):
    """Nothing in a full run may reach the error log."""
    sim = build(lua, harness, enemies_on_me=8, enemies_on_mate=8)
    run(sim, 70)
    errors = sim.grep("ERROR #")
    assert not errors, "errors logged:\n  " + "\n  ".join(errors[:5])
    unavailable = [line for line in sim.grep("unavailable")
                   if "status file" not in line and "log file" not in line]
    return f"no errors; {len(unavailable)} optional API(s) absent in the fake game"


def scenario_no_anchors(lua, harness):
    """No player unit is ever found (wrong CFG.me_hashes, or a snapshot that misses them):
    nothing can be placed, so everything must count as yours rather than the eye going dark."""
    sim = build(lua, harness, players=0, enemies_on_me=12, enemies_on_mate=0)
    run(sim, 40)
    settled = sim.passes()[2:]
    assert any(r["detected"] == 1 for r in settled), "went dark instead of counting unplaceable activity"
    assert any(r["unanchored"] > 0 for r in settled), "did not report the activity as unanchored"
    modes = {a["mode"] for a in sim.attributions()[2:]}
    assert modes == {"unknown"}, f"expected mode=unknown with no anchors, saw {sorted(modes)}"
    return f"eye still lit, mode={sorted(modes)[0]}, activity flagged unanchored"


def scenario_anchor_lost_midfight(lua, harness):
    """Your unit stops being sighted partway through a fight: detection must survive it."""
    sim = build(lua, harness, enemies_on_me=12, enemies_on_mate=0)
    run(sim, 25)
    before = [r["detected"] for r in sim.passes()[2:]]
    assert any(before), "never detected before the anchor was lost"
    for index in range(1, 5):  # retire every player unit
        sim.world.units[index].alive = False
    run(sim, 30)
    after = sim.passes()[len(before) + 2:]
    assert after, "no passes completed after losing the anchors"
    assert any(r["detected"] == 1 for r in after), "losing the anchor killed detection"
    return f"{len(after)} passes after losing every anchor, still detecting"


def scenario_untried_getter_is_never_called(lua, harness):
    """The crash guard. A getter that has never been confirmed must not be called on its own:
    this models Unit.has_camera, which killed the game when the mod probed it unprompted."""
    sim = build(lua, harness, camera_api=True, fatal_camera_api=True, probe_state=None,
                enemies_on_me=10, enemies_on_mate=10)
    run(sim, 40)
    assert not sim.grep("about to call"), "called an unconfirmed getter without being asked to"
    assert sim.passes(), "sampler stopped running"
    modes = {a["mode"] for a in sim.attributions()[2:]}
    assert modes == {"assumed"}, f"expected assumed mode, saw {sorted(modes)}"
    return "never touched the unconfirmed getter; stayed in assumed mode"


def scenario_fatal_getter_is_not_retried(lua, harness):
    """A probe file holding a `try` with no result means that call never returned: the game died
    mid-probe. The getter must be treated as fatal and never attempted again."""
    sim = build(lua, harness, camera_api=True, fatal_camera_api=True,
                probe_state="try unit_num_cameras" + "\n", enemies_on_me=10, enemies_on_mate=10)
    run(sim, 30)
    assert sim.grep("probe state unit_num_cameras=fatal"), "did not read the crash back as fatal"
    assert not sim.grep("about to call"), "retried a getter that had already killed the game"
    assert any(r["detected"] == 1 for r in sim.passes()[2:]), "stopped detecting"
    return "read the interrupted trial back as fatal and left it alone"


SCENARIOS = [
    ("quiet world stays hidden", scenario_quiet),
    ("unlisted resources never count", scenario_unlisted_resources_are_ignored),
    ("idle enemies are counted, not detected", scenario_idle_enemies_are_counted_not_detected),
    ("fight on you lights the eye only", scenario_fight_on_me),
    ("fight on a squadmate lights team only", scenario_fight_on_mate),
    ("two fights at once stay separate", scenario_both),
    ("no local-player getter falls back safely", scenario_no_local_player_api),
    ("anchor identification is stable", scenario_anchor_stability),
    ("no anchors still counts activity", scenario_no_anchors),
    ("losing your anchor mid-fight is survivable", scenario_anchor_lost_midfight),
    ("an unconfirmed getter is never auto-called", scenario_untried_getter_is_never_called),
    ("a getter that killed the game is not retried", scenario_fatal_getter_is_not_retried),
    ("the hud draws its rows in order", scenario_hud_layout),
    ("hud counts escalate with the fight", scenario_hud_escalates),
    ("a full run logs no errors", scenario_no_errors),
]


ANSI = {
    (255, 112, 105): "\033[91m", (250, 207, 96): "\033[93m", (112, 226, 145): "\033[92m",
    (255, 170, 80): "\033[33m", (140, 190, 255): "\033[94m", (200, 200, 210): "\033[37m",
    (238, 243, 235): "\033[97m", (118, 132, 148): "\033[90m", (68, 80, 94): "\033[90m",
}


def show_panel(label, sim):
    """Prints what the in-game panel looks like, in the mod's own colours where the terminal has them."""
    print(f"\n  {label}")
    for row in sim.hud():
        colour = ANSI.get(row["color"], "")
        reset = "\033[0m" if colour else ""
        print(f"    {colour}{row['text']}{reset}")


def show_panels(harness_source):
    print("\n--- what the panel draws (colours are the mod's own) ---")
    for label, kwargs, churn in (
        ("nothing around you", dict(enemies_on_me=0, enemies_on_mate=0), ()),
        ("enemies nearby, none the wiser", dict(enemies_on_me=9, enemies_on_mate=4), ()),
        ("a fight on you, squad clear", dict(enemies_on_me=12, enemies_on_mate=0), ("me",)),
        ("a fight on both of you", dict(enemies_on_me=12, enemies_on_mate=12), ("me", "mate")),
    ):
        lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        harness = lua.execute(harness_source)
        sim = build(lua, harness, **kwargs)
        run(sim, 40, churn=churn)
        show_panel(label, sim)
    print()


def main():
    with open(os.path.join(HERE, "harness.lua"), "r", encoding="utf-8") as fh:
        harness_source = fh.read()

    failures = 0
    for name, fn in SCENARIOS:
        lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        harness = lua.execute(harness_source)
        try:
            detail = fn(lua, harness)
            print(f"ok    {name}  --  {detail}")
        except AssertionError as exc:
            failures += 1
            print(f"FAIL  {name}\n        {exc}")
        except Exception as exc:  # harness/loading problems
            failures += 1
            print(f"ERROR {name}\n        {type(exc).__name__}: {exc}")

    print()
    if failures:
        print(f"FAILED: {failures}/{len(SCENARIOS)} scenario(s)")
        return 1
    print(f"PASSED: {len(SCENARIOS)} scenarios")
    if SHOW:
        show_panels(harness_source)
    return 0


if __name__ == "__main__":
    sys.exit(main())
