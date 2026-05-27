import Foundation
import Observation

@MainActor
@Observable
final class AIRetryQueueService {
    private(set) var retryQueue: [AIAnalysisRetryRecord] = []

    // Mutable so FernletStore can wire it after all stored properties are initialized.
    @ObservationIgnored var onChange: () -> Void = {}

    init(initial: [AIAnalysisRetryRecord] = [], onChange: @escaping () -> Void = {}) {
        self.retryQueue = initial
        self.onChange = onChange
    }

    var pendingCount: Int { retryQueue.count }

    /// Queue a meal-analysis retry. Future retry kinds (workout, recipe, daily-summary)
    /// should be added as new methods, not by overloading this one.
    func queueMealRetry(_ meal: Meal) {
        retryQueue.append(AIAnalysisRetryRecord(
            payloadType: "meal",
            sourceId: meal.id,
            note: FernletVoice.message(for: .mealAnalysisFailed)
        ))
        onChange()
    }

    func clear(id: UUID) {
        retryQueue.removeAll { $0.id == id }
        onChange()
    }

    func apply(_ queue: [AIAnalysisRetryRecord]) {
        retryQueue = queue
    }

    func reset() {
        retryQueue = []
    }
}
