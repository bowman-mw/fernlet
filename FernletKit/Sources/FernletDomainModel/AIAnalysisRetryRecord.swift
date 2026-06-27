// AIAnalysisRetryRecord.swift
// SPM carve-up: pure Codable retry-queue record carved DOWN out of the app-layer
// LocalFernletRepository.swift so the persistence layer (extracted next) can reference it without
// an upward edge. It is the element type of FernletSnapshot.retryQueue. Pure Foundation value type —
// no proximity / service / manager dependencies.

import Foundation

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
