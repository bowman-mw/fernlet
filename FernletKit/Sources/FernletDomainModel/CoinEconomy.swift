// CoinEconomy.swift
// Custom-clothing feature, Increment 2 — the coin economy as an append-only LEDGER.
//
// Why a ledger (and not a derived counter): coins must be (a) monotonic on the earn side — turning
// HealthKit off or rolling past the 370-day day-storage cap must NOT take coins away — and (b)
// sync-correct on the spend side — two devices spending offline must not let the user spend the same
// coins twice. A value derived live from the (shrinkable, last-writer-wins) day history + settings can
// give neither. So earning and spending are recorded as individual `CoinLedgerEntry` rows in a per-row,
// union-merged synced store (see `CoinLedgerRepositoring`), and the balance is their aggregate.
//
// Idempotency is structural, not stateful:
//   • An `earn` row's id is DETERMINISTIC from its day (`earn:<dayKey>`), so two devices that both see
//     the same active day mint the SAME id → the union-merge collapses them to one row → never double
//     granted, even if a long-pruned day re-syncs later.
//   • A `spend` row's id is derived from a caller-supplied reference (`spend:<ref>`), so a retried buy
//     re-applies the same id and can't debit twice.
//
// Wall-safe: pure value types + math in `FernletDomainModel`, never a `Private*` store (S3 wall).

import Foundation
import FernletFoundation

/// Forward-compat contract (deliberately NOT the freeze-and-park pattern used elsewhere): the
/// ledger rows live in a per-row store, so a `kind` raw value only a NEWER build knows makes just
/// that ONE row fail decode and be skipped (`CoinLedgerRepository.entry(from:)` is a per-row
/// `try?`; `load()` compactMaps the failures away) — nothing cascades and nothing is deleted.
/// Rows are append-only and union-merged by id across devices, so the newer device keeps its row
/// and a re-sync restores it here after this build upgrades. The cost: while builds are mixed, the
/// older build under-counts the balance by the rows it can't decode — any new kind must accept
/// that until every device is updated. `MilestoneEventKind` documents the same contract for the
/// milestone ledger.
public nonisolated enum CoinLedgerKind: String, Codable, Sendable, CaseIterable {
    /// Coins granted for an active day (a day with logged content). One per calendar day, ever.
    case earn
    /// Coins debited for a purchase (Increment 3). Amount is the item price.
    case spend
    /// A "reset all data" boundary. Carries no coins (amount 0); its `dayKey`/`createdAt` void every earn for
    /// a day STRICTLY BEFORE the reset day and every spend created at or before it, so a full reset zeroes the
    /// balance in an append-only, sync-safe way — another device can't undo the reset by deterministically
    /// re-minting earns for pre-reset days. The reset day itself stays earnable (its content is wiped by the
    /// reset), so same-day-as-reset activity accrues normally.
    case reset
}

/// One immutable line in the coin ledger. Rows are append-only and union-merge across devices by `id`.
public nonisolated struct CoinLedgerEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: CoinLedgerKind
    public let amount: Int
    /// The active day this `earn` row credits (`yyyy-MM-dd`). Nil for `spend`.
    public let dayKey: String?
    /// The caller's idempotency reference for a `spend` (e.g. the purchased item id). Nil for `earn`.
    public let spendRef: String?
    public let createdAt: Date

    public init(id: String, kind: CoinLedgerKind, amount: Int, dayKey: String? = nil, spendRef: String? = nil, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.amount = amount
        self.dayKey = dayKey
        self.spendRef = spendRef
        self.createdAt = createdAt
    }

    /// The deterministic row id for a day's earn entry — the key to idempotent, sync-safe earning.
    public static func earnID(dayKey: String) -> String { "earn:\(dayKey)" }

    /// The deterministic row id for a spend keyed by `ref` — re-applying the same purchase is a no-op.
    public static func spendID(ref: String) -> String { "spend:\(ref)" }

    public static func earn(dayKey: String, amount: Int, at date: Date) -> CoinLedgerEntry {
        CoinLedgerEntry(id: earnID(dayKey: dayKey), kind: .earn, amount: amount, dayKey: dayKey, createdAt: date)
    }

    public static func spend(ref: String, amount: Int, at date: Date) -> CoinLedgerEntry {
        CoinLedgerEntry(id: spendID(ref: ref), kind: .spend, amount: amount, spendRef: ref, createdAt: date)
    }

    /// A reset boundary marker. `dayKey` is the reset day (`yyyy-MM-dd`); every earn for a day STRICTLY BEFORE
    /// it and every spend created at/ before `createdAt` is voided (the reset day itself stays earnable — its
    /// content is wiped by the reset). The id embeds the reset instant so distinct resets stay distinct rows
    /// under the union-merge.
    public static func resetID(at date: Date) -> String { "reset:\(date.timeIntervalSince1970)" }

    public static func reset(dayKey: String, at date: Date) -> CoinLedgerEntry {
        CoinLedgerEntry(id: resetID(at: date), kind: .reset, amount: 0, dayKey: dayKey, createdAt: date)
    }
}

