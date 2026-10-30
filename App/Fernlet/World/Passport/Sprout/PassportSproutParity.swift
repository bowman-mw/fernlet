import Foundation

/// `ps-parity` as data (World-Passport-Spec §4, approved 2026-10-30): every action the close-up, Customize and the
/// shop offered, and the page-1 action that is its new home. Nothing may lose its home: `PassportSproutPageTests`
/// checks every one is in ``PassportSproutModel/actions``. Display-only items (the name, the hearts, the previews)
/// and the items that moved off page 1 (the Wardrobe's line, ✕, Customize from Today) are in the lane's notes.
nonisolated enum PassportSproutParity {
    /// One action of today's screens and its home on page 1.
    struct Row: Sendable {
        /// What it was, for a failing test's message.
        let item: StaticString
        /// The page-1 actions that replace it.
        let actions: [PassportSproutAction]
    }

    /// The close-up (`ref-comp-close`, `ref-comp-react`, `ref-comp-home-add`, `ref-comp-home-at`).
    static let closeUp: [Row] = [
        Row(item: "Tap to pet (the reactions)", actions: [.pet]),
        Row(item: "This is home (away from a home)", actions: [.thisIsHome]),
        Row(item: "Manage (at a home or the hotel)", actions: [.manageHomes]),
        Row(item: "Customize (the button, the hold)",
            actions: CustomizeSlot.allCases.map { .slot($0) } + [.wardrobe, .creationStudio, .appColors]),
    ]

    /// Customize (`b2-customize` and its slot pages).
    static let customize: [Row] = [
        Row(item: "Body, Accessory, Clothing, Side item", actions: CustomizeSlot.allCases.map { .slot($0) }),
        Row(item: "Wardrobe", actions: [.wardrobe]),
        Row(item: "Creation Studio", actions: [.creationStudio]),
        Row(item: "App colors", actions: [.appColors]),
    ]

    /// The shop (`b2-shop-editor`, `b2-friend-shop`, `b4-mem-home-shop`).
    static let shop: [Row] = [
        Row(item: "Your shop", actions: [.yourShop]),
        Row(item: "Friend shops, the hour after a session", actions: [.friendShops]),
    ]

    /// Every row.
    static var all: [Row] { closeUp + customize + shop }
}
