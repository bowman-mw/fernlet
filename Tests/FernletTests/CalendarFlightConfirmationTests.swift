import Foundation
import LocalPersistence
import Testing
import WorldMapStore
@testable import Fernlet

/// A calendar flight counts as the person's own only once the trip is confirmed (release review F10; owner
/// 2026-11-19: "no, needs confirmation of a trip. Example is calendar invite from a friend and picking them up from
/// the airport"). A shared calendar's flight with no landing stays upcoming, makes no travel day and no memory city,
/// and lapses; Fernlet's own landing confirms it; and the upgrade moves flights earlier builds counted without proof
/// back to the upcoming flights, with the travel days they made. Made-up flights (a Portland traveller to Denver),
/// dated around the real clock because the travel-day keys read it.
@MainActor
struct CalendarFlightConfirmationTests {
    /// The keeper's made-up airport tokens and their IATA codes.
    static let codes = ["tok-pdx": "PDX", "tok-den": "DEN"]

    /// A store with its passport open and made-up airport tokens, or nil where this machine's own "Airports and
    /// flights" is off (the travel-day reads use the standard defaults, as `TravelDayWorkoutTests` notes).
    private func store() -> FernletStore? {
        let store = makeTestStore()
        guard store.keepsWorldAirportsAndFlights() else { return nil }
        store.worldFog.load()
        store.worldLocation.flights.useAirports({ NoAirports() }, iataCode: { Self.codes[$0] })
        return store
    }

