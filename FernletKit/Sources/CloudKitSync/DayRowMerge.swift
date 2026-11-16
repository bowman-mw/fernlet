// DayRowMerge.swift
// CloudKitSync
//
// The per-device day merge (G9-1, Docs/G9-Data-Integrity-Recovery-Plan-2026-11-15.md Part 1): each
// device writes ITS OWN `DayRecord` row for a day, so two devices never write the same CloudKit
// record and CloudKit's whole-record last-writer-wins can no longer drop what the other device
// logged. Every element of a day — each meal, workout, planned workout, journal stub, planned meal,
// planned recipe, hygiene tick, care task, plus sleep and water — carries a stamp (when, by which
// device, and whether it was removed). Reading a day takes, per element, the newest stamp across all
// the day's rows: a later deletion beats an earlier entry, a later edit beats an earlier value.
//
// Pure value arithmetic over `FernletDay`; the Core Data side lives in `DayRecordRepository`.

import Foundation
import FernletDomainModel

/// One element's sync stamp: when it was last written, by which device, and whether that write
/// removed it (a tombstone).
///
/// Ordered by `(at, by)`, so every device picks the same winner. `at` is seconds since 1970 at full
/// precision (the row coders' dates are whole seconds, too coarse for two edits in one second).
/// A tombstone holds no content of the element it removed — only its key, inside the day row.
nonisolated struct DayElementStamp: Codable, Equatable, Sendable {
    /// Seconds since 1970, full precision.
    var at: Double
    /// The writing device's ``DayRecordRepository`` device key; `""` for a pre-G9 (legacy) row.
    var by: String
    /// True when this write removed the element.
    var removed: Bool

    /// Persisted keys, short because every element of every day row carries one stamp.
    enum CodingKeys: String, CodingKey {
        case at = "t"
        case by = "d"
        case removed = "x"
    }

    init(at: Double, by: String, removed: Bool = false) {
        self.at = at
        self.by = by
        self.removed = removed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = try container.decode(Double.self, forKey: .at)
        by = try container.decode(String.self, forKey: .by)
        removed = try container.decodeIfPresent(Bool.self, forKey: .removed) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(at, forKey: .at)
        try container.encode(by, forKey: .by)
        if removed { try container.encode(true, forKey: .removed) }
    }

    /// True when `self` beats `other`: a later `at`, or the same `at` and a greater device key.
    func beats(_ other: DayElementStamp) -> Bool {
        (at, by) > (other.at, other.by)
    }
}

