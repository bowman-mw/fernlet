import FernletUI
import SwiftUI
import WorldMapStore

/// What a Flighty file held (World-Airports-Spec §9.4, screen 21, approved): "Past flights", from the file's name,
/// with Cancel top left; four tiles (flights, airports, countries, years; two by two at the largest text), what was
/// skipped (unknown codes named, never guessed), what the passport already holds, what the flights will do, the
/// lock notice, a link to what Fernlet reads (screen 24), and the one button that adds them, "Add 48 flights",
/// with "You can remove them all in Privacy & data." under it. Full height, paper.
struct FlightyImportSheet: View {
    let found: FlightyImportFound
    let onAdd: () -> Void
    let onCancel: () -> Void
    @State private var showsReads = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        FlightyImportTiles(summary: found.summary)
                        FlightyImportLine(title: FlightyImportCopy.skipped, text: Text(verbatim: skippedLine))
                        if let held = heldLine {
                            FlightyImportLine(title: FlightyImportCopy.alreadyHeld, text: Text(verbatim: held))
                        }
                        FlightyImportLine(title: FlightyImportCopy.whatTheyDo, text: Text(FlightyImportCopy.whatTheyDoBody))
                        FernletNotice(text: Text(FlightyImportCopy.lockNotice)) { FernletIcon(.lock) }
                        readsLink
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                }
                footer
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: Text(FlightyImportCopy.sheetTitle),
                            subtitle: Text(FlightyImportCopy.fromFile(found.fileName)), onCancel: onCancel)
            }
            .navigationDestination(isPresented: $showsReads) { FlightyImportReadsPage() }
            .toolbar(.hidden, for: .navigationBar)
        }
        .fernletSheet()
        .uxScreenAnchor("screen.flightyImport")
    }

    /// The confirm and the line under it.
    private var footer: some View {
        FernletSheetFooter {
            VStack(spacing: 8) {
                Button(action: onAdd) {
                    Text(count > 0 ? FlightyImportCopy.add(count) : FlightyImportCopy.noneToAdd)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .disabled(count == 0)
                .accessibilityInputLabels([Text(FlightyImportCopy.add(count))])
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

    /// The flights to add.
    private var count: Int { found.plan.flights.count }

    /// "2 cancelled · 4 repeated rows · 1 unknown airport code: XYZ", or "Nothing".
    private var skippedLine: String {
        let summary = found.summary
        var parts: [String] = []
        if summary.cancelled > 0 { parts.append(String(localized: FlightyImportCopy.cancelled(summary.cancelled))) }
        if summary.repeatedRows > 0 { parts.append(String(localized: FlightyImportCopy.repeated(summary.repeatedRows))) }
        if !summary.unknownCodes.isEmpty {
            let codes = summary.unknownCodes.prefix(Self.maxCodesNamed).joined(separator: ", ")
            parts.append(String(localized: FlightyImportCopy.unknownCodes(summary.unknownCodes.count, codes)))
        }
        if summary.unreadableRows > 0 { parts.append(String(localized: FlightyImportCopy.unreadable(summary.unreadableRows))) }
        return parts.isEmpty ? String(localized: FlightyImportCopy.nothingSkipped) : parts.joined(separator: " · ")
    }

    /// "3 flights Fernlet saw, kept once" (and the earlier imports), or nil when the passport holds none of them.
    private var heldLine: String? {
        var parts: [String] = []
        if found.plan.alreadySeen > 0 { parts.append(String(localized: FlightyImportCopy.alreadySeen(found.plan.alreadySeen))) }
        if found.plan.alreadyImported > 0 {
            parts.append(String(localized: FlightyImportCopy.alreadyImported(found.plan.alreadyImported)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The most unknown codes named on the line (the rest are counted).
    static let maxCodesNamed = 8
}

/// The four tiles (`.apsum`): flights, airports, countries and years, four across or two by two at the largest
/// text. One element for VoiceOver: "Found 48 flights, 31 airports, 9 countries, 2014 to 2026". The countries
/// tile is left out where the list doesn't know every airport's country (never undercounted).
struct FlightyImportTiles: View {
    let summary: FlightyImportSummary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: dynamicTypeSize.isAccessibilitySize ? 2 : 4)
        LazyVGrid(columns: columns, spacing: 6) {
            tile(Text(verbatim: "\(summary.flights)"), FlightyImportCopy.tileFlights)
            tile(Text(verbatim: "\(summary.airports)"), FlightyImportCopy.tileAirports)
            if let countries = summary.countries { tile(Text(verbatim: "\(countries)"), FlightyImportCopy.tileCountries) }
            tile(Text(verbatim: years), FlightyImportCopy.tileYears)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(FlightyImportCopy.foundLabel(summary)))
    }

    /// "2014–26", "2026", or "–" with no flights.
    private var years: String {
        guard let span = summary.years else { return "–" }
        guard span.lowerBound != span.upperBound else { return "\(span.lowerBound)" }
        let last = span.upperBound / 100 == span.lowerBound / 100 ? String(format: "%02d", span.upperBound % 100) : "\(span.upperBound)"
        return "\(span.lowerBound)–\(last)"
    }

    private func tile(_ number: Text, _ noun: LocalizedStringResource) -> some View {
        VStack(spacing: 2) {
            number
                .font(Font.custom(FernletFontName.dmSansBold, size: 22, relativeTo: .title3))
                .foregroundStyle(WorldPalette.bark)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(noun)
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
