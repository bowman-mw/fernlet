import FernletUI
import SwiftUI
import WorldMapStore

/// A Flights page of Sprout's passport (World-Airports-Spec §8, screens 11, 19 and 23, approved): "FLIGHTS" with
/// the totals ("5 flights · 24,850 km"), then the trips as boarding-pass stubs under year headings, each imported
/// one tagged "Imported". The last Flights page ends with the layovers' total ("1 layover · 2 h 40 min. Tap a flight
/// to see its arc on Your world.") and the "Add past flights" button (from a Flighty file, read on this iPhone).
/// Tapping a stub opens Your world on its arc.
struct PassportFlightsPage: View {
    let flights: PassportFlightsModel
    /// Which Flights page, from 0.
    let index: Int
    /// A trip's airports' cities, by IATA code (the list's English or Spanish city; nil for a points-only code).
    let city: (String) -> String?
    let onOpenTrip: (PassportFlightTrip) -> Void
    let onAddPastFlights: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PassportPageHeader(title: Text(PassportFlightsCopy.title), detail: totals)
            if flights.isEmpty {
                PassportFlightsEmpty()
            } else {
                ForEach(flights.rows(onPage: index), id: \.self) { row in
                    switch row {
                    case .year(let year): PassportFlightsYear(year: year)
                    case .trip(let number): stub(flights.trips[number])
                    }
                }
            }
            if index == flights.pages.count - 1 {
                if !flights.isEmpty {
                    Text(note)
                        .font(Font.custom(FernletFontName.dmSansMedium, size: 12.5, relativeTo: .caption))
                        .foregroundStyle(PassportBookPalette.dim)
                        .fernletWrappingText()
                        .padding(.top, 4)
                }
                PassportAddFlightsButton(action: onAddPastFlights)
            }
        }
    }

    /// "5 flights · 24,850 km", or nothing before the first flight.
    private var totals: Text? {
        guard !flights.isEmpty else { return nil }
        return Text(PassportFlightsCopy.totals(flights.flightCount, PassportFlightsText.kilometres(flights.totalMetres)))
    }

    /// The layovers' total and the hint.
    private var note: LocalizedStringResource {
        guard flights.layoverCount > 0 else { return PassportFlightsCopy.tapHint }
        return PassportFlightsCopy.layovers(flights.layoverCount, PassportFlightsText.duration(flights.layoverSeconds))
    }

    private func stub(_ trip: PassportFlightTrip) -> some View {
        PassportFlightStub(trip: trip, city: city) { onOpenTrip(trip) }
    }
}

/// One trip's boarding-pass stub (`.apstub`): the route's codes with a small jet between, the "Imported" tag, the
/// days and the distance, and "via Helsinki · 2 h 40 min" for a stop. A button; VoiceOver reads "Portland to San
/// Francisco, 12 March 2014, 880 km, imported".
struct PassportFlightStub: View {
    let trip: PassportFlightTrip
    let city: (String) -> String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                route
                Text(verbatim: PassportFlightsText.days(of: trip) + " · " + PassportFlightsText.kilometres(trip.metres))
                    .font(Font.custom(FernletFontName.dmSansMedium, size: 12.5, relativeTo: .caption))
                    .foregroundStyle(PassportBookPalette.dim)
                if let via { Text(via).font(Font.custom(FernletFontName.dmSansBold, size: 12.5, relativeTo: .caption))
                    .foregroundStyle(PassportBookPalette.moss) }
            }
            .fernletWrappingText()
            .padding(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 10))
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(PassportBookPalette.paper2.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(PassportBookPalette.rule, lineWidth: 1.5))
            .overlay(alignment: .leading) { PassportStubPerforation() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    /// "PDX ✈ HEL ✈ NRT" and the tag.
    private var route: some View {
        HStack(spacing: 5) {
            ForEach(Array(trip.codes.enumerated()), id: \.offset) { position, code in
                if position > 0 {
                    WorldSpriteView(sprite: PassportFlightSprites.jet, scale: 1.6, tint: PassportBookPalette.text)
                }
                Text(verbatim: code)
                    .font(Font.custom(FernletFontName.dmSansBold, size: 17, relativeTo: .headline))
                    .tracking(0.85)
                    .foregroundStyle(PassportBookPalette.text)
            }
            if trip.isImported { PassportImportedTag() }
        }
    }

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
        if trip.isImported { parts.append(String(localized: PassportFlightsCopy.importedSpoken)) }
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
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(PassportBookPalette.rule, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])))
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

/// The Flights page's pixel art.
nonisolated enum PassportFlightSprites {
    /// A small jet in profile (the page's `apJet`, `JET_SIDE`, 15 × 7), one ink.
    static let jet = WorldSprite(rows: ["k..............", "kk.............", "kkk............", "kkkkkkkkkkkkkk.",
                                        ".kkkkkkkkkkkkkk", "......kkk......", ".....kkk......."],
                                 palette: ["k": WorldSprite.ink])
}

/// The words of the Flights pages (World-Airports-Spec §8; Spanish drafts in `r7-airports-ui-es.json`).
nonisolated enum PassportFlightsCopy {
    static let title = LocalizedStringResource("Flights", comment: "Sprout's passport: the Flights page's name and header")
    /// "5 flights · 24,850 km".
    static func totals(_ count: Int, _ distance: String) -> LocalizedStringResource {
        LocalizedStringResource("\(count) flights · \(distance)",
                                comment: "Sprout's passport Flights page header: how many flights, then the distance flown")
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
    /// " to " between the cities VoiceOver reads ("Portland to San Francisco").
    static let toJoiner = LocalizedStringResource(" to ", comment: "VoiceOver: between the cities of a flight's route, with spaces")
    static let noneYet = LocalizedStringResource("No flights yet", comment: "Sprout's passport Flights page before any flight")
    static let noneYetBody = LocalizedStringResource("Flights you take show here with their arcs on Your world. Add past ones from a Flighty file.",
                                                     comment: "Sprout's passport Flights page before any flight: what shows here")
}
