import Foundation

/// The World passport's contents (round 7, idea 4; owner 2026-10-29): every country or territory, continent,
/// ocean, sea, city, landmark and terrain class the person has been to, each by its frozen token
/// (``AtlasDiscovery/token``) with the date of the first visit. A value type with no display strings. A found
/// landmark is kept by its token alone; its city comes from the bundled list (``WorldLandmarks``), so the
/// city card counts it with ``foundLandmarkCount(inCity:of:)``.
///
/// **Versioned bytes.** ``encoded()`` and ``init(data:)`` are the one format, used both for the sealed file on
/// the iPhone (``PassportStore``) and for the passport's part of Fernlet's sealed iCloud backup: JSON with a
/// `version` field (``currentVersion``) and one object per kind, token to first date in seconds since 1970.
/// A version this build does not know, a kind over its cap, or a token that is not a token is refused whole.
/// Landmarks joined version 1 as one more kind key (`landmark`); a build from before them reads such a book
/// with that key left out.
///
/// **Bounded** (Power of 10): at most ``cap(for:)`` entries per kind (300 countries and territories,
/// 7 continents, 5 oceans, 250 seas, 20,000 cities, 5,000 landmarks, 20 terrain classes), tokens of at most
/// ``maxTokenBytes`` bytes, and at most ``maxEncodedBytes`` of encoding. Past a cap a new entry is refused and
/// counted (``refusedCount``), never an eviction of an earlier one.
public nonisolated struct PassportBook: Codable, Equatable, Sendable {
    /// The format version this build writes and reads.
    public static let currentVersion = 1
    /// The longest token kept, in UTF-8 bytes.
    public static let maxTokenBytes = 64
    /// The largest encoding read (a full book is about 1.2 MB).
    public static let maxEncodedBytes = 4 * 1_024 * 1_024
    /// The most first visits one visit can add: one of each kind but landmarks, plus up to
    /// ``AtlasVisit/maxLandmarks`` landmarks.
    public static let maxDiscoveriesPerVisit = AtlasDiscoveryKind.allCases.count - 1 + AtlasVisit.maxLandmarks

    /// Why bytes were refused as a passport.
    public enum BookError: Error, Equatable {
        /// The bytes are larger than any passport this build writes.
        case tooLarge
        /// The bytes are not a passport at all.
        case malformed
        /// A passport from a format version this build does not read.
        case unsupportedVersion(Int)
        /// More entries of a kind than its cap allows.
        case overCap(AtlasDiscoveryKind)
        /// An entry whose token is empty, too long, or not a token of its kind.
        case badToken(AtlasDiscoveryKind)
    }

    /// The format version of this book (always ``currentVersion`` once read).
    public let version: Int
    /// Token to first-visit date, by kind; a kind with no entries has no key.
    private var entries: [AtlasDiscoveryKind: [String: Date]]
    /// Entries refused because a cap was reached (an audit count; never encoded, never shown). A refusal
    /// inside a save that failed is counted again on the next try.
    public private(set) var refusedCount = 0

    /// An empty passport.
    public init() {
        version = Self.currentVersion
        entries = [:]
    }

    /// The most entries of `kind` a book keeps.
    public static func cap(for kind: AtlasDiscoveryKind) -> Int {
        switch kind {
        case .country: 300
        case .continent: 7
        case .ocean: 5
        case .sea: 250
        case .city: 20_000
        case .landmark: 5_000
        case .terrain: 20
        }
    }

    // MARK: Reading

    /// Whether nothing has been visited yet.
    public var isEmpty: Bool { entries.isEmpty }

    /// When `token` of `kind` was first visited, or nil when it hasn't been.
    public func firstVisit(_ kind: AtlasDiscoveryKind, token: String) -> Date? {
        entries[kind]?[token]
    }

    /// How many of `kind` have been visited.
    public func count(of kind: AtlasDiscoveryKind) -> Int {
        entries[kind]?.count ?? 0
    }

    /// Every visited token of `kind`, with its first date.
    public func visits(of kind: AtlasDiscoveryKind) -> [String: Date] {
        entries[kind] ?? [:]
    }

    /// Every entry as a discovery, earliest first (ties by kind, in ``AtlasDiscoveryKind`` order, then token).
    /// Bounded by the caps' sum.
    public var discoveries: [AtlasDiscovery] {
        var all: [AtlasDiscovery] = []
        for kind in AtlasDiscoveryKind.allCases {
            for (token, date) in visits(of: kind).prefix(Self.cap(for: kind)) {
                all.append(AtlasDiscovery(kind: kind, token: token, at: date))
            }
        }
        return all.sorted { Self.precedes($0, $1) }
    }

    // MARK: First visits

    /// The kind and token of each place `visit` names, in the fixed order of ``AtlasDiscoveryKind``
    /// (country, continent, ocean, sea, city, landmark, terrain): one of each kind but landmarks, of which the
    /// first ``AtlasVisit/maxLandmarks`` are taken in the visit's order. Tokens unchecked.
    public static func places(in visit: AtlasVisit) -> [(kind: AtlasDiscoveryKind, token: String)] {
        let before: [(AtlasDiscoveryKind, String?)] = [
            (.country, visit.countryCode), (.continent, visit.continent?.rawValue), (.ocean, visit.ocean?.rawValue),
            (.sea, visit.sea?.token), (.city, visit.city?.token)
        ]
        let landmarks: [(AtlasDiscoveryKind, String?)] = visit.landmarks.prefix(AtlasVisit.maxLandmarks)
            .map { (.landmark, $0) }
        let named = before + landmarks + [(.terrain, visit.terrain.rawValue)]
        return named.compactMap { kind, token in token.map { (kind: kind, token: $0) } }
    }

    /// The first visits `visit` would add at `date`, in the fixed order, without changing the book: the places
    /// it names with a valid token that the book does not hold yet, each once even when the visit names it
    /// twice (caps are applied by ``record(_:at:)``). At most ``maxDiscoveriesPerVisit``.
    public func newDiscoveries(in visit: AtlasVisit, at date: Date) -> [AtlasDiscovery] {
        guard date.timeIntervalSince1970.isFinite else { return [] }
        var seen = Set<String>(), found: [AtlasDiscovery] = []
        // Bounded: places(in:) names at most maxDiscoveriesPerVisit places.
        for place in Self.places(in: visit).prefix(Self.maxDiscoveriesPerVisit)
        where Self.isValidToken(place.token, of: place.kind) && firstVisit(place.kind, token: place.token) == nil {
            guard seen.insert(place.kind.rawValue + "/" + place.token).inserted else { continue }
            found.append(AtlasDiscovery(kind: place.kind, token: place.token, at: date))
        }
        return found
    }

    /// Records `visit` at `date` and returns only its first visits, in the fixed order (country, continent,
    /// ocean, sea, city, landmark, terrain). A first visit past its kind's cap is refused and counted. At most
    /// ``maxDiscoveriesPerVisit``.
    public mutating func record(_ visit: AtlasVisit, at date: Date) -> [AtlasDiscovery] {
        let candidates = newDiscoveries(in: visit, at: date)
        guard !candidates.isEmpty else { return [] }
        var kept: [AtlasDiscovery] = []
        for discovery in candidates.prefix(Self.maxDiscoveriesPerVisit) {
            guard count(of: discovery.kind) < Self.cap(for: discovery.kind) else {
                refusedCount += 1
                continue
            }
            entries[discovery.kind, default: [:]][discovery.token] = discovery.at
            kept.append(discovery)
        }
        return kept
    }

    // MARK: Landmarks

    /// Whether `landmark` has been found.
    public func isFound(_ landmark: AtlasLandmark) -> Bool {
        firstVisit(.landmark, token: landmark.token) != nil
    }

    /// The landmarks of the city whose atlas token is `cityToken` that have been found, in `list`'s order
    /// (the city card's icons with names; the rest stay question marks).
    public func foundLandmarks(inCity cityToken: String, of list: WorldLandmarks) -> [AtlasLandmark] {
        guard count(of: .landmark) > 0 else { return [] }
        return list.landmarks(inCity: cityToken).filter { isFound($0) }
    }

    /// How many of the city's landmarks have been found ("2 of 6 found": the 6 is
    /// `list.landmarks(inCity:).count`).
    public func foundLandmarkCount(inCity cityToken: String, of list: WorldLandmarks) -> Int {
        foundLandmarks(inCity: cityToken, of: list).count
    }

    // MARK: Restoring

    /// Merges `other` (a passport restored from the sealed backup) into this one by token, keeping the earliest
    /// date of each; returns how many entries were added or moved earlier. New entries past a cap are refused
    /// and counted, earliest kept first. Bounded by the caps of `other`.
    public mutating func merge(_ other: PassportBook) -> Int {
        var changed = 0
        for kind in AtlasDiscoveryKind.allCases {
            let incoming = other.visits(of: kind)
            guard !incoming.isEmpty else { continue }
            changed += merge(incoming, of: kind)
        }
        return changed
    }

    /// Merges one kind's entries; how many changed.
    private mutating func merge(_ incoming: [String: Date], of kind: AtlasDiscoveryKind) -> Int {
        let cap = Self.cap(for: kind)
        guard cap > 0 else { return 0 }
        var current = visits(of: kind), changed = 0
        let ordered = incoming.sorted { ($0.value, $0.key) < ($1.value, $1.key) }
        for (token, date) in ordered.prefix(cap) where Self.isValidToken(token, of: kind) {
            if let existing = current[token] {
                guard date < existing else { continue }
                current[token] = date
                changed += 1
            } else if current.count < cap {
                current[token] = date
                changed += 1
            } else {
                refusedCount += 1
            }
        }
        entries[kind] = current.isEmpty ? nil : current
        return changed
    }

    // MARK: Bytes

    /// The versioned bytes (sorted keys, so the same book always encodes the same).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(self)
        guard data.count <= Self.maxEncodedBytes else { throw BookError.tooLarge }
        return data
    }

    /// The passport in `data`; throws a ``BookError`` when the bytes are not a passport this build reads.
    public init(data: Data) throws {
        guard data.count <= Self.maxEncodedBytes else { throw BookError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            self = try decoder.decode(PassportBook.self, from: data)
        } catch let error as BookError {
            throw error
        } catch {
            throw BookError.malformed
        }
    }

    /// Reads a book, refusing an unknown version, a kind over its cap and a bad token.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let version = try container.decode(Int.self, forKey: Key("version"))
        guard version == Self.currentVersion else { throw BookError.unsupportedVersion(version) }
        var read: [AtlasDiscoveryKind: [String: Date]] = [:]
        for kind in AtlasDiscoveryKind.allCases {
            let list = try container.decodeIfPresent([String: Date].self, forKey: Key(kind.rawValue)) ?? [:]
            guard list.count <= Self.cap(for: kind) else { throw BookError.overCap(kind) }
            guard list.keys.allSatisfy({ Self.isValidToken($0, of: kind) }) else { throw BookError.badToken(kind) }
            if !list.isEmpty { read[kind] = list }
        }
        self.version = version
        self.entries = read
    }

    /// Writes the version and each kind that has entries.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(Self.currentVersion, forKey: Key("version"))
        for kind in AtlasDiscoveryKind.allCases {
            guard let list = entries[kind], !list.isEmpty else { continue }
            try container.encode(list, forKey: Key(kind.rawValue))
        }
    }

    /// Two books are equal when they hold the same entries (the refusal count is an audit, not content).
    public static func == (lhs: PassportBook, rhs: PassportBook) -> Bool {
        lhs.version == rhs.version && lhs.entries == rhs.entries
    }

    // MARK: Rules

    /// Whether `token` may be kept as a `kind`: not empty, at most ``maxTokenBytes``, a known rawValue for a
    /// continent, ocean or terrain, lowerCamel ASCII for a landmark (``AtlasLandmark/isValidToken(_:)``), and
    /// printable ASCII without spaces for a country, sea or city.
    public static func isValidToken(_ token: String, of kind: AtlasDiscoveryKind) -> Bool {
        guard !token.isEmpty, token.utf8.count <= maxTokenBytes else { return false }
        switch kind {
        case .continent: return AtlasContinent(rawValue: token) != nil
        case .ocean: return AtlasOcean(rawValue: token) != nil
        case .terrain: return AtlasTerrain(rawValue: token) != nil
        case .landmark: return AtlasLandmark.isValidToken(token)
        case .country, .sea, .city: return token.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F }
        }
    }

    /// Earliest first, then kind order, then token.
    private static func precedes(_ lhs: AtlasDiscovery, _ rhs: AtlasDiscovery) -> Bool {
        guard lhs.at == rhs.at else { return lhs.at < rhs.at }
        let order = AtlasDiscoveryKind.allCases
        let left = order.firstIndex(of: lhs.kind) ?? 0, right = order.firstIndex(of: rhs.kind) ?? 0
        guard left == right else { return left < right }
        return lhs.token < rhs.token
    }

    /// A coding key spelled by its string (the version and the kinds' frozen rawValues).
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
