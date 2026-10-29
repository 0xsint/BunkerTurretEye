"""Mine DetectionAlert.log so threshold changes rest on a captured session rather than a guess.

Reports the per-pass distributions behind each detection tier, how well each metric separates
fights from quiet, how activity was attributed to you versus your squad, and a replay of the
shipped tier machine against the verdicts the session actually recorded.

Usage: python tools/analysis/analyze_log.py <path to DetectionAlert.log>
"""
import re
import sys
from collections import Counter

# The pre-revamp pass line: one global "active" figure, with no player/squad split.
PASS_V1_RE = re.compile(
    r"pass t=(?P<t>[\d.]+) wall=\S+ units=(?P<units>\d+) animated=(?P<animated>\d+) "
    r"changed=(?P<changed>\d+) active=(?P<active>-?\d+) alerted=(?P<alerted>\d+) team=(?P<team>\d+) "
    r"far=(?P<loose>\d+) detected=(?P<detected>\d+) searching=(?P<searching>\d+) cost=(?P<cost>[\d.]+)ms"
)
# The current pass line, with activity attributed to you or to a squadmate.
PASS_V2_RE = re.compile(
    r"pass t=(?P<t>[\d.]+) wall=\S+ units=(?P<units>\d+) animated=(?P<animated>\d+) "
    r"changed=(?P<changed>\d+) ambient=(?P<ambient>\d+) me=(?P<active>\d+) mate=(?P<mate>\d+) "
    r"loose=(?P<loose>\d+) unplaced=(?P<unplaced>\d+) unanchored=(?P<unanchored>\d+) "
    r"alerted_me=(?P<alerted>\d+) "
    r"alerted_mate=(?P<alerted_mate>\d+) detected=(?P<detected>\d+) searching=(?P<searching>\d+) "
    r"team=(?P<team>\d+) cost=(?P<cost>[\d.]+)ms"
)
ATTR_V1_RE = re.compile(r"attribution t=[\d.]+ overall=\S+ .*?basis=(?P<basis>\S+) "
                        r"player_candidates=(?P<anchors>-?\d+)")
ATTR_V2_RE = re.compile(r"attribution t=[\d.]+ overall=\S+ player=(?P<player>\S+) team=(?P<team>\S+) "
                        r"wwise=\S+ anchors=(?P<anchors>\d+) mode=(?P<mode>\S+) basis=(?P<basis>\S+)")
CHANGES_RE = re.compile(r"changes t=[\d.]+ (.*)$")
MARKER_RE = re.compile(r"(START|END) MARKER t=(?P<t>[\d.]+)")

# Must mirror CFG.detect / CFG.alert_detect / CFG.search in the mod.
SHIPPED = {
    "detect": {"enter": 6, "pair": 3, "exit_at": 1, "exit_passes": 2},
    "alert_detect": {"enter": 8, "exit_at": 3},
    "search": {"enter": 3, "exit_at": 1, "exit_passes": 2},
}
# What the mod used before the revamp: higher entry, and `alerted` ignored entirely.
PREVIOUS = {
    "detect": {"enter": 8, "pair": 3, "exit_at": 2, "exit_passes": 2},
    "alert_detect": {"enter": 10 ** 9, "exit_at": 10 ** 9},
    "search": {"enter": 5, "exit_at": 2, "exit_passes": 2},
}


def parse(path):
    passes, attrs, markers = [], [], []
    change_hashes, change_hash_passes = Counter(), Counter()
    change_lines = 0
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = PASS_V2_RE.search(line) or PASS_V1_RE.search(line)
            if m:
                row = {k: (float(v) if "." in v else int(v)) for k, v in m.groupdict().items()}
                row.setdefault("mate", 0)
                row.setdefault("alerted_mate", 0)
                passes.append(row)
                continue
            m = ATTR_V2_RE.search(line) or ATTR_V1_RE.search(line)
            if m:
                attrs.append(m.groupdict())
                continue
            m = MARKER_RE.search(line)
            if m:
                markers.append((m.group(1), float(m.group("t"))))
                continue
            m = CHANGES_RE.search(line)
            if m:
                change_lines += 1
                for item in m.group(1).split():
                    key, _, count = item.rpartition("=")
                    if count.isdigit():
                        change_hashes[key] += int(count)
                        change_hash_passes[key] += 1
    return passes, attrs, markers, change_hashes, change_hash_passes, change_lines


def stats(rows, key):
    vals = sorted(r.get(key, 0) for r in rows)
    if not vals:
        return "n/a"
    n = len(vals)
    return (f"min={vals[0]} p25={vals[n // 4]} med={vals[n // 2]} p75={vals[3 * n // 4]} "
            f"p90={vals[min(n - 1, 9 * n // 10)]} max={vals[-1]}")


