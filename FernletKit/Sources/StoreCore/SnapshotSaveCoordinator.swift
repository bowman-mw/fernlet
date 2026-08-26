import Combine
import Foundation
import FernletDomainModel
import FernletFoundation
import FernletPersistence

/// Debounces snapshot persistence for the whole app state, and debounces remote-change reloads
/// coming back from the repository.
///
/// `FernletStore` (and `DiaryStore` through its injected hook) funnels every "state changed,
/// persist it" signal through ``schedule()``. After the debounce window (1 second by default) the
/// coordinator invokes the injected `buildSnapshot` closure AT FIRE TIME on the main actor — the
/// write always serializes current state, never state captured when the save was scheduled — and
/// hands the resulting `SanitizedSnapshot` (the privacy-stripped aggregate that is the ONLY input
/// `FernletRepository.saveSnapshot` accepts) to the repository. A failed save is audit-logged
/// (`snapshot.save.failed`) and `onAfterSave` still runs with the durable-write result, so callers
/// can keep retry-safe bookkeeping while publishing external mirrors only after a real save.
///
/// The reverse direction: when the repository also conforms to `RemoteChangePublishingRepository`
/// (the CloudKit-backed one does), ``subscribeRemote(remoteReloadDebounce:handler:)`` coalesces its
/// remote-change notifications so a burst of CloudKit imports triggers one reload, not many.
///
/// A pending save has exactly three exits: the debounce elapses and it fires; ``flushPending()``
/// forces it immediately; or ``cancelPending()`` drops it unwritten — the delete-everything path,
/// where the promised save must be broken so it cannot resurrect just-purged rows.
///
/// Concurrency: `@MainActor` but deliberately not `@Observable` — it holds no UI-facing state.
/// Debounce timers are `Task`s sleeping on `ContinuousClock`; rescheduling cancels the prior task,
/// so only the newest schedule survives.
@MainActor
public final class SnapshotSaveCoordinator {
    private let repository: FernletRepository
    private let debounce: Duration
    /// Invoked on the main actor at save-fire time to serialize the CURRENT app state.
    private let buildSnapshot: @MainActor () -> SanitizedSnapshot
    /// Runs after every save attempt, carrying whether it reached durable persistence.
    private let onAfterSave: @MainActor (Bool) -> Void

    /// The single pending debounced save, if any — rescheduling cancels and replaces it, so at most
    /// one save is ever in flight.
    private var snapshotSaveTask: Task<Void, Never>?
    /// The single pending debounced remote-change reload, if any — same newest-wins replacement.
    private var remoteReloadTask: Task<Void, Never>?
    /// Retains the remote-change publisher subscription for the coordinator's lifetime.
    private var cancellables = Set<AnyCancellable>()

    /// Creates the coordinator.
    ///
    /// - Parameters:
    ///   - repository: The active persistence backend (local JSON or Core Data + CloudKit).
    ///   - debounce: How long a scheduled save waits for further mutations before firing.
    ///   - buildSnapshot: Called at fire time, on the main actor, to mint the sanitized snapshot.
    ///   - onAfterSave: Post-save hook, run whether or not the write succeeded with its result.
    public init(
        repository: FernletRepository,
        debounce: Duration = .seconds(1),
        buildSnapshot: @escaping @MainActor () -> SanitizedSnapshot,
        onAfterSave: @escaping @MainActor (Bool) -> Void
    ) {
        self.repository = repository
        self.debounce = debounce
        self.buildSnapshot = buildSnapshot
        self.onAfterSave = onAfterSave
    }

    /// (Re)starts the debounced save — the newest call wins, cancelling any earlier pending save,
    /// so a burst of mutations coalesces into a single write of the final state.
    public func schedule() {
        snapshotSaveTask?.cancel()
        let debounce = debounce
        snapshotSaveTask = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(for: debounce)
            } catch {
                return  // cancelled during the debounce window — a newer schedule() owns this save
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.snapshotSaveTask = nil
                self.performSnapshotSave()
            }
        }
    }

    /// Fires the pending save immediately, if one is scheduled; a no-op otherwise (unlike the
    /// per-row services there is no failed-write queue here — no scheduled task means nothing to
    /// write). Called when the app is about to lose its chance to save (backgrounding, teardown).
    @discardableResult public func flushPending() -> Bool {
        guard snapshotSaveTask != nil else { return true }
        snapshotSaveTask?.cancel()
        snapshotSaveTask = nil
        return performSnapshotSave()
    }

    /// Drops a pending debounced save WITHOUT writing it — the delete-everything counterpart to
    /// `flushPending`. A scheduled save is a promise to serialize `buildSnapshot()` one second from now;
    /// during a wipe that promise must be broken, not kept, or the save lands after the purge and
    /// re-creates the very rows (and CloudKit records) the purge just removed.
    ///
    /// This does not merely fix an ordering nicety. `buildSnapshot` runs at FIRE time, so a save
    /// scheduled before the wipe happens to serialize post-wipe (empty) state today — the store looks
    /// safe by accident. Cancelling makes the invariant explicit instead of emergent, so moving to an
    /// eager snapshot capture can't silently turn a wipe back into a resurrection.
    ///
    /// Also cancels any pending debounced remote-change reload for the same reason: a reload firing
    /// mid-wipe would repopulate in-memory state from rows the purge is in the middle of removing.
    public func cancelPending() {
        snapshotSaveTask?.cancel()
        snapshotSaveTask = nil
        remoteReloadTask?.cancel()
        remoteReloadTask = nil
    }

    /// Subscribes to the repository's remote-change publisher, when it has one, debouncing bursts
    /// of change notifications into a single `handler` invocation. A repository without
    /// `RemoteChangePublishingRepository` conformance (the local JSON one) makes this a no-op.
    public func subscribeRemote(
        remoteReloadDebounce: Duration = .milliseconds(750),
        handler: @escaping @MainActor () async -> Void
    ) {
        guard let remoteRepository = repository as? any RemoteChangePublishingRepository else { return }
        remoteRepository.remoteChangePublisher
            .sink { [weak self] in
                self?.scheduleRemoteRepositoryReload(
                    debounce: remoteReloadDebounce,
                    handler: handler
                )
            }
            .store(in: &cancellables)
    }

    /// Mints the sanitized snapshot NOW and writes it, audit-logging a failed save before running
    /// `onAfterSave` unconditionally with the result.
    @discardableResult private func performSnapshotSave() -> Bool {
        let saved = repository.saveSnapshot(buildSnapshot())
        if !saved {
            FernletAuditLog.log("snapshot.save.failed", context: [:])
        }
        onAfterSave(saved)
        return saved
    }

    /// Debounces the remote-reload handler — each fresh remote-change notification cancels the
    /// prior pending reload and restarts the window.
    private func scheduleRemoteRepositoryReload(
        debounce: Duration,
        handler: @escaping @MainActor () async -> Void
    ) {
        remoteReloadTask?.cancel()
        remoteReloadTask = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(for: debounce)
            } catch {
                // Cancelled — a newer remote change, or `cancelPending()` during a delete-everything
                // wipe, owns this reload. Returning here states that contract at the site.
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.remoteReloadTask = nil
            }
            await handler()
        }
    }
}
