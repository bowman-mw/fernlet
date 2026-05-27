import Foundation
import Observation

@MainActor
@Observable
final class DerivedSignalsService {
    private(set) var derivedSignals: [DerivedSignalRecord] = []

    @ObservationIgnored private var deferredStarted = false

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
        allDaysProvider: @escaping () -> [String: FernletDay],
        todayKey: String
    ) {
        guard !deferredStarted else { return }
        deferredStarted = true
        Task(priority: .utility) { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.rebuild(allDays: allDaysProvider(), todayKey: todayKey)
        }
    }
}
