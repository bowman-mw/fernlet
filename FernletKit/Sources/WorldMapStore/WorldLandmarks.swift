import Foundation

// The World's landmarks (round 7, World-Exploration-Spec §2 "Landmarks"; Docs/World-Atlas-Pack.md, "Landmarks").
// A hand-written list bundled beside the atlas pack (`WorldLandmarks.json`), never imported from OpenStreetMap and
// never fetched. Every token and JSON key here is English and frozen; the names in the file are data, so this
// module still holds no display strings.

/// The generic icon of a landmark with no art of its own (a frozen token; the six the spec names).
public nonisolated enum AtlasLandmarkKind: String, CaseIterable, Codable, Sendable {
    case park, bridge, lighthouse, stadium, castle, tower
}

/// Which of the two tiers a landmark is in (owner, World-Exploration-Spec §2).
public nonisolated enum AtlasLandmarkTier: Hashable, Sendable {
    /// A famous landmark drawn with its own big pixel art, named by its frozen art id
    /// (one of ``WorldLandmarks/famousArtIDs``).
    case famous(artID: String)
    /// Every other landmark: one of the generic icons.
    case generic(AtlasLandmarkKind)

    /// The art the map draws now: a drawn famous id, else the generic icon (a placeholder's stand-in).
    public var drawable: AtlasLandmarkTier {
        guard case .famous(let artID) = self, let stand = WorldLandmarks.placeholderArtIDs[artID] else { return self }
        return .generic(stand)
    }
}

/// One landmark from the hand-written list. Before it is found the map draws it grey and unnamed through the
/// fog; once an accepted fix comes within ``findRadiusMetres`` of ``point`` it is found, and the passport keeps
/// it (by ``token``) with its city (``cityToken``).
public nonisolated struct AtlasLandmark: Hashable, Sendable {
    /// The frozen token, lowerCamel ASCII ("eiffelTower"): what the passport stores.
    public let token: String
    /// The English name (data from the list, shown only once found).
    public let englishName: String
    /// The Spanish name: the usual Spanish one, else the English one.
    public let spanishName: String
    /// The frozen atlas token of its city (``AtlasCity/token``, the city's Wikidata ID in the shipped pack).
    public let cityToken: String
    /// Where it stands (the point a fix is measured from).
    public let point: GeoPoint
    /// How near an accepted fix must come to find it, in metres (``WorldLandmarks/radiusRange``).
    public let findRadiusMetres: Double
    /// Its tier: its own art or a generic icon.
    public let tier: AtlasLandmarkTier

    /// A landmark with every field given (``WorldLandmarks/init(landmarks:)`` checks them).
    public init(token: String, englishName: String, spanishName: String, cityToken: String, point: GeoPoint,
                findRadiusMetres: Double, tier: AtlasLandmarkTier) {
        self.token = token
        self.englishName = englishName
        self.spanishName = spanishName
        self.cityToken = cityToken
        self.point = point
        self.findRadiusMetres = findRadiusMetres
        self.tier = tier
    }

    /// Whether a fix at `fix` finds it: the fix is valid and within ``findRadiusMetres`` of ``point``
    /// (the flat-earth distance, measured the short way round the antimeridian).
    public func isFound(by fix: GeoPoint) -> Bool {
        guard fix.isValid, point.isValid, findRadiusMetres.isFinite else { return false }
        guard abs(fix.latitude - point.latitude) * GeoPoint.metresPerDegree <= findRadiusMetres else { return false }
        return WorldAtlas.separation(fix, point) <= findRadiusMetres
    }

    /// Whether `token` may be a landmark's token: 1 to ``PassportBook/maxTokenBytes`` bytes of lowerCamel
    /// ASCII (a lowercase letter, then letters and digits).
    public static func isValidToken(_ token: String) -> Bool {
        guard let first = token.utf8.first, token.utf8.count <= PassportBook.maxTokenBytes else { return false }
        guard (0x61...0x7A).contains(first) else { return false }
        return token.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
        }
    }
}

