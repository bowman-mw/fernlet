import FernletDomainModel
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Sprout's passport book (World-Passport-Spec §2–§9): six stamps a page, the pages and the contents' ranges, the
/// ribbon's page, the index's rows with every trip's page, a continent's A to Z with its unnamed spaces (Spanish
/// sorting by the Spanish names), the new stamp opening its page once, and the fresh, full and decoy page counts.
@MainActor
struct PassportBookTests {
    nonisolated static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    nonisolated static func day(_ month: Int, _ day: Int, year: Int = 2026, minute: Int = 0) -> Date {
        DateComponents(calendar: utc, year: year, month: month, day: day, hour: 10, minute: minute).date ?? .distantPast
    }

    /// The mockup's sample traveller (13 stamps) with a second trip to the United States: 14 stamps, 3 pages.
    nonisolated static let sample: [PassportStampEntry] = {
        let rows: [(PassportStampEntry.Kind, String, Int, Int, Int)] = [
            (.continent, "northAmerica", 8, 14, 1), (.country, "US", 8, 14, 1), (.ocean, "pacific", 8, 16, 1),
            (.country, "CA", 9, 2, 1), (.country, "MX", 9, 20, 1), (.sea, "Q1247", 9, 21, 1),
            (.continent, "europe", 10, 3, 1), (.country, "GB", 10, 3, 1), (.ocean, "atlantic", 10, 5, 1),
            (.country, "FR", 10, 9, 1), (.continent, "asia", 10, 22, 1), (.country, "JP", 10, 22, 1),
            (.country, "US", 10, 23, 2), (.sea, "Q27092", 10, 24, 1)
        ]
        return rows.enumerated().map { index, row in
            PassportStampEntry(kind: row.0, token: row.1, date: day(row.2, row.3, minute: index), trip: row.4)
        }
    }()

    /// A small country table: North America's four, Europe's two, Asia's one; Puerto Rico counts toward the US.
    nonisolated static let table = PassportCountryTable(
        continentOf: ["US": .northAmerica, "CA": .northAmerica, "MX": .northAmerica, "GT": .northAmerica,
                      "GB": .europe, "FR": .europe, "JP": .asia],
        countsToward: ["US": "US", "CA": "CA", "MX": "MX", "GT": "GT", "GB": "GB", "FR": "FR", "JP": "JP", "PR": "US"],
        totals: [.northAmerica: 4, .europe: 2, .asia: 1])

    nonisolated static let english = ["US": "United States", "CA": "Canada", "MX": "Mexico", "GT": "Guatemala",
                                      "GB": "United Kingdom", "FR": "France", "JP": "Japan"]
    nonisolated static let spanish = ["US": "Estados Unidos", "CA": "Canadá", "MX": "México", "GT": "Guatemala",
                                      "GB": "Reino Unido", "FR": "Francia", "JP": "Japón"]

    nonisolated static func name(_ kind: PassportStampKind) -> String {
        switch kind {
        case .country(let code): english[code] ?? code
        case .ocean(let ocean): ocean.rawValue.capitalized
        case .sea(let token): token == "Q1247" ? "Caribbean Sea" : "Sea of Japan"
        default: ""
        }
    }

    // MARK: Paging

    /// Six a page in visit order; page 1 Sprout, 2 Your world, the stamp pages, the index last.
    @Test func stampsLandSixAPageAfterTheWorldPage() {
        let book = PassportBookModel(entries: Array(Self.sample.reversed()), calendar: Self.utc)
        #expect(book.stampPages.map(\.count) == [6, 6, 2])
        #expect(book.pageCount == 6 && book.indexPage == 6 && book.stampPageNumbers == 3 ... 5)
        #expect(book.page(at: 1) == .sprout && book.page(at: 2) == .world && book.page(at: 4) == .stamps(1))
        #expect(book.page(at: 6) == .index && book.page(at: 99) == .index && book.page(at: -3) == .sprout)
        #expect(book.stamps(onStampPage: 0).first?.token == "northAmerica", "the continent's reading came first")
        #expect(book.stamps(onStampPage: 0).map(\.token) == ["northAmerica", "US", "pacific", "CA", "MX", "Q1247"])
        let second = book.stamps(onStampPage: 2)
        #expect(second.map(\.token) == ["US", "Q27092"] && second.first?.trip == 2)
        #expect(book.isNewestStampPage(2) && !book.isNewestStampPage(1))
    }

