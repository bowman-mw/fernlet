import Foundation

/// A plane's colours (owner 2026-11-19, call 5: "commercial flights get different color schemes"; colours only, no
/// logos). The design's ink outlines every plane; these fill it.
nonisolated struct LiveAircraftLivery: Hashable, Sendable {
    /// The fuselage.
    let body: UInt32
    /// The wings.
    let wing: UInt32
    /// The tail.
    let tail: UInt32
    /// The engines or nacelles, and a stripe where the design has one.
    let accent: UInt32

    /// The wings' grey on an airliner.
    static let airlinerWing: UInt32 = 0xC3C8CC

    /// An airline's scheme: its fuselage, tail and accent, on grey wings.
    static func airline(body: UInt32, tail: UInt32, accent: UInt32) -> LiveAircraftLivery {
        LiveAircraftLivery(body: body, wing: airlinerWing, tail: tail, accent: accent)
    }

    /// The scheme of a plane flying for no listed airline, by design: cream and stone with a family colour, so private
    /// planes, helicopters and the like still differ from each other.
    static func plain(_ family: LiveAircraftFamily) -> LiveAircraftLivery {
        switch family {
        case .lightSingle: LiveAircraftLivery(body: 0xFFF8EA, wing: 0xFFF8EA, tail: 0xC8553D, accent: 0xC8553D)
        case .lightTwin: LiveAircraftLivery(body: 0xFFF8EA, wing: 0xFFF8EA, tail: 0x3F7FB3, accent: 0x3F7FB3)
        case .helicopter: LiveAircraftLivery(body: 0xD9A92E, wing: 0xA8B0B6, tail: 0xD9A92E, accent: 0x4A2E1C)
        case .fighter: LiveAircraftLivery(body: 0x8E979D, wing: 0x7A8389, tail: 0x8E979D, accent: 0x5E676D)
        case .bizjet: LiveAircraftLivery(body: 0xF6F1E4, wing: 0xD2C8B2, tail: 0x5E844D, accent: 0xA39B88)
        case .turboprop: LiveAircraftLivery(body: 0xF6F1E4, wing: 0xD2C8B2, tail: 0x6FA8D0, accent: 0xA39B88)
        case .narrowbody, .widebody, .jumbo, .regionalJet:
            LiveAircraftLivery(body: 0xF6F1E4, wing: 0xD2C8B2, tail: 0xA39B88, accent: 0xA39B88)
        }
    }
}

/// One airline: its short name for the card and its colours.
nonisolated struct LiveAircraftAirline: Equatable, Sendable {
    /// The ICAO airline designator, the callsign's first three letters ("UAL").
    let code: String
    /// The name the card uses ("United"). Brand names, not translated.
    let name: String
    let livery: LiveAircraftLivery
}

