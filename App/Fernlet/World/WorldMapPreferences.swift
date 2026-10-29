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
/// - **Remember places I eat out** (on by default, as `b1-settings-map` draws it; World build round 6): whether
///   the meals logged at a place to eat are noted there. Off notes no meal; the places kept stay.
/// - **Log my bike rides** (off by default; round 7, `b1-settings-map`): whether car and bike detection reads
///   the motion coprocessor, so bike rides log as exercise. Motion & Fitness is asked only when it is turned on.
/// - **Bike rides checked through** (round 7): the moment the motion history was last looked through for
///   bike rides, so a ride is logged once and never one from before the switch was turned on. A time only;
///   no motion data is kept.
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
        static let remembersEatingOut = "fernlet.worldMap.rememberEatingOut"
        static let locationIntroAnswered = "fernlet.worldMap.locationIntroAnswered"
        static let companionHintShown = "fernlet.worldMap.companionHintShown"
        static let logBikeRides = "fernlet.worldMap.logBikeRides"
        static let bikeRidesCheckedThrough = "fernlet.worldMap.bikeRidesCheckedThrough"
    }

    /// Whether "Log my bike rides" is on (default off).
    static func logsBikeRides(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.logBikeRides)
    }

    /// Sets "Log my bike rides".
    static func setLogsBikeRides(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: Key.logBikeRides)
    }

    /// When the motion history was last looked through for bike rides; nil before the first look.
    static func bikeRidesCheckedThrough(in defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: Key.bikeRidesCheckedThrough) as? Date
    }

    /// Records how far the motion history has been looked through for bike rides (nil forgets it).
    static func setBikeRidesCheckedThrough(_ date: Date?, in defaults: UserDefaults = .standard) {
        guard let date else {
            defaults.removeObject(forKey: Key.bikeRidesCheckedThrough)
            return
        }
        defaults.set(date, forKey: Key.bikeRidesCheckedThrough)
    }

    /// Whether the meals logged at a place to eat are noted there, so it becomes a favourite after three
    /// ("Remember places I eat out", `b1-settings-map`; default on, as drawn).
    static func remembersEatingOut(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: Key.remembersEatingOut) != nil else { return true }
        return defaults.bool(forKey: Key.remembersEatingOut)
    }

    /// Sets "Remember places I eat out".
    static func setRemembersEatingOut(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: Key.remembersEatingOut)
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
        defaults.removeObject(forKey: Key.remembersEatingOut)
        defaults.removeObject(forKey: Key.locationIntroAnswered)
        defaults.removeObject(forKey: Key.companionHintShown)
        defaults.removeObject(forKey: Key.logBikeRides)
        defaults.removeObject(forKey: Key.bikeRidesCheckedThrough)
    }
}
