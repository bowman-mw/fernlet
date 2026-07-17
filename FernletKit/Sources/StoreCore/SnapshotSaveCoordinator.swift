import Combine
import Foundation
import FernletDomainModel
import FernletFoundation
import FernletPersistence

@MainActor
public final class SnapshotSaveCoordinator {
    private let repository: FernletRepository
    private let debounce: Duration
    private let buildSnapshot: @MainActor () -> SanitizedSnapshot
    private let onAfterSave: @MainActor () -> Void

    private var snapshotSaveTask: Task<Void, Never>?
    private var remoteReloadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    public init(
        repository: FernletRepository,
        debounce: Duration = .seconds(1),
        buildSnapshot: @escaping @MainActor () -> SanitizedSnapshot,
        onAfterSave: @escaping @MainActor () -> Void
    ) {
        self.repository = repository
        self.debounce = debounce
        self.buildSnapshot = buildSnapshot
        self.onAfterSave = onAfterSave
    }

    public func schedule() {
        snapshotSaveTask?.cancel()
        let debounce = debounce
        snapshotSaveTask = Task { [weak self] in
            try? await ContinuousClock().sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.snapshotSaveTask = nil
                self.performSnapshotSave()
            }
        }
    }

    public func flushPending() {
        guard snapshotSaveTask != nil else { return }
        snapshotSaveTask?.cancel()
        snapshotSaveTask = nil
        performSnapshotSave()
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
    public func cancelPending() {
        snapshotSaveTask?.cancel()
        snapshotSaveTask = nil
        remoteReloadTask?.cancel()
        remoteReloadTask = nil
    }

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

    private func performSnapshotSave() {
        let saved = repository.saveSnapshot(buildSnapshot())
        if !saved {
            FernletAuditLog.log("snapshot.save.failed", context: [:])
        }
        onAfterSave()
    }

    private func scheduleRemoteRepositoryReload(
        debounce: Duration,
        handler: @escaping @MainActor () async -> Void
    ) {
        remoteReloadTask?.cancel()
        remoteReloadTask = Task { [weak self] in
            try? await ContinuousClock().sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.remoteReloadTask = nil
            }
            await handler()
        }
    }
}