    private func defaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "CalendarFlightConfirmationTests.\(UUID().uuidString)"))
        WorldMapPreferences.setKeepsAirportsAndFlights(true, in: defaults)
        return defaults
    }

    /// The calendar's PDX>DEN leaving at `departure`, landing 2.5 h later.
    private func calendarFlight(_ departure: Date) throws -> PassportFlight {
        try #require(PassportFlight(from: "PDX", to: "DEN", departure: departure,
                                    arrival: departure.addingTimeInterval(9_000), sources: .calendar,
                                    eventHash: String(repeating: "ab", count: 32)))
    }

    /// Whether Tier-2's snapshot names Denver on any day.
    private func memoryNamesDenver(_ store: FernletStore) -> Bool {
        store.tierTwoTravel.snapshot.days.values.contains { $0.toCity == "Denver" }
    }

    /// A partner's flight in a shared calendar, the person at home: after it leaves it stays upcoming, the Flights page
    /// has nothing flown, no day is a travel day and memory has no city; a look after the window lapses it.
    @Test func aSharedCalendarFlightWithNoLandingStaysPlanned() throws {
        guard let store = store() else { return }
        let defaults = try defaults(), now = Date()
        let flight = try calendarFlight(now.addingTimeInterval(-4 * 3_600))
        #expect(store.worldFog.atlas.keepCalendarLook(flown: [flight], upcoming: []))
        let book = store.worldFog.atlas.book
        #expect(book.flights.isEmpty, "a calendar flight alone became a flight flown")
        #expect(book.upcomingFlights == [flight], "it waits, upcoming, for the trip's confirmation")
        #expect(store.workoutTravelDay(now: now) == .none, "a friend's flight made a travel day")
        #expect(store.worldTravelDayFlights(now: now).isEmpty)
        store.rememberWorkoutTravelDays(now: now)
        #expect(store.workoutTravelDayKeys.isEmpty, "a friend's flight was remembered as a travel day")
        store.publishTierTwoTravel(now: now, defaults: defaults)
        #expect(store.tierTwoTravel.snapshot.days.isEmpty && !memoryNamesDenver(store), "memory named a trip not taken")
        // The next look's window (2 days back) no longer holds it: it lapses, never counted.
        #expect(store.worldFog.atlas.keepCalendarLook(flown: [], upcoming: []))
        #expect(store.worldFog.atlas.book.flights.isEmpty && store.worldFog.atlas.book.upcomingFlights.isEmpty)
    }

    /// Fernlet's own landing at Denver confirms the calendar's flight: it is flown (both sources, the calendar's hash),
    /// leaves the upcoming list, makes a travel day, and memory may name Denver.
    @Test func aLandingConfirmsTheCalendarFlight() throws {
        guard let store = store() else { return }
        let defaults = try defaults(), now = Date()
        let departure = now.addingTimeInterval(-4 * 3_600), landed = departure.addingTimeInterval(9_300)
        let flight = try calendarFlight(departure)
        #expect(store.worldFog.atlas.keepCalendarLook(flown: [flight], upcoming: []))
        #expect(store.recordWorldFlightEvents([.landed(token: "tok-den", from: "tok-pdx",
                                                       departed: departure.addingTimeInterval(900), at: landed)],
                                              defaults: defaults))
        let book = store.worldFog.atlas.book
        #expect(book.flights.count == 1 && book.upcomingFlights.isEmpty)
        #expect(book.flights.first?.sources == [.fernlet, .calendar] && book.flights.first?.eventHash != nil)
        #expect(store.worldTravelDayFlights(now: now).count == 1, "a confirmed flight made no travel day")
        store.rememberWorkoutTravelDays(now: now)
        #expect(!store.workoutTravelDayKeys.isEmpty)
        store.publishTierTwoTravel(now: now, defaults: defaults)
        #expect(!store.tierTwoTravel.snapshot.days.isEmpty)
        if store.worldLocation.flights.airportsShelf.pack() != nil {
            #expect(memoryNamesDenver(store), "the confirmed trip's city didn't reach memory")
        }
    }

    /// A landing whose take-off the gate didn't see (the phone off at Portland) still confirms the calendar's flight
    /// to that airport, taking its departure airport and time.
    @Test func aLandingWithNoTakeOffSeenTakesTheCalendarsAirport() throws {
        guard let store = store() else { return }
        let defaults = try defaults(), now = Date()
        let departure = now.addingTimeInterval(-4 * 3_600), landed = departure.addingTimeInterval(9_300)
        #expect(store.worldFog.atlas.keepCalendarLook(flown: [try calendarFlight(departure)], upcoming: []))
        #expect(store.recordWorldFlightEvents([.landed(token: "tok-den", from: nil,
                                                       departed: landed.addingTimeInterval(-600), at: landed)],
                                              defaults: defaults))
        let flown = try #require(store.worldFog.atlas.book.flights.first)
        #expect(flown.route == "PDX>DEN" && flown.departure == departure && flown.arrival == landed)
        #expect(flown.sources == [.fernlet, .calendar] && store.worldFog.atlas.book.upcomingFlights.isEmpty)
        // A landing somewhere the calendar has no flight to records nothing.
        #expect(store.worldLocation.flights.flight(plannedIn: [], to: "tok-den", arrived: landed) == nil)
    }

    /// The upgrade: a calendar-only flight an earlier build counted as flown (with its remembered travel day) goes
    /// back to the upcoming flights, its day is forgotten and memory has no city; a calendar-only flight from before
    /// calendar flights shipped (only the first look's "Add" could bring it) and a flight Fernlet saw stay; and it
    /// runs once.
    @Test func theUpgradeDemotesUnprovenCalendarFlights() throws {
        guard let store = store() else { return }
        let defaults = try defaults(), now = Date()
        let friend = try calendarFlight(now.addingTimeInterval(-26 * 3_600))
        let added = try calendarFlight(FernletStore.calendarFlightsShipped.addingTimeInterval(-90 * 86_400))
        let seen = try #require(PassportFlight(from: "DEN", to: "PDX", departure: now.addingTimeInterval(-10 * 86_400),
                                               arrival: now.addingTimeInterval(-10 * 86_400 + 9_000), sources: .fernlet))
        #expect(store.worldFog.atlas.importFlights([friend, added, seen]))
        let pack = store.worldLocation.flights.airportsShelf.pack()
        let zone: (String) -> TimeZone = { pack?.timeZone(iata: $0) ?? .current }
        let friendDays = WorldTravelDayRule.days(of: FernletStore.travelDayFlights([friend], zone: zone)).keys.sorted()
        try store.worldMapVault.write(JSONEncoder().encode(friendDays), to: FernletStore.travelDaysFile)
        #expect(!store.workoutTravelDayKeys.isDisjoint(with: friendDays), "the old build's travel day wasn't set up")

        store.upgradeUnconfirmedCalendarFlights(now: now, defaults: defaults)
        let book = store.worldFog.atlas.book
        #expect(Set(book.flights) == [added, seen], "the unproven flight is still flown, or a kept one went")
        #expect(book.upcomingFlights == [friend], "demoted, never deleted")
        #expect(store.workoutTravelDayKeys.isDisjoint(with: friendDays), "the friend's travel day is still remembered")
        store.publishTierTwoTravel(now: now, defaults: defaults)
        #expect(!memoryNamesDenver(store), "memory still names the friend's trip")
        #expect(WorldMapPreferences.calendarFlightsUpgraded(in: defaults))

        #expect(store.worldFog.atlas.importFlights([try calendarFlight(now.addingTimeInterval(-40 * 86_400))]))
        store.upgradeUnconfirmedCalendarFlights(now: now, defaults: defaults)
        #expect(store.worldFog.atlas.book.flights.count == 3, "the upgrade ran twice and took a confirmed import")
    }
}