/// A `DayRecord` row's payload: the day itself (encoded flat, so an older build still decodes it as
/// a plain `FernletDay`) plus the row format and the element stamps under two extra keys an older
/// build ignores.
///
/// Format 0 is a pre-G9 row (no stamps); format 1 is this file's shape. A build that reads a row with
/// a format newer than ``currentFormat`` leaves that row alone: it reads only its day, as a legacy
/// row, and never rewrites it (owner call S5 = C).
nonisolated struct DayRowPayload: Codable {
    /// The format this build writes.
    static let currentFormat = 1

    /// The day as this row's device last wrote it.
    var day: FernletDay
    /// The row format; 0 when absent.
    var format: Int
    /// Every element's stamp, live and removed, keyed by ``DayElementKeys`` key.
    var stamps: [String: DayElementStamp]

    /// The two keys added beside the day's own keys. Distinct from every `FernletDay` key.
    enum ExtraKeys: String, CodingKey {
        case format = "syncFormat"
        case stamps = "syncStamps"
    }

    init(day: FernletDay, format: Int = DayRowPayload.currentFormat, stamps: [String: DayElementStamp]) {
        self.day = day
        self.format = format
        self.stamps = stamps
    }

    init(from decoder: Decoder) throws {
        day = try FernletDay(from: decoder)
        let container = try decoder.container(keyedBy: ExtraKeys.self)
        format = try container.decodeIfPresent(Int.self, forKey: .format) ?? 0
        stamps = try container.decodeIfPresent([String: DayElementStamp].self, forKey: .stamps) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        try day.encode(to: encoder)
        var container = encoder.container(keyedBy: ExtraKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(stamps, forKey: .stamps)
    }
}

/// The element keys of a day: one string per entry, set member and scalar the merge stamps.
///
/// Keys are FROZEN tokens (they persist inside synced rows): a prefix, a colon, and the element's
/// own id or token. Never localize or rename one.
nonisolated enum DayElementKeys {
    static let meal = "meal:"
    static let workout = "workout:"
    static let plannedWorkout = "plannedWorkout:"
    static let journal = "journal:"
    static let plannedMeal = "plannedMeal:"
    static let plannedRecipe = "plannedRecipe:"
    static let hygiene = "hygiene:"
    static let hygieneToken = "hygieneToken:"
    static let task = "task:"
    static let sleep = "sleep"
    static let water = "water"

    /// Every element key `day` holds.
    static func keys(of day: FernletDay) -> Set<String> {
        var keys = Set<String>()
        keys.formUnion(day.meals.map { meal + "\($0.id)" })
        keys.formUnion(day.workouts.map { workout + "\($0.id)" })
        keys.formUnion(day.plannedWorkouts.map { plannedWorkout + "\($0.id)" })
        keys.formUnion(day.journals.map { journal + "\($0.id)" })
        keys.formUnion((day.plannedMeals ?? []).map { plannedMeal + $0.recipeID.uuidString })
        keys.formUnion(day.plannedRecipeIDs.map { plannedRecipe + $0.uuidString })
        keys.formUnion(day.hygiene.map { hygiene + $0.rawValue })
        keys.formUnion(day.unknownHygieneTokens.map { hygieneToken + $0 })
        keys.formUnion(day.completedPersonalCareTaskIDs.map { task + $0 })
        if day.sleep != nil { keys.insert(sleep) }
        if day.bottleCount > 0 { keys.insert(water) }
        return keys
    }

    /// Every element of `day`, keyed, with the bytes that tell one version of it from another (its
    /// sorted-key JSON; empty for a set member, whose presence is its whole value).
    static func values(of day: FernletDay, encoder: JSONEncoder) throws -> [String: Data] {
        var out: [String: Data] = [:]
        try encode(day.meals, prefix: meal, into: &out, encoder)
        try encode(day.workouts, prefix: workout, into: &out, encoder)
        try encode(day.plannedWorkouts, prefix: plannedWorkout, into: &out, encoder)
        try encode(day.journals, prefix: journal, into: &out, encoder)
        for entry in day.plannedMeals ?? [] { out[plannedMeal + entry.recipeID.uuidString] = try encoder.encode(entry) }
        for id in day.plannedRecipeIDs { out[plannedRecipe + id.uuidString] = Data() }
        for item in day.hygiene { out[hygiene + item.rawValue] = Data() }
        for token in day.unknownHygieneTokens { out[hygieneToken + token] = Data() }
        for id in day.completedPersonalCareTaskIDs { out[task + id] = Data() }
        if let log = day.sleep { out[sleep] = try encoder.encode(log) }
        if day.bottleCount > 0 { out[water] = Data(String(day.bottleCount).utf8) }
        return out
    }

    private static func encode<Entry: Identifiable & Encodable>(
        _ entries: [Entry], prefix: String, into out: inout [String: Data], _ encoder: JSONEncoder
    ) throws {
        for entry in entries { out[prefix + "\(entry.id)"] = try encoder.encode(entry) }
    }

    /// The encoder ``values(of:encoder:)`` compares with: sorted keys, so equal values give equal bytes.
    static func makeFingerprintEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }
}

