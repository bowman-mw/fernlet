import CloudKitSync
import CryptoKit
import FernletFoundation
import Foundation
import WorldMapStore

/// The World passport's Sealed backup seam is shut: a duress session is active (the decoy shows an
/// empty passport and keeps nothing). Thrown by every gated member of ``PassportBackupAdapter`` —
/// never an empty answer.
struct PassportBackupSeamClosedError: Error, Equatable {}

/// One World passport entry as the passport's Sealed iCloud backup carries it (round 7, owner
/// 2026-10-29), inside a sealed v2 chunk (``SealedBackupV2Envelope``): the kind and frozen token of one
/// place first visited, with the date of that first visit — or, for a country or an airport, one trip there with
/// the trip's start (owner 2026-10-29, "Stamp each trip": a country and an airport have a record per trip).
/// FROZEN keys: `id`, `kind`, `token`, `first` (seconds since 1970), and `last`, optional, on a country's or an
/// airport's latest trip: its clock (the last accepted fix in a country; an airport's latest ticket or landing),
/// so a restored phone knows how long the person has been away. A record written before trips (one per country,
/// no `last`) reads as that country's one trip.
///
/// **Airports and flights** (World-Airports-Spec §8–§11) keep the same shape and add only OPTIONAL keys:
/// - kind `airport`: an airport (``WorldAirport/token``), one record per trip, like a country;
/// - kind `airportTransit`: one layover, `token` the airport and `first` its trip's start;
/// - kind `flight` (flown) and `upcomingFlight`: one ``PassportFlight``, `token` "FROM>TO" (IATA codes), `first`
///   the departure and `last` the arrival when known, with `src` the sources bitmask, `flags` (bit 1: the times
///   are unsure; absent when 0) and `eh` the calendar event's hash (calendar flights only).
///
/// The `id` is minted when the export's snapshot is taken and names the record only within its set
/// (the engine keeps one copy per id of a hostile set); it says nothing about the place and is never
/// kept on the iPhone. A restore merges by kind and token, never by id. `kind` is kept as its raw
/// spelling, and every key this build does not know is kept as it was read (``extra``, at most
/// ``maxExtraKeys``), so a record of a kind this build does not know decodes whole: the restore skips it and
/// keeps it (``PassportBook/keptBackupRecords``), and every later export carries it again (World-Airports-Spec
/// §11), so a newer Fernlet's records survive a round trip through this build.
nonisolated struct PassportBackupRecord: Codable, Equatable {
    /// The record's id within its set.
    var id: UUID
    /// The kind's frozen rawValue (`AtlasDiscoveryKind`, or one of the airport kinds above).
    var kind: String
    /// The place's frozen token (`AtlasDiscovery.token`), or a flight's "FROM>TO".
    var token: String
    /// When it was first visited; for a country or an airport, when this trip began; for a layover, its trip's
    /// start; for a flight, its departure.
    var date: Date
    /// For a country's or an airport's latest trip, its clock; for a flight, its arrival when known; nil
    /// otherwise and in records from before trips.
    var lastSeen: Date?
    /// A flight's sources bitmask (`src`, ``PassportFlight/Sources``); nil for every other kind.
    var sources: Int?
    /// A flight's flags (`flags`: bit 1, the times are unsure); nil when there are none.
    var flags: Int?
    /// A calendar flight's event hash (`eh`); nil otherwise.
    var eventHash: String?
    /// Every key this build does not know, as it was read (a newer Fernlet's).
    var extra: [String: PassportJSONValue]

    /// The most keys this build does not know that one record may carry; a record with more is not one
    /// this build reads (a `DecodingError`: the set needs a newer Fernlet).
    static let maxExtraKeys = 16
    /// The record kinds this build adds beside `AtlasDiscoveryKind` (frozen rawValues).
    static let transitKind = "airportTransit"
    static let flightKind = "flight"
    static let upcomingFlightKind = "upcomingFlight"
    /// The flags bit for a flight whose times are unsure.
    static let timesUnsureFlag = 1

    /// FROZEN keys.
    nonisolated enum CodingKeys: String, CodingKey, CaseIterable {
        case id, kind, token
        case date = "first"
        case lastSeen = "last"
        case sources = "src"
        case flags
        case eventHash = "eh"
    }

    /// Creates a record.
    init(id: UUID, kind: String, token: String, date: Date, lastSeen: Date? = nil, sources: Int? = nil,
         flags: Int? = nil, eventHash: String? = nil, extra: [String: PassportJSONValue] = [:]) {
        self.id = id
        self.kind = kind
        self.token = token
        self.date = date
        self.lastSeen = lastSeen
        self.sources = sources
        self.flags = flags
        self.eventHash = eventHash
        self.extra = extra
    }

    /// The record of `flight`, flown or (when `upcoming`) upcoming.
    init(id: UUID, flight: PassportFlight, upcoming: Bool) {
        self.init(id: id, kind: upcoming ? Self.upcomingFlightKind : Self.flightKind, token: flight.route,
                  date: flight.departure, lastSeen: flight.arrival, sources: flight.sources.rawValue,
                  flags: flight.timesUnsure ? Self.timesUnsureFlag : nil, eventHash: flight.eventHash)
    }

    /// Decodes the frozen shape (`first` and `last` in seconds since 1970; `last`, `src`, `flags` and `eh` may be
    /// absent), keeping every other key as it was read.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        token = try container.decode(String.self, forKey: .token)
        date = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .date))
        lastSeen = try container.decodeIfPresent(Double.self, forKey: .lastSeen).map(Date.init(timeIntervalSince1970:))
        sources = try container.decodeIfPresent(Int.self, forKey: .sources)
        flags = try container.decodeIfPresent(Int.self, forKey: .flags)
        eventHash = try container.decodeIfPresent(String.self, forKey: .eventHash)
        let all = try decoder.container(keyedBy: AnyKey.self)
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        let others = all.allKeys.filter { !known.contains($0.stringValue) }
        guard others.count <= Self.maxExtraKeys else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container,
                                                   debugDescription: "more keys than a passport record carries")
        }
        var extra: [String: PassportJSONValue] = [:]
        // Bounded: at most maxExtraKeys (checked above).
        for key in others {
            extra[key.stringValue] = try all.decode(PassportJSONValue.self, forKey: key)
        }
        self.extra = extra
    }

    /// Encodes the frozen shape (`last`, `src`, `flags` and `eh` only when set) and every kept key.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        // Bounded: at most maxExtraKeys; a kept key never takes a frozen key's place.
        for (key, value) in extra where CodingKeys(stringValue: key) == nil {
            try container.encode(value, forKey: AnyKey(key))
        }
        try container.encode(id, forKey: AnyKey(CodingKeys.id.stringValue))
        try container.encode(kind, forKey: AnyKey(CodingKeys.kind.stringValue))
        try container.encode(token, forKey: AnyKey(CodingKeys.token.stringValue))
        try container.encode(date.timeIntervalSince1970, forKey: AnyKey(CodingKeys.date.stringValue))
        try container.encodeIfPresent(lastSeen?.timeIntervalSince1970, forKey: AnyKey(CodingKeys.lastSeen.stringValue))
        try container.encodeIfPresent(sources, forKey: AnyKey(CodingKeys.sources.stringValue))
        try container.encodeIfPresent(flags, forKey: AnyKey(CodingKeys.flags.stringValue))
        try container.encodeIfPresent(eventHash, forKey: AnyKey(CodingKeys.eventHash.stringValue))
    }

    /// The passport entry this record carries (a country's or an airport's: one trip), or nil for a layover, a
    /// flight, or a kind this build does not know.
    var discovery: AtlasDiscovery? {
        AtlasDiscoveryKind(rawValue: kind).map { AtlasDiscovery(kind: $0, token: token, at: date) }
    }

    /// The flight a `flight` or `upcomingFlight` record carries, or nil for any other kind or a flight that
    /// breaks ``PassportFlight``'s rules.
    var flight: PassportFlight? {
        guard kind == Self.flightKind || kind == Self.upcomingFlightKind, let sources else { return nil }
        let codes = token.split(separator: ">", omittingEmptySubsequences: false)
        guard codes.count == 2 else { return nil }
        return PassportFlight(from: String(codes[0]), to: String(codes[1]), departure: date, arrival: lastSeen,
                              sources: PassportFlight.Sources(rawValue: sources),
                              timesUnsure: (flags ?? 0) & Self.timesUnsureFlag != 0, eventHash: eventHash)
    }

    /// Whether this build knows the record's kind.
    var isKnownKind: Bool {
        AtlasDiscoveryKind(rawValue: kind) != nil
            || [Self.transitKind, Self.flightKind, Self.upcomingFlightKind].contains(kind)
    }

    /// The record as the passport keeps it (a kind this build does not know): its JSON object without the `id`,
    /// or nil when it can't be written.
    var keptValue: PassportJSONValue? {
        guard let data = try? JSONEncoder().encode(self),
              var object = (try? JSONDecoder().decode(PassportJSONValue.self, from: data))?.objectValue else {
            return nil
        }
        object[CodingKeys.id.stringValue] = nil
        return .object(object)
    }

    /// The record a kept object carries again, under `id`, or nil when it is not one.
    init?(id: UUID, kept: PassportJSONValue) {
        guard var object = kept.objectValue else { return nil }
        object[CodingKeys.id.stringValue] = .string(id.uuidString)
        guard let data = try? JSONEncoder().encode(PassportJSONValue.object(object)),
              let record = try? JSONDecoder().decode(PassportBackupRecord.self, from: data) else { return nil }
        self = record
    }

    /// A coding key spelled by any string (the kept keys).
    nonisolated struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// The World passport's Sealed backup adapter for the v2 engine (round 7; owner 2026-10-29: the