/// The bundled landmark list, read and checked (World-Exploration-Spec §2; Docs/World-Atlas-Pack.md,
/// "Landmarks"). Immutable and `Sendable`. Every query is bounded: one pass over at most ``maxLandmarks``
/// entries, or a dictionary lookup.
///
/// **The file** (`WorldLandmarks.json`, beside the pack; frozen keys): `{"version": 1, "landmarks": [...]}`,
/// each entry `id`, `en`, `es`, `city`, `lat`, `lon`, `radius` and exactly one of `art` (famous) or `kind`
/// (generic). A file over ``maxFileBytes``, a version this build does not read, more than ``maxLandmarks``
/// entries, an unknown key, or any entry that breaks a rule is refused whole, never half read.
public nonisolated struct WorldLandmarks: Sendable {
    /// The file format version this build reads.
    public static let currentVersion = 1
    /// The most landmarks a list may hold.
    public static let maxLandmarks = 5_000
    /// The largest file read (5,000 entries are about 1 MB).
    public static let maxFileBytes = 2 * 1_024 * 1_024
    /// The longest name kept, in UTF-8 bytes.
    public static let maxNameBytes = 120
    /// A find radius's allowed range, in metres: a tower about 150, a big park 250 to 400 from its centre.
    public static let radiusRange: ClosedRange<Double> = 50...600
    /// The famous tier's drawn and approved art ids (Eiffel Tower, Empire State Building, Sydney Opera House,
    /// and the Colosseum, approved 2026-10-29).
    public static let drawnArtIDs: Set<String> = ["eiffel", "empire", "opera", "colosseum"]
    /// Famous art ids not drawn and approved yet, each with the generic icon the map uses meanwhile: the owner's
    /// 24 more famous landmarks (2026-10-29, "all 24 of those"). When an id's art is approved it moves to
    /// ``drawnArtIDs``; its token never changes.
    public static let placeholderArtIDs: [String: AtlasLandmarkKind] = [
        "bigben": .tower, "goldengate": .bridge, "pisa": .tower, "burjkhalifa": .tower, "spaceneedle": .tower,
        "liberty": .tower, "tajmahal": .castle, "greatwall": .castle, "redeemer": .tower, "pyramids": .castle,
        "sagrada": .tower, "acropolis": .castle,
        "towerbridge": .bridge, "harbourbridge": .bridge, "cntower": .tower, "skytree": .tower, "stbasils": .castle,
        "brandenburg": .castle, "petronas": .tower, "machupicchu": .castle, "chichenitza": .castle, "petra": .castle,
        "angkorwat": .castle, "hollywood": .park,
    ]
    /// Every famous art id a list may name: the drawn ones and the placeholders.
    public static var famousArtIDs: Set<String> { drawnArtIDs.union(placeholderArtIDs.keys) }
    /// The widest search ``landmarks(near:withinMetres:)`` answers, in metres (the flat-earth distance is
    /// good to well under a percent at this range).
    public static let maxSearchMetres = 50_000.0
    /// The most landmarks ``landmarks(near:withinMetres:)`` returns (the nearest kept).
    public static let maxNearbyResults = 500

    /// Why a landmark file or list was refused. Each case after ``overCap`` names the offending entry's id.
    public enum LandmarkError: Error, Equatable {
        /// The file is larger than ``maxFileBytes``.
        case tooLarge
        /// The bytes are not a landmark file (bad JSON, a missing field, a wrong type).
        case malformed
        /// A file format version this build does not read.
        case unsupportedVersion(Int)
        /// More than ``maxLandmarks`` entries.
        case overCap
        /// A key the format does not have (a typo is refused, never ignored).
        case unknownKey(String)
        /// An id that is not lowerCamel ASCII of at most 64 bytes.
        case badToken(String)
        /// An id used twice.
        case duplicateToken(String)
        /// An empty, overlong or control-character name.
        case badName(String)
        /// A city token that is not an atlas token.
        case badCity(String)
        /// A point off the globe.
        case badPoint(String)
        /// A find radius outside ``radiusRange``.
        case badRadius(String)
        /// Both `art` and `kind`, neither, an art id not in ``famousArtIDs``, or an unknown kind.
        case badTier(String)
    }

    /// An empty list (no file, or a refused one: the atlas still works, nothing is found).
    public static let empty = WorldLandmarks(checked: [])

    /// Every landmark, in the file's order (the map draws the unfound ones grey through the fog).
    public let all: [AtlasLandmark]
    /// Each city token's landmarks, as indices into ``all`` in file order.
    private let byCity: [String: [Int]]
    /// Each token's index into ``all``.
    private let byToken: [String: Int]

    /// Whether the list holds no landmark.
    public var isEmpty: Bool { all.isEmpty }

    /// The list in `data` (a whole `WorldLandmarks.json`), or the ``LandmarkError`` that refuses it.
    public init(data: Data) throws {
        guard data.count <= Self.maxFileBytes else { throw LandmarkError.tooLarge }
        let file: LandmarkFile
        do {
            file = try JSONDecoder().decode(LandmarkFile.self, from: data)
        } catch let error as LandmarkError {
            throw error
        } catch {
            throw LandmarkError.malformed
        }
        try self.init(landmarks: file.landmarks)
    }

    /// The list `landmarks`, every entry checked (token, names, city, point, radius, tier; no token twice),
    /// or the first ``LandmarkError`` found.
    public init(landmarks: [AtlasLandmark]) throws {
        guard landmarks.count <= Self.maxLandmarks else { throw LandmarkError.overCap }
        var seen = Set<String>()
        // Bounded: one pass over at most maxLandmarks entries.
        for landmark in landmarks {
            if let problem = Self.problem(with: landmark) { throw problem }
            guard seen.insert(landmark.token).inserted else { throw LandmarkError.duplicateToken(landmark.token) }
        }
        self.init(checked: landmarks)
    }

    /// A list already checked: builds the city and token indices in one pass.
    private init(checked: [AtlasLandmark]) {
        var cities: [String: [Int]] = [:], tokens: [String: Int] = [:]
        // Bounded: one pass over at most maxLandmarks entries.
        for (index, landmark) in checked.enumerated().prefix(Self.maxLandmarks) {
            cities[landmark.cityToken, default: []].append(index)
            tokens[landmark.token] = index
        }
        all = checked
        byCity = cities
        byToken = tokens
    }

    // MARK: Queries

    /// The landmark whose token is `token`, or nil.
    public func landmark(token: String) -> AtlasLandmark? {
        guard let index = byToken[token], all.indices.contains(index) else { return nil }
        return all[index]
    }

    /// The landmarks of the city whose atlas token is `cityToken`, in file order (the city card's list).
    public func landmarks(inCity cityToken: String) -> [AtlasLandmark] {
        guard let indices = byCity[cityToken] else { return [] }
        return indices.prefix(Self.maxLandmarks).compactMap { all.indices.contains($0) ? all[$0] : nil }
    }

    /// The landmarks within `metres` of `point`, nearest first (ties by token), at most ``maxNearbyResults``.
    /// Nothing for an invalid point or a distance that is not positive; one wider than ``maxSearchMetres``
    /// searches ``maxSearchMetres``.
    public func landmarks(near point: GeoPoint, withinMetres metres: Double) -> [AtlasLandmark] {
        guard point.isValid, metres.isFinite, metres > 0 else { return [] }
        let reach = min(metres, Self.maxSearchMetres)
        var hits: [(landmark: AtlasLandmark, metres: Double)] = []
        // Bounded: one pass over at most maxLandmarks entries.
        for landmark in all.prefix(Self.maxLandmarks) {
            guard abs(landmark.point.latitude - point.latitude) * GeoPoint.metresPerDegree <= reach else { continue }
            let distance = WorldAtlas.separation(point, landmark.point)
            if distance <= reach { hits.append((landmark, distance)) }
        }
        let ordered = hits.sorted { ($0.metres, $0.landmark.token) < ($1.metres, $1.landmark.token) }
        return ordered.prefix(Self.maxNearbyResults).map(\.landmark)
    }

    /// The landmarks an accepted fix at `fix` finds (it lies within each one's find radius), in file order,
    /// at most ``AtlasVisit/maxLandmarks``. Nothing for an invalid fix.
    public func found(at fix: GeoPoint) -> [AtlasLandmark] {
        guard fix.isValid else { return [] }
        var hits: [AtlasLandmark] = []
        // Bounded: one pass over at most maxLandmarks entries, stopping at AtlasVisit.maxLandmarks hits.
        for landmark in all.prefix(Self.maxLandmarks) where landmark.isFound(by: fix) {
            hits.append(landmark)
            guard hits.count < AtlasVisit.maxLandmarks else { break }
        }
        return hits
    }

    // MARK: Rules

    /// What is wrong with `landmark`, or nil when it may be kept.
    static func problem(with landmark: AtlasLandmark) -> LandmarkError? {
        let id = landmark.token
        guard AtlasLandmark.isValidToken(id) else { return .badToken(id) }
        guard isValidName(landmark.englishName), isValidName(landmark.spanishName) else { return .badName(id) }
        guard PassportBook.isValidToken(landmark.cityToken, of: .city) else { return .badCity(id) }
        guard landmark.point.isValid else { return .badPoint(id) }
        guard landmark.findRadiusMetres.isFinite, radiusRange.contains(landmark.findRadiusMetres) else {
            return .badRadius(id)
        }
        if case .famous(let artID) = landmark.tier, !famousArtIDs.contains(artID) { return .badTier(id) }
        return nil
    }

    /// Whether `name` may be shown: 1 to ``maxNameBytes`` bytes, no control characters, not only spaces.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maxNameBytes else { return false }
        guard !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        return !name.allSatisfy(\.isWhitespace)
    }
}

