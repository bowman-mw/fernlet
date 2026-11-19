import Foundation

/// The pixel design a live plane is drawn with (owner 2026-11-19, call 5: "each type of plane gets a different
/// design"). One per family of aircraft, so the sky reads at a glance without a design per model.
nonisolated enum LiveAircraftFamily: String, CaseIterable, Sendable {
    /// Two-engine single-aisle jets (737, A320, 757).
    case narrowbody
    /// Two-engine twin-aisle jets (787, 777, A330, A350, 767).
    case widebody
    /// Four-engine jets (747, A380, A340, C-17).
    case jumbo
    /// Regional jets with engines at the tail or small wings (CRJ, ERJ, E-Jets).
    case regionalJet
    /// Business jets (Citation, Gulfstream, Learjet).
    case bizjet
    /// Turboprop airliners and utility planes (ATR, Dash 8, King Air, Caravan).
    case turboprop
    /// Light single-engine planes (Cessna 172, Piper, Cirrus).
    case lightSingle
    /// Light twin piston planes (Baron, Seneca, DA42).
    case lightTwin
    /// Helicopters.
    case helicopter
    /// Fast military jets (F-16, F/A-18, T-38).
    case fighter

    /// The family an unlisted type falls back to, from its ADS-B emitter category (A1 light … A7 rotorcraft).
    static func fallback(category: String?) -> LiveAircraftFamily {
        switch category {
        case "A1", "B1", "B4": .lightSingle
        case "A2": .bizjet
        case "A4": .narrowbody
        case "A5": .widebody
        case "A6": .fighter
        case "A7": .helicopter
        default: .narrowbody
        }
    }
}

/// One aircraft type: its family and its name in words.
nonisolated struct LiveAircraftType: Equatable, Sendable {
    /// The ICAO type designator ("B738").
    let code: String
    /// The type in words ("Boeing 737-800"). Maker and model names, not translated.
    let name: String
    let family: LiveAircraftFamily
}

