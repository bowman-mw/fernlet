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

    /// Build this device's broadcast shop catalog. Only the user's OWN designs (`designer.id == designerID`)
    /// that are marked shareable are listed, so a bought item can never be re-sold and provenance stays
    /// honest. Listing is capped at `ClothingShopLimits.maxListedItems`.
    static func catalog(
        forShareable items: [CustomizationItem],
        designerID: UUID,
        displayName: String
    ) -> ClothingCatalogPayload {
        let listed = items
            .filter { $0.isShareable && $0.designer.id == designerID }
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
