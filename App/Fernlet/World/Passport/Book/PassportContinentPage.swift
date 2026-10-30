import FernletUI
import SwiftUI
import WorldMapStore

/// A continent's countries, A to Z (World-Passport-Spec §8, `ps-continent`, approved): "INDEX · A TO Z", the
/// continent's stamp at 1.1 with its name and "3 of 23 countries", then every country of the continent in the
/// current language's order, four across (three with the largest text): earned stamps at 1.18 with their name (and
/// "2 trips" when there's more than one), which turn to the page the stamp first landed on, and the countries not
/// reached as dashed spaces, never named. Antarctica shows its stamp and the 60°S rule; the oceans and the seas show
/// theirs the same way.
struct PassportContinentPage: View {
    let detail: PassportIndexDetail
    let book: PassportBookModel
    let index: PassportIndexModel
    let library: PassportLibrary
    /// Turns to `page` and wiggles the stamp of `kind` and `token` there.
    let onTurn: (_ page: Int, _ kind: PassportStampEntry.Kind, _ token: String) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PassportPageHeader(title: Text(PassportBookCopy.index), detail: Text(PassportPageCopy.aToZ))
            header
            if detail == .continent(.antarctica) {
                PassportIndexSmall(text: Text(PassportPageCopy.antarcticaRule))
            }
            LazyVGrid(columns: columns, alignment: .center, spacing: 8) {
                content
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        switch detail {
        case .continent(let continent):
            let row = index.row(continent)
            let found = continent == .antarctica ? (row?.earned == true ? 1 : 0) : sheet(continent).earnedCount
            PassportDetailHeader(stamp: PassportStampView(model: PassportStampModel(kind: .continent(continent),
                                                                                    firstVisit: row?.earned == true ? .now : nil),
                                                          library: library, scale: 1.1),
                                 name: Text(continent.passportName),
                                 line: continent == .antarctica
                                     ? Text(PassportPageCopy.count(found, of: 1))
                                     : Text(PassportPageCopy.countries(found, of: row?.total ?? continent.specCountryTotal)))
        case .oceans:
            PassportDetailHeader(stamp: PassportStampView(model: PassportStampModel(kind: .ocean(.pacific), firstVisit: .now),
                                                          library: library, scale: 1.1),
                                 name: Text(PassportPageCopy.oceans),
                                 line: Text(PassportPageCopy.count(index.oceans.count, of: PassportProgress.oceanTotal)))
        case .seas:
            PassportDetailHeader(stamp: PassportStampView(model: PassportStampModel(kind: .sea(index.seas.first?.token ?? "Q1247"),
                                                                                    firstVisit: .now),
                                                          library: library, scale: 1.1),
                                 name: Text(PassportPageCopy.seasRow), line: Text(verbatim: "\(index.seas.count)"))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch detail {
        case .continent(.antarctica):
            EmptyView()
        case .continent(let continent):
            ForEach(sheet(continent).cells, id: \.code) { cell in
                PassportAToZCell(kind: .country(cell.code), name: cell.earned ? cell.name : nil, trips: cell.trips,
                                 library: library) {
                    onTurn(cell.firstPage ?? PassportBookModel.firstStampPage, .country, cell.code)
                }
            }
        case .oceans:
            ForEach(AtlasOcean.passportOrder, id: \.self) { ocean in
                let place = index.oceans.first { $0.token == ocean.rawValue }
                PassportAToZCell(kind: .ocean(ocean), name: place?.name, trips: place == nil ? 0 : 1, library: library) {
                    onTurn(place?.pages.first ?? PassportBookModel.firstStampPage, .ocean, ocean.rawValue)
                }
            }
        case .seas:
            ForEach(index.seas, id: \.token) { place in
                PassportAToZCell(kind: .sea(place.token), name: place.name, trips: 1, library: library) {
                    onTurn(place.pages.first ?? PassportBookModel.firstStampPage, .sea, place.token)
                }
            }
        }
    }

    /// Four across, three with the largest text.
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 3, alignment: .top),
              count: dynamicTypeSize.isAccessibilitySize ? 3 : 4)
    }

    /// `continent`'s countries A to Z.
    private func sheet(_ continent: AtlasContinent) -> PassportContinentSheet {
        PassportContinentSheet(continent: continent, book: book, table: library.countryTable) {
            library.name(of: .country($0))
        }
    }
}

/// The A to Z view's header (`.ppchead`): the stamp, the name in Fraunces 21 and its count.
struct PassportDetailHeader<Stamp: View>: View {
    let stamp: Stamp
    let name: Text
    let line: Text

    var body: some View {
        HStack(spacing: 10) {
            stamp.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                name.font(PassportBookType.title).foregroundStyle(PassportBookPalette.text)
                    .accessibilityAddTraits(.isHeader)
                line.font(Font.custom(FernletFontName.dmSans, size: 13.5, relativeTo: .footnote))
                    .foregroundStyle(PassportBookPalette.dim)
            }
            .fernletWrappingText()
        }
        .accessibilityElement(children: .combine)
    }
}

/// One space in the A to Z grid (`.ppcs`): an earned stamp at 1.18 with its name (and "2 trips"), a button that
/// turns to its page; or a dashed space, unnamed (`name` nil).
struct PassportAToZCell: View {
    let kind: PassportStampKind
    let name: String?
    let trips: Int
    let library: PassportLibrary
    let action: () -> Void

    var body: some View {
        if let name {
            Button(action: action) {
                VStack(spacing: 2) {
                    PassportStampView(model: PassportStampModel(kind: kind, firstVisit: .now), library: library, scale: 1.18)
                    Text(verbatim: name)
                        .font(PassportBookType.cellName)
                        .foregroundStyle(PassportBookPalette.text)
                        .multilineTextAlignment(.center)
                        .fernletWrappingText()
                    if trips > 1 {
                        Text(PassportPageCopy.trips(trips))
                            .font(PassportBookType.cellTrips)
                            .foregroundStyle(PassportBookPalette.moss)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 66, alignment: .top)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(PassportPageCopy.earnedCell(name, trips: trips)))
            .accessibilityInputLabels([Text(verbatim: name)])
            .accessibilityHint(Text(PassportPageCopy.turnsToPage))
        } else {
            PassportEmptySpace(kind: kind, scale: 1.18)
                .frame(maxWidth: .infinity, minHeight: 66, alignment: .top)
        }
    }
}