/// One decoded `DayRecord` row as the merge sees it: its day, its effective stamps, and its order key.
nonisolated struct DayRowView {
    /// The row's day.
    var day: FernletDay
    /// The row's stamps. A legacy or newer-format row gets one live stamp per element, at the row's
    /// `updatedAt` by device `""` (see ``legacy(day:updatedAt:)``).
    var stamps: [String: DayElementStamp]
    /// The row's `updatedAt`, newest-first ordering only.
    var updatedAt: Date
    /// A per-row tiebreak that orders equal `updatedAt`s the same way on every read.
    var tiebreak: String

    /// A view of a row whose own stamps this build will not use: every element it holds is live,
    /// stamped at `updatedAt` by the legacy device `""`.
    static func legacy(day: FernletDay, updatedAt: Date, tiebreak: String) -> DayRowView {
        let stamp = DayElementStamp(at: updatedAt.timeIntervalSince1970, by: "")
        let stamps = Dictionary(uniqueKeysWithValues: DayElementKeys.keys(of: day).map { ($0, stamp) })
        return DayRowView(day: day, stamps: stamps, updatedAt: updatedAt, tiebreak: tiebreak)
    }

    /// A view of a current-format row, filling in a legacy stamp for any element it holds unstamped.
    static func stamped(payload: DayRowPayload, updatedAt: Date, tiebreak: String) -> DayRowView {
        var view = legacy(day: payload.day, updatedAt: updatedAt, tiebreak: tiebreak)
        view.stamps.merge(payload.stamps) { _, own in own }
        return view
    }
}

/// The merge of one day's rows: the day every device converges on, and the winning stamp per element.
nonisolated struct DayMerge {
    /// The merged day (removed elements absent). Its ``FernletDay/loadedSyncKeys`` is set.
    var day: FernletDay
    /// The winning stamp per element key, removed ones included.
    var winners: [String: DayElementStamp]

    /// True when no element is live (every one removed): the day reads as absent.
    var isEmpty: Bool { !day.hasLoggedContent }
}

