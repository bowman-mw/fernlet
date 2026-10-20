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