/// passport backup should "have its own switch"): the passport the app's one `WorldAtlasKeeper` keeps,
/// mapped onto ``SealedBackupV2Adapter``, so it runs on the same engine as the period, intimate-log and
/// journal backups with nothing forked — its own switch (`sealedBackupPassportEnabled`), E1, the E2
/// compare-and-swap, the owner hold, spacing and deletes, and every record sealed through the same
/// content-key path (``SealedBackupService``) before anything reaches CloudKit.
///
/// - **What a backup holds.** One ``PassportBackupRecord`` per entry: every continent, ocean, sea, city,
///   landmark and terrain class first visited, with that first date; every trip to each country or
///   territory and through each airport, with the trip's start (the latest also carrying the clock); every
///   layover, flight and upcoming flight (World-Airports-Spec §11: airport visits, flights and layovers are
///   passport records, carried only here); and every record of a kind this build does not know that a restore
///   kept. An empty passport exports an empty set.
/// - **The seam** is `!duress` (the passport has no hide switch; a decoy shows an empty passport): every
///   gated member throws ``PassportBackupSeamClosedError`` while a duress session runs, and the keeper
///   itself refuses in a decoy, so a decoy exports and restores nothing.
/// - **The snapshot** reads the passport (``passport``), which THROWS while it can't be read right now
///   (the phone locked) — never an empty passport in its place — so the export fails with nothing
///   written and the upload still owed. Each chunk reads the passport again: an entry removed since the
///   snapshot is left out, and the date is the one held now (a trip or a layover is named by its start, so
///   one gone since is left out too; a flight is the one the book holds now under the one-flight rule).
/// - **The restore** merges by kind and token, keeping the earliest date and never removing a local
///   entry, a country's and an airport's trips by date, each once, and flights one flight once
///   (``mergePassport``, `PassportBook.merge`). A record of a kind this build does not know is SKIPPED and
///   KEPT (World-Airports-Spec §11: an older build skips unknown kinds when restoring and keeps them when
///   rewriting), so it is carried again in every later export. A token it would refuse, a flight that breaks the
///   rules, or a set over a cap (more than ``PassportBook/maxKeptBackupRecords`` kept records among them) is
///   ``SealedBackupV2FormatError/unreadableRecords`` (a newer Fernlet wrote it: never dropped, never written
///   over); a failed save is rethrown, so the restore stays unresolved and a later pass merges again. No
///   follow-up write.
/// - No row of a passport is ever dead (the entries are not sealed one by one), so nothing pauses and
///   "Remove them" removes nothing. There never was a v1 passport set.
@MainActor
final class PassportBackupAdapter: SealedBackupV2Adapter {
    /// One snapshotted entry.
    private enum Entry: Equatable {
        /// A first visit of a kind without trips, by kind and token.
        case place(AtlasDiscoveryKind, String)
        /// One trip to a country or through an airport, by its start.
        case trip(AtlasDiscoveryKind, String, Date)
        /// One layover, by its airport and trip start.
        case transit(String, Date)
        /// One flight, flown or upcoming, as the snapshot saw it.
        case flight(PassportFlight, upcoming: Bool)
        /// One kept record of a kind this build does not know.
        case kept(PassportJSONValue)
    }