/// The landmark file as written: its version and its entries, read in one bounded pass.
nonisolated struct LandmarkFile: Decodable {
    /// The format version (``WorldLandmarks/currentVersion``).
    let version: Int
    /// The entries, in file order.
    let landmarks: [AtlasLandmark]

    /// Reads the version, then at most ``WorldLandmarks/maxLandmarks`` entries; refuses a file with more.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LandmarkKey.self)
        try LandmarkKey.refuseUnknown(in: container, allowed: ["version", "landmarks"])
        let version = try container.decode(Int.self, forKey: LandmarkKey("version"))
        guard version == WorldLandmarks.currentVersion else {
            throw WorldLandmarks.LandmarkError.unsupportedVersion(version)
        }
        var list = try container.nestedUnkeyedContainer(forKey: LandmarkKey("landmarks"))
        var read: [AtlasLandmark] = []
        // Bounded: at most maxLandmarks entries are read; one more is a refusal.
        for _ in 0..<WorldLandmarks.maxLandmarks where !list.isAtEnd {
            read.append(try list.decode(LandmarkEntry.self).landmark)
        }
        guard list.isAtEnd else { throw WorldLandmarks.LandmarkError.overCap }
        self.version = version
        self.landmarks = read
    }
}

/// One entry of the landmark file as written (frozen keys), turned into an ``AtlasLandmark``. The tier's
/// rule (exactly one of `art` or `kind`, a known kind) is applied here; the rest by ``WorldLandmarks``.
nonisolated struct LandmarkEntry: Decodable {
    /// Every key an entry may have.
    static let keys: Set<String> = ["id", "en", "es", "city", "lat", "lon", "radius", "art", "kind"]

    /// The entry as a landmark.
    let landmark: AtlasLandmark

    /// Reads one entry; a missing field or a wrong type is a decoding error (``WorldLandmarks/LandmarkError/malformed``).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LandmarkKey.self)
        try LandmarkKey.refuseUnknown(in: container, allowed: Self.keys)
        let id = try container.decode(String.self, forKey: LandmarkKey("id"))
        let art = try container.decodeIfPresent(String.self, forKey: LandmarkKey("art"))
        let kind = try container.decodeIfPresent(String.self, forKey: LandmarkKey("kind"))
        let tier: AtlasLandmarkTier
        switch (art, kind.map(AtlasLandmarkKind.init(rawValue:))) {
        case (let art?, nil): tier = .famous(artID: art)
        case (nil, let kind??): tier = .generic(kind)
        default: throw WorldLandmarks.LandmarkError.badTier(id)
        }
        let point = GeoPoint(try container.decode(Double.self, forKey: LandmarkKey("lat")),
                             try container.decode(Double.self, forKey: LandmarkKey("lon")))
        landmark = AtlasLandmark(token: id, englishName: try container.decode(String.self, forKey: LandmarkKey("en")),
                                 spanishName: try container.decode(String.self, forKey: LandmarkKey("es")),
                                 cityToken: try container.decode(String.self, forKey: LandmarkKey("city")),
                                 point: point,
                                 findRadiusMetres: try container.decode(Double.self, forKey: LandmarkKey("radius")),
                                 tier: tier)
    }
}

