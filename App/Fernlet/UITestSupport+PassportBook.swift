import Foundation
import SwiftUI
import WorldMapStore

// Sprout's passport book's DEBUG screenshot hook (round 7, lane explore-ui, piece `book`):
// `FERNLET_UI_TEST_PASSPORT_BOOK=<scene>` opens the book over Home once the launch settles, on an in-memory demo
// passport (the mockup's sample traveller, Portland since August), never written anywhere. Scenes: `turn` (page 3
// with the contents open), `world`, `stamps`, `stamps2`, `new` (the Sea of Japan landing on page 5), `index`,
// `continent` (North America A to Z), `fresh`, `full` (every stamp found), `decoy`. Absent in Release.

extension UITestSupport {
    #if DEBUG
    /// The passport scene to open at launch (`FERNLET_UI_TEST_PASSPORT_BOOK`), or nil.
    static var passportBookScene: String? { ProcessInfo.processInfo.environment["FERNLET_UI_TEST_PASSPORT_BOOK"] }
    #else
    static var passportBookScene: String? { nil }
    #endif
}

#if DEBUG
extension View {
    /// Opens the passport scene the DEBUG hook asks for, once the root appears.
    func passportBookHook(_ presenter: WorldPassportPresenter, store: FernletStore) -> some View {
        modifier(PassportBookHook(presenter: presenter, store: store))
    }
}

/// Opens the requested scene after the launch settles.
private struct PassportBookHook: ViewModifier {
    let presenter: WorldPassportPresenter
    let store: FernletStore

    func body(content: Content) -> some View {
        content.task {
            guard let scene = UITestSupport.passportBookScene, !presenter.isPresented else { return }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            PassportBookDemoScenes.open(scene, presenter: presenter, atlas: store.worldFog.atlas.openedAtlas)
        }
    }
}

/// The demo passports the screenshots open, in memory only.
enum PassportBookDemoScenes {
    /// Opens `scene` on `presenter`.
    static func open(_ scene: String, presenter: WorldPassportPresenter, atlas: WorldAtlas?) {
        let world = WorldAtlasMapDemo.content(atlas: atlas)
        let fog = WorldViewContent.make(atlas: atlas, book: PassportBook(), cells: [], start: nil)
        switch scene {
        case "fresh":
            presenter.demo = PassportBookDemo(entries: [], world: fog)
            presenter.open(page: 3)
        case "decoy":
            presenter.demo = PassportBookDemo(entries: [], isDecoy: true, world: fog)
            presenter.open(page: 2)
        case "full":
            let entries = full(atlas: atlas)
            presenter.demo = PassportBookDemo(entries: entries, world: world)
            presenter.open(page: PassportBookModel(entries: entries).stampPageNumbers.upperBound)
        case "new":
            presenter.demo = PassportBookDemo(entries: sample, world: world)
            if let last = PassportStampEntry.ordered(sample).last { presenter.noteNewStamp(last) }
            presenter.open()
        default:
            presenter.demo = PassportBookDemo(entries: sample, world: world, opensContents: scene == "turn",
                                              detail: scene == "continent" ? .continent(.northAmerica) : nil)
            presenter.open(page: page(of: scene))
        }
    }

    /// The scene's page in the sample book (6 pages).
    private static func page(of scene: String) -> Int {
        switch scene {
        case "world": 2
        case "stamps2": 4
        case "index", "continent": 6
        default: 3
        }
    }

    /// The mockup's sample traveller (`PP.LOG`) with a second trip to the United States (the index's "3, 5").
    static let sample: [PassportStampEntry] = {
        let rows: [(PassportStampEntry.Kind, String, Int, Int, Int)] = [
            (.continent, "northAmerica", 8, 14, 1), (.country, "US", 8, 14, 1), (.ocean, "pacific", 8, 16, 1),
            (.country, "CA", 9, 2, 1), (.country, "MX", 9, 20, 1), (.sea, "Q1247", 9, 21, 1),
            (.continent, "europe", 10, 3, 1), (.country, "GB", 10, 3, 1), (.ocean, "atlantic", 10, 5, 1),
            (.country, "FR", 10, 9, 1), (.continent, "asia", 10, 22, 1), (.country, "JP", 10, 22, 1),
            (.country, "US", 10, 23, 2), (.sea, "Q27092", 10, 24, 1)
        ]
        return rows.enumerated().map { index, row in
            PassportStampEntry(kind: row.0, token: row.1, date: date(2026, row.2, row.3, minute: index), trip: row.4)
        }
    }()

    /// A full passport: every passport country of the atlas over the years, the continents and oceans on the way,
    /// and the last day (Antarctica and the Southern Ocean) earning both specials.
    static func full(atlas: WorldAtlas?) -> [PassportStampEntry] {
        let table = atlas.map(PassportCountryTable.init(atlas:)) ?? .empty
        let codes = table.continentOf.keys.sorted()
        var entries = codes.enumerated().map { index, code in
            PassportStampEntry(kind: .country, token: code, date: date(2026 + index / 26, 1 + (index / 2) % 12, 1 + index % 27))
        }
        let early = date(2026, 8, 14)
        entries += AtlasContinent.allCases.filter { $0 != .antarctica }
            .map { PassportStampEntry(kind: .continent, token: $0.rawValue, date: early) }
        entries += AtlasOcean.allCases.filter { $0 != .southern }
            .map { PassportStampEntry(kind: .ocean, token: $0.rawValue, date: early) }
        let last = date(2034, 2, 2)
        entries += [PassportStampEntry(kind: .continent, token: AtlasContinent.antarctica.rawValue, date: last),
                    PassportStampEntry(kind: .ocean, token: AtlasOcean.southern.rawValue, date: last),
                    PassportStampEntry(kind: .special, token: PassportStampEntry.allContinentsToken, date: last),
                    PassportStampEntry(kind: .special, token: PassportStampEntry.allOceansToken, date: last)]
        return entries
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, minute: Int = 0) -> Date {
        DateComponents(calendar: .current, year: year, month: month, day: day, hour: 10, minute: minute).date ?? .now
    }
}
#else
extension View {
    /// The passport's DEBUG hook: nothing in Release.
    func passportBookHook(_ presenter: WorldPassportPresenter, store: FernletStore) -> some View { self }
}
#endif