    /// Whether the passport's seam is open (`!duress`).
    let isOpen: @MainActor () -> Bool
    /// The World passport as it is now; throws when it can't be read right now (never an empty one in
    /// its place).
    let passport: @MainActor () throws -> PassportBook
    /// Merges a restored passport into this iPhone's (by token, the earliest date kept) and saves;
    /// returns how many entries were added or moved earlier, and throws when it was not saved.
    let mergePassport: @MainActor (PassportBook) throws -> Int
    /// The entries the last snapshot named, by the id minted for each.
    private var snapshot: [UUID: Entry] = [:]

    /// Creates the adapter.
    ///
    /// - Parameters:
    ///   - isOpen: Whether the seam is open (`!duress`).
    ///   - passport: The World passport now; throws when it can't be read.
    ///   - mergePassport: Merges a restored passport and saves; how many entries changed.
    init(
        isOpen: @escaping @MainActor () -> Bool,
        passport: @escaping @MainActor () throws -> PassportBook,
        mergePassport: @escaping @MainActor (PassportBook) throws -> Int
    ) {
        self.isOpen = isOpen
        self.passport = passport
        self.mergePassport = mergePassport
    }

    var payload: SealedBackupPayloadType { .worldPassport }
    var isSurfaceOpen: Bool { isOpen() }
    /// The passport has no store to attach: one that can't be read right now fails the snapshot.
    var isStoreHealthy: Bool { true }

