// TierTwoMemoryRecord.swift
// SPM carve-up: pure Codable tier-two memory record carved DOWN out of the app-layer
// LocalFernletRepository.swift so the persistence layer (extracted next) can reference it without
// an upward edge. Referenced by the FernletRepository protocol, MemoryAgent, and others. Pure
// Foundation value type — no proximity / service / manager dependencies. The custom
// init(from decoder:) preserves backward-compatible decode of records missing newer fields.

import Foundation

/// A distilled "tier two" behavioral memory the memory pipeline extracted from recent data.
///
/// Referenced by the `FernletRepository` protocol and the app-layer MemoryAgent; a change in
/// `state` (the key behavioral verdict) triggers a NEW record rather than mutating this one, and
/// `active` retires superseded records. The custom decode keeps records written before newer fields
/// existed loading cleanly.
public nonisolated struct TierTwoMemoryRecord: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var category: String
    public var text: String
    public var state: String = ""             // key behavioral verdict; change triggers a new record
    public var evidence: String = ""
    public var confidence: String = "medium"  // "low", "medium", "high"
    public var extractedDate = Date()
    public var active = true
    public var dataWindowDays: Int = 14

    public init(
        category: String,
        text: String,
        state: String = "",
        evidence: String = "",
        confidence: String = "medium",
        dataWindowDays: Int = 14
    ) {
        self.category = category
        self.text = text
        self.state = state
        self.evidence = evidence
        self.confidence = confidence
        self.dataWindowDays = dataWindowDays
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        category = try container.decode(String.self, forKey: .category)
        text = try container.decode(String.self, forKey: .text)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        confidence = try container.decodeIfPresent(String.self, forKey: .confidence) ?? "medium"
        extractedDate = try container.decodeIfPresent(Date.self, forKey: .extractedDate) ?? Date()
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? true
        dataWindowDays = try container.decodeIfPresent(Int.self, forKey: .dataWindowDays) ?? 14
    }
}
