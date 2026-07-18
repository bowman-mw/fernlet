import CryptoKit
import Foundation

/// Thrown when an intimacy write is attempted while intimacy tracking is hidden. Mirrors
/// `PeriodTrackingHiddenError`: the UI suppresses the affordance while hidden, so reaching this means a
/// caller bypassed the gate — a programmer error surfaced as a throw rather than a user-facing state.
public nonisolated struct IntimacyTrackingHiddenError: Error, Equatable {
    public init() {}
}

/// The `@MainActor` funnel for every intimacy sealed-note read/write. Plays the role `PeriodTrackerStore`
/// plays for cycle data: the HARD visibility gate lives HERE, at the decrypt/seal seam, rather than in a
/// `View` body. Intimacy logs are read on ambient paths (the calendar's `.task`, a sheet dismiss) that a
/// UI-level `if` would hide the surface for while the plaintext kept flowing behind it — the exact
/// pattern the privacy invariant forbids.
///
/// While `isVisible()` is false the store is INERT: `logs()` returns `[]` (no decrypt happens) and
/// `insert()` throws (no seal happens). Deletes are deliberately NOT gated, so hiding never blocks a
/// wipe — mirroring `IntimacyLogRepository.deleteAll()`, which deletes rows without decrypting them.
///
/// `isVisible` is injected as a closure (this store is a leaf with no access to settings) and read
/// lazily, so a toggle mid-session takes effect on the very next call — including a flip while the log
/// sheet is still open, which `insert()` then refuses (closing that write race). It defaults to
/// fail-CLOSED (`{ false }`): a store nobody wired must read and write nothing. `ContentView` wires the
/// real derived closure in its launch task, next to `periodStore.isVisible`, before any load runs.
@MainActor
public final class IntimacyLogStore {
    private let repository: IntimacyLogRepository

    /// Fail-closed hard gate. See `PeriodTrackerStore.isVisible` — same contract, same reasoning.
    public var isVisible: () -> Bool = { false }

    public init(repository: IntimacyLogRepository = IntimacyLogRepository()) {
        self.repository = repository
    }

    /// Sealed intimacy logs, newest first — or `[]` while hidden, in which case nothing is decrypted.
    public func logs(contentKey: SymmetricKey?) throws -> [IntimacyLog] {
        guard isVisible() else { return [] }
        return try repository.logs(contentKey: contentKey)
    }

    /// Seals a new intimacy log. Refuses while hidden: closes the race where the derived gate flips to
    /// hidden while the log sheet is still open (the save then throws instead of sealing a new row).
    public func insert(_ log: IntimacyLog, contentKey: SymmetricKey?) throws {
        guard isVisible() else { throw IntimacyTrackingHiddenError() }
        try repository.insert(log, contentKey: contentKey)
    }

    /// Records a HealthKit external UUID on an already-saved log. Metadata only (it never decrypts or
    /// re-seals the note), so it is not gated — the row it updates only exists because a visible
    /// `insert()` created it.
    public func markSavedToHealthKit(id: UUID, externalUUID: UUID) throws {
        try repository.markSavedToHealthKit(id: id, externalUUID: externalUUID)
    }

    /// Drops every stored log WITHOUT decrypting, so it works while locked and while hidden. Ungated on
    /// purpose: hiding must never block the "delete everything" wipe.
    public func deleteAll() throws {
        try repository.deleteAll()
    }
}
