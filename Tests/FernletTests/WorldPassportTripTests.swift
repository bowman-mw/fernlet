import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// A stamp each trip (owner 2026-10-29, World-Passport-Spec §6): a country earns a new stamp each time the person
/// comes back after 7 or more days away from it, their own country included; the counts still count each country
/// once; continents, oceans, seas and the two specials stay one stamp each. The sealed backup carries every trip,
/// reads an old record as one trip, and a restore keeps each trip once.
@MainActor
struct WorldPassportTripTests {
    nonisolated static let day: TimeInterval = 86_400
    nonisolated static let t0 = Date(timeIntervalSince1970: 1_792_800_000)

    /// The date `days` after ``t0``.
    nonisolated static func at(_ days: Double) -> Date {
        t0.addingTimeInterval(days * day)
    }

    nonisolated static let us = AtlasVisit(countryCode: "US", continent: .northAmerica, terrain: .temperateForest)
    nonisolated static let france = AtlasVisit(countryCode: "FR", continent: .europe, terrain: .temperateForest)

    /// A passport of `visits`, recorded in order.
    nonisolated static func book(_ visits: [(AtlasVisit, Date)]) -> PassportBook {
        var book = PassportBook()
        for (visit, date) in visits { _ = book.record(visit, at: date) }
        return book
    }

    // MARK: The rule

    /// Six days away is the same trip; the clock is the last fix there, not the trip's start.
    @Test func leavingForSixDaysDoesNotStampAgain() {
        let book = Self.book([(Self.us, Self.t0), (Self.france, Self.at(1)), (Self.us, Self.at(6))])
        #expect(book.trips(inCountry: "US") == [Self.t0])
        #expect(book.lastSeen(inCountry: "US") == Self.at(6))
        #expect(book.stamps.filter { $0.token == "US" }.count == 1)
        var edge = Self.book([(Self.us, Self.t0)])
        _ = edge.record(Self.us, at: Self.at(7).addingTimeInterval(-1))
        #expect(edge.trips(inCountry: "US") == [Self.t0], "a second short of 7 days is still away too briefly")
    }

