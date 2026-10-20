#!/usr/bin/env python3
"""Plateau-detector tuning prototype for Fernlet's workout planner (round 2, engine lane).

This mirrors the Swift simulation harness in
FernletKit/Tests/FernletDomainModelTests/WorkoutPlateauSimulationTests.swift so thresholds can be
explored quickly. It is deterministic: every history comes from a SplitMix64 stream seeded by its
index, never the system RNG, and every loop is bounded.

Synthetic truth: e1RM(t) = start * (1 + b * ln(t / t0)), t in weeks, t0 = 1.
  b ~ 0.10 for an untrained start, ~0.025 for a trained start.
Events layered on top: true stalls (slope 0 from week N), fatigue dips (5-8% drop recovering
over 1-2 weeks), session noise sigma in {3%, 4%, 5%}, 2-3 sessions a week, and sleep-flagged
sessions with a ~3% true penalty on lower-body lifts.

Run: python3 Tools/plateau-sim/plateau_sim.py
"""

import math

MASK64 = (1 << 64) - 1


class SplitMix64:
    """Same constants as the Swift harness, so both produce identical streams."""

    def __init__(self, seed):
        self.state = seed & MASK64

    def next_u64(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return z ^ (z >> 31)

    def unit(self):
        """Uniform in [0, 1) from the top 53 bits."""
        return (self.next_u64() >> 11) / float(1 << 53)

    def gaussian(self):
        """Box-Muller, one draw per call (the second value is discarded for simplicity)."""
        u1 = max(self.unit(), 1e-12)
        u2 = self.unit()
        return math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2)


# ---------------------------------------------------------------------------------------------
# Synthetic histories
# ---------------------------------------------------------------------------------------------

DAY_PATTERNS = {2: (0, 3), 3: (0, 2, 4)}


class Session:
    __slots__ = ("day", "true", "score", "flagged", "firm", "trim", "completed", "in_dip")

    def __init__(self, day, true, score, flagged, firm, trim, completed, in_dip):
        self.day = day
        self.true = true
        self.score = score
        self.flagged = flagged
        self.firm = firm
        self.trim = trim
        self.completed = completed
        self.in_dip = in_dip


class History:
    """One lift's synthetic truth and its logged sessions."""

    def __init__(self, cohort, b, t0_weeks, sigma, per_week, lower_body, stall_week, dip, sessions):
        self.cohort = cohort
        self.b = b
        self.t0_weeks = t0_weeks
        self.sigma = sigma
        self.per_week = per_week
        self.lower_body = lower_body
        self.stall_week = stall_week
        self.dip = dip
        self.sessions = sessions


COHORTS = ("beginner", "trained", "older")
SIGMAS = (0.03, 0.04, 0.05)
FLAG_RATE = 0.15        # share of sessions after a short night or on a light readiness day
FIRM_SHARE = 0.4        # of flagged sessions, the share after two short nights in a row
SLEEP_PENALTY = 0.03    # true lower-body cost of a flagged session
DIP_SHARE = 0.3         # share of histories with one fatigue dip
SKIP_RATE = 0.05        # sessions skipped at random


def true_value(start, b, weeks_trained, stall_weeks):
    """Linear-log truth, flat from the stall (in training weeks) on."""
    t = weeks_trained if stall_weeks is None else min(weeks_trained, stall_weeks)
    return start * (1.0 + b * math.log(max(t, 1.0)))


