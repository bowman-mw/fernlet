import FernletUI
import SwiftUI
import WorldMapStore

/// What the index opens inside the book (World-Passport-Spec §8): a continent's countries A to Z (Antarctica's
/// stamp and its 60°S rule), or the oceans or the seas.
nonisolated enum PassportIndexDetail: Hashable, Sendable {
    case continent(AtlasContinent)
    case oceans
    case seas
}

/// The index at the back (World-Passport-Spec §7): "INDEX" with the countries found, one row per continent (its
/// stamp at 0.66, dashed if not earned; its name and count; the countries found A to Z, each a link to every page it
/// is on), Antarctica's rule, then the oceans and the seas. A row's › opens its A to Z inside the book. No country
/// is named until found. Then (World-Airports-Spec §4.2, `ap-index`) the Airports row (a ticket, "Airports", the
/// count with no total, each found airport A to Z with its pages, a link to its ticket) and the Flights row (the
/// jet, "Flights", "5 · page 7", "1 layover"), whose tap turns to the Flights page.
struct PassportIndexPage: View {
    let index: PassportIndexModel
    let library: PassportLibrary
    /// Turns to `page` and wiggles the stamp of `kind` and `token` there.
    let onTurn: (_ page: Int, _ kind: PassportStampEntry.Kind, _ token: String) -> Void
    let onOpen: (PassportIndexDetail) -> Void
    /// Turns to `page` (the Flights row); nil leaves the row without a tap.
    var onGo: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PassportPageHeader(title: Text(PassportBookCopy.index),
                               detail: Text(PassportPageCopy.countries(index.countryCount, of: PassportProgress.countryTotal)))
                .padding(.bottom, 4)
            ForEach(index.continents, id: \.continent) { row in
                PassportIndexRow(stamp: PassportStampView(model: PassportStampModel(kind: .continent(row.continent),
                                                                                    firstVisit: row.earned ? .now : nil),
                                                          library: library, scale: 0.66),
                                 name: Text(row.continent.passportName),
                                 count: Text(PassportPageCopy.count(row.continent == .antarctica && row.earned ? 1 : row.places.count,
                                                                    of: row.total)),
                                 open: { onOpen(.continent(row.continent)) }) {
                    rowLine(row)
                }
            }
            PassportIndexRow(stamp: PassportStampView(model: PassportStampModel(kind: .ocean(.pacific), firstVisit: .now),
                                                      library: library, scale: 0.66),
                             name: Text(PassportPageCopy.oceans),
                             count: Text(PassportPageCopy.count(index.oceans.count, of: PassportProgress.oceanTotal)),
                             open: { onOpen(.oceans) }) {
                links(index.oceans, kind: .ocean)
            }
            PassportIndexRow(stamp: PassportStampView(model: PassportStampModel(kind: .sea(index.seas.first?.token ?? "Q1247"),
                                                                                firstVisit: .now),
                                                      library: library, scale: 0.66),
                             name: Text(PassportPageCopy.seasRow), count: Text(verbatim: "\(index.seas.count)"),
                             open: { onOpen(.seas) }) {
                links(index.seas, kind: .sea)
            }
            PassportIndexAirportRows(index: index, library: library, onGo: onGo) { places in
                links(places, kind: .airport)
            }
        }
    }

    /// A continent's line: Antarctica's rule, the countries found, or "None yet".
    @ViewBuilder
    private func rowLine(_ row: PassportIndexModel.ContinentRow) -> some View {
        if row.continent == .antarctica {
            PassportIndexSmall(text: Text(PassportPageCopy.antarcticaRule))
        } else if row.places.isEmpty {
            PassportIndexSmall(text: Text(PassportPageCopy.noneYet))
        } else {
            links(row.places, kind: .country)
        }
    }

    /// `places` as links, "Canada 3, Mexico 3, United States 3, 5".
    private func links(_ places: [PassportIndexModel.Place], kind: PassportStampEntry.Kind) -> some View {
        PassportFlowLayout(spacing: 4, lineSpacing: 0) {
            ForEach(Array(places.enumerated()), id: \.element.token) { offset, place in
                PassportIndexLink(place: place, last: offset == places.count - 1) {
                    onTurn(place.pages.first ?? PassportBookModel.firstStampPage, kind, place.token)
                }
            }
        }
    }
}

/// One index row (`.ppix > div`): the stamp, then the name and count with ›, which opens the A to Z inside the
/// book (or, `hint` says, turns to a page), then its line. With no `open` the name and count are plain words.
struct PassportIndexRow<Stamp: View, Line: View>: View {
    let stamp: Stamp
    let name: Text
    let count: Text
    let open: (() -> Void)?
    var hint = PassportPageCopy.opensAToZ
    @ViewBuilder let line: Line
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var nameText: some View {
        name.font(PassportBookType.rowName).foregroundStyle(PassportBookPalette.text)
    }

    private var countText: some View {
        count.font(PassportBookType.rowName.weight(.semibold)).foregroundStyle(PassportBookPalette.dim)
    }

