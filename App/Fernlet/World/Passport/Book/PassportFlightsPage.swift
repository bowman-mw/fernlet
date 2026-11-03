import FernletUI
import SwiftUI
import WorldMapStore

/// The Flights page of Sprout's passport (World-Airports-Spec §8, screens 11, 19 and 23; owner 2026-11-02, option A):
/// "FLIGHTS" with the totals ("178 flights · 494,810 km"), then the years, newest first, each a stub that opens its
/// log (``PassportFlightsYearPage``). A history that fits one page shows its boarding-pass stubs here instead, under
/// year headings. The page ends with the layovers' total and the "Add past flights" button (from a Flighty file, read
/// on this iPhone). The book gains this one page however many flights there are.
struct PassportFlightsPage: View {
    let flights: PassportFlightsModel
    /// The year whose row VoiceOver goes back to, its log just closed, or nil.
    let refocusYear: Int?
    /// A trip's airports' cities, by IATA code (the list's English or Spanish city; nil for a points-only code).
    let city: (String) -> String?
    let onOpenTrip: (PassportFlightTrip) -> Void
    let onOpenYear: (Int) -> Void
    /// "Add past flights", or nil where none may be added ("Airports and flights" is off).
    let onAddPastFlights: (() -> Void)?
    @AccessibilityFocusState private var focusedYear: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if flights.isEmpty {
                PassportFlightsEmpty()
            } else if flights.listsYears {
                ForEach(flights.years) { log in
                    PassportFlightsYearRow(log: log) { onOpenYear(log.year) }
                        .accessibilityFocused($focusedYear, equals: log.year)
                }
            } else {
                ForEach(flights.years) { log in
                    PassportFlightsYear(year: log.year)
                    ForEach(log.trips) { trip in
                        PassportFlightStub(trip: trip, days: PassportFlightsText.days(of: trip), city: city) { onOpenTrip(trip) }
                    }
                }
            }
            if !flights.isEmpty {
                Text(note)
                    .font(Font.custom(FernletFontName.dmSansMedium, size: 12.5, relativeTo: .caption))
                    .foregroundStyle(PassportBookPalette.dim)
                    .fernletWrappingText()
                    .padding(.top, 4)
            }
            if let onAddPastFlights { PassportAddFlightsButton(action: onAddPastFlights) }
        }
        .task {
            guard let refocusYear, await PassportFlightsFocus.settled() else { return }
            focusedYear = refocusYear
        }
    }

    /// "FLIGHTS" and the totals, which VoiceOver reads as the page's heading.
    @ViewBuilder
    private var header: some View {
        if flights.isEmpty {
            PassportPageHeader(title: Text(PassportFlightsCopy.title))
        } else {
            let distance = PassportFlightsText.kilometres(flights.totalMetres)
            PassportPageHeader(title: Text(PassportFlightsCopy.title),
                               detail: Text(verbatim: PassportFlightsCopy.summary(flights.flightCount, distance, planned: flights.plannedCount)))
                .modifier(PassportFlightsSpokenHeader(label: PassportFlightsCopy.spokenSummary(flights.flightCount, distance, planned: flights.plannedCount)))
        }
    }

    /// The layovers' total and the hint: tap a year, or tap a flight where the page shows the stubs itself.
    private var note: LocalizedStringResource {
        let length = PassportFlightsText.duration(flights.layoverSeconds)
        if flights.listsYears {
            return flights.layoverCount > 0 ? PassportFlightsCopy.layoversYearHint(flights.layoverCount, length)
                : PassportFlightsCopy.tapYearHint
        }
        return flights.layoverCount > 0 ? PassportFlightsCopy.layovers(flights.layoverCount, length) : PassportFlightsCopy.tapHint
    }
}

/// One year's log, opened inside the book from the Flights page: the year and its totals ("2024", "23 flights ·
/// 61,300 km"), then its trips' stubs in date order, which scroll within the page. ‹ Flights goes back and the year bar
/// steps between years. Tapping a stub opens Your world on its arc.
struct PassportFlightsYearPage: View {
    let log: PassportFlightYearLog
    /// Whether VoiceOver goes to the header (the log was opened, not stepped to from its bar).
    let takesFocus: Bool
    let city: (String) -> String?
    let onOpenTrip: (PassportFlightTrip) -> Void
    @AccessibilityFocusState private var headerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PassportPageHeader(title: Text(verbatim: String(log.year)),
                               detail: Text(verbatim: PassportFlightsCopy.summary(log.flightCount, PassportFlightsText.kilometres(log.metres),
                                                                                  planned: log.plannedCount)))
                .modifier(PassportFlightsSpokenHeader(label: PassportFlightsCopy.yearSpoken(log)))
                .accessibilityFocused($headerFocused)
            ForEach(log.trips) { trip in
                PassportFlightStub(trip: trip, days: PassportFlightsText.daysInYear(of: trip), city: city) { onOpenTrip(trip) }
            }
            Text(PassportFlightsCopy.tapHint)
                .font(Font.custom(FernletFontName.dmSansMedium, size: 12.5, relativeTo: .caption))
                .foregroundStyle(PassportBookPalette.dim)
                .fernletWrappingText()
                .padding(.top, 4)
        }
        .task {
            guard takesFocus, await PassportFlightsFocus.settled() else { return }
            headerFocused = true
        }
    }
}