def make_history(index, weeks, stall=False, sigma=None, cohort=None):
    rng = SplitMix64(0xF3A7_0000 + index * 7919 + (1 if stall else 0) * 104_729)
    cohort = cohort or COHORTS[int(rng.unit() * 2)]  # beginner or trained; "older" only on request
    if cohort == "beginner":
        b, t0 = 0.10, 1.0 + rng.unit() * 7.0
    elif cohort == "trained":
        b, t0 = 0.025, 26.0 + rng.unit() * 130.0
    else:
        b, t0 = 0.0, 260.0 + rng.unit() * 260.0
    sigma = sigma if sigma is not None else SIGMAS[int(rng.unit() * 3) % 3]
    per_week = 2 if rng.unit() < 0.5 else 3
    lower_body = rng.unit() < 0.5
    stall_week = (3.0 + rng.unit() * 3.0) if stall else None
    dip = None
    if rng.unit() < DIP_SHARE:
        dip = (2.0 + rng.unit() * (weeks - 4.0), 0.05 + rng.unit() * 0.03, 1.0 + rng.unit())
    start = 100.0
    sessions = []
    required = None
    for week in range(weeks):
        for offset in DAY_PATTERNS[per_week]:
            if rng.unit() < SKIP_RATE:
                continue
            day = week * 7 + offset
            elapsed = day / 7.0
            stall_t = None if stall_week is None else t0 + stall_week
            value = true_value(start, b, t0 + elapsed, stall_t)
            in_dip = False
            if dip is not None and dip[0] <= elapsed <= dip[0] + dip[2]:
                value *= 1.0 - dip[1] * (1.0 - (elapsed - dip[0]) / dip[2])
                in_dip = True
            flagged = rng.unit() < FLAG_RATE
            firm = flagged and rng.unit() < FIRM_SHARE
            if flagged and lower_body:
                value *= 1.0 - SLEEP_PENALTY
            score = value * math.exp(sigma * rng.gaussian())
            trim = flag_trim(flagged, firm, lower_body)
            # The rep-ladder rule asks for about one more rep (~2.5 %) after every completed session.
            if required is None:
                required = score * 0.97
            completed = score >= required
            if completed:
                required *= 1.025
            sessions.append(Session(day, value, score, flagged, firm, trim, completed, in_dip))
    return History(cohort, b, t0, sigma, per_week, lower_body, stall_week, dip, sessions)


def flag_trim(flagged, firm, lower_body):
    """How far below the line a flagged session may land and still 'meet the trend' (log units).
    The literature trim (~3 % lower body, ~1.5 % upper) applies in full after two short nights;
    one short night or a light readiness day gets half (the flag is softer)."""
    if not flagged:
        return 0.0
    full = 0.03 if lower_body else 0.015
    return full if firm else full / 2.0


# ---------------------------------------------------------------------------------------------
# The OLD rule: WorkoutPlateau.isStalled as of 925476cc (latest 4 vs the 112-day best)
# ---------------------------------------------------------------------------------------------

def old_is_stalled(sessions):
    last = sessions[-1]
    recent = [s for s in sessions if last.day - s.day <= 28]
    if len(recent) < 3:
        return False
    for a, b2 in zip(recent, recent[1:]):
        if b2.day - a.day > 14:
            return False
    evidence = [s for s in sessions if last.day - s.day <= 112]
    if len(evidence) <= 4:
        return False
    latest = evidence[-4:]
    if sum(1 for s in latest if s.completed) > 1:
        return False
    earlier_best = max(s.score for s in evidence[:-4])
    recent_best = max(s.score for s in latest)
    return recent_best <= earlier_best * 1.01


# ---------------------------------------------------------------------------------------------
# The NEW detector (mirrors WorkoutTrend in FernletDomainModel)
# ---------------------------------------------------------------------------------------------

TIERS = {
    # min clean sessions, min span (weeks), trend window (weeks), stall window (weeks), noise prior
    "beginner": dict(min_sessions=5, min_weeks=1.5, max_weeks=4.0, stall_weeks=8.0, prior=0.045),
    "intermediate": dict(min_sessions=8, min_weeks=6.0, max_weeks=8.0, stall_weeks=10.0, prior=0.035),
    "advanced": dict(min_sessions=12, min_weeks=10.0, max_weeks=12.0, stall_weeks=12.0, prior=0.03),
}
PARAMS = dict(
    z_upper=0.8416,          # one-sided 80 % bound
    z_expected=1.2816,          # how clearly the slope must sit under the expected curve, in SEs
    stall_persist=3,         # consecutive evaluations the stall test must hold
    own_weeks=4.0,           # inferred training age: the earlier stretch the own-progress slope reads
    own_min_sessions=6,
    stall_gain=0.01,         # 1 % per 4 weeks
    huber_k=1.5,             # robust reweighting, in noise units
    huber_passes=3,
    personal_after=10,       # clean sessions before the person's own scatter replaces the prior
    personal_floor=0.75,     # personal noise never below this share of the prior
    dip_errors=2.0,          # dipping: two clean sessions this many typical errors under the line
    flagged_weight=0.5,
)


