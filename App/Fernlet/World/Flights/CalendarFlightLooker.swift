import CryptoKit
import Foundation
import WorldMapStore

/// Why a calendar look didn't happen (World-Airports-Spec §10.2, §11).
nonisolated enum CalendarLookProblem: Error, Equatable, Sendable {
    /// "Flights from Calendar" or "Airports and flights" is off, or a decoy is showing: nothing is read.
    case switchedOff
    /// iOS doesn't give Fernlet full access (Don't Allow, or taken away later): nothing is read, and the switch
    /// goes back off.
    case notAllowed
    /// The bundled airport list is missing, so no code can be checked.
    case noAirportList
    /// The passport or the map's vault can't be read or saved now (the phone is locked, or a save failed).
    case passportClosed
}

/// One look through the calendar (World-Airports-Spec §10.5, §10.6), shared by the switch's first look and each
/// open's watch: the gates, the per-install salt, the bundled airport list, and the read off the main actor.
///
/// **Gates, every time:** both switches on and no decoy (`mayRead`), checked before anything is read and again
/// when the read ends, so a switch turned off mid-look keeps nothing; and full access, or nothing is asked of
/// EventKit at all. **Never writes to the calendar**, never opens a link.
@MainActor
struct CalendarFlightLooker {
    /// Where the events come from (EventKit in the app).
    let source: any CalendarEventSource
    /// The passport the look's flights go to.
    let atlas: WorldAtlasKeeper
    /// The bundled airport list, or nil when it's missing.
    let airports: () -> (any FlightAirportLookup)?
    /// The per-install salt (``CalendarFlightSalt``); throws while the vault can't be read.
    let salt: () throws -> SymmetricKey
    /// Whether the calendar may be read now: both switches on, no decoy.
    let mayRead: () -> Bool
    /// The phone's zone (EventKit's for floating and all-day events).
    var deviceTimeZone: TimeZone = .current

    /// Reads `window` as flights, split at `now`; the look, or why there wasn't one.
    func look(_ window: DateInterval, now: Date) async -> Result<CalendarFlightLook, CalendarLookProblem> {
        guard mayRead() else { return .failure(.switchedOff) }
        guard source.access() == .allowed else { return .failure(.notAllowed) }
        guard let airports = airports() else { return .failure(.noAirportList) }
        let key: SymmetricKey
        do {
            key = try salt()
        } catch {
            return .failure(.passportClosed)
        }
        let source = source, zone = deviceTimeZone
        let look = await Task.detached(priority: .utility) {
            CalendarFlightReader.look(source, window: window, airports: airports, salt: key, now: now, deviceTimeZone: zone)
        }.value
        guard mayRead() else { return .failure(.switchedOff) }
        return .success(look)
    }

    /// Each open's look (spec §10.6, option A): 2 days ago to 60 days ahead; passed upcoming flights and the
    /// window's flown ones join the Flights page, and the upcoming flights are replaced by the window's (a moved
    /// or cancelled event is followed). Nil when it was kept, else why not.
    @discardableResult
    func keepWatching(now: Date) async -> CalendarLookProblem? {
        switch await look(CalendarFlightLook.watchWindow(now: now), now: now) {
        case .success(let look):
            atlas.keepCalendarLook(flown: look.flown, upcoming: look.upcoming, now: now) ? nil : .passportClosed
        case .failure(let problem):
            problem
        }
    }
}

extension FernletStore {
    /// Whether the calendar may be read now (spec §10, §11): "Airports and flights" and "Flights from Calendar"
    /// both on, and no decoy.
    func mayReadWorldCalendar(defaults: UserDefaults = .standard) -> Bool {
        !duressSessionActive && !worldFog.atlas.isDecoy && WorldMapPreferences.keepsAirportsAndFlights(in: defaults)
            && WorldMapPreferences.readsCalendarFlights(in: defaults)
    }

    /// A looker over `source` for this store: its passport, the flight gate's bundled airport list and the map's
    /// vault for the salt.
    func worldCalendarLooker(source: any CalendarEventSource, defaults: UserDefaults = .standard) -> CalendarFlightLooker {
        let shelf = worldLocation.flights.airportsShelf, vault = worldMapVault
        return CalendarFlightLooker(
            source: source, atlas: worldFog.atlas, airports: { shelf.pack().map { $0 as any FlightAirportLookup } },
            salt: { try CalendarFlightSalt.key(in: vault) },
            mayRead: { [weak self] in self?.mayReadWorldCalendar(defaults: defaults) ?? false })
    }
}
