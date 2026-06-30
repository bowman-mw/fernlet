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

public nonisolated enum CoinLedgerKind: String, Codable, Sendable, CaseIterable {
    /// Coins granted for an active day (a day with logged content). One per calendar day, ever.
    case earn
    /// Coins debited for a purchase (Increment 3). Amount is the item price.
    case spend
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

    /// Earned/spent totals over the id-collapsed rows. The single place the dedup-then-sum happens.
    public static func totals(in entries: [CoinLedgerEntry]) -> (earned: Int, spent: Int) {
        deduplicatedByID(entries).reduce(into: (earned: 0, spent: 0)) { totals, entry in
            switch entry.kind {
            case .earn: totals.earned += max(0, entry.amount)
            case .spend: totals.spent += max(0, entry.amount)
            }
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

    /// The set of day keys already credited by an `earn` row.
    public static func earnedDayKeys(in entries: [CoinLedgerEntry]) -> Set<String> {
        Set(entries.compactMap { $0.kind == .earn ? $0.dayKey : nil })
    }

    /// The earn entries that SHOULD exist for `activeDayKeys` but don't yet — i.e. the idempotent delta a
    /// reconcile appends. Sorted for determinism. Re-running with the same inputs returns nothing new.
    public static func missingEarnEntries(activeDayKeys: Set<String>, existing: [CoinLedgerEntry], at date: Date) -> [CoinLedgerEntry] {
        activeDayKeys
            .subtracting(earnedDayKeys(in: existing))
            .sorted()
            .map { CoinLedgerEntry.earn(dayKey: $0, amount: coinsPerActiveDay, at: date) }
    }
}
