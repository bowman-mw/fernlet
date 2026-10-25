import Foundation

/// The World map's device-only settings (World app plan steps 5a and 5b; design page answers 4 and 20).
///
/// - **Uncover the map as you go** (on by default): whether precise readings lift the fog. The fog
///   starts on its own from the first open, with no prompt of its own beyond iOS's location prompt.
/// - **Always, low power** (off by default): iOS's visit and significant-change updates fill the fog
///   along the day. Needs the Always permission, asked only when the person turns this on.
/// - **Save new routes** (on by default; owner, 2026-10-22): whether a finished walk keeps its line on
///   this iPhone. Off stops new lines only: the walk still lifts the fog and logs its distance.
/// - **Remember where your workout spaces are** (asked once, in workout-space setup; step 6a): not asked
///   (nil), yes or no. Until it is yes nothing pins a space.
/// - **Remember places I stop at** (on by default; owner, World build round 5): whether Where you've been
///   notes new visits and timeline stops. Off notes nothing new and asks no lookup; what is kept stays until
///   it is deleted (the fog and the walk lines have their own switches).
/// - **The map intro answered** (step 5c, `b1-loc-intro`): the intro shows once, before iOS asks; Turn on
///   location and Not now both answer it.
/// - **The companion hint shown** (`ref-hint`): "Tap me to say hi!" shows once on this iPhone.
///
/// Device-only `UserDefaults`, never in the synced settings: they describe this phone's location
/// behaviour. Every key is cleared by the delete funnel (``clearAll(in:)``,
/// `PersistedSurfaceWipeBoundaryTests`).
nonisolated enum WorldMapPreferences {
    /// The keys (frozen tokens).
    enum Key {
        static let uncoverAsYouGo = "fernlet.worldMap.uncoverAsYouGo"
        static let alwaysLowPower = "fernlet.worldMap.alwaysLowPower"
        static let saveNewRoutes = "fernlet.worldMap.saveNewRoutes"
        static let rememberSpaces = "fernlet.worldMap.rememberSpaces"
        static let remembersPlaces = "fernlet.worldMap.rememberPlaces"
        static let locationIntroAnswered = "fernlet.worldMap.locationIntroAnswered"
        static let companionHintShown = "fernlet.worldMap.companionHintShown"
    }

    /// Whether Where you've been notes the places the person stops at (default on).
    static func remembersPlaces(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: Key.remembersPlaces) != nil else { return true }
        return defaults.bool(forKey: Key.remembersPlaces)
    }

    /// Sets "Remember places I stop at".
    static func setRemembersPlaces(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: Key.remembersPlaces)
    }

    /// Whether the map intro has been answered on this iPhone (Turn on location or Not now).
    static func locationIntroAnswered(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.locationIntroAnswered)
    }

    /// Records that the map intro was answered.
    static func setLocationIntroAnswered(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: Key.locationIntroAnswered)
    }

    /// Whether the one-time "Tap me to say hi!" hint has had its turn on this iPhone.
    static func companionHintShown(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.companionHintShown)
    }

    /// Records that the companion hint has had its turn.
    static func setCompanionHintShown(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: Key.companionHintShown)
    }

    /// Whether the fog lifts as you go (default on).
    static func uncoverAsYouGo(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: Key.uncoverAsYouGo) != nil else { return true }
        return defaults.bool(forKey: Key.uncoverAsYouGo)
    }

    /// Sets "Uncover the map as you go".
    static func setUncoverAsYouGo(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: Key.uncoverAsYouGo)
    }

    /// Whether the low-power Always mode is on (default off).
    static func alwaysLowPower(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.alwaysLowPower)
    }

    /// Sets the low-power Always mode.
    static func setAlwaysLowPower(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: Key.alwaysLowPower)
    }

    /// Whether a finished walk keeps its line on this iPhone (default on).
    static func saveNewRoutes(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: Key.saveNewRoutes) != nil else { return true }
        return defaults.bool(forKey: Key.saveNewRoutes)
    }

    /// Sets "Save new routes".
    static func setSaveNewRoutes(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: Key.saveNewRoutes)
    }

    /// The answer to "Remember where your workout spaces are?": nil until it has been asked.
    static func rememberSpaces(in defaults: UserDefaults = .standard) -> Bool? {
        guard defaults.object(forKey: Key.rememberSpaces) != nil else { return nil }
        return defaults.bool(forKey: Key.rememberSpaces)
    }

    /// Records the answer to "Remember where your workout spaces are?".
    static func setRememberSpaces(_ yes: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(yes, forKey: Key.rememberSpaces)
    }

    /// Removes every setting (the delete funnel), so the next launch starts from the defaults.
    static func clearAll(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Key.uncoverAsYouGo)
        defaults.removeObject(forKey: Key.alwaysLowPower)
        defaults.removeObject(forKey: Key.saveNewRoutes)
        defaults.removeObject(forKey: Key.rememberSpaces)
        defaults.removeObject(forKey: Key.remembersPlaces)
        defaults.removeObject(forKey: Key.locationIntroAnswered)
        defaults.removeObject(forKey: Key.companionHintShown)
    }
}
