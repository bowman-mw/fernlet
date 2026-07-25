import Foundation
import Testing
import AIContext
import FernletDomainModel
import FernletPersistence
import LocalPersistence
@testable import Fernlet

/// Covers the device-local AI audit log (Ladder §7.2): the new `modelIdentifier` / `outcome` fields,
/// the ring-buffer cap, tolerant enum parking, cross-relaunch persistence, and the invariants that keep
/// the log OFF the synced/exported paths and swept by delete-all.
///
/// Serialized + `@MainActor`: the store-touching tests stand up a real `FernletStore` (process-level
/// state) exactly like `DeleteAllDataTests`.
@MainActor
@Suite(.serialized)
struct AIAuditLogTests {

    // MARK: - Helpers

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    private func entry(
        payloadKind: String,
        destination: AIDestination = .onDeviceFoundationModels,
        modelIdentifier: String? = AIAuditEntry.onDeviceFoundationModel,
        outcome: AIAuditOutcome = .succeeded,
        memoryChars: Int = 0
    ) -> AIAuditEntry {
        AIAuditEntry(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            payloadKind: payloadKind,
            destination: destination,
            modelIdentifier: modelIdentifier,
            outcome: outcome,
            includedFields: ["sourceHost", "charCount"],
            memorySummaryCharCount: memoryChars
        )
    }