/// The bundled table of common ICAO type designators (ICAO Doc 8643 codes as the feed sends them), for the card's
/// "type in words" and each plane's design. Unlisted codes fall back to the emitter category; the card then shows the
/// code itself. Pure data.
nonisolated enum LiveAircraftTypes {
    /// The most rows the table is read to.
    static let maxRows = 400

    /// `code|name|family` rows.
    static let rows = """
    B712|Boeing 717|narrowbody
    B732|Boeing 737-200|narrowbody
    B733|Boeing 737-300|narrowbody
    B734|Boeing 737-400|narrowbody
    B735|Boeing 737-500|narrowbody
    B736|Boeing 737-600|narrowbody
    B737|Boeing 737-700|narrowbody
    B738|Boeing 737-800|narrowbody
    B739|Boeing 737-900|narrowbody
    B37M|Boeing 737 MAX 7|narrowbody
    B38M|Boeing 737 MAX 8|narrowbody
    B39M|Boeing 737 MAX 9|narrowbody
    B3XM|Boeing 737 MAX 10|narrowbody
    B752|Boeing 757-200|narrowbody
    B753|Boeing 757-300|narrowbody
    A318|Airbus A318|narrowbody
    A319|Airbus A319|narrowbody
    A320|Airbus A320|narrowbody
    A321|Airbus A321|narrowbody
    A19N|Airbus A319neo|narrowbody
    A20N|Airbus A320neo|narrowbody
    A21N|Airbus A321neo|narrowbody
    BCS1|Airbus A220-100|narrowbody
    BCS3|Airbus A220-300|narrowbody
    MD82|McDonnell Douglas MD-82|regionalJet
    MD83|McDonnell Douglas MD-83|regionalJet
    MD88|McDonnell Douglas MD-88|regionalJet
    MD90|McDonnell Douglas MD-90|regionalJet
    C919|COMAC C919|narrowbody
    B762|Boeing 767-200|widebody
    B763|Boeing 767-300|widebody
    B764|Boeing 767-400|widebody
    B772|Boeing 777-200|widebody
    B77L|Boeing 777-200LR|widebody
    B773|Boeing 777-300|widebody
    B77W|Boeing 777-300ER|widebody
    B778|Boeing 777-8|widebody
    B779|Boeing 777-9|widebody
    B788|Boeing 787-8 Dreamliner|widebody
    B789|Boeing 787-9 Dreamliner|widebody
    B78X|Boeing 787-10 Dreamliner|widebody
    A306|Airbus A300-600|widebody
    A310|Airbus A310|widebody
    A332|Airbus A330-200|widebody
    A333|Airbus A330-300|widebody
    A338|Airbus A330-800neo|widebody
    A339|Airbus A330-900neo|widebody
    A359|Airbus A350-900|widebody
    A35K|Airbus A350-1000|widebody
    MD11|McDonnell Douglas MD-11|widebody
    DC10|McDonnell Douglas DC-10|widebody
    KC46|Boeing KC-46 Pegasus|widebody
    B744|Boeing 747-400|jumbo
    B748|Boeing 747-8|jumbo
    A388|Airbus A380|jumbo
    A342|Airbus A340-200|jumbo
    A343|Airbus A340-300|jumbo
    A345|Airbus A340-500|jumbo
    A346|Airbus A340-600|jumbo
    A124|Antonov An-124|jumbo
    C17|Boeing C-17 Globemaster III|jumbo
    C5M|Lockheed C-5 Galaxy|jumbo
    K35R|Boeing KC-135 Stratotanker|jumbo
    E3TF|Boeing E-3 Sentry|jumbo
    B52|Boeing B-52 Stratofortress|jumbo
    CRJ1|Bombardier CRJ100|regionalJet
    CRJ2|Bombardier CRJ200|regionalJet
    CRJ7|Bombardier CRJ700|regionalJet
    CRJ9|Bombardier CRJ900|regionalJet
    CRJX|Bombardier CRJ1000|regionalJet
    E135|Embraer ERJ 135|regionalJet
    E145|Embraer ERJ 145|regionalJet
    E170|Embraer 170|regionalJet
    E75S|Embraer 175|regionalJet
    E75L|Embraer 175|regionalJet
    E190|Embraer 190|regionalJet
    E195|Embraer 195|regionalJet
    E290|Embraer 190-E2|regionalJet
    E295|Embraer 195-E2|regionalJet
    SU95|Sukhoi Superjet 100|regionalJet
    F100|Fokker 100|regionalJet
    AT43|ATR 42-300|turboprop
    AT45|ATR 42-500|turboprop
    AT46|ATR 42-600|turboprop
    AT72|ATR 72|turboprop
    AT75|ATR 72-500|turboprop
    AT76|ATR 72-600|turboprop
    DH8A|De Havilland Dash 8-100|turboprop
    DH8B|De Havilland Dash 8-200|turboprop
    DH8C|De Havilland Dash 8-300|turboprop
    DH8D|De Havilland Dash 8-400|turboprop
    DHC6|De Havilland Twin Otter|turboprop
    SF34|Saab 340|turboprop
    JS41|BAe Jetstream 41|turboprop
    B190|Beechcraft 1900|turboprop
    BE99|Beechcraft 99|turboprop
    BE9L|Beechcraft King Air 90|turboprop
    BE20|Beechcraft King Air 200|turboprop
    BE30|Beechcraft King Air 300|turboprop
    B350|Beechcraft King Air 350|turboprop
    PC12|Pilatus PC-12|turboprop
    C208|Cessna 208 Caravan|turboprop
    TBM7|Daher TBM 700|turboprop
    TBM8|Daher TBM 850|turboprop
    TBM9|Daher TBM 900|turboprop
    P180|Piaggio P.180 Avanti|turboprop
    PAY3|Piper Cheyenne III|turboprop
    SW4|Fairchild Metro|turboprop
    C130|Lockheed C-130 Hercules|turboprop
    C30J|Lockheed C-130J Super Hercules|turboprop
    AT8T|Air Tractor AT-802|turboprop
    C25A|Cessna Citation CJ2|bizjet
    C25B|Cessna Citation CJ3|bizjet
    C25C|Cessna Citation CJ4|bizjet
    C510|Cessna Citation Mustang|bizjet
    C525|Cessna CitationJet|bizjet
    C550|Cessna Citation II|bizjet
    C560|Cessna Citation V|bizjet
    C56X|Cessna Citation Excel|bizjet
    C680|Cessna Citation Sovereign|bizjet
    C68A|Cessna Citation Latitude|bizjet
    C700|Cessna Citation Longitude|bizjet
    C750|Cessna Citation X|bizjet
    CL30|Bombardier Challenger 300|bizjet
    CL35|Bombardier Challenger 350|bizjet
    CL60|Bombardier Challenger 600|bizjet
    GL5T|Bombardier Global 5000|bizjet
    GLEX|Bombardier Global Express|bizjet
    GL7T|Bombardier Global 7500|bizjet
    GLF4|Gulfstream IV|bizjet
    GLF5|Gulfstream V|bizjet
    GLF6|Gulfstream G650|bizjet
    GA6C|Gulfstream G600|bizjet
    G280|Gulfstream G280|bizjet
    LJ35|Learjet 35|bizjet
    LJ45|Learjet 45|bizjet
    LJ60|Learjet 60|bizjet
    LJ75|Learjet 75|bizjet
    E50P|Embraer Phenom 100|bizjet
    E55P|Embraer Phenom 300|bizjet
    E545|Embraer Legacy 450|bizjet
    E550|Embraer Praetor 600|bizjet
    E35L|Embraer Legacy 600|bizjet
    F2TH|Dassault Falcon 2000|bizjet
    F900|Dassault Falcon 900|bizjet
    FA7X|Dassault Falcon 7X|bizjet
    FA8X|Dassault Falcon 8X|bizjet
    HDJT|HondaJet|bizjet
    PC24|Pilatus PC-24|bizjet
    SF50|Cirrus Vision Jet|bizjet
    BE40|Beechcraft Beechjet 400|bizjet
    H25B|Hawker 800|bizjet
    C150|Cessna 150|lightSingle
    C152|Cessna 152|lightSingle
    C162|Cessna Skycatcher|lightSingle
    C170|Cessna 170|lightSingle
    C172|Cessna 172 Skyhawk|lightSingle
    C177|Cessna Cardinal|lightSingle
    C180|Cessna 180|lightSingle
    C182|Cessna 182 Skylane|lightSingle
    C206|Cessna 206 Stationair|lightSingle
    C210|Cessna 210 Centurion|lightSingle
    P28A|Piper Cherokee|lightSingle
    P28B|Piper Cherokee Six|lightSingle
    P28R|Piper Arrow|lightSingle
    PA32|Piper Saratoga|lightSingle
    PA46|Piper Malibu|lightSingle
    PA18|Piper Super Cub|lightSingle
    J3|Piper Cub|lightSingle
    SR20|Cirrus SR20|lightSingle
    SR22|Cirrus SR22|lightSingle
    S22T|Cirrus SR22T|lightSingle
    DA20|Diamond DA20|lightSingle
    DA40|Diamond DA40|lightSingle
    BE33|Beechcraft Debonair|lightSingle
    BE35|Beechcraft Bonanza|lightSingle
    BE36|Beechcraft Bonanza|lightSingle
    M20P|Mooney M20|lightSingle
    M20T|Mooney M20 Turbo|lightSingle
    RV7|Van's RV-7|lightSingle
    RV8|Van's RV-8|lightSingle
    RV10|Van's RV-10|lightSingle
    GLID|Glider|lightSingle
    PA44|Piper Seminole|lightTwin
    PA34|Piper Seneca|lightTwin
    PA31|Piper Navajo|lightTwin
    PA23|Piper Aztec|lightTwin
    BE55|Beechcraft Baron 55|lightTwin
    BE58|Beechcraft Baron 58|lightTwin
    BE76|Beechcraft Duchess|lightTwin
    BE65|Beechcraft Queen Air|lightTwin
    DA42|Diamond DA42|lightTwin
    DA62|Diamond DA62|lightTwin
    C310|Cessna 310|lightTwin
    C340|Cessna 340|lightTwin
    C414|Cessna 414|lightTwin
    C421|Cessna 421|lightTwin
    R22|Robinson R22|helicopter
    R44|Robinson R44|helicopter
    R66|Robinson R66|helicopter
    B06|Bell 206 JetRanger|helicopter
    B407|Bell 407|helicopter
    B429|Bell 429|helicopter
    B412|Bell 412|helicopter
    B505|Bell 505|helicopter
    EC20|Airbus H120|helicopter
    EC30|Airbus H130|helicopter
    EC35|Airbus H135|helicopter
    EC45|Airbus H145|helicopter
    AS50|Airbus AS350|helicopter
    AS65|Airbus Dauphin|helicopter
    A109|Leonardo AW109|helicopter
    A119|Leonardo AW119|helicopter
    A139|Leonardo AW139|helicopter
    S76|Sikorsky S-76|helicopter
    S92|Sikorsky S-92|helicopter
    H60|Sikorsky Black Hawk|helicopter
    H47|Boeing Chinook|helicopter
    MD52|MD 520N|helicopter
    F16|Lockheed Martin F-16|fighter
    F15|Boeing F-15|fighter
    F18|Boeing F/A-18 Hornet|fighter
    F18S|Boeing F/A-18 Super Hornet|fighter
    F35|Lockheed Martin F-35|fighter
    F22|Lockheed Martin F-22|fighter
    T38|Northrop T-38 Talon|fighter
    A10|Fairchild A-10|fighter
    EUFI|Eurofighter Typhoon|fighter
    HAWK|BAE Hawk|fighter
    """

    /// The table, read once.
    static let byCode: [String: LiveAircraftType] = {
        var table: [String: LiveAircraftType] = [:]
        // Bounded: at most `maxRows` rows.
        for line in rows.split(separator: "\n").prefix(maxRows) {
            let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3, let family = LiveAircraftFamily(rawValue: parts[2]) else { continue }
            table[parts[0]] = LiveAircraftType(code: parts[0], name: parts[1], family: family)
        }
        return table
    }()

    /// The listed type for `code`, or nil.
    static func type(_ code: String?) -> LiveAircraftType? {
        guard let code else { return nil }
        return byCode[code.uppercased()]
    }

    /// The family `code` is drawn as, falling back to the emitter `category`.
    static func family(code: String?, category: String?) -> LiveAircraftFamily {
        type(code)?.family ?? .fallback(category: category)
    }

    // MARK: Names a flight record wrote

    /// Other ways flight logs write a listed type, `name|code` (Flighty writes "Embraer E175" for the 175).
    static let aliasRows = """
    Embraer E170|E170
    Embraer E175|E75L
    Embraer E175|E75S
    Embraer E190|E190
    Embraer E195|E195
    Boeing 737-8 MAX|B38M
    Boeing 737-9 MAX|B39M
    Boeing 737-7 MAX|B37M
    Airbus A220-100|BCS1
    Airbus A220-300|BCS3
    De Havilland Canada Dash 8-400|DH8D
    Bombardier Q400|DH8D
    """

    /// Every listed code under each written form of its name: the whole name and the name less its leading words
    /// ("Boeing 737-800", "737-800"), squeezed by ``squeezed(_:)``.
    static let codesByName: [String: Set<String>] = {
        var index: [String: Set<String>] = [:]
        func add(_ name: String, _ code: String) {
            let words = name.split(separator: " ").map(String.init)
            // Bounded: at most the name's words (types run to five).
            for start in words.indices.prefix(6) {
                let key = squeezed(words[start...].joined(separator: " "))
                if key.count >= 3 { index[key, default: []].insert(code) }
            }
        }
        // Bounded: the table's rows.
        for type in byCode.values { add(type.name, type.code) }
        // Bounded: at most `maxRows` alias rows.
        for line in aliasRows.split(separator: "\n").prefix(maxRows) {
            let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { add(parts[0], parts[1]) }
        }
        return index
    }()

    /// `name` lowercased with only its letters and digits, less "Dreamliner" ("Boeing 787-9 Dreamliner" → "boeing7879").
    static func squeezed(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "dreamliner", with: "").filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The ICAO codes a flight record's type `name` names: a code written as itself, or a listed name in any of its
    /// written forms. Empty when it names nothing listed.
    static func codes(forName name: String?) -> Set<String> {
        guard let name, !name.isEmpty, name.count <= 64 else { return [] }
        if let listed = byCode[name.uppercased()] { return [listed.code] }
        return codesByName[squeezed(name)] ?? []
    }
}
