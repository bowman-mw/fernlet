import Foundation
import LocalPersistence
import FernletFoundation
import Observation
import FernletDomainModel

/// Holds the current derived-signal records and controls when they are rebuilt.
///
/// A thin `@MainActor` `@Observable` wrapper around the pure ``DerivedSignalsRebuilder``.
/// `FernletStore` owns one instance, calls ``rebuild(allDays:todayKey:isSickToday:)`` after
/// day-history mutations (and when today's unwell flag flips), and uses
/// ``scheduleDeferredRebuild(allDaysProvider:isSickTodayProvider:todayKey:)`` at launch so the
/// first (potentially large) rebuild runs at utility priority after startup instead of blocking
/// first render. The deferred rebuild is one-shot: `deferredStarted` latches on the first
/// schedule and never resets, and the pending closure nils itself before running so the rebuild
/// can never execute twice. ``flushDeferredRebuild()`` lets an early reader (or a test) force the
/// pending rebuild synchronously before the utility-priority task gets around to it.
///
/// Today's unwell flag is a REQUIRED input on both entry points, unlike the defaulted parameter on
/// the pure factory: it lives in settings, not on the day, so a call that forgot it would compute a
/// behaviour-only readiness and tell an unwell user they are ready for a hard session (spec §6a:
/// sickness always forces `"needs rest"`). The compiler, not a review, keeps every rebuild honest.
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
    /// `isSickToday` is today's unwell flag; see the type note for why it is required.
    public func rebuild(allDays: [String: FernletDay], todayKey: String, isSickToday: Bool) {
        StartupTiming.timed("FernletStore.rebuildDerivedSignals") {
            derivedSignals = DerivedSignalsRebuilder.rebuild(
                allDays: allDays,
                todayKey: todayKey,
                isSickToday: isSickToday
            )
        }
    }

    /// Schedules a low-priority rebuild after launch. Runs exactly once — later calls are ignored.
    /// `allDaysProvider` and `isSickTodayProvider` are evaluated at fire time (not capture time) so
    /// the rebuild sees the day history and the unwell flag as they stand when the utility-priority
    /// task finally runs. `todayKey`, by contrast, is captured at schedule time — acceptable because
    /// the deferred task fires moments after launch, well inside the same day.
    public func scheduleDeferredRebuild(
        allDaysProvider: @escaping @MainActor () -> [String: FernletDay],
        isSickTodayProvider: @escaping @MainActor () -> Bool,
        todayKey: String
    ) {
        guard !deferredStarted else { return }
        deferredStarted = true
        pendingDeferredRebuild = { [weak self] in
            guard let self else { return }
            self.pendingDeferredRebuild = nil
            self.rebuild(allDays: allDaysProvider(), todayKey: todayKey, isSickToday: isSickTodayProvider())
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
