// AIAnalysisRetryRecord.swift
// SPM carve-up: pure Codable retry-queue record carved DOWN out of the app-layer
// LocalFernletRepository.swift so the persistence layer (extracted next) can reference it without
// an upward edge. It is the element type of FernletSnapshot.retryQueue. Pure Foundation value type —
// no proximity / service / manager dependencies.

import Foundation

/// One queued retry of a failed AI meal analysis, persisted in the snapshot's retry queue.
///
/// The element type of `FernletSnapshot.retryQueue`: when an on-device analysis can't complete
/// (model unavailable, timeout), the app-side `AIRetryQueueService` appends one of these and replays
/// it on a later launch/foreground, bumping `attemptCount`/`lastAttemptAt` per try. Pure Foundation
/// value type so the persistence layer can hold it without an upward edge to any service.
public nonisolated struct AIAnalysisRetryRecord: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var payloadType: String
    public var sourceId: UUID
    /// Day the source meal was logged on (yyyy-MM-dd). Optional for backward-compatible decode of
    /// records written before this field existed; nil is treated as "today" by the retry path.
    public var dayKey: String?
    public var createdAt = Date()
    public var lastAttemptAt: Date?
    public var attemptCount = 0
    public var note: String

    public init(
        id: UUID = UUID(),
        payloadType: String,
        sourceId: UUID,
        dayKey: String? = nil,
        createdAt: Date = Date(),
        lastAttemptAt: Date? = nil,
        attemptCount: Int = 0,
        note: String
    ) {
        self.id = id
        self.payloadType = payloadType
        self.sourceId = sourceId
        self.dayKey = dayKey
        self.createdAt = createdAt
        self.lastAttemptAt = lastAttemptAt
        self.attemptCount = attemptCount
        self.note = note
    }
}
