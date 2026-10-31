import FernletDomainModel
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// The passport's reusable pieces (World-Exploration-Spec §3; round 7, lane explore-ui, held for Sprout's passport
/// redesign): the progress counts, every continent's countries adding up to 194, the stamps' stable tilt, the sea
/// inks (the spec's named seas exactly, neighbours apart), dark mode's `mix2`, and a decoy counting nothing.
@MainActor
struct PassportStampsTests {
    nonisolated static let t1 = Date(timeIntervalSince1970: 1_792_800_000)
    nonisolated static let t2 = Date(timeIntervalSince1970: 1_792_886_400)
    nonisolated static let t3 = Date(timeIntervalSince1970: 1_792_972_800)

    /// The shipped atlas, opened once for the suite.
    static let atlas: WorldAtlas? = {
        guard let url = Bundle.main.url(forResource: "WorldAtlas", withExtension: "pack"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? WorldAtlas(data: data)
    }()

    // MARK: Progress

    /// Countries N of 194 (a territory counts toward its sovereign, once), continents N of 7, oceans N of 5, the
    /// seas counted, the specials, and a continent's countries in first-visit order.
    @Test func theProgressCountsWhatTheBookHolds() throws {
        let atlas = try #require(Self.atlas)
        let book = try PassportBook(discoveries: [
            AtlasDiscovery(kind: .country, token: "CA", at: Self.t2), AtlasDiscovery(kind: .country, token: "US", at: Self.t1),
            AtlasDiscovery(kind: .country, token: "PR", at: Self.t3), AtlasDiscovery(kind: .country, token: "GB", at: Self.t3),
            AtlasDiscovery(kind: .continent, token: "northAmerica", at: Self.t1),
            AtlasDiscovery(kind: .continent, token: "europe", at: Self.t3),
            AtlasDiscovery(kind: .ocean, token: "pacific", at: Self.t1),
            AtlasDiscovery(kind: .sea, token: "Q1247", at: Self.t2), AtlasDiscovery(kind: .sea, token: "Q4918", at: Self.t3)
        ])
        let progress = PassportProgress(book: book, table: PassportCountryTable(atlas: atlas))
        #expect(progress.countries == ["US", "CA", "GB"], "Puerto Rico counts toward the United States, once")
        #expect(progress.countryCount == 3 && PassportProgress.countryTotal == 194)
        #expect(progress.continentCount == 2 && PassportProgress.continentTotal == 7)
        #expect(progress.oceanCount == 1 && PassportProgress.oceanTotal == 5)
        #expect(progress.seaCount == 2 && progress.seas == ["Q1247", "Q4918"])
        #expect(progress.specialsEarned == 0 && !progress.hasAllContinents && !progress.hasAllOceans)
        #expect(progress.earned(in: .northAmerica) == ["US", "CA"] && progress.earned(in: .europe) == ["GB"])
        #expect(progress.total(in: .northAmerica) == 23)
    }

    /// Every continent and every ocean earns its special.
    @Test func theSpecialsAreEarnedWithAllSevenAndAllFive() throws {
        let continents = AtlasContinent.allCases.map { AtlasDiscovery(kind: .continent, token: $0.rawValue, at: Self.t1) }
        let oceans = AtlasOcean.allCases.map { AtlasDiscovery(kind: .ocean, token: $0.rawValue, at: Self.t2) }
        let progress = PassportProgress(book: try PassportBook(discoveries: continents + oceans), table: .empty)
        #expect(progress.hasAllContinents && progress.hasAllOceans && progress.specialsEarned == 2)
    }

    /// The continents' countries add up to the passport's 194, North Korea out, each as the spec counts it.
    @Test func everyContinentsCountriesAddUpTo194() throws {
        let table = PassportCountryTable(atlas: try #require(Self.atlas))
        let progress = PassportProgress(book: PassportBook(), table: table)
        let totals = AtlasContinent.passportOrder.map { progress.total(in: $0) }
        #expect(totals.reduce(0, +) == WorldAtlas.passportCountryTotal)
        #expect(totals == AtlasContinent.passportOrder.map(\.specCountryTotal), "\(totals)")
        #expect(table.passportCode(for: "KP") == nil, "North Korea is out of the passport")
        #expect(table.continentOf.count == 194)
    }

    /// A decoy's passport is empty, so the progress counts nothing.
    @Test func aDecoyCountsNothing() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = WorldPassportTests.keeper(vault)
        keeper.observe(point: WorldPassportTests.portlandPoint, at: Self.t1)
        let table = PassportCountryTable(atlas: try #require(Self.atlas))
        #expect(PassportProgress(book: keeper.book, table: table).countryCount == 1)
        keeper.setDecoy(true)
        let decoy = PassportProgress(book: keeper.book, table: table)
        #expect(decoy.countryCount == 0 && decoy.continentCount == 0 && decoy.oceanCount == 0 && decoy.seaCount == 0)
        #expect(decoy.specialsEarned == 0)
    }

    /// A country stamped on several trips still counts once, as do a continent, an ocean and a sea; the specials'
    /// own entries count nothing.
    @Test func repeatTripsCountACountryOnce() {
        let entries = [
            PassportStampEntry(kind: .country, token: "CA", date: Self.t1),
            PassportStampEntry(kind: .country, token: "CA", date: Self.t3),
            PassportStampEntry(kind: .continent, token: "northAmerica", date: Self.t1),
            PassportStampEntry(kind: .sea, token: "Q1247", date: Self.t2),
            PassportStampEntry(kind: .sea, token: "Q1247", date: Self.t3),
            PassportStampEntry(kind: .special, token: PassportStampEntry.allOceansToken, date: Self.t3)
        ]
        let progress = PassportProgress(entries: entries, table: .empty)
        #expect(progress.countryCount == 1 && progress.continentCount == 1 && progress.seaCount == 1)
        #expect(progress.oceanCount == 0 && progress.specialsEarned == 0)
    }

    // MARK: Visit order

    /// Stamps land in visit order: by day, then reading time; a country then its continent at the same moment;
    /// the specials mixed in on their day; six to a page; the input's order never matters.
    @Test func stampsLandInVisitOrderSixToAPage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let morning = Self.t1, noon = Self.t1.addingTimeInterval(3_600)
        let continents = AtlasContinent.allCases.map { AtlasDiscovery(kind: .continent, token: $0.rawValue, at: noon) }
        let book = try PassportBook(discoveries: continents + [
            AtlasDiscovery(kind: .country, token: "US", at: noon), AtlasDiscovery(kind: .ocean, token: "pacific", at: morning),
            AtlasDiscovery(kind: .sea, token: "Q1247", at: Self.t2), AtlasDiscovery(kind: .country, token: "JP", at: Self.t3),
            AtlasDiscovery(kind: .city, token: "Q6106", at: morning)
        ])
        let entries = PassportStampEntry.firstVisits(in: book)
        #expect(entries.count == 12, "7 continents, 2 countries, an ocean, a sea and the continents special; no city")
        let ordered = PassportStampEntry.ordered(entries, calendar: calendar)
        #expect(ordered.first?.token == "pacific", "the earlier reading on the same day comes first")
        #expect(ordered[1].token == "US", "at the same moment the country lands first")
        #expect(ordered[2...8].allSatisfy { $0.kind == .continent }, "its continents beside it")
        #expect(ordered[9].kind == .special && ordered[9].token == PassportStampEntry.allContinentsToken)
        let trips = [PassportStampEntry(kind: .country, token: "US", date: Self.t3, trip: 2),
                     PassportStampEntry(kind: .country, token: "US", date: Self.t1, trip: 1)]
        #expect(PassportStampEntry.ordered(trips, calendar: calendar).map(\.trip) == [1, 2])
        #expect(PassportStampEntry(kind: .country, token: "US", date: Self.t1, trip: 0).trip == 1)
        #expect(ordered.suffix(2).map(\.token) == ["Q1247", "JP"])
        #expect(PassportStampEntry.ordered(Array(entries.reversed()), calendar: calendar) == ordered)
        let pages = PassportStampEntry.pages(entries, calendar: calendar)
        #expect(pages.map(\.count) == [6, 6] && pages.joined().map(\.self) == ordered)
        #expect(PassportStampEntry.pages([], calendar: calendar).isEmpty)
    }

    /// The date box prints "14 AUG 2026" / "14 AGO 2026", and VoiceOver hears the long form.
    @Test func theDateBoxPrintsTheSpecsMonths() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let august = try #require(DateComponents(calendar: calendar, year: 2026, month: 8, day: 14, hour: 12).date)
        #expect(PassportDates.short(august, calendar: calendar, language: .english) == "14 AUG 2026")
        #expect(PassportDates.short(august, calendar: calendar, language: .spanish) == "14 AGO 2026")
        let september = try #require(DateComponents(calendar: calendar, year: 2026, month: 9, day: 2, hour: 12).date)
        #expect(PassportDates.short(september, calendar: calendar, language: .spanish) == "2 SEP 2026")
        #expect(PassportDates.long(september, calendar: calendar, language: .english) == "2 September 2026")
        #expect(PassportDates.long(september, calendar: calendar, language: .spanish) == "2 de septiembre de 2026")
    }

