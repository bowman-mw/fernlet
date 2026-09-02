// MeshSessionStoreTests.swift
// FernletTests
//
// P3 item 2 (plan §8.1, §20.2): the sealed `MeshSessionContext` store — its five-state load, its
// write token, and the two rules that make the state machine worth having.
//
// The claims worth walling here are the ones a later item cannot cheaply re-check:
//
// 1. **A refusal is never an absence.** Three of the five states mean "the field may be full" and
//    NONE of them vends a write token, so a caller holding one structurally cannot overwrite.
//    D4 makes this live rather than theoretical: `ColumnCrypto` refuses to seal without a
//    `DeviceBindingID`, i.e. before first unlock, on every shipping build.
// 2. **Durable before acknowledged (plan §3.6).** `save` returns only with the bytes on disk. A
//    refused seal writes nothing and — over an existing file — changes nothing.
// 3. **The group control key is not in the context, and cannot be.** `MeshGroupKey` is not
//    `Codable`; that is now a load-bearing guard rather than a passing remark.
//
// Every test runs on its OWN scope (temp directory + `com.fernlet.mesh-session.test.<uuid>`
// keychain service). `MeshSessionStoreIsolationTests` is the grep-wall that keeps it that way.

import CryptoKit
import Foundation
import Testing
import FernletFoundation
@testable import FernletCrypto
@testable import ProximityKit

// MARK: - Fixtures

/// Per-test scope + context fixtures. Nothing here reads a wall clock or the production scope.
enum MeshSessionStoreFixtures {

    /// Install identity pinned by most tests, so the binding is deterministic rather than whatever
    /// the simulator's real row happens to be.
    static let installA = Data(repeating: 0xA7, count: 16)

    /// A second install, for the "sealed elsewhere" case.
    static let installB = Data(repeating: 0xB9, count: 16)

    /// A scope nobody else in the process shares: temp directory + a `.test.` keychain service
    /// (the spelling `PrivacyWipeCoverageTests`' service discovery deliberately skips).
    static func scope() -> MeshSessionStorageScope {
        MeshSessionStorageScope(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("MeshSessionStore-\(UUID().uuidString)", isDirectory: true),
            keychainService: "com.fernlet.mesh-session.test.\(UUID().uuidString)"
        )
    }

    /// A context with two admissions and one departure, so the sealed bytes carry a real ledger
    /// rather than an empty one.
    static func context(developedLocally: Bool = false, epochHeads: [String] = ["epoch-1"]) -> MeshSessionContext {
        var ledger = MeshMembershipLedger(
            admissions: MeshMembershipRecordSet([
                MeshMembershipFixtures.admission(0),
                MeshMembershipFixtures.admission(1)
            ])
        )
        ledger.departures = MeshMembershipRecordSet([MeshMembershipFixtures.departure(1)])
        return MeshSessionContext(
            meshID: MeshMembershipFixtures.meshID,
            protocolVersion: 3,
            createdAt: MeshMembershipFixtures.base,
            hardDeadline: MeshMembershipFixtures.base.addingTimeInterval(6 * 3_600),
            ledger: ledger,
            epochHeads: epochHeads,
            lastExternalHeartbeat: MeshMembershipFixtures.base.addingTimeInterval(60),
            developedLocally: developedLocally
        )
    }

    /// The write token a load vends, or nil for the three states that vend none.
    static func token(_ load: MeshSessionLoad) -> MeshSessionStore.LoadToken? {
        switch load {
        case .loaded(_, let token), .absent(let token): return token
        case .deferred, .corrupt, .refused: return nil
        }
    }

    /// Saves `context` under a pinned install binding, from an `absent`/`loaded` token.
    static func save(
        _ context: MeshSessionContext,
        into store: MeshSessionStore,
        install: Data = installA
    ) throws {
        try DeviceBindingID.$testOverride.withValue(.identifier(install)) {
            guard let token = token(store.load()) else {
                throw MeshSessionSaveError.tokenFromAnotherStore
            }
            try store.save(context, token: token)
        }
    }

    /// Writes raw bytes straight into the store's file, bypassing the sealer — the only way to
    /// produce truncated, garbage, empty or wrong-schema files.
    static func writeRaw(_ bytes: Data, into store: MeshSessionStore) throws {
        try FileManager.default.createDirectory(
            at: store.scope.directory,
            withIntermediateDirectories: true
        )
        try bytes.write(to: store.fileURL, options: .atomic)
    }

    /// Destroys a scope's files and key so a finished test leaves nothing behind.
    static func tearDown(_ scope: MeshSessionStorageScope) {
        MeshSessionStore.wipeForDeleteAll(scope: scope)
        try? FileManager.default.removeItem(at: scope.directory)
    }
}

