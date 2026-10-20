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