    func withOpenSeam<T>(_ body: () throws -> T) throws -> T {
        guard isOpen() else { throw PassportBackupSeamClosedError() }
        return try body()
    }

    /// The most records one passport makes: an entry each, a record for every later trip, layover, flight and
    /// upcoming flight, and every kept record (under ``SealedBackupV2Engine/maxRecords``).
    static let maxRecords = PassportBook.maxEntries + PassportBook.maxReturns + PassportBook.maxAirportReturns
        + PassportBook.maxTransits + PassportBook.maxFlights + PassportBook.maxUpcomingFlights
        + PassportBook.maxKeptBackupRecords

    /// One id per passport entry, per later trip, per layover, per flight and upcoming flight, and per kept
    /// record — first visits earliest first, then the later trips, the layovers, the flights and the kept
    /// records — or the passport's own error while it can't be read (never an empty snapshot in its place).
    /// Gated: throws while the seam is shut.
    func snapshotIDs() throws -> [UUID] {
        let book = try withOpenSeam { try passport() }
        var entries: [Entry] = []
        // R2: bounded by the caps' sum and the trip caps.
        for discovery in (book.discoveries + book.returnVisits + book.airportReturnVisits).prefix(Self.maxRecords) {
            let hasTrips = discovery.kind == .country || discovery.kind == .airport
            entries.append(hasTrips ? .trip(discovery.kind, discovery.token, discovery.at)
                                    : .place(discovery.kind, discovery.token))
        }
        entries += book.transitVisits.prefix(PassportBook.maxTransits).map { .transit($0.token, $0.at) }
        entries += book.flights.prefix(PassportBook.maxFlights).map { .flight($0, upcoming: false) }
        entries += book.upcomingFlights.prefix(PassportBook.maxUpcomingFlights).map { .flight($0, upcoming: true) }
        entries += book.keptBackupRecords.prefix(PassportBook.maxKeptBackupRecords).map { .kept($0) }
        var ids: [UUID] = []
        var taken: [UUID: Entry] = [:]
        ids.reserveCapacity(entries.count)
        for entry in entries.prefix(Self.maxRecords) {  // R2: bounded by maxRecords.
            let id = UUID()
            ids.append(id)
            taken[id] = entry
        }
        snapshot = taken
        return ids
    }

