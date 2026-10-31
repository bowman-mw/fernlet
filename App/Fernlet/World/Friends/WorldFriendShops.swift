import FernletDomainModel
import FernletSocial
import Foundation
import ProximityKit

/// Whose shop is open (World Friends §3, screens 9–11, approved 2026-10-31): the one list of friends'
/// open shops that the gold button's count, Sprout's line on Home, the switcher's row in Friend shops
/// and the passport's Friend shops row all read, so the four never disagree.
///
/// Each friend's shop has its own hour after the hangout (``MeshClothingShop/openShops(at:)``, newest
/// hangout first). The list is empty in a decoy and while nearby clothing sharing is off, and it leaves
/// out a seller banned on this phone, as Friend shops always has.
enum WorldFriendShops {
    /// The shops Friend shops can show at `date`, newest hangout first.
    static func browsable(store: FernletStore, at date: Date) -> [MeshClothingShop.OpenShop] {
        guard !store.duressSessionActive, store.settings.allowNearbyClothingShares else { return [] }
        return store.meshFeatures.clothingShop.openShops(at: date)
            .filter { !store.isProximitySellerBanned(fingerprint: $0.catalog.senderFingerprint) }
    }

    /// The shops Home announces at `date`: the browsable ones, but none during a hangout, when the
    /// session button holds the gold button's corner (`b4-mem-home-shop`).
    static func open(store: FernletStore, at date: Date) -> [MeshClothingShop.OpenShop] {
        guard !store.meshNetworkManager.isInSession else { return [] }
        return browsable(store: store, at: date)
    }

    /// The seller's display name, sanitized with the SAME rule the store applies before persisting
    /// it (`DiaryStore.setKnownDesignerName`), so a hostile wire-claimed name — multi-kilobyte, or
    /// carrying bidi overrides — can neither render raw nor disagree with what is stored. The envelope's
    /// own `senderDisplayName` is the fallback, and it comes off the same wire, so it is sanitized too.
    static func sellerName(_ catalog: ProximityClothingCatalog) -> String {
        let name = ItemNameModeration.sanitizedName(catalog.payload.displayName)
        guard name.isEmpty else { return name }
        return ItemNameModeration.sanitizedName(catalog.senderDisplayName)
    }
}

/// What one closing moment does to Friend shops (`fr-shop-close`): the friends whose hours ended leave
/// the row, the page moves on if it was showing one of them, and one toast names them all — closures
/// that land together are said together, once.
struct WorldShopClosing: Equatable {
    /// The closed shops' sellers, in the row's order (newest hangout first).
    let closedNames: [String]
    /// How many shops are still open.
    let stillOpen: Int
    /// The shop the page shows now; nil shows the newest.
    let selectedID: String?

    /// The toast's sentence: nil when nothing closed, or when nothing is left open (the Album's pushed
    /// page then closes, and the passport's shows its "No shops right now" note).
    var toast: String? {
        guard stillOpen > 0 else { return nil }
        return WorldShopCopy.closed(names: closedNames, stillOpen: stillOpen)
    }

    /// The closing moment from the row as drawn (`before`) to the shops open at `now` (`after`).
    ///
    /// - Parameters:
    ///   - before: The row before the moment, newest hangout first.
    ///   - after: The shops still open, newest hangout first.
    ///   - selectedID: The shop the page showed; nil for the newest.
    ///   - now: The moment. Only a shop whose hour ended by then counts as closed (one that left the row
    ///     for another reason, a report, is not announced).
    static func step(before: [MeshClothingShop.OpenShop], after: [MeshClothingShop.OpenShop],
                     selectedID: String?, now: Date) -> WorldShopClosing {
        let open = Set(after.map(\.id))
        let closed = before.filter { !open.contains($0.id) && $0.window.expiresAt <= now }
        return WorldShopClosing(closedNames: closed.map { WorldFriendShops.sellerName($0.catalog) },
                                stillOpen: after.count,
                                selectedID: nextSelection(before: before, open: open, selectedID: selectedID))
    }

