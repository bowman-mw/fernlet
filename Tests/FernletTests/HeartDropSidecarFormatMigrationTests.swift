// HeartDropSidecarFormatMigrationTests.swift
// FernletTests
//
// Phase 2.2 of Docs/Plan-Crypto-Standardization-2026-08-27.md: the `FSC1` → `FSC2` format
// migrator for the heart-drop sidecars (`HeartDropSidecarFormatMigrator`).
//
// What these tests have to establish, because Phase 3 deletes the legacy reader on the strength
// of the corpus this migrator retires:
//   1. A legacy main row is converted through the REAL seal — opened by the shipping legacy
//      branch, re-sealed by the shipping v2 path — and the re-seal genuinely binds the
//      `heartDropSidecarV2` domain (an unauthenticated open of the new body FAILS), it does not
//      relabel.
//   2. Everything that is not a provably-convertible legacy main row is left BYTE-IDENTICAL:
//      unopenable, unmarked, unreadable and quarantine files, and every file on a keyless pass.
//   3. Every blocked state keeps the latch closed, every examined row lands in exactly one
//      bucket, and a keyless pass never mints a keychain row (open-before-seal ordering).
//   4. A set latch is observation, not memory: `runAtLaunch()` re-surveys every launch and
//      resets on any blocking-class main row — the same set the latch predicate refuses.
//
// Group 12 of the reviewed test plan is the wipe wall itself: the
// `com.fernlet.heartdrop.sidecarFormatMigrationComplete` disposition row in
// `PersistedSurfaceWipeBoundaryTests` and the manifest token in `PrivacyWipeCoverageTests` land
// in the same change as the key (the discovery wall fails otherwise). Funnel-EFFECT observation
// carries the same recorded testability residual as the 2.1 latch: there is no injection seam at
// the `deleteAllData` funnel, so the wall row and the funnel call are the enforced artifacts —
// widening the seam is its own change.
//
// Isolation: `uniqueProximityDirectory()` + `uniqueHeartDropKeychainService()` per test (the
// house rule for anything heart-drop), plus an isolated `UserDefaults` suite per test so no
// latch state ever touches the device's real completion bit.

import Foundation
import Testing
import CryptoKit
import Security
import ProximityKit
import FernletCrypto  // the shared FormatMigrator.run(maxPasses:) protocol extension
import FernletFoundation

@MainActor
struct HeartDropSidecarFormatMigrationTests {

    // MARK: - Harness

    /// A fresh, created-on-disk heart-drop root (the census suite's idiom — several tests plant
    /// files into it directly).
    private func makeRoot() throws -> URL {
        let root = uniqueProximityDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// An isolated defaults suite so a test never reads or writes the device's real latch. The
    /// suite name comes back so the test can remove the persistent domain when it finishes.
    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let name = "HeartDropSidecarFormatMigrationTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// A byte-exact `FSC1` legacy sidecar blob: the legacy magic, then a ChaCha20-Poly1305 box
    /// sealed with NO authenticated data — the exact pre-91c3956 layout the migrator converts.
    private func legacyBlob(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        // cryptographic-domain: legacy-read — this fixture reproduces the pre-91c3956 unbound box
        // on purpose; it is the corpus this migrator exists to retire.
        let box = try ChaChaPoly.seal(plaintext, using: key)
        return Data("FSC1".utf8) + box.combined
    }

    /// Mints a 32-byte seal key and files it where `HeartDropSidecarSeal` looks for it. Returns
    /// the key for building fixtures. The account literal matches `HeartDropSidecarKey.swift:31`.
    private func plantSealKey(service: String) -> SymmetricKey {
        let keyData = Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
        let status = KeychainItem.store(
            keyData,
            account: "sidecarSealKey",
            service: service,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            synchronizable: false
        )
        #expect(status == errSecSuccess, "the fixture seal key was not filed in the keychain")
        return SymmetricKey(data: keyData)
    }

    /// Drives a REAL `HeartDropOutbox` on this root + service until it has sealed one entry, and
    /// returns the file it wrote — the bytes production emits, never planted.
    private func mintProductionOutboxFile(root: URL, service: String) -> URL {
        let url = HeartDropOutbox.fileURL(in: root)
        let outbox = HeartDropOutbox(
            fileURL: url,
            seal: HeartDropSidecarSeal.make(keychainService: service)
        )
        let entry = HeartDropOutbox.Entry(
            id: UUID(),
            friendSigningKey: Data(repeating: 0x11, count: 32),
            tag: "fixture-tag",
            wire: Data(repeating: 0x22, count: 48),
            createdAt: Date()
        )
        #expect(outbox.enqueue(entry) == .queued, "the fixture outbox never durably sealed anything")
        return url
    }

    /// Every file currently in `root`, by name, with its bytes — the byte-identity proofs'
    /// snapshot.
    private func snapshot(_ root: URL) throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        var bytes: [String: Data] = [:]
        for name in names {
            bytes[name] = try Data(contentsOf: root.appendingPathComponent(name))
        }
        return bytes
    }

