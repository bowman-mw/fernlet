import Foundation

/// A small, persisted ring of workout ids that were removed locally while their app-authored Apple
/// Health sample might still have been in flight.
///
/// A Fernlet log's Health save can land a couple of seconds after logging — after the row was
/// removed. It survives relaunch on purpose: the workout observation anchor persists immediately,
/// but the snapshot save is debounced, so a plain in-memory set would be lost across the window that
/// matters. The workout observer consults it so a resurrected orphan sample — recognised by its
/// `fernlet.workoutID` — is deleted-and-skipped instead of re-imported as a new, untagged,
/// unremovable Health row (which would reopen the guided double-log window).
///
/// Capped FIFO so it can't grow without bound; an entry is cleared as soon as the Health delete for it
/// confirms. A tombstone that never clears (the workout had no Health copy, e.g. logging authorized but
/// Health writes off) is harmless — it simply ages out.
///
/// - Important: Backed by `UserDefaults` with unsynchronized read-modify-write mutations — the type
///   itself provides no locking or actor isolation, so callers serialize access (in practice the
///   main-actor store/observer path).
final class WorkoutTombstoneStore {
    private let defaults: UserDefaults
    private let key: String
    private let cap: Int

    /// - Parameters:
    ///   - defaults: The backing defaults store (injectable for tests).
    ///   - key: The defaults key the ring persists under.
    ///   - cap: Maximum number of retained ids before FIFO eviction.
    init(defaults: UserDefaults = .standard, key: String = "fernlet.workout.tombstones", cap: Int = 200) {
        self.defaults = defaults
        self.key = key
        self.cap = cap
    }

    /// The persisted ring, oldest first — read fresh from defaults on every access.
    private var ids: [String] {
        get { defaults.stringArray(forKey: key) ?? [] }
        set { defaults.set(newValue, forKey: key) }
    }

    /// Records a removed workout id, moving it to the recent end and evicting the oldest past `cap`.
    func insert(_ id: UUID) {
        let token = id.uuidString
        var current = ids
        current.removeAll { $0 == token }   // move-to-end on re-insert so recency drives eviction
        current.append(token)
        if current.count > cap { current.removeFirst(current.count - cap) }
        ids = current
    }

    /// Whether the id is tombstoned — the workout observer's "delete-and-skip, don't re-import" check.
    func contains(_ id: UUID) -> Bool {
        ids.contains(id.uuidString)
    }

    /// Clears a tombstone once the Health delete for it has confirmed. No-op if absent.
    func remove(_ id: UUID) {
        let token = id.uuidString
        var current = ids
        guard current.contains(token) else { return }
        current.removeAll { $0 == token }
        ids = current
    }
}
