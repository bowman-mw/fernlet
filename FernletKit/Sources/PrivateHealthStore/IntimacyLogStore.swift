import CryptoKit
import FernletFoundation
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
/// The Sealed backup is the second client (added 2026-08-10 with the `intimacyLogs` payload; on the
/// v2 engine since the journal and intimacy Sealed backup v2 design 2026-09-30, unit B2). It works
/// through the APP'S ONE instance — `ContentView`'s, handed to the backup coordinator at launch
/// wiring — never a second one of its own, so every write any surface makes moves the same mutation
/// hook. See the sealed-backup seam at the bottom of this type, where each member documents whether
/// it is gated and why.
///
/// **Mutation hook (design 2026-09-30, §4.4).** After every call that changed something on disk — an
/// insert, a Health link recorded, a delete-all or batch delete that removed rows, a restore merge
/// that changed anything — the installed hook runs (``attachMutationHook(_:)``). The app wires it to
/// mark the intimacy backup's upload owed (never its enabled switch), so the next Private visit
/// re-exports.
///
/// `isVisible` is injected as a closure (this store is a leaf with no access to settings) and read
/// lazily, so a toggle mid-session takes effect on the very next call — including a flip while the log
/// sheet is still open, which `insert()` then refuses (closing that write race). It defaults to
/// fail-CLOSED (`{ false }`): a store nobody wired must read and write nothing. `ContentView` installs
/// the real derived closure through `attachVisibilityGate(_:)` in its launch task, next to the period
/// store's, before any load runs — the property itself is read-only from outside.
@MainActor
public final class IntimacyLogStore {
    /// The sealed persistence layer this funnel gates; the only object allowed to touch it.
    private let repository: IntimacyLogRepository

    /// Fail-closed hard gate. See `PeriodTrackerStore.isVisible` — same contract, same reasoning,
    /// including R6: readable everywhere, installed only through ``attachVisibilityGate(_:)``.
    public private(set) var isVisible: () -> Bool = { false }

    /// Runs after every call that changed something on disk; installed only through
    /// ``attachMutationHook(_:)``. Nothing by default.
    private var onMutation: @MainActor () -> Void = {}

    /// Installs the visibility gate. Called by the app's launch wiring (and again, with the same
    /// derived verdict, when the Sealed backup coordinator is handed this instance), before anything
    /// reads or writes; until then the store refuses.
    ///
    /// - Parameter gate: The derived visibility verdict, re-read on every call.
    public func attachVisibilityGate(_ gate: @escaping () -> Bool) {
        isVisible = gate
    }

    /// Installs the mutation hook (see the type's documentation).
    ///
    /// - Parameter hook: Runs after every call that changed something on disk.
    public func attachMutationHook(_ hook: @escaping @MainActor () -> Void) {
        onMutation = hook
    }

    /// Creates the funnel over a sealed repository.
    ///
    /// - Parameter repository: The sealed CRUD layer; defaults to one on the shared private store.
    ///   Tests inject a repository backed by an in-memory context.
    public init(repository: IntimacyLogRepository = IntimacyLogRepository()) {
        self.repository = repository
    }

    /// The newest sealed intimacy logs, newest first (bounded by the repository's display cap, R3) —
    /// or `[]` while hidden, in which case nothing is decrypted.
    public func logs(contentKey: SymmetricKey?) throws -> [IntimacyLog] {
        guard isVisible() else { return [] }
        return try repository.logs(contentKey: contentKey)
    }

    /// R5/R3: longest note this funnel will seal, mirroring the 1000-character cap the cycle side
    /// applies at the equivalent seam (`PeriodTrackerStore.logEvent`). Unbounded text would otherwise
    /// spill into the store's `_SUPPORT` external-blob directory and into every sealed-backup chunk.
    /// The repository's own constant, so a restored note is capped at exactly the same length.
    public static let maxNoteLength = IntimacyLogRepository.maxNoteLength