    private func plant(_ bytes: Data, as sidecar: HeartDropSidecarFormatCensus.Sidecar, in root: URL) throws {
        try bytes.write(to: sidecar.url(in: root), options: [.atomic])
    }

    /// A migrator over `root` + `service` with its latch on the isolated `defaults`.
    private func makeMigrator(
        root: URL,
        service: String,
        defaults: UserDefaults,
        writeData: ((Data, URL) throws -> Void)? = nil
    ) -> HeartDropSidecarFormatMigrator {
        HeartDropSidecarFormatMigrator(
            scope: HeartDropStorageScope(directory: root, keychainService: service),
            latch: HeartDropSidecarMigrationLatch(defaults: defaults),
            writeData: writeData
        )
    }

    // MARK: - 1. Conversion binds the v2 domain

    /// Every legacy main row is converted through the shipping seal: the files come back
    /// `FSC2`-prefixed, open to the exact original plaintext, and the census — the number
    /// Phase 3 is gated on — reads zero legacy. The re-seal genuinely bound the
    /// `heartDropSidecarV2` domain: a bare unauthenticated open of the new body FAILS, so this
    /// was a re-encryption, not a relabel.
    @Test func migrationConvertsEveryLegacyMainRowAndBindsTheV2Domain() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = uniqueHeartDropKeychainService()
        defer { KeychainItem.deleteAll(service: service) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = plantSealKey(service: service)
        let plaintexts: [HeartDropSidecarFormatCensus.Sidecar: Data] = [
            .outbox: Data(#"[{"note":"outbox"}]"#.utf8),
            .peerBundles: Data(#"{"bundles":[]}"#.utf8),
            .dedup: Data(#"{"accepted":{}}"#.utf8)
        ]
        for (sidecar, plaintext) in plaintexts {
            try plant(try legacyBlob(plaintext, key: key), as: sidecar, in: root)
        }

        let migrator = makeMigrator(root: root, service: service, defaults: defaults)
        #expect(migrator.run(), "a fully-convertible corpus must convert and latch")
        #expect(HeartDropSidecarMigrationLatch(defaults: defaults).isComplete)

        let seal = HeartDropSidecarSeal.make(keychainService: service)
        for (sidecar, plaintext) in plaintexts {
            let converted = try Data(contentsOf: sidecar.url(in: root))
            #expect(converted.starts(with: Data("FSC2".utf8)))
            #expect(try seal.open(converted) == plaintext,
                    "\(sidecar) did not round-trip to its exact original plaintext")
            // The old format no longer opens: the body authenticates the sidecar purpose now,
            // so the unbound legacy-style open MUST fail.
            let box = try ChaChaPoly.SealedBox(combined: converted.dropFirst(4))
            #expect(throws: (any Error).self, "the re-seal relabelled instead of binding the domain") {
                _ = try ChaChaPoly.open(box, using: key)
            }
        }

        let report = HeartDropSidecarFormatCensus.survey(in: root)
        #expect(report.legacySealedCount == 0)
        #expect(report.v2SealedCount == 3)
        #expect(report.isClean)
    }

    // MARK: - 2. Idempotence

    /// A second pass over a converted corpus is the survey plus nothing: zero writes, a
    /// byte-identical corpus, and a clean no-progress tally.
    @Test func aSecondPassIsAByteIdenticalNoOp() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = uniqueHeartDropKeychainService()
        defer { KeychainItem.deleteAll(service: service) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = plantSealKey(service: service)
        try plant(try legacyBlob(Data("[]".utf8), key: key), as: .outbox, in: root)
        try plant(try legacyBlob(Data("{}".utf8), key: key), as: .dedup, in: root)

        let migrator = makeMigrator(root: root, service: service, defaults: defaults)
        #expect(migrator.run())

        let before = try snapshot(root)
        let result = migrator.performPass()
        let after = try snapshot(root)

        #expect(after == before, "a pass over a converted corpus modified it")
        #expect(result.isClean)
        #expect(result.converted == 0)
        #expect(!result.madeForwardProgress)
        #expect(result.alreadyV2 == 2)
    }

    // MARK: - 3. Key-free clean pass + latch short-circuit

    /// A clean corpus latches WITHOUT touching the keychain: the scan is marker-only (the
    /// census's key-free property inherited), so even a wiped seal key cannot stop a clean
    /// verdict — and the pass mints nothing. Separately, a pre-set latch short-circuits `run()`
    /// entirely: byte-identical corpus, no key row.
    @Test func theLatchShortCircuitsAndACleanPassNeverTouchesTheKeychain() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = uniqueHeartDropKeychainService()
        defer { KeychainItem.deleteAll(service: service) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = mintProductionOutboxFile(root: root, service: service)
        KeychainItem.deleteAll(service: service)
        #expect(KeychainItem.load(account: "sidecarSealKey", service: service) == nil)

        let migrator = makeMigrator(root: root, service: service, defaults: defaults)
        #expect(migrator.run(), "a marker-only clean scan must latch with no key at all")
        #expect(HeartDropSidecarMigrationLatch(defaults: defaults).isComplete)
        #expect(KeychainItem.load(account: "sidecarSealKey", service: service) == nil,
                "a clean pass touched the keychain")

        // A pre-set latch: run() returns true without a pass — even over a legacy blob the
        // migrator was never funded to look at — and nothing is read, written, or minted.
        let root2 = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root2) }
        let service2 = uniqueHeartDropKeychainService()
        defer { KeychainItem.deleteAll(service: service2) }
        try plant(try legacyBlob(Data("[]".utf8), key: SymmetricKey(size: .bits256)), as: .dedup, in: root2)
        let latch2 = HeartDropSidecarMigrationLatch(defaults: defaults)
        latch2.markComplete()
        let before = try snapshot(root2)
        let migrator2 = makeMigrator(root: root2, service: service2, defaults: defaults)
        #expect(migrator2.run())
        #expect(try snapshot(root2) == before)
        #expect(KeychainItem.load(account: "sidecarSealKey", service: service2) == nil)
    }

    // MARK: - 4. Unreadable blocks

    /// "I could not look" must never latch: an unreadable main row lands in its own blocking
    /// bucket, and the pass never guesses at what it could not read.
    @Test func anUnreadableMainRowBlocksTheLatch() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = uniqueHeartDropKeychainService()
        defer { KeychainItem.deleteAll(service: service) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = plantSealKey(service: service)
        let url = HeartDropSidecarFormatCensus.Sidecar.peerBundles.url(in: root)
        try plant(try legacyBlob(Data("[]".utf8), key: key), as: .peerBundles, in: root)
        // Deny read — the closest a test can get to a Complete-class file whose protected data
        // is unavailable. Restored before teardown so the cleanup can still remove it.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }

        let migrator = makeMigrator(root: root, service: service, defaults: defaults)
        let result = migrator.performPass()
        #expect(result.unreadable == 1)
        #expect(!result.isClean)
        #expect(!migrator.run())
        #expect(!HeartDropSidecarMigrationLatch(defaults: defaults).isComplete,
                "the latch was set over a file the pass could not read")
    }

    // MARK: - 5. Missing key is indeterminate — and never mints

    /// A keyless legacy corpus is INDETERMINATE, never unopenable: the first row's key error
    /// stops the pass, and the two unattempted rows tally into the SAME bucket — every examined
    /// row lands in exactly one, so the count is 3, never 1 with phantom rows. Nothing is
    /// touched, and the keychain stays rowless: the open-before-seal ordering keeps
    /// `loadOrMintKey`'s minting arm unreachable.
    @Test func aMissingKeyIsIndeterminateNotUnopenable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = uniqueHeartDropKeychainService()
        defer { KeychainItem.deleteAll(service: service) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = SymmetricKey(size: .bits256)  // never filed in the keychain
        try plant(try legacyBlob(Data("[]".utf8), key: key), as: .outbox, in: root)
        try plant(try legacyBlob(Data("{}".utf8), key: key), as: .peerBundles, in: root)
        try plant(try legacyBlob(Data("[]".utf8), key: key), as: .dedup, in: root)
        let before = try snapshot(root)

        let migrator = makeMigrator(root: root, service: service, defaults: defaults)
        let result = migrator.performPass()
        #expect(result.keyUnavailable == 3,
                "the unattempted rows after the key-error stop must share the indeterminate bucket")
        #expect(result.converted == 0)
        #expect(result.unopenableLegacy == 0)
        #expect(!result.isClean)
        #expect(!migrator.run())
        #expect(!HeartDropSidecarMigrationLatch(defaults: defaults).isComplete)
        #expect(try snapshot(root) == before, "a keyless pass modified the corpus")
        #expect(KeychainItem.load(account: "sidecarSealKey", service: service) == nil,
                "the migrator minted a seal key — the open-before-seal ordering is broken")
    }

    // MARK: - 6. Unopenable legacy blocks, is never deleted

    /// A legacy blob the present key cannot authenticate BLOCKS the latch (the named deviation
    /// from the OwnPhoto unopenable rule: the store read path resolves such a file only
    /// destructively and only on its lazily-triggered next load, so "already resolves" cannot be
    /// asserted at pass time) — and the migrator never deletes, truncates, or quarantines it;
    /// disposal stays delegated to the store's shipped policy.
    @Test func anUnopenableLegacyBlobBlocksAndIsNeverDeleted() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = uniqueHeartDropKeychainService()
        defer { KeychainItem.deleteAll(service: service) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = plantSealKey(service: service)
        // Sealed under a DIFFERENT key than the planted one: key present, authentication fails.
        try plant(try legacyBlob(Data("[]".utf8), key: SymmetricKey(size: .bits256)), as: .dedup, in: root)
        let before = try snapshot(root)

        let migrator = makeMigrator(root: root, service: service, defaults: defaults)
        let result = migrator.performPass()
        #expect(result.unopenableLegacy == 1)
        #expect(result.keyUnavailable == 0)
        #expect(!result.isClean)
        #expect(!migrator.run())
        #expect(!HeartDropSidecarMigrationLatch(defaults: defaults).isComplete)
        #expect(try snapshot(root) == before, "an unopenable file was touched")
    }

    // MARK: - 7. Unmarked rows block, are never touched — and the store resolves them

    /// v0 plaintext and garbage share the census's conflated bucket, and the migrator treats
    /// both fail-closed: never converted, never touched, latch blocked. Distinguishing them
    /// would mean decoding the friend graph, which a bytes-level pass refuses.
    @Test func unmarkedMainRowsBlockAndAreNeverTouched() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = uniqueHeartDropKeychainService()
        defer { KeychainItem.deleteAll(service: service) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try plant(Data("[]".utf8), as: .outbox, in: root)
        try plant(Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00]), as: .dedup, in: root)
        let before = try snapshot(root)

        let migrator = makeMigrator(root: root, service: service, defaults: defaults)
        let result = migrator.performPass()
        #expect(result.unmarkedPending == 2)
        #expect(result.converted == 0)
        #expect(!result.isClean)
        #expect(!migrator.run())
        #expect(!HeartDropSidecarMigrationLatch(defaults: defaults).isComplete)
        #expect(try snapshot(root) == before, "an unmarked file was touched")
        #expect(KeychainItem.load(account: "sidecarSealKey", service: service) == nil,
                "an unmarked-only pass touched the keychain")
    }

    /// The Q2 delegation, end-to-end: the STORE's own load is the authority that resolves a v0
    /// plaintext file (`ProtectedSidecar.performLoad` seals it on load), after which a fresh
    /// migrator pass reads clean and latches — eventual, and correct.
    @Test func afterTheStoreResolvesAV0FileTheNextRunLatches() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = uniqueHeartDropKeychainService()
        defer { KeychainItem.deleteAll(service: service) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try plant(Data("[]".utf8), as: .outbox, in: root)
        let migrator = makeMigrator(root: root, service: service, defaults: defaults)
        #expect(!migrator.run(), "an unmarked row must block until the store resolves it")

        // A real outbox on the scope: its init's performLoad decodes the v0 file and rewrites it
        // sealed (the shipped one-way seal-on-load migration).
        let outbox = HeartDropOutbox(
            fileURL: HeartDropOutbox.fileURL(in: root),
            seal: HeartDropSidecarSeal.make(keychainService: service)
        )
        #expect(outbox.isAvailable, "the fixture store failed to load and seal the v0 file")

        let fresh = makeMigrator(root: root, service: service, defaults: defaults)
        #expect(fresh.run(), "the store resolved the file; the next run must latch")
        #expect(HeartDropSidecarMigrationLatch(defaults: defaults).isComplete)
    }

    // MARK: - 8. The quarantine tombstone

    /// The quarantine row never blocks and is never rewritten, whatever its marker bytes say: it
    /// is a durable data-loss tombstone no reader ever opens again, so re-sealing it would be
    /// rewriting evidence of loss into fresh ciphertext nothing will read. (This is also why
    /// Phase 3's zero-gate must be read per-row, quarantine excluded.)
    @Test func theQuarantineRowNeverBlocksAndIsNeverRewritten() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = uniqueHeartDropKeychainService()
        defer { KeychainItem.deleteAll(service: service) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try plant(Data("FSC1".utf8) + Data([0x09, 0x0A]), as: .outboxQuarantine, in: root)
        let before = try snapshot(root)

        let migrator = makeMigrator(root: root, service: service, defaults: defaults)
        let result = migrator.performPass()
        #expect(result.quarantineState == .legacySealed, "the tombstone's reading is still reported")
        #expect(result.isClean, "a legacy-marked tombstone must not block the latch")
        #expect(migrator.run())
        #expect(HeartDropSidecarMigrationLatch(defaults: defaults).isComplete)
        #expect(try snapshot(root) == before, "the quarantine tombstone was rewritten")
    }

    // MARK: - 9. Failed writes leave the source intact

    /// The verify-before-replace ordering: a failed write blocks the latch and leaves the source
    /// bytes byte-identical — nothing was deleted, nothing half-written, and the next pass
    /// re-examines.
    @Test func aFailedWriteBlocksTheLatchAndLeavesTheSourceIntact() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = uniqueHeartDropKeychainService()
        defer { KeychainItem.deleteAll(service: service) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = plantSealKey(service: service)
        try plant(try legacyBlob(Data("[]".utf8), key: key), as: .outbox, in: root)
        let before = try snapshot(root)

        let migrator = makeMigrator(root: root, service: service, defaults: defaults,
                                    writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let result = migrator.performPass()
        #expect(result.convertFailures == 1)
        #expect(result.converted == 0)
        #expect(!result.isClean)
        #expect(!migrator.run())
        #expect(!HeartDropSidecarMigrationLatch(defaults: defaults).isComplete)
        #expect(try snapshot(root) == before, "a failed write left the source modified")
    }

    // MARK: - 10. runAtLaunch: observation beats memory

    /// A set latch is revalidated against the disk: a legacy row under a set latch resets the
    /// latch and re-runs (converting and re-latching in the same launch), while a clean disk
    /// returns true from the marker-only survey without a keychain touch.
    @Test func runAtLaunchRevalidatesASetLatchAgainstTheDisk() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = uniqueHeartDropKeychainService()
        defer { KeychainItem.deleteAll(service: service) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = plantSealKey(service: service)
        let plaintext = Data(#"[{"note":"restored"}]"#.utf8)
        try plant(try legacyBlob(plaintext, key: key), as: .outbox, in: root)
        let latch = HeartDropSidecarMigrationLatch(defaults: defaults)
        latch.markComplete()

        let migrator = makeMigrator(root: root, service: service, defaults: defaults)
        #expect(migrator.runAtLaunch(), "the reset pass converts and re-latches in one launch")
        let converted = try Data(contentsOf: HeartDropOutbox.fileURL(in: root))
        #expect(converted.starts(with: Data("FSC2".utf8)),
                "a set latch outlived a legacy row instead of being revalidated")
        let seal = HeartDropSidecarSeal.make(keychainService: service)
        #expect(try seal.open(converted) == plaintext)
        #expect(HeartDropSidecarMigrationLatch(defaults: defaults).isComplete)

        // A clean disk under a set latch: the marker-only survey confirms, no keychain touch.
        let root2 = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root2) }
        let service2 = uniqueHeartDropKeychainService()
        defer { KeychainItem.deleteAll(service: service2) }
        let migrator2 = makeMigrator(root: root2, service: service2, defaults: defaults)
        #expect(migrator2.runAtLaunch())
        #expect(KeychainItem.load(account: "sidecarSealKey", service: service2) == nil,
                "a clean revalidation touched the keychain")
    }

    /// The reset predicate is the LATCH predicate, not FSC1-only: any blocking-class main row —
    /// here a v0 plaintext outbox, which surveys `unsealedOrUnrecognized` — resets a set latch,
    /// and the run then honestly fails (nothing converted, file untouched, latch left unset), so
    /// the `incomplete` audit signal keeps firing until the store's load resolves the file.
    @Test func aSetLatchIsResetByAnyBlockingClassMainRow() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = uniqueHeartDropKeychainService()
        defer { KeychainItem.deleteAll(service: service) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try plant(Data("[]".utf8), as: .outbox, in: root)
        let latch = HeartDropSidecarMigrationLatch(defaults: defaults)
        latch.markComplete()
        let before = try snapshot(root)

        let migrator = makeMigrator(root: root, service: service, defaults: defaults)
        #expect(!migrator.runAtLaunch(), "a blocking-class row under a set latch must not report complete")
        #expect(!HeartDropSidecarMigrationLatch(defaults: defaults).isComplete,
                "the stale latch survived a corpus its own isClean would refuse")
        #expect(try snapshot(root) == before, "the reset changed a file's fate")
        let result = migrator.performPass()
        #expect(result.unmarkedPending == 1)
        #expect(result.converted == 0)
    }

    // MARK: - 11. Latch unit pins

    /// The latch's whole contract on an isolated suite: absent reads false, markComplete sets,
    /// reset clears — and the funnel's named clear (`resetForDeleteAll`) is a reset.
    @Test func theLatchRoundTripsOnAnIsolatedSuite() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let latch = HeartDropSidecarMigrationLatch(defaults: defaults)
        #expect(!latch.isComplete, "an absent latch must read incomplete — the fail-closed direction")
        latch.markComplete()
        #expect(latch.isComplete)
        latch.reset()
        #expect(!latch.isComplete)

        latch.markComplete()
        HeartDropSidecarMigrationLatch.resetForDeleteAll(defaults: defaults)
        #expect(!latch.isComplete, "the delete-all clear did not reach the latch")
        #expect(HeartDropSidecarMigrationLatch.defaultsKey
                == "com.fernlet.heartdrop.sidecarFormatMigrationComplete")
    }
}
