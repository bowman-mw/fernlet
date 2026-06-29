// CustomItemRepositoring.swift
// FernletPersistence
//
// The persistence contract for user-designed custom items, kept in its own per-row store separate from
// the snapshot blob so a large closet never bloats the frequently-written character/day state. Mirrors
// `SavedRecipeRepositoring`. The Core Data + iCloud implementation lives in `CloudKitSync`.

import Foundation
import FernletDomainModel

@MainActor
public protocol CustomItemRepositoring {
    func load() -> [CustomizationItem]
    func loadAsync() async -> [CustomizationItem]
    @discardableResult func save(_ items: [CustomizationItem]) -> Bool
}