    /// The name and the count side by side (stacked with the largest text), with › when the row opens.
    private var heading: some View {
        HStack(spacing: 6) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) { nameText; countText }
            } else {
                nameText
                Spacer(minLength: 4)
                countText
            }
            Spacer(minLength: 0)
            if open != nil {
                WorldSpriteView(sprite: WorldSprites.chevR, scale: 2, tint: WorldPalette.iconInk)
            }
        }
        .frame(minHeight: 26)
        .contentShape(Rectangle())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            stamp.frame(width: 34).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let open {
                    Button(action: open) { heading }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint(Text(hint))
                } else {
                    heading.accessibilityElement(children: .combine)
                }
                line
            }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { PassportBookPalette.rule.frame(height: 1) }
    }
}

/// The index's Airports and Flights rows (World-Airports-Spec §4.2, `ap-index`): the Airports row (a ticket at
/// 0.6 so it fits the rows' 34-pt column, dashed before the first airport, "Airports" and the count, every found airport A to Z with its pages, or "None yet"), then the Flights row
/// (the jet at 2×, "Flights", "5 · page 7", "1 layover"; "None yet" before the first flight) where the book shows
/// a Flights page. Airports are named only once found.
struct PassportIndexAirportRows<Links: View>: View {
    let index: PassportIndexModel
    let library: PassportLibrary
    let onGo: ((Int) -> Void)?
    /// The airports as links, as the other rows draw theirs.
    @ViewBuilder let links: ([PassportIndexModel.Place]) -> Links

    var body: some View {
        // The first airport's ticket; a dashed one, naming nothing, before the first is found.
        let first = index.airports.first?.token
        PassportIndexRow(stamp: PassportStampView(model: PassportStampModel(kind: .airport(first ?? "", transit: false),
                                                                            firstVisit: first == nil ? nil : .now),
                                                  library: library, scale: 0.6),
                         name: Text(PassportPageCopy.airportsRow), count: Text(verbatim: "\(index.airports.count)"),
                         open: nil) {
            if index.airports.isEmpty {
                PassportIndexSmall(text: Text(PassportPageCopy.noneYet))
            } else {
                links(index.airports)
            }
        }
        if let flights = index.flights {
            PassportIndexRow(stamp: WorldSpriteView(sprite: PassportFlightSprites.jet, scale: 2),
                             name: Text(PassportFlightsCopy.title), count: Text(countWords(flights)),
                             open: turn(to: flights.pages.lowerBound),
                             hint: PassportPageCopy.turnsToFlights) {
                if flights.count == 0 {
                    PassportIndexSmall(text: Text(PassportPageCopy.noneYet))
                } else if flights.layovers > 0 {
                    PassportIndexSmall(text: Text(PassportPageCopy.layovers(flights.layovers)))
                }
            }
        }
    }

    /// The Flights row's tap: turns to `page`, or nil (no tap) when the index can't turn pages.
    private func turn(to page: Int) -> (() -> Void)? {
        guard let onGo else { return nil }
        return { onGo(page) }
    }

    /// "5 · page 7", or "53 · pages 7 to 9" over several pages.
    private func countWords(_ flights: PassportIndexModel.FlightsRow) -> LocalizedStringResource {
        flights.pages.count == 1 ? PassportPageCopy.flightsCount(flights.count, page: flights.pages.lowerBound)
            : PassportPageCopy.flightsCount(flights.count, pages: flights.pages.lowerBound, to: flights.pages.upperBound)
    }
}

/// A row's small line ("None yet", Antarctica's rule).
struct PassportIndexSmall: View {
    let text: Text

    var body: some View {
        text.font(PassportBookType.rowSmall)
            .foregroundStyle(PassportBookPalette.dim)
            .fernletWrappingText()
    }
}

/// One found place in the index: its name as a link, then its pages ("United States 3, 5,"). Tapping turns to the
/// first page its stamp landed on.
struct PassportIndexLink: View {
    let place: PassportIndexModel.Place
    let last: Bool
    let action: () -> Void

    var body: some View {
        let pages = place.pages.map(String.init).joined(separator: ", ")
        HStack(spacing: 3) {
            Button(action: action) {
                Text(verbatim: place.name)
                    .font(PassportBookType.rowLink)
                    .foregroundStyle(PassportBookPalette.link)
                    .frame(minHeight: 21)
                    .contentShape(Rectangle().inset(by: -4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(PassportPageCopy.onPages(place.name, pages: pages)))
            .accessibilityInputLabels([Text(verbatim: place.name)])
            .accessibilityHint(Text(PassportPageCopy.turnsToPage))
            Text(verbatim: last ? pages : pages + ",")
                .font(PassportBookType.rowSmall)
                .foregroundStyle(PassportBookPalette.dim)
                .accessibilityHidden(true)
        }
    }
}

/// Lays its children out in lines, left to right, wrapping when a line is full (the index's links). Bounded by its
/// children (a continent's countries at most).
struct PassportFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = place(subviews, width: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0, height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = place(subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    /// Each child's frame in lines `width` wide.
    private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: min(size.width, width), height: size.height)))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}
