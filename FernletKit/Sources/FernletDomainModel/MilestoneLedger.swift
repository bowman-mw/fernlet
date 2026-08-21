// MilestoneLedger.swift
// Cumulative care milestones — an append-only LEDGER of counted care events, mirroring the coin
// ledger's proven shape (see CoinEconomy.swift + Docs/Coin-Ledger-Design-2026-06-29.md).
//
// Why its own store (and not new kinds inside the coin ledger): the two have deliberately DIFFERENT
// reset MECHANISMS. Coins are spendable currency and a full "reset all data" zeroes them via an
// in-band reset-boundary marker row that voids pre-reset rows sync-safely. Milestone events reset
// by row DELETION: since 2026-08-20 the wipe clears the ledger too (`MilestoneLedgerRepository.
// deleteAll()`, reached only through the deletion funnel — the protocol still exposes no delete;
// see `MilestoneLedgerRepositoring`), reversing the earlier product rule that milestone counts
// survive a reset — the rows are a dated metadata trail of the very content the wipe destroys.
// The milestone vocabulary has no marker kind, so rows held by another signed-in device can sync
// back after a wipe. Folding the two into `CoinEconomy` would force one store to carry both rules.
//
// Idempotency is structural, exactly like coins:
//   • An event row's id is DETERMINISTIC from the counted thing (`event:journal:<entry UUID>`,
//     `event:water:<dayKey>`), so two devices that both see the same journal entry mint the SAME id
//     → the application-level union-merge (`deduplicatedByID`) collapses them → counted exactly once.
//   • Lifetime counts = distinct-row counts. Outside the full wipe (which empties the whole
//     ledger), rows are never deleted, so between wipes counts are monotonic: deleting a meal or
//     disabling HealthKit never shrinks a lifetime count.
//   • Milestone COIN awards are `CoinLedgerEntry` earn rows with deterministic ids
//     (`milestone:journal:40`), so two devices crossing the same threshold offline collapse to one
//     award under the coin ledger's own dedup. Award rows carry the threshold-crossing day as their
//     `dayKey`, so the coin ledger's reset boundary voids pre-reset awards like any other earn —
//     load-bearing even now that the wipe deletes the milestone events too (2026-08-20), because
//     event rows held by another signed-in device can sync back and must not re-award coins.
//
// NO streaks, no windows, no expiry — every value here is a lifetime cumulative count.
// Wall-safe: pure value types + math in `FernletDomainModel`, never a `Private*` store (S3 wall).

import Foundation

/// The kinds of care events the milestone ledger counts. Raw values are embedded in persisted row
/// ids (`event:<kind>:<ref>`) — never rename. An old app version that doesn't know a new kind drops
/// just that row at decode (the repository's per-row `try?`), mirroring the coin ledger's
/// forward-compat behavior.
public nonisolated enum MilestoneEventKind: String, Codable, Sendable, CaseIterable {
    /// A journal entry saved (including one-tap tag-only mood check-ins — a check-in is a real
    /// journal moment, and the backfill couldn't distinguish them anyway: sealed entries are
    /// stripped to empty text in the persisted blob, so "empty text" carries no signal there).
    case journal
    /// A meal logged (any path: quick log, recipe, saved recipe, web import).
    case meal
    /// A workout logged BY THE USER. HealthKit-imported workouts (`Workout.healthKitUUID != nil`)
    /// are deliberately excluded — milestones celebrate deliberate acts of care, not passive data.
    case workout
    /// A breathing exercise completed in First Aid. Not derivable from day history (sessions write
    /// to HealthKit, not the diary), so these rows come only from the live completion hook.
    case breathing
    /// A worry released ("let go") from the Worry Box. Also live-hook-only: worries are sealed,
    /// device-local, and deleted on release — the ledger row is the only surviving trace, and it
    /// carries no content, only that a letting-go happened.
    case worry
    /// A day on which the hydration target was met (day-grain: one row per day, `event:water:<dayKey>`).
    /// Judged against the CURRENT hydration target at reconcile time — a later target change does not
    /// retroactively re-judge past days that already earned their row (an earned row is never revoked),
    /// but un-rowed past days are re-judged against the new target. Accepted simplification.
    case water
}

