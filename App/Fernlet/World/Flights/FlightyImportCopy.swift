import Foundation
import WorldMapStore

/// The words of the Flighty import and the Flights page (World-Airports-Spec §8, §9; the approved page's copy,
/// Spanish drafts in the lane's `r7-airports-ui-es.json`).
nonisolated enum FlightyImportCopy {
    // MARK: Where it lives (19)

    /// "Add past flights" (the Flights page's button, the Privacy & data row, Voice Control's name).
    static let addPastFlights = LocalizedStringResource("Add past flights",
                                                        comment: "Airports: the button and Settings row that import past flights from a Flighty file")
    /// The button's sub line.
    static let addPastFlightsSub = LocalizedStringResource("From a Flighty export file. Read on this iPhone, never sent.",
                                                           comment: "Airports: the line under Add past flights on the passport's Flights page")
    /// The Settings row's sub line.
    static let addPastFlightsRowSub = LocalizedStringResource("From a Flighty export file",
                                                              comment: "Privacy & data: the line under Add past flights")
    /// "Airports and flights" (the Privacy & data card's title).
    static let cardTitle = LocalizedStringResource("Airports and flights", comment: "Privacy & data: the airports and flights card's title")
    /// "Remove imported flights".
    static let removeImported = LocalizedStringResource("Remove imported flights",
                                                        comment: "Privacy & data: removes every flight added from a file or the calendar")
    /// The removal's confirmation.
    static let removeTitle = LocalizedStringResource("Remove imported flights?", comment: "Privacy & data: the confirmation's title")
    static let removeBody = LocalizedStringResource("Their arcs and Flights page entries go. Flights Fernlet saw itself stay.",
                                                    comment: "Privacy & data: what removing imported flights does")
    static let removeConfirm = LocalizedStringResource("Remove", comment: "Privacy & data: confirms removing imported flights")
    /// "Removed 48 imported flights" (announced).
    static func removed(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("Removed \(count) imported flights",
                                comment: "VoiceOver: announced after imported flights were removed; the number of flights")
    }

    // MARK: What was found (21)

    /// "Past flights" (the sheet's title).
    static let sheetTitle = LocalizedStringResource("Past flights", comment: "Airports: the Flighty import summary sheet's title")
    /// "From FlightyExport.csv".
    static func fromFile(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource("From \(name)", comment: "Airports: the import sheet's subtitle: the file's name")
    }
    static let tileFlights = LocalizedStringResource("flights", comment: "Airports: the import summary tile under the number of flights")
    static let tileAirports = LocalizedStringResource("airports", comment: "Airports: the import summary tile under the number of airports")
    static let tileCountries = LocalizedStringResource("countries", comment: "Airports: the import summary tile under the number of countries")
    static let tileYears = LocalizedStringResource("years", comment: "Airports: the import summary tile under the years flown")
    /// "Found 48 flights, 31 airports, 9 countries, 2014 to 2026" (the tiles, for VoiceOver): the countries left
    /// out where the list doesn't know them all, "Found no flights" for none.
    static func foundLabel(_ summary: FlightyImportSummary) -> LocalizedStringResource {
        guard let years = summary.years else {
            return LocalizedStringResource("Found no flights", comment: "VoiceOver: the import summary when the file held no flights")
        }
        let first = String(years.lowerBound), last = String(years.upperBound)
        guard let countries = summary.countries else {
            return LocalizedStringResource("Found \(summary.flights) flights, \(summary.airports) airports, \(first) to \(last)",
                                           comment: "VoiceOver: the import summary's tiles: flights, airports, first and last year")
        }
        return LocalizedStringResource("Found \(summary.flights) flights, \(summary.airports) airports, \(countries) countries, \(first) to \(last)",
                                       comment: "VoiceOver: the import summary's tiles: flights, airports, countries, first and last year")
    }

    static let skipped = LocalizedStringResource("Skipped", comment: "Airports: the import sheet's heading for rows left out")
    static func cancelled(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("\(count) cancelled", comment: "Airports: import rows skipped because the flight was cancelled")
    }
    static func repeated(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("\(count) repeated rows", comment: "Airports: import rows skipped because the file repeats a flight")
    }
    static func unknownCodes(_ count: Int, _ codes: String) -> LocalizedStringResource {
        LocalizedStringResource("\(count) unknown airport code: \(codes)",
                                comment: "Airports: import rows skipped for airport codes not in the list; the codes named, never guessed")
    }
    static func unreadable(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("\(count) rows without a date or airports",
                                comment: "Airports: import rows skipped because their date or airport codes couldn't be read")
    }
    static let nothingSkipped = LocalizedStringResource("Nothing", comment: "Airports: the import skipped no rows")

    static let alreadyHeld = LocalizedStringResource("Already in the passport", comment: "Airports: the import sheet's heading for flights kept once")
    static func alreadySeen(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("\(count) flights Fernlet saw, kept once",
                                comment: "Airports: import flights the passport already holds because Fernlet saw them")
    }
    static func alreadyImported(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("\(count) flights already imported, kept once",
                                comment: "Airports: import flights the passport already holds from an earlier import")
    }

    static let whatTheyDo = LocalizedStringResource("What they'll do", comment: "Airports: the import sheet's heading for its effect")
    static let whatTheyDoBody = LocalizedStringResource("Draw their arcs on Your world and join the Flights page, marked Imported. Their airports show as flown through; stamps, countries and fog still need you there.",
                                                        comment: "Airports: what imported flights do, and don't do")
    static let lockNotice = LocalizedStringResource("Fernlet reads only each flight's date, airports and gate times. The file isn't kept, and nothing leaves this iPhone.",
                                                    comment: "Airports: the import sheet's privacy notice")
    /// "Add 48 flights" (the confirm, and Voice Control's name).
    static func add(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("Add \(count) flights", comment: "Airports: the import sheet's confirm button; the number of flights")
    }
    static let noneToAdd = LocalizedStringResource("No flights to add", comment: "Airports: the import sheet's disabled confirm when the file held no flights")
    static let removeLater = LocalizedStringResource("You can remove them all in Privacy & data.",
                                                     comment: "Airports: the line under the import sheet's confirm")
    /// "Added 48 flights from Flighty" (the toast).
    static func addedToast(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("Added \(count) flights from Flighty", comment: "Airports: the toast after an import; Undo beside it")
    }

    // MARK: What Fernlet reads (24)

    static let readsLink = LocalizedStringResource("What Fernlet reads from the file",
                                                   comment: "Airports: the import sheet's link to what is read from a Flighty file")
    static let readsTitle = LocalizedStringResource("What Fernlet reads", comment: "Airports: the title of what is read from a Flighty file")
    static let readsColumn = LocalizedStringResource("Read", comment: "Airports: the heading of the column of what's read from a Flighty file")
    static let readsWhy = LocalizedStringResource("What for", comment: "Airports: the heading of the column of why each field is read")
    /// The table's rows: what's read, then what for.
    static let readsRows: [(LocalizedStringResource, LocalizedStringResource)] = [
        (LocalizedStringResource("Date", comment: "Airports: a field read from a Flighty file"),
         LocalizedStringResource("The day it goes on", comment: "Airports: why a Flighty file's date is read")),
        (LocalizedStringResource("From, To", comment: "Airports: fields read from a Flighty file"),
         LocalizedStringResource("The airports and the arc", comment: "Airports: why a Flighty file's From and To are read")),
        (LocalizedStringResource("Gate departure and arrival times", comment: "Airports: fields read from a Flighty file"),
         LocalizedStringResource("To put flights in order and time stops", comment: "Airports: why a Flighty file's gate times are read")),
        (LocalizedStringResource("Cancelled, Diverted to", comment: "Airports: fields read from a Flighty file"),
         LocalizedStringResource("To skip a flight, or use where it really went", comment: "Airports: why a Flighty file's Cancelled and Diverted to are read")),
        (LocalizedStringResource("Flighty's flight ID", comment: "Airports: a field read from a Flighty file"),
         LocalizedStringResource("To count a flight once when the file repeats it", comment: "Airports: why a Flighty file's flight ID is read")),
    ]
    static let droppedTitle = LocalizedStringResource("Dropped as it's read, never kept", comment: "Airports: the heading of what a Flighty file holds that is never kept")
    static let droppedBody = LocalizedStringResource("Airline, flight number, aircraft, booking code, seat, seat type, cabin, reason, notes, tail number, terminals and gates.",
                                                     comment: "Airports: what a Flighty file holds that is never kept")
    static let zonesTitle = LocalizedStringResource("Times without a time zone", comment: "Airports: the heading of how a Flighty file's times are read")
    static let zonesBody = LocalizedStringResource("The file's times are local to each airport. The airport list carries each airport's time zone, so the phone works out stops offline.",
                                                   comment: "Airports: how a Flighty file's local times are read")
    static let columnsTitle = LocalizedStringResource("Columns by name", comment: "Airports: the heading of how a Flighty file's columns are found")
    static let columnsBody = LocalizedStringResource("Columns are matched by name, so a Flighty update that adds columns still imports.",
                                                     comment: "Airports: why a newer Flighty file still imports")

    // MARK: Problems

    static let problemTitle = LocalizedStringResource("Couldn't add flights", comment: "Airports: the alert's title when a Flighty file isn't imported")

    /// The alert's message for `problem`.
    static func message(_ problem: FlightyImportProblem) -> LocalizedStringResource {
        switch problem {
        case .refused(let refusal): message(refusal)
        case .unreadable:
            LocalizedStringResource("That file couldn't be opened. Try saving it to Files first.",
                                    comment: "Airports: a picked file couldn't be read")
        case .noAirportList:
            LocalizedStringResource("Fernlet's airport list is missing from this copy of the app.",
                                    comment: "Airports: the bundled airport list couldn't be opened")
        case .passportClosed:
            LocalizedStringResource("The passport can't be opened right now. Unlock your iPhone and try again.",
                                    comment: "Airports: the passport couldn't be read or saved")
        }
    }

    /// Why a whole file was turned away.
    static func message(_ refusal: FlightyImportRefusal) -> LocalizedStringResource {
        switch refusal {
        case .tooLarge:
            LocalizedStringResource("That file is too big to be a Flighty export.", comment: "Airports: a picked file is over the size cap")
        case .tooManyRows:
            LocalizedStringResource("That file has more flights than Fernlet can read at once.", comment: "Airports: a picked file is over the row cap")
        case .missingColumn(let column):
            LocalizedStringResource("That file has no \(column) column, so it isn't a Flighty export.",
                                    comment: "Airports: a picked file lacks a column every Flighty export has; the column's English name")
        case .empty, .notText, .tooManyFields, .fieldTooLong, .badQuoting:
            LocalizedStringResource("That doesn't look like a Flighty export file.", comment: "Airports: a picked file isn't a readable CSV")
        }
    }
}
