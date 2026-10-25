import Foundation
import FernletDomainModel

/// What the pixel companion wears, read the same way by every World picture of it and by the widget
/// (phone test W-06a, W-07 and lane 2 "wardrobe drawings on the map", 2026-10-25).
extension FernletStore {
    /// The Creation Studio pieces the companion wears: the equipped ones, or none while a decoy session
    /// is open, so a decoy draws the decoy companion only.
    var wornCustomItems: [CustomizationItem] {
        duressSessionActive ? [] : equippedCustomItems
    }

    /// The companion's look as the widget draws it: the appearance and the worn pieces, fitted to their
    /// boxes. The widget snapshot's `companionLook` (integrator: `currentWidgetSnapshot()` reads this).
    var widgetCompanionLook: WidgetSnapshot.CompanionLook {
        WidgetSnapshot.CompanionLook(appearance: settings.companionAppearance, items: wornCustomItems)
    }
}