    /// The date box's ink reads at 4.6:1 on the passport's paper (7:1 with Increase Contrast), light and dark, for
    /// every stamp ink there is.
    @Test func theDateBoxInkPassesContrast() throws {
        let stamps = try #require(WorldCountryStampsLoader.bundled())
        let inks: [UInt32] = stamps.inks.map { UInt32($0.red) << 16 | UInt32($0.green) << 8 | UInt32($0.blue) }
            + AtlasContinent.allCases.map(\.stampInk) + AtlasOcean.allCases.map(\.stampInk) + PassportSeaInks.palette
            + [0x9A6E14]
        for ink in inks {
            for dark in [false, true] {
                for strong in [false, true] {
                    let text = PassportInk.dateInk(ink, dark: dark, increasedContrast: strong)
                    let ratio = PassportInk.contrast(text, PassportInk.paper(dark: dark))
                    #expect(ratio >= (strong ? 7 : 4.5), "\(String(ink, radix: 16)) dark \(dark) strong \(strong)")
                }
            }
        }
        #expect(PassportInk.dateInk(0x2A1808, dark: false, increasedContrast: false) == 0x2A1808, "dark enough as is")
    }

    // MARK: Tilt

    /// The tilt comes from the mockup's own hash of the stamp's key, so it is the same every launch and lands
    /// within −6…+6 for every stamp.
    @Test func theTiltIsStableAndInRange() throws {
        #expect(PassportStampSeed.seed("us") == 117 * 31 + 115)
        #expect(PassportStampSeed.tilt("us") == 5 && PassportStampSeed.tilt("us") == PassportStampSeed.tilt("us"))
        #expect(PassportStampSeed.tilt("na") == Int((110 * 31 + 97) % 13) - 6)
        let stamps = try #require(WorldCountryStampsLoader.bundled())
        let keys = stamps.stamps.keys.map { $0.lowercased() } + AtlasContinent.allCases.map(\.stampKey)
            + AtlasOcean.allCases.map(\.rawValue) + (Self.atlas?.seas.map(\.token) ?? [])
        let tilts = keys.map(PassportStampSeed.tilt)
        #expect(tilts.allSatisfy { (-6...6).contains($0) })
        #expect(Set(tilts).count > 6, "the tilts vary from stamp to stamp")
        let nudges = (keys + ["continents!", "oceans!"]).map(PassportStampSeed.nudge)
        #expect(nudges.allSatisfy { (-7...7).contains($0.across) && (-5...5).contains($0.down) })
        #expect(PassportStampSeed.nudge("us").across == Int((3_742 >> 3) % 15) - 7, "the mockup's rule")
        #expect(PassportStampSeed.nudge("us").down == Int((3_742 >> 7) % 11) - 5)
        #expect(PassportStampModel(kind: .country("us"), firstVisit: nil, wear: 4).wear == 1)
    }