    /// The shop to show once `before` has lost every shop not in `open`: the one shown if it is still
    /// open; else the next one along the row; else the nearest before it; nil (the newest) without one.
    static func nextSelection(before: [MeshClothingShop.OpenShop], open: Set<String>, selectedID: String?) -> String? {
        guard let selectedID, let index = before.firstIndex(where: { $0.id == selectedID }) else { return nil }
        guard !open.contains(selectedID) else { return selectedID }
        if let next = before[(index + 1)...].first(where: { open.contains($0.id) }) { return next.id }
        return before[..<index].last(where: { open.contains($0.id) })?.id
    }
}

/// The words of "whose shop is open" (World Friends §3), English and the spec's Spanish in the app's
/// catalog; each count plurals through the catalog's plural variations.
enum WorldShopCopy {
    /// Sprout's line on Home (`fr-shop-line`), or nil with no shop open: "Sam's shop is open for a bit."
    /// for one; "Sam's and 7 more friends' shops are open for a bit." for more, Sam being the newest.
    static func sproutLine(_ shops: [MeshClothingShop.OpenShop]) -> String? {
        guard let newest = shops.first else { return nil }
        let name = WorldFriendShops.sellerName(newest.catalog)
        let others = shops.count - 1
        guard others > 0 else {
            return String(localized: "worldShop.line.one", defaultValue: "\(name)'s shop is open for a bit.",
                          comment: "World Home, the companion's speech while one friend's shop is open after a hangout; their name. Spanish: 'La tienda de Sam está abierta un rato.'")
        }
        return String(localized: "worldShop.line.more", defaultValue: "\(name)'s and \(others) more friends' shops are open for a bit.",
                      comment: "World Home, the companion's speech while several friends' shops are open; the newest friend's name, then how many more. Plural on the number (1: 'and 1 more friend's shops')")
    }

    /// The gold button's VoiceOver label: "Friend shops, 8 open."
    static func buttonSpoken(open: Int) -> String {
        String(localized: "worldShop.button.a11y", defaultValue: "Friend shops, \(open) open.",
               comment: "World Home, VoiceOver: the gold shop button, with how many friends' shops are open. Spanish plurals 'abierta/abiertas'")
    }

    /// A switcher chip's VoiceOver label: "Sam, 52 minutes left" (the selected trait adds "selected").
    static func chipSpoken(name: String, minutes: Int) -> String {
        String(localized: "worldShop.chip.a11y", defaultValue: "\(name), \(minutes) minutes left",
               comment: "Friend shops, VoiceOver: a friend's chip in the row of open shops; their name, then the minutes left in their shop's hour. Plural on the number (1: '1 minute left')")
    }

    /// The closing toast (`fr-shop-close`): "Kai's and Lu's shops have closed. 6 are still open."
    static func closed(names: [String], stillOpen: Int) -> String? {
        guard let first = names.first else { return nil }
        switch names.count {
        case 1:
            return String(localized: "worldShop.closed.one", defaultValue: "\(first)'s shop has closed. \(stillOpen) are still open.",
                          comment: "Friend shops, a toast as one friend's shop closes; their name, then how many shops are still open. Plural on the number (1: '1 is still open.')")
        case 2:
            return String(localized: "worldShop.closed.two", defaultValue: "\(first)'s and \(names[1])'s shops have closed. \(stillOpen) are still open.",
                          comment: "Friend shops, a toast as two friends' shops close together; their names, then how many shops are still open. Plural on the number (1: '1 is still open.')")
        default:
            return String(localized: "worldShop.closed.many", defaultValue: "\(first)'s and \(names.count - 1) more friends' shops have closed. \(stillOpen) are still open.",
                          comment: "Friend shops, a toast as three or more friends' shops close together; the first name, how many more, then how many shops are still open. Plural on both numbers")
        }
    }
}
