import FernletDomainModel
import Foundation

/// The Bodybuilding goal on the Log panel and Log meal (World bodybuilding spec §5–§6, `bb-bowel`,
/// `bb-free`; round 7 piece D).
///
/// - The Bathroom tile takes Care's place ONCE, the first time the goal is in force
///   (``seatBathroomTileIfNeeded()``, recorded in `bodybuildingCalendar.bathroomTileSeeded`); after that
///   the person's own Settings › Quick-log shortcuts choice wins, so Care swapped back in stays.
/// - Another goal hides the tile for display only (``visibleQuickLogItems``): Care shows in its place,
///   the stored layout keeps it, and choosing Bodybuilding again shows it again. Nothing is deleted.
/// - Log meal's Free meal tag is saved, sealed, for each meal the sheet logged
///   (``tagFreeMeals(_:loggedTo:)``).
///
/// Nothing is stored on the store itself; a decoy (duress) session seats nothing and keeps no tag.
extension FernletStore {
    /// Whether the Bathroom tile and the Free meal tag show: the Bodybuilding goal is chosen.
    var isBathroomTileAvailable: Bool { isBodybuildingCalendarOn }

    /// The six tiles the Log panel draws: the stored layout through the sensitive-surface gates and the
    /// Bodybuilding rule, display only.
    var visibleQuickLogItems: [FernletShortcut] {
        FernletShortcut.visibleQuickLog(settings.quickLogItems, visibility: sensitiveSurfaceVisibility,
                                        bathroomAvailable: isBathroomTileAvailable)
    }

    /// Puts the Bathroom tile in Care's place the first time the Bodybuilding goal is in force, then
    /// never again. Called where the goal is chosen and wherever the tiles are drawn or edited, so a
    /// goal that arrived another way (onboarding, a synced device) is seated the next time Log opens.
    /// A layout without Care is left as the person made it (the flag is still set).
    func seatBathroomTileIfNeeded() {
        guard isBodybuildingCalendarOn, !duressSessionActive, !bodybuildingCalendarSettings.bathroomTileSeeded else { return }
        let current = FernletShortcut.normalizedQuickLog(settings.quickLogItems)
        let seated = FernletShortcut.seatingBathroom(in: current)
        if seated != current { setQuickLogItems(seated) }
        var prefs = bodybuildingCalendarSettings
        prefs.bathroomTileSeeded = true
        bodybuildingCalendarSettings = prefs
    }

    /// Tags each meal Log meal just logged as a free meal on `dayKey` (today when nil), sealed with the
    /// body tallies. Untagged meals are left alone; a decoy keeps nothing.
    ///
    /// - Returns: The write results, one per meal, in order.
    @discardableResult
    func tagFreeMeals(_ meals: [Meal], loggedTo dayKey: String?) -> [BodyTallyWriteResult] {
        let day = dayKey ?? todayKey
        // Bounded: a day holds at most 20 free meals, so one save never tags more.
        return meals.prefix(20).map { setFreeMeal(true, mealID: $0.id, on: day) }
    }
}

#if DEBUG
extension FernletStore {
    /// DEBUG screenshot seed (`bb-bowel`): two bathroom visits today, sealed like any tap, when today
    /// has none yet. Run from `seedBodybuildingDemoWeeks` on the simulator only.
    func seedBathroomDemoCount() {
        guard bathroomVisits(on: todayKey) == 0 else { return }
        if setBathroomVisits(2, on: todayKey) != .saved {
            assertionFailure("bathroom demo count failed to save")
        }
    }
}
#endif
