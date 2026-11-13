import FernletFoundation
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
/// - **Airports and flights** (on by default; World-Airports-Spec §11, screen 13): whether airport stamps,
///   flights and layovers are kept. Off keeps no new ones and stops the calendar's look; what is kept stays until
///   the person deletes it.
/// - **Flights from Calendar** (off by default; spec §10.1, screen 25): whether Fernlet looks through the
///   calendar for flights. On only once iOS gave full access; never read in a decoy.
/// - **The map intro answered** (step 5c, `b1-loc-intro`): the intro shows once, before iOS asks; Turn on
///   location and Not now both answer it.
/// - **The companion hint shown** (`ref-hint`): "Tap me to say hi!" shows once on this iPhone.
/// - **Background mapping's marker** (owner 2026-11-09, the locked launch): an empty file in Application Support that
///   mirrors the Always switch for the app's own defaults, because a launch the locked phone refuses can't trust what
///   it reads; ``clearAll(in:)`` removes it with the rest.
/// - **The car book and its salt** (owner 2026-11-09, car signals): which Bluetooth devices are the person's cars
///   (``WorldCarBook``, kept by ``WorldCarKeeper``), and the random salt their scrambled tags are made with, so a wipe
///   makes every old tag meaningless as well as deleting it.
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
        static let airportsAndFlights = "fernlet.worldMap.airportsAndFlights"
        static let flightsFromCalendar = "fernlet.worldMap.flightsFromCalendar"
        static let carBook = "fernlet.worldMap.carBook"
        static let carTagSalt = "fernlet.worldMap.carTagSalt"
    }

    /// The car book's saved bytes (``WorldCarKeeper``); nil before the first car or sighting.
    static func carBookData(in defaults: UserDefaults = .standard) -> Data? {
        defaults.data(forKey: Key.carBook)
    }

    /// Saves the car book's bytes.
    static func setCarBookData(_ data: Data, in defaults: UserDefaults = .standard) {
        defaults.set(data, forKey: Key.carBook)
    }

    /// The salt the car book's tags are made with, created once on this iPhone (a wipe makes a new one).
    static func carTagSalt(in defaults: UserDefaults = .standard) -> String {
        if let salt = defaults.string(forKey: Key.carTagSalt), !salt.isEmpty { return salt }
        let salt = UUID().uuidString
        defaults.set(salt, forKey: Key.carTagSalt)
        return salt
    }

    /// Whether "Airports and flights" is on (default on).
    static func keepsAirportsAndFlights(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: Key.airportsAndFlights) != nil else { return true }
        return defaults.bool(forKey: Key.airportsAndFlights)
    }

    /// Sets "Airports and flights".
    static func setKeepsAirportsAndFlights(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: Key.airportsAndFlights)
    }

    /// Whether "Flights from Calendar" is on (default off).
    static func readsCalendarFlights(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.flightsFromCalendar)
    }

    /// Sets "Flights from Calendar".
    static func setReadsCalendarFlights(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: Key.flightsFromCalendar)
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

    /// Sets the low-power Always mode; for the app's own defaults, its marker too (``backgroundMappingMarked(in:)``).
    static func setAlwaysLowPower(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: Key.alwaysLowPower)
        if defaults === UserDefaults.standard { setBackgroundMarker(on) }
    }

    // MARK: Background mapping's marker (owner 2026-11-09, the locked launch)

    /// The marker's name in Application Support (a frozen token).
    static let backgroundMarkerName = "WorldMapBackground.on"

    /// Where the marker lives: Application Support, or `directory` (tests).
    static func backgroundMarkerURL(in directory: URL? = nil) -> URL? {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return folder?.appendingPathComponent(backgroundMarkerName, isDirectory: false)
    }

    /// Whether background mapping's marker is there: an empty file that mirrors the switch, so a launch the locked
    /// phone refuses (iOS relaunching a closed Fernlet for a fence, a significant change or a Focus filter) can still
    /// tell background mapping is on and start the map's location (`WorldLockedMapping`). Being there is readable
    /// whatever the lock; the file holds nothing.
    static func backgroundMappingMarked(in directory: URL? = nil) -> Bool {
        guard let url = backgroundMarkerURL(in: directory) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Writes the marker to match the switch in the app's own defaults (a launch the phone allowed reads the switch
    /// itself, so an install from before the marker gets one).
    static func syncBackgroundMarker() {
        setBackgroundMarker(alwaysLowPower())
    }

    /// Puts the marker in place (readable after the first unlock, never backed up) or removes it, in `directory` when
    /// given; a failure is logged and leaves things as they were.
    static func setBackgroundMarker(_ on: Bool, in directory: URL? = nil) {
        guard let url = backgroundMarkerURL(in: directory) else { return }
        let files = FileManager.default
        do {
            guard on else {
                if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
                return
            }
            guard !files.fileExists(atPath: url.path) else { return }
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var marked = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try marked.setResourceValues(values)
        } catch {
            FernletAuditLog.log("worldMap.backgroundMarker.failed")
        }
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
        defaults.removeObject(forKey: Key.airportsAndFlights)
        defaults.removeObject(forKey: Key.flightsFromCalendar)
        defaults.removeObject(forKey: Key.carBook)
        defaults.removeObject(forKey: Key.carTagSalt)
        if defaults === UserDefaults.standard { setBackgroundMarker(false) }
    }
}
