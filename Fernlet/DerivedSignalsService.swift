import Foundation
import Observation

@MainActor
@Observable
final class DerivedSignalsService {
    private(set) var derivedSignals: [DerivedSignalRecord] = []

    @ObservationIgnored private var deferredStarted = false
    @ObservationIgnored private var pendingDeferredRebuild: (@MainActor () -> Void)?

    func rebuild(allDays: [String: FernletDay], todayKey: String) {
        StartupTiming.timed("FernletStore.rebuildDerivedSignals") {
            derivedSignals = DerivedSignalsRebuilder.rebuild(
                allDays: allDays,
                todayKey: todayKey
            )
        }
    }

    /// Schedules a low-priority rebuild after launch. Runs exactly once.
    func scheduleDeferredRebuild(
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

    func flushDeferredRebuild() {
        pendingDeferredRebuild?()
    }
}
