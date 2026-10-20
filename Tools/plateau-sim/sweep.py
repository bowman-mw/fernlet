#!/usr/bin/env python3
"""Threshold sweep over plateau_sim's detector. Each line: the settings tried, then the false-plateau
rate (new, old) over 12 weeks with an explicit and an inferred training age, the false-dipping rate,
and the share of true stalls the new rule found within 18 weeks with its median delay.

Run: python3 Tools/plateau-sim/sweep.py [histories]
"""

import sys

import plateau_sim as sim


def measure(count):
    out = {}
    for mode in ("explicit", "inferred"):
        rows = sim.run(count, 12, False, mode)
        old, new, dip = sim.totals(rows)
        older = sim.totals(sim.run(count // 4, 12, False, mode, cohort="older"))[1]
        stall_rows = [x for r in sim.run(count // 2, 24, True, mode).values() for x in r]
        found = sorted(x[4] for x in stall_rows if x[4] is not None and x[4] <= 18)
        beginner = [x for (c, _), r in sim.run(count // 2, 24, True, mode, cohort="beginner").items() for x in r]
        b_found = sorted(x[4] for x in beginner if x[4] is not None and x[4] <= 18)
        out[mode] = (new, old, dip, older, 100.0 * len(found) / max(1, len(stall_rows)), sim.median(found),
                     100.0 * len(b_found) / max(1, len(beginner)), sim.median(b_found))
    return out


def report(label, count):
    out = measure(count)
    for mode, v in out.items():
        print("%-40s %-8s false new %5.1f%% old %5.1f%% dip %4.1f%% older %5.1f%% | stall found %5.1f%% med %.1f wk"
              " | beginner found %5.1f%% med %.1f wk" % ((label, mode) + v))
    sys.stdout.flush()


B8I10 = {"beginner": {"stall_weeks": 8.0}, "intermediate": {"stall_weeks": 10.0}}
B6I10 = {"beginner": {"stall_weeks": 6.0}, "intermediate": {"stall_weeks": 10.0}}
B6I12 = {"beginner": {"stall_weeks": 6.0}, "intermediate": {"stall_weeks": 12.0}}
CANDIDATES = [
    ("baseline", {}, {}),
    ("p3 ze0.84 b8i10", {"stall_persist": 3, "z_expected": 0.8416}, B8I10),
    ("p3 ze1.28 b8i10", {"stall_persist": 3, "z_expected": 1.2816}, B8I10),
    ("p3 ze1.64 b8i10", {"stall_persist": 3, "z_expected": 1.645}, B8I10),
    ("p3 ze1.28 b6i10", {"stall_persist": 3, "z_expected": 1.2816}, B6I10),
    ("p3 ze1.28 b6i12", {"stall_persist": 3, "z_expected": 1.2816}, B6I12),
    ("p2 ze1.64 b6i10", {"stall_persist": 2, "z_expected": 1.645}, B6I10),
    ("p3 ze1.28 b6i10 own6", {"stall_persist": 3, "z_expected": 1.2816, "own_weeks": 6.0}, B6I10),
]


def main(argv):
    count = int(argv[1]) if len(argv) > 1 else 400
    pick = argv[2:] or None
    base_params = dict(sim.PARAMS)
    base_tiers = {k: dict(v) for k, v in sim.TIERS.items()}
    for label, params, tiers in CANDIDATES:
        if pick and label not in pick:
            continue
        sim.PARAMS.clear()
        sim.PARAMS.update(base_params, **params)
        for name, values in base_tiers.items():
            sim.TIERS[name] = dict(values, **tiers.get(name, {}))
        report(label, count)


if __name__ == "__main__":
    main(sys.argv)