// MARK: - Round trip and the write token

/// The happy path plus the token's guarantees.
struct MeshSessionStoreRoundTripTests {

    private typealias Fixture = MeshSessionStoreFixtures

    @Test func anEmptyScopeLoadsAsAbsentAndVendsAWriteToken() {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshSessionStore(scope: scope)

        let load = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            store.load()
        }

        guard case .absent = load else {
            Issue.record("an empty scope loaded as \(load) rather than .absent")
            return
        }
        #expect(Fixture.token(load) != nil, "`absent` is a green field and must vend a write token")
    }

    @Test func aSavedContextReloadsByteForByte() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshSessionStore(scope: scope)
        let context = Fixture.context()

        try Fixture.save(context, into: store)
        let load = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            store.load()
        }

        guard case .loaded(let reloaded, _) = load else {
            Issue.record("a saved context reloaded as \(load) rather than .loaded")
            return
        }
        #expect(reloaded == context)
        #expect(reloaded.ledger.derivedRoster.members.map(\.fingerprint) == [MeshMembershipFixtures.fingerprint(0)],
                "the roster must still derive as admitted − departed after a round trip")
    }

    @Test func theSecondSaveReplacesTheFirstAndLeavesOneFile() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshSessionStore(scope: scope)

        try Fixture.save(Fixture.context(developedLocally: false), into: store)
        try Fixture.save(Fixture.context(developedLocally: true), into: store)

        let load = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            store.load()
        }
        guard case .loaded(let reloaded, _) = load else {
            Issue.record("the overwritten context reloaded as \(load)")
            return
        }
        #expect(reloaded.developedLocally, "the atomic overwrite kept the older context")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: scope.directory.path)
        #expect(siblings.filter { !$0.hasPrefix(".") } == [MeshSessionStore.fileName],
                "an atomic write left something beside the file: \(siblings)")
    }

    @Test func aTokenMintedByAnotherStoreCannotAuthoriseAWrite() {
        let scopeA = Fixture.scope()
        let scopeB = Fixture.scope()
        defer { Fixture.tearDown(scopeA); Fixture.tearDown(scopeB) }
        let storeA = MeshSessionStore(scope: scopeA)
        let storeB = MeshSessionStore(scope: scopeB)

        DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            guard let tokenA = Fixture.token(storeA.load()) else {
                Issue.record("store A vended no token from an absent load")
                return
            }
            #expect(throws: MeshSessionSaveError.tokenFromAnotherStore) {
                try storeB.save(Fixture.context(), token: tokenA)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: storeB.fileURL.path),
                "a rejected token still wrote a file")
    }

    @Test func epochHeadsAreClampedOnInitAndOnDecode() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshSessionStore(scope: scope)
        let cap = MeshSessionContextSchema.maxEpochHeads
        let context = Fixture.context(epochHeads: (0..<(cap + 6)).map { "epoch-\($0)" })

        #expect(context.epochHeads.count == cap, "init did not clamp the epoch heads")

        try Fixture.save(context, into: store)
        let load = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            store.load()
        }
        guard case .loaded(let reloaded, _) = load else {
            Issue.record("clamped context reloaded as \(load)")
            return
        }
        #expect(reloaded.epochHeads.count == cap)
    }

    /// The `MeshGroupKey` doc guard, made mechanical. Plan §8.1 keeps the group control key
    /// memory-only forever; the sealed context is what makes that promise load-bearing, so the
    /// cheapest durable enforcement is that the key type cannot be encoded at all.
    @Test func theGroupControlKeyIsStructurallyUnpersistable() throws {
        #expect((MeshGroupKey.self as? any Encodable.Type) == nil,
                "MeshGroupKey became Encodable — the group control key must never reach any sealed file (plan §8.1)")
        #expect((MeshGroupKey.self as? any Decodable.Type) == nil,
                "MeshGroupKey became Decodable — nothing may read a persisted group key back")

        let json = try JSONEncoder().encode(MeshSessionStoreFixtures.context())
        let text = String(decoding: json, as: UTF8.self)
        #expect(!text.contains("keyBytes"), "the sealed context's plaintext names key material: \(text.prefix(200))")
    }
}

// MARK: - The five states

/// The load matrix: `loaded` / `absent` / `deferred` / `corrupt` / `refused`, and the rule that
/// only the first two vend a write token.
struct MeshSessionStoreLoadStateTests {

    private typealias Fixture = MeshSessionStoreFixtures

    /// The D4 refusal on the READ side. The context exists; the install binding does not; the store
    /// must say so by name. Reporting `absent` here is the exact bug plan §20.2 forbids — a caller
    /// would start a fresh mesh and overwrite live membership on the next unlock.
    @Test func anAbsentInstallBindingRefusesRatherThanReportingAbsent() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshSessionStore(scope: scope)
        try Fixture.save(Fixture.context(), into: store)

