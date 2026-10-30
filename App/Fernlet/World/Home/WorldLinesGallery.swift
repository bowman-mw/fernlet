#if DEBUG
import FernletUI
import SwiftUI

/// DEBUG-only: one of the five lines boards (`ex-lines-land`, `-open`, `-towns`, `-marks`, `-world`;
/// `FERNLET_UI_TEST_LINES=board:<board>`): each category with its three lines, numbered as the mockup numbers them,
/// each in Sprout's own bubble at the map's wrap width, the name slot filled with an example. Its headings are
/// verbatim DEBUG copy, never harvested; the lines are the real ones. Absent from Release builds (a stub stands in).
struct WorldLinesGallery: View {
    let board: WorldLineBoard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(board.categories, id: \.self) { category in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: category.rawValue).font(FernletFramedFont.rowTitleBold).foregroundStyle(WorldPalette.bark)
                        ForEach(0..<WorldDiscoveryLine.linesPerCategory, id: \.self) { index in
                            HStack(alignment: .top, spacing: 10) {
                                Text(verbatim: "\(number(of: category, index: index))")
                                    .font(FernletFramedFont.noteBold).foregroundStyle(WorldPalette.dim).frame(width: 24)
                                WorldSpeechBubble(text: WorldDiscoveryLinesCopy.line(category, index: index, name: example(category)))
                                    .padding(.bottom, 10)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SheetHeader(title: Text(verbatim: "Lines · \(board.rawValue)"), onDone: { dismiss() })
        }
        .fernletSheet()
    }

    /// The line's number on the approved page (1–66).
    private func number(of category: WorldLineCategory, index: Int) -> Int {
        let position = WorldLineCategory.allCases.firstIndex(of: category) ?? 0
        return position * WorldDiscoveryLine.linesPerCategory + index + 1
    }

    /// The name a board fills in (the mockup's places).
    private func example(_ category: WorldLineCategory) -> String {
        switch category {
        case .village: "Hood River"
        case .town: "Astoria"
        case .city: "Portland"
        case .bigCity: "Seattle"
        case .megacity: "Tokyo"
        case .landmark: "Laurelhurst Park"
        case .country: "Canada"
        case .continent: "Europe"
        case .ocean: "Pacific"
        case .sea: "Salish Sea"
        default: ""
        }
    }
}
#else
import SwiftUI

/// The lines boards are DEBUG-only; Release builds carry this empty stand-in.
struct WorldLinesGallery: View {
    let board: WorldLineBoard

    var body: some View { EmptyView() }
}
#endif