def tier_for(weeks):
    if weeks < 26:
        return "beginner"
    if weeks < 104:
        return "intermediate"
    return "advanced"


def wls(xs, ys, ws):
    sw = sum(ws)
    if sw <= 0:
        return None
    xm = sum(w * x for w, x in zip(ws, xs)) / sw
    ym = sum(w * y for w, y in zip(ws, ys)) / sw
    sxx = sum(w * (x - xm) ** 2 for w, x in zip(ws, xs))
    if sxx <= 1e-9:
        return None
    sxy = sum(w * (x - xm) * (y - ym) for w, x, y in zip(ws, xs, ys))
    slope = sxy / sxx
    return slope, ym - slope * xm, sxx


def robust_fit(xs, ys, ws, sigma):
    """Weighted least squares with bounded Huber reweighting. Returns (slope, intercept, sxx)."""
    robust = [1.0] * len(xs)
    for _ in range(PARAMS["huber_passes"]):
        fit = wls(xs, ys, [w * r for w, r in zip(ws, robust)])
        if fit is None:
            return None
        slope, icpt, _ = fit
        k = PARAMS["huber_k"] * sigma
        robust = []
        for x, y in zip(xs, ys):
            r = abs(y - (icpt + slope * x))
            robust.append(1.0 if r <= k else k / r)
    return wls(xs, ys, [w * r for w, r in zip(ws, robust)])


class Profile:
    def __init__(self, b, start_weeks, tier, inferred=False):
        self.b = b
        self.start_weeks = start_weeks
        self.tier = tier
        self.inferred = inferred


def explicit_profile(history):
    return Profile(history.b, history.t0_weeks, tier_for(history.t0_weeks))


def inferred_profile(sessions):
    weeks = 1.0 + (sessions[-1].day - sessions[0].day) / 7.0
    return Profile(0.10, 1.0, tier_for(weeks), inferred=True)


def expected_slope(profile, first_day, last_day, origin_day):
    if profile.b <= 0:
        return 0.0
    t1 = max(profile.start_weeks + (first_day - origin_day) / 7.0, 1.0)
    t2 = max(profile.start_weeks + (last_day - origin_day) / 7.0, 1.0)
    if t2 - t1 < 1e-6:
        return profile.b / t2
    return profile.b * math.log(t2 / t1) / (t2 - t1)


def adherent(sessions):
    last = sessions[-1].day
    recent = [s for s in sessions if last - s.day <= 28]
    if len(recent) < 3:
        return False
    return all(b2.day - a.day <= 14 for a, b2 in zip(recent, recent[1:]))


def fit_window(window, sigma, flagged_short_weight):
    """Two-pass fit: flagged sessions start at half weight; one that meets the line (within its
    trim) counts fully, one that falls short keeps `flagged_short_weight`."""
    origin = window[0].day
    xs = [(s.day - origin) / 7.0 for s in window]
    ys = [math.log(s.score) for s in window]
    first = robust_fit(xs, ys, [PARAMS["flagged_weight"] if s.flagged else 1.0 for s in window], sigma)
    if first is None:
        return None
    slope, icpt, _ = first
    ws = []
    for s, x, y in zip(window, xs, ys):
        if not s.flagged or y - (icpt + slope * x) >= -s.trim:
            ws.append(1.0)
        else:
            ws.append(flagged_short_weight)
    fit = robust_fit(xs, ys, ws, sigma)
    if fit is None:
        return None
    return fit, xs, ys, ws