    /// The snapshotted entries among `ids` that the passport still holds, with their dates now. The
    /// hub key is not needed: the records are sealed by the engine's content-key path alone.
    func classifiedChunk(_ ids: [UUID], hubKey: SymmetricKey) throws -> SealedBackupChunkPage<PassportBackupRecord> {
        try withOpenSeam {
            let book = try passport()
            var lookup = Lookup(book: book)
            var page = SealedBackupChunkPage<PassportBackupRecord>()
            for id in ids {  // R2: bounded by one chunk (SealedBackupV2Engine.chunkSize).
                guard let entry = snapshot[id], let record = Self.record(id: id, entry, in: book, lookup: &lookup) else {
                    continue
                }
                page.records.append(record)
            }
            return page
        }
    }

    func recordID(_ record: PassportBackupRecord) -> UUID { record.id }

    /// One chunk's indexes over the book, built only when the chunk needs them.
    private struct Lookup {
        let book: PassportBook
        /// Flown flights by route.
        private var flown: [String: [PassportFlight]]?
        /// Upcoming flights by route.
        private var upcoming: [String: [PassportFlight]]?
        /// The kept records.
        private var kept: Set<PassportJSONValue>?

        init(book: PassportBook) { self.book = book }

        /// The flight the book holds now that is the same flight as `flight`, flown or upcoming.
        mutating func flight(_ flight: PassportFlight, upcoming isUpcoming: Bool) -> PassportFlight? {
            let index: [String: [PassportFlight]]
            if isUpcoming {
                index = upcoming ?? Dictionary(grouping: book.upcomingFlights, by: \.route)
                upcoming = index
            } else {
                index = flown ?? Dictionary(grouping: book.flights, by: \.route)
                flown = index
            }
            return index[flight.route]?.first { $0.isSameFlight(as: flight) }
        }

        /// Whether the book still keeps `record`.
        mutating func keeps(_ record: PassportJSONValue) -> Bool {
            let set = kept ?? Set(book.keptBackupRecords)
            kept = set
            return set.contains(record)
        }
    }

    /// The record for `entry` as `book` holds it now, or nil when it is gone: a first visit with its date now,
    /// a country or airport trip the book still has (its latest carrying the clock), a layover still marked, a
    /// flight as the book holds it now, or a record still kept.
    private static func record(id: UUID, _ entry: Entry, in book: PassportBook, lookup: inout Lookup)
        -> PassportBackupRecord? {
        switch entry {
        case .place(let kind, let token):
            guard let date = book.firstVisit(kind, token: token) else { return nil }
            return PassportBackupRecord(id: id, kind: kind.rawValue, token: token, date: date)
        case .trip(let kind, let token, let trip):
            let trips = kind == .airport ? book.trips(atAirport: token) : book.trips(inCountry: token)
            guard trips.contains(trip) else { return nil }
            let clock = trip == trips.last
                ? (kind == .airport ? book.lastSeen(atAirport: token) : book.lastSeen(inCountry: token)) : nil
            return PassportBackupRecord(id: id, kind: kind.rawValue, token: token, date: trip, lastSeen: clock)
        case .transit(let token, let trip):
            guard book.isTransit(atAirport: token, trip: trip) else { return nil }
            return PassportBackupRecord(id: id, kind: PassportBackupRecord.transitKind, token: token, date: trip)
        case .flight(let flight, let isUpcoming):
            guard let now = lookup.flight(flight, upcoming: isUpcoming) else { return nil }
            return PassportBackupRecord(id: id, flight: now, upcoming: isUpcoming)
        case .kept(let value):
            guard lookup.keeps(value) else { return nil }
            return PassportBackupRecord(id: id, kept: value)
        }
    }

