// ClothingShopLimits.swift
// FernletDomainModel
//
// Shared constants + a wire-boundary sanitizer for the in-person clothing shop (Increment 3). Pure and
// wall-safe so BOTH the proximity exchange manager (ProximityKit) and the app-layer codec can clamp an
// untrusted, peer-received item into a safe shape before it is rendered, stored, or bought.

import Foundation

public nonisolated enum ClothingShopLimits {
    /// Most items a single shop may broadcast at once (decision §2.1).
    public static let maxListedItems = 6
    /// Inclusive price bounds a seller may set, in coins (decision: 1–100).
    public static let minPrice = 1
    public static let maxPrice = 100

    /// Clamp a price into `[minPrice, maxPrice]`.
    public static func clampedPrice(_ price: Int) -> Int {
        min(maxPrice, max(minPrice, price))
    }

    /// Repair a (possibly untrusted) item for shop use, never throwing: fit the texture to its slot grid
    /// (clamping oversized dimensions and coercing out-of-range palette indices), sanitize the name
    /// (charset / length), and clamp the price. The item's `id` and `designer` are left untouched so
    /// provenance — "designed by <friend>" — travels intact. Mirrors `ItemGridTexture.sanitized()`'s
    /// never-trust-the-wire stance for every mutable field of the item.
    public static func sanitizedForShop(_ item: CustomizationItem) -> CustomizationItem {
        var copy = item
        copy.texture = item.texture.sanitized(maxCols: item.slot.gridCols, maxRows: item.slot.gridRows)
        copy.name = ItemNameModeration.sanitizedName(item.name)
        copy.price = clampedPrice(item.price)
        return copy
    }
}