    /// The contents' range and each page's months ("AUG – SEP 2026"), and VoiceOver's days.
    @Test func theContentsAndHeadersReadTheirDates() throws {
        let book = PassportBookModel(entries: Self.sample, calendar: Self.utc)
        let first = try #require(book.dates(onStampPage: 0)), span = try #require(book.dateSpan)
        #expect(PassportBookDates.months(from: first.first, to: first.last, calendar: Self.utc, language: .english)
            == "AUG – SEP 2026")
        #expect(PassportBookDates.months(from: first.first, to: first.last, calendar: Self.utc, language: .spanish)
            == "AGO – SEP 2026")
        let second = try #require(book.dates(onStampPage: 1))
        #expect(PassportBookDates.months(from: second.first, to: second.last, calendar: Self.utc, language: .english)
            == "OCT 2026")
        #expect(PassportBookDates.months(from: Self.day(12, 30), to: Self.day(1, 2, year: 2027), calendar: Self.utc,
                                         language: .english) == "DEC 2026 – JAN 2027")
        #expect(PassportBookDates.shortDay(span.first, calendar: Self.utc, language: .english) == "14 AUG")
        #expect(PassportBookDates.shortDay(span.last, calendar: Self.utc, language: .spanish) == "24 OCT")
        #expect(PassportBookDates.dayMonth(first.last, calendar: Self.utc, language: .english) == "21 September")
        #expect(PassportBookDates.dayMonth(first.last, calendar: Self.utc, language: .spanish) == "21 de septiembre")
    }

    /// The ribbon marks the newest stamp's page; a fresh passport has none.
    @Test func theRibbonMarksTheNewestStampsPage() {
        let book = PassportBookModel(entries: Self.sample, calendar: Self.utc)
        #expect(book.newest?.token == "Q27092" && book.ribbonPage == 5)
        #expect(PassportBookModel(entries: Array(Self.sample.prefix(6)), calendar: Self.utc).ribbonPage == 3)
        #expect(PassportBookModel(entries: [], calendar: Self.utc).ribbonPage == nil)
    }

    // MARK: The index

    /// One row per continent with its found countries A to Z and every page they're on; oceans and seas A to Z;
    /// nothing unvisited named.
    @Test func theIndexListsWhatWasFoundWithEveryTripsPage() throws {
        let book = PassportBookModel(entries: Self.sample, calendar: Self.utc)
        let index = PassportIndexModel(book: book, table: Self.table, language: .english, name: Self.name)
        #expect(index.continents.map(\.continent) == AtlasContinent.passportOrder)
        let america = try #require(index.row(.northAmerica))
        #expect(america.places.map(\.name) == ["Canada", "Mexico", "United States"])
        #expect(america.places.map(\.pages) == [[3], [3], [3, 5]], "United States 3, 5: a stamp each trip")
        #expect(america.earned && america.total == 4 && america.page == 3)
        #expect(!america.places.contains { $0.token == "GT" }, "never named until found")
        let europe = try #require(index.row(.europe))
        #expect(europe.places.map(\.name) == ["France", "United Kingdom"] && europe.places.map(\.pages) == [[4], [4]])
        #expect(index.row(.southAmerica)?.places.isEmpty == true && index.row(.southAmerica)?.earned == false)
        #expect(index.row(.antarctica)?.total == 1 && index.row(.antarctica)?.earned == false)
        #expect(index.oceans.map(\.token) == ["atlantic", "pacific"] && index.oceans.map(\.pages) == [[4], [3]])
        #expect(index.seas.map(\.name) == ["Caribbean Sea", "Sea of Japan"] && index.seas.map(\.pages) == [[3], [5]])
        #expect(index.countryCount == 6)
    }

    /// A territory's stamps count toward its sovereign in the index, on their own pages.
    @Test func aTerritoryIsIndexedUnderItsSovereign() throws {
        let entries = Self.sample + [PassportStampEntry(kind: .country, token: "PR", date: Self.day(11, 2))]
        let book = PassportBookModel(entries: entries, calendar: Self.utc)
        let index = PassportIndexModel(book: book, table: Self.table, language: .english, name: Self.name)
        let states = try #require(index.row(.northAmerica)?.places.first { $0.token == "US" })
        #expect(states.pages == [3, 5] && index.countryCount == 6)
    }

    // MARK: A to Z

    /// Every country of the continent A to Z, the earned ones with their trips and first page, the rest unnamed
    /// spaces in their alphabetical place.
    @Test func aContinentsCountriesRunAToZWithUnnamedSpaces() {
        let book = PassportBookModel(entries: Self.sample, calendar: Self.utc)
        let sheet = PassportContinentSheet(continent: .northAmerica, book: book, table: Self.table,
                                           language: .english) { Self.english[$0] ?? $0 }
        #expect(sheet.cells.map(\.code) == ["CA", "GT", "MX", "US"])
        #expect(sheet.cells.map(\.earned) == [true, false, true, true] && sheet.earnedCount == 3)
        #expect(sheet.cells.map(\.trips) == [1, 0, 1, 2])
        #expect(sheet.cells.map(\.firstPage) == [3, nil, 3, 3])
    }

    /// In Spanish the A to Z follows the Spanish names (Estados Unidos before Guatemala and México).
    @Test func spanishSortsBySpanishNames() {
        let book = PassportBookModel(entries: Self.sample, calendar: Self.utc)
        let sheet = PassportContinentSheet(continent: .northAmerica, book: book, table: Self.table,
                                           language: .spanish) { Self.spanish[$0] ?? $0 }
        #expect(sheet.cells.map(\.code) == ["CA", "US", "GT", "MX"])
        let index = PassportIndexModel(book: book, table: Self.table, language: .spanish) { kind in
            if case .country(let code) = kind { return Self.spanish[code] ?? code }
            return Self.name(kind)
        }
        #expect(index.row(.northAmerica)?.places.map(\.name) == ["Canadá", "Estados Unidos", "México"])
    }

    // MARK: The presenter

    /// A new stamp makes the next open go to its page once, then opens are page 1 again.
    @Test func aNewStampOpensItsPageOnce() throws {
        let presenter = WorldPassportPresenter()
        let book = PassportBookModel(entries: Self.sample, calendar: Self.utc)
        let newest = try #require(book.newest)
        presenter.noteNewStamp(newest)
        presenter.open()
        #expect(presenter.isPresented && presenter.landing == newest && presenter.startPage(in: book) == 5)
        presenter.dismiss()
        #expect(!presenter.isPresented && presenter.landing == nil)
        presenter.open()
        #expect(presenter.landing == nil && presenter.startPage(in: book) == 1)
        presenter.dismiss()
        presenter.open(page: 2)
        #expect(presenter.startPage(in: book) == 2 && presenter.openCount == 3)
        presenter.close()
        #expect(presenter.isClosing && presenter.isPresented)
        presenter.dismiss()
        presenter.close()
        #expect(!presenter.isClosing)
    }

    // MARK: Fresh, full, decoy

    /// A fresh passport has 4 pages and no ribbon; a decoy's book is fresh too.
    @Test func aFreshOrDecoyPassportHasFourPages() {
        let fresh = PassportBookModel(entries: [], calendar: Self.utc)
        #expect(fresh.isFresh && fresh.pageCount == 4 && fresh.stampPageNumbers == 3 ... 3 && fresh.ribbonPage == nil)
        #expect(fresh.page(at: 3) == .stamps(0) && fresh.page(at: 4) == .index && fresh.stamps(onStampPage: 0).isEmpty)
        let decoy = PassportBookModel(entries: PassportStampEntry.entries(of: PassportBook()), calendar: Self.utc)
        #expect(decoy.pageCount == 4)
    }

    /// A full passport: 194 countries, 7 continents, 5 oceans and the 2 specials make 208 stamps, 35 stamp pages,
    /// 38 pages; the specials share the last row.
    @Test func aFullPassportGrowsPastThirtyPages() {
        let codes = (0 ..< 194).map { String(format: "C%03d", $0) }
        var entries = codes.enumerated().map { PassportStampEntry(kind: .country, token: $1, date: Self.day(1, 1, year: 2027 + $0 / 30)) }
        entries += AtlasContinent.allCases.map { PassportStampEntry(kind: .continent, token: $0.rawValue, date: Self.day(1, 1, year: 2040)) }
        entries += AtlasOcean.allCases.map { PassportStampEntry(kind: .ocean, token: $0.rawValue, date: Self.day(1, 1, year: 2040)) }
        entries += [PassportStampEntry(kind: .special, token: PassportStampEntry.allContinentsToken, date: Self.day(1, 1, year: 2040)),
                    PassportStampEntry(kind: .special, token: PassportStampEntry.allOceansToken, date: Self.day(1, 1, year: 2040))]
        let book = PassportBookModel(entries: entries, calendar: Self.utc)
        #expect(book.stampPages.count == 35 && book.pageCount == 38 && book.ribbonPage == 37)
        #expect(book.stampPages.last?.suffix(2).map(\.kind) == [.special, .special])
    }

    /// The per-trip store's stamps map to page entries, the specials to this layer's tokens.
    @Test func theStoresStampsMapToPageEntries() {
        let date = Self.day(8, 14)
        let mapped = [PassportStamp(kind: .country, token: "US", date: date, trip: 2),
                      PassportStamp(kind: .allContinents, token: "allContinents", date: date),
                      PassportStamp(kind: .allOceans, token: "allOceans", date: date)].compactMap(PassportStampEntry.init(stamp:))
        #expect(mapped.count == 3)
        #expect(mapped[0] == PassportStampEntry(kind: .country, token: "US", date: date, trip: 2))
        #expect(mapped[1].kind == .special && mapped[1].token == PassportStampEntry.allContinentsToken)
        #expect(mapped[2].stampKind == .special(allOceans: true))
        #expect(PassportStampEntry(stamp: PassportStamp(kind: .airport, token: "PDX", date: date)) == nil,
                "an airport's stamp waits for its own ticket stamp")
    }
}
