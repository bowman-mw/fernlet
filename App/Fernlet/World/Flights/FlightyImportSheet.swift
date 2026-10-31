import FernletUI
import SwiftUI
import WorldMapStore

/// What an import's summary sheet shows (World-Airports-Spec §9.4, §10.5): a Flighty file's ("Past flights",
/// screen 21) or the calendar's first look back ("Flights in your calendar", screen 28). The same sheet, tiles,
/// lines and confirm for both; only the words and numbers differ.
nonisolated struct FlightImportSummaryContent: Sendable {
    let title: LocalizedStringResource
    /// "From FlightyExport.csv", "Looked back to 2019".
    let subtitle: LocalizedStringResource
    /// The tiles, in order (four across, two by two at the largest text).
    let tiles: [FlightImportTile]
    /// The tiles as one VoiceOver label ("Found 48 flights, 31 airports, 9 countries, 2014 to 2026").
    let tilesLabel: LocalizedStringResource
    /// The headed lines under the tiles ("Skipped", "Already in the passport", ...).
    let lines: [FlightImportSummaryLine]
    /// The lock notice.
    let notice: LocalizedStringResource
    /// Whether the sheet links to what Fernlet reads from a Flighty file (screen 24).
    let showsReadsLink: Bool
    /// The flights "Add N flights" adds.
    let count: Int
    /// The screen's anchor for UI tests (a token).
    let anchor: String
}

/// One tile: a number (or a span of years) over its noun.
nonisolated struct FlightImportTile: Sendable {
    /// The number, already written out ("48", "2014–26").
    let value: String
    let noun: LocalizedStringResource

    /// A count's tile.
    init(_ count: Int, _ noun: LocalizedStringResource) {
        value = "\(count)"
        self.noun = noun
    }

    /// The years' tile: "2014–26", "2026", or "–" with no flights.
    init(years span: ClosedRange<Int>?, _ noun: LocalizedStringResource) {
        self.noun = noun
        guard let span else {
            value = "–"
            return
        }
        guard span.lowerBound != span.upperBound else {
            value = "\(span.lowerBound)"
            return
        }
        let sameCentury = span.upperBound / 100 == span.lowerBound / 100
        let last = sameCentury ? String(format: "%02d", span.upperBound % 100) : "\(span.upperBound)"
        value = "\(span.lowerBound)–\(last)"
    }
}

/// A bold heading over its line's parts, joined with " · " ("Skipped" over "2 cancelled · 4 repeated rows").
nonisolated struct FlightImportSummaryLine: Sendable {
    let title: LocalizedStringResource
    let parts: [LocalizedStringResource]
}

