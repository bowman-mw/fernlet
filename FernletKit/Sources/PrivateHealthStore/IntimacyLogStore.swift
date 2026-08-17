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
/// The sealed-backup coordinator is the second client (added 2026-08-10 with the `intimacyLogs`
/// payload) and builds its OWN instance wired to the same derived gate — see the sealed-backup seam
/// at the bottom of this type, where each member documents whether it is gated and why.
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

    /// Installs the visibility gate. Called by the app's launch wiring and by the sealed-backup
    /// coordinator on its own instance, before anything reads or writes; until then the store refuses.
    ///
    /// - Parameter gate: The derived visibility verdict, re-read on every call.
    public func attachVisibilityGate(_ gate: @escaping () -> Bool) {
        isVisible = gate
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
    public static let maxNoteLength = 1_000

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

    // MARK: - Sealed-backup seam

    // The app's `SealedBackupCoordinator` reaches intimacy data through THIS funnel, not through a raw
    // `IntimacyLogRepository` — the wiring `SensitiveSurfaceGateTests` greps the app target for. Which
    // members are gated is the whole design, so each says why.

    /// Whether this install has ever written an intimacy log — the one-way divergence latch the
    /// sealed-backup restore consults so it can never resurrect logs the user deleted.
    ///
    /// **Ungated on purpose.** It reads a device-local boolean (backfilled from a row count) and
    /// decrypts nothing. Gating it would make a hidden store answer "never populated", which is the
    /// hidden-means-empty bug: a restore would then happily write the cloud copy in behind the gate.
    public var hasEverStoredLog: Bool { repository.hasEverStoredLog }

    /// Total stored logs, counted without decrypting (or faulting in) any row.
    ///
    /// **Ungated for the same reason as ``hasEverStoredLog``** — and additionally because the
    /// sealed-backup re-upload guard uses it to refuse exporting from an empty store; a hidden store
    /// reading as 0 there would let a re-upload overwrite the user's cloud backup with an empty one.
    public func backupLogCount() throws -> Int {
        try repository.logCount()
    }

    /// One page of logs for the sealed-backup export, in a stable total order.
    ///
    /// **Gated**, and throws rather than returning `[]`: this decrypts every note it touches, so it is
    /// a decrypt seam. Returning empty while hidden would be worse than throwing — the export writes a
    /// head record even for zero records, so a silent empty page would REPLACE the user's cloud backup
    /// with nothing. The caller checks visibility first; this is the backstop that makes a regression
    /// there loud instead of destructive.
    public func backupPage(offset: Int, limit: Int, contentKey: SymmetricKey?) throws -> [IntimacyLog] {
        guard isVisible() else { throw IntimacyTrackingHiddenError() }
        return try repository.logs(offset: offset, limit: limit, contentKey: contentKey)
    }

    /// Writes a restored batch of logs in ONE all-or-nothing transaction (sealed-backup restore).
    ///
    /// **Gated**, matching ``insert(_:contentKey:)``: a restore seals plaintext into the store, so it
    /// must not run behind the visibility gate. A hidden restore therefore fails and is retried once
    /// the user un-hides, rather than quietly repopulating a surface the app is presenting as off.
    public func restore(_ logs: [IntimacyLog], contentKey: SymmetricKey?) throws {
        guard isVisible() else { throw IntimacyTrackingHiddenError() }
        try repository.insertAtomically(logs, contentKey: contentKey)
    }
}