        let load = DeviceBindingID.$testOverride.withValue(.unavailable) { store.load() }

        guard case .refused(let refusal) = load else {
            Issue.record("an unavailable binding loaded as \(load) rather than .refused")
            return
        }
        #expect(refusal.operation == .open)
        #expect(refusal.cause == .installBindingUnavailable)
        #expect(Fixture.token(load) == nil, "a refusal vended a write token — the green-field trap")
    }

    /// A transient keychain outage on the binding row is retryable by `DeviceBindingID`'s own
    /// contract, so it must DEFER, not refuse and not corrupt.
    @Test func aTransientBindingReadErrorDefersAndSelfHeals() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshSessionStore(scope: scope)
        let context = Fixture.context()
        try Fixture.save(context, into: store)

        let deferredLoad = DeviceBindingID.$testOverride.withValue(.readError) { store.load() }
        guard case .deferred(let deferral) = deferredLoad else {
            Issue.record("a binding read error loaded as \(deferredLoad) rather than .deferred")
            return
        }
        #expect(deferral.reason == .installBindingReadError)
        #expect(Fixture.token(deferredLoad) == nil)

        let healed = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) { store.load() }
        guard case .loaded(let reloaded, _) = healed else {
            Issue.record("the deferred load did not heal: \(healed)")
            return
        }
        #expect(reloaded == context)
    }

    /// The seal key is gone but the ciphertext is not. Terminal and named — never "absent", because
    /// the bytes are right there and overwriting them is a decision, not a default.
    @Test func aMissingSealKeyOverCiphertextRefusesByName() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshSessionStore(scope: scope)
        try Fixture.save(Fixture.context(), into: store)

        KeychainItem.deleteAll(service: scope.keychainService)

        let load = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) { store.load() }
        guard case .refused(let refusal) = load else {
            Issue.record("a missing seal key loaded as \(load) rather than .refused")
            return
        }
        #expect(refusal.cause == .sealKeyMissingForSealedFile)
        #expect(refusal.summary.contains("sealKeyMissingForSealedFile"))
    }

    @Test func anEmptyFileIsCorrupt() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshSessionStore(scope: scope)
        try Fixture.writeRaw(Data(), into: store)

        let load = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) { store.load() }
        #expect(load == .corrupt(MeshSessionCorruption(detail: .emptyFile)))
    }

    @Test func truncatedCiphertextIsCorruptNotAbsent() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshSessionStore(scope: scope)
        try Fixture.save(Fixture.context(), into: store)

        let sealed = try Data(contentsOf: store.fileURL)
        try Fixture.writeRaw(sealed.prefix(sealed.count - 8), into: store)

        let load = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) { store.load() }
        guard case .corrupt(let corruption) = load else {
            Issue.record("truncated ciphertext loaded as \(load) rather than .corrupt")
            return
        }
        #expect(corruption.detail == .authenticationFailed)
        #expect(Fixture.token(load) == nil, "corruption vended a write token")
    }

    /// Garbage that does not even carry the v3 marker byte. `ColumnCrypto` classifies it as a
    /// retired generation, which this store reports as a REFUSAL by name rather than as an
    /// authentication failure — nothing is wrong with a key here.
    @Test func bytesInARetiredFormatAreRefusedByName() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshSessionStore(scope: scope)
        try Fixture.save(Fixture.context(), into: store)
        try Fixture.writeRaw(Data(repeating: 0x02, count: 96), into: store)

        let load = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) { store.load() }
        guard case .refused(let refusal) = load else {
            Issue.record("retired-format bytes loaded as \(load)")
            return
        }
        #expect(refusal.cause == .retiredAtRestFormat)
    }

    /// A context stamped with a schema version this build does not own is refused as a WHOLE, and
    /// the refusal names the version. Field-by-field leniency here would silently drop membership
    /// records a newer build wrote.
    @Test func anUnsupportedSchemaVersionIsCorruptAndNamesTheVersion() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshSessionStore(scope: scope)
        // Establish the key by saving once, then overwrite with a probe sealed under the same key.
        try Fixture.save(Fixture.context(), into: store)
        guard case .available(let key) = MeshSessionSealKey.forSeal(service: scope.keychainService) else {
            Issue.record("could not read the seal key the save just minted")
            return
        }
        let probe = try DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            try ColumnCrypto(purpose: FernletCryptoPurpose.KeyDerivation.meshSessionContextV1)
                .seal(SchemaVersionProbe(schemaVersion: 99), contentKey: key)
        }
        try Fixture.writeRaw(probe, into: store)

        let load = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) { store.load() }
        #expect(load == .corrupt(MeshSessionCorruption(detail: .unsupportedSchemaVersion(99))))
    }

    /// A context sealed on another install opens for nobody here. It is the ciphertext that is
    /// wrong for this device, not the custody, so this is corruption rather than a refusal.
    @Test func aContextSealedOnAnotherInstallDoesNotOpen() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshSessionStore(scope: scope)
        try Fixture.save(Fixture.context(), into: store, install: Fixture.installB)

        let load = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) { store.load() }
        guard case .corrupt(let corruption) = load else {
            Issue.record("a foreign-install context loaded as \(load)")
            return
        }
        #expect(corruption.detail == .authenticationFailed)
    }

    /// Corruption is recoverable only by an explicit act, and the bytes are preserved beside the
    /// file rather than destroyed.
    @Test func quarantineSetsTheCorruptFileAsideAndVendsAToken() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshSessionStore(scope: scope)
        try Fixture.writeRaw(Data(repeating: 0x03, count: 64), into: store)

        let token = try store.quarantineCorruptFile(MeshSessionCorruption(detail: .authenticationFailed))
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: store.quarantineURL.path),
                "the corrupt bytes were destroyed rather than preserved")

        try DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            try store.save(Fixture.context(), token: token)
        }
        let load = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) { store.load() }
        guard case .loaded = load else {
            Issue.record("the post-quarantine save did not reload: \(load)")
            return
        }
    }

    /// A stand-in for a context written by a future build: only the schema stamp, which the decoder
    /// reads first and refuses on.
    private struct SchemaVersionProbe: Encodable {
        let schemaVersion: Int
    }
}