/// When VoiceOver's focus can move on a page that has just replaced another: the button it was on has gone, and a move
/// made in the same moment is lost.
nonisolated enum PassportFlightsFocus {
    /// Waits for the new page to settle; false when the page went first.
    static func settled() async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(300))
            return true
        } catch {
            return false
        }
    }
}

/// Makes a page's header one heading for VoiceOver, spoken as `label` (the drawn header is hidden from it).
struct PassportFlightsSpokenHeader: ViewModifier {
    let label: String

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityHidden(false)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A year's row on the Flights page, drawn as a stub: the year, its flights and its distance, and a › into its log.
/// A button; VoiceOver reads "2024, 23 flights, 61,300 km" and Voice Control takes "2024".
struct PassportFlightsYearRow: View {
    let log: PassportFlightYearLog
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(verbatim: String(log.year))
                    .font(Font.custom(FernletFontName.dmSansBold, size: 17, relativeTo: .headline))
                    .tracking(0.85)
                    .monospacedDigit()
                    .foregroundStyle(PassportBookPalette.text)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        count
                        Spacer(minLength: 0)
                        if log.flightCount > 0 { distance }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        count
                        if log.flightCount > 0 { distance }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                WorldSpriteView(sprite: WorldSprites.chevR, scale: 2, tint: PassportBookPalette.text)
            }
            .modifier(PassportStubFrame())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: PassportFlightsCopy.yearSpoken(log)))
        .accessibilityHint(Text(PassportFlightsCopy.yearHint))
        .accessibilityInputLabels([Text(verbatim: String(log.year))])
        .accessibilityIdentifier("passport.flights.year.\(log.year)")
    }

    private var count: some View {
        Text(verbatim: PassportFlightsCopy.yearCount(log))
            .font(Font.custom(FernletFontName.dmSansBold, size: 12.5, relativeTo: .caption))
            .foregroundStyle(PassportBookPalette.text)
    }

    private var distance: some View {
        Text(verbatim: PassportFlightsText.kilometres(log.metres))
            .font(Font.custom(FernletFontName.dmSansMedium, size: 12.5, relativeTo: .caption))
            .foregroundStyle(PassportBookPalette.dim)
    }
}

/// The boarding-pass frame of a stub or a year's row: its padding, tint and hairline, and the dotted tear line. A
/// planned flight has no tint or tear line and a dashed outline: a ticket not yet used.
struct PassportStubFrame: ViewModifier {
    var isPlanned = false

    func body(content: Content) -> some View {
        content
            .fernletWrappingText()
            .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 10))
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(PassportBookPalette.paper2.opacity(isPlanned ? 0 : 0.55), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isPlanned ? PassportBookPalette.dim : PassportBookPalette.rule,
                              style: StrokeStyle(lineWidth: 1.5, dash: isPlanned ? [6, 4] : [])))
            .overlay(alignment: .leading) {
                if !isPlanned { PassportStubPerforation() }
            }
            .contentShape(Rectangle())
    }
}