/// The per-element merge and the own-row write rule (G9-1). `nonisolated`: pure value arithmetic.
nonisolated enum DayRowMerge {
    /// The merge of `rows` for `date`, or nil for no rows.
    static func merge(date: String, rows: [DayRowView]) -> DayMerge? {
        guard !rows.isEmpty else { return nil }
        let ordered = rows.sorted { ($0.updatedAt, $1.tiebreak) > ($1.updatedAt, $0.tiebreak) }
        var winners: [String: DayElementStamp] = [:]
        // R2: bounded by the rows for one day × the elements each holds.
        for row in ordered {
            for (key, stamp) in row.stamps where winners[key].map({ stamp.beats($0) }) ?? true {
                winners[key] = stamp
            }
        }
        var day = assemble(date: date, rows: ordered, winners: winners)
        day.loadedSyncKeys = DayElementKeys.keys(of: day)
        return DayMerge(day: day, winners: winners)
    }

    /// The day built from each element's winning row, in newest-row-first order.
    private static func assemble(date: String, rows: [DayRowView], winners: [String: DayElementStamp]) -> FernletDay {
        func live(_ key: String, in row: DayRowView) -> Bool {
            guard let winner = winners[key], !winner.removed else { return false }
            return row.stamps[key] == winner
        }
        var day = FernletDay(date: date)
        day.meals = pick(rows, \.meals, prefix: DayElementKeys.meal, live)
        day.workouts = pick(rows, \.workouts, prefix: DayElementKeys.workout, live)
        day.plannedWorkouts = pick(rows, \.plannedWorkouts, prefix: DayElementKeys.plannedWorkout, live)
        day.journals = pick(rows, \.journals, prefix: DayElementKeys.journal, live)
        let anyPlan = rows.contains { $0.day.plannedMeals != nil }
        let plan = pickBy(rows, { $0.plannedMeals ?? [] }, key: { DayElementKeys.plannedMeal + $0.recipeID.uuidString }, live)
        day.plannedMeals = anyPlan ? plan : nil
        day.plannedRecipeIDs = pickBy(rows, \.plannedRecipeIDs, key: { DayElementKeys.plannedRecipe + $0.uuidString }, live)
        day.hygiene = Set(pickBy(rows, { Array($0.hygiene) }, key: { DayElementKeys.hygiene + $0.rawValue }, live))
        day.unknownHygieneTokens = pickBy(rows, \.unknownHygieneTokens, key: { DayElementKeys.hygieneToken + $0 }, live)
        day.completedPersonalCareTaskIDs = Set(pickBy(rows, { Array($0.completedPersonalCareTaskIDs) },
                                                      key: { DayElementKeys.task + $0 }, live))
        day.sleep = rows.first { $0.day.sleep != nil && live(DayElementKeys.sleep, in: $0) }?.day.sleep
        day.bottleCount = rows.first { $0.day.bottleCount > 0 && live(DayElementKeys.water, in: $0) }?.day.bottleCount ?? 0
        // Never synced (the storage strip nils it before any row write); the newest row's, as before.
        day.healthContext = rows.first { $0.day.healthContext != nil }?.day.healthContext
        return day
    }

    /// This device's new row for a day it writes: `incoming` (what the person's copy of the day now
    /// holds) with a stamp per element, plus tombstones for what they removed.
    ///
    /// - An element unchanged from this device's own row keeps that row's stamp, and one unchanged
    ///   from the merged winner keeps the winner's stamp — so re-saving a stale copy never outranks
    ///   another device's later edit or deletion of it.
    /// - A changed or new element gets a fresh stamp from `deviceKey`, later than every stamp known
    ///   for that key (a clock that went backwards still cannot lose an edit).
    /// - A key this copy was handed (`incoming.loadedSyncKeys`) or that this device's own row held
    ///   live, and that `incoming` no longer holds, is a deletion: a fresh tombstone when the element
    ///   is still live in the merge. A key the copy never held is left to the rows that hold it.
    /// - This device's earlier tombstones are carried forward unless `incoming` re-adds the key.
    static func ownRow(
        incoming: FernletDay, own: DayRowView?, merged: DayMerge?, deviceKey: String, now: Double
    ) throws -> DayRowPayload {
        let encoder = DayElementKeys.makeFingerprintEncoder()
        let incomingValues = try DayElementKeys.values(of: incoming, encoder: encoder)
        let ownValues = try own.map { try DayElementKeys.values(of: $0.day, encoder: encoder) } ?? [:]
        let mergedValues = try merged.map { try DayElementKeys.values(of: $0.day, encoder: encoder) } ?? [:]
        func fresh(_ key: String, removed: Bool) -> DayElementStamp {
            let known = [own?.stamps[key]?.at, merged?.winners[key]?.at].compactMap { $0 }.max() ?? 0
            return DayElementStamp(at: max(now, known + 0.001), by: deviceKey, removed: removed)
        }
        var stamps: [String: DayElementStamp] = [:]
        // R2: bounded by the elements of one day.
        for (key, value) in incomingValues {
            if let mine = own?.stamps[key], !mine.removed, ownValues[key] == value {
                stamps[key] = mine
            } else if let winner = merged?.winners[key], !winner.removed, mergedValues[key] == value {
                stamps[key] = winner
            } else {
                stamps[key] = fresh(key, removed: false)
            }
        }
        let ownLive = Set((own?.stamps ?? [:]).filter { !$0.value.removed && ownValues[$0.key] != nil }.keys)
        let removedKeys = (incoming.loadedSyncKeys ?? []).union(ownLive).subtracting(incomingValues.keys)
        for key in removedKeys where mergedValues[key] != nil {
            stamps[key] = fresh(key, removed: true)
        }
        for (key, stamp) in own?.stamps ?? [:] where stamp.removed && stamps[key] == nil {
            stamps[key] = stamp
        }
        var day = incoming
        day.loadedSyncKeys = nil
        return DayRowPayload(day: day, stamps: stamps)
    }

    private static func pick<Entry: Identifiable>(
        _ rows: [DayRowView], _ list: KeyPath<FernletDay, [Entry]>, prefix: String,
        _ live: (String, DayRowView) -> Bool
    ) -> [Entry] {
        pickBy(rows, { $0[keyPath: list] }, key: { prefix + "\($0.id)" }, live)
    }

    private static func pickBy<Element>(
        _ rows: [DayRowView], _ list: (FernletDay) -> [Element], key: (Element) -> String,
        _ live: (String, DayRowView) -> Bool
    ) -> [Element] {
        var seen = Set<String>()
        var out: [Element] = []
        // R2: bounded by the rows for one day × the elements each holds.
        for row in rows {
            for element in list(row.day) {
                let elementKey = key(element)
                guard !seen.contains(elementKey), live(elementKey, row) else { continue }
                seen.insert(elementKey)
                out.append(element)
            }
        }
        return out
    }
}
