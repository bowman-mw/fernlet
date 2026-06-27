//
//  SealedBackupChunkTests.swift
//  FernletTests
//
//  Covers the chunked period-backup hardening: the sealed-backup export no longer materializes the
//  whole menstrual-narrative history in memory. These exercise the pieces that are unit-testable
//  without iCloud — the repository's paged fetch, the chunk-position AEAD binding, and the
//  coordinator's multi-chunk restore writeback. The end-to-end seal -> CloudKit -> restoreChunks
//  round-trip lives in CloudKitDataServiceTests (it reuses the CloudKit mock there).
//

import CoreData
import FernletFoundation
import CryptoKit
import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

struct SealedBackupChunkTests {

    // MARK: - Repository paging

    @MainActor
    @Test func pagedNarrativesCoverHistoryWithoutOverlapOrGaps() throws {
        let key = SymmetricKey(size: .bits256)
        let repo = MenstrualNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext
        )
        let total = 7
        for index in 0..<total {
            let dateKey = String(format: "2026-01-%02d", index + 1)
            try repo.insert(
                MenstrualNarrative(hkExternalUUID: "uuid-\(index)", dateKey: dateKey, note: "note \(index)"),
                contentKey: key
            )
        }

        #expect(try repo.narrativeCount() == total)

        // Page through with a limit that doesn't divide the total evenly.
        let pageSize = 3
        var collected: [MenstrualNarrative] = []
        var offset = 0
        while true {
            let page = try repo.narratives(offset: offset, limit: pageSize, contentKey: key)
            if page.isEmpty { break }
            #expect(page.count <= pageSize)
            collected.append(contentsOf: page)
            offset += pageSize
        }

        #expect(collected.count == total)
        // No row appears twice and none is skipped: the union is exactly the full history.
        #expect(Set(collected.map(\.hkExternalUUID)) == Set((0..<total).map { "uuid-\($0)" }))
        // Pages come back in the declared stable order (dateKey ascending).
        #expect(collected.map(\.dateKey) == collected.map(\.dateKey).sorted())
    }

    @MainActor
    @Test func pagedNarrativesAreEmptyForZeroLimitOrLockedKey() throws {
        let key = SymmetricKey(size: .bits256)
        let repo = MenstrualNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext
        )
        try repo.insert(MenstrualNarrative(hkExternalUUID: "u", dateKey: "2026-01-01"), contentKey: key)

        #expect(try repo.narratives(offset: 0, limit: 0, contentKey: key).isEmpty)
        #expect(try repo.narratives(offset: 0, limit: 10, contentKey: nil).isEmpty)
    }

    // MARK: - Chunk-position authentication

    @MainActor
    @Test func chunkPositionIsAuthenticatedSoCiphertextCannotMove() throws {
        let serviceID = "com.fernlet.sealed-backup.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: serviceID) }
        let identity = IdentityService(keychainService: serviceID)
        try identity.ensureProvisioned()

        let plaintext = Data("page-zero".utf8)
        let record = try SealedBackupCrypto.seal(
            plaintext,
            payloadType: .periodData,
            identityService: identity,
            chunkIndex: 0,
            chunkCount: 3
        )

        // Same slot still opens.
        #expect(try SealedBackupCrypto.open(record, identityService: identity) == plaintext)

        // Re-labeling the chunk's position (substitution/reorder) breaks the GCM tag.
        var movedIndex = record
        movedIndex.chunkIndex = 1
        #expect(throws: SealedBackupError.malformedRecord) {
            try SealedBackupCrypto.open(movedIndex, identityService: identity)
        }

        // A chunk from a differently-sized generation also fails closed.
        var otherGeneration = record
        otherGeneration.chunkCount = 5
        #expect(throws: SealedBackupError.malformedRecord) {
            try SealedBackupCrypto.open(otherGeneration, identityService: identity)
        }
    }

    // MARK: - Coordinator multi-chunk restore writeback

    @MainActor
    @Test func applyRestoredChunksInsertsEveryPeriodChunk() throws {
        let store = makeTestStore()
        let key = SymmetricKey(size: .bits256)
        store.activateSealedJournals(contentKey: key)
        let repo = MenstrualNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext
        )

        let chunkA = try JSONEncoder().encode([
            MenstrualNarrative(hkExternalUUID: "a1", dateKey: "2026-06-01", note: "a1"),
            MenstrualNarrative(hkExternalUUID: "a2", dateKey: "2026-06-02", note: "a2")
        ])
        let chunkB = try JSONEncoder().encode([
            MenstrualNarrative(hkExternalUUID: "b1", dateKey: "2026-06-03", note: "b1")
        ])

        let count = try store.applyRestoredChunks(
            [chunkA, chunkB],
            payloadType: .periodData,
            narrativeRepository: repo
        )
        #expect(count == 3)
        #expect(try repo.narrativeCount() == 3)
    }

    @MainActor
    @Test func applyRestoredChunksThrowsWhenPeriodKeyLocked() throws {
        let store = makeTestStore() // no lock activated → no content key
        let chunk = try JSONEncoder().encode([
            MenstrualNarrative(hkExternalUUID: "a1", dateKey: "2026-06-01", note: "a1")
        ])
        #expect(throws: FernletStore.SealedBackupWiringError.self) {
            try store.applyRestoredChunks([chunk], payloadType: .periodData)
        }
    }

    @MainActor
    @Test func applyRestoredChunksConcatenatesSensitiveNotes() throws {
        let store = makeTestStore()
        let chunkA = try JSONEncoder().encode([
            TierTwoMemoryRecord(category: "consistency", text: "Steady.", state: "steady")
        ])
        let chunkB = try JSONEncoder().encode([
            TierTwoMemoryRecord(category: "recovery", text: "Gentle.", state: "present")
        ])

        let count = try store.applyRestoredChunks([chunkA, chunkB], payloadType: .sensitiveNotes)
        #expect(count == 2)
        #expect(Set(store.tierTwoMemories.map(\.category)) == ["consistency", "recovery"])
    }
}