    /// Seals a new intimacy log. Refuses while hidden: closes the race where the derived gate flips to
    /// hidden while the log sheet is still open (the save then throws instead of sealing a new row).
    /// The note is trimmed and capped at ``maxNoteLength`` characters before sealing.
    public func insert(_ log: IntimacyLog, contentKey: SymmetricKey?) throws {
        guard isVisible() else { throw IntimacyTrackingHiddenError() }
        var bounded = log
        bounded.note = String(
            log.note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNoteLength)
        )
        try repository.insert(bounded, contentKey: contentKey)
        onMutation()
    }

    /// Records a HealthKit external UUID on an already-saved log. Metadata only (it never decrypts or
    /// re-seals the note), so it is not gated — the row it updates only exists because a visible
    /// `insert()` created it.
    public func markSavedToHealthKit(id: UUID, externalUUID: UUID) throws {
        try repository.markSavedToHealthKit(id: id, externalUUID: externalUUID)
        onMutation()
    }

    /// Drops every stored log WITHOUT decrypting, so it works while locked and while hidden. Ungated on
    /// purpose: hiding must never block the "delete everything" wipe. The mutation hook runs when rows
    /// were removed (counted keyless first).
    public func deleteAll() throws {
        let hadRows = try repository.logCount() > 0
        try repository.deleteAll()
        if hadRows { onMutation() }
    }

    // MARK: - Sealed-backup seam

    // The app's `SealedBackupCoordinator` reaches intimacy data through THIS funnel, not through a raw
    // `IntimacyLogRepository` — the wiring `SensitiveSurfaceGateTests` greps the app target for. Which
    // members are gated is the whole design, so each says why.

    /// Whether this install has ever written an intimacy log — the one-way divergence latch. Since the
    /// Sealed backup v2 it is read once, as the seed of the app's intimacy restore marker, so an
    /// install that already held (or deleted) logs never merges a stale cloud copy back in.
    ///
    /// **Ungated on purpose.** It reads a device-local boolean (backfilled from a row count) and
    /// decrypts nothing. Gating it would make a hidden store answer "never populated", which is the
    /// hidden-means-empty bug: the marker would then be seeded unresolved and a later restore would
    /// merge the cloud copy back in behind the user's deletes.
    public var hasEverStoredLog: Bool { repository.hasEverStoredLog }

    /// Clears the divergence latch behind ``hasEverStoredLog`` — see
    /// `IntimacyLogRepository.clearDivergenceLatch()` for when that is legitimate.
    ///
    /// **Ungated**, like the latch it clears: it touches one device-local boolean and decrypts
    /// nothing, and the callers (the app's new-key check, the app-lock reset funnel) run while the
    /// hub is closed and whatever the visibility.
    public func clearDivergenceLatch() {
        repository.clearDivergenceLatch()
    }

    /// Total stored logs, counted without decrypting (or faulting in) any row.
    ///
    /// **Ungated for the same reason as ``hasEverStoredLog``** — a hidden store reading as 0 would be
    /// the hidden-means-empty bug ("the entries this iPhone can't open" check counts with it).
    public func backupLogCount() throws -> Int {
        try repository.logCount()
    }

    /// Every stored id, in the store's total order — the Sealed backup export's snapshot.
    ///
    /// **Ungated**: it decrypts nothing, and the engine's own gates run before it.
    public func allIDs() throws -> [UUID] {
        try repository.allIDs()
    }

    /// Whether the sealed store is attached and loaded — false for a controller whose store failed to
    /// load (it keeps running against an empty coordinator) or is mid-rebuild. The Sealed backup engine
    /// requires it before every snapshot and restore write, so a storeless controller can never export
    /// an empty set over the cloud copy (design 2026-09-30, R2-F2). Keyless and ungated.
    public var isStoreHealthy: Bool { repository.isStoreHealthy }

    /// One Sealed backup export chunk: the logs with these snapshot ids, classified.
    ///
    /// **Gated**, and throws rather than answering empty: ``IntimacyTrackingHiddenError`` while hidden
    /// and `FernletLockError.locked` without a key. This decrypts every note it touches, and an empty
    /// chunk is a legitimate answer (every id in it was deleted mid-export) — a hidden or keyless one
    /// that answered empty would be indistinguishable from it and write a short set over the cloud copy.
    ///
    /// - Parameter ids: At most `IntimacyLogRepository.maxPageSize` ids.
    public func backupChunk(ids: [UUID], contentKey: SymmetricKey?) throws -> IntimacyLogPage {
        guard isVisible() else { throw IntimacyTrackingHiddenError() }
        guard contentKey != nil else { throw FernletLockError.locked }
        return try repository.logs(ids: ids, contentKey: contentKey)
    }

    /// A Sealed backup restore: the id-keyed merge (``IntimacyLogRepository/upsertMerged(_:contentKey:)``
    /// — insert absent ids, keep every row that opens and only fill its missing Health link, replace
    /// dead ones, never delete). Runs the mutation hook when anything changed.
    ///
    /// **Gated**, matching ``insert(_:contentKey:)``: a restore seals plaintext into the store, so it
    /// must not run behind the visibility gate — hidden throws ``IntimacyTrackingHiddenError`` and the
    /// restore waits for the user to un-hide. Never writes HealthKit (restoring is not a user save).
    public func restoreMerging(_ logs: [IntimacyLog], contentKey: SymmetricKey?) throws -> IntimacyLogMergeResult {
        guard isVisible() else { throw IntimacyTrackingHiddenError() }
        let result = try repository.upsertMerged(logs, contentKey: contentKey)
        if result.changedAnything { onMutation() }
        return result
    }

    /// Runs `body` only while the seam is open — throws ``IntimacyTrackingHiddenError`` while hidden
    /// — so the Sealed backup engine's decrypt of an intimacy BACKUP chunk (its head probe, E2, its
    /// restore) happens behind this funnel's own gate, in the same synchronous step as the check
    /// (design 2026-09-30, §4.1, §8.1, R1-BR-12). Nothing is read from the store here: `body` is the
    /// caller's decrypt of cloud ciphertext.
    public func withBackupSeam<T>(_ body: () throws -> T) throws -> T {
        guard isVisible() else { throw IntimacyTrackingHiddenError() }
        return try body()
    }

    /// Deletes these logs without decrypting them — "Remove them" for logs that can never open.
    /// Ungated: hiding never blocks deletion. Runs the mutation hook when rows were removed.
    ///
    /// - Returns: How many rows were removed.
    public func delete(ids: [UUID]) throws -> Int {
        let removed = try repository.delete(ids: ids)
        if removed > 0 { onMutation() }
        return removed
    }
}
