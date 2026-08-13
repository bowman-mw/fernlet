import SwiftUI
import FernletDomainModel

/// The three ways `store.listCustomItemForSale` can refuse a listing, as alert cases.
///
/// In every case the item itself was already saved (just left unlisted) — the alerts say so.
/// Shared by ``CreationStudioView``'s confirmation step and ``WardrobeView``'s swipe-to-sell
/// path; the per-screen copy differences live in ``ShopAlert/alert(in:)``, keyed by
/// ``ShopAlertContext``.
enum ShopAlert: Identifiable {
    /// The chosen shop name failed moderation; the item stays saved but unlisted.
    case nameFlagged
    /// The shop already holds `ClothingShopLimits.maxListedItems` items.
    case capReached
    /// The shop is temporarily closed because shared items were reported.
    case storeBanned

    /// Stable identity for `.alert(item:)` presentation.
    var id: Int {
        switch self {
        case .nameFlagged: 0
        case .capReached: 1
        case .storeBanned: 2
        }
    }
}

/// Which screen is presenting a ``ShopAlert`` — the refusal copy points the user at the fix
/// path that exists on that screen.
enum ShopAlertContext {
    /// ``CreationStudioView``'s naming + shop-listing confirmation step. A refused listing
    /// deliberately does NOT dismiss — the user stays on this screen, where the name field
    /// lives, to rename and retry; the copy also reassures that the just-saved item is kept.
    case studioConfirmation
    /// ``WardrobeView``'s swipe "Sell" action. This screen has no name field, so the fix path
    /// is "rename it in the editor".
    case wardrobe
}

extension ShopAlert {
    /// The alert for this refusal as presented from `context`, with the exact per-screen copy
    /// each screen has always shown (full string literals, so the `LocalizedStringKey` `Text`
    /// init is preserved).
    func alert(in context: ShopAlertContext) -> Alert {
        switch (self, context) {
        case (.nameFlagged, .studioConfirmation):
            return Alert(
                title: Text("Pick a friendlier name"),
                message: Text("This name can't be used in your shop. Your item is saved — rename it and try listing again. (Private items can be named anything.)"),
                dismissButton: .default(Text("OK"))
            )
        case (.nameFlagged, .wardrobe):
            return Alert(
                title: Text("Pick a friendlier name"),
                message: Text("This name can't be used in your shop. Rename it in the editor, then list it again. (Private items can be named anything.)"),
                dismissButton: .default(Text("OK"))
            )
        case (.capReached, .studioConfirmation):
            return Alert(
                title: Text("Your shop is full"),
                message: Text("You can list up to \(ClothingShopLimits.maxListedItems) items at once. Unlist one to make room. Your item is saved and ready whenever you are."),
                dismissButton: .default(Text("OK"))
            )
        case (.capReached, .wardrobe):
            return Alert(
                title: Text("Your shop is full"),
                message: Text("You can list up to \(ClothingShopLimits.maxListedItems) items at once. Unlist one to make room."),
                dismissButton: .default(Text("OK"))
            )
        case (.storeBanned, _):
            return Alert(
                title: Text("Your shop is closed"),
                message: Text("Your shop is paused because items you shared were reported. It reopens automatically after a while — your items are still saved."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}
