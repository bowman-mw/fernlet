import Foundation
import LocalPersistence
import FernletFoundation
import Observation
import FernletDomainModel

/// Holds the current derived-signal records and controls when they are rebuilt.
///
/// A thin `@MainActor` `@Observable` wrapper around the pure ``DerivedSignalsRebuilder``.
/// `FernletStore` owns one instance, calls ``rebuild(allDays:todayKey:)`` after day-history
/// mutations, and uses ``scheduleDeferredRebuild(allDaysProvider:todayKey:)`` at launch so the
/// first (potentially large) rebuild runs at utility priority after startup instead of blocking
/// first render. The deferred rebuild is one-shot: `deferredStarted` latches on the first
/// schedule and never resets, and the pending closure nils itself before running so the rebuild
/// can never execute twice. ``flushDeferredRebuild()`` lets an early reader (or a test) force the
/// pending rebuild synchronously before the utility-priority task gets around to it.
@MainActor
@Observable
public final class DerivedSignalsService {
    /// The most recently rebuilt signal records (empty until the first rebuild runs).
    public private(set) var derivedSignals: [DerivedSignalRecord] = []

    /// One-shot latch: set on the first `scheduleDeferredRebuild` call and never reset, so the
    /// deferred launch rebuild can only ever be scheduled once per service lifetime.
    @ObservationIgnored private var deferredStarted = false
    /// The not-yet-run deferred rebuild; it nils itself as its first act so a racing
    /// `flushDeferredRebuild()` and the utility-priority task can't both execute it.
    @ObservationIgnored private var pendingDeferredRebuild: (@MainActor () -> Void)?

    public init() {}

    /// Rebuilds the signals synchronously from `allDays`, timed under the startup profiler.
    public func rebuild(allDays: [String: FernletDay], todayKey: String) {
        StartupTiming.timed("FernletStore.rebuildDerivedSignals") {
            derivedSignals = DerivedSignalsRebuilder.rebuild(
                allDays: allDays,
                todayKey: todayKey
            )
        }
    }

    /// Schedules a low-priority rebuild after launch. Runs exactly once — later calls are ignored.
    /// `allDaysProvider` is evaluated at fire time (not capture time) so the rebuild sees the day
    /// history as it stands when the utility-priority task finally runs. `todayKey`, by contrast,
    /// is captured at schedule time — acceptable because the deferred task fires moments after
    /// launch, well inside the same day.
    public func scheduleDeferredRebuild(
        allDaysProvider: @escaping @MainActor () -> [String: FernletDay],
        todayKey: String
    ) {
        guard !deferredStarted else { return }
        deferredStarted = true
        pendingDeferredRebuild = { [weak self] in
            guard let self else { return }
            self.pendingDeferredRebuild = nil
            self.rebuild(allDays: allDaysProvider(), todayKey: todayKey)
        }
        Task(priority: .utility) { [weak self] in
            await Task.yield()
            await MainActor.run {
                self?.flushDeferredRebuild()
            }
        }
    }

    /// Runs the deferred rebuild now if one is still pending; otherwise a no-op.
    public func flushDeferredRebuild() {
        pendingDeferredRebuild?()
    }
}
