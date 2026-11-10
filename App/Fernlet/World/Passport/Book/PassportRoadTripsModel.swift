import FernletDomainModel
import Foundation

/// One road trip on the passport's Road trips page (World-RoadTrip-Spec §2.9, `rt-end`, the owner's choice "passport":
/// "The trip is also added to the passport's trips, next to flights and country trips"): a trip no longer on for this
/// iPhone, once its numbers are in, as one entry (never a stamp) — its name, its first and last days and its road.
nonisolated struct PassportRoadTrip: Equatable, Identifiable, Sendable {
    /// The trip's id.
    let id: UUID
    /// Its name: the person's own, or "Road trip" and the day it started.
    let name: String
    /// When it started.
    let start: Date
    /// When it stopped being on for this iPhone (its end, or this phone's leave).
    let end: Date
    /// Its road on this iPhone, in metres (the summary's).
    let metres: Double

    /// The entry for `trip`; nil while it is on or before its numbers are in.
    init?(_ trip: RoadTrip) {
        guard let end = trip.closedAt, let summary = trip.summary else { return nil }
        id = trip.id
        name = RoadTripCopy.name(of: trip)
        start = trip.startedAt
        self.end = max(end, trip.startedAt)
        metres = summary.metres
    }

    /// An entry from its parts (tests and the year logs).
    init(id: UUID, name: String, start: Date, end: Date, metres: Double) {
        self.id = id
        self.name = name
        self.start = start
        self.end = max(end, start)
        self.metres = metres
    }
}

/// One year's road trips on the Road trips page: the trips that started in it, earliest first, and their road. Its
/// row opens its log inside the book, as a year of flights does. A trip over New Year belongs to the year it started.
nonisolated struct PassportRoadTripYearLog: Equatable, Identifiable, Sendable {
    let year: Int
    let trips: [PassportRoadTrip]
    /// Their road, in metres.
    let metres: Double

    var id: Int { year }

    /// The log of `trips`, all of `year`.
    init(year: Int, trips: [PassportRoadTrip]) {
        self.year = year
        self.trips = trips
        metres = trips.reduce(0) { $0 + $1.metres }
    }
}

/// The passport's Road trips page (World-RoadTrip-Spec PR 4), on the Flights page's pattern (World-Airports-Spec §8):
/// every road trip this iPhone keeps that is no longer on, grouped by the year it started, newest year first. The book
/// gains one page however many there are: a history that fits one page (``tripsOnOnePage``) shows its rows under year
/// headings, and a longer one lists its years, each opening its own log. The header's totals count every trip and its
/// road.
///
/// A value built from the trip book's closed trips (`worldFog.roadTrip.book.closed`, empty in a decoy). The book shows
/// no Road trips page in a decoy, in the demo, or with none (``isEmpty``). Bounded by ``RoadTripBook/maxTrips``.
nonisolated struct PassportRoadTripsModel: Equatable, Sendable {
    /// The trips, earliest first.
    let trips: [PassportRoadTrip]
    /// The years with trips, newest first.
    let years: [PassportRoadTripYearLog]
    /// Every trip's road, in metres.
    let totalMetres: Double

    /// The most trips the page shows as rows itself; past this it lists the years (the Flights page's own).
    static let tripsOnOnePage = PassportFlightsModel.tripsOnOnePage

    /// The page for `trips` (a book's closed trips; one still on or without its numbers is left out), dated by
    /// `calendar`.
    init(trips: [RoadTrip], calendar: Calendar = .current) {
        self.init(entries: trips.prefix(RoadTripBook.maxTrips).compactMap(PassportRoadTrip.init), calendar: calendar)
    }

    /// The page for `entries`, dated by `calendar`.
    init(entries: [PassportRoadTrip], calendar: Calendar = .current) {
        let sorted = entries.prefix(RoadTripBook.maxTrips).sorted { $0.start < $1.start }
        trips = sorted
        totalMetres = sorted.reduce(0) { $0 + $1.metres }
        var byYear: [Int: [PassportRoadTrip]] = [:]
        // R2: bounded by the book's trips.
        for trip in sorted {
            byYear[calendar.component(.year, from: trip.start), default: []].append(trip)
        }
        years = byYear.keys.sorted(by: >).map { PassportRoadTripYearLog(year: $0, trips: byYear[$0] ?? []) }
    }

    /// No road trips (the book then shows no page).
    var isEmpty: Bool { trips.isEmpty }

    /// Whether the page lists the years rather than showing the rows itself.
    var listsYears: Bool { trips.count > Self.tripsOnOnePage }

    /// The log of `year`, or nil when no trip started in it.
    func log(ofYear year: Int) -> PassportRoadTripYearLog? {
        years.first { $0.year == year }
    }

    /// `year`'s place in ``years``, from 0, or nil when no trip started in it.
    func position(ofYear year: Int) -> Int? {
        years.firstIndex { $0.year == year }
    }
}

/// The Road trips page's words built from its numbers: a trip's days as the Flights page writes them, and what
/// VoiceOver reads for a row and a year.
nonisolated enum PassportRoadTripsText {
    /// "10–12 NOV 2026", "10 NOV 2026" (the page's rows), or "10–12 NOV" in a year's log, whose header gives the year.
    static func days(of trip: PassportRoadTrip, inYear: Bool, calendar: Calendar = .current, language: FernletLanguage = .app) -> String {
        inYear ? PassportFlightsText.daysInYear(from: trip.start, to: trip.end, calendar: calendar, language: language)
            : PassportFlightsText.days(from: trip.start, to: trip.end, calendar: calendar, language: language)
    }

    /// "Road trip to the coast, 10 November 2026 to 12 November 2026, 412 km" (VoiceOver: a row), one day said once.
    static func spoken(_ trip: PassportRoadTrip, calendar: Calendar = .current) -> String {
        let first = PassportDates.long(trip.start, calendar: calendar)
        let days = calendar.isDate(trip.start, inSameDayAs: trip.end) ? first
            : AddressedCopy.plain(RoadTripCopy.passportSpokenDays(first, to: PassportDates.long(trip.end, calendar: calendar)))
        return [trip.name, days, RoadTripCopy.distance(trip.metres)].joined(separator: ", ")
    }

    /// "2026, 3 road trips, 1,240 km" (VoiceOver: a year's row, its log's heading, and read on stepping to it).
    static func yearSpoken(_ log: PassportRoadTripYearLog) -> String {
        String(log.year) + ", " + RoadTripCopy.passportTotalsSpoken(log.trips.count, metres: log.metres)
    }
}