def evaluate(sessions, profile):
    """State of the lift after its newest session: tooEarly, dipping, stalled, slowing, progressing."""
    p = TIERS[profile.tier]
    origin = sessions[0].day
    now = sessions[-1].day
    window = [s for s in sessions if now - s.day <= p["max_weeks"] * 7.0]
    clean = [s for s in window if not s.flagged]
    span = (now - window[0].day) / 7.0
    if len(clean) < p["min_sessions"] or span < p["min_weeks"]:
        return "tooEarly"
    if sum(1 for s in window if s.flagged) * 2 >= len(window):
        return "tooEarly"
    sigma = p["prior"]
    trend = fit_window(window, sigma, PARAMS["flagged_weight"])
    if trend is None:
        return "tooEarly"
    (slope, icpt, sxx), xs, ys, ws = trend
    sigma = noise(window, p, trend)
    g =expected_slope(profile, window[0].day, now, origin)
    if is_dipping(window, sigma):
        return "dipping"
    persist = PARAMS["stall_persist"]
    if all(stall_candidate(sessions[:len(sessions) - k], profile) for k in range(persist)):
        return "stalled"
    upper = slope + PARAMS["z_upper"] * sigma / math.sqrt(sxx)
    previous = previous_slope(sessions, window[0].day, p, sigma)
    if upper < g or (previous is not None and previous > 0 and upper < 0.5 * previous):
        return "slowing"
    return "progressing"


def noise(window, p, fit):
    """The prior, or the person's own scatter around the line once there are enough clean sessions."""
    (slope, icpt, _), xs, ys, _ = fit
    clean = [(x, y) for s, x, y in zip(window, xs, ys) if not s.flagged]
    if len(clean) < PARAMS["personal_after"]:
        return p["prior"]
    res = [y - (icpt + slope * x) for x, y in clean]
    personal = math.sqrt(sum(r * r for r in res) / max(1, len(res) - 2))
    return max(personal, PARAMS["personal_floor"] * p["prior"])


def stall_candidate(sessions, profile):
    """The stall test on its own longer window: the upper bound of the slope, flagged sessions
    that fell short left out, stays under 1 % per 4 weeks AND clearly under the expected curve."""
    if len(sessions) < 2 or profile.b <= 0 or not adherent(sessions):
        return False
    p = TIERS[profile.tier]
    now = sessions[-1].day
    window = [s for s in sessions if now - s.day <= p["stall_weeks"] * 7.0]
    clean = [s for s in window if not s.flagged]
    if len(clean) < p["min_sessions"] or (now - window[0].day) / 7.0 < p["stall_weeks"] - 0.5:
        return False
    if sum(1 for s in window if s.flagged) * 2 >= len(window):
        return False
    trend = fit_window(window, p["prior"], PARAMS["flagged_weight"])
    if trend is None:
        return False
    sigma = noise(window, p, trend)
    stall = fit_window(window, sigma, 0.0)
    if stall is None:
        return False
    (slope, _, sxx), _, _, _ = stall
    se = sigma / math.sqrt(sxx)
    if profile.inferred:
        g = own_expected_slope(sessions, window[0].day, p, sigma)
        if g is None:
            return False
    else:
        g = expected_slope(profile, window[0].day, now, sessions[0].day)
    return (slope + PARAMS["z_upper"] * se) * 4.0 < PARAMS["stall_gain"] and slope + PARAMS["z_expected"] * se < g


def own_expected_slope(sessions, window_start, p, sigma):
    """With the training age only inferred, the expected slope is the lift's own earlier progress:
    the lower 80 % bound of the slope just before the stall window (never below zero)."""
    weeks = PARAMS["own_weeks"]
    prior = [s for s in sessions if window_start - weeks * 7.0 <= s.day < window_start]
    if sum(1 for s in prior if not s.flagged) < PARAMS["own_min_sessions"]:
        return None
    fit = fit_window(prior, sigma, PARAMS["flagged_weight"])
    if fit is None:
        return None
    (slope, _, sxx), _, _, _ = fit
    return max(0.0, slope - PARAMS["z_upper"] * sigma / math.sqrt(sxx))


def is_dipping(window, sigma):
    if len(window) < 4 or window[-1].flagged or window[-2].flagged:
        return False
    base = window[:-2]
    fit = fit_window(base, sigma, PARAMS["flagged_weight"])
    if fit is None:
        return False
    (slope, icpt, _), _, _, _ = fit
    # The line's level at the last earlier session, never extrapolated: a rising curve can only
    # lift the newest sessions, so a beginner's bending curve never reads as a dip.
    level = icpt + slope * (base[-1].day - base[0].day) / 7.0
    for s in window[-2:]:
        if math.log(s.score) - level >= -PARAMS["dip_errors"] * sigma:
            return False
    return True