/// Pure aggregation + minting over a set of ledger entries. No state of its own — every value is a
/// function of the rows, so any device with the same rows computes the same balance.
///
/// The cross-device "union-merge" is performed HERE, in code — NOT by the storage layer. Two devices
/// that independently mint the same deterministic row (e.g. `earn:<dayKey>`) produce two *distinct*
/// CloudKit records (`NSPersistentCloudKitContainer` mirrors by record identity and does not honor the
/// `idString` attribute as unique), so the synced store can legitimately hold duplicate-id rows. Every
/// aggregate therefore collapses rows by id first — that collapse is what actually delivers idempotent,
/// double-grant-free coins.
public nonisolated enum CoinEconomy {
    /// Coins earned per active day. Tunable; gentle and cumulative (never a streak).
    public static let coinsPerActiveDay = 5

    /// Collapses rows that share an id, keeping the first seen — the application-level union-merge.
    public static func deduplicatedByID(_ entries: [CoinLedgerEntry]) -> [CoinLedgerEntry] {
        var seen = Set<String>()
        var unique: [CoinLedgerEntry] = []
        unique.reserveCapacity(entries.count)
        for entry in entries where seen.insert(entry.id).inserted { unique.append(entry) }
        return unique
    }

    /// The most recent reset boundary among the rows, or nil if the ledger was never reset.
    public static func latestReset(in entries: [CoinLedgerEntry]) -> CoinLedgerEntry? {
        entries.filter { $0.kind == .reset }.max { $0.createdAt < $1.createdAt }
    }

    /// Earned/spent totals over the id-collapsed rows. The single place the dedup-then-sum happens. Any earn
    /// for a day STRICTLY BEFORE the latest reset boundary day, and any spend created at/ before it, is voided
    /// — so a reset zeroes the balance even if a pre-reset row lingers or re-syncs from an offline device, and
    /// even if another device deterministically re-mints a pre-reset earn (same `dayKey < boundary` → still
    /// void). The reset DAY itself is NOT voided: a soft reset wipes that day's logged content (see
    /// `FernletStore.resetAll` / `DiaryStore.resetDiary` — the reset day is today, replaced with an empty
    /// `FernletDay`), so `earn:<resetDay>` only re-mints once the user logs genuinely post-reset activity on
    /// that day, and same-day-as-reset activity can earn normally instead of being permanently locked out.
    public static func totals(in entries: [CoinLedgerEntry]) -> (earned: Int, spent: Int) {
        let deduped = deduplicatedByID(entries)
        let reset = latestReset(in: deduped)
        return deduped.reduce(into: (earned: 0, spent: 0)) { totals, entry in
            switch entry.kind {
            case .earn:
                if let reset {
                    if entry.id.hasPrefix("milestone:") {
                        // Milestone AWARD earns (`milestone:<kind>:<threshold>`, see `MilestoneEconomy`)
                        // are voided by the reset INSTANT like spends (createdAt-based), NOT by dayKey:
                        // an award minted post-reset carries a post-reset createdAt and survives, while a
                        // stale pre-reset award re-synced from an offline device carries a pre-reset
                        // createdAt and is voided — so a full reset zeroes milestone coins too, even
                        // though the milestone EVENTS themselves deliberately survive.
                        if entry.createdAt <= reset.createdAt { return }
                    } else if let boundary = reset.dayKey, let day = entry.dayKey, day < boundary {
                        // Active-day earns: void days STRICTLY BEFORE the reset day (the reset day stays earnable).
                        return
                    }
                }
                totals.earned += max(0, entry.amount)
            case .spend:
                if let resetAt = reset?.createdAt, entry.createdAt <= resetAt { return }
                totals.spent += max(0, entry.amount)
            case .reset:
                break
            }
        }
    }

    /// Coins granted specifically by milestone AWARD earns (`milestone:*`), reset-aware — voided by
    /// the same createdAt rule `totals` applies to milestone earns, so this can never disagree with
    /// the wallet after a reset (a stale pre-reset award re-synced from an offline device is excluded).
    public static func milestoneAwardCoins(in entries: [CoinLedgerEntry]) -> Int {
        let deduped = deduplicatedByID(entries)
        let reset = latestReset(in: deduped)
        return deduped.reduce(0) { sum, entry in
            guard entry.kind == .earn, entry.id.hasPrefix("milestone:") else { return sum }
            if let reset, entry.createdAt <= reset.createdAt { return sum }
            return sum + max(0, entry.amount)
        }
    }

    public static func earned(in entries: [CoinLedgerEntry]) -> Int { totals(in: entries).earned }

    public static func spent(in entries: [CoinLedgerEntry]) -> Int { totals(in: entries).spent }

    /// Spendable balance: earned − spent, floored at zero. The floor is defensive: with the local spend
    /// guard it never goes negative on one device, but two devices spending the same coins offline both
    /// land distinct `spend` rows (correctly summed), so the floor is what keeps a transient cross-device
    /// over-spend from showing a negative balance. (Bounded over-acquisition across devices is inherent
    /// without a server and is accepted; see `CoinLedgerService.spend`.)
    public static func balance(in entries: [CoinLedgerEntry]) -> Int {
        let t = totals(in: entries)
        return max(0, t.earned - t.spent)
    }

    /// Whether `amount` coins can be spent against the current rows.
    public static func canSpend(amount: Int, in entries: [CoinLedgerEntry]) -> Bool {
        amount > 0 && balance(in: entries) >= amount
    }

    /// The set of day keys already credited by an ACTIVE-DAY `earn` row (`earn:<dayKey>`).
    ///
    /// Matched by the deterministic active-day id, not by `kind == .earn` alone: milestone awards
    /// (`milestone:<kind>:<threshold>`, see `MilestoneEconomy`) are also earn rows and carry their
    /// threshold-crossing day as `dayKey` (so the reset boundary voids them like any earn) — but a
    /// milestone award for a day must NOT make `missingEarnEntries` think that day's 5 active-day
    /// coins were already minted.
    public static func earnedDayKeys(in entries: [CoinLedgerEntry]) -> Set<String> {
        Set(entries.compactMap { entry in
            guard entry.kind == .earn, let dayKey = entry.dayKey,
                  entry.id == CoinLedgerEntry.earnID(dayKey: dayKey) else { return nil }
            return dayKey
        })
    }

    /// The earn entries that SHOULD exist for `activeDayKeys` but don't yet — i.e. the idempotent delta a
    /// reconcile appends. Sorted for determinism. Re-running with the same inputs returns nothing new.
    public static func missingEarnEntries(activeDayKeys: Set<String>, existing: [CoinLedgerEntry], at date: Date) -> [CoinLedgerEntry] {
        // Don't re-mint earns for days STRICTLY BEFORE the latest reset boundary day: those days were wiped
        // by a reset, and minting them (with a fresh, post-reset timestamp) is exactly how another device's
        // reconcile would otherwise undo the reset and inflate the balance. The reset day itself IS
        // re-mintable: a soft reset empties that day's content (the reset day is today, replaced with a fresh
        // `FernletDay`), so it re-enters `activeDayKeys` only when the user logs genuine post-reset activity —
        // and voiding it here would permanently lock out same-day-as-reset earning (matching the `< boundary`
        // void in `totals`).
        let resetBoundary = latestReset(in: existing)?.dayKey
        // Never mint for a day in the FUTURE. Active days come from `hasLoggedContent`, which now counts
        // a plan-only day (`plannedRecipeIDs`, F3) — and plans (like `plannedWorkouts` before them) can be
        // placed on future dates. Reconcile runs over every stored row on each launch/foreground, so an
        // uncapped mint would let a user plan meals/workouts N days forward and farm `coinsPerActiveDay`
        // per future day (unplanning never revokes it — the earn row is append-only and keyed off the day,
        // not its current content). Clamp to `<= today` (lexicographic `yyyy-MM-dd` compare == chronological)
        // so only days that have actually arrived can accrue.
        let today = FernletDate.dayKey(for: date)
        return activeDayKeys
            .subtracting(earnedDayKeys(in: existing))
            .filter { resetBoundary == nil || $0 >= resetBoundary! }
            .filter { $0 <= today }
            .sorted()
            .map { CoinLedgerEntry.earn(dayKey: $0, amount: coinsPerActiveDay, at: date) }
    }
}