/// One trip's boarding-pass stub (`.apstub`): the route's codes with a small jet between, the "Imported" tag, the
/// days and the distance, and "via Helsinki · 2 h 40 min" for a stop. A button; VoiceOver reads "Portland to San
/// Francisco, 12 March 2014, 880 km, imported". A flight still to come draws in dim ink in a dashed frame with the
/// "Planned" tag in place of "Imported", and VoiceOver says "planned".
struct PassportFlightStub: View {
    let trip: PassportFlightTrip
    /// The trip's days, as this list writes them ("12 MAR 2014", or "12 MAR" under its year).
    let days: String
    let city: (String) -> String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                route
                Text(verbatim: days + " · " + PassportFlightsText.kilometres(trip.metres))
                    .font(Font.custom(FernletFontName.dmSansMedium, size: 12.5, relativeTo: .caption))
                    .foregroundStyle(PassportBookPalette.dim)
                if let via { Text(via).font(Font.custom(FernletFontName.dmSansBold, size: 12.5, relativeTo: .caption))
                    .foregroundStyle(PassportBookPalette.moss) }
            }
            .modifier(PassportStubFrame(isPlanned: trip.isPlanned))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    /// "PDX ✈ HEL ✈ NRT" and the tag, which drops under the codes where they leave it too little room.
    private var route: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                codes
                tag
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) { codes }
                tag.padding(.leading, -4)
            }
        }
    }

    /// "Planned" for a flight still to come, else "Imported" for one from a file or the calendar.
    @ViewBuilder
    private var tag: some View {
        if trip.isPlanned {
            PassportPlannedTag()
        } else if trip.isImported {
            PassportImportedTag()
        }
    }

    /// The route's codes with a small jet between.
    @ViewBuilder
    private var codes: some View {
        ForEach(Array(trip.codes.enumerated()), id: \.offset) { position, code in
            if position > 0 {
                WorldSpriteView(sprite: PassportFlightSprites.jet, scale: 1.6, tint: ink)
            }
            Text(verbatim: code)
                .font(Font.custom(FernletFontName.dmSansBold, size: 17, relativeTo: .headline))
                .tracking(0.85)
                .foregroundStyle(ink)
        }
    }

    /// The route's colour: dim for a flight still to come.
    private var ink: Color { trip.isPlanned ? PassportBookPalette.dim : PassportBookPalette.text }

    /// "via Helsinki · 2 h 40 min" for the first stop with a known length, or "via Helsinki" without one.
    private var via: LocalizedStringResource? {
        guard let stop = trip.stops.first else { return nil }
        let name = city(stop.code) ?? stop.code
        guard let seconds = stop.seconds else { return PassportFlightsCopy.via(name) }
        return PassportFlightsCopy.via(name, PassportFlightsText.duration(seconds))
    }

    /// "Portland to San Francisco, 12 March 2014, 880 km, imported".
    private var spoken: String {
        let joiner = String(localized: PassportFlightsCopy.toJoiner)
        let places = trip.codes.map { city($0) ?? $0 }.joined(separator: joiner)
        var parts = [places, PassportDates.long(trip.departure), PassportFlightsText.kilometres(trip.metres)]
        if let via { parts.append(String(localized: via)) }
        if trip.isPlanned {
            parts.append(String(localized: PassportFlightsCopy.plannedSpoken))
        } else if trip.isImported {
            parts.append(String(localized: PassportFlightsCopy.importedSpoken))
        }
        return parts.joined(separator: ", ")
    }
}

/// The stub's dotted tear line down its left edge (the mockup's 4-pt dotted left border). Decoration.
struct PassportStubPerforation: View {
    var body: some View {
        PassportVerticalLine()
            .stroke(PassportBookPalette.rule, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [0.1, 6]))
            .frame(width: 4)
            .padding(.vertical, 5)
            .padding(.leading, 1)
            .accessibilityHidden(true)
    }
}

/// A vertical line down the middle of its frame.
nonisolated struct PassportVerticalLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

/// The "Imported" tag (`.apimpd`): small caps in a dashed outline.
struct PassportImportedTag: View {
    var body: some View {
        Text(PassportFlightsCopy.imported)
            .font(Font.custom(FernletFontName.dmSansBold, size: 10.5, relativeTo: .caption2))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(PassportBookPalette.dim)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(PassportBookPalette.rule, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])))
            .padding(.leading, 4)
    }
}

/// The "Planned" tag on a flight still to come: small caps in moss, in a solid outline, so it reads apart from
/// "Imported" without relying on its colour.
struct PassportPlannedTag: View {
    var body: some View {
        Text(PassportFlightsCopy.plannedTag)
            .font(Font.custom(FernletFontName.dmSansBold, size: 10.5, relativeTo: .caption2))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(PassportBookPalette.moss)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(PassportBookPalette.moss, lineWidth: 1.5))
            .padding(.leading, 4)
    }
}

/// A year's heading among the stubs (`.apyr`): "2014", a heading for VoiceOver.
struct PassportFlightsYear: View {
    let year: Int

    var body: some View {
        Text(verbatim: String(year))
            .font(Font.custom(FernletFontName.dmSansBold, size: 12, relativeTo: .caption))
            .tracking(1.4)
            .foregroundStyle(PassportBookPalette.dim)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The Flights page before any flight: what will show here.
struct PassportFlightsEmpty: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(PassportFlightsCopy.noneYet)
                .font(PassportBookType.title)
                .foregroundStyle(PassportBookPalette.text)
                .accessibilityAddTraits(.isHeader)
            Text(PassportFlightsCopy.noneYetBody)
                .font(PassportBookType.body)
                .foregroundStyle(PassportBookPalette.dim)
                .fernletWrappingText()
        }
        .padding(.vertical, 12)
    }
}