    /// There never was a v1 passport set: a bare array under this payload's name is not this build's.
    func decodeV1Chunk(_ data: Data) throws -> [PassportBackupRecord] {
        throw SealedBackupV2FormatError.malformedEnvelope
    }

    /// Merges `records` into this iPhone's passport by kind and token, keeping the earliest date and
    /// removing nothing; a record of a kind this build does not know is kept, not merged. A set this build can't
    /// hold whole is ``SealedBackupV2FormatError/unreadableRecords``.
    func restoreMerging(_ records: [PassportBackupRecord], hubKey: SymmetricKey) throws -> SealedBackupMergeResult {
        try withOpenSeam {
            let restored = try Self.book(of: records)
            guard !restored.holdsNothing else { return SealedBackupMergeResult() }
            return SealedBackupMergeResult(merged: try mergePassport(restored))
        }
    }

    /// No follow-up: the map and the passport screen read the keeper.
    func didRestore(_ result: SealedBackupMergeResult) -> Bool { true }

    /// Nothing of a passport is ever dead; nothing is removed (gated like every other member).
    func removeStillDead(_ ids: [UUID], hubKey: SymmetricKey) throws -> Int {
        try withOpenSeam { 0 }
    }

    /// The passport `records` carry. A country's or an airport's records are its trips (an old record, one per
    /// country, is one trip), its clock the latest `last` among them; layovers, flights and upcoming flights come
    /// from their own kinds; and a record of a kind this build does not know is skipped and kept
    /// (``PassportBook/keptBackupRecords``). ``SealedBackupV2FormatError/unreadableRecords`` for a token this
    /// build would refuse, a flight that breaks the rules, or more than a cap allows.
    static func book(of records: [PassportBackupRecord]) throws -> PassportBook {
        guard records.count <= maxRecords else { throw SealedBackupV2FormatError.unreadableRecords }
        var discoveries: [AtlasDiscovery] = [], transits: [AtlasDiscovery] = [], kept: [PassportJSONValue] = []
        var flights: [PassportFlight] = [], upcoming: [PassportFlight] = []
        var clocks: [String: Date] = [:], airportClocks: [String: Date] = [:]
        discoveries.reserveCapacity(records.count)
        for record in records {  // R2: bounded by maxRecords (checked above).
            switch record.kind {
            case PassportBackupRecord.transitKind:
                transits.append(AtlasDiscovery(kind: .airport, token: record.token, at: record.date))
            case PassportBackupRecord.flightKind, PassportBackupRecord.upcomingFlightKind:
                guard let flight = record.flight else {
                    FernletAuditLog.log("sealedBackup.v2.passportRecordsUnreadable")
                    throw SealedBackupV2FormatError.unreadableRecords
                }
                if record.kind == PassportBackupRecord.flightKind { flights.append(flight) } else { upcoming.append(flight) }
            default:
                guard let discovery = record.discovery else {
                    guard let value = record.keptValue else { throw SealedBackupV2FormatError.unreadableRecords }
                    kept.append(value)
                    continue
                }
                discoveries.append(discovery)
                if let clock = record.lastSeen, discovery.kind == .country {
                    clocks[record.token] = max(clocks[record.token] ?? clock, clock)
                } else if let clock = record.lastSeen, discovery.kind == .airport {
                    airportClocks[record.token] = max(airportClocks[record.token] ?? clock, clock)
                }
            }
        }
        if !kept.isEmpty { FernletAuditLog.log("sealedBackup.v2.passportKindKept") }
        do {
            return try PassportBook(discoveries: discoveries, lastSeen: clocks, airportLastSeen: airportClocks,
                                    transits: transits, flights: flights, upcomingFlights: upcoming,
                                    keptBackupRecords: kept)
        } catch {
            FernletAuditLog.log("sealedBackup.v2.passportRecordsUnreadable")
            throw SealedBackupV2FormatError.unreadableRecords
        }
    }
}