// MARK: - Durable before acknowledged

/// Plan §3.6 at the seam D4 makes real: if the store cannot seal, it must not report success, and
/// it must not have changed anything.
struct MeshSessionStoreDurabilityTests {

    private typealias Fixture = MeshSessionStoreFixtures

    @Test func aRefusedSealThrowsAndWritesNothing() {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshSessionStore(scope: scope)

        DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            guard let token = Fixture.token(store.load()) else {
                Issue.record("no token from an absent load")
                return
            }
            DeviceBindingID.$testOverride.withValue(.unavailable) {
                #expect(throws: MeshSessionSealRefusal(operation: .seal, cause: .installBindingUnavailable)) {
                    try store.save(Fixture.context(), token: token)
                }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path),
                "a refused seal created a file — durable-before-acknowledged is inverted")
    }

    /// The worse half of the same failure: a refusal over an EXISTING file must leave the previous
    /// bytes exactly as they were. Truncating first and failing second is how a save that "failed"
    /// still destroys a session.
    @Test func aRefusedSealOverAnExistingFileChangesNothing() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshSessionStore(scope: scope)
        let original = Fixture.context()
        try Fixture.save(original, into: store)
        let bytesBefore = try Data(contentsOf: store.fileURL)

        DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            guard let token = Fixture.token(store.load()) else {
                Issue.record("no token from a loaded load")
                return
            }
            DeviceBindingID.$testOverride.withValue(.unavailable) {
                #expect(throws: MeshSessionSealRefusal.self) {
                    try store.save(Fixture.context(developedLocally: true), token: token)
                }
            }
        }

        #expect(try Data(contentsOf: store.fileURL) == bytesBefore, "a refused seal rewrote the file")
        let load = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) { store.load() }
        guard case .loaded(let reloaded, _) = load else {
            Issue.record("the untouched file no longer loads: \(load)")
            return
        }
        #expect(reloaded == original)
    }

    /// The wipe takes file, quarantine sibling and key together — the property `MeshSessionStorageScope`
    /// exists to make expressible.
    @Test func wipeForDeleteAllRemovesTheFileTheQuarantineAndTheKey() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let store = MeshSessionStore(scope: scope)
        try Fixture.save(Fixture.context(), into: store)
        try Fixture.writeRaw(Data(repeating: 0x03, count: 32), into: store)
        _ = try store.quarantineCorruptFile(MeshSessionCorruption(detail: .authenticationFailed))
        try Fixture.save(Fixture.context(), into: store)

        #expect(MeshSessionStore.wipeForDeleteAll(scope: scope))

        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: store.quarantineURL.path))
        guard case .refused(let refusal) = MeshSessionSealKey.forOpen(service: scope.keychainService) else {
            Issue.record("the seal key survived the wipe")
            return
        }
        #expect(refusal == .sealKeyMissingForSealedFile)
    }

    /// A wipe of a scope that never held anything is a success, not a failure: the funnel asks for
    /// an end state, not for work to have been done.
    @Test func wipingAnUntouchedScopeSucceeds() {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        #expect(MeshSessionStore.wipeForDeleteAll(scope: scope))
    }
}
