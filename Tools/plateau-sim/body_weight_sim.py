#!/usr/bin/env python3
"""Body-weight trend tuning simulation for Fernlet's workout planner (round 2, engine lane, G13).

The plateau story may say that body weight has been coming down — to explain a Size lifter's stall
during a deficit, or beside weight management's quiet "strength held" check — but only when the
person already logs their weight, and only when the fall is real rather than water. This simulation
settles how much logged weight the check needs and how firm the fall must be, by scoring the
shipping rule (FernletDomainModel/WorkoutBodyWeightTrend.swift, mirrored line for line below) on
seeded synthetic weigh-ins. The Swift harness (Tests/FernletTests/WorkoutBodyWeightTrendTests.swift)
draws the same histories from the same SplitMix64 stream and pins the counts this script prints.

Synthetic truth: ln(weight) = ln(80 kg) + r * t, r a weekly change of 0, -0.25 %, -0.5 %, -1 % or
+0.25 %, from day 0. Day-to-day water noise sigma in {0.6 %, 0.8 %, 1.0 %}, and in half the histories
AR(1) with rho = 0.5 (a salty dinner shows for two or three mornings). Weigh-ins 7, 3 or 2 days a
week, 10 % of them skipped. The check is read on every weigh-in day from day 14.

Scores: a steady history that is ever called falling over 8 weeks is a false call; a falling one is
found on the first day it is called, and its delay is that day.

The sweep that chose the rule (all on these histories): a fall of 0.25 %/week at 1.645 SE, read on
one weigh-in, called 48 % of steady weights falling within 8 weeks — day-to-day water swamps two
weeks of a small trend, and reading it on every weigh-in multiplies the chances. Raising the fall to
0.5 %/week and asking for it on three weigh-ins in a row brought that to about 3 %, while still
finding most 0.5 %/week deficits within six weeks and nearly every 1 %/week one within three.

| History (count)               | Called falling | Median day |
|-------------------------------|----------------|------------|
| steady, 8 weeks (400)         | 13 (3.25 %)    | -          |
| gaining 0.25 %/wk, 8 wk (200) | 1 (0.5 %)      | -          |
| slow -0.25 %/wk, 6 wk (200)   | 45 (22.5 %)    | 23         |
| deficit -0.5 %/wk, 6 wk (200) | 136 (68 %)     | 25         |
| fast -1 %/wk, 6 wk (200)      | 192 (96 %)     | 21         |

Deterministic and bounded: every history comes from a seeded stream, every loop is bounded.

Run: python3 Tools/plateau-sim/body_weight_sim.py
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from plateau_sim import SplitMix64  # noqa: E402  (the shared stream)

# --- The shipping rule's constants (WorkoutBodyWeightTrend) ------------------------------------

WINDOW_DAYS = 28
MINIMUM_SPAN_DAYS = 14
MINIMUM_SAMPLES = 6
FALLING_Z = 1.645
MINIMUM_WEEKLY_DROP = 0.005
PERSISTENCE = 3

# --- The synthetic weigh-ins -------------------------------------------------------------------

FREQUENCIES = (7, 3, 2)
DAY_PATTERNS = {7: (0, 1, 2, 3, 4, 5, 6), 3: (0, 2, 4), 2: (0, 3)}
SIGMAS = (0.006, 0.008, 0.010)
CORRELATED_SHARE = 0.5
RHO = 0.5
SKIP_RATE = 0.1
START_KG = 80.0
# name: (seed index, weekly change)
SCENARIOS = {"steady": (0, 0.0), "slow": (1, -0.0025), "deficit": (2, -0.005), "fast": (3, -0.01),
             "gaining": (4, 0.0025)}


def make_weigh_ins(index, days, scenario):
    """One history's weigh-ins as (day, kg), oldest first, drawn as the Swift harness draws them."""
    seed_index, weekly = SCENARIOS[scenario]
    rng = SplitMix64(0xB0D70000 + index * 7919 + seed_index * 104729)
    frequency = FREQUENCIES[int(rng.unit() * 3) % 3]
    sigma = SIGMAS[int(rng.unit() * 3) % 3]
    rho = RHO if rng.unit() < CORRELATED_SHARE else 0.0
    innovation = sigma * math.sqrt(1.0 - rho * rho)
    noise = rng.gaussian() * sigma
    daily = math.log(1.0 + weekly) / 7.0
    out = []
    for day in range(days):
        if day > 0:
            noise = rho * noise + innovation * rng.gaussian()
        skip = rng.unit() < SKIP_RATE
        if day % 7 not in DAY_PATTERNS[frequency] or skip:
            continue
        out.append((day, START_KG * math.exp(daily * day + noise)))
    return out


