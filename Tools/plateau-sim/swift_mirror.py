#!/usr/bin/env python3
"""A line-for-line Python mirror of the SHIPPING plateau detector, so the numbers the Swift
simulation harness pins can be regenerated on a machine without Xcode.

plateau_sim.py explored the thresholds with a looser prototype. This file instead mirrors
FernletKit/Sources/FernletDomainModel/WorkoutTrend.swift and WorkoutTrend+Fit.swift exactly (the
training tier read at the newest session, the robust weights in the dipping check's level, the
64-point cap), and scores the same seeded histories the Swift harness builds
(Tests/FernletTests/WorkoutPlateauSimulationTests.swift): plateau_sim's generator and its port of
the old "latest four vs the 112-day best" rule, unchanged.

If you change WorkoutTrend, change this file the same way, rerun it, and update the numbers pinned
in WorkoutPlateauSimulationTests and in WorkoutTrend.swift's header.

Run: python3 -I Tools/plateau-sim/swift_mirror.py [histories]
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import plateau_sim as sim  # noqa: E402  (the shared generator and the old rule)

# WorkoutTrend's tuned numbers.
INTERMEDIATE_WEEKS = 26.0
ADVANCED_WEEKS = 104.0
UPPER_Z = 0.8416
EXPECTED_Z = 1.645
STALL_GAIN = 0.01
STALL_PERSISTENCE = 3
PERSONAL_AFTER = 10
PERSONAL_FLOOR = 0.75
DIP_ERRORS = 2.0
FLAGGED_WEIGHT = 0.5
OWN_WEEKS = 4.0
OWN_SESSIONS = 6
ADHERENCE_DAYS = 28.0
ADHERENCE_SESSIONS = 3
ADHERENCE_GAP = 14.0
OLDER_YEARS = 60
HUBER_PASSES = 3
HUBER_K = 1.5
MAX_POINTS = 64

TIERS = {
    # minimumSessions, minimumWeeks, trendWeeks, stallWeeks, noisePrior, baseRate
    "beginner": (5, 1.5, 4.0, 8.0, 0.045, 0.10),
    "intermediate": (8, 6.0, 8.0, 10.0, 0.035, 0.025),
    "advanced": (12, 10.0, 12.0, 12.0, 0.03, 0.025),
}
LOWER_TRIM, UPPER_TRIM = 0.03, 0.015


class Point:
    """A TrendPoint: day (fractional days from the history's start), score, flag (None or firm)."""
    __slots__ = ("day", "score", "flagged", "firm")

    def __init__(self, day, score, flagged, firm):
        self.day = day
        self.score = score
        self.flagged = flagged
        self.firm = firm


def tier_for(weeks):
    if weeks < INTERMEDIATE_WEEKS:
        return "beginner"
    if weeks < ADVANCED_WEEKS:
        return "intermediate"
    return "advanced"


def weeks_between(a, b):
    return (b - a) / 7.0


def trim(point, lower_body):
    full = LOWER_TRIM if lower_body else UPPER_TRIM
    return full if point.firm else full / 2.0


class Fit:
    __slots__ = ("slope", "intercept", "sxx", "x_mean", "weight_sum")

    def value(self, x):
        return self.intercept + self.slope * x


def line(xs, ys, ws):
    weight_sum = sum(ws)
    if not xs or weight_sum <= 0:
        return None
    x_mean = sum(w * x for w, x in zip(ws, xs)) / weight_sum
    y_mean = sum(w * y for w, y in zip(ws, ys)) / weight_sum
    sxx = 0.0
    sxy = 0.0
    for x, y, w in zip(xs, ys, ws):
        dx = x - x_mean
        sxx += w * dx * dx
        sxy += w * dx * (y - y_mean)
    if not sxx > 1e-9:
        return None
    fit = Fit()
    fit.slope = sxy / sxx
    fit.intercept = y_mean - fit.slope * x_mean
    fit.sxx = sxx
    fit.x_mean = x_mean
    fit.weight_sum = weight_sum
    return fit


def robust_line(xs, ys, ws, sigma):
    if not (sigma > 0 and math.isfinite(sigma)):
        return line(xs, ys, ws)
    cutoff = HUBER_K * sigma
    robust = [1.0] * len(xs)
    for _ in range(HUBER_PASSES):
        fit = line(xs, ys, [w * r for w, r in zip(ws, robust)])
        if fit is None:
            return None
        robust = []
        for x, y in zip(xs, ys):
            residual = abs(y - fit.value(x))
            robust.append(1.0 if residual <= cutoff else cutoff / residual)
    return line(xs, ys, [w * r for w, r in zip(ws, robust)])


def fit_window(window, sigma, short_weight, lower_body):
    if not window:
        return None
    origin = window[0].day
    xs = [weeks_between(origin, p.day) for p in window]
    ys = [math.log(max(p.score, 1e-6)) for p in window]
    initial = robust_line(xs, ys, [FLAGGED_WEIGHT if p.flagged else 1.0 for p in window], sigma)
    if initial is None:
        return None
    weights = []
    for p, x, y in zip(window, xs, ys):
        if not p.flagged:
            weights.append(1.0)
            continue
        residual = y - initial.value(x)
        weights.append(1.0 if residual >= -trim(p, lower_body) else short_weight)
    fit = robust_line(xs, ys, weights, sigma)
    if fit is None:
        return None
    return fit, xs, ys


def noise(window, tier, trend):
    fit, xs, ys = trend
    squares = [(y - fit.value(x)) ** 2 for p, x, y in zip(window, xs, ys) if not p.flagged]
    prior = TIERS[tier][4]
    if len(squares) < PERSONAL_AFTER:
        return prior
    personal = math.sqrt(sum(squares) / max(1, len(squares) - 2))
    return max(personal, PERSONAL_FLOOR * prior)


def is_dipping(window, sigma, lower_body):
    if len(window) < 4 or window[-1].flagged or window[-2].flagged:
        return False
    trend = fit_window(window[:-2], sigma, FLAGGED_WEIGHT, lower_body)
    if trend is None:
        return False
    fit, xs, _ = trend
    end = xs[-1]
    level = fit.value(end)
    spread = end - fit.x_mean
    level_variance = sigma * sigma * (1.0 / fit.weight_sum + spread * spread / fit.sxx)
    typical = math.sqrt(sigma * sigma + level_variance)
    return all(math.log(max(p.score, 1e-6)) - level < -DIP_ERRORS * typical for p in window[-2:])


def previous_slope(points, start, tier, sigma, lower_body):
    trend_weeks = TIERS[tier][2]
    prior = [p for p in points if p.day < start and weeks_between(p.day, start) <= trend_weeks]
    if sum(1 for p in prior if not p.flagged) < TIERS[tier][0]:
        return None
    trend = fit_window(prior, sigma, FLAGGED_WEIGHT, lower_body)
    return None if trend is None else trend[0].slope


def own_expected_slope(points, start, sigma, lower_body):
    prior = [p for p in points if p.day < start and weeks_between(p.day, start) <= OWN_WEEKS]
    if sum(1 for p in prior if not p.flagged) < OWN_SESSIONS:
        return None
    trend = fit_window(prior, sigma, FLAGGED_WEIGHT, lower_body)
    if trend is None:
        return None
    fit = trend[0]
    return max(0.0, fit.slope - UPPER_Z * sigma / math.sqrt(fit.sxx))


class Resolved:
    __slots__ = ("tier", "rate", "weeks_at_last", "last_day", "inferred", "lower_body")


def resolve(explicit_weeks, older, lower_body, first_day, last_day):
    """TrendProfile → ResolvedProfile. `explicit_weeks` is the training age at the newest point
    (None infers it from the history's length); `older` stands for LifterTraits(ageYears: 65)."""
    inferred = explicit_weeks is None
    weeks = 1.0 + weeks_between(first_day, last_day) if inferred else explicit_weeks
    weeks = max(1.0, weeks)
    resolved = Resolved()
    resolved.tier = tier_for(weeks)
    resolved.rate = 0.0 if (older and weeks >= ADVANCED_WEEKS) else TIERS[resolved.tier][5]
    resolved.weeks_at_last = weeks
    resolved.last_day = last_day
    resolved.inferred = inferred
    resolved.lower_body = lower_body
    return resolved


def expected_slope(resolved, start, end):
    if resolved.rate <= 0:
        return 0.0
    late = max(1.0, resolved.weeks_at_last - weeks_between(end, resolved.last_day))
    early = max(1.0, resolved.weeks_at_last - weeks_between(start, resolved.last_day))
    if not late - early > 1e-6:
        return resolved.rate / late
    return resolved.rate * math.log(late / early) / (late - early)


def is_adherent(points):
    last = points[-1].day
    recent = [p for p in points if last - p.day <= ADHERENCE_DAYS]
    if len(recent) < ADHERENCE_SESSIONS:
        return False
    return all(b.day - a.day <= ADHERENCE_GAP for a, b in zip(recent, recent[1:]))


def is_stall_candidate(points, resolved):
    if not (resolved.rate > 0) or not points or not is_adherent(points):
        return False
    tier = resolved.tier
    minimum, _, _, stall_weeks, prior, _ = TIERS[tier]
    last = points[-1].day
    window = [p for p in points if last - p.day <= stall_weeks * 7]
    flagged = sum(1 for p in window if p.flagged)
    if not window or len(window) - flagged < minimum or flagged * 2 >= len(window):
        return False
    start = window[0].day
    if weeks_between(start, last) < stall_weeks - 0.5:
        return False
    trend = fit_window(window, prior, FLAGGED_WEIGHT, resolved.lower_body)
    if trend is None:
        return False
    sigma = noise(window, tier, trend)
    stall = fit_window(window, sigma, 0.0, resolved.lower_body)
    if stall is None:
        return False
    error = sigma / math.sqrt(stall[0].sxx)
    if resolved.inferred:
        expected = own_expected_slope(points, start, sigma, resolved.lower_body)
    else:
        expected = expected_slope(resolved, start, last)
    if expected is None:
        return False
    slope = stall[0].slope
    return (slope + UPPER_Z * error) * 4 < STALL_GAIN and slope + EXPECTED_Z * error < expected


def is_stalled(points, resolved):
    if len(points) <= STALL_PERSISTENCE:
        return False
    return all(is_stall_candidate(points[:len(points) - back], resolved) for back in range(STALL_PERSISTENCE))


def reading_state(points, explicit_weeks, older, lower_body):
    """WorkoutTrend.reading(of:profile:levelKg: nil).state"""
    points = points[-MAX_POINTS:]
    if not points:
        return "tooEarly"
    first, last = points[0].day, points[-1].day
    resolved = resolve(explicit_weeks, older, lower_body, first, last)
    minimum, min_weeks, trend_weeks, _, prior, _ = TIERS[resolved.tier]
    window = [p for p in points if last - p.day <= trend_weeks * 7]
    flagged = sum(1 for p in window if p.flagged)
    start = window[0].day
    if len(window) - flagged < minimum or weeks_between(start, last) < min_weeks or flagged * 2 >= len(window):
        return "tooEarly"
    trend = fit_window(window, prior, FLAGGED_WEIGHT, lower_body)
    if trend is None:
        return "tooEarly"
    sigma = noise(window, resolved.tier, trend)
    expected = None if resolved.inferred else expected_slope(resolved, start, last)
    if is_dipping(window, sigma, lower_body):
        return "dipping"
    if is_stalled(points, resolved):
        return "stalled"
    fit = trend[0]
    upper = fit.slope + UPPER_Z * sigma / math.sqrt(fit.sxx)
    if expected is not None and upper < expected:
        return "slowing"
    previous = previous_slope(points, start, resolved.tier, sigma, lower_body)
    if previous is None:
        return "progressing"
    return "slowing" if previous > 0 and upper < previous / 2 else "progressing"


# ---------------------------------------------------------------------------------------------
# The harness, as WorkoutPlateauSimulationTests runs it
# ---------------------------------------------------------------------------------------------

def score(history, explicit):
    """(old false stall, new false stall, new false dip, old delay, new delay) over every prefix."""
    onset = None if history.stall_week is None else history.stall_week * 7.0
    older = history.cohort == "older"
    points = [Point(float(s.day), s.score, s.flagged, s.firm) for s in history.sessions]
    old_false = new_false = false_dip = False
    old_delay = new_delay = None
    for k in range(1, len(points) + 1):
        day = points[k - 1].day
        weeks = history.t0_weeks + day / 7.0 if explicit else None
        state = reading_state(points[:k], weeks, older, history.lower_body)
        old = sim.old_is_stalled(history.sessions[:k])
        if onset is None or day < onset:
            old_false = old_false or old
            new_false = new_false or state == "stalled"
        else:
            if old and old_delay is None:
                old_delay = (day - onset) / 7.0
            if state == "stalled" and new_delay is None:
                new_delay = (day - onset) / 7.0
        if state == "dipping" and not sim.in_true_dip(history, day):
            false_dip = True
    return old_false, new_false, false_dip, old_delay, new_delay


def run(count, weeks, stall, explicit, cohort=None):
    return [(h.cohort, score(h, explicit)) for h in
            (sim.make_history(i, weeks, stall=stall, cohort=cohort) for i in range(count))]


def rates(rows):
    n = max(1, len(rows))
    return (sum(r[0] for _, r in rows), sum(r[1] for _, r in rows), sum(r[2] for _, r in rows), n)


def main(argv):
    count = int(argv[1]) if len(argv) > 1 else 400
    for explicit in (True, False):
        mode = "known" if explicit else "inferred"
        rows = run(count, 12, False, explicit)
        old, new, dip, n = rates(rows)
        print("%-8s 12 wk, no stall, n=%d: old false %d (%.1f%%), new false %d (%.1f%%), false dip %d (%.1f%%)"
              % (mode, n, old, 100.0 * old / n, new, 100.0 * new / n, dip, 100.0 * dip / n))
        for cohort in ("beginner", "trained"):
            sub = [x for x in rows if x[0] == cohort]
            o, w, d, m = rates(sub)
            print("    %-8s n=%d old %d new %d dip %d" % (cohort, m, o, w, d))
        older = run(count // 4, 12, False, explicit, cohort="older")
        o, w, d, m = rates(older)
        print("%-8s older (b = 0) n=%d: old false %d, new false %d, false dip %d" % (mode, m, o, w, d))
        for cohort in ("beginner", "trained"):
            stalls = run(count // 4, 24, True, explicit, cohort=cohort)
            found = sorted(r[4] for _, r in stalls if r[4] is not None)
            old_found = sorted(r[3] for _, r in stalls if r[3] is not None)
            med = found[len(found) // 2] if found else float("nan")
            old_med = old_found[len(old_found) // 2] if old_found else float("nan")
            print("%-8s true stall %-8s n=%d: new found %d median %.2f wk (max %.2f) | old found %d median %.2f wk"
                  % (mode, cohort, len(stalls), len(found), med, found[-1] if found else float("nan"),
                     len(old_found), old_med))


if __name__ == "__main__":
    main(sys.argv)