    // MARK: Inks

    /// Dark mode lifts every ink 38 % toward white, rounded as the mockup's `mix2` rounds.
    @Test func darkModeLiftsEachInk38PercentTowardWhite() {
        #expect(PassportInk.mix2(0x1B3F8B) == 0x7288B7)
        #expect(PassportInk.mix2(0x000000) == 0x616161)
        #expect(PassportInk.mix2(0xFFFFFF) == 0xFFFFFF)
        #expect(PassportInk.resolved(0x2F6FA3, dark: false) == 0x2F6FA3)
        #expect(PassportInk.resolved(0x2F6FA3, dark: true) == PassportInk.mix2(0x2F6FA3))
    }

    /// The spec's named seas take exactly its inks, and each is in the atlas under its name.
    @Test func theNamedSeasTakeTheSpecsInks() throws {
        let atlas = try #require(Self.atlas)
        let inks = PassportSeaInks(tokens: atlas.seas.map(\.token), neighbours: atlas.seaNeighbours())
        let named: [(String, String, UInt32)] = [
            ("Q1247", "Caribbean Sea", 0x0E8EA6), ("Q27092", "Sea of Japan", 0x2F86C8),
            ("Q4918", "Mediterranean Sea", 0x2F86C8), ("Q199408", "Alboran Sea", 0x12938A),
            ("Q200712", "Balearic Sea", 0x4A7FD0), ("Q42820", "Ligurian Sea", 0x1B8C80),
            ("Q38882", "Tyrrhenian Sea", 0x0E8EA6), ("Q37495", "Ionian Sea", 0x2E78C2),
            ("Q13924", "Adriatic Sea", 0x2C8FB0), ("Q34575", "Aegean Sea", 0x0F7F99), ("Q193149", "Sea of Crete", 0x12938A)
        ]
        for (token, name, ink) in named {
            #expect(atlas.sea(token: token)?.names.english == name, "\(name) is \(token) in SEAS")
            #expect(inks.ink(for: token) == ink, "\(name)")
        }
        #expect(atlas.seas.allSatisfy { PassportSeaInks.palette.contains(inks.ink(for: $0.token)) })
    }

