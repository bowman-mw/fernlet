// MilestoneLedger.swift
// Cumulative care milestones — an append-only LEDGER of counted care events, mirroring the coin
// ledger's proven shape (see CoinEconomy.swift + Docs/Coin-Ledger-Design-2026-06-29.md).
//
// Why its own store (and not new kinds inside the coin ledger): the two have deliberately DIFFERENT
// reset MECHANISMS — though since 2026-08-21 they share the marker half. Coins are spendable
// currency and a full "reset all data" zeroes them via an in-band reset-boundary marker row that
// voids pre-reset rows sync-safely, deleting nothing. Milestone events reset by row DELETION AND a
// marker: since 2026-08-20 the wipe clears the ledger (`MilestoneLedgerRepository.deleteAll()`,
// reached only through the deletion funnel — the protocol still exposes no delete; see
// `MilestoneLedgerRepositoring`), reversing the earlier product rule that milestone counts survive
// a reset — the rows are a dated metadata trail of the very content the wipe destroys — and since
// 2026-08-21 the same reset APPENDS a `resetBoundary` row, so event rows another signed-in device
// was still holding when it went offline cannot resurrect the dated trail by syncing back after the
// delete. That gap was the whole reason to build this: a delete alone is not sync-safe.
//
// The boundary RULE here is BOTH halves at once: a row counts only if its `dayKey` is at or after
// the marker's day AND its `createdAt` is strictly after the marker's instant. The instant alone was
// tried first and leaked — milestone rows are also DERIVED from the day history and stamped with the
// reconcile's own clock, so a pre-wipe day re-synced from a device that was offline at the wipe
// (days keep no tombstones, by product decision) minted rows that were post-boundary by
// construction, and the dated trail came back through days even though every re-synced ROW was
// voided. The day half is what says which side of the wipe the counted THING belongs to, whoever
// minted the row and whatever their clock said; the instant half is what catches a threshold crossed
// earlier on the wipe day. The marker's `dayKey` is therefore LOAD-BEARING, not decoration.
//
// Coins carry the same two halves split across row kinds (day-grain for active-day earns, instant
// for spends and milestone awards; see `CoinEconomy.totals`) — which is exactly why folding the two
// stores into `CoinEconomy` would force one type to carry two rules.
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
//     event rows held by another signed-in device can sync back and must not re-award coins. Since
//     2026-08-21 the milestone side voids those rows FIRST (the `resetBoundary` marker below), so
//     the coin-side guard is now the second of two independent defenses rather than the only one —
//     still load-bearing for any row set that carries a coin reset but no milestone marker.
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
    /// NOT a care event: the "delete everything" boundary row appended by
    /// `MilestoneLedgerService.reset(deletingRowsWith:)`, mirroring `CoinLedgerKind.reset`. It is
    /// the wipe's zero-the-counts row — **never counted, never displayed, never awarded** — and
    /// ``MilestoneEconomy/countedEvents(in:)`` voids every event row on the wrong side of it (day
    /// before the marker's day, or created at/before its instant), which is what stops rows a second
    /// signed-in device still holds from resurrecting the dated trail when they sync back.
    ///
    /// Old-build behavior, accepted deliberately (owner decision, 2026-08-21): a build that predates
    /// this raw value drops just the marker row at decode (the per-row `try?` documented above), so
    /// its counts are un-voided until it updates. What it keeps is NOT "its pre-reset rows" wholesale
    /// — the wipe's delete is object-by-object through the CloudKit mirror, so it propagates to that
    /// device whatever build it runs; what survives there is only rows the delete never reached
    /// (minted or held offline). The wiped device is unaffected either way — its own aggregation
    /// voids everything pre-boundary — and the old device self-heals the moment it updates and
    /// re-reads the marker.
    ///
    /// Known ceiling, shared with the coin marker and not fixed this round: a marker stamped by a
    /// badly future-set device clock voids every event until that future instant. Inherent to an
    /// instant-based boundary without a trusted clock.
    case resetBoundary
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

    /// The deterministic row id for a reset boundary — `reset:<instant>`, mirroring
    /// `CoinLedgerEntry.resetID(at:)`. The instant is in the id so two distinct resets stay two
    /// distinct rows under the union-merge, and the `reset:` prefix can never collide with an event
    /// row: those are `event:<kind>:<ref>` for every kind and every caller-supplied `ref`.
    public static func resetBoundaryID(at date: Date) -> String { "reset:\(date.timeIntervalSince1970)" }

    /// The wipe's zero-the-counts row: it counts nothing, awards nothing and is never displayed —
    /// it VOIDS everything before it. `MilestoneEconomy` counts an event row only when its `dayKey`
    /// is at or after this row's day AND its `createdAt` is strictly after this row's instant, so a
    /// pre-wipe row that re-syncs from a device that was offline at the wipe raises no lifetime
    /// count and mints no milestone coin.
    ///
    /// **Both fields are load-bearing.** `dayKey` should be the wipe's own day
    /// (`FernletDate.dayKey(for: date)` — what `MilestoneLedgerService.reset(deletingRowsWith:)`
    /// passes): it is what voids rows RE-DERIVED from a re-synced day, which carry a fresh
    /// reconcile-time `createdAt` and so cannot be caught by the instant. `createdAt` is what voids a
    /// threshold crossed earlier on the wipe day itself. A marker built with some other day would
    /// silently move the boundary — write the wipe day, always.
    public static func resetBoundary(dayKey: String, at date: Date) -> MilestoneLedgerEntry {
        MilestoneLedgerEntry(id: resetBoundaryID(at: date), kind: .resetBoundary, dayKey: dayKey, createdAt: date)
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

    /// Every kind that COUNTS: all cases except the `resetBoundary` marker, in declaration order.
    ///
    /// Iterate this — never `MilestoneEventKind.allCases` — anywhere a kind is counted, seeded into
    /// a counts dictionary, awarded a coin, or DRAWN. The marker is the wipe's bookkeeping row, so
    /// an `allCases` seed would publish a `[.resetBoundary: 0]` count and an `allCases` shelf would
    /// put a keepsake for "you deleted everything" on Home.
    public static let countedKinds: [MilestoneEventKind] = MilestoneEventKind.allCases.filter { $0 != .resetBoundary }

    /// Collapses rows that share an id, keeping the first seen — the application-level union-merge
    /// (the synced store can hold duplicate-id rows minted independently on two devices).
    /// Delegates to the shared `Array.deduplicatedByID()` (see `IdentityDedup.swift`).
    public static func deduplicatedByID(_ entries: [MilestoneLedgerEntry]) -> [MilestoneLedgerEntry] {
        entries.deduplicatedByID()
    }

    /// The most recent reset boundary among the rows, or nil if the ledger was never wiped on any
    /// device — the mirror of `CoinEconomy.latestReset(in:)`.
    public static func latestReset(in entries: [MilestoneLedgerEntry]) -> MilestoneLedgerEntry? {
        entries.filter { $0.kind == .resetBoundary }.max { $0.createdAt < $1.createdAt }
    }

    /// The rows that count, in ONE place: id-collapsed (the union-merge), marker rows removed, and
    /// every event row on the wrong side of the latest boundary voided.
    ///
    /// **The rule, both halves.** A row counts only when its `dayKey` is at or after the boundary's
    /// day AND its `createdAt` is strictly after the boundary's instant. Either half alone leaks:
    ///   • Instant alone leaked through the DAY history. Rows are also DERIVED from days
    ///     (``derivedEvents(from:hydrationTarget:ledgerEntries:excludingMealIDs:at:)``) and stamped
    ///     with the reconcile's own `Date()`, so a pre-wipe day re-synced from a device that was
    ///     offline at the wipe (days keep no tombstones — the delete dialog discloses this) minted
    ///     fresh rows that were post-boundary *by construction*. The dated trail came back through
    ///     days even though every re-synced ledger ROW was voided. The day half voids them whatever
    ///     build or device minted them, and also covers cross-device clock skew.
    ///   • Day alone would let a threshold crossed earlier on the wipe day survive a wipe later the
    ///     same day (the case the coin ledger's own createdAt tiebreak exists for).
    /// This is the coin ledger's `CoinEconomy.totals` idiom, applied to one row type instead of two.
    ///
    /// **Accepted grain, identical to coins' `earn:<resetDay>`:** the wipe DAY itself stays
    /// countable, so same-day pre-wipe content re-synced from another device can re-derive and count
    /// (see `derivedEvents`, which mirrors this on the mint side). Voiding the wipe day instead would
    /// permanently lock out genuine post-wipe care on the day the user wiped — the same trade
    /// `CoinEconomy` documents for the reset day's earn, made the same way.
    ///
    /// Dedup runs FIRST, so when the same deterministic id exists on both sides of the boundary the
    /// older row wins and the pair is voided. That is reachable only for the day-grain kind: a
    /// hydration day met before a wipe and met AGAIN later the same day, whose pre-wipe
    /// `event:water:<dayKey>` row syncs back from another device. The cost is one uncounted water day
    /// on the day of a wipe; the alternative (letting the newer row win) would hand every re-synced
    /// pre-wipe row a way back in. Undercount toward the wipe, never resurrection — the same
    /// direction `derivedEvents` already accepts for pruned history.
    public static func countedEvents(in entries: [MilestoneLedgerEntry]) -> [MilestoneLedgerEntry] {
        let deduped = deduplicatedByID(entries)
        let events = deduped.filter { $0.kind != .resetBoundary }
        guard let boundary = latestReset(in: deduped) else { return events }
        return events.filter { $0.dayKey >= boundary.dayKey && $0.createdAt > boundary.createdAt }
    }

    /// Lifetime count for one kind: the number of DISTINCT post-boundary event rows. Monotonic
    /// between wipes by construction; `.resetBoundary` always counts 0 (it is not a care event).
    public static func count(of kind: MilestoneEventKind, in entries: [MilestoneLedgerEntry]) -> Int {
        countedEvents(in: entries).lazy.filter { $0.kind == kind }.count
    }

    /// All lifetime counts at once (kinds with no rows are 0). Keyed by ``countedKinds``, so the
    /// marker kind never appears — not even as a zero.
    public static func lifetimeCounts(in entries: [MilestoneLedgerEntry]) -> [MilestoneEventKind: Int] {
        var counts = Dictionary(uniqueKeysWithValues: countedKinds.map { ($0, 0) })
        for entry in countedEvents(in: entries) { counts[entry.kind, default: 0] += 1 }
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
    ///
    /// `ledgerEntries` is the ledger's CURRENT rows, and it is deliberately NOT defaulted: it exists
    /// only to locate the reset boundary, and a caller that forgot it would re-mint rows for wiped
    /// days — the exact defect this parameter was added to close (2026-08-21). Days STRICTLY BEFORE
    /// the boundary day are skipped, so the ledger never accumulates rows the aggregation would only
    /// void; the wipe DAY itself stays derivable, matching `CoinEconomy.missingEarnEntries`'
    /// `dayKey >= resetBoundary` mint filter and the same accepted grain
    /// (``countedEvents(in:)`` documents it): same-day pre-wipe content re-synced from another device
    /// can re-derive and count, because locking the wipe day out would also lock out genuine
    /// post-wipe care on the day the user wiped.
    public static func derivedEvents(
        from days: [String: FernletDay],
        hydrationTarget: Int,
        ledgerEntries: [MilestoneLedgerEntry],
        excludingMealIDs: Set<UUID> = [],
        at date: Date
    ) -> [MilestoneLedgerEntry] {
        // The mint-side half of the boundary. Rows minted here carry `date` (now) as their
        // `createdAt`, so a day re-synced from a device that was offline at the wipe would otherwise
        // produce rows that are post-boundary by construction and could not be voided by instant.
        // `?? ""` is the never-reset case: every dayKey sorts at or after the empty string.
        let boundaryDay = latestReset(in: ledgerEntries)?.dayKey ?? ""
        var events: [MilestoneLedgerEntry] = []
        for (dayKey, day) in days where dayKey >= boundaryDay {
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
    ///   • Only rows on the right side of the milestone ledger's own latest `resetBoundary` are even
    ///     considered (``countedEvents(in:)`` — day at/after the boundary day AND created strictly
    ///     after its instant): a pre-wipe event row re-synced from a device that was offline at the
    ///     wipe, or RE-DERIVED from a day that came back, raises no count — so it can never carry a
    ///     threshold and can never re-mint the `milestone:<kind>:<n>` coin row that goes with it.
    ///     The day half of that filter is what makes this true for re-derived rows, whose fresh
    ///     reconcile-time `createdAt` would otherwise sail past both this and the coin guard below.
    ///   • A threshold already REACHED as of the latest COIN reset instant belongs to pre-reset
    ///     milestone coins that the reset zeroed — it is never (re-)minted here, and
    ///     `CoinEconomy.totals` voids any stale pre-reset award that re-syncs (createdAt <= reset).
    ///     Since 2026-08-21 the milestone filter above usually empties `rows` of those events before
    ///     this guard ever sees them, which makes it the SECOND of two independent defenses rather
    ///     than the only one — and it is still load-bearing on its own for a row set that carries a
    ///     coin reset but no milestone marker (an old build that dropped the marker at decode, or a
    ///     wipe whose milestone marker append failed and is still queued). A threshold reached only
    ///     once POST-reset events are counted is a genuine new milestone and mints normally with a
    ///     post-reset `createdAt` that survives.
    public static func missingAwards(
        events: [MilestoneLedgerEntry],
        coinEntries: [CoinLedgerEntry],
        at date: Date
    ) -> [CoinLedgerEntry] {
        let deduped = countedEvents(in: events)
        let existingCoinIDs = Set(coinEntries.map(\.id))
        let reset = CoinEconomy.latestReset(in: coinEntries)
        var awards: [CoinLedgerEntry] = []
        for kind in countedKinds {
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
            //
            // Since 2026-08-21 `rows` has ALREADY had every row at/before the milestone ledger's own
            // boundary removed, so after an ordinary wipe this count is 0 and the guard is inert —
            // which is the intended shape: the milestone marker is the primary defense and this is
            // the backstop for row sets that carry a coin reset without a milestone marker (an old
            // build that dropped the marker at decode; a marker whose append failed and is still
            // queued). It is deliberately NOT relaxed on that account: two independent voids of the
            // same coin cost nothing, and either one alone must be sufficient.
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
