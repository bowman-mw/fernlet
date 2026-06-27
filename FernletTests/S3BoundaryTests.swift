import Foundation
import Testing
import FernletDomainModel

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
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        func locate(_ filename: String) -> URL? {
            for root in [repoRoot.appendingPathComponent("Fernlet"),
                         repoRoot.appendingPathComponent("FernletKit/Sources")] {
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
                for case let url as URL in enumerator where url.lastPathComponent == filename {
                    return url
                }
            }
            return nil
        }

        for file in aiFacingFiles {
            guard let url = locate(file) else {
                Issue.record("could not locate AI-facing source \(file)")
                continue
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            for token in forbiddenPrivateStoreTokens {
                #expect(
                    !source.contains(token),
                    "\(file) must consume typed filtered payloads, not private-store type \(token)"
                )
            }
        }
    }
}
