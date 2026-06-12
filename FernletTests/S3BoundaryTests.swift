import Foundation
import Testing

struct S3BoundaryTests {
    private let aiFacingFiles = [
        "AIContextPayload.swift",
        "AIAuditLog.swift",
        "FoundationFoodSelection.swift",
        "LaunchPreparationService.swift",
        "MemoryAgent.swift"
    ]

    private let forbiddenPrivateStoreTokens = [
        "PrivatePersistenceController",
        "MenstrualNarrativeRepository",
        "JournalNarrativeRepository",
        "IntimacyLogRepository",
        "MenstrualNarrative",
        "JournalNarrative",
        "IntimacyLog"
    ]

    @Test func aiFacingSourcesCannotReachRawPrivateStoreTypes() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fernlet")

        for file in aiFacingFiles {
            let source = try String(contentsOf: sourceRoot.appendingPathComponent(file), encoding: .utf8)
            for token in forbiddenPrivateStoreTokens {
                #expect(
                    !source.contains(token),
                    "\(file) must consume typed filtered payloads, not private-store type \(token)"
                )
            }
        }
    }
}
