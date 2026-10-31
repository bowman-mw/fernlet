import Foundation
import WorldMapStore

/// The words of Take a trip, the ticket and the boarding pass (World-Airports-Spec §5, §7, §10.7; the mockup's
/// `T(c, en, es)` pairs carry the approved Spanish, and the few lines the mockup doesn't draw have drafts, all in
/// `r7-airports-ui-es-trip.json`). Airport names and cities are data from the bundled list.
nonisolated enum WorldTripCopy {
    // MARK: The blue button's row (§7, screen 16)

    /// "Take a trip": the blue button's row, the Home Screen quick action and its Voice Control name.
    static let takeATrip = LocalizedStringResource("worldTrip.takeATrip", defaultValue: "Take a trip",
                                                   comment: "World Home quick start and the Home Screen quick action: opens the companion's boarding pass to start a trip (Spanish: Hacer un viaje)")

    /// "Sprout's boarding pass: say where you're going" (the row's line).
    static func takeATripDetail(companion: String) -> String {
        String(localized: "worldTrip.takeATrip.detail", defaultValue: "\(companion)'s boarding pass: say where you're going",
               comment: "World Home quick start: under 'Take a trip'; the companion's name (Spanish: La tarjeta de embarque de …: di adónde vas)")
    }

    /// "End trip · London", or "End trip" with no destination.
    static func endTrip(city: String?) -> String {
        guard let city else { return String(localized: endTripPlain) }
        return String(localized: "worldTrip.endTrip.to", defaultValue: "End trip · \(city)",
                      comment: "World Home quick start while a trip is on: ends it; the destination's city (Spanish: Terminar el viaje · …)")
    }

    /// "End trip".
    static let endTripPlain = LocalizedStringResource("worldTrip.endTrip", defaultValue: "End trip",
                                                      comment: "World Home quick start while a trip with no destination is on: ends it")

    /// The End trip row's line.
    static let endTripDetail = LocalizedStringResource("worldTrip.endTrip.detail", defaultValue: "It ends by itself when you get home",
                                                       comment: "World Home quick start: under 'End trip'; a trip also ends on its own back home")

    /// Said when a trip starts and ends (VoiceOver).
    static let started = LocalizedStringResource("worldTrip.started", defaultValue: "Trip started",
                                                 comment: "VoiceOver: said after Start trip on the companion's boarding pass")
    static let ended = LocalizedStringResource("worldTrip.ended", defaultValue: "Trip ended",
                                               comment: "VoiceOver: said after End trip in the quick start")

    // MARK: The pass and the ticket (§5, §7, screens 6 and 17)

    static let boardingPass = LocalizedStringResource("worldTrip.pass.header", defaultValue: "Boarding pass",
                                                      comment: "The companion's boarding pass: its green header band (Spanish: Tarjeta de embarque)")
    static let from = LocalizedStringResource("worldTrip.pass.from", defaultValue: "From",
                                              comment: "The companion's boarding pass: the departure airport's label (Spanish: De)")
    static let to = LocalizedStringResource("worldTrip.pass.to", defaultValue: "To",
                                            comment: "The companion's boarding pass: the arrival airport's label, and the ticket's To field (Spanish: A)")
    static let passenger = LocalizedStringResource("worldTrip.pass.passenger", defaultValue: "Passenger",
                                                   comment: "The companion's boarding pass: the passenger's label (Spanish: Pasajero)")
    static let date = LocalizedStringResource("worldTrip.pass.date", defaultValue: "Date",
                                              comment: "The companion's boarding pass: the date's label (Spanish: Fecha)")
    static let seat = LocalizedStringResource("worldTrip.pass.seat", defaultValue: "Seat",
                                              comment: "The companion's boarding pass: the seat's label (Spanish: Asiento)")
    /// "Window": the seat, a joke (§5).
    static let window = LocalizedStringResource("worldTrip.pass.window", defaultValue: "Window",
                                                comment: "The companion's boarding pass: its seat, always the window, a joke (Spanish: Ventanilla)")
    /// "Wherever you land": To before a landing (§5).
    static let whereverYouLand = LocalizedStringResource("worldTrip.pass.wherever", defaultValue: "Wherever you land",
                                                         comment: "The companion's boarding pass: under an empty To before landing (Spanish: Donde aterrices)")
    /// From before the person is at an airport (§7).
    static let fromFillsIn = LocalizedStringResource("worldTrip.pass.fromFillsIn", defaultValue: "Fills in at the airport you leave from",
                                                     comment: "The companion's ticket away from an airport: under an empty From")
    /// The pass's stub line before landing.
    static func stub(companion: String) -> String {
        String(localized: "worldTrip.pass.stub", defaultValue: "Fills in when you land, then goes in \(companion)'s passport.",
               comment: "The companion's boarding pass before landing: the line beside the barcode; the companion's name (Spanish: Se completa al aterrizar y pasa al pasaporte de …)")
    }

    /// The ticket's To field's prompt and VoiceOver hint: "A city, airport or code".
    static let toPrompt = LocalizedStringResource("worldTrip.ticket.toPrompt", defaultValue: "A city, airport or code",
                                                  comment: "The companion's ticket: the To field's placeholder (Spanish: Ciudad, aeropuerto o código)")
    /// "Start trip".
    static let startTrip = LocalizedStringResource("worldTrip.ticket.start", defaultValue: "Start trip",
                                                   comment: "The companion's ticket: starts the trip (Spanish: Empezar el viaje)")
    /// The hint under Start trip (hidden at the largest text).
    static let leaveBlank = LocalizedStringResource("worldTrip.ticket.leaveBlank",
                                                    defaultValue: "Not sure yet? Leave To blank; it fills in when you land.",
                                                    comment: "The companion's ticket: under Start trip (Spanish: ¿Aún no lo sabes? Deja A en blanco; se completa al aterrizar.)")
    /// The suggestions list's name for VoiceOver.
    static let suggestions = LocalizedStringResource("worldTrip.ticket.suggestions", defaultValue: "Suggestions",
                                                     comment: "VoiceOver: the airport suggestions under the companion's ticket (Spanish: Sugerencias)")

    /// The ticket's name for VoiceOver: "Take a trip. Sprout's boarding pass."
    static func spokenTicket(companion: String) -> String {
        String(localized: "worldTrip.ticket.spoken", defaultValue: "Take a trip. \(companion)'s boarding pass.",
               comment: "VoiceOver: the companion's ticket; the companion's name (Spanish: Hacer un viaje. Tarjeta de embarque de ….)")
    }

    // MARK: Suggestions

    /// A suggestion's first line: "London · every airport", or "LHR · Heathrow".
    static func title(_ suggestion: WorldTripSuggestion) -> String {
        switch suggestion.destination.kind {
        case .city:
            let city = suggestion.city
            return String(localized: "worldTrip.suggestion.city", defaultValue: "\(city) · every airport",
                          comment: "The companion's ticket: a suggestion for every airport of a city; the city (Spanish: … · todos los aeropuertos)")
        case .airport:
            return "\(suggestion.destination.code) · \(suggestion.name)"
        }
    }

    /// A suggestion's second line: a city's codes ("LHR, LGW, STN, LCY, LTN"), or an airport's city.
    static func detail(_ suggestion: WorldTripSuggestion) -> String {
        suggestion.destination.kind == .city ? codes(suggestion.destination) : suggestion.city
    }

    /// A city destination's codes, comma separated.
    static func codes(_ destination: WorldTripDestination) -> String {
        destination.cityCodes.joined(separator: ", ")
    }

    // MARK: On the day (§10.7, screen 29)

    /// "Trip to Honolulu": the blue button's label on the day of a calendar flight.
    static func tripTo(_ city: String) -> String {
        String(localized: "worldTrip.today.label", defaultValue: "Trip to \(city)",
               comment: "World Home: the label beside the blue button at the airport on a calendar flight's day; the destination's city (Spanish: Viaje a …)")
    }

    /// "Honolulu today? Your ticket's ready!": the companion's line, once.
    static func todayLine(_ city: String) -> String {
        String(localized: "worldTrip.today.line", defaultValue: "\(city) today? Your ticket's ready!",
               comment: "World Home: the companion's line at the airport on a calendar flight's day; the destination's city (Spanish: ¿… hoy? ¡Tu billete está listo!)")
    }

    // MARK: Spoken pass

    /// VoiceOver for the pass: "Sprout's boarding pass. From PDX, Portland, to LHR, London. 2 October 2026." (§5).
    static func spokenPass(companion: String, from: String, to: String?, date: String) -> String {
        guard let to else {
            return String(localized: "worldTrip.pass.spoken.open",
                          defaultValue: "\(companion)'s boarding pass. From \(from). To: not known yet, it fills in when you land. \(date).",
                          comment: "VoiceOver: the companion's boarding pass before landing; the companion's name, the departure (code and name), the date (Spanish: Tarjeta de embarque de …. De …. A: aún no se sabe, se completa al aterrizar. ….)")
        }
        return String(localized: "worldTrip.pass.spoken", defaultValue: "\(companion)'s boarding pass. From \(from), to \(to). \(date).",
                      comment: "VoiceOver: the companion's boarding pass; the companion's name, the departure and arrival (each a code and city), the date (Spanish: Tarjeta de embarque de …. De …, a …. ….)")
    }

    /// A stop as VoiceOver reads it: "PDX, Portland".
    static func spokenStop(code: String, place: String) -> String {
        place.isEmpty || place == code ? code : "\(code), \(place)"
    }
}