def separability(mission, det, hid):
    """Threshold that best splits fights from quiet, by Youden's J (recall minus false alarms)."""
    print("\nseparability (threshold maximising detected-recall minus hidden-false-positives):")
    for key in ("active", "alerted", "changed"):
        hi = max((p.get(key, 0) for p in mission), default=0)
        best = None
        for thr in range(0, int(hi) + 1):
            tpr = sum(1 for p in det if p.get(key, 0) >= thr) / len(det) if det else 0
            fpr = sum(1 for p in hid if p.get(key, 0) >= thr) / len(hid) if hid else 0
            if best is None or tpr - fpr > best[0]:
                best = (tpr - fpr, thr, tpr, fpr)
        if best:
            label = {"active": "me/active", "alerted": "alerted_me", "changed": "changed"}[key]
            print(f"  {label:11s} best_threshold={best[1]:3d}  recall={best[2]:.2f}  "
                  f"false_alarm={best[3]:.2f}  J={best[0]:.2f}")


def replay(rows, cfg):
    """Mirrors score_scope() in the mod, so a tier change can be judged before it ships."""
    detect, alert_detect, search = cfg["detect"], cfg["alert_detect"], cfg["search"]
    out = []
    detected = searching = False
    low_detect = low_search = last_changed = 0
    for row in rows:
        changed, alerted = row.get("active", 0), row.get("alerted", 0)
        if not detected:
            if (changed >= detect["enter"] or alerted >= alert_detect["enter"]
                    or (changed >= detect["pair"] and last_changed >= detect["pair"])):
                detected, low_detect = True, 0
        elif changed <= detect["exit_at"] and alerted <= alert_detect["exit_at"]:
            low_detect += 1
            if low_detect >= detect["exit_passes"]:
                detected = False
        else:
            low_detect = 0

        if detected:
            searching, low_search = True, 0
        elif not searching:
            if changed >= search["enter"]:
                searching, low_search = True, 0
        elif changed <= search["exit_at"]:
            low_search += 1
            if low_search >= search["exit_passes"]:
                searching = False
        else:
            low_search = 0

        last_changed = changed
        out.append(detected)
    return out


def flips(series):
    return sum(1 for a, b in zip(series, series[1:]) if a != b)


def run_replay(mission):
    logged = [p["detected"] == 1 for p in mission]
    print(f"\nreplay over {len(mission)} mission passes "
          f"({sum(logged)} recorded detected, {flips(logged)} transitions):")
    for label, cfg in (("previous tiers", PREVIOUS), ("shipped tiers", SHIPPED)):
        det = replay(mission, cfg)
        agree = sum(1 for a, b in zip(det, logged) if a == b) / len(logged)
        print(f"  {label:15s} detected={sum(det):4d} ({sum(det) / len(det):5.1%})  "
              f"transitions={flips(det):3d}  agrees with the recorded verdict {agree:5.1%}")
    print("  (a log written before the revamp has no me/mate split, so `me` there is still"
          "\n   whole-world activity; agreement is a regression check, not ground truth)")


def main(path):
    passes, attrs, markers, hashes, hash_passes, change_lines = parse(path)
    print(f"passes={len(passes)}  attributions={len(attrs)}  change-lines={change_lines}  "
          f"fight-markers={len(markers)}")
    if not markers:
        print("  no F9/F10 markers in this log: press F9 when a fight starts and F10 when it ends to"
              "\n  record ground truth, which is what turns the numbers below into a real validation")

    mission = [p for p in passes if p["animated"] >= 20]
    det = [p for p in mission if p["detected"] == 1]
    hid = [p for p in mission if p["detected"] == 0]
    print(f"\nmission passes (animated>=20): {len(mission)}  detected={len(det)}  hidden={len(hid)}")
    for key in ("active", "alerted", "mate", "alerted_mate", "changed", "loose", "animated"):
        label = {"active": "me", "alerted": "alerted_me"}.get(key, key)
        print(f"  {label:12s} detected: {stats(det, key)}")
        print(f"  {label:12s} hidden  : {stats(hid, key)}")

    if det and hid:
        separability(mission, det, hid)
    if mission:
        run_replay(mission)

    print("\nattribution:")
    for field in ("basis", "mode"):
        values = Counter(a[field] for a in attrs if field in a)
        if values:
            print(f"  {field}: " + "  ".join(f"{k}={v}" for k, v in values.most_common()))
    anchors = Counter(a["anchors"] for a in attrs if "anchors" in a)
    if anchors:
        print("  anchors: " + "  ".join(f"{k}->{v}" for k, v in sorted(anchors.items(), key=lambda kv: int(kv[0]))))
    team_on = sum(1 for p in mission if p["team"] == 1)
    mate_seen = sum(1 for p in mission if p["mate"] > 0)
    print(f"  squad scope: team detected in {team_on}/{len(mission)} mission passes, "
          f"mate activity seen in {mate_seen}")

    print("\ntop change hashes (total changes, passes seen, share of change-lines, avg per pass):")
    for key, total in hashes.most_common(20):
        seen = hash_passes[key]
        share = seen / change_lines if change_lines else 0
        print(f"  {key:18s} total={total:6d} passes={seen:5d} ({share:5.1%}) avg={total / seen:.2f}")


if __name__ == "__main__":
    main(sys.argv[1])