/// One immutable line in the milestone ledger. Rows are append-only and union-merge across devices
/// by `id` (the merge happens in `MilestoneEconomy` aggregation, not in storage — same as coins).
public nonisolated struct MilestoneLedgerEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: MilestoneEventKind
    /// The calendar day (`yyyy-MM-dd`) the counted event belongs to. Drives the deterministic
    /// threshold-crossing day used for award reset semantics — see `MilestoneEconomy.missingAwards`.
    public let dayKey: String
    public let createdAt: Date

    public init(id: String, kind: MilestoneEventKind, dayKey: String, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.dayKey = dayKey
        self.createdAt = createdAt
    }

    /// The deterministic row id for a counted event — the key to idempotent, sync-safe counting.
    /// `ref` is the counted thing's stable identity (entry/meal/workout UUID, worry UUID, or the
    /// dayKey for day-grain kinds like water).
    public static func eventID(kind: MilestoneEventKind, ref: String) -> String {
        "event:\(kind.rawValue):\(ref)"
    }

    public static func event(kind: MilestoneEventKind, ref: String, dayKey: String, at date: Date) -> MilestoneLedgerEntry {
        MilestoneLedgerEntry(id: eventID(kind: kind, ref: ref), kind: kind, dayKey: dayKey, createdAt: date)
    }
}