/// A coding key spelled by its string (the landmark file's frozen keys).
nonisolated struct LandmarkKey: CodingKey {
    /// The key as written.
    let stringValue: String
    /// Never an integer key.
    var intValue: Int? { nil }

    /// The key `string`.
    init(_ string: String) { stringValue = string }
    /// The key `stringValue`.
    init?(stringValue: String) { self.stringValue = stringValue }
    /// Integer keys are not used.
    init?(intValue: Int) { nil }

    /// Throws ``WorldLandmarks/LandmarkError/unknownKey(_:)`` for the first key of `container` not in `allowed`.
    static func refuseUnknown(in container: KeyedDecodingContainer<LandmarkKey>, allowed: Set<String>) throws {
        // Bounded: the container's keys (one JSON object's).
        guard let stray = container.allKeys.first(where: { !allowed.contains($0.stringValue) }) else { return }
        throw WorldLandmarks.LandmarkError.unknownKey(stray.stringValue)
    }
}

/// The atlas and the landmark list together: the visit the atlas makes of a fix, with
/// ``AtlasVisit/landmarks`` filled from the list (the landmarks the fix finds). What the app's
/// `WorldAtlasKeeper` reads fixes against when the bundled list opened.
public nonisolated struct AtlasWithLandmarks: AtlasVisitResolving {
    /// The atlas (the bundled pack, or a test's fake).
    public let atlas: any AtlasVisitResolving
    /// The landmark list.
    public let landmarks: WorldLandmarks

    /// The atlas `atlas` with the list `landmarks`.
    public init(atlas: any AtlasVisitResolving, landmarks: WorldLandmarks) {
        self.atlas = atlas
        self.landmarks = landmarks
    }

    /// The atlas's visit at `point`, with the tokens of the landmarks it finds (in file order). An invalid
    /// point finds none.
    public func visit(at point: GeoPoint) -> AtlasVisit {
        var visit = atlas.visit(at: point)
        guard point.isValid else { return visit }
        visit.landmarks = landmarks.found(at: point).map(\.token)
        return visit
    }

    /// The atlas's own water answer (landmarks never make water).
    public func isWater(at point: GeoPoint) -> Bool {
        atlas.isWater(at: point)
    }
}