    private func isoCoders() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }

    /// In-memory sink that captures what the actor saves (for cap / clear / configure assertions).
    private final class MockAuditSink: AIAuditLogPersisting, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [AIAuditEntry] = []
        private var seed: [AIAuditEntry] = []
        init(seed: [AIAuditEntry] = []) { self.seed = seed }
        func load() -> [AIAuditEntry] { lock.lock(); defer { lock.unlock() }; return seed }
        func save(_ entries: [AIAuditEntry]) { lock.lock(); defer { lock.unlock() }; stored = entries }
        @discardableResult
        func clear() -> Bool { lock.lock(); defer { lock.unlock() }; stored = []; seed = []; return true }
        var savedCount: Int { lock.lock(); defer { lock.unlock() }; return stored.count }
        var savedFirstKind: String? { lock.lock(); defer { lock.unlock() }; return stored.first?.payloadKind }
        var isCleared: Bool { lock.lock(); defer { lock.unlock() }; return stored.isEmpty && seed.isEmpty }
    }

    // MARK: - Entry round-trip with the new fields

    @Test func entryRoundTripPreservesModelIdentifierAndOutcome() throws {
        let (enc, dec) = isoCoders()
        let original = entry(payloadKind: "recipe.extract", outcome: .schemaFailed, memoryChars: 42)
        let decoded = try dec.decode(AIAuditEntry.self, from: try enc.encode(original))
        #expect(decoded.payloadKind == "recipe.extract")
        #expect(decoded.destination == .onDeviceFoundationModels)
        #expect(decoded.modelIdentifier == AIAuditEntry.onDeviceFoundationModel)
        #expect(decoded.outcome == .schemaFailed)
        #expect(decoded.includedFields == ["sourceHost", "charCount"])
        #expect(decoded.memorySummaryCharCount == 42)
        #expect(decoded.id == original.id)
    }

    @Test func entryRoundTripAllowsNilModelIdentifier() throws {
        let (enc, dec) = isoCoders()
        let original = entry(payloadKind: "web.lookup", destination: .webNutritionLookup,
                             modelIdentifier: nil, outcome: .succeeded)
        let decoded = try dec.decode(AIAuditEntry.self, from: try enc.encode(original))
        #expect(decoded.modelIdentifier == nil)
        #expect(decoded.destination == .webNutritionLookup)
    }

    // MARK: - Tolerant enum parking (unknown destination / outcome from a future build)

    @Test func unknownDestinationAndOutcomeTokensFreezeAndParkWithoutThrowing() throws {
        // A JSON entry written by a newer build carrying raw values THIS build doesn't know. It must
        // decode (never throw), freeze both enums to their floor default, and PARK the true tokens so a
        // re-upgrade re-adopts them and a settings UI can still surface the truth.
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111",
         "timestamp":"2026-07-24T00:00:00Z",
         "payloadKind":"future.kind",
         "destination":"quantumRelay2099",
         "outcome":"partiallyRefused",
         "includedFields":["a"],
         "memorySummaryCharCount":3}
        """
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(AIAuditEntry.self, from: Data(json.utf8))
        #expect(decoded.destination == .onDeviceFoundationModels)
        #expect(decoded.destinationParkedToken == "quantumRelay2099")
        #expect(decoded.outcome == AIAuditOutcome.freezeDefault)
        #expect(decoded.outcomeParkedToken == "partiallyRefused")

        // Re-encoding keeps the parked tokens alive AND writes a known raw value on the main key (so a
        // strict older build can still decode the re-save).
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let reencoded = String(decoding: try enc.encode(decoded), as: UTF8.self)
        #expect(reencoded.contains("quantumRelay2099"))
        #expect(reencoded.contains("partiallyRefused"))
        #expect(reencoded.contains("onDeviceFoundationModels"))
    }

    @Test func aSingleUnknownEntryDoesNotFailTheWholeArray() throws {
        let json = """
        [
         {"id":"22222222-2222-2222-2222-222222222222","timestamp":"2026-07-24T00:00:00Z",
          "payloadKind":"ok","destination":"onDeviceFoundationModels","outcome":"succeeded",
          "includedFields":[],"memorySummaryCharCount":0},
         {"id":"33333333-3333-3333-3333-333333333333","timestamp":"2026-07-24T00:00:00Z",
          "payloadKind":"future","destination":"someFutureRung","outcome":"someFutureOutcome",
          "includedFields":[],"memorySummaryCharCount":0}
        ]
        """
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode([AIAuditEntry].self, from: Data(json.utf8))
        #expect(decoded.count == 2)
        #expect(decoded[1].destinationParkedToken == "someFutureRung")
    }

    // MARK: - Ring buffer: cap + FIFO (the actor)

    @Test func actorCapsAtEntryLimitAndPrunesOldestFirst() async {
        let sink = MockAuditSink()
        let log = AIAuditLog()
        await log.configure(sink: sink)
        let overflow = 12
        for i in 0..<(AIAuditLog.entryLimit + overflow) {
            await log.record(payloadKind: "k\(i)", destination: .onDeviceFoundationModels, includedFields: [])
        }
        let entries = await log.entries
        #expect(entries.count == AIAuditLog.entryLimit)
        // FIFO: the first `overflow` records were dropped; oldest surviving is k<overflow>.
        #expect(entries.first?.payloadKind == "k\(overflow)")
        #expect(entries.last?.payloadKind == "k\(AIAuditLog.entryLimit + overflow - 1)")
        // The sink received the same capped array on the last save.
        #expect(sink.savedCount == AIAuditLog.entryLimit)
        #expect(sink.savedFirstKind == "k\(overflow)")
    }

    @Test func recordPassesModelIdentifierAndOutcomeThrough() async {
        let sink = MockAuditSink()
        let log = AIAuditLog()
        await log.configure(sink: sink)
        await log.record(payloadKind: "k", destination: .onDeviceFoundationModels,
                         modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
                         includedFields: ["x"], memorySummaryCharCount: 7, outcome: .fellBack)
        let e = await log.entries.first
        #expect(e?.modelIdentifier == AIAuditEntry.onDeviceFoundationModel)
        #expect(e?.outcome == .fellBack)
        #expect(e?.memorySummaryCharCount == 7)
    }

    // MARK: - Error → outcome classifier (guardrail refusal is a reachable outcome, not schemaFailed)

    @Test func modelErrorMapperClassifiesCancellationAndGenericErrors() {
        // A cancelled task threw nothing usable → the caller falls back.
        #expect(AIAuditOutcome.fromModelError(CancellationError()) == .fellBack)
        // Any other (non-guardrail) error is a schema / resolution failure. Guardrail refusals map to
        // `.refused`, but `LanguageModelSession.GenerationError.guardrailViolation` is not constructible
        // off-device in a unit test — the classifier's guardrail arm is exercised on-device.
        struct Boom: Error {}
        #expect(AIAuditOutcome.fromModelError(Boom()) == .schemaFailed)
        let ns = NSError(domain: "test", code: 7)
        #expect(AIAuditOutcome.fromModelError(ns) == .schemaFailed)
    }

    // MARK: - configure adopts persisted history; clear sweeps memory + sink

    @Test func configureAdoptsPersistedHistory() async {
        let sink = MockAuditSink(seed: [entry(payloadKind: "survived-relaunch")])
        let log = AIAuditLog()
        await log.configure(sink: sink)
        #expect(await log.entries.count == 1)
        #expect(await log.entries.first?.payloadKind == "survived-relaunch")
    }

    @Test func configureMergesPreConfigureSessionEntriesWithPersistedHistory() async {
        // An AI call can record BEFORE the unstructured configure Task runs (sink still nil). Those
        // session entries must be merged with — not overwritten by — the persisted history, and
        // re-persisted so the next relaunch keeps them.
        let sink = MockAuditSink(seed: [entry(payloadKind: "persisted")])
        let log = AIAuditLog()
        await log.record(payloadKind: "pre-configure", destination: .onDeviceFoundationModels, includedFields: [])
        await log.configure(sink: sink)
        let kinds = await log.entries.map(\.payloadKind)
        #expect(kinds.contains("persisted"))
        #expect(kinds.contains("pre-configure"))
        #expect(kinds.count == 2)
        // Persisted history stays oldest-first ahead of the newer session entry.
        #expect(kinds.first == "persisted")
        // The merged set was re-persisted (pending was non-empty), so it survives another load.
        #expect(sink.savedCount == 2)
    }

    @Test func configureIsIdempotentAndDoesNotDuplicateEntriesOnSecondCall() async {
        // A second configure (e.g. the two FernletStore inits) reloads the same file; dedupe-by-id keeps
        // each entry once rather than doubling the log.
        let seedEntry = entry(payloadKind: "seed")
        let sink = MockAuditSink(seed: [seedEntry])
        let log = AIAuditLog()
        await log.configure(sink: sink)
        await log.configure(sink: sink)
        let ids = await log.entries.map(\.id)
        #expect(ids == [seedEntry.id])
    }

    @Test func clearEmptiesMemoryAndSink() async {
        let sink = MockAuditSink(seed: [entry(payloadKind: "a")])
        let log = AIAuditLog()
        await log.configure(sink: sink)
        await log.record(payloadKind: "b", destination: .onDeviceFoundationModels, includedFields: [])
        await log.clear()
        #expect(await log.entries.isEmpty)
        #expect(sink.isCleared)
    }

    // MARK: - File sink: persistence across relaunch + cap

    @Test func fileStorePersistsAcrossReload() {
        let url = tempURL("audit-persist")
        let writer = FileAIAuditLogStore(fileURL: url)
        writer.save([entry(payloadKind: "one", outcome: .refused),
                     entry(payloadKind: "two", outcome: .succeeded, memoryChars: 9)])
        // A fresh instance over the same file — the relaunch case.
        let reader = FileAIAuditLogStore(fileURL: url)
        let loaded = reader.load()
        #expect(loaded.count == 2)
        #expect(loaded.first?.payloadKind == "one")
        #expect(loaded.first?.outcome == .refused)
        #expect(loaded.last?.memorySummaryCharCount == 9)
    }

    @Test func fileStoreCapsToEntryLimitFIFOOnLoad() {
        let url = tempURL("audit-cap")
        let store = FileAIAuditLogStore(fileURL: url)
        let many = (0..<(AIAuditLog.entryLimit + 20)).map { entry(payloadKind: "k\($0)") }
        store.save(many)
        let loaded = FileAIAuditLogStore(fileURL: url).load()
        #expect(loaded.count == AIAuditLog.entryLimit)
        // The tail is kept (FIFO prune of the oldest).
        #expect(loaded.first?.payloadKind == "k20")
        #expect(loaded.last?.payloadKind == "k\(AIAuditLog.entryLimit + 19)")
    }

    @Test func fileStoreClearEmptiesTheLogAndReportsSuccess() {
        let url = tempURL("audit-clear")
        let store = FileAIAuditLogStore(fileURL: url)
        store.save([entry(payloadKind: "x")])
        #expect(!store.load().isEmpty)
        #expect(store.clear() == true, "clear should report success when it removed the file")
        #expect(store.load().isEmpty)
        // A second clear finds no file — that is a clean sweep, not a failure (the delete-all funnel
        // clears the sink directly AND via the actor, so the redundant removal must not report failure).
        #expect(store.clear() == true, "clear should report success when there was nothing to remove")
    }

    @Test func fileStoreToleratesMissingAndCorruptFile() {
        // Missing file → empty, never a throw.
        let missing = FileAIAuditLogStore(fileURL: tempURL("audit-missing"))
        #expect(missing.load().isEmpty)
        // Garbage bytes → empty, never a throw.
        let url = tempURL("audit-corrupt")
        try? Data("not json".utf8).write(to: url)
        #expect(FileAIAuditLogStore(fileURL: url).load().isEmpty)
    }

    // MARK: - OFF the synced / exported paths

    @Test func absentFromFernletSnapshotEncode() throws {
        let snapshot = FernletSnapshot(
            todayKey: "2026-07-24",
            day: FernletDay(date: "2026-07-24"),
            settings: FernletSettings(),
            recentMeals: [],
            previousJournals: [],
            memories: [],
            goals: [],
            workshop: WorkshopData()
        )
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).lowercased()
        // Audit-unique field names must never appear in the synced blob. `memorysummarycharcount` and
        // `payloadkind` are ALWAYS encoded on an `AIAuditEntry` (not `encodeIfPresent`-omitted like the
        // nil-able parked tokens / modelIdentifier), so their absence is the load-bearing canary that
        // no audit entry can even be named by the snapshot type; the compile-time layering is the real
        // guarantee, and these assertions witness it.
        #expect(!json.contains("memorysummarycharcount"))
        #expect(!json.contains("payloadkind"))
        #expect(!json.contains("modelidentifier"))
        #expect(!json.contains("outcomeparkedtoken"))
        #expect(!json.contains("destinationparkedtoken"))
    }

    @Test func absentFromDataExportEvenWhenTheLogIsPopulated() throws {
        // A populated audit log must not bleed into the plaintext data export — the export is an
        // allowlist projection, so audit metadata is excluded by construction.
        let auditURL = tempURL("audit-export")
        let sink = FileAIAuditLogStore(fileURL: auditURL)
        sink.save([entry(payloadKind: "recipe.extract", outcome: .schemaFailed)])
        let store = FernletStore(
            repository: LocalFernletRepository(fileURL: tempURL("export-db")),
            aiAuditLogStore: sink
        )
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let json = String(decoding: try enc.encode(store.buildDataExport()), as: UTF8.self).lowercased()
        #expect(!json.contains("modelidentifier"))
        #expect(!json.contains("schemafailed"))
        #expect(!json.contains("foundation-models"))
        #expect(!json.contains("recipe.extract"))
    }

    // MARK: - Cleared by delete-all-data

    @Test func deleteAllDataClearsTheAuditLog() async {
        let auditURL = tempURL("audit-wipe")
        let sink = FileAIAuditLogStore(fileURL: auditURL)
        sink.save([entry(payloadKind: "before-wipe"), entry(payloadKind: "before-wipe-2")])
        #expect(!sink.load().isEmpty)

        let store = FernletStore(
            repository: LocalFernletRepository(fileURL: tempURL("wipe-db")),
            aiAuditLogStore: sink
        )
        await store.deleteAllData(includingHealthKitSamples: false)
        #expect(sink.load().isEmpty, "delete-all left the AI audit log on disk")
    }
}
