#if DEBUG
import FernletUI
import SwiftUI
import WorldMapStore

/// DEBUG-only: the passport's stamp kinds on a Today panel frame, for the round's screenshots (`ex-pass-stamps`,
/// `ex-pass-country`) while Sprout's passport is redesigned. Opened by `FERNLET_UI_TEST_WORLD_GALLERY=<scene>`
/// (through ``WorldFoundationGallery``); it opens the bundled atlas itself and reads no one's data: every stamp is
/// shown earned (or empty) by hand.
///
/// Scenes: `passportStamps` (the 7 continents, the 5 oceans and a sea, the two specials earned and not, the mockup's
/// `allStamps` board), `passportSeas` (the Caribbean, the Sea of Japan and the Mediterranean's nine, then empty
/// spaces of every shape) and `passportCountry` (North America's 23 country stamps four to a row at the spread's
/// size, then a few two-line labels), and `passportPage` / `passportPage2` (the mockup's sample traveller's first two
/// stamp pages, `ps-stamps` and `ps-stamps-2`, placed by ``PassportStampEntry/pages(_:calendar:)`` with their date
/// boxes; the book around them is another piece's). Its words are verbatim: DEBUG copy, never harvested into a catalog.
struct PassportStampGallery: View {
    let scene: String
    @State private var library = PassportLibrary(openAtlas: {
        WorldAtlasKeeper.bundledPack(open: { try WorldAtlas(data: $0) })() as? WorldAtlas
    })

    /// The scenes this gallery draws.
    static let scenes: Set<String> = ["passportStamps", "passportSeas", "passportCountry", "passportPage",
                                      "passportPage2"]

    var body: some View {
        WorldPanelFrame(panel: .today, onClose: {}) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch scene {
                    case "passportSeas": seas
                    case "passportCountry": countries
                    case "passportPage": page(0)
                    case "passportPage2": page(1)
                    default: board
                    }
                }
                .padding(20)
            }
            .fernletPageBackground()
        }
        .worldDesignLanguage()
    }

    /// The 14 stamps (`ex-pass-stamps` draft 2).
    @ViewBuilder
    private var board: some View {
        heading("7 continents")
        grid(AtlasContinent.passportOrder.map { .continent($0) }, scale: 1.2, names: true)
        heading("5 oceans, and the seas")
        grid(AtlasOcean.passportOrder.map { .ocean($0) } + [.sea("Q1247")], scale: 1.2, names: true)
        heading("The two specials, in full colour")
        HStack(alignment: .top, spacing: 10) {
            special(allOceans: false, earned: true)
            special(allOceans: true, earned: true)
        }
        heading("Not earned yet")
        HStack(alignment: .top, spacing: 10) {
            special(allOceans: false, earned: false)
            special(allOceans: true, earned: false)
        }
    }

    /// The named seas' blues and the empty spaces.
    @ViewBuilder
    private var seas: some View {
        heading("Seas, each its own blue")
        grid(["Q1247", "Q27092", "Q4918", "Q199408", "Q200712", "Q42820", "Q38882", "Q37495", "Q13924", "Q34575",
              "Q193149"].map { .sea($0) }, scale: 1.15, names: true)
        heading("Not reached yet")
        grid([.country("us"), .continent(.europe), .ocean(.indian), .sea("Q1247")], scale: 1.15, names: false,
             earned: false)
    }

    /// Country stamps at the spread's size, four to a row (`ex-pass-country`).
    @ViewBuilder
    private var countries: some View {
        heading("North America, 23 of 23")
        grid(["us", "ca", "mx", "gt", "bz", "hn", "sv", "ni", "cr", "pa", "cu", "jm", "ht", "do", "bs", "bb", "tt",
              "lc", "gd", "vc", "ag", "dm", "kn"].map { .country($0) }, scale: 1.25, names: true)
        heading("Long names")
        grid(["az", "vn", "cf", "ba"].map { .country($0) }, scale: 1.25, names: true)
    }

    /// One of the sample traveller's stamp pages: six stamps, two across and three down, 172 pt a row.
    @ViewBuilder
    private func page(_ index: Int) -> some View {
        let pages = PassportStampEntry.pages(Self.sampleLog)
        heading(index == 0 ? "STAMPS · Aug – Sep 2026" : "STAMPS · Oct 2026")
        if pages.indices.contains(index) {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 2)
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(pages[index], id: \.self) { entry in
                    PassportPlacedStamp(entry: entry, library: library)
                        .frame(maxWidth: .infinity, minHeight: 172)
                }
            }
        }
    }

    /// The mockup's sample traveller (`PP.LOG`): Portland since August, with the atlas's sea tokens.
    static let sampleLog: [PassportStampEntry] = {
        let rows: [(PassportStampEntry.Kind, String, Int, Int)] = [
            (.continent, "northAmerica", 8, 14), (.country, "US", 8, 14), (.ocean, "pacific", 8, 16),
            (.country, "CA", 9, 2), (.country, "MX", 9, 20), (.sea, "Q1247", 9, 21), (.continent, "europe", 10, 3),
            (.country, "GB", 10, 3), (.ocean, "atlantic", 10, 5), (.country, "FR", 10, 9), (.continent, "asia", 10, 22),
            (.country, "JP", 10, 22), (.sea, "Q27092", 10, 24)
        ]
        return rows.enumerated().map { index, row in
            let date = DateComponents(calendar: .current, year: 2026, month: row.2, day: row.3, hour: 10,
                                      minute: index).date ?? .now
            return PassportStampEntry(kind: row.0, token: row.1, date: date)
        }
    }()

    private func heading(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.fernlet(.headerMedium))
            .foregroundStyle(WorldPalette.bark)
    }

    /// `kinds` four to a row, each over its name when `names`.
    private func grid(_ kinds: [PassportStampKind], scale: CGFloat, names: Bool, earned: Bool = true) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .top), count: 4)
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in
                VStack(spacing: 3) {
                    PassportStampView(model: PassportStampModel(kind: kind, firstVisit: earned ? .now : nil),
                                      library: library, scale: scale)
                    if names {
                        Text(verbatim: name(of: kind))
                            .font(.custom(FernletFontName.dmSansBold, size: 12, relativeTo: .caption))
                            .foregroundStyle(WorldPalette.bark)
                            .multilineTextAlignment(.center)
                            .fernletWrappingText()
                    }
                }
            }
        }
    }

    private func special(allOceans: Bool, earned: Bool) -> some View {
        VStack(spacing: 4) {
            PassportStampView(model: PassportStampModel(kind: .special(allOceans: allOceans),
                                                        firstVisit: earned ? .now : nil),
                              library: library, scale: earned ? 3.6 : 2.6)
            Text(verbatim: allOceans ? "All five oceans" : "All seven continents")
                .font(.custom(FernletFontName.dmSansBold, size: 14, relativeTo: .subheadline))
                .foregroundStyle(WorldPalette.bark)
        }
        .frame(maxWidth: .infinity)
    }

    /// A stamp's caption (English; DEBUG copy).
    private func name(of kind: PassportStampKind) -> String {
        switch kind {
        case .country(let code): library.countryStamp(code)?.englishName ?? code
        case .continent(let continent): String(localized: continent.passportName)
        case .ocean(let ocean): String(localized: ocean.passportName)
        case .sea(let token): library.sea(token)?.names.english ?? token
        case .special(let allOceans): allOceans ? "All five oceans" : "All seven continents"
        }
    }
}
#endif
