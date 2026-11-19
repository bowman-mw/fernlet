import Foundation

/// The words of "Live planes nearby" (owner 2026-11-19). ``disclosure`` is the owner's approved copy, used verbatim on
/// the onboarding question, the Settings switch and the first-time confirmation.
nonisolated enum LiveAircraftCopy {
    /// The switch's name, and the onboarding question's heading.
    static let title = LocalizedStringResource("livePlanes.title", defaultValue: "Live planes nearby",
                                               comment: "Live planes: the Settings switch and the onboarding question's heading")
    /// The approved disclosure (owner 2026-11-19, call 12, verbatim).
    static let disclosure = LocalizedStringResource(
        "livePlanes.disclosure",
        defaultValue: "While the map is open, Fernlet asks adsb.lol, a community flight tracker, for planes in the area the map shows (about 55 km around). adsb.lol sees that area and your internet address. Nothing about the planes is saved.",
        comment: "Live planes: what the switch sends and to whom (owner-approved wording; keep 'adsb.lol' as written)")
    /// The button that turns live planes on (onboarding, the first-time confirmation).
    static let turnOn = LocalizedStringResource("livePlanes.turnOn", defaultValue: "Show live planes",
                                                comment: "Live planes: the button that turns them on (onboarding and the first-time confirmation)")
    /// The first-time confirmation's no.
    static let notNow = LocalizedStringResource("livePlanes.notNow", defaultValue: "Not now",
                                                comment: "Live planes: leave them off")
    /// Spoken once the onboarding button turns live planes on (the button is replaced by "On").
    static let onAnnouncement = LocalizedStringResource("livePlanes.on.announcement", defaultValue: "Live planes are on.",
                                                        comment: "VoiceOver, onboarding: said after the live planes button turns them on")
    /// The first-time confirmation's title.
    static let confirmTitle = LocalizedStringResource("livePlanes.confirm.title", defaultValue: "Show live planes nearby?",
                                                      comment: "Live planes: the one-time confirmation when the switch is first turned on")
    /// Settings' quiet line once today's cap is spent.
    static let resting = LocalizedStringResource("livePlanes.resting", defaultValue: "Live planes are resting until tomorrow.",
                                                 comment: "Settings, under the live planes switch: today's 400 lookups are used up")
    /// The map's credit, a notice kept as written in every language.
    static let credit = "© adsb.lol contributors"
    /// The credit's VoiceOver label.
    static let creditSpoken = LocalizedStringResource("livePlanes.credit.spoken", defaultValue: "Live plane data from adsb.lol contributors",
                                                      comment: "VoiceOver label of the small map credit for live planes; it opens adsb.lol's licence page")

    // MARK: The card

    /// The card's altitude row.
    static let altitude = LocalizedStringResource("livePlanes.card.altitude", defaultValue: "Altitude",
                                                  comment: "Live plane card: the altitude row's label")
    /// The card's speed row.
    static let speed = LocalizedStringResource("livePlanes.card.speed", defaultValue: "Speed",
                                               comment: "Live plane card: the ground speed row's label")
    /// The card's type row.
    static let type = LocalizedStringResource("livePlanes.card.type", defaultValue: "Aircraft",
                                              comment: "Live plane card: the aircraft type row's label")
    /// The card's title for a plane with no callsign.
    static let noCallsign = LocalizedStringResource("livePlanes.card.noCallsign", defaultValue: "A plane",
                                                    comment: "Live plane card: the title when the plane sends no callsign")
    /// The type row for a type the app doesn't know.
    static let unknownType = LocalizedStringResource("livePlanes.card.unknownType", defaultValue: "Not known",
                                                     comment: "Live plane card: the aircraft row when the type isn't sent")
    /// The card's line that nothing is kept.
    static let nothingSaved = LocalizedStringResource("livePlanes.card.nothingSaved", defaultValue: "Live from adsb.lol. Nothing is saved.",
                                                      comment: "Live plane card: the small line at the bottom")
    /// The card's close button.
    static let close = LocalizedStringResource("livePlanes.card.close", defaultValue: "Close", comment: "Live plane card: close it")

    // MARK: Planes you've flown on

    /// The label on a plane whose tail matches one of the person's flights.
    static let flewOnThisPlane = LocalizedStringResource("livePlanes.flown.plane", defaultValue: "You flew on this plane",
                                                         comment: "Live planes: the label on a plane with the same tail number as one of your flights")
    /// The lighter label on a plane whose type matches one of the person's flights.
    static let flewThisType = LocalizedStringResource("livePlanes.flown.type", defaultValue: "You've flown this type",
                                                      comment: "Live planes: the light label on a plane of a type you've flown")

    // MARK: VoiceOver

    /// The one element the planes are to VoiceOver.
    static func spokenCount(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("livePlanes.spoken.count", defaultValue: "\(count) live planes on the map",
                                comment: "VoiceOver: the planes on the map as one element; its actions open each plane's card")
    }

    /// The airline's flight ("United 1704") or the callsign as flown, or nil with neither.
    static func flightName(_ plane: LiveAircraft) -> String? {
        if let flight = LiveAircraftAirlines.flight(plane.callsign) { return "\(flight.airline.name) \(flight.number)" }
        return plane.callsign
    }

    /// The type in words, or its code when it isn't listed, or nil when the feed didn't send it.
    static func typeName(_ plane: LiveAircraft) -> String? {
        LiveAircraftTypes.type(plane.typeCode)?.name ?? plane.typeCode
    }

    /// Altitude in the person's units: feet where the locale doesn't use metric (and in the UK, where flying does),
    /// metres elsewhere.
    static func altitude(feet: Int, locale: Locale = .current) -> String {
        let measurement = Measurement(value: Double(feet), unit: UnitLength.feet)
        let usesFeet = locale.measurementSystem != .metric
        let shown = usesFeet ? measurement : measurement.converted(to: .meters)
        let rounded = Measurement(value: (shown.value / (usesFeet ? 50 : 10)).rounded() * (usesFeet ? 50 : 10), unit: shown.unit)
        return rounded.formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))).locale(locale))
    }

    /// Ground speed in the person's units (mph or km/h, as the locale says).
    static func speed(knots: Double, locale: Locale = .current) -> String {
        Measurement(value: knots, unit: UnitSpeed.knots)
            .formatted(.measurement(width: .abbreviated, usage: .general, numberFormatStyle: .number.precision(.fractionLength(0))).locale(locale))
    }
}
