import CoreData
import CryptoKit
import Testing
import FernletDomainModel
import PrivateStoreCore
@testable import Fernlet

@Suite(.serialized)
struct PrivateEncryptedRepositoryRecoveryTests {
    @Test func intimacyLogsSkipRowsEncryptedWithDestroyedKey() throws {
        let controller = PrivatePersistenceController(inMemory: true)
        let repository = IntimacyLogRepository(context: controller.container.viewContext)
        let destroyedKey = SymmetricKey(size: .bits256)
        let currentKey = SymmetricKey(size: .bits256)
        let oldLog = IntimacyLog(
            eventDate: Date(timeIntervalSince1970: 1_779_664_800),
            note: "Old unrecoverable note"
        )
        let currentLog = IntimacyLog(
            eventDate: Date(timeIntervalSince1970: 1_779_751_200),
            note: "Current note"
        )

        try repository.insert(oldLog, contentKey: destroyedKey)
        try repository.insert(currentLog, contentKey: currentKey)

        let logs = try repository.logs(contentKey: currentKey)

        #expect(logs.map(\.id) == [currentLog.id])
        #expect(logs.first?.note == "Current note")
    }

    @MainActor @Test func menstrualNarrativesSkipRowsEncryptedWithDestroyedKey() throws {
        let controller = PrivatePersistenceController(inMemory: true)
        let repository = MenstrualNarrativeRepository(context: controller.container.viewContext)
        let destroyedKey = SymmetricKey(size: .bits256)
        let currentKey = SymmetricKey(size: .bits256)
        let oldNarrative = MenstrualNarrative(
            hkExternalUUID: UUID().uuidString,
            dateKey: "2026-05-10",
            note: "Old unrecoverable narrative",
            symptomFlags: [.cramps],
            customSymptomScales: ["fatigue": 3]
        )
        let currentNarrative = MenstrualNarrative(
            hkExternalUUID: UUID().uuidString,
            dateKey: "2026-05-11",
            note: "Current narrative",
            symptomFlags: [.headache],
            customSymptomScales: ["energy": 7]
        )
        let interval = DateInterval(
            start: Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 10))!,
            end: Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 11))!
        )

        try repository.insert(oldNarrative, contentKey: destroyedKey)
        try repository.insert(currentNarrative, contentKey: currentKey)

        let narratives = try repository.narratives(in: interval, contentKey: currentKey)

        #expect(narratives.map(\.id) == [currentNarrative.id])
        #expect(narratives.first?.note == "Current narrative")
        #expect(throws: (any Error).self) { _ = try repository.narrative(forHKUUID: oldNarrative.hkExternalUUID, contentKey: currentKey) }
    }
}
