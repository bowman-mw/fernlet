import Foundation
import Observation
import FernletDomainModel
import FernletFoundation
import FernletScoring

@MainActor
@Observable
public final class AIRetryQueueService {
    public private(set) var retryQueue: [AIAnalysisRetryRecord] = []

    private static let maxQueueSize = 20
    /// Records older than this are aged out so long-abandoned retries don't permanently occupy slots.
    private static let recordTTL: TimeInterval = 14 * 24 * 60 * 60  // 14 days

    /// The `payloadType` tag written by `queueMealRetry` and the one the meal retry path consumes.
    /// The queue is intentionally multi-kind (the type invites workout/recipe/daily-summary records);
    /// the meal path must dispatch on this so it never consumes — or on a miss, destroys — a
    /// non-meal record. Future retry kinds add their own constant + accessor rather than widening
    /// this one.
    public static let mealPayloadType = "meal"

    @ObservationIgnored private let now: () -> Date
    // Mutable so FernletStore can wire it after all stored properties are initialized.
    @ObservationIgnored public var onChange: () -> Void = {}

    public init(initial: [AIAnalysisRetryRecord] = [], now: @escaping () -> Date = Date.init, onChange: @escaping () -> Void = {}) {
        self.retryQueue = initial
        self.now = now
        self.onChange = onChange
    }

    /// Total pending across every payload kind. Use `mealPendingCount` for the Food-page badge.
    public var pendingCount: Int { retryQueue.count }

    /// Count of pending *meal* retries only — the number the Food page surfaces. Scoping this keeps a
    /// non-meal record (which the Food "Retry oldest" button will never process) out of the badge.
    public var mealPendingCount: Int {
        retryQueue.reduce(into: 0) { $0 += ($1.payloadType == Self.mealPayloadType ? 1 : 0) }
    }

    /// The oldest pending meal retry, if any — the dispatch seam the meal retry path consumes.
    /// Non-meal records are skipped (and thus never cleared by the meal path). A future dispatcher
    /// adds sibling accessors (e.g. `oldestWorkoutRetry`) and routes on `payloadType`.
    public var oldestMealRetry: AIAnalysisRetryRecord? {
        retryQueue.first { $0.payloadType == Self.mealPayloadType }
    }

    /// Queue a meal-analysis retry. Future retry kinds (workout, recipe, daily-summary)
    /// should be added as new methods, not by overloading this one.
    public func queueMealRetry(_ meal: Meal, dayKey: String? = nil) {
        // Dedupe only against meal records: this method never re-enqueues a meal already pending.
        // Scoping to the meal kind keeps enqueue symmetric with the meal-scoped dispatch/eviction
        // so a future non-meal record sharing (impossibly) the same UUID can't suppress a meal.
        guard !retryQueue.contains(where: { $0.sourceId == meal.id && $0.payloadType == Self.mealPayloadType }) else { return }
        // Age out stale records first so the cap is reached only by genuinely-pending retries.
        let cutoff = now().addingTimeInterval(-Self.recordTTL)
        retryQueue.removeAll { $0.createdAt < cutoff }
        if retryQueue.count >= Self.maxQueueSize {
            // Still full of fresh records: evict to make room, but record it rather than dropping
            // silently. Prefer evicting the oldest *meal* record so a burst of meal failures can't
            // destroy a queued non-meal (workout/recipe/…) record — the meal enqueue path only ever
            // sheds its own kind. Fall back to the oldest overall only if no meal record exists.
            let evictIndex = retryQueue.firstIndex { $0.payloadType == Self.mealPayloadType } ?? retryQueue.startIndex
            let dropped = retryQueue.remove(at: evictIndex)
            FernletAuditLog.log("airetry.queue.evicted", context: ["sourceId": dropped.sourceId.uuidString])
        }
        retryQueue.append(AIAnalysisRetryRecord(
            payloadType: Self.mealPayloadType,
            sourceId: meal.id,
            dayKey: dayKey,
            note: FernletVoice.message(for: .mealAnalysisFailed)
        ))
        onChange()
    }

    public func clear(id: UUID) {
        retryQueue.removeAll { $0.id == id }
        onChange()
    }

    public func clearForSourceID(_ sourceID: UUID) {
        retryQueue.removeAll { $0.sourceId == sourceID }
        onChange()
    }

    public func apply(_ queue: [AIAnalysisRetryRecord]) {
        retryQueue = queue
    }

    public func reset() {
        retryQueue = []
    }
}