# --- The shipping rule, line for line -----------------------------------------------------------

def weekly_change(weigh_ins, today):
    """(slope per week, its standard error) of ln(kg) over the window ending today, or None without
    enough weigh-ins."""
    xs, ys = [], []
    for day, kg in weigh_ins:
        age = today - day
        if age < 0 or age >= WINDOW_DAYS or not (kg > 0):
            continue
        xs.append(float(-age))
        ys.append(math.log(kg))
    n = len(xs)
    if n < MINIMUM_SAMPLES or max(xs) - min(xs) < MINIMUM_SPAN_DAYS:
        return None
    mean_x = sum(xs) / n
    mean_y = sum(ys) / n
    sxx = 0.0
    sxy = 0.0
    for x, y in zip(xs, ys):
        sxx += (x - mean_x) * (x - mean_x)
        sxy += (x - mean_x) * (y - mean_y)
    slope = sxy / sxx
    residual = 0.0
    for x, y in zip(xs, ys):
        r = y - mean_y - slope * (x - mean_x)
        residual += r * r
    error = math.sqrt(residual / (n - 2) / sxx)
    return slope * 7.0, error * 7.0


def falls_at(weigh_ins, end):
    """The fall test on the window ending at `end`."""
    change = weekly_change(weigh_ins, end)
    if change is None:
        return False
    slope, error = change
    return slope <= -MINIMUM_WEEKLY_DROP and slope + FALLING_Z * error < 0


def is_falling(weigh_ins, today):
    """Falling: the test passes on each of the last PERSISTENCE weigh-ins, each read on its own day."""
    days = sorted({day for day, _ in weigh_ins if day <= today})
    if len(days) < PERSISTENCE:
        return False
    return all(falls_at([w for w in weigh_ins if w[0] <= end], end) for end in days[-PERSISTENCE:])


# --- Scoring -----------------------------------------------------------------------------------

def first_call(weigh_ins):
    """The first weigh-in day, from day 14, on which the check calls the weight falling; None if never."""
    seen = []
    for day, kg in weigh_ins:
        seen.append((day, kg))
        if day >= MINIMUM_SPAN_DAYS and is_falling(seen, day):
            return day
    return None


def tally(count, days, scenario):
    calls = [first_call(make_weigh_ins(i, days, scenario)) for i in range(count)]
    found = sorted(c for c in calls if c is not None)
    median = found[len(found) // 2] if found else None
    if found and len(found) % 2 == 0:
        median = (found[len(found) // 2 - 1] + found[len(found) // 2]) / 2
    return len(found), median


def main():
    print(f"rule: window {WINDOW_DAYS} d, span >= {MINIMUM_SPAN_DAYS} d, >= {MINIMUM_SAMPLES} weigh-ins, "
          f"slope <= -{MINIMUM_WEEKLY_DROP * 100:.2f} %/wk and slope + {FALLING_Z} SE < 0 "
          f"on each of the last {PERSISTENCE} weigh-ins")
    for name, weeks, count in (("steady", 8, 400), ("gaining", 8, 200), ("slow", 6, 200),
                               ("deficit", 6, 200), ("fast", 6, 200)):
        found, median = tally(count, weeks * 7, name)
        print(f"  {name:8s} {weeks} wk ({count}): called falling {found} ({100 * found / count:.1f} %), "
              f"median day {median}")


if __name__ == "__main__":
    main()
