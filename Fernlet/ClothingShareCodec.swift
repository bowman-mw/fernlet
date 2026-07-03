import ProximityKit
import Foundation
import FernletDomainModel

/// Domain ⇄ wire bridge for the in-person clothing shop (Increment 3). Mirrors `RecipeShareCodec`.
///
/// The SEND side builds a `ClothingCatalogPayload` from the user's own shareable designs — capped,
/// deterministically ordered (so the signed envelope bytes are stable), and each item clamped via
/// `ClothingShopLimits.sanitizedForShop`. The RECEIVE side re-sanitizes every item before it is rendered,
/// stored, or bought — wire bytes are never trusted (`ItemGridTexture.sanitized`, price clamp, name
/// charset/length), exactly as the recipe codec sanitizes incoming recipes.
enum ClothingShareCodec {

    /// Build this device's broadcast shop catalog. Only the user's OWN designs — an item whose designer id
    /// is in `ownedDesignerIDs` (the whole set of ids this user has ever designed under, across their
    /// devices) — that are marked shareable are listed, so a bought item can never be re-sold and
    /// provenance stays honest. Filtering by the owned SET (not equality to the single, last-writer-wins
    /// `localDesignerID`) matches the listing predicate `FernletStore.isSelfDesigned`, so an item designed
    /// under a superseded-but-still-owned id — which counts against the shop cap and reads as "In your
    /// shop" — is actually broadcast, not silently dropped. Listing is capped at
    /// `ClothingShopLimits.maxListedItems`. `ownedDesignerIDs` defaults to just `{designerID}` for callers
    /// that have only the single broadcast id.
    static func catalog(
        forShareable items: [CustomizationItem],
        designerID: UUID,
        displayName: String,
        ownedDesignerIDs: Set<UUID>? = nil
    ) -> ClothingCatalogPayload {
        let owned = ownedDesignerIDs ?? [designerID]
        let listed = items
            .filter { $0.isShareable && owned.contains($0.designer.id) }
            .sorted(by: Self.deterministicOrder)
            .prefix(ClothingShopLimits.maxListedItems)
            .map { ClothingShopLimits.sanitizedForShop($0) }
        return ClothingCatalogPayload(
            designerID: designerID,
            displayName: displayName,
            items: Array(listed)
        )
    }

    /// Sanitize every item in a received catalog (defense-in-depth — the manager already sanitizes on
    /// receive). Safe to render and buy from. Items are de-duplicated by id and re-ordered deterministically.
    static func sanitizedItems(from payload: ClothingCatalogPayload) -> [CustomizationItem] {
        var seen = Set<UUID>()
        return payload.items
            .map { ClothingShopLimits.sanitizedForShop($0) }
            .filter { seen.insert($0.id).inserted }
            .sorted(by: Self.deterministicOrder)
    }

    /// Stable ordering by creation time then id, so two devices encode the same catalog to the same bytes.
    private static func deterministicOrder(_ lhs: CustomizationItem, _ rhs: CustomizationItem) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