/// An import's summary (World-Airports-Spec §9.4 screen 21, §10.5 screen 28, approved): the title and its sub,
/// with Cancel top left; the tiles (two by two at the largest text), the headed lines, the lock notice, for a
/// Flighty file a link to what Fernlet reads (screen 24), and the one button that adds them, "Add 48 flights",
/// with "You can remove them all in Privacy & data." under it. Full height, paper.
struct FlightImportSummarySheet: View {
    let content: FlightImportSummaryContent
    let onAdd: () -> Void
    let onCancel: () -> Void
    @State private var showsReads = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        FlightImportTiles(tiles: content.tiles, label: content.tilesLabel)
                        ForEach(Array(content.lines.enumerated()), id: \.offset) { _, line in
                            FlightyImportLine(title: line.title, text: Text(verbatim: Self.joined(line.parts)))
                        }
                        FernletNotice(text: Text(content.notice)) { FernletIcon(.lock) }
                        if content.showsReadsLink { readsLink }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                }
                footer
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: Text(content.title), subtitle: Text(content.subtitle), onCancel: onCancel)
            }
            .navigationDestination(isPresented: $showsReads) { FlightyImportReadsPage() }
            .toolbar(.hidden, for: .navigationBar)
        }
        .fernletSheet()
        .uxScreenAnchor(content.anchor)
    }

    /// The confirm and the line under it.
    private var footer: some View {
        FernletSheetFooter {
            VStack(spacing: 8) {
                Button(action: onAdd) {
                    Text(content.count > 0 ? FlightyImportCopy.add(content.count) : FlightyImportCopy.noneToAdd)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .disabled(content.count == 0)
                .accessibilityInputLabels([Text(FlightyImportCopy.add(content.count))])
                .accessibilityIdentifier("flightyImport.add")
                Text(FlightyImportCopy.removeLater)
                    .font(FernletFramedFont.note)
                    .foregroundStyle(WorldPalette.dim)
                    .multilineTextAlignment(.center)
                    .fernletWrappingText()
            }
        }
    }

    /// "What Fernlet reads from the file ›".
    private var readsLink: some View {
        Button { showsReads = true } label: {
            HStack(spacing: 6) {
                Text(FlightyImportCopy.readsLink)
                    .font(FernletFramedFont.bodyBold)
                    .foregroundStyle(WorldPalette.mossInk)
                    .fernletWrappingText()
                WorldSpriteView(sprite: WorldSprites.chevR, scale: 2, tint: WorldPalette.mossInk)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("flightyImport.reads")
    }

    /// A line's parts, each localized, joined with " · ".
    static func joined(_ parts: [LocalizedStringResource]) -> String {
        parts.map { String(localized: $0) }.joined(separator: " · ")
    }
}

extension FlightyImportFound {
    /// The most unknown codes named on the Skipped line (the rest are counted).
    static let maxCodesNamed = 8

    /// A Flighty file's summary (screen 21): flights, airports, countries (left out where the list doesn't know
    /// every airport's country, never undercounted) and years; Skipped, Already in the passport (only when it
    /// holds some), What they'll do; the file's lock notice and the reads link.
    var content: FlightImportSummaryContent {
        var tiles = [FlightImportTile(summary.flights, FlightyImportCopy.tileFlights),
                     FlightImportTile(summary.airports, FlightyImportCopy.tileAirports)]
        if let countries = summary.countries { tiles.append(FlightImportTile(countries, FlightyImportCopy.tileCountries)) }
        tiles.append(FlightImportTile(years: summary.years, FlightyImportCopy.tileYears))
        var lines = [FlightImportSummaryLine(title: FlightyImportCopy.skipped, parts: skippedParts)]
        if !heldParts.isEmpty { lines.append(FlightImportSummaryLine(title: FlightyImportCopy.alreadyHeld, parts: heldParts)) }
        lines.append(FlightImportSummaryLine(title: FlightyImportCopy.whatTheyDo, parts: [FlightyImportCopy.whatTheyDoBody]))
        return FlightImportSummaryContent(
            title: FlightyImportCopy.sheetTitle, subtitle: FlightyImportCopy.fromFile(fileName), tiles: tiles,
            tilesLabel: FlightyImportCopy.foundLabel(summary), lines: lines, notice: FlightyImportCopy.lockNotice,
            showsReadsLink: true, count: plan.flights.count, anchor: "screen.flightyImport")
    }

    /// "2 cancelled · 4 repeated rows · 1 unknown airport code: XYZ", or "Nothing".
    private var skippedParts: [LocalizedStringResource] {
        var parts: [LocalizedStringResource] = []
        if summary.cancelled > 0 { parts.append(FlightyImportCopy.cancelled(summary.cancelled)) }
        if summary.repeatedRows > 0 { parts.append(FlightyImportCopy.repeated(summary.repeatedRows)) }
        if !summary.unknownCodes.isEmpty {
            let codes = summary.unknownCodes.prefix(Self.maxCodesNamed).joined(separator: ", ")
            parts.append(FlightyImportCopy.unknownCodes(summary.unknownCodes.count, codes))
        }
        if summary.unreadableRows > 0 { parts.append(FlightyImportCopy.unreadable(summary.unreadableRows)) }
        return parts.isEmpty ? [FlightyImportCopy.nothingSkipped] : parts
    }

    /// "3 flights Fernlet saw, kept once" (and the earlier imports); empty when the passport holds none of them.
    private var heldParts: [LocalizedStringResource] {
        var parts: [LocalizedStringResource] = []
        if plan.alreadySeen > 0 { parts.append(FlightyImportCopy.alreadySeen(plan.alreadySeen)) }
        if plan.alreadyImported > 0 { parts.append(FlightyImportCopy.alreadyImported(plan.alreadyImported)) }
        return parts
    }
}

/// The tiles (`.apsum`), four across or two by two at the largest text. One element for VoiceOver, read as the
/// content's label.
struct FlightImportTiles: View {
    let tiles: [FlightImportTile]
    let label: LocalizedStringResource
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let across = dynamicTypeSize.isAccessibilitySize ? 2 : max(min(tiles.count, 4), 1)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: across), spacing: 6) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, item in tile(item) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }

    private func tile(_ item: FlightImportTile) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: item.value)
                .font(Font.custom(FernletFontName.dmSansBold, size: 22, relativeTo: .title3))
                .foregroundStyle(WorldPalette.bark)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(item.noun)
                .font(Font.custom(FernletFontName.dmSans, size: 12, relativeTo: .caption))
                .foregroundStyle(WorldPalette.dim)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background(WorldPalette.paperLight, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldPalette.ink, lineWidth: 2))
    }
}

