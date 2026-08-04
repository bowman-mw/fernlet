// Closeness.swift
// FernletDomainModel
//
// Deterministic (no-AI) closeness math + the close-friend slot assignment (spec §10 friend tiers,
// 2026-07-11 closeness memo). Pure value types + functions so both the ProximityKit ledger and the
// app can compute closeness and slots without a calendar or any I/O. Everything is integer counts ×
// fixed rational weights — bit-for-bit reproducible.

import Foundation

/// One day's capped interaction counts with a single friend (day-granularity only — no timestamps,
/// names, or durations, so this is a warmth signal, never a surveillance log).
public nonisolated struct FriendInteractionDayCounts: Codable, Equatable, Sendable {
    public var sessions: Int = 0        // in-person friend sessions (dominant signal)
    public var photoSessions: Int = 0   // sessions where a photo was taken together
    public var sharesAccepted: Int = 0  // a recipe/clothing share you accepted
    public var heartSent: Int = 0
    public var heartReceived: Int = 0

    public init() {}

    /// This day's contribution, capped at 10 so no single day dominates. In-person meetings weigh
    /// 5:1 over a heart, so heart-pumping can never outrank real time together.
    public var points: Int {
        let raw =
            5 * min(sessions, 2)
            + 3 * min(photoSessions, 1)
            + 2 * min(sharesAccepted, 1)
            + min(heartSent, 1)
            + min(heartReceived, 1)
            + ((heartSent >= 1 && heartReceived >= 1) ? 1 : 0)   // mutuality bonus
        return min(raw, 10)
    }
}

/// Deterministic trailing-30-day closeness scoring over per-day interaction counts.
///
/// Pure integer/rational math — no calendar, clock, or I/O — so the ProximityKit ledger and the app
/// compute bit-for-bit identical closeness from the same ``FriendInteractionDayCounts`` rows.
public nonisolated enum ClosenessMath {
    public static let windowDays = 30

    /// Trailing-30-day closeness: Σ over each day of `weight(age) · points`, `weight = (31 − age)/31`
    /// (today ≈ 1.0, day 30 ≈ 0.03). Days outside the window are ignored. Deterministic.
    public static func closeness(daily: [(ageDays: Int, counts: FriendInteractionDayCounts)]) -> Double {
        daily.reduce(0.0) { total, entry in
            guard (0...windowDays).contains(entry.ageDays) else { return total }
            let weight = Double(31 - entry.ageDays) / 31.0
            return total + weight * Double(entry.counts.points)
        }
    }
}

/// The persisted close-slot assignment (device-local — closeness is a private, per-device view and
/// never leaves the device).
///
/// Holds the four close-slot fingerprints, when each entered (for the dwell immunity), and the last
/// day ``CloseSlotAssignment/evaluate(eligible:firstAcceptedAt:state:now:todayKey:)`` ran, so the
/// once-per-day re-evaluation is idempotent within a day.
public nonisolated struct CloseSlotState: Codable, Equatable, Sendable {
    public var closeFingerprints: [String] = []
    public var enteredAt: [String: Date] = [:]
    public var lastEvalDayKey: String = ""
    public init() {}
}

/// The close-friend slot machine: tier limits plus the hysteretic 4-slot assignment pass.
///
/// Holds the friend-tier constants (4 close / 8 core / 12 max) and `evaluate`, the deterministic
/// once-per-day re-assignment: vacancies fill freely from friends with real closeness, and otherwise
/// at most ONE margin-gated challenge swap per run against an incumbent past its dwell — so slots
/// stay stable day to day instead of churning on small score changes.
public nonisolated enum CloseSlotAssignment {
    public static let closeSlots = 4
    public static let coreSlots = 8
    public static let maxFriends = 12
    /// A challenger must beat the lowest close incumbent by this margin (≈ one extra in-person meetup).
    public static let challengeMargin = 8.0
    /// A newly promoted close friend is immune to challenge for this many days.
    public static let dwellDays = 3

    /// Re-assigns the 4 close slots with hysteresis. `eligible`: fingerprint → closeness for the active
    /// friends. Vacancies fill freely; otherwise at most ONE swap, and only when a challenger clears the
    /// margin against the lowest incumbent that is past its dwell. Deterministic total order
    /// (closeness desc, firstAcceptedAt asc, fingerprint asc). Blocked/removed friends must be absent
    /// from `eligible`; their slots are vacated.
    public static func evaluate(
        eligible: [String: Double],
        firstAcceptedAt: [String: Date],
        state: CloseSlotState,
        now: Date,
        todayKey: String
    ) -> CloseSlotState {
        var newState = state
        // Vacate slots for friends no longer eligible.
        newState.closeFingerprints.removeAll { eligible[$0] == nil }
        newState.enteredAt = newState.enteredAt.filter { eligible[$0.key] != nil }

        func ranked(_ fingerprints: [String]) -> [String] {
            fingerprints.sorted { a, b in
                let ca = eligible[a] ?? 0, cb = eligible[b] ?? 0
                if ca != cb { return ca > cb }
                let fa = firstAcceptedAt[a] ?? .distantFuture, fb = firstAcceptedAt[b] ?? .distantFuture
                if fa != fb { return fa < fb }
                return a < b
            }
        }

        // Fill empty close slots with the highest-ranked non-close friends who have ANY closeness. A
        // zero-interaction friend must never be promoted: doing so would stamp a 3-day dwell immunity on
        // a friend you haven't actually met, locking out someone you later genuinely grow close to. Empty
        // slots stay empty until there's real closeness to honor.
        while newState.closeFingerprints.count < closeSlots {
            let candidates = ranked(eligible.keys.filter { !newState.closeFingerprints.contains($0) && (eligible[$0] ?? 0) > 0 })
            guard let next = candidates.first else { break }
            newState.closeFingerprints.append(next)
            newState.enteredAt[next] = now
        }

        // At most one challenge swap, gated by margin + dwell.
        if let challenger = ranked(eligible.keys.filter { !newState.closeFingerprints.contains($0) }).first {
            let pastDwell = newState.closeFingerprints.filter { fp in
                now.timeIntervalSince(newState.enteredAt[fp] ?? now) >= Double(dwellDays) * 86_400
            }
            if let incumbent = pastDwell.min(by: { (eligible[$0] ?? 0) < (eligible[$1] ?? 0) }),
               (eligible[challenger] ?? 0) >= (eligible[incumbent] ?? 0) + challengeMargin {
                newState.closeFingerprints.removeAll { $0 == incumbent }
                newState.enteredAt[incumbent] = nil
                newState.closeFingerprints.append(challenger)
                newState.enteredAt[challenger] = now
            }
        }

        newState.lastEvalDayKey = todayKey
        return newState
    }
}
