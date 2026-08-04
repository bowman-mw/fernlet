import Foundation
import Observation
import FernletDomainModel
import FernletFoundation
import FernletScoring

/// Holds the pending AI-analysis retry queue and enforces its dedupe, TTL, and eviction policy.
///
/// When on-device meal analysis fails, `FernletStore` queues the meal here via
/// ``queueMealRetry(_:dayKey:)``; the Food page surfaces ``mealPendingCount`` as its badge and its
/// "Retry oldest" button drains the queue through ``oldestMealRetry``. Unlike the per-row ledger
/// services in this module, the queue has no repository of its own — it is persisted inside the
/// snapshot blob (`FernletSnapshot.retryQueue`), so every user-visible mutation fires ``onChange``
/// (which `FernletStore` wires to ``SnapshotSaveCoordinator/schedule()``), while the restore/wipe
/// paths (``apply(_:)``, ``reset()``) deliberately do not.
///
/// The queue is multi-kind by design: each `AIAnalysisRetryRecord` carries a `payloadType` tag
/// (``mealPayloadType`` is the only kind today), and every meal-path operation — dedupe, badge
/// count, dispatch, eviction — is scoped to its own kind so a future workout/recipe/daily-summary
/// record can never be consumed or destroyed by the meal path. Capacity is bounded (20 records)
/// with a 14-day TTL age-out applied at enqueue time; a queue still full of fresh records evicts
/// the oldest record of the enqueuing kind and audit-logs the drop rather than failing silently.
///
/// Concurrency: `@MainActor` and `@Observable`; the injected `now` clock keeps the TTL
/// deterministic under test.
@MainActor
@Observable
public final class AIRetryQueueService {
    /// The pending retry records in append (oldest-first) order, across every payload kind.
    public private(set) var retryQueue: [AIAnalysisRetryRecord] = []

    /// Hard cap on queued records — reached only by genuinely pending retries, because the TTL
    /// age-out runs before the cap is checked.
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
    /// Fired after every user-visible mutation so the owner can schedule snapshot persistence.
    /// Mutable so `FernletStore` can wire it after all stored properties are initialized.
    @ObservationIgnored public var onChange: () -> Void = {}

    /// Creates the service.
    ///
    /// - Parameters:
    ///   - initial: The queue restored from the loaded snapshot.
    ///   - now: Clock used for the TTL age-out (injectable for tests).
    ///   - onChange: Persistence hook; usually rewired post-init via ``onChange``.
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

    /// Removes the record with the given queue-record id (any payload kind) and fires ``onChange``.
    public func clear(id: UUID) {
        retryQueue.removeAll { $0.id == id }
        onChange()
    }

    /// Removes every record queued for the given source object (e.g. a deleted meal's id, across
    /// all payload kinds) and fires ``onChange``.
    public func clearForSourceID(_ sourceID: UUID) {
        retryQueue.removeAll { $0.sourceId == sourceID }
        onChange()
    }

    /// Replaces the whole queue from a loaded snapshot WITHOUT firing ``onChange`` — the restore
    /// path must not schedule a save of the very state it just loaded.
    public func apply(_ queue: [AIAnalysisRetryRecord]) {
        retryQueue = queue
    }

    /// Empties the queue without firing ``onChange`` — the delete-everything path manages its own
    /// persistence (and cancels pending saves) itself.
    public func reset() {
        retryQueue = []
    }
}