/// The bundled table of airlines by ICAO designator, with an approximation of each one's colours (colours only, no
/// logos), and the callsign reading that uses it. Pure data.
///
/// Regional carriers that fly for several mainline brands (SkyWest, Republic and the like) keep a neutral scheme: the
/// callsign doesn't say whose colours the plane wears that day.
nonisolated enum LiveAircraftAirlines {
    /// The most rows the table is read to.
    static let maxRows = 300

    /// `code|name|body|tail|accent` rows, colours as hex.
    static let rows = """
    AAL|American|C9CDD2|0078D2|C30019
    UAL|United|F4F5F7|005DAA|0C2340
    DAL|Delta|F4F5F7|C01933|003366
    SWA|Southwest|304CB2|C8102E|FFBF27
    JBU|JetBlue|F4F5F7|003876|0099FF
    ASA|Alaska|F4F5F7|01426A|48A9C5
    QXE|Horizon|F4F5F7|01426A|48A9C5
    FFT|Frontier|F4F5F7|007A53|00843D
    NKS|Spirit|FFE600|FFE600|222222
    HAL|Hawaiian|F4F5F7|4B2A84|D3006F
    AAY|Allegiant|F4F5F7|0B5394|F7A800
    SCX|Sun Country|F4F5F7|F58025|1E3765
    MXY|Breeze|F4F5F7|0D2A4A|5DB4E5
    VXP|Avelo|F4F5F7|5C2D91|FFC400
    SKW|SkyWest|F4F5F7|8A9299|5E676D
    RPA|Republic|F4F5F7|8A9299|5E676D
    ENY|Envoy|C9CDD2|0078D2|C30019
    PDT|Piedmont|C9CDD2|0078D2|C30019
    JIA|PSA|C9CDD2|0078D2|C30019
    EDV|Endeavor|F4F5F7|C01933|003366
    ASH|Mesa|F4F5F7|005DAA|0C2340
    GJS|GoJet|F4F5F7|005DAA|0C2340
    CPZ|Compass|F4F5F7|8A9299|5E676D
    FDX|FedEx|F4F5F7|4D148C|FF6600
    UPS|UPS|F4F5F7|5E3A1E|FFB500
    GTI|Atlas Air|F4F5F7|003A70|8A9299
    ABX|ABX Air|F4F5F7|0B3D91|C8102E
    ACA|Air Canada|F4F5F7|1A1A1A|D22630
    JZA|Jazz|F4F5F7|1A1A1A|D22630
    WJA|WestJet|F4F5F7|00A3AD|002E5D
    POE|Porter|F4F5F7|0A2240|8A9299
    TSC|Air Transat|F4F5F7|00A3E0|0B2343
    AMX|Aeroméxico|F4F5F7|0B2343|8A9299
    VOI|Volaris|F4F5F7|7B2A90|8BC43F
    VIV|Viva Aerobus|F4F5F7|00A650|F4F5F7
    BAW|British Airways|F4F5F7|0B1F4A|C8102E
    VIR|Virgin Atlantic|F4F5F7|DA0530|4F2683
    EZY|easyJet|F4F5F7|FF6600|FF6600
    RYR|Ryanair|F4F5F7|073590|F1C933
    DLH|Lufthansa|F4F5F7|05164D|FFAD00
    AFR|Air France|F4F5F7|002157|ED1C24
    KLM|KLM|00A1DE|00A1DE|003145
    IBE|Iberia|F4F5F7|D7192D|FFCC00
    VLG|Vueling|F4F5F7|FFCC00|5E676D
    SAS|SAS|F4F5F7|0B1560|8A9299
    FIN|Finnair|F4F5F7|0B1560|F4F5F7
    SWR|Swiss|F4F5F7|E3000F|F4F5F7
    AUA|Austrian|F4F5F7|D81E05|F4F5F7
    TAP|TAP Air Portugal|F4F5F7|00A651|ED1C24
    AEE|Aegean|F4F5F7|003B79|8A9299
    THY|Turkish Airlines|F4F5F7|C70A0C|8A9299
    EIN|Aer Lingus|F4F5F7|00877A|6FBE44
    ITY|ITA Airways|F4F5F7|0057A8|8A9299
    WZZ|Wizz Air|F4F5F7|C6007E|25205B
    NAX|Norwegian|F4F5F7|D81939|8A9299
    ICE|Icelandair|F4F5F7|003A79|FFB71B
    LOT|LOT|F4F5F7|11397E|8A9299
    EWG|Eurowings|F4F5F7|A3195B|8A9299
    CFG|Condor|F4F5F7|FFC72C|8A9299
    TOM|TUI|F4F5F7|6CC4EE|E2001A
    UAE|Emirates|F4F5F7|D71921|C5A35A
    QTR|Qatar Airways|F4F5F7|5C0632|8A9299
    ETD|Etihad|F4F5F7|BD8B13|8A9299
    SVA|Saudia|F4F5F7|003F70|BD8B13
    ELY|El Al|F4F5F7|0A2D6E|8A9299
    FDB|flydubai|F4F5F7|F26822|003B70
    SIA|Singapore Airlines|F4F5F7|0B1A47|F2A900
    CPA|Cathay Pacific|F4F5F7|006564|8A9299
    JAL|Japan Airlines|F4F5F7|CC0000|8A9299
    ANA|ANA|F4F5F7|13448F|00A0E9
    KAL|Korean Air|8EC3E8|8EC3E8|00256C
    AAR|Asiana|F4F5F7|9D8C67|8A9299
    CCA|Air China|F4F5F7|E60012|8A9299
    CES|China Eastern|F4F5F7|C8161D|003A84
    CSN|China Southern|F4F5F7|0A6FB8|E60012
    EVA|EVA Air|F4F5F7|00664F|F68B1F
    CAL|China Airlines|F4F5F7|E5729C|003C78
    QFA|Qantas|F4F5F7|E40000|8A9299
    ANZ|Air New Zealand|F4F5F7|111111|8A9299
    VOZ|Virgin Australia|F4F5F7|CC0033|8A9299
    AIC|Air India|F4F5F7|DA0E29|BD8B13
    IGO|IndiGo|F4F5F7|001B94|8A9299
    THA|Thai|F4F5F7|5B2C83|BD8B13
    MAS|Malaysia Airlines|F4F5F7|003F87|D8232A
    GIA|Garuda Indonesia|F4F5F7|00B2C2|8A9299
    PAL|Philippine Airlines|F4F5F7|003366|D8232A
    VJC|VietJet|F4F5F7|E31E24|FFD400
    HVN|Vietnam Airlines|F4F5F7|006A80|BD8B13
    AXM|AirAsia|F4F5F7|E31B23|8A9299
    LAN|LATAM|F4F5F7|1B0088|ED1650
    TAM|LATAM|F4F5F7|1B0088|ED1650
    GLO|Gol|F4F5F7|FF6E00|8A9299
    AZU|Azul|F4F5F7|003D87|8A9299
    AVA|Avianca|F4F5F7|DA291C|8A9299
    CMP|Copa|F4F5F7|1A3668|BD8B13
    ARG|Aerolíneas Argentinas|F4F5F7|5BA4D9|8A9299
    ETH|Ethiopian|F4F5F7|3E9A3E|F8D20F
    SAA|South African|F4F5F7|00824A|8A9299
    KQA|Kenya Airways|F4F5F7|D21034|8A9299
    RAM|Royal Air Maroc|F4F5F7|C1272D|8A9299
    MSR|EgyptAir|F4F5F7|00205B|BD8B13
    CLX|Cargolux|F4F5F7|003C7D|D8232A
    DHK|DHL|FFCC00|FFCC00|D40511
    BCS|DHL|FFCC00|FFCC00|D40511
    """

    /// The table, read once.
    static let byCode: [String: LiveAircraftAirline] = {
        var table: [String: LiveAircraftAirline] = [:]
        // Bounded: at most `maxRows` rows.
        for line in rows.split(separator: "\n").prefix(maxRows) {
            let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 5, let body = UInt32(parts[2], radix: 16), let tail = UInt32(parts[3], radix: 16),
                  let accent = UInt32(parts[4], radix: 16) else { continue }
            table[parts[0]] = LiveAircraftAirline(code: parts[0], name: parts[1],
                                                  livery: .airline(body: body, tail: tail, accent: accent))
        }
        return table
    }()

    /// The airline flying `callsign` and its flight number ("UAL1704" → United, "1704"), or nil when the callsign
    /// isn't three letters then a number, or the letters aren't in the table.
    static func flight(_ callsign: String?) -> (airline: LiveAircraftAirline, number: String)? {
        guard let callsign, let parts = split(callsign), let airline = byCode[parts.code] else { return nil }
        return (airline, parts.number)
    }

    /// A callsign's three-letter designator and its flight part, when it has that shape: three letters, then a digit,
    /// then at most four more letters or digits.
    static func split(_ callsign: String) -> (code: String, number: String)? {
        let characters = Array(callsign.uppercased())
        guard (4...8).contains(characters.count),
              characters.prefix(3).allSatisfy({ ("A"..."Z").contains($0) }),
              ("0"..."9").contains(characters[3]),
              characters.dropFirst(3).allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) }) else { return nil }
        return (String(characters.prefix(3)), String(characters.dropFirst(3)))
    }
}
