// IdentityDedup.swift
// The application-level union-merge primitive: collapse duplicate-id rows, keeping the first seen.
//
// Per-row synced stores can legitimately hold duplicate-id rows — `NSPersistentCloudKitContainer`
// mirrors by record identity and does not honor an id attribute as unique, so two devices minting
// the same deterministic row produce two distinct records. Every load and aggregate therefore
// collapses rows by id in code. This extension is the one shared implementation behind
// `CoinEconomy.deduplicatedByID`, `MilestoneEconomy.deduplicatedByID`, and the StoreCore per-row
// services' load paths.

import Foundation

extension Array where Element: Identifiable {
    /// Collapses elements that share an `id`, keeping the first seen and preserving order — the
    /// application-level union-merge for per-row synced stores (the storage layer does NOT
    /// de-duplicate; see `CoinEconomy` for the cross-device rationale).
    public func deduplicatedByID() -> [Element] {
        var seen = Set<Element.ID>()
        var unique: [Element] = []
        unique.reserveCapacity(count)
        for element in self where seen.insert(element.id).inserted { unique.append(element) }
        return unique
    }
}
