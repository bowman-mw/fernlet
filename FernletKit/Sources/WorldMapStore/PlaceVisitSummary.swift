import FernletFoundation
import Foundation

/// Home's small summary of Where you've been (owner's P1-A, 2026-11-27): what the gentle "quiet place"
/// card may know of the places the person returns to, without the lock.
///
/// Per kept place it holds the person's own name for it (``Entry/label``), Fernlet's own kind token when
/// one is known (``Entry/kind``: one of the five everyday kinds), the day of the last visit, and a 60-day
/// visit count. Never Apple's name, never a point, never Apple's reference, never the timeline.
///
/// - **Written by the fold.** Only ``PlaceLogStore/fold(hubKey:now:calendar:)``, which runs under the
///   Private tab's hub key, adds visits to it, so nothing is written while Private is closed or in a decoy
///   (a decoy never has the hub key). The kind comes from Fernlet's own records at the fold (a place the
///   person eats out at is food and drink) and from the kind the app's own name lookup reports while
///   Private is open (``PlaceLogStore/notePlaceKind(_:for:)``).
/// - **Read without the lock.** It is under the map vault's buffer key (``WorldMapVault/File/placeSummary``),
///   read only through ``PlaceVisitSummaryReader``. Device-only: never synced, never in CloudKit, never in
///   a backup or a decoy.
/// - **Goes with Where you've been.** A deleted place, a deleted day's or stop's place, "Delete all of it",
///   an app-lock reset and every wipe (the vault's folder) remove it.
///
/// **The count.** ``Entry/visits60`` counts the visits that kept coming within 60 days of each other,
/// ending at the last one: a visit more than 60 days after the last one starts the count again at 1. It
/// is kept without any visit's date but the last (the summary holds no dates beyond it).
///
/// Bounded: at most ``maxEntries`` entries, and an entry whose last visit is over ``keptDays`` days old is
/// dropped. Frozen at rest: `schemaVersion`, `entries` and the entry field names.
public nonisolated struct PlaceVisitSummary: Codable, Equatable, Sendable {
    /// The format this build writes.
    public static let currentSchema = 1
    /// The most entries kept (Where you've been's own cap).
    public static let maxEntries = PlaceLog.maxPlaces
    /// The visit count's window, in days.
    public static let countWindowDays = 60
    /// How long an entry is kept after its last visit, in days.
    public static let keptDays = 365
    /// The highest count kept.
    public static let maxCount = 999
    /// Nothing summarised.
    public static let empty = PlaceVisitSummary(entries: [])

    /// One place the person returns to, as Home may know it.
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        /// The place's id in Where you've been (``PlaceRecord/id``): Fernlet's own random id, never Apple's.
        public let id: UUID
        /// The person's own name for the place, or nil.
        public var label: String?
        /// Fernlet's own kind token for it, or nil while none is known.
        public var kind: PlaceCategory?
        /// The start of the day of the last visit.
        public var lastVisitDay: Date
        /// The visits that kept coming within 60 days of each other, ending at the last one.
        public var visits60: Int

        /// An entry.
        public init(id: UUID, label: String? = nil, kind: PlaceCategory? = nil, lastVisitDay: Date, visits60: Int) {
            self.id = id
            self.label = label.flatMap(PlaceRecord.validLabel)
            self.kind = kind
            self.lastVisitDay = lastVisitDay
            self.visits60 = min(max(visits60, 0), PlaceVisitSummary.maxCount)
        }
    }

    public var schemaVersion: Int
    /// The places, most recently visited first.
    public var entries: [Entry]

    /// A summary in the current format.
    public init(entries: [Entry]) {
        schemaVersion = Self.currentSchema
        self.entries = entries
    }

    /// This summary after a fold at `now`: `newVisits` (visit stops not counted before) counted on their
    /// places, then every entry brought in line with `log` (the person's names; a place no longer kept is
    /// dropped), a place to eat in `eating` marked food and drink, and old entries dropped.
    public func folding(newVisits: [PlaceStop], log: PlaceLog, eating: [EatingPlace], now: Date,
                        calendar: Calendar = .current) -> PlaceVisitSummary {
        let places = Dictionary(log.places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let visits = newVisits.filter { $0.kind == .visit }.sorted { $0.at < $1.at }
        for visit in visits.prefix(PlaceLog.maxStops) {
            guard let id = visit.placeID, places[id] != nil else { continue }
            let day = calendar.startOfDay(for: visit.at)
            if let entry = byID[id] {
                byID[id] = Self.counting(day, on: entry, calendar: calendar)
            } else if byID.count < Self.maxEntries {
                byID[id] = Entry(id: id, lastVisitDay: day, visits60: 1)
            }
        }
        let next = byID.values.compactMap { entry -> Entry? in
            guard let place = places[entry.id] else { return nil }
            var kept = entry
            kept.label = place.label
            if kept.kind == nil, Self.isEatingPlace(place, in: eating) { kept.kind = .foodAndDrink }
            return kept
        }
        return PlaceVisitSummary(entries: Self.sortedAndPruned(next, now: now, calendar: calendar))
    }

    /// `entry` with a visit on `day` counted: a visit more than ``countWindowDays`` after the last starts
    /// the count again; one more than that before it is not counted.
    static func counting(_ day: Date, on entry: Entry, calendar: Calendar) -> Entry {
        var next = entry
        let gap = calendar.dateComponents([.day], from: entry.lastVisitDay, to: day).day ?? 0
        if gap > countWindowDays {
            next.visits60 = 1
        } else if gap >= -countWindowDays {
            next.visits60 = min(entry.visits60 + 1, maxCount)
        }
        next.lastVisitDay = max(entry.lastVisitDay, day)
        return next
    }

    /// Whether `place` is one of the places the person eats out at, by Fernlet's id or Apple's reference.
    static func isEatingPlace(_ place: PlaceRecord, in eating: [EatingPlace]) -> Bool {
        eating.contains { $0.id == place.id || (place.placeID != nil && $0.placeID == place.placeID) }
    }

    /// `entries` without those last visited over ``keptDays`` before `now`, most recently visited first
    /// (ties by id), at most ``maxEntries``.
    static func sortedAndPruned(_ entries: [Entry], now: Date, calendar: Calendar) -> [Entry] {
        let oldest = calendar.date(byAdding: .day, value: -keptDays, to: calendar.startOfDay(for: now)) ?? now
        var entries = entries.filter { $0.lastVisitDay >= oldest }
        entries.sort { ($0.lastVisitDay, $1.id.uuidString) > ($1.lastVisitDay, $0.id.uuidString) }
        return Array(entries.prefix(maxEntries))
    }

    /// This summary with place `id` marked as `kind` (unchanged when it has no entry for it).
    public func notingKind(_ kind: PlaceCategory, for id: UUID) -> PlaceVisitSummary {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].kind != kind else { return self }
        var next = self
        next.entries[index].kind = kind
        return next
    }

    /// This summary without the places `ids` (the person deleted them, or one of their visits).
    public func forgetting(_ ids: Set<UUID>) -> PlaceVisitSummary {
        guard !ids.isEmpty else { return self }
        var next = self
        next.entries.removeAll { ids.contains($0.id) }
        return next
    }
}

/// The one way to read ``PlaceVisitSummary`` (the app's Home, CAP-2's named exception): read-only, under
/// the map vault's buffer key, with no hub key and no other file. A decoy never asks (the app's gate).
@MainActor
public final class PlaceVisitSummaryReader {
    private let vault: WorldMapVault

    /// A reader over `vault`.
    public init(vault: WorldMapVault) {
        self.vault = vault
    }

    /// The summary now: empty when there is none, it can't be read right now, or it reads as none (the
    /// next fold writes it again). Never removes or writes anything.
    public func read() -> PlaceVisitSummary {
        do {
            guard let data = try vault.read(WorldMapVault.File.placeSummary) else { return .empty }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let summary = try decoder.decode(PlaceVisitSummary.self, from: data)
            return summary.schemaVersion == PlaceVisitSummary.currentSchema ? summary : .empty
        } catch {
            FernletAuditLog.log("worldMap.places.summaryUnread")
            return .empty
        }
    }
}