/// "Add past flights" under the stubs (`.apimp`, screen 19): a plus, the title and "From a Flighty export file.
/// Read on this iPhone, never sent." in a 2-pt frame. Voice Control: "Add past flights".
struct PassportAddFlightsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                WorldSpriteView(sprite: WorldSprites.plus, scale: 2, tint: PassportBookPalette.text)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(FlightyImportCopy.addPastFlights)
                        .font(Font.custom(FernletFontName.dmSansBold, size: 15.5, relativeTo: .subheadline))
                        .foregroundStyle(PassportBookPalette.text)
                    Text(FlightyImportCopy.addPastFlightsSub)
                        .font(Font.custom(FernletFontName.dmSansMedium, size: 12.5, relativeTo: .caption))
                        .foregroundStyle(PassportBookPalette.dim)
                }
                .fernletWrappingText()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PassportBookPalette.text, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
        .accessibilityInputLabels([Text(FlightyImportCopy.addPastFlights)])
        .accessibilityIdentifier("passport.flights.addPast")
    }
}

/// The Flights page button's choice (World-Airports-Spec §9.1, "the button offers a Flighty file or Calendar"):
/// "From a Flighty file" opens the file picker, "From Calendar" turns Flights from Calendar on (iOS asks first).
struct PassportFlightSourcePicker: ViewModifier {
    @Binding var isPresented: Bool
    let onFile: () -> Void
    let onCalendar: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(Text(FlightyImportCopy.addPastFlights), isPresented: $isPresented, titleVisibility: .visible) {
            Button { onFile() } label: { Text(PassportFlightsCopy.fromFile) }
            Button { onCalendar() } label: { Text(PassportFlightsCopy.fromCalendar) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// The Flights page's pixel art.
nonisolated enum PassportFlightSprites {
    /// A small jet in profile (the page's `apJet`, `JET_SIDE`, 15 × 7), one ink.
    static let jet = WorldSprite(rows: ["k..............", "kk.............", "kkk............", "kkkkkkkkkkkkkk.",
                                        ".kkkkkkkkkkkkkk", "......kkk......", ".....kkk......."],
                                 palette: ["k": WorldSprite.ink])
}

/// The words of the Flights page and its years' logs (World-Airports-Spec §8; Spanish drafts in `r7-airports-ui-es.json`).
nonisolated enum PassportFlightsCopy {
    static let title = LocalizedStringResource("Flights", comment: "Sprout's passport: the Flights page's name and header")
    /// "5 flights · 24,850 km".
    static func totals(_ count: Int, _ distance: String) -> LocalizedStringResource {
        LocalizedStringResource("\(count) flights · \(distance)",
                                comment: "Sprout's passport Flights page header: how many flights, then the distance flown")
    }
    /// "178 flights, 494,810 km" (VoiceOver, the Flights page's heading).
    static func totalsSpoken(_ count: Int, _ distance: String) -> LocalizedStringResource {
        LocalizedStringResource("\(count) flights, \(distance)",
                                comment: "VoiceOver: flights in the passport: how many, then the distance flown (the page's heading, a year's row)")
    }
    /// "23 flights" (a year's row).
    static func count(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("\(count) flights", comment: "Sprout's passport Flights page: how many flights left in a year")
    }
    /// "2 planned" (a page's or a year's flights still to come).
    static func planned(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("passport.flights.planned", defaultValue: "\(count) planned",
                                comment: "Sprout's passport Flights page: how many flights haven't left yet")
    }
    /// "23 flights · 61,300 km · 2 planned", leaving out what there is none of.
    static func summary(_ count: Int, _ distance: String, planned plannedCount: Int) -> String {
        let flown = String(localized: totals(count, distance)), planned = String(localized: planned(plannedCount))
        guard plannedCount > 0 else { return flown }
        // A no-break space after the dot: where the line wraps, it starts the next line rather than ending this one.
        return count > 0 ? flown + " ·\u{00A0}" + planned : planned
    }
    /// ``summary(_:_:planned:)`` for VoiceOver: "23 flights, 61,300 km, 2 planned".
    static func spokenSummary(_ count: Int, _ distance: String, planned plannedCount: Int) -> String {
        let flown = String(localized: totalsSpoken(count, distance)), planned = String(localized: planned(plannedCount))
        guard plannedCount > 0 else { return flown }
        return count > 0 ? flown + ", " + planned : planned
    }
    /// A year's row's count: "23 flights", "23 flights · 2 planned", or "2 planned".
    static func yearCount(_ log: PassportFlightYearLog) -> String {
        let flown = String(localized: count(log.flightCount)), planned = String(localized: planned(log.plannedCount))
        guard log.plannedCount > 0 else { return flown }
        return log.flightCount > 0 ? flown + " · " + planned : planned
    }
    /// "2024, 23 flights, 61,300 km" (VoiceOver: a year's row, its log's heading, and read on stepping to it).
    static func yearSpoken(_ log: PassportFlightYearLog) -> String {
        String(log.year) + ", " + spokenSummary(log.flightCount, PassportFlightsText.kilometres(log.metres), planned: log.plannedCount)
    }
    static let yearHint = LocalizedStringResource("Opens this year's flights.", comment: "VoiceOver hint: a year's row on the passport's Flights page")
    static let backToFlights = LocalizedStringResource("Back to Flights", comment: "VoiceOver: the back button in a year's flights in the passport")
    static let newerYear = LocalizedStringResource("Newer year", comment: "Sprout's passport: steps to the next more recent year's flights")
    static let olderYear = LocalizedStringResource("Older year", comment: "Sprout's passport: steps to the next older year's flights")
    static let years = LocalizedStringResource("Years", comment: "VoiceOver: the passport's bar of years under a year's flights")
    /// "· 3 of 13" (the year bar's quiet part).
    static func yearStep(_ number: Int, of count: Int) -> LocalizedStringResource {
        LocalizedStringResource("· \(number) of \(count)", comment: "Sprout's passport: which year of the flown years, in the year bar")
    }
    static let tapYearHint = LocalizedStringResource("Tap a year to see its flights.", comment: "Sprout's passport Flights page: the hint under the years")
    /// "38 layovers · 62 h 10 min. Tap a year to see its flights."
    static func layoversYearHint(_ count: Int, _ length: String) -> LocalizedStringResource {
        LocalizedStringResource("\(count) layovers · \(length). Tap a year to see its flights.",
                                comment: "Sprout's passport Flights page: the layovers' count and total length, then the hint under the years")
    }
    /// "1 layover · 2 h 40 min. Tap a flight to see its arc on Your world."
    static func layovers(_ count: Int, _ length: String) -> LocalizedStringResource {
        LocalizedStringResource("\(count) layovers · \(length). Tap a flight to see its arc on Your world.",
                                comment: "Sprout's passport Flights page: the layovers' count and total length, then the hint")
    }
    static let tapHint = LocalizedStringResource("Tap a flight to see its arc on Your world.",
                                                 comment: "Sprout's passport Flights page: the hint under the stubs")
    /// "via Helsinki · 2 h 40 min".
    static func via(_ place: String, _ length: String) -> LocalizedStringResource {
        LocalizedStringResource("via \(place) · \(length)", comment: "Sprout's passport Flights page: a trip's stop and how long it lasted")
    }
    /// "via Helsinki" (a stop whose length isn't known).
    static func via(_ place: String) -> LocalizedStringResource {
        LocalizedStringResource("via \(place)", comment: "Sprout's passport Flights page: a trip's stop, its length unknown")
    }
    static let imported = LocalizedStringResource("Imported", comment: "Sprout's passport Flights page: the tag on a flight added from a file or the calendar")
    static let importedSpoken = LocalizedStringResource("imported", comment: "VoiceOver: said after an imported flight's stub")
    static let plannedTag = LocalizedStringResource("Planned", comment: "Sprout's passport Flights page: the tag on a flight that hasn't left yet")
    static let plannedSpoken = LocalizedStringResource("planned", comment: "VoiceOver: said after the stub of a flight that hasn't left yet")
    /// " to " between the cities VoiceOver reads ("Portland to San Francisco").
    static let toJoiner = LocalizedStringResource(" to ", comment: "VoiceOver: between the cities of a flight's route, with spaces")
    static let fromFile = LocalizedStringResource("From a Flighty file", comment: "Sprout's passport Flights page: adds past flights from a Flighty export file")
    static let fromCalendar = LocalizedStringResource("From Calendar", comment: "Sprout's passport Flights page: turns on Flights from Calendar")
    static let noneYet = LocalizedStringResource("No flights yet", comment: "Sprout's passport Flights page before any flight")
    static let noneYetBody = LocalizedStringResource("Flights you take show here with their arcs on Your world. Add past ones from a Flighty file.",
                                                     comment: "Sprout's passport Flights page before any flight: what shows here")
}