/// A bold heading over a line (the page's `.cold`): "Skipped" over "2 cancelled · 4 repeated rows".
struct FlightyImportLine: View {
    let title: LocalizedStringResource
    let text: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(FernletFramedFont.bodyBold)
                .foregroundStyle(WorldPalette.bark)
                .accessibilityAddTraits(.isHeader)
            text
                .font(FernletFramedFont.note)
                .foregroundStyle(WorldPalette.dim)
                .fernletWrappingText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// What Fernlet reads from a Flighty file (World-Airports-Spec §9.2, screen 24, approved with 24 A): the five
/// things read and what for, what's dropped as it's read, how times without a zone are read, and why a newer
/// Flighty file still imports. Pushed inside the summary sheet, so it keeps the system bar and its Back (the
/// sheet frame's rule for pages pushed in a sheet).
struct FlightyImportReadsPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(FlightyImportCopy.readsTitle)
                    .font(FernletFramedFont.sheetTitle)
                    .foregroundStyle(WorldPalette.bark)
                    .accessibilityAddTraits(.isHeader)
                table
                FlightyImportLine(title: FlightyImportCopy.droppedTitle, text: Text(FlightyImportCopy.droppedBody))
                FlightyImportLine(title: FlightyImportCopy.zonesTitle, text: Text(FlightyImportCopy.zonesBody))
                FlightyImportLine(title: FlightyImportCopy.columnsTitle, text: Text(FlightyImportCopy.columnsBody))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .navigationBarTitleDisplayMode(.inline)
        .background(WorldPalette.paper.ignoresSafeArea())
    }

    /// Read │ What for, one row each.
    private var table: some View {
        VStack(spacing: 0) {
            row(FlightyImportCopy.readsColumn, FlightyImportCopy.readsWhy, header: true)
            ForEach(Array(FlightyImportCopy.readsRows.enumerated()), id: \.offset) { _, pair in
                row(pair.0, pair.1, header: false)
            }
        }
        .background(WorldPalette.paperLight, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldPalette.ink, lineWidth: 2))
    }

    private func row(_ read: LocalizedStringResource, _ why: LocalizedStringResource, header: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) {
                cell(read, bold: true, dim: header).frame(maxWidth: .infinity, alignment: .leading)
                cell(why, bold: header, dim: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                cell(read, bold: true, dim: header)
                cell(why, bold: header, dim: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { WorldPalette.rule.frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(header ? .isHeader : [])
    }

    private func cell(_ text: LocalizedStringResource, bold: Bool, dim: Bool) -> some View {
        Text(text)
            .font(bold ? FernletFramedFont.noteBold : FernletFramedFont.note)
            .foregroundStyle(dim ? WorldPalette.dim : WorldPalette.bark)
            .fernletWrappingText()
    }
}
