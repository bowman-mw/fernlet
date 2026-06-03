import CryptoKit
import Foundation
import Testing
@testable import Fernlet

struct PrivateHistoryPruningTests {
    @Test func menstrualDeletionPrunesWithoutLeavingRecord() throws {
        let context = PrivatePersistenceController(inMemory: true).container.viewContext
        let repository = MenstrualNarrativeRepository(context: context)
        let contentKey = SymmetricKey(size: .bits256)
        let narrative = MenstrualNarrative(
            hkExternalUUID: UUID().uuidString,
            dateKey: "2026-06-01",
            note: "private"
        )

        try repository.insert(narrative, contentKey: contentKey)
        try repository.delete(id: narrative.id)

        #expect(try repository.narrative(forHKUUID: narrative.hkExternalUUID, contentKey: contentKey) == nil)
    }

    @Test func intimacyDeletionPrunesWithoutLeavingRecord() throws {
        let context = PrivatePersistenceController(inMemory: true).container.viewContext
        let repository = IntimacyLogRepository(context: context)
        let contentKey = SymmetricKey(size: .bits256)
        let log = IntimacyLog(eventDate: Date(), note: "private")

        try repository.insert(log, contentKey: contentKey)
        try repository.delete(id: log.id)

        #expect(try repository.logs(contentKey: contentKey).isEmpty)
    }
}