def previous_slope(sessions, window_start, p, sigma):
    prior = [s for s in sessions if window_start - p["max_weeks"] * 7.0 <= s.day < window_start]
    if sum(1 for s in prior if not s.flagged) < p["min_sessions"]:
        return None
    fit = fit_window(prior, sigma, PARAMS["flagged_weight"])
    return None if fit is None else fit[0][0]


# ---------------------------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------------------------

def in_true_dip(history, day):
    if history.dip is None:
        return False
    start = history.dip[0] * 7.0
    return start <= day <= start + history.dip[2] * 7.0 + 7.0


def score_history(history, mode):
    """(old false call, new false call, new false dipping, old delay, new delay) for one history."""
    onset = None if history.stall_week is None else history.stall_week * 7.0
    old_false = new_false = false_dip = False
    old_delay = new_delay = None
    sessions = history.sessions
    for k in range(1, len(sessions) + 1):
        prefix = sessions[:k]
        day = prefix[-1].day
        profile = explicit_profile(history) if mode == "explicit" else inferred_profile(prefix)
        state = evaluate(prefix, profile)
        old = old_is_stalled(prefix)
        if onset is None or day < onset:
            old_false = old_false or old
            new_false = new_false or state == "stalled"
        else:
            if old and old_delay is None:
                old_delay = (day - onset) / 7.0
            if state == "stalled" and new_delay is None:
                new_delay = (day - onset) / 7.0
        if state == "dipping" and not in_true_dip(history, day):
            false_dip = True
    return old_false, new_false, false_dip, old_delay, new_delay


def run(count, weeks, stall, mode, cohort=None):
    rows = {}
    for i in range(count):
        h = make_history(i, weeks, stall=stall, cohort=cohort)
        rows.setdefault((h.cohort, h.sigma), []).append(score_history(h, mode))
    return rows


def median(xs):
    return xs[len(xs) // 2] if xs else float("nan")


def summarize(rows, stall):
    out = []
    for key in sorted(rows):
        r = rows[key]
        n = len(r)
        if stall:
            old = sorted(x[3] for x in r if x[3] is not None)
            new = sorted(x[4] for x in r if x[4] is not None)
            out.append("%-9s s=%.2f n=%4d  old: found %5.1f%% median %.1f wk | new: found %5.1f%% median %.1f wk"
                       % (key[0], key[1], n, 100.0 * len(old) / n, median(old), 100.0 * len(new) / n, median(new)))
        else:
            out.append("%-9s s=%.2f n=%4d  false plateau old %5.1f%%  new %5.1f%% | false dipping new %5.1f%%"
                       % (key[0], key[1], n, 100.0 * sum(x[0] for x in r) / n,
                          100.0 * sum(x[1] for x in r) / n, 100.0 * sum(x[2] for x in r) / n))
    return out


def totals(rows):
    flat = [x for r in rows.values() for x in r]
    n = max(1, len(flat))
    return (100.0 * sum(x[0] for x in flat) / n, 100.0 * sum(x[1] for x in flat) / n,
            100.0 * sum(x[2] for x in flat) / n)


def main(argv):
    count = int(argv[1]) if len(argv) > 1 else 1200
    for mode in ("explicit", "inferred"):
        print("== %s training age, 12 weeks, no true stall" % mode)
        rows = run(count, 12, False, mode)
        print("\n".join(summarize(rows, False)))
        print("TOTAL false plateau old %.1f%% new %.1f%%, false dipping %.1f%%" % totals(rows))
        print("== %s, older long-trained (b = 0), 12 weeks" % mode)
        print("\n".join(summarize(run(count // 4, 12, False, mode, cohort="older"), False)))
        print("== %s, true stall from week 3-6, 24 weeks" % mode)
        print("\n".join(summarize(run(count // 2, 24, True, mode), True)))


if __name__ == "__main__":
    import sys
    main(sys.argv)
