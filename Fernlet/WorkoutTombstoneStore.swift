import Foundation

/// A small, persisted ring of workout ids that were removed locally while their app-authored Apple
/// Health sample might still have been in flight (a Fernlet log's Health save can land a couple of
/// seconds after logging — after the row was removed). It survives relaunch on purpose: the workout
/// observation anchor persists immediately, but the snapshot save is debounced, so a plain in-memory set
/// would be lost across the window that matters. The workout observer consults it so a resurrected orphan
/// sample — recognised by its `fernlet.workoutID` — is deleted-and-skipped instead of re-imported as a
/// new, untagged, unremovable Health row (which would reopen the guided double-log window).
///
/// Capped FIFO so it can't grow without bound; an entry is cleared as soon as the Health delete for it
/// confirms. A tombstone that never clears (the workout had no Health copy, e.g. logging authorized but
/// Health writes off) is harmless — it simply ages out.
final class WorkoutTombstoneStore {
    private let defaults: UserDefaults
    private let key: String
    private let cap: Int

    init(defaults: UserDefaults = .standard, key: String = "fernlet.workout.tombstones", cap: Int = 200) {
        self.defaults = defaults
        self.key = key
        self.cap = cap
    }

    private var ids: [String] {
        get { defaults.stringArray(forKey: key) ?? [] }
        set { defaults.set(newValue, forKey: key) }
    }

    func insert(_ id: UUID) {
        let token = id.uuidString
        var current = ids
        current.removeAll { $0 == token }   // move-to-end on re-insert so recency drives eviction
        current.append(token)
        if current.count > cap { current.removeFirst(current.count - cap) }
        ids = current
    }

    func contains(_ id: UUID) -> Bool {
        ids.contains(id.uuidString)
    }

    func remove(_ id: UUID) {
        let token = id.uuidString
        var current = ids
        guard current.contains(token) else { return }
        current.removeAll { $0 == token }
        ids = current
    }
}