    /// Eight days away (or exactly seven) starts a new trip on that fix's date, stamped in visit order.
    @Test func leavingForEightDaysStampsAgain() {
        let book = Self.book([(Self.us, Self.t0), (Self.france, Self.at(1)), (Self.us, Self.at(8))])
        #expect(book.trips(inCountry: "US") == [Self.t0, Self.at(8)])
        #expect(book.trips(inCountry: "FR") == [Self.at(1)])
        let countries = book.stamps.filter { $0.kind == .country }
        #expect(countries.map(\.token) == ["US", "FR", "US"])
        #expect(countries.map(\.trip) == [1, 1, 2])
        #expect(countries.last?.date == Self.at(8))
        #expect(Self.book([(Self.us, Self.t0), (Self.us, Self.at(7))]).trips(inCountry: "US").count == 2,
                "exactly 7 days away counts")
    }

    /// Coming home after a trip abroad stamps home again; days at home keep home's clock going, so staying
    /// never stamps it.
    @Test func yourOwnCountryAfterATripAbroad() {
        var visits: [(AtlasVisit, Date)] = (0...20).map { (Self.us, Self.at(Double($0))) }
        visits += (21...32).map { (Self.france, Self.at(Double($0))) }
        visits += (33...40).map { (Self.us, Self.at(Double($0))) }
        let book = Self.book(visits)
        #expect(book.trips(inCountry: "US") == [Self.t0, Self.at(33)], "three weeks at home is one trip; home again is two")
        #expect(book.trips(inCountry: "FR") == [Self.at(21)])
        #expect(book.returnCount == 1)
    }

    /// A week at home with every fix inside the keeper's spacing still keeps home's clock going.
    @Test func stayingPutAtHomeNeverStampsItAgain() {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let home = WorldPassportTests.portlandPoint
        let keeper = WorldPassportTests.keeper(vault)
        for day in 0...9 {
            keeper.observe(point: home.offset(east: Double(day % 2) * 10, north: 0), at: Self.at(Double(day)))
        }
        keeper.observe(point: WorldPassportTests.caribbeanPoint, at: Self.at(10))
        keeper.observe(point: home, at: Self.at(11))
        #expect(keeper.book.trips(inCountry: "US") == [Self.t0], "never 7 days without a fix at home")
        keeper.observe(point: WorldPassportTests.caribbeanPoint, at: Self.at(12))
        keeper.observe(point: home, at: Self.at(19))
        #expect(keeper.book.trips(inCountry: "US") == [Self.t0, Self.at(19)], "eight days away")
    }

    // MARK: Counts and specials

    /// The counts count each country once however many trips; continents, oceans, seas and each special stay
    /// one stamp, the special on the day the last one was reached.
    @Test func theCountsAreUnchanged() {
        var visits: [(AtlasVisit, Date)] = [(Self.us, Self.t0), (Self.us, Self.at(10)), (Self.us, Self.at(20)),
                                            (Self.france, Self.at(30)), (Self.france, Self.at(31))]
        for (index, continent) in AtlasContinent.allCases.enumerated() {
            visits.append((AtlasVisit(continent: continent, terrain: .grassland), Self.at(40 + Double(index))))
            visits.append((AtlasVisit(continent: continent, terrain: .grassland), Self.at(60 + Double(index))))
        }
        let book = Self.book(visits)
        #expect(book.discoveries(of: .country) == 2 && book.discoveries(of: .continent) == 7)
        #expect(book.trips(inCountry: "US").count == 3 && book.trips(inCountry: "FR").count == 1)
        let stamps = book.stamps
        #expect(stamps.filter { $0.kind == .country }.count == 4)
        #expect(stamps.filter { $0.kind == .continent }.count == 7, "a continent is stamped once")
        let special = stamps.filter { $0.kind == .allContinents }
        #expect(special.count == 1 && special.first?.date == Self.at(40 + Double(AtlasContinent.allCases.count - 1)))
        #expect(stamps.last?.kind == .allContinents, "beside the seventh continent")
        #expect(!stamps.contains { $0.kind == .allOceans }, "not every ocean yet")
        #expect(stamps.map(\.date) == stamps.map(\.date).sorted())
    }

    // MARK: Bytes and the store

    /// Trips and clocks round-trip in the sealed file's bytes; a book written before trips reads as one trip per
    /// country; trips for a country that isn't there are refused.
    @Test func tripsRoundTripAndAnOldBookReadsAsOneTripEach() throws {
        let book = Self.book([(Self.us, Self.t0), (Self.france, Self.at(1)), (Self.us, Self.at(9))])
        #expect(try PassportBook(data: book.encoded()) == book)
        let old = try PassportBook(data: WorldPassportTests.json(["version": 1, "country": ["US": 1_792_800_000.0]]))
        #expect(old.trips(inCountry: "US") == [Self.t0] && old.lastSeen(inCountry: "US") == Self.t0)
        #expect(throws: PassportBook.BookError.badToken(.country)) {
            try PassportBook(data: WorldPassportTests.json(["version": 1, "returns": ["US": [1_792_800_000.0]]]))
        }
    }

    /// A trip is saved at once; a fix that only moves the clock on is saved at most once an hour.
    @Test func theClockIsSavedAtMostHourly() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let store = PassportStore(vault: vault)
        try store.load()
        _ = try store.record(Self.us, at: Self.t0)
        _ = try store.record(Self.us, at: Self.t0.addingTimeInterval(600))
        let early = PassportStore(vault: vault)
        try early.load()
        #expect(early.book.lastSeen(inCountry: "US") == Self.t0, "ten minutes on is not written on its own")
        _ = try store.record(Self.us, at: Self.t0.addingTimeInterval(3_600))
        _ = try store.record(Self.us, at: Self.at(8))
        let later = PassportStore(vault: vault)
        try later.load()
        #expect(later.book.trips(inCountry: "US") == [Self.t0, Self.at(8)] && later.book == store.book)
    }

    /// A decoy records no trip; every wipe clears them.
    @Test func aDecoyKeepsNoTripAndTheWipeClearsThem() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = WorldPassportTests.keeper(vault)
        keeper.observe(point: WorldPassportTests.portlandPoint, at: Self.t0)
        keeper.setDecoy(true)
        keeper.observe(point: WorldPassportTests.portlandPoint.offset(east: 500, north: 0), at: Self.at(9))
        keeper.setDecoy(false)
        #expect(keeper.book.trips(inCountry: "US") == [Self.t0], "the decoy's fix started nothing")
        keeper.observe(point: WorldPassportTests.caribbeanPoint, at: Self.at(9))
        keeper.observe(point: WorldPassportTests.portlandPoint, at: Self.at(18))
        #expect(keeper.book.trips(inCountry: "US").count == 2)
        #expect(keeper.clearAll())
        let reopened = PassportStore(vault: vault)
        try reopened.load()
        #expect(keeper.book.returnCount == 0 && reopened.book.trips(inCountry: "US").isEmpty)
    }

    // MARK: The new-trip event

    /// Seattle: the United States again, with a city not visited yet.
    nonisolated static let seattlePoint = GeoPoint(47.6062, -122.3321)
    nonisolated static let seattle = AtlasVisit(
        countryCode: "US", sovereignCode: "US", continent: .northAmerica,
        city: AtlasCity(token: "Q5083", countryCode: "US", size: .city, population: 750_000, point: seattlePoint,
                        names: AtlasCityNames(english: "Seattle")),
        terrain: .temperateForest)

    /// A keeper over `vault` whose atlas also knows Seattle.
    static func keeper(_ vault: WorldMapVault) -> WorldAtlasKeeper {
        var visits = WorldPassportTests.atlas.visits
        visits[seattlePoint] = seattle
        let atlas = WorldPassportTests.FakeAtlas(visits: visits)
        return WorldAtlasKeeper(vault: vault, openAtlas: { atlas })
    }

    /// Everything `stream` held once ended.
    static func drain(_ stream: AsyncStream<PassportEvent>) async -> [PassportEvent] {
        var heard: [PassportEvent] = []
        for await event in stream.prefix(64) { heard.append(event) }
        return heard
    }

    /// A return trip is announced once, with its country, start and trip number, before the first visits the
    /// same fix makes; a first visit is never also a new trip, and staying on announces nothing more.
    @Test func aNewTripIsAnnouncedOnceWithItsNumber() async {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = Self.keeper(vault)
        let stream = keeper.discoveries()
        keeper.observe(point: WorldPassportTests.portlandPoint, at: Self.t0)
        keeper.observe(point: WorldPassportTests.caribbeanPoint, at: Self.at(1))
        keeper.observe(point: Self.seattlePoint, at: Self.at(9))
        keeper.observe(point: WorldPassportTests.portlandPoint, at: Self.at(10))
        keeper.observe(point: WorldPassportTests.caribbeanPoint, at: Self.at(11))
        keeper.observe(point: WorldPassportTests.portlandPoint, at: Self.at(20))
        keeper.endDiscoveries()
        let heard = await Self.drain(stream)
        let trips = heard.compactMap(\.trip)
        #expect(trips == [PassportStamp(kind: .country, token: "US", date: Self.at(9), trip: 2),
                          PassportStamp(kind: .country, token: "US", date: Self.at(20), trip: 3)])
        let seattleFix = heard.drop { $0.trip?.trip != 2 }.prefix(2)
        #expect(seattleFix.last?.discovery?.token == "Q5083", "the trip, then the new city, from the same fix")
        #expect(heard.first?.discovery?.kind == .country, "the first visit is announced as a first visit only")
        #expect(heard.filter { $0.discovery?.kind == .country }.count == 1)
    }

    /// A decoy's fix starts no trip and announces nothing; a restore that brings trips announces nothing; a trip
    /// is announced only for the accepted fix that starts it, once.
    @Test func aNewTripIsNeverAnnouncedInADecoyOrForARestore() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = Self.keeper(vault)
        keeper.observe(point: WorldPassportTests.portlandPoint, at: Self.t0)
        let stream = keeper.discoveries()
        keeper.setDecoy(true)
        keeper.observe(point: Self.seattlePoint, at: Self.at(9))
        keeper.setDecoy(false)
        try keeper.restore(Self.book([(Self.us, Self.at(-30)), (Self.us, Self.at(-20))]))
        #expect(keeper.book.trips(inCountry: "US").count == 3, "the restore brought two trips, quietly")
        keeper.observe(point: Self.seattlePoint, at: Self.at(9))
        keeper.observe(point: Self.seattlePoint, at: Self.at(9.5))
        keeper.endDiscoveries()
        let heard = await Self.drain(stream)
        #expect(heard.compactMap(\.trip) == [PassportStamp(kind: .country, token: "US", date: Self.at(9), trip: 4)])
        #expect(heard.compactMap(\.discovery).map(\.token) == ["Q5083"], "the decoy's fix announced nothing")
    }

    // MARK: The sealed backup

    /// The backup carries a record per trip (the latest with the clock) and reads back the same book; an old
    /// record, one per country with no `last`, reads as that country's one trip.
    @Test func theBackupCarriesTripsAndOldRecordsReadAsOneTripEach() throws {
        let book = Self.book([(Self.us, Self.t0), (Self.france, Self.at(1)), (Self.us, Self.at(9)), (Self.us, Self.at(10))])
        var records: [PassportBackupRecord] = []
        for discovery in book.discoveries + book.returnVisits {
            let trips = book.trips(inCountry: discovery.token)
            let clock = discovery.kind == .country && discovery.at == trips.last ? book.lastSeen(inCountry: discovery.token) : nil
            records.append(PassportBackupRecord(id: UUID(), kind: discovery.kind.rawValue, token: discovery.token,
                                                date: discovery.at, lastSeen: clock))
        }
        #expect(records.filter { $0.token == "US" }.count == 2)
        let bytes = try JSONEncoder().encode(records)
        let decoded = try JSONDecoder().decode([PassportBackupRecord].self, from: bytes)
        #expect(try PassportBackupAdapter.book(of: decoded) == book)
        let old = Data(#"[{"id":"\#(UUID().uuidString)","kind":"country","token":"US","first":1792800000}]"#.utf8)
        let oldRecords = try JSONDecoder().decode([PassportBackupRecord].self, from: old)
        #expect(oldRecords.first?.lastSeen == nil)
        let restored = try PassportBackupAdapter.book(of: oldRecords)
        #expect(restored.trips(inCountry: "US") == [Self.t0] && restored.lastSeen(inCountry: "US") == Self.t0)
        let object = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(PassportBackupRecord(id: UUID(), kind: "country", token: "US", date: Self.t0,
                                                            lastSeen: Self.at(2)))) as? [String: Any])
        #expect(Set(object.keys) == ["id", "kind", "token", "first", "last"], "FROZEN keys")
    }

    /// A restore keeps each trip once: the same trips twice change nothing, a trip only one side has is added,
    /// and a trip that began within 7 days of the other side's last fix there is the same trip, not a second.
    @Test func aMergeKeepsEachTripOnce() throws {
        let old = Self.book([(Self.us, Self.t0), (Self.us, Self.at(10)), (Self.us, Self.at(30))])
        var here = old
        #expect(here.merge(old) == 0 && here == old, "the same trips merge to nothing new")
        var phone = Self.book([(Self.us, Self.at(10)), (Self.us, Self.at(20)), (Self.us, Self.at(45))])
        #expect(phone.merge(old) == 4, "the first trip and the day-30 trip are new; the continent and terrain move earlier")
        #expect(phone.trips(inCountry: "US") == [Self.t0, Self.at(10), Self.at(20), Self.at(30), Self.at(45)],
                "the day-10 trip both had is kept once")
        #expect(phone.merge(old) == 0, "merging twice adds nothing")
        #expect(phone.discoveries(of: .country) == 1, "still one country")
        var newPhone = Self.book([(Self.us, Self.at(33))])
        _ = newPhone.merge(old)
        #expect(newPhone.trips(inCountry: "US") == [Self.t0, Self.at(10), Self.at(30)],
                "a new phone's first fix three days after the old phone's last is not a new trip")
        #expect(newPhone.lastSeen(inCountry: "US") == Self.at(33))
        let twice = try PassportBackupAdapter.book(of: [
            PassportBackupRecord(id: UUID(), kind: "country", token: "US", date: Self.t0),
            PassportBackupRecord(id: UUID(), kind: "country", token: "US", date: Self.t0),
            PassportBackupRecord(id: UUID(), kind: "country", token: "US", date: Self.at(10))
        ])
        #expect(twice.trips(inCountry: "US") == [Self.t0, Self.at(10)], "a record twice is one trip")
    }
}
