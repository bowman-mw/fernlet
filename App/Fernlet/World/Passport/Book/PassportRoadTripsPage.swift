import FernletUI
import SwiftUI

/// The Road trips page of Sprout's passport (World-RoadTrip-Spec PR 4, `rt-end`, choice "passport"), beside Flights and
/// on its pattern: "ROAD TRIPS" with the totals ("3 road trips · 1,240 km"), then the years, newest first, each a row
/// that opens its log (``PassportRoadTripsYearPage``). A history that fits one page shows its trips here instead, under
/// year headings. Each trip is one plain row — its name, its days and its road — never a stamp. The book shows this
/// page only when there is a road trip to show (none in a decoy or the demo).
struct PassportRoadTripsPage: View {
    let roadTrips: PassportRoadTripsModel
    /// The year whose row VoiceOver goes back to, its log just closed, or nil.
    let refocusYear: Int?
    let onOpenYear: (Int) -> Void
    @AccessibilityFocusState private var focusedYear: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PassportPageHeader(title: Text(RoadTripCopy.passportTitle),
                               detail: Text(verbatim: RoadTripCopy.passportTotals(roadTrips.trips.count, metres: roadTrips.totalMetres)))
                .modifier(PassportFlightsSpokenHeader(label: RoadTripCopy.passportTotalsSpoken(roadTrips.trips.count,
                                                                                               metres: roadTrips.totalMetres)))
            if roadTrips.listsYears {
                ForEach(roadTrips.years) { log in
                    PassportRoadTripsYearRow(log: log) { onOpenYear(log.year) }
                        .accessibilityFocused($focusedYear, equals: log.year)
                }
                Text(RoadTripCopy.passportTapYear)
                    .font(Font.custom(FernletFontName.dmSansMedium, size: 12.5, relativeTo: .caption))
                    .foregroundStyle(PassportBookPalette.dim)
                    .fernletWrappingText()
                    .padding(.top, 4)
            } else {
                ForEach(roadTrips.years) { log in
                    PassportFlightsYear(year: log.year)
                    ForEach(log.trips) { trip in PassportRoadTripStub(trip: trip, inYear: false) }
                }
            }
        }
        .task {
            guard let refocusYear, await PassportFlightsFocus.settled() else { return }
            focusedYear = refocusYear
        }
    }
}

/// One year's road trips, opened inside the book from the Road trips page: the year and its totals ("2026", "3 road
/// trips · 1,240 km"), then its trips in date order, which scroll within the page. ‹ Road trips goes back and the year
/// bar steps between years.
struct PassportRoadTripsYearPage: View {
    let log: PassportRoadTripYearLog
    /// Whether VoiceOver goes to the header (the log was opened, not stepped to from its bar).
    let takesFocus: Bool
    @AccessibilityFocusState private var headerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PassportPageHeader(title: Text(verbatim: String(log.year)),
                               detail: Text(verbatim: RoadTripCopy.passportTotals(log.trips.count, metres: log.metres)))
                .modifier(PassportFlightsSpokenHeader(label: PassportRoadTripsText.yearSpoken(log)))
                .accessibilityFocused($headerFocused)
            ForEach(log.trips) { trip in PassportRoadTripStub(trip: trip, inYear: true) }
        }
        .task {
            guard takesFocus, await PassportFlightsFocus.settled() else { return }
            headerFocused = true
        }
    }
}

/// A year's row on the Road trips page, drawn as a flight year's is: the year, its trips and its road, and a › into
/// its log. A button; VoiceOver reads "2026, 3 road trips, 1,240 km" and Voice Control takes "2026".
struct PassportRoadTripsYearRow: View {
    let log: PassportRoadTripYearLog
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
                        distance
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        count
                        distance
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                WorldSpriteView(sprite: WorldSprites.chevR, scale: 2, tint: PassportBookPalette.text)
            }
            .modifier(PassportStubFrame())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: PassportRoadTripsText.yearSpoken(log)))
        .accessibilityHint(Text(RoadTripCopy.passportYearHint))
        .accessibilityInputLabels([Text(verbatim: String(log.year))])
        .accessibilityIdentifier("passport.roadTrips.year.\(log.year)")
    }

    private var count: some View {
        Text(RoadTripCopy.passportCount(log.trips.count))
            .font(Font.custom(FernletFontName.dmSansBold, size: 12.5, relativeTo: .caption))
            .foregroundStyle(PassportBookPalette.text)
    }

    private var distance: some View {
        Text(verbatim: RoadTripCopy.distance(log.metres))
            .font(Font.custom(FernletFontName.dmSansMedium, size: 12.5, relativeTo: .caption))
            .foregroundStyle(PassportBookPalette.dim)
    }
}

/// One road trip on the page, as plain as a flight's stub (`.apstub`'s frame and tear line): its name, then its days
/// and its road ("10–12 NOV 2026 · 412 km"). One entry, not a button; VoiceOver reads "Road trip to the coast, 10
/// November 2026 to 12 November 2026, 412 km".
struct PassportRoadTripStub: View {
    let trip: PassportRoadTrip
    /// Whether it sits in a year's log (its days leave the year out).
    let inYear: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: trip.name)
                .font(Font.custom(FernletFontName.dmSansBold, size: 17, relativeTo: .headline))
                .foregroundStyle(PassportBookPalette.text)
            Text(verbatim: PassportRoadTripsText.days(of: trip, inYear: inYear) + " · " + RoadTripCopy.distance(trip.metres))
                .font(Font.custom(FernletFontName.dmSansMedium, size: 12.5, relativeTo: .caption))
                .foregroundStyle(PassportBookPalette.dim)
        }
        .modifier(PassportStubFrame())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: PassportRoadTripsText.spoken(trip)))
        .accessibilityIdentifier("passport.roadTrips.trip")
    }
}
