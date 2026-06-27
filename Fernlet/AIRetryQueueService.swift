import Foundation
import Observation
import FernletDomainModel
import FernletFoundation
import FernletScoring

@MainActor
@Observable
final class AIRetryQueueService {
    private(set) var retryQueue: [AIAnalysisRetryRecord] = []

    private static let maxQueueSize = 20
    /// Records older than this are aged out so long-abandoned retries don't permanently occupy slots.
    private static let recordTTL: TimeInterval = 14 * 24 * 60 * 60  // 14 days

    @ObservationIgnored private let now: () -> Date
    // Mutable so FernletStore can wire it after all stored properties are initialized.
    @ObservationIgnored var onChange: () -> Void = {}

    init(initial: [AIAnalysisRetryRecord] = [], now: @escaping () -> Date = Date.init, onChange: @escaping () -> Void = {}) {
        self.retryQueue = initial
        self.now = now
        self.onChange = onChange
    }

    var pendingCount: Int { retryQueue.count }

    /// Queue a meal-analysis retry. Future retry kinds (workout, recipe, daily-summary)
    /// should be added as new methods, not by overloading this one.
    func queueMealRetry(_ meal: Meal, dayKey: String? = nil) {
        guard !retryQueue.contains(where: { $0.sourceId == meal.id }) else { return }
        // Age out stale records first so the cap is reached only by genuinely-pending retries.
        let cutoff = now().addingTimeInterval(-Self.recordTTL)
        retryQueue.removeAll { $0.createdAt < cutoff }
        if retryQueue.count >= Self.maxQueueSize {
            // Still full of fresh records: evict the oldest, but record it rather than dropping silently.
            let dropped = retryQueue.removeFirst()
            FernletAuditLog.log("airetry.queue.evicted", context: ["sourceId": dropped.sourceId.uuidString])
        }
        retryQueue.append(AIAnalysisRetryRecord(
            payloadType: "meal",
            sourceId: meal.id,
            dayKey: dayKey,
            note: FernletVoice.message(for: .mealAnalysisFailed)
        ))
        onChange()
    }

    func clear(id: UUID) {
        retryQueue.removeAll { $0.id == id }
        onChange()
    }

    func clearForSourceID(_ sourceID: UUID) {
        retryQueue.removeAll { $0.sourceId == sourceID }
        onChange()
    }

    func apply(_ queue: [AIAnalysisRetryRecord]) {
        retryQueue = queue
    }

    func reset() {
        retryQueue = []
    }
}
