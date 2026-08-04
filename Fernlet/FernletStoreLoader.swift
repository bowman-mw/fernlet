import Foundation
import Observation
import FernletDomainModel

/// The observable launch state machine that loads ``FernletStore`` off the first frame.
///
/// Owned by ``FernletApp`` and driven from the scene's `.task`: `startIfNeeded()` runs
/// `FernletStore.load` (async Core Data snapshot + per-row service loads) exactly once per
/// process, streaming human-readable progress into `statusMessage` for `LaunchScreen`, then opens
/// the bundled food catalog and kicks the detached best-effort sealed-backup restore before
/// flipping `phase` to `.ready`. A thrown load lands in `.failed`, which `LaunchFailureView`
/// surfaces with a `retry()` that resets the one-shot guard and runs the pipeline again.
/// @MainActor + @Observable: all state is main-actor UI state.
@MainActor
@Observable
final class FernletStoreLoader {
    /// The three launch states ``FernletApp`` switches its scene content on.
    ///
    /// `.preparing` renders the launch screen, `.ready` carries the loaded ``FernletStore`` into
    /// the main content, and `.failed` carries the error `LaunchFailureView` surfaces with a retry.
    enum Phase {
        case preparing
        case ready(FernletStore)
        case failed(Error)
    }

    /// Current launch state; starts `.preparing` and only ever advances via `loadStore`/`retry`.
    private(set) var phase: Phase = .preparing
    /// The progress line `LaunchScreen` shows while `phase == .preparing`.
    private(set) var statusMessage: String = LaunchPreparationService.initialStatusMessage

    @ObservationIgnored private var didStart = false

    /// Starts the load exactly once per process; safe to call from a re-fired `.task`.
    func startIfNeeded() async {
        guard !didStart else { return }
        didStart = true
        await loadStore()
    }

    /// Resets the one-shot guard and status, returns to `.preparing`, and re-runs the load.
    func retry() async {
        didStart = false
        phase = .preparing
        statusMessage = LaunchPreparationService.initialStatusMessage
        await startIfNeeded()
    }

    private func loadStore() async {
        do {
            let store = try await FernletStore.load { [weak self] message in
                self?.statusMessage = message
            }
            statusMessage = "Loading food catalog..."
            await store.loadBundledFoodItemsForLaunch()
            statusMessage = "Getting Fernlet ready..."
            phase = .ready(store)
            // Pull any sealed iCloud backup into local stores on a fresh install. Detached and
            // best-effort so a slow/absent CloudKit fetch never delays launch; restored data
            // surfaces as soon as it lands (and retries next launch on failure).
            Task { await store.restoreSealedBackupsIfNeeded() }
        } catch {
            phase = .failed(error)
        }
    }
}