/// Pure aggregation + minting over milestone rows, and the bridge that turns lifetime counts into
/// idempotent coin awards. No state of its own — every value is a function of the rows, so any
/// device with the same rows computes the same counts and the same awards.
public nonisolated enum MilestoneEconomy {
    /// Cumulative lifetime thresholds. Purely additive celebration points — never a rate, never a
    /// window, never "in a row".
    public static let thresholds: [Int] = [1, 5, 10, 25, 40, 75, 100, 250, 500]

    /// Coins gifted per milestone reached. Flat and gentle — bigger milestones are not "worth more",
    /// because care isn't a payout curve.
    public static let coinsPerMilestone = 5

    /// Collapses rows that share an id, keeping the first seen — the application-level union-merge
    /// (the synced store can hold duplicate-id rows minted independently on two devices).
    /// Delegates to the shared `Array.deduplicatedByID()` (see `IdentityDedup.swift`).
    public static func deduplicatedByID(_ entries: [MilestoneLedgerEntry]) -> [MilestoneLedgerEntry] {
        entries.deduplicatedByID()
    }

    /// Lifetime count for one kind: the number of DISTINCT event rows. Monotonic by construction.
    public static func count(of kind: MilestoneEventKind, in entries: [MilestoneLedgerEntry]) -> Int {
        deduplicatedByID(entries).lazy.filter { $0.kind == kind }.count
    }

    /// All lifetime counts at once (kinds with no rows are 0).
    public static func lifetimeCounts(in entries: [MilestoneLedgerEntry]) -> [MilestoneEventKind: Int] {
        var counts = Dictionary(uniqueKeysWithValues: MilestoneEventKind.allCases.map { ($0, 0) })
        for entry in deduplicatedByID(entries) { counts[entry.kind, default: 0] += 1 }
        return counts
    }

    /// The deterministic coin-ledger row id for a milestone award — same id on every device, so the
    /// coin ledger's union-merge makes the award exactly-once (`milestone:journal:40`).
    public static func awardID(kind: MilestoneEventKind, threshold: Int) -> String {
        "milestone:\(kind.rawValue):\(threshold)"
    }

    /// Events the ledger SHOULD hold (derived from the surviving day history) — the idempotent
    /// backfill/reconcile input. Undercount is accepted and deliberate: history pruned or reset
    /// before this ran can't be re-derived, so lifetime counts start from what survives (they only
    /// ever grow from there — normal operation never deletes a row).
    ///
    /// Day-history kinds only (journal/meal/workout/water). Breathing + worry events are not in the
    /// diary and arrive exclusively through their live hooks.
    ///
    /// `excludingMealIDs` skips meals still pending AI resolution (queued in the retry service): an
    /// AI-fallback placeholder is replaced by a fresh-UUID resolved meal on retry, so counting the
    /// placeholder now AND the resolved meal later would count one logged meal twice (normal operation
    /// never deletes a row). Excluding the pending placeholder means only the resolved meal is ever
    /// counted, once.
    public static func derivedEvents(
        from days: [String: FernletDay],
        hydrationTarget: Int,
        excludingMealIDs: Set<UUID> = [],
        at date: Date
    ) -> [MilestoneLedgerEntry] {
        var events: [MilestoneLedgerEntry] = []
        for (dayKey, day) in days {
            for entry in day.journals {
                events.append(.event(kind: .journal, ref: entry.id.uuidString, dayKey: dayKey, at: date))
            }
            for meal in day.meals where !excludingMealIDs.contains(meal.id) {
                events.append(.event(kind: .meal, ref: meal.id.uuidString, dayKey: dayKey, at: date))
            }
            // HealthKit-imported workouts are passive data, not a deliberate log — excluded.
            for workout in day.workouts where workout.healthKitUUID == nil {
                events.append(.event(kind: .workout, ref: workout.id.uuidString, dayKey: dayKey, at: date))
            }
            if hydrationTarget > 0, day.bottleCount >= hydrationTarget {
                events.append(.event(kind: .water, ref: dayKey, dayKey: dayKey, at: date))
            }
        }
        return events.sorted { $0.id < $1.id }
    }

    /// The milestone coin awards that SHOULD exist for the current lifetime counts but don't yet —
    /// the idempotent delta a reconcile appends to the COIN ledger. Deterministic and sync-safe:
    ///   • Award ids are threshold-deterministic, so two devices crossing 40 offline mint one award.
    ///   • A threshold already REACHED as of the latest reset instant belongs to pre-reset milestone
    ///     coins that the reset zeroed — it is never (re-)minted here, and `CoinEconomy.totals` voids
    ///     any stale pre-reset award that re-syncs (createdAt <= reset). Since 2026-08-20 the wipe
    ///     also deletes the milestone EVENTS, but the milestone store has no reset-boundary marker,
    ///     so pre-reset events held by another signed-in device can sync back — this guard is what
    ///     keeps them from silently re-awarding coins with no user action. A threshold reached only
    ///     once POST-reset events are counted is a genuine new milestone and mints normally with a
    ///     post-reset `createdAt` that survives.
    public static func missingAwards(
        events: [MilestoneLedgerEntry],
        coinEntries: [CoinLedgerEntry],
        at date: Date
    ) -> [CoinLedgerEntry] {
        let deduped = deduplicatedByID(events)
        let existingCoinIDs = Set(coinEntries.map(\.id))
        let reset = CoinEconomy.latestReset(in: coinEntries)
        var awards: [CoinLedgerEntry] = []
        for kind in MilestoneEventKind.allCases {
            let rows = deduped
                .filter { $0.kind == kind }
                .sorted { ($0.dayKey, $0.id) < ($1.dayKey, $1.id) }
            // How many of this kind's events are pre-reset — thresholds up to this count were crossed
            // before the reset (their coins were zeroed) and must not be re-minted. An event is
            // pre-reset if its day is strictly before the reset day, OR it's on the reset day itself
            // but was created at/before the reset instant (this createdAt tiebreak is what catches the
            // same-day case dayKey alone can't: a threshold crossed earlier today, then "reset
            // everything"). A day AFTER the reset day is always post-reset. Order-independent (a
            // count, not a sorted position), so UUID sort order can't fool it.
            let preResetCount = reset.map { r in
                rows.reduce(0) { count, row in
                    let isPreReset: Bool
                    if let boundary = r.dayKey {
                        isPreReset = row.dayKey < boundary || (row.dayKey == boundary && row.createdAt <= r.createdAt)
                    } else {
                        isPreReset = row.createdAt <= r.createdAt
                    }
                    return count + (isPreReset ? 1 : 0)
                }
            } ?? 0
            for threshold in thresholds where threshold <= rows.count {
                guard threshold > preResetCount else { continue }
                let id = awardID(kind: kind, threshold: threshold)
                guard !existingCoinIDs.contains(id) else { continue }
                awards.append(CoinLedgerEntry(
                    id: id,
                    kind: .earn,
                    amount: coinsPerMilestone,
                    dayKey: rows[threshold - 1].dayKey,
                    createdAt: date
                ))
            }
        }
        return awards.sorted { $0.id < $1.id }
    }
}
