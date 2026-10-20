// WorkoutLocation+Weights.swift
// FernletDomainModel
//
// The synced shape of each location's "Weights I have" (``WorkoutWeightInventory``). It rides at the
// TOP LEVEL of the settings blob as one key, `workoutLocationWeights`, mapping a location's id to its
// entry:
//
//     "workoutLocationWeights": {
//       "0A1B2C3D-…": { "unit": "lb", "dumbbells": [5, 10, 15, 20, 25],
//                       "kettlebells": [35], "barWeight": 45, "platePairs": [10, 25, 45, 45] }
//     }
//
// The key is written only when some location has weights, so a blob without any keeps its old shape.
// Reading is tolerant end to end: a value of the wrong kind or out of range is skipped, a key this build
// does not know is parked on the entry and written back, an entry whose unit this build cannot read is
// kept verbatim on its location (``WorkoutLocation/unreadableWeights``), and an entry for a location
// that no longer exists is dropped.

import Foundation

extension WorkoutWeightInventory {

    /// The entry's own wire keys. FROZEN: they persist in the synced settings blob.
    enum WireKey: String, CaseIterable {
        case unit, dumbbells, kettlebells, barWeight, platePairs
    }

    /// An inventory read from its synced value, or nil when this build cannot read it: not an object,
    /// or a unit token this build does not know (the caller keeps such an entry verbatim).
    static func decoded(from value: JSONValue) -> WorkoutWeightInventory? {
        guard case .object(let entry) = value,
              case .string(let token)? = entry[WireKey.unit.rawValue],
              let unit = LoadUnit(rawValue: token) else { return nil }
        var inventory = WorkoutWeightInventory(unit: unit)
        inventory.setDumbbells(numbers(entry[WireKey.dumbbells.rawValue]))
        for weight in numbers(entry[WireKey.kettlebells.rawValue]).prefix(maxKettlebells) {
            inventory.addKettlebell(weight)
        }
        if let bar = number(entry[WireKey.barWeight.rawValue]) {
            inventory.setBar(bar)
            inventory.adoptPlatePairs(numbers(entry[WireKey.platePairs.rawValue]))
        }
        let known = Set(WireKey.allCases.map(\.rawValue))
        for key in entry.keys.sorted() where !known.contains(key) && inventory.parkedUnknownKeys.count < maxParkedKeys {
            inventory.parkedUnknownKeys[key] = entry[key]
        }
        return inventory
    }

    /// The synced value: the unit, every non-empty list, the bar when set, then the parked keys.
    var wireValue: JSONValue {
        var entry = parkedUnknownKeys
        entry[WireKey.unit.rawValue] = .string(unit.rawValue)
        if !dumbbells.isEmpty { entry[WireKey.dumbbells.rawValue] = .array(dumbbells.map(JSONValue.number)) }
        if !kettlebells.isEmpty { entry[WireKey.kettlebells.rawValue] = .array(kettlebells.map(JSONValue.number)) }
        if let barWeight {
            entry[WireKey.barWeight.rawValue] = .number(barWeight)
            if !platePairs.isEmpty { entry[WireKey.platePairs.rawValue] = .array(platePairs.map(JSONValue.number)) }
        }
        return .object(entry)
    }

    /// Plate pairs as stored (one entry per pair), sanitized and bounded but not deduplicated.
    mutating func adoptPlatePairs(_ values: [Double]) {
        let kept = values.prefix(Self.maxDecodedValues).compactMap(Self.cleaned)
        platePairs = Array(kept.prefix(Self.maxPlatePairs)).sorted()
    }

    /// The numbers of a JSON array (integers or decimals), at most ``maxDecodedValues``; anything
    /// else reads as none.
    static func numbers(_ value: JSONValue?) -> [Double] {
        guard case .array(let items)? = value else { return [] }
        return items.prefix(maxDecodedValues).compactMap { number($0) }
    }

    /// A JSON number as a `Double` (an integer or a decimal); nil for anything else.
    static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .integer(let whole)?: Double(whole)
        case .number(let decimal)?: decimal
        default: nil
        }
    }
}

extension WorkoutLocation {

    /// Most entries a decode walks (R2): far past ``FernletSettings/maxWorkoutLocations``.
    static let maxWeightEntries = 64

    /// Gives each location its weights from the settings blob's `workoutLocationWeights` value,
    /// matched by id. Entries this build can't read stay verbatim on their location; an entry for no
    /// location is dropped; anything but an object reads as no weights at all.
    static func adoptWeights(from value: JSONValue?, into locations: inout [WorkoutLocation]) {
        guard case .object(let entries)? = value else { return }
        var byID: [UUID: JSONValue] = [:]
        for key in entries.keys.sorted().prefix(maxWeightEntries) {
            guard let id = UUID(uuidString: key), let entry = entries[key] else { continue }
            byID[id] = entry
        }
        for index in locations.indices {
            guard let entry = byID[locations[index].id] else { continue }
            if let inventory = WorkoutWeightInventory.decoded(from: entry) {
                locations[index].weights = inventory
            } else {
                locations[index].unreadableWeights = entry
            }
        }
    }

    /// The `workoutLocationWeights` value for `locations`: each location with weights (or an entry
    /// this build couldn't read) by its id; empty when none has any, and then the key is not written.
    static func weightsValue(for locations: [WorkoutLocation]) -> [String: JSONValue] {
        var entries: [String: JSONValue] = [:]
        for location in locations {
            if !location.weights.isEmpty || !location.weights.parkedUnknownKeys.isEmpty {
                entries[location.id.uuidString] = location.weights.wireValue
            } else if let unreadable = location.unreadableWeights {
                entries[location.id.uuidString] = unreadable
            }
        }
        return entries
    }
}