    /// Neighbouring seas never share an ink, where the eight blues leave a free one; the Mediterranean's own
    /// neighbours are told apart; and the same atlas always gives the same inks.
    @Test func neighbouringSeasTakeDifferentInks() throws {
        let atlas = try #require(Self.atlas)
        let neighbours = atlas.seaNeighbours()
        #expect(neighbours["Q4918"]?.contains("Q34575") == true, "the Mediterranean touches the Aegean")
        #expect(neighbours["Q34575"]?.contains("Q4918") == true, "both ways")
        let inks = PassportSeaInks(tokens: atlas.seas.map(\.token), neighbours: neighbours)
        for (token, touching) in neighbours where PassportSeaInks.fixed[token] == nil && touching.count < 8 {
            for other in touching {
                #expect(inks.ink(for: token) != inks.ink(for: other), "\(token) and \(other) touch")
            }
        }
        #expect(PassportSeaInks(tokens: Array(atlas.seas.map(\.token).reversed()), neighbours: neighbours) == inks)
    }

    /// Every passport screen draws its sea inks from the keeper's one table of which seas touch (each screen's own
    /// pass over the sea raster held the main thread for 476 ms on a page turn): the atlas's own answer, kept, the
    /// same inks a library works out alone, and empty with no atlas.
    @Test func theKeeperKeepsOneSeaTableForEveryScreen() throws {
        let atlas = try #require(Self.atlas)
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = WorldAtlasKeeper(vault: vault, openAtlas: { atlas })
        let table = keeper.seaNeighbours()
        #expect(table == atlas.seaNeighbours())
        #expect(keeper.seaNeighbours() == table)
        let shared = PassportLibrary(openAtlas: { atlas }, seaNeighbours: { keeper.seaNeighbours() })
        #expect(shared.seaInks == PassportLibrary(openAtlas: { atlas }).seaInks)
        #expect(WorldAtlasKeeper(vault: vault, openAtlas: { nil }).seaNeighbours().isEmpty)
    }

    /// A continent's silhouette comes from the atlas: North America is 22 × 11 with land in it, and Antarctica is
    /// drawn round the pole.
    @Test func theSilhouettesComeFromTheAtlas() throws {
        let atlas = try #require(Self.atlas)
        let america = PassportStampArt.silhouette(.northAmerica, width: 22, atlas: atlas)
        #expect(america.count == 11 && america.allSatisfy { $0.count == 22 })
        #expect(america.joined().filter { $0 }.count > 40)
        let ice = PassportStampArt.silhouette(.antarctica, width: 18, atlas: atlas)
        #expect(ice.count == 18 && ice[9][9], "the pole is ice")
        #expect(!ice[0][0], "the corners are past 60°S")
    }
}
