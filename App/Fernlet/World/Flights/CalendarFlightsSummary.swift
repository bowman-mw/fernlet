import Foundation
import WorldMapStore

extension CalendarFlightsFound {
    /// The first look's summary (World-Airports-Spec §10.5, screen 28): "Flights in your calendar", "Looked back
    /// to 2019"; tiles for the flights, airports, upcoming flights and years; Skipped (the flight events with no
    /// airport codes, else "Nothing"), Already in the passport (only when it holds some), Upcoming (only when there
    /// are some); the calendar's lock notice; and "Add 23 flights" for the flown ones.
    var content: FlightImportSummaryContent {
        let tiles = [
            FlightImportTile(look.flown.count, FlightyImportCopy.tileFlights),
            FlightImportTile(look.airportCount, FlightyImportCopy.tileAirports),
            FlightImportTile(look.upcoming.count, CalendarFlightsCopy.tileUpcoming),
            FlightImportTile(years: look.years, FlightyImportCopy.tileYears),
        ]
        let skipped = look.noAirportCodes > 0 ? CalendarFlightsCopy.noAirportCodes(look.noAirportCodes)
            : FlightyImportCopy.nothingSkipped
        var lines = [FlightImportSummaryLine(title: FlightyImportCopy.skipped, parts: [skipped])]
        if let held = CalendarFlightsCopy.alreadyHeld(fromFlighty: fromFlighty, fernletSaw: fernletSaw) {
            lines.append(FlightImportSummaryLine(title: FlightyImportCopy.alreadyHeld, parts: [held]))
        }
        if !look.upcoming.isEmpty {
            lines.append(FlightImportSummaryLine(title: CalendarFlightsCopy.upcomingTitle,
                                                 parts: [CalendarFlightsCopy.upcoming(look.upcoming.count)]))
        }
        let label = CalendarFlightsCopy.foundLabel(flights: look.flown.count, airports: look.airportCount,
                                                   upcoming: look.upcoming.count, years: look.years)
        return FlightImportSummaryContent(
            title: CalendarFlightsCopy.sheetTitle, subtitle: CalendarFlightsCopy.lookedBackTo(CalendarFlightLook.firstLookYear),
            tiles: tiles, tilesLabel: label, lines: lines, notice: CalendarFlightsCopy.lockNotice, showsReadsLink: false,
            count: plan.flights.count, anchor: "screen.calendarFlights")
    }
}
