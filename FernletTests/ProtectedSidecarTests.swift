// ProtectedSidecarTests.swift
// FernletTests
//
// Track A of Docs/Plan-Prekeys-ProtectedLoad-CoachMesh-2026-07-26.md: the `ProtectedSidecar`
// load/persist state machine (Increment 1) and the at-rest seal (Increment 4).
//
// The regression these tests pin down: every heart sidecar used to treat ANY read failure as
// "no data", and the next persist() wrote that empty state back over the real file. A deferred
// read must be `.unavailable` — never empty — and a failed WRITE must keep the in-memory value
// as the truth and re-persist it, never re-read the (older) disk copy.

import Foundation
import Testing
import CryptoKit
import ProximityKit
import FernletFoundation

@MainActor
@Suite(.serialized)
struct ProtectedSidecarTests {

    // MARK: - Harness

    nonisolated final class IOGate: @unchecked Sendable {
        var failReads = false
        var failWrites = false
        var readCount = 0
        var writeCount = 0
    }

    nonisolated final class TestClock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        func advance(_ interval: TimeInterval) { date = date.addingTimeInterval(interval) }
    }

    private func tempFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("protected-sidecar-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func makeSidecar(
        url: URL,
        io: IOGate = IOGate(),
        clock: TestClock = TestClock(),
        seal: SidecarSeal? = nil,
        salvage: ((Data) -> (value: [String], lostCount: Int)?)? = nil,
        quarantines: Bool = false
    ) -> ProtectedSidecar<[String]> {
        ProtectedSidecar(
            fileURL: url,
            empty: [],
            seal: seal,
            auditPrefix: "test.sidecar",
            salvage: salvage,
            quarantinesUnreadableSealedData: quarantines,
            now: { clock.date },
            readData: { url in
                io.readCount += 1
                if io.failReads { throw CocoaError(.fileReadNoPermission) }
                return try Data(contentsOf: url)
            },
            writeData: { data, url in
                io.writeCount += 1
                if io.failWrites { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: [.atomic])
            },
            observeProtectedData: false
        )
    }

    private func seed(_ url: URL, _ value: [String]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url)
    }

    private func diskValue(_ url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    // MARK: - Read classification (Increment 1)

    @Test func anAbsentFileIsReadyAndEmpty() {
        let sidecar = makeSidecar(url: tempFile("absent.json"))
        #expect(sidecar.state == .ready)
        #expect(sidecar.read() == [])
        #expect(sidecar.mutate { $0.append("a") } == .persisted)
    }

    /// THE bug Track A fixes: a read failure is `.unavailable`, not "empty" — and while
    /// unavailable, nothing can overwrite the file that could not be read.
    @Test func aFailedReadIsUnavailableAndNeverOverwritesTheFile() throws {
        let url = tempFile("deferred.json")
        try seed(url, ["precious"])
        let io = IOGate()
        io.failReads = true
        let sidecar = makeSidecar(url: url, io: io)

        #expect(sidecar.state == .unavailable)
        #expect(sidecar.read() == nil)
        #expect(sidecar.mutate { $0.append("clobber") } == .refused)
        #expect(!sidecar.mutateIfPersisted { $0.append("clobber") })
        #expect(diskValue(url) == ["precious"], "a refused mutation must leave the unreadable file untouched")

        io.failReads = false
        #expect(sidecar.retryLoad())
        #expect(sidecar.state == .ready)
        #expect(sidecar.read() == ["precious"])
    }

    @Test func aCorruptFileWithoutSalvageResetsEmptyAndDiscardsTheBlob() throws {
        let url = tempFile("corrupt.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: url)
        let sidecar = makeSidecar(url: url)

        #expect(sidecar.state == .ready)
        #expect(sidecar.read() == [])
        #expect(sidecar.dataLossOccurred)
        // Locked decision O4: corrupt plaintext is DISCARDED, never parked in a second file.
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: url.path + ".corrupt"))
    }

    @Test func aCorruptFileWithSalvageKeepsWhatParses() throws {
        let url = tempFile("salvage.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: url)
        let sidecar = makeSidecar(url: url, salvage: { _ in (value: ["kept"], lostCount: 2) })

        #expect(sidecar.state == .ready)
        #expect(sidecar.read() == ["kept"])
        #expect(sidecar.dataLossOccurred)
        #expect(diskValue(url) == ["kept"], "the salvaged value is re-persisted so the corruption is healed one-way")
    }

    // MARK: - Write failure is not read failure (Increment 1)

    @Test func aPersistFailureFlipsStateButKeepsMemoryAsTheTruth() throws {
        let url = tempFile("dirty.json")
        try seed(url, ["a"])
        let io = IOGate()
        let sidecar = makeSidecar(url: url, io: io)
        #expect(sidecar.read() == ["a"])

        io.failWrites = true
        #expect(sidecar.mutate { $0.append("b") } == .appliedNotPersisted)
        #expect(sidecar.state == .unavailable)
        #expect(sidecar.read() == ["a", "b"], "memory is the truth after a failed write")
        #expect(diskValue(url) == ["a"], "the disk copy is older, and stays untouched")

        // A second mutation builds on MEMORY — recovery must never re-read the older disk copy,
        // which would discard the unpersisted mutation.
        #expect(sidecar.mutate { $0.append("c") } == .appliedNotPersisted)
        #expect(sidecar.read() == ["a", "b", "c"])

        io.failWrites = false
        #expect(sidecar.retryLoad(), "recovery re-persists the in-memory truth")
        #expect(sidecar.state == .ready)
        #expect(diskValue(url) == ["a", "b", "c"])
    }

    @Test func aTransactionalMutationRollsBackOnAFailedWrite() throws {
        let url = tempFile("transactional.json")
        try seed(url, ["a"])
        let io = IOGate()
        let sidecar = makeSidecar(url: url, io: io)
        #expect(sidecar.read() == ["a"])

        io.failWrites = true
        #expect(!sidecar.mutateIfPersisted { $0.append("b") })
        #expect(sidecar.state == .ready, "a rolled-back mutation leaves memory and disk agreeing")
        #expect(sidecar.read() == ["a"])
        #expect(diskValue(url) == ["a"])
    }

    // MARK: - Retry floor (Increment 1 risk note: view bodies read accessors every render)

    @Test func onAccessRetriesHonorTheFloorButRetryLoadBypassesIt() throws {
        let url = tempFile("floor.json")
        try seed(url, ["a"])
        let io = IOGate()
        io.failReads = true
        let clock = TestClock()
        let sidecar = makeSidecar(url: url, io: io, clock: clock)
        #expect(io.readCount == 1) // the init-time load

        _ = sidecar.read()
        _ = sidecar.read()
        #expect(io.readCount == 1, "a failing read must not be re-attempted on every access")

        clock.advance(6) // past the floor
        _ = sidecar.read()
        #expect(io.readCount == 2)

        _ = sidecar.retryLoad() // the sync-pass / unlock-notification path skips the floor
        #expect(io.readCount == 3)
    }

    // MARK: - Wipe (Increment 1 + 4)

    @Test func wipeRemovesThePrimaryAndQuarantineFilesAndResetsEmpty() throws {
        let url = tempFile("wipe.json")
        try seed(url, ["a"])
        let quarantine = url.appendingPathExtension("corrupt")
        try Data([0xFF]).write(to: quarantine)
        let sidecar = makeSidecar(url: url)

        sidecar.wipe()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: quarantine.path))
        #expect(sidecar.state == .ready)
        #expect(sidecar.read() == [])
        #expect(!sidecar.dataLossOccurred)
    }

    // MARK: - Seal at rest (Increment 4)

    private func uuidKeychainService() -> String {
        "com.fernlet.heartdrop.test.\(UUID().uuidString)"
    }

    @Test func aPlaintextFileIsMigratedToSealedOneWay() throws {
        let service = uuidKeychainService()
        defer { KeychainItem.deleteAll(service: service) }
        let url = tempFile("migrate.json")
        try seed(url, ["v0-plaintext"])

        let sidecar = makeSidecar(url: url, seal: HeartDropSidecarSeal.make(keychainService: service))
        #expect(sidecar.state == .ready)
        #expect(sidecar.read() == ["v0-plaintext"])

        let raw = try Data(contentsOf: url)
        #expect(raw.starts(with: Data("FSC1".utf8)), "the plaintext file is rewritten sealed on first read")
        #expect(diskValue(url) == nil, "no plaintext remains")

        // A second instance (relaunch) reads the sealed format.
        let relaunched = makeSidecar(url: url, seal: HeartDropSidecarSeal.make(keychainService: service))
        #expect(relaunched.read() == ["v0-plaintext"])
    }

    @Test func sealedMutationsRoundTripAcrossInstances() throws {
        let service = uuidKeychainService()
        defer { KeychainItem.deleteAll(service: service) }
        let url = tempFile("sealed.json")

        let sidecar = makeSidecar(url: url, seal: HeartDropSidecarSeal.make(keychainService: service))
        #expect(sidecar.mutate { $0.append("sealed-value") } == .persisted)

        let relaunched = makeSidecar(url: url, seal: HeartDropSidecarSeal.make(keychainService: service))
        #expect(relaunched.read() == ["sealed-value"])
    }

    /// "File exists + key definitively gone" is unrecoverable, not deferred. The outbox
    /// quarantines (ciphertext is privacy-inert and the parked file is the durable loss marker);
    /// the dedup/bundle stores delete and continue.
    @Test func aSealedFileWhoseKeyIsGoneIsQuarantinedOrDeletedPerPolicy() throws {
        let service = uuidKeychainService()
        let url = tempFile("keyless.json")
        let minter = makeSidecar(url: url, seal: HeartDropSidecarSeal.make(keychainService: service))
        #expect(minter.mutate { $0.append("unreachable") } == .persisted)
        KeychainItem.deleteAll(service: service) // the key is now definitively gone

        let quarantining = makeSidecar(
            url: url, seal: HeartDropSidecarSeal.make(keychainService: service), quarantines: true)
        #expect(quarantining.state == .ready)
        #expect(quarantining.read() == [])
        #expect(quarantining.dataLossOccurred)
        let quarantine = url.appendingPathExtension("corrupt")
        #expect(FileManager.default.fileExists(atPath: quarantine.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // wipe() owns the quarantine path.
        quarantining.wipe()
        #expect(!FileManager.default.fileExists(atPath: quarantine.path))

        // Delete-and-continue policy (dedup / peer bundles).
        let url2 = tempFile("keyless2.json")
        let service2 = uuidKeychainService()
        let minter2 = makeSidecar(url: url2, seal: HeartDropSidecarSeal.make(keychainService: service2))
        #expect(minter2.mutate { $0.append("unreachable") } == .persisted)
        KeychainItem.deleteAll(service: service2)
        let deleting = makeSidecar(
            url: url2, seal: HeartDropSidecarSeal.make(keychainService: service2), quarantines: false)
        #expect(deleting.state == .ready)
        #expect(deleting.read() == [])
        #expect(deleting.dataLossOccurred)
        #expect(!FileManager.default.fileExists(atPath: url2.path))
        #expect(!FileManager.default.fileExists(atPath: url2.appendingPathExtension("corrupt").path))
    }

    /// A seal that refuses (read-back-verify failed, key unmintable) makes the persist FAIL —
    /// the store goes dirty and retries — rather than silently writing plaintext or writing
    /// ciphertext against an unverified key.
    @Test func aRefusedSealFailsThePersistInsteadOfDowngrading() throws {
        let url = tempFile("refusing-seal.json")
        try seed(url, ["a"])
        let refusingSeal = SidecarSeal(
            isSealed: { _ in false },
            open: { _ in throw SidecarSeal.SealError.openFailed },
            seal: { _ in throw SidecarSeal.SealError.sealFailed }
        )
        let sidecar = makeSidecar(url: url, seal: refusingSeal)
        // The v0 plaintext loads, but its sealed rewrite is refused → dirty, retried.
        #expect(sidecar.read() == ["a"])
        #expect(sidecar.state == .unavailable)
        #expect(sidecar.mutate { $0.append("b") } == .appliedNotPersisted)
        #expect(diskValue(url) == ["a"], "nothing is ever written through a refusing seal")
    }

    /// The seal key mints with read-back verification and round-trips through the real keychain.
    @Test func theSealKeyMintsOnceAndIsSharedAcrossStores() throws {
        let service = uuidKeychainService()
        defer { KeychainItem.deleteAll(service: service) }
        let sealA = HeartDropSidecarSeal.make(keychainService: service)
        let sealB = HeartDropSidecarSeal.make(keychainService: service)

        let sealed = try sealA.seal(Data("cross-store".utf8))
        #expect(sealB.isSealed(sealed))
        #expect(try sealB.open(sealed) == Data("cross-store".utf8))
    }
}
