import Foundation

/// The Bodybuilding goal's Bathroom tile in the quick-log layout (World round 7, spec §5, `bb-bowel`).
///
/// Two pure rules, both on the six-tile layout:
/// - ``seatingBathroom(in:)`` is the one-time swap when the goal is chosen: Bathroom takes Care's
///   place, drawn right after Water (Meals, Water, Bathroom, Move, Sleep, Journal on the default six).
///   The app runs it once, behind `BodybuildingCalendarSettings.bathroomTileSeeded`, so a person who
///   swaps Care back in keeps their choice.
/// - ``hidingBathroom(_:)`` is the display rule while another goal is chosen: Care shows where the
///   Bathroom tile sits. Display only; the stored layout keeps Bathroom, so choosing Bodybuilding again
///   shows it again and nothing is deleted.
extension FernletShortcut {
    /// The layout with Bathroom in Care's place, right after Water (in Care's own slot when there is
    /// no Water tile). Unchanged when Bathroom is already there or when the person has no Care tile
    /// (their six are all their own choices, so nothing of theirs is pushed out).
    public static func seatingBathroom(in items: [FernletShortcut]) -> [FernletShortcut] {
        var result = normalizedQuickLog(items)
        guard !result.contains(.bathroom), let careIndex = result.firstIndex(of: .care) else { return result }
        result.remove(at: careIndex)
        let slot = result.firstIndex(of: .water).map { $0 + 1 } ?? careIndex
        result.insert(.bathroom, at: min(slot, result.count))
        return result
    }

    /// The layout as shown without the Bodybuilding goal: Care where Bathroom sits, or Bathroom simply
    /// left out when Care already has a tile of its own (the free slot then fills as usual).
    public static func hidingBathroom(_ items: [FernletShortcut]) -> [FernletShortcut] {
        guard let index = items.firstIndex(of: .bathroom) else { return items }
        var result = items
        if result.contains(.care) {
            result.remove(at: index)
        } else {
            result[index] = .care
        }
        return result
    }
}
