//
//  SealedPhotoBackupTests.swift
//  FernletTests
//
//  The own-photo escrow route (security-hardening Phase 5, step 5b): one sealed CloudKit record
//  per photo id plus a sealed manifest written LAST as the commit marker. These drive the REAL
//  `SealedPhotoBackupService` over a mock CloudKit record database and a planted escrow identity,
//  so what is asserted is what would actually reach (and come back from) iCloud.
//
//  The properties the scheme exists for, each with a test below:
//  1. INCREMENTAL — sealing photo B leaves A's record byte-identical (the chunked scheme cannot),
//     and the ambient launch pass compares id sets without decrypting the library.
//  2. COMMIT MARKER — bodies without a manifest restore nothing; a manifest id with no openable
//     record fails THAT photo, not the set; an uncommitted body is an ignored orphan.
//  3. ROUND TRIP — including the progress corpus's sidecar (its sealed timeline index), and the
//     MULTI-DEVICE union rule: an upload carries forward ids it does not have and prunes only ids
//     it uploaded itself (own photos never sync device-to-device, so "not mine" ≠ "deleted").
//  4. ROLLBACK — a stale-generation manifest is rejected via the generation high-water mark, and a
//     foreign escrow key classifies as "not yours" rather than "corrupt".
//  5. COORDINATOR POLICY — restore into an empty corpus, never over a full one, and never upload
//     from an empty one.
//  6. NO-CLOBBER — the per-corpus emptiness gate is FILE PRESENCE, not id parsing.
//

import CloudKit
import CloudKitSync
import CryptoKit
import FernletCrypto
import FernletFoundation
import Foundation
import PrivateMediaStore
import ProximityKit
import Security
import Testing
import UIKit
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct SealedPhotoBackupTests {

    // MARK: - Fixtures

    /// A planted escrow private key, so a "second device" can be simulated by planting the same
    /// bytes in a different keychain service (the `SealedBackupFormatPinTests` idiom).
    private func plantedIdentity(escrowRaw: Data? = nil) throws -> (identity: IdentityService, service: String) {
        let service = "com.fernlet.identity.test.sealedphoto.\(UUID().uuidString)"
        let identity = IdentityService(keychainService: service)
        try identity.ensureProvisioned()
        #expect(KeychainItem.store(
            escrowRaw ?? Data((0..<32).map { UInt8($0 &+ 3) }),
            account: "backupEscrowPrivateKey",
            service: service,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            synchronizable: false
        ) == errSecSuccess)
        #expect(identity.loadBackupEscrowKeyForOpen(), "planted escrow key was not discovered")
        return (identity, service)
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "fernlet.tests.sealedPhoto.\(UUID().uuidString)") ?? .standard
    }

    private func makeCloud(_ database: MockPhotoRecordDatabase) -> CloudKitDataService {
        CloudKitDataService(
            accountProvider: AlwaysAvailableAccountProvider(),
            database: database,
            zoneID: CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName),
            isCloudKitSyncEnabled: { true }
        )
    }

    private func makeService(
        identity: IdentityService,
        database: MockPhotoRecordDatabase,
        defaults: UserDefaults
    ) -> SealedPhotoBackupService {
        SealedPhotoBackupService(
            cloudDataService: makeCloud(database),
            identityService: identity,
            generationStore: SealedBackupGenerationStore(defaults: defaults)
        )
    }

    private func jpeg(width: Int, height: Int, color: UIColor = .systemTeal) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.jpegData(compressionQuality: 0.7)!
    }

    // MARK: - 1. Incremental

    /// THE property the per-photo scheme exists for: adding a second photo uploads exactly one new
    /// body plus a rewritten (small) manifest, and leaves the first photo's record byte-identical.
    /// The chunked payload scheme rewrites its whole set on every change, which is why photos are
    /// deliberately NOT a `SealedBackupPayloadType` case.
    @Test func sealingASecondPhotoRewritesOnlyItsOwnRecordAndTheManifest() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())

        let a = UUID()
        let b = UUID()
        try await service.addPhoto(Data("photo A".utf8), id: a, corpus: .meal)
        let recordA = try #require(database.record(named: "sealed-photo.meal.\(a.uuidString)"))
        let sealedABefore = try #require(database.ciphertext(of: recordA))
        let manifestBefore = try #require(database.ciphertext(named: "sealed-photo.meal.manifest"))

        try await service.addPhoto(Data("photo B".utf8), id: b, corpus: .meal)

        #expect(database.ciphertext(named: "sealed-photo.meal.\(a.uuidString)") == sealedABefore,
                "adding photo B rewrote photo A's record — the scheme is not incremental")
        #expect(database.ciphertext(named: "sealed-photo.meal.manifest") != manifestBefore,
                "the manifest was not rewritten, so photo B is not committed")
        #expect(database.recordNames(withPrefix: "sealed-photo.meal.").count == 3,
                "expected two bodies plus one manifest")

        // ...and B really is committed: a restore returns both.
        var restored: [UUID: Data] = [:]
        let summary = try #require(try await service.restore(corpus: .meal) { id, data in
            restored[id] = data
            return true
        })
        #expect(summary.restored == 2)
        #expect(restored[a] == Data("photo A".utf8))
        #expect(restored[b] == Data("photo B".utf8))
    }

    // MARK: - 2. Commit marker

    /// Bodies with no manifest restore NOTHING. That is the commit marker doing its job: an upload
    /// interrupted after the bodies but before the manifest must not restore as a partial set.
    @Test func recordsWithoutAManifestRestoreNothing() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())

        let id = UUID()
        try await service.addPhoto(Data("orphaned body".utf8), id: id, corpus: .recipe)
        // Model the interrupted upload: the body is up, the commit marker never landed.
        database.remove(named: "sealed-photo.recipe.manifest")

        var wrote = 0
        let summary = try await service.restore(corpus: .recipe) { _, _ in
            wrote += 1
            return true
        }
        #expect(summary == nil, "a set with no manifest must restore nothing at all")
        #expect(wrote == 0)
    }

    /// A manifest id whose record is missing (or unopenable, or whose bytes do not match the hash
    /// the manifest committed) fails THAT photo — never the whole set. The other photos still land,
    /// and the failure is reported rather than swallowed.
    @Test func aManifestIDWithNoOpenableRecordFailsThatPhotoOnly() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())

        let good = UUID()
        let missing = UUID()
        let tampered = UUID()
        let bodies: [UUID: Data] = [
            good: Data("good body".utf8),
            missing: Data("missing body".utf8),
            tampered: Data("tampered body".utf8)
        ]
        try await service.reconcile(corpus: .meal, ids: [good, missing, tampered]) { bodies[$0] }

        // One body deleted outright, one body swapped for a DIFFERENT validly-sealed body (the
        // content-hash check is what catches this — the record itself opens fine).
        database.remove(named: "sealed-photo.meal.\(missing.uuidString)")
        let donor = try #require(database.record(named: "sealed-photo.meal.\(good.uuidString)"))
        database.replaceCiphertext(
            named: "sealed-photo.meal.\(tampered.uuidString)",
            with: try #require(database.ciphertext(of: donor))
        )

        var restored: [UUID: Data] = [:]
        let summary = try #require(try await service.restore(corpus: .meal) { id, data in
            restored[id] = data
            return true
        })
        #expect(summary.restored == 1)
        #expect(restored[good] == Data("good body".utf8))
        #expect(Set(summary.failed) == [missing, tampered],
                "a missing body and a substituted body must each fail their own photo, and only theirs")
    }

    /// A record the manifest does not name is an ignored orphan — never restored, and never trusted
    /// just because it sits under a plausible name and is validly sealed.
    @Test func aRecordNotInTheManifestIsAnIgnoredOrphan() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())

        let committed = UUID()
        let orphan = UUID()
        _ = try await service.reconcile(corpus: .meal, ids: [committed]) { _ in Data("committed".utf8) }

        // A body nobody ever committed: an interrupted upload, a failed prune, or an attacker with
        // write access to the container. It is validly sealed and correctly named — the manifest is
        // what makes it a non-member.
        try await makeCloud(database).saveSealedPhoto(
            try SealedPhotoCrypto.seal(
                Data("uncommitted orphan".utf8),
                corpus: .meal,
                slot: .photo(orphan),
                identityService: identity,
                generation: 99,
                keySalt: Data(repeating: 0x22, count: 32)
            )
        )

        var restored: [UUID] = []
        let summary = try #require(try await service.restore(corpus: .meal) { id, _ in
            restored.append(id)
            return true
        })
        #expect(restored == [committed])
        #expect(summary.failed.isEmpty)
    }

    /// MULTI-DEVICE SAFETY: an upload carries forward committed ids it does not have, and removes
    /// ONLY ids it previously uploaded itself.
    ///
    /// Own photos are device-local files that no sync carries between devices, so "not in my id set"
    /// means "my other phone's photo" at least as often as "deleted". Pruning everything unknown
    /// would make each device's pass delete the other's photos — and then re-upload its own on the
    /// next pass, ping-ponging the whole library forever.
    @Test func anUploadCarriesForwardOtherDevicesPhotosAndPrunesOnlyItsOwn() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())

        let mine = UUID()
        let theirs = UUID()
        let bodies: [UUID: Data] = [mine: Data("mine".utf8), theirs: Data("theirs".utf8)]
        _ = try await service.reconcile(corpus: .meal, ids: [mine, theirs]) { bodies[$0] }

        // A device that holds only `mine`, and has only ever uploaded `mine`.
        let carried = try await service.reconcile(
            corpus: .meal,
            ids: [mine],
            prunableIDs: [mine]
        ) { bodies[$0] }
        #expect(carried.pruned == 0, "an id this device never uploaded was pruned")
        var restored: Set<UUID> = []
        _ = try await service.restore(corpus: .meal) { id, _ in
            restored.insert(id)
            return true
        }
        #expect(restored == [mine, theirs], "the other device's photo was dropped from the manifest")

        // Now the same device deletes `mine` locally: it DID upload that one, so it may remove it.
        let pruned = try await service.reconcile(
            corpus: .meal,
            ids: [],
            prunableIDs: [mine]
        ) { bodies[$0] }
        #expect(pruned.pruned == 1)
        #expect(database.record(named: "sealed-photo.meal.\(mine.uuidString)") == nil)
        restored = []
        _ = try await service.restore(corpus: .meal) { id, _ in
            restored.insert(id)
            return true
        }
        #expect(restored == [theirs], "a local delete either failed to propagate or took the other device's photo with it")
    }

    // MARK: - 3. Round trip

    /// Full round trip on the progress corpus, including the SIDECAR — the sealed timeline index.
    /// Without it a restored body-photo corpus is bytes nothing renders, so the index rides inside
    /// the (authenticated) manifest and lands after the photos.
    @Test func progressCorpusRoundTripsBodiesAndItsSealedIndex() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let defaults = isolatedDefaults()
        let service = makeService(identity: identity, database: database, defaults: defaults)

        let first = UUID()
        let second = UUID()
        let bodies: [UUID: Data] = [first: Data("body 1".utf8), second: Data("body 2".utf8)]
        let sidecar = Data("the sealed timeline index".utf8)
        let summary = try await service.reconcile(
            corpus: .progress,
            ids: [first, second],
            sidecar: sidecar
        ) { bodies[$0] }
        #expect(summary.uploaded == 2)

        // A restoring device: fresh keychain, same escrow bytes (the iCloud-Keychain-synced key).
        let (restoringIdentity, restoringService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: restoringService) }
        let restoringSide = makeService(
            identity: restoringIdentity,
            database: database,
            defaults: isolatedDefaults()
        )
        var restored: [UUID: Data] = [:]
        let restoreSummary = try #require(try await restoringSide.restore(corpus: .progress) { id, data in
            restored[id] = data
            return true
        })
        #expect(restoreSummary.restored == 2)
        #expect(restoreSummary.sidecar == sidecar,
                "the sidecar must ride back with the SAME manifest whose generation was checked")
        #expect(restored == bodies)
        #expect(try await restoringSide.sidecar(corpus: .progress) == sidecar)
    }

    /// An unchanged photo is not re-uploaded on the next pass (the content hash decides), and a
    /// photo whose local bytes cannot be read right now KEEPS its cloud copy instead of being
    /// dropped from the manifest — a transient local failure must never delete a good backup.
    @Test func reconcileSkipsUnchangedPhotosAndKeepsUnreadableOnesInTheManifest() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())

        let stable = UUID()
        let flaky = UUID()
        let bodies: [UUID: Data] = [stable: Data("stable".utf8), flaky: Data("flaky".utf8)]
        _ = try await service.reconcile(corpus: .meal, ids: [stable, flaky]) { bodies[$0] }
        let stableBefore = try #require(database.ciphertext(named: "sealed-photo.meal.\(stable.uuidString)"))

        // Second pass: nothing changed locally, and `flaky`'s bytes are momentarily unreadable.
        let second = try await service.reconcile(corpus: .meal, ids: [stable, flaky]) { id in
            id == flaky ? nil : bodies[id]
        }
        #expect(second.uploaded == 0, "an unchanged photo was re-uploaded")
        #expect(second.skipped == 1)
        #expect(second.unreadable == 1)
        #expect(second.pruned == 0, "an unreadable local file pruned a good cloud copy")
        #expect(database.ciphertext(named: "sealed-photo.meal.\(stable.uuidString)") == stableBefore)

        var restored: [UUID: Data] = [:]
        let summary = try #require(try await service.restore(corpus: .meal) { id, data in
            restored[id] = data
            return true
        })
        #expect(summary.restored == 2, "the unreadable photo's cloud copy was lost")
        #expect(restored == bodies)
    }

    /// The LAUNCH pass shape: with hash verification off, an id already committed with a present
    /// record is skipped without its bytes ever being read. That is what keeps launching from
    /// decrypting the user's whole photo library on the main actor — and the honest cost, pinned
    /// here so nobody "fixes" it by accident, is that an in-place replacement waits for a full pass.
    @Test func theLaunchPassComparesIDSetsWithoutReadingCommittedPhotos() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())

        let committed = UUID()
        let fresh = UUID()
        _ = try await service.reconcile(corpus: .meal, ids: [committed]) { _ in Data("original".utf8) }

        var readIDs: [UUID] = []
        let summary = try await service.reconcile(
            corpus: .meal,
            ids: [committed, fresh],
            verifyingContentHashes: false
        ) { id in
            readIDs.append(id)
            return id == fresh ? Data("brand new".utf8) : Data("replaced in place".utf8)
        }
        #expect(readIDs == [fresh], "the launch pass read a photo it had already committed")
        #expect(summary.uploaded == 1)
        #expect(summary.skipped == 1)

        // The replacement really is deferred — the cloud still holds the original bytes...
        var restored: [UUID: Data] = [:]
        _ = try await service.restore(corpus: .meal) { id, data in
            restored[id] = data
            return true
        }
        #expect(restored[committed] == Data("original".utf8))
        #expect(restored[fresh] == Data("brand new".utf8))

        // ...and a FULL pass picks it up.
        let full = try await service.reconcile(corpus: .meal, ids: [committed, fresh]) { id in
            id == fresh ? Data("brand new".utf8) : Data("replaced in place".utf8)
        }
        #expect(full.uploaded == 1)
        restored = [:]
        _ = try await service.restore(corpus: .meal) { id, data in
            restored[id] = data
            return true
        }
        #expect(restored[committed] == Data("replaced in place".utf8))
    }

    /// Deleting a photo drops it from the manifest (the commit) and removes its record; the rest of
    /// the corpus is untouched.
    @Test func deletingAPhotoDropsItFromTheManifestAndRemovesItsRecord() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())

        let keep = UUID()
        let drop = UUID()
        let bodies: [UUID: Data] = [keep: Data("keep".utf8), drop: Data("drop".utf8)]
        _ = try await service.reconcile(corpus: .recipe, ids: [keep, drop]) { bodies[$0] }

        try await service.deletePhoto(id: drop, corpus: .recipe)

        #expect(database.record(named: "sealed-photo.recipe.\(drop.uuidString)") == nil)
        var restored: [UUID] = []
        let summary = try #require(try await service.restore(corpus: .recipe) { id, _ in
            restored.append(id)
            return true
        })
        #expect(restored == [keep])
        #expect(summary.failed.isEmpty)
    }

    /// Teardown removes every body AND the manifest — the "delete everything" / "turn it off" leg.
    @Test func teardownRemovesEveryBodyAndTheManifest() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())

        _ = try await service.reconcile(corpus: .meal, ids: [UUID(), UUID()]) { _ in Data("body".utf8) }
        _ = try await service.reconcile(corpus: .recipe, ids: [UUID()]) { _ in Data("body".utf8) }
        #expect(database.recordNames(withPrefix: "sealed-photo.").count == 5)

        try await service.deleteCorpus(.meal)

        #expect(database.recordNames(withPrefix: "sealed-photo.meal.").isEmpty,
                "teardown left own-photo records in iCloud")
        #expect(database.recordNames(withPrefix: "sealed-photo.recipe.").count == 2,
                "teardown of one corpus reached another")
    }

    // MARK: - 4. Rollback / identity

    /// A manifest older than one this device already accepted is refused via the photo-namespaced
    /// generation high-water mark — the same rollback defense as the chunked route, and checked
    /// AFTER the AEAD has authenticated the generation it claims.
    @Test func aStaleGenerationManifestIsRejected() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let defaults = isolatedDefaults()
        let service = makeService(identity: identity, database: database, defaults: defaults)

        let id = UUID()
        _ = try await service.reconcile(corpus: .meal, ids: [id]) { _ in Data("generation 1".utf8) }
        let staleManifest = try #require(database.record(named: "sealed-photo.meal.manifest")?.copy() as? CKRecord)
        let staleBody = try #require(database.record(named: "sealed-photo.meal.\(id.uuidString)")?.copy() as? CKRecord)

        // Move forward, then substitute the whole earlier generation back in — every byte of it is
        // authentic, which is exactly why the AEAD alone cannot catch this.
        _ = try await service.reconcile(corpus: .meal, ids: [id]) { _ in Data("generation 2".utf8) }
        database.overwrite(staleManifest)
        database.overwrite(staleBody)

        await #expect(throws: SealedBackupError.self) {
            _ = try await service.restore(corpus: .meal) { _, _ in true }
        }
    }

    /// A manifest sealed under somebody else's escrow key classifies as `notRecognized` (not
    /// "corrupt"), so the UI can say "this isn't your backup" instead of implying data loss.
    @Test func aForeignEscrowKeyManifestClassifiesAsNotRecognized() async throws {
        let (foreign, foreignService) = try plantedIdentity(
            escrowRaw: Data((0..<32).map { UInt8(0xA0 &+ $0) })
        )
        defer { KeychainItem.deleteAll(service: foreignService) }
        let database = MockPhotoRecordDatabase()
        let foreignSide = makeService(identity: foreign, database: database, defaults: isolatedDefaults())
        _ = try await foreignSide.reconcile(corpus: .meal, ids: [UUID()]) { _ in Data("not yours".utf8) }

        let (mine, myService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: myService) }
        let mySide = makeService(identity: mine, database: database, defaults: isolatedDefaults())

        await #expect(throws: SealedBackupError.keyAgreementIdentityMismatch) {
            _ = try await mySide.restore(corpus: .meal) { _, _ in true }
        }
    }

    /// A record moved to another slot or corpus does not open: the AAD binds the corpus and the
    /// record's own name suffix, so relabelling is not a way to smuggle a photo somewhere else.
    @Test func aRecordCannotBeReplayedIntoAnotherSlotOrCorpus() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }

        let id = UUID()
        let record = try SealedPhotoCrypto.seal(
            Data("body".utf8),
            corpus: .meal,
            slot: .photo(id),
            identityService: identity,
            generation: 4,
            keySalt: Data(repeating: 0x11, count: 32)
        )
        #expect(try SealedPhotoCrypto.open(record, identityService: identity) == Data("body".utf8))

        var movedCorpus = record
        movedCorpus.corpus = .progress
        #expect(throws: SealedBackupError.malformedRecord) {
            _ = try SealedPhotoCrypto.open(movedCorpus, identityService: identity)
        }

        var movedSlot = record
        movedSlot.slot = .photo(UUID())
        #expect(throws: SealedBackupError.malformedRecord) {
            _ = try SealedPhotoCrypto.open(movedSlot, identityService: identity)
        }

        var promotedToManifest = record
        promotedToManifest.slot = .manifest
        #expect(throws: SealedBackupError.malformedRecord) {
            _ = try SealedPhotoCrypto.open(promotedToManifest, identityService: identity)
        }
    }

    // MARK: - 5. Coordinator policy: restore before re-upload, per corpus

    /// The whole 5b-4 contract, end to end through `OwnPhotoBackupCoordinator`: a device with photos
    /// uploads them; a FRESH device (empty corpus) restores them; and a device that already has its
    /// OWN photo is never restored over — it uploads instead. The last leg is the one that matters:
    /// an empty-corpus check that was per-device rather than per-corpus, or a re-upload that ran
    /// before the restore, would each destroy exactly the photos this route exists to protect.
    @Test func coordinatorRestoresIntoAnEmptyCorpusAndNeverOverAFullOne() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()

        // Device 1: one meal photo, sealed under the real own-photos key the coordinator uses.
        let deviceOne = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: deviceOne) }
        let uploadedID = try #require(mealStore(in: deviceOne).save(jpeg(width: 120, height: 90)))
        let uploadedBytes = try #require(mealStore(in: deviceOne).imageData(for: uploadedID))

        let hostOne = RecordingOwnPhotoHost()
        let coordinatorOne = OwnPhotoBackupCoordinator(
            host: hostOne,
            documentsDirectory: deviceOne,
            identityFactory: { identity },
            cloudFactory: { self.makeCloud(database) },
            defaults: isolatedDefaults()
        )
        #expect(await coordinatorOne.setEnabled(true))
        #expect(database.recordNames(withPrefix: "sealed-photo.meal.").count == 2,
                "expected one body plus the manifest")

        // Device 2: empty meal corpus → restores.
        let deviceTwo = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: deviceTwo) }
        let hostTwo = RecordingOwnPhotoHost()
        let coordinatorTwo = OwnPhotoBackupCoordinator(
            host: hostTwo,
            documentsDirectory: deviceTwo,
            identityFactory: { identity },
            cloudFactory: { self.makeCloud(database) },
            defaults: isolatedDefaults()
        )
        _ = await coordinatorTwo.synchronize(preferenceOverride: true)
        #expect(mealStore(in: deviceTwo).imageData(for: uploadedID) == uploadedBytes,
                "the photo did not restore onto the empty device")
        #expect(hostTwo.outcomes.last == .restored(1))

        // Device 3: already holds its OWN different photo → must NOT be restored into, and must
        // upload rather than be overwritten.
        let deviceThree = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: deviceThree) }
        let localID = try #require(mealStore(in: deviceThree).save(jpeg(width: 80, height: 80, color: .systemPink)))
        let localBytes = try #require(mealStore(in: deviceThree).imageData(for: localID))
        let hostThree = RecordingOwnPhotoHost()
        let coordinatorThree = OwnPhotoBackupCoordinator(
            host: hostThree,
            documentsDirectory: deviceThree,
            identityFactory: { identity },
            cloudFactory: { self.makeCloud(database) },
            defaults: isolatedDefaults()
        )
        _ = await coordinatorThree.synchronize(preferenceOverride: true)

        #expect(mealStore(in: deviceThree).imageData(for: localID) == localBytes,
                "a non-empty corpus was restored into")
        #expect(mealStore(in: deviceThree).imageData(for: uploadedID) == nil,
                "the other device's photo was restored over a corpus that was already in use")
        #expect(mealStore(in: deviceThree).storedPhotoIDs() == [localID])
        // ...and its own photo reached the cloud, joining rather than replacing the committed set.
        #expect(database.recordNames(withPrefix: "sealed-photo.meal.").count == 3)
        var restored: Set<UUID> = []
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())
        _ = try await service.restore(corpus: .meal) { id, _ in
            restored.insert(id)
            return true
        }
        #expect(restored == [uploadedID, localID],
                "the third device's upload dropped the first device's photo from the manifest")
    }

    /// An empty corpus NEVER uploads. A device that has not restored yet is empty for exactly the
    /// reason the backup exists, so exporting from it would replace the committed manifest with an
    /// empty one — the clobber that costs the user everything.
    @Test func anEmptyCorpusNeverUploadsOverACommittedManifest() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()

        // A committed cloud set whose bodies cannot be restored here (the manifest names an id whose
        // record was lost), so the local corpus STAYS empty across the pass.
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())
        let strandedID = UUID()
        _ = try await service.reconcile(corpus: .meal, ids: [strandedID]) { _ in Data("committed".utf8) }
        database.remove(named: "sealed-photo.meal.\(strandedID.uuidString)")
        let manifestBefore = try #require(database.ciphertext(named: "sealed-photo.meal.manifest"))

        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }
        let host = RecordingOwnPhotoHost()
        let coordinator = OwnPhotoBackupCoordinator(
            host: host,
            documentsDirectory: device,
            identityFactory: { identity },
            cloudFactory: { self.makeCloud(database) },
            defaults: isolatedDefaults()
        )
        _ = await coordinator.synchronize(preferenceOverride: true)

        #expect(database.ciphertext(named: "sealed-photo.meal.manifest") == manifestBefore,
                "an empty corpus rewrote the committed manifest — a device that has not restored yet just destroyed the backup")
        // The failure is surfaced, not swallowed: a partial restore is retryable, and the user sees it.
        #expect(host.outcomes.last?.needsAttention == true)
        #expect(host.outcomes.last?.isRetryable == true)
    }

    private func temporaryDocumentsDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwnPhotoBackupDocs-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A meal-photo store over the SAME directory and the SAME (real, device-keychain) own-photos key
    /// the coordinator builds internally, so a test can seed and inspect what it reads and writes.
    private func mealStore(in documentsDirectory: URL) -> MealPhotoStore {
        MealPhotoStore(
            directory: OwnPhotoCorpusLayout.mealPhotosDirectory(in: documentsDirectory),
            keyProvider: KeychainPrivateMediaKeyProvider(role: .ownPhotos)
        )
    }

    // MARK: - 6. Per-corpus no-clobber gate

    /// The emptiness gate that decides whether a corpus may be restored INTO is file presence, not
    /// "no ids I can parse": a corpus holding bytes this build cannot name is still in use, and
    /// restoring over it would clobber the user's photos.
    @Test func corpusEmptinessGateIsFilePresenceNotIDParsing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SealedPhotoNoClobber-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MealPhotoStore(
            directory: directory,
            keyProvider: InMemoryPrivateMediaKeyProvider(),
            allowsLegacyPlaintextUpgrade: false
        )
        #expect(store.isEmptyForRestore(), "a brand-new corpus must read as empty")

        // A file whose name is not a UUID: unparseable, but unmistakably data on disk.
        try Data("something".utf8).write(to: directory.appendingPathComponent("not-a-uuid.jpg"))
        #expect(store.storedPhotoIDs().isEmpty)
        #expect(!store.isEmptyForRestore(), "an unparseable file must still count as 'this corpus is in use'")
    }

    /// The progress corpus is empty only when BOTH halves are: an index-only corpus (photos deleted,
    /// timeline kept) and a bytes-only corpus (index lost) are each in use.
    @Test func progressCorpusEmptinessRequiresBothIndexAndBytesAbsent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SealedPhotoProgress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProgressPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider())
        #expect(store.isEmptyForRestore())

        let record = try #require(store.add(jpeg(width: 60, height: 60), caption: "week 1", capturedAt: Date()))
        #expect(!store.isEmptyForRestore())

        // Bytes gone, index kept — still in use.
        store.delete(id: record.id)
        #expect(!store.isEmptyForRestore(), "an index with no photos still describes the user's timeline")
    }

    /// The sidecar round-trips through the store seam: an unreadable index refuses to be exported
    /// (nil, so the caller skips the corpus rather than uploading "you have no photos"), and a
    /// restored index refuses to overwrite one that already exists.
    @Test func sidecarExportRefusesAnUnreadableIndexAndRestoreRefusesToClobber() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SealedPhotoSidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProgressPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider())

        // The payload is encoded the way the store seals it — ISO-8601 dates — so a reader has to
        // decode it the same way.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Absent index → an honest encoded empty timeline, not nil.
        let empty = try #require(store.backupIndexPayload())
        #expect((try? decoder.decode([ProgressPhotoRecord].self, from: empty))?.isEmpty == true)

        let record = try #require(store.add(jpeg(width: 60, height: 60), caption: "week 2", capturedAt: Date()))
        // The exported payload is the index PLAINTEXT — it is sealed by the manifest record it
        // rides in, not here — so it decodes straight back to the timeline.
        let payload = try #require(store.backupIndexPayload())
        #expect(try decoder.decode([ProgressPhotoRecord].self, from: payload).map(\.caption) == ["week 2"])
        #expect(store.records().map(\.id) == [record.id])

        // A restore into a corpus that already has an index is refused.
        #expect(!store.restoreIndexPayload(payload), "a restored index overwrote an existing timeline")

        // Present-but-unreadable index → nil, so the upload path skips the corpus.
        try Data("garbage that is not sealed".utf8)
            .write(to: directory.appendingPathComponent("index.bin"))
        #expect(store.backupIndexPayload() == nil)

        // ...and into a genuinely empty corpus it lands.
        let freshDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SealedPhotoSidecarFresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: freshDirectory) }
        let fresh = ProgressPhotoStore(directory: freshDirectory, keyProvider: InMemoryPrivateMediaKeyProvider())
        #expect(fresh.restoreIndexPayload(payload))
        #expect(fresh.records().map(\.id) == [record.id])
    }

    /// Restored bytes are sealed AS-IS: no second lossy re-encode, and therefore a stable content
    /// hash, which is what keeps the next backup pass from re-uploading the whole restored corpus.
    @Test func restoringSealedBytesPreservesThemExactlyForTheNextContentHash() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SealedPhotoRestore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MealPhotoStore(
            directory: directory,
            keyProvider: InMemoryPrivateMediaKeyProvider(),
            allowsLegacyPlaintextUpgrade: false
        )

        // What a backup would have uploaded: an already-normalized photo read back out of a store.
        let source = MealPhotoStore(
            directory: directory.appendingPathComponent("source", isDirectory: true),
            keyProvider: InMemoryPrivateMediaKeyProvider(),
            allowsLegacyPlaintextUpgrade: false
        )
        let sourceID = try #require(source.save(jpeg(width: 120, height: 90)))
        let uploaded = try #require(source.imageData(for: sourceID))

        let id = UUID()
        #expect(store.restoreSealedPhoto(uploaded, forID: id))
        #expect(store.imageData(for: id) == uploaded,
                "restored bytes were re-encoded — the manifest's content hash would never match again")
        #expect(store.storedPhotoIDs() == [id])

        // Fail-closed backstop: bytes that are not an image are refused, nothing written.
        let junk = UUID()
        #expect(!store.restoreSealedPhoto(Data("not an image".utf8), forID: junk))
        #expect(store.imageData(for: junk) == nil)
    }

    // MARK: - 7. Custody / recovery regressions (adversarial review, 2026-08-11)

    /// A progress-photo store over the SAME directory and key the coordinator builds internally.
    private func progressStore(in documentsDirectory: URL) -> ProgressPhotoStore {
        ProgressPhotoStore(
            directory: OwnPhotoCorpusLayout.progressPhotosDirectory(in: documentsDirectory),
            keyProvider: KeychainPrivateMediaKeyProvider(role: .ownPhotos)
        )
    }

    /// A coordinator plus the host it reports to. The host comes back with it because the
    /// coordinator holds it `unowned` — an inline `RecordingOwnPhotoHost()` is deallocated the
    /// instant the call returns, and the first status it publishes traps.
    private func makeCoordinator(
        documents: URL,
        identity: IdentityService,
        database: MockPhotoRecordDatabase,
        defaults: UserDefaults
    ) -> (coordinator: OwnPhotoBackupCoordinator, host: RecordingOwnPhotoHost) {
        let host = RecordingOwnPhotoHost()
        return (
            OwnPhotoBackupCoordinator(
                host: host,
                documentsDirectory: documents,
                identityFactory: { identity },
                cloudFactory: { self.makeCloud(database) },
                defaults: defaults
            ),
            host
        )
    }

    /// THE phone-swap case, and the one the whole route exists for: after the own-photos key is
    /// device-bound, a device backup restored onto a NEW phone brings the sealed photo FILES back
    /// without the key, so every one of them is permanently unopenable. A file-PRESENCE gate reads
    /// that as "this corpus is in use" and declines the escrow restore — the user paid iCloud quota
    /// for a backup that then refuses to restore. The gate must tell "not empty" from "holds only
    /// bytes this install can never open".
    @Test func aCorpusOfUnopenableBytesIsRestoredIntoRatherThanReadAsInUse() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()

        let deviceOne = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: deviceOne) }
        let uploadedID = try #require(mealStore(in: deviceOne).save(jpeg(width: 120, height: 90)))
        let uploadedBytes = try #require(mealStore(in: deviceOne).imageData(for: uploadedID))
        let progressRecord = try #require(
            progressStore(in: deviceOne).add(jpeg(width: 80, height: 80), caption: "week 1", capturedAt: Date())
        )
        let progressBytes = try #require(progressStore(in: deviceOne).imageData(for: progressRecord.id))
        let one = makeCoordinator(
            documents: deviceOne, identity: identity, database: database, defaults: isolatedDefaults()
        )
        #expect(await one.coordinator.setEnabled(true))

        // The new phone: the files are there, none of them opens under any key this install holds.
        // The progress corpus additionally carries a sealed index in the same state — dead bytes
        // that would otherwise refuse the restored timeline and leave the bodies unrenderable.
        let deviceTwo = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: deviceTwo) }
        let deadBytes = Data(repeating: 0xAB, count: 512)
        let strandedMeal = OwnPhotoCorpusLayout.mealPhotosDirectory(in: deviceTwo)
        try FileManager.default.createDirectory(at: strandedMeal, withIntermediateDirectories: true)
        try deadBytes.write(to: strandedMeal.appendingPathComponent("\(UUID().uuidString).jpg"))
        let progressRoot = OwnPhotoCorpusLayout.progressPhotosDirectory(in: deviceTwo)
        let strandedProgress = progressRoot
            .appendingPathComponent(OwnPhotoCorpusLayout.progressPhotosInnerDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: strandedProgress, withIntermediateDirectories: true)
        try deadBytes.write(to: strandedProgress.appendingPathComponent("\(UUID().uuidString).jpg"))
        try deadBytes.write(to: progressRoot.appendingPathComponent(OwnPhotoCorpusLayout.progressIndexFileName))

        #expect(!mealStore(in: deviceTwo).isEmptyForRestore(),
                "the file-presence half of the gate must still read this corpus as non-empty")
        #expect(mealStore(in: deviceTwo).holdsOnlyUnopenableFiles())
        #expect(!progressStore(in: deviceTwo).isEmptyForRestore())
        #expect(progressStore(in: deviceTwo).holdsOnlyUnopenableFiles())

        let two = makeCoordinator(
            documents: deviceTwo, identity: identity, database: database, defaults: isolatedDefaults()
        )
        _ = await two.coordinator.synchronize(preferenceOverride: true)

        #expect(mealStore(in: deviceTwo).imageData(for: uploadedID) == uploadedBytes,
                "the escrow restore was skipped on the exact device it exists for")
        #expect(progressStore(in: deviceTwo).records().map(\.caption) == ["week 1"],
                "the dead sealed index refused the restored timeline, so the bodies render nowhere")
        #expect(progressStore(in: deviceTwo).imageData(for: progressRecord.id) == progressBytes)
        #expect(two.host.outcomes.last == .restored(2))
    }

    /// ...and the second half of that gate, which is why the stranded files are never deleted to
    /// achieve it: a pre-sealing PLAINTEXT meal photo opens under no key either, yet the read path
    /// still returns it (and re-seals it on access). It is live data, not stranded bytes — a corpus
    /// holding one must never be restored over. The corpora with no plaintext generation (recipe,
    /// progress bodies) refuse those same bytes, so for them it really is dead weight.
    @Test func legacyPlaintextIsNotMistakenForStrandedBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SealedPhotoStranded-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plaintextPhoto = jpeg(width: 60, height: 60)

        let mealLike = MealPhotoStore(
            directory: root.appendingPathComponent("meal", isDirectory: true),
            keyProvider: InMemoryPrivateMediaKeyProvider(),
            allowsLegacyPlaintextUpgrade: true
        )
        try plaintextPhoto.write(to: root.appendingPathComponent("meal/\(UUID().uuidString).jpg"))
        #expect(!mealLike.isEmptyForRestore())
        #expect(!mealLike.holdsOnlyUnopenableFiles(),
                "a pre-sealing plaintext photo the read path still returns was written off as stranded")

        let sealedOnly = MealPhotoStore(
            directory: root.appendingPathComponent("recipe", isDirectory: true),
            keyProvider: InMemoryPrivateMediaKeyProvider(),
            allowsLegacyPlaintextUpgrade: false
        )
        try plaintextPhoto.write(to: root.appendingPathComponent("recipe/\(UUID().uuidString).jpg"))
        #expect(sealedOnly.holdsOnlyUnopenableFiles())

        // Fail-closed everywhere else: an empty corpus is not "stranded", and neither is one this
        // install has no key for.
        let empty = MealPhotoStore(
            directory: root.appendingPathComponent("empty", isDirectory: true),
            keyProvider: InMemoryPrivateMediaKeyProvider(),
            allowsLegacyPlaintextUpgrade: false
        )
        #expect(!empty.holdsOnlyUnopenableFiles())
        let keyless = MealPhotoStore(
            directory: root.appendingPathComponent("recipe", isDirectory: true),
            keyProvider: NoMediaKeyProvider(),
            allowsLegacyPlaintextUpgrade: false
        )
        #expect(!keyless.holdsOnlyUnopenableFiles(),
                "'I cannot look' must never read as 'these bytes are dead'")
    }

    /// Enabling the backup must report FAILURE when nothing reached iCloud. The caller persists the
    /// preference and IRREVERSIBLY device-binds the own-photos key on that return value, so a `true`
    /// after an upload that committed nothing takes away the device-backup route without having
    /// built the replacement — and the failure was invisible: a device that HAS photos never enters
    /// the restore branch, so the pass published `.nothingToRestore`.
    @Test func enablingReportsFailureWhenNothingReachedICloud() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        database.failSaves = true

        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }
        _ = try #require(mealStore(in: device).save(jpeg(width: 100, height: 100)))

        let defaults = isolatedDefaults()
        let (coordinator, host) = makeCoordinator(
            documents: device, identity: identity, database: database, defaults: defaults
        )

        #expect(await coordinator.setEnabled(true) == false,
                "enabling claimed success after an upload that reached nothing")
        #expect(database.recordNames(withPrefix: "sealed-photo.").isEmpty)
        #expect(host.uploadFailures.last == true, "the upload failure never reached the banner")
        #expect(!OwnPhotoEscrowCommitLedger(defaults: defaults).isCommitted)

        // ...and the binding gate refuses on that proof even with the migration latch satisfied.
        let bindingDefaults = isolatedDefaults()
        OwnPhotoMigrationLatch(defaults: bindingDefaults).markComplete()
        #expect(
            OwnPhotoKeyBinder(
                escrowRouteCommitted: OwnPhotoEscrowCommitLedger(defaults: defaults).isCommitted,
                defaults: bindingDefaults
            ).bindIfEligible() == .refusedNoRecoveryRoute,
            "the key was device-bound on a route that has never committed a single record"
        )

        // Once the transport recovers, the same coordinator commits and the proof follows.
        database.failSaves = false
        #expect(await coordinator.setEnabled(true))
        #expect(OwnPhotoEscrowCommitLedger(defaults: defaults).isCommitted)
        #expect(host.uploadFailures.last == false)
    }

    /// A partial restore used to be terminal: the first successful write makes the corpus non-empty,
    /// the emptiness gate closes, and the ids that failed can never be fetched again on any launch
    /// or Retry — while their sealed bodies sit intact in iCloud. The repair ledger remembers
    /// exactly those ids and the next pass fetches them, gate or no gate.
    @Test func aPartialRestoreIsRepairedOnTheNextPass() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()

        let deviceOne = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: deviceOne) }
        let landedID = try #require(mealStore(in: deviceOne).save(jpeg(width: 90, height: 90)))
        let strandedID = try #require(mealStore(in: deviceOne).save(jpeg(width: 70, height: 110, color: .systemPink)))
        let landedBytes = try #require(mealStore(in: deviceOne).imageData(for: landedID))
        let strandedBytes = try #require(mealStore(in: deviceOne).imageData(for: strandedID))
        let one = makeCoordinator(
            documents: deviceOne, identity: identity, database: database, defaults: isolatedDefaults()
        )
        #expect(await one.coordinator.setEnabled(true))

        // One body drops out mid-restore (a transient CloudKit fetch failure), the rest lands.
        database.unfetchableRecordNames = ["sealed-photo.meal.\(strandedID.uuidString)"]

        let deviceTwo = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: deviceTwo) }
        let defaultsTwo = isolatedDefaults()
        let (coordinatorTwo, hostTwo) = makeCoordinator(
            documents: deviceTwo, identity: identity, database: database, defaults: defaultsTwo
        )
        _ = await coordinatorTwo.synchronize(preferenceOverride: true)

        #expect(mealStore(in: deviceTwo).imageData(for: landedID) == landedBytes)
        #expect(mealStore(in: deviceTwo).imageData(for: strandedID) == nil)
        #expect(!mealStore(in: deviceTwo).isEmptyForRestore(),
                "the restore itself is what closes the emptiness gate — that is the trap")
        #expect(hostTwo.outcomes.last?.isRetryable == true)
        #expect(OwnPhotoRestoreRepairLedger(defaults: defaultsTwo).pendingIDs(for: .meal) == [strandedID])

        // The transient failure clears. The next pass must fetch exactly the owed id.
        database.unfetchableRecordNames = []
        _ = await coordinatorTwo.synchronize(preferenceOverride: true)

        #expect(mealStore(in: deviceTwo).imageData(for: strandedID) == strandedBytes,
                "the ids a partial restore left behind were unrecoverable through any UI")
        #expect(mealStore(in: deviceTwo).imageData(for: landedID) == landedBytes)
        #expect(OwnPhotoRestoreRepairLedger(defaults: defaultsTwo).pendingIDs(for: .meal).isEmpty)
    }

    /// The coordinator half of the terminal-refusal pin: a permanently unverifiable entry must not
    /// enter the repair ledger, and must not pin the route uncommitted.
    ///
    /// This is the exact cascade the crypto-standardization plan warned Phase 3 could start. The
    /// entry cannot be verified by anything this build ships, so a retry re-fetches the same record
    /// and fails identically; if it were queued, `pendingIDs` would be non-empty on every launch,
    /// every launch would run the same doomed repair, the corpus would answer `.deferredTransient`,
    /// and `OwnPhotoEscrowCommitLedger` would read false forever — which is what withholds the
    /// irreversible own-photo key binding. All three are asserted here, not just the ledger.
    @Test func anUnverifiableLegacyEntryNeverEntersTheRepairLedger() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        _ = try await plantLegacyMealBackup(identity: identity, database: database)

        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }
        let defaults = isolatedDefaults()
        let (coordinator, host) = makeCoordinator(
            documents: device, identity: identity, database: database, defaults: defaults
        )
        let pass = await coordinator.synchronize(preferenceOverride: true)

        #expect(OwnPhotoRestoreRepairLedger(defaults: defaults).pendingIDs(for: .meal).isEmpty,
                "a doomed repair was queued: every launch would re-fetch a record nothing can verify")
        #expect(pass.routeCommitted, "the route was pinned uncommitted by an unrecoverable photo")
        #expect(OwnPhotoEscrowCommitLedger(defaults: defaults).isCommitted)
        #expect(host.outcomes.last?.isRetryable != true,
                "an unrecoverable entry was reported as retryable, which invites an endless Retry")

        // A second pass behaves identically — the state is stable, not a treadmill.
        let second = await coordinator.synchronize(preferenceOverride: true)
        #expect(second.routeCommitted)
        #expect(OwnPhotoRestoreRepairLedger(defaults: defaults).pendingIDs(for: .meal).isEmpty)
    }

    /// The progress corpus's sidecar (its sealed timeline index) is what makes that corpus
    /// "not empty". Committing it after a restore in which ZERO bodies landed would lock the corpus
    /// out of every future restore on the first attempt — a timeline of missing pictures, forever,
    /// while every sealed body sits intact in iCloud.
    @Test func aRestoreThatLandsNoBodiesDoesNotCommitTheProgressIndex() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()

        let deviceOne = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: deviceOne) }
        let record = try #require(
            progressStore(in: deviceOne).add(jpeg(width: 80, height: 80), caption: "week 1", capturedAt: Date())
        )
        let bodyBytes = try #require(progressStore(in: deviceOne).imageData(for: record.id))
        let one = makeCoordinator(
            documents: deviceOne, identity: identity, database: database, defaults: isolatedDefaults()
        )
        #expect(await one.coordinator.setEnabled(true))

        // Every body is unfetchable: the manifest opens, not one picture arrives.
        database.unfetchableRecordNames = ["sealed-photo.progress.\(record.id.uuidString)"]

        let deviceTwo = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: deviceTwo) }
        let defaultsTwo = isolatedDefaults()
        let two = makeCoordinator(
            documents: deviceTwo, identity: identity, database: database, defaults: defaultsTwo
        )
        _ = await two.coordinator.synchronize(preferenceOverride: true)

        #expect(progressStore(in: deviceTwo).records().isEmpty)
        #expect(progressStore(in: deviceTwo).isEmptyForRestore(),
                "an index was committed over a restore in which nothing landed — the corpus is now permanently 'in use'")

        database.unfetchableRecordNames = []
        _ = await two.coordinator.synchronize(preferenceOverride: true)

        #expect(progressStore(in: deviceTwo).records().map(\.caption) == ["week 1"])
        #expect(progressStore(in: deviceTwo).imageData(for: record.id) == bodyBytes)
    }

    /// The manifest is the sole authority on membership, so "I could not READ what was committed"
    /// must never be treated as "nothing was committed". Rewriting it from this device's ids alone
    /// leaves the other device's bodies in iCloud as permanently unnamed orphans that no code path
    /// can re-adopt.
    @Test func anUnreadableManifestIsNeverReplacedByThisDevicesIDsAlone() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()

        let deviceOne = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: deviceOne) }
        let committedID = try #require(mealStore(in: deviceOne).save(jpeg(width: 120, height: 90)))
        let one = makeCoordinator(
            documents: deviceOne, identity: identity, database: database, defaults: isolatedDefaults()
        )
        #expect(await one.coordinator.setEnabled(true))

        // The manifest becomes unreadable — corrupt bytes here; a dropped fetch or a foreign escrow
        // identity land in exactly the same place.
        database.replaceCiphertext(named: "sealed-photo.meal.manifest", with: Data("not openable".utf8))
        let corrupted = try #require(database.ciphertext(named: "sealed-photo.meal.manifest"))

        // Device 2 holds its own photo, so it never restores — it goes straight to the upload leg.
        let deviceTwo = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: deviceTwo) }
        _ = try #require(mealStore(in: deviceTwo).save(jpeg(width: 60, height: 60, color: .systemPink)))
        let two = makeCoordinator(
            documents: deviceTwo, identity: identity, database: database, defaults: isolatedDefaults()
        )
        _ = await two.coordinator.synchronize(preferenceOverride: true)

        #expect(database.ciphertext(named: "sealed-photo.meal.manifest") == corrupted,
                "a manifest this device could not read was replaced by one naming only its own ids")
        #expect(database.record(named: "sealed-photo.meal.\(committedID.uuidString)") != nil,
                "the other device's committed body lost the only thing that named it")
        #expect(two.host.uploadFailures.last == true, "the refusal was silent")
    }

    /// A corpus the user has EMPTIED is empty for the opposite reason a fresh device's is. Restoring
    /// there writes every deleted photo back to disk as an orphan that nothing references, renders
    /// nowhere, and cannot be removed through any UI — "delete my food photos" undoing itself on
    /// relaunch. The delete must propagate to the backup instead.
    @Test func anEmptiedCorpusPrunesInsteadOfResurrectingTheDeletedPhotos() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()

        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }
        let photoID = try #require(mealStore(in: device).save(jpeg(width: 120, height: 90)))
        let defaults = isolatedDefaults()
        let (coordinator, host) = makeCoordinator(
            documents: device, identity: identity, database: database, defaults: defaults
        )
        #expect(await coordinator.setEnabled(true))
        #expect(host.uploadFailures.last == false)
        #expect(database.recordNames(withPrefix: "sealed-photo.meal.").count == 2)

        // The user deletes their last meal photo.
        mealStore(in: device).delete(id: photoID)
        #expect(mealStore(in: device).isEmptyForRestore())

        _ = await coordinator.synchronize(preferenceOverride: true)
        #expect(mealStore(in: device).storedPhotoIDs().isEmpty,
                "a deleted photo was written back to disk from the backup")
        #expect(database.record(named: "sealed-photo.meal.\(photoID.uuidString)") == nil,
                "the delete never reached the backup, so it would resurrect on any later restore")

        // ...and it stays deleted: a corpus with nothing left to prune neither restores nor rewrites.
        let manifestAfterPrune = database.ciphertext(named: "sealed-photo.meal.manifest")
        _ = await coordinator.synchronize(preferenceOverride: true)
        #expect(mealStore(in: device).storedPhotoIDs().isEmpty)
        #expect(database.ciphertext(named: "sealed-photo.meal.manifest") == manifestAfterPrune)
    }

    /// The THIRD upload-side status reaching the host (WS-4). A full-verification pass that could
    /// not read some of the user's photos still COMMITS — the manifest names everything it could
    /// see — so `recordOwnPhotoBackupUploadFailed(_:)` correctly says `false` and the restore
    /// vocabulary never speaks at all. Without its own signal the pass reads as clean while exactly
    /// the gap verification exists to find goes unreported: those photos may be missing from the
    /// backup or stale in it, and nothing but a pass that reads every byte can tell which. The
    /// ambient pass has no verdict to publish — it reads almost nothing — so it must leave the last
    /// full pass's count standing rather than overwrite it with a near-zero it never earned.
    @Test func aFullPassPublishesHowManyPhotosItCouldNotRead() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()

        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }
        _ = try #require(mealStore(in: device).save(jpeg(width: 120, height: 90)))
        let unreadableID = try #require(mealStore(in: device).save(jpeg(width: 80, height: 80, color: .systemPink)))

        // Deny read on ONE photo's file — the closest a test gets to a Complete-class file whose
        // protected data is unavailable (the `OwnPhotoKeyMigrationTests` idiom). Permissions are
        // restored before teardown so the directory can still be removed.
        let unreadableURL = OwnPhotoCorpusLayout.mealPhotosDirectory(in: device)
            .appendingPathComponent("\(unreadableID.uuidString).jpg")
        #expect(FileManager.default.fileExists(atPath: unreadableURL.path))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadableURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadableURL.path)
        }

        // The corpus still holds one photo this install opens, so it is neither empty nor
        // all-stranded: the pass goes straight to the upload leg and never touches the restore gate.
        #expect(!mealStore(in: device).isEmptyForRestore())
        #expect(!mealStore(in: device).holdsOnlyUnopenableFiles(),
                "'I cannot read this file' must never read as 'these bytes are dead'")

        let (coordinator, host) = makeCoordinator(
            documents: device, identity: identity, database: database, defaults: isolatedDefaults()
        )
        #expect(await coordinator.setEnabled(true))
        #expect(host.uploadFailures.last == false,
                "the manifest committed for everything this device could see — that is not an upload failure")
        #expect(host.verifiedUnreadableCounts.last == 1,
                "a committed-but-not-clean pass was reported as clean, so the gap never reached the banner")

        // The ambient pass publishes NOTHING here, rather than a count of bytes it never read.
        let afterFullPass = host.verifiedUnreadableCounts.count
        _ = await coordinator.synchronize(preferenceOverride: true)
        #expect(host.verifiedUnreadableCounts.count == afterFullPass,
                "an ambient pass overwrote the last full pass's verdict")

        // ...and a full pass that finally reads everything clears the state.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadableURL.path)
        _ = await coordinator.synchronize(preferenceOverride: true, fullVerification: true)
        #expect(host.verifiedUnreadableCounts.last == 0, "a clean full pass left the warning standing")
    }

    // MARK: - 8. Hash-version marker (crypto standardization Phase 1)

    /// The manifest plaintext a PRE-MARKER build wrote: `id` + `contentHash`, and no `hashVersion`
    /// key at all. Hand-built rather than encoded, because no build that still exists can produce
    /// it — `Entry` always writes the field now — and the field's ABSENCE is the whole fixture. The
    /// spellings are `JSONEncoder`'s defaults, which is what the service decodes back with: a UUID
    /// is its `uuidString`, a `Data` is base64.
    private func legacyManifestJSON(
        corpus: SealedPhotoCorpus = .meal,
        entries: [(id: UUID, contentHash: Data)]
    ) -> Data {
        let rows = entries.map {
            "{\"id\":\"\($0.id.uuidString)\",\"contentHash\":\"\($0.contentHash.base64EncodedString())\"}"
        }
        return Data("{\"corpus\":\"\(corpus.rawValue)\",\"entries\":[\(rows.joined(separator: ","))]}".utf8)
    }

    /// Plants exactly what a pre-marker build left in a user's iCloud: one sealed meal body, plus a
    /// sealed manifest with no `hashVersion` field whose committed digest is the LEGACY bare
    /// SHA-256 of that body's plaintext — not the domain-separated v2 digest today's builds compute.
    private func plantLegacyMealBackup(
        identity: IdentityService,
        database: MockPhotoRecordDatabase
    ) async throws -> (id: UUID, plaintext: Data, legacyDigest: Data) {
        let id = UUID()
        let plaintext = Data("legacy photo".utf8)
        let legacyDigest = Data(SHA256.hash(data: plaintext))
        let cloud = makeCloud(database)
        try await cloud.saveSealedPhoto(
            try SealedPhotoCrypto.seal(
                plaintext,
                corpus: .meal,
                slot: .photo(id),
                identityService: identity,
                generation: 1,
                keySalt: Data(repeating: 0x11, count: 32)
            )
        )
        try await cloud.saveSealedPhoto(
            try SealedPhotoCrypto.seal(
                legacyManifestJSON(entries: [(id: id, contentHash: legacyDigest)]),
                corpus: .meal,
                slot: .manifest,
                identityService: identity,
                generation: 1,
                keySalt: Data(repeating: 0x11, count: 32)
            )
        )
        return (id, plaintext, legacyDigest)
    }

    /// The manifest as COMMITTED, read back the way a restoring device reads it: fetched from the
    /// database, opened under the escrow key, decoded with a plain `JSONDecoder` — the same decoder
    /// the service uses, so the decode defaults under test here are the real ones.
    private func committedManifest(
        corpus: SealedPhotoCorpus = .meal,
        identity: IdentityService,
        database: MockPhotoRecordDatabase
    ) async throws -> SealedPhotoManifest {
        let record = try #require(try await makeCloud(database).sealedPhoto(corpus: corpus, slot: .manifest))
        let plaintext = try SealedPhotoCrypto.open(record, identityService: identity)
        return try JSONDecoder().decode(SealedPhotoManifest.self, from: plaintext)
    }

    /// THE heal: a full-verification pass rewrites a pre-marker entry with the domain-separated v2
    /// digest AND stamps it, so a corpus's `minimumEntryHashVersion` climbs to 2 on its own as the
    /// device runs its normal passes. Nothing else proves the legacy bare-SHA256 digest ever leaves
    /// a live manifest.
    ///
    /// What a failure here MEANS changed in Phase 3, and this comment states the new stakes rather
    /// than the retired ones. The heal used to be the gate on deleting the legacy digest read
    /// branch — a stamp that quietly stayed at 1 would have stranded that branch or seen it deleted
    /// out from under entries still restoring through it. The branch is gone
    /// (``aLegacyDigestEntryIsRefusedTerminallyRatherThanRestored`` pins the refusal that replaced
    /// it), so there is no retirement left to block. An entry this pass leaves stamped 1 is instead
    /// one the SHIPPING restore refuses terminally, as `unverifiableLegacyDigest`, and a full pass
    /// that re-reads its plaintext is now the only thing that gives the photo back. Read a red here
    /// as "this id is unrestorable until healed", never as "the retirement is blocked".
    @Test func aFullPassHealsALegacyManifestEntryToTheV2DigestAndStamp() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())
        let legacy = try await plantLegacyMealBackup(identity: identity, database: database)

        let summary = try await service.reconcile(
            corpus: .meal,
            ids: [legacy.id],
            verifyingContentHashes: true
        ) { _ in legacy.plaintext }
        #expect(summary.uploaded == 1,
                "the v2 digest cannot match the committed legacy one, so the body must re-upload")
        #expect(summary.skipped == 0)

        let manifest = try await committedManifest(identity: identity, database: database)
        #expect(manifest.entries.count == 1, "the healed entry was appended beside the legacy one")
        let entry = try #require(manifest.entries.first)
        #expect(entry.id == legacy.id)
        #expect(entry.contentHash == SealedPhotoBackupService.contentHash(legacy.plaintext),
                "the legacy digest survived a pass that read the plaintext and could recompute it")
        #expect(entry.hashVersion == 2)
        #expect(manifest.minimumEntryHashVersion == 2,
                "an entry is still stamped 1, and the shipping restore refuses those terminally")

        // ...and healing is not a way to lose the photo: the committed set still restores.
        var restored: [UUID: Data] = [:]
        let restore = try #require(try await service.restore(corpus: .meal) { id, data in
            restored[id] = data
            return true
        })
        #expect(restore.restored == 1)
        #expect(restored[legacy.id] == legacy.plaintext)
    }

    /// The refusal Phase 3 put in place of the deleted v1 digest read, and the loop it must not
    /// start.
    ///
    /// The legacy branch used to accept a bare-SHA256 digest so a pre-marker manifest stayed
    /// restorable. With it gone, a legacy-stamped entry whose committed digest is that bare digest
    /// can never match, and the restore has to refuse the photo. WHERE that refusal is recorded is
    /// the whole test: `failed` is the retryable list the coordinator writes into the repair
    /// ledger, so putting it there would re-fetch the same record on every launch forever, hold the
    /// ledger non-empty, keep the corpus `.deferredTransient`, and pin the route uncommitted —
    /// withholding the key binding on a photo that is never coming back. It goes in the terminal
    /// list instead, and the coordinator half of this pin is
    /// ``anUnverifiableLegacyEntryNeverEntersTheRepairLedger``.
    @Test func aLegacyDigestEntryIsRefusedTerminallyRatherThanRestored() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())
        let legacy = try await plantLegacyMealBackup(identity: identity, database: database)

        var written: [UUID: Data] = [:]
        let summary = try #require(try await service.restore(corpus: .meal) { id, data in
            written[id] = data
            return true
        })

        #expect(summary.restored == 0)
        #expect(written.isEmpty, "bytes whose committed digest cannot be verified were handed to the writer")
        #expect(summary.failed.isEmpty, "a permanently unverifiable entry was queued for repair")
        #expect(summary.unverifiableLegacyDigest == [legacy.id])

        // And the healed corpus restores normally — the refusal is about the retired digest, not
        // about this id or these bytes.
        _ = try await service.reconcile(
            corpus: .meal, ids: [legacy.id], verifyingContentHashes: true
        ) { _ in legacy.plaintext }
        let healed = try #require(try await service.restore(corpus: .meal) { id, data in
            written[id] = data
            return true
        })
        #expect(healed.restored == 1)
        #expect(healed.unverifiableLegacyDigest.isEmpty)
        #expect(written[legacy.id] == legacy.plaintext)
    }

    /// A v2-STAMPED entry whose bytes do not match stays retryable, because its digest is known to
    /// be the current spelling — so the mismatch is a divergence a later upload can genuinely fix,
    /// not a format nobody can read. The split has to fall on the stamp, or every corrupt body
    /// would be abandoned as if it were a retired digest.
    @Test func aStampedEntryWhoseBytesDivergeStaysRetryable() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())

        let good = UUID()
        let tampered = UUID()
        _ = try await service.reconcile(corpus: .meal, ids: [good, tampered]) { id in
            id == good ? Data("good body".utf8) : Data("other body".utf8)
        }
        // Substitute one body with another authentically-sealed one: the record opens, the digest
        // does not match, and the entry is stamped 2.
        let donor = try #require(database.record(named: "sealed-photo.meal.\(good.uuidString)"))
        database.replaceCiphertext(
            named: "sealed-photo.meal.\(tampered.uuidString)",
            with: try #require(database.ciphertext(of: donor))
        )

        let summary = try #require(try await service.restore(corpus: .meal) { _, _ in true })
        #expect(summary.failed == [tampered])
        #expect(summary.unverifiableLegacyDigest.isEmpty,
                "a stamped entry was abandoned as if its digest were the retired spelling")
    }

    /// The ambient launch pass must NOT heal — and, far more important, must not PRETEND to. It
    /// skips a committed id without reading a byte, so it has proven nothing about which pre-image
    /// produced the committed digest; carrying the entry forward verbatim keeps the honest 1. A
    /// stamp applied on this rung would read fleet-wide as "no legacy digests left" for a digest
    /// nobody looked at, which is the one way the zero-proof can lie.
    @Test func anAmbientPassCarriesALegacyEntryForwardWithoutTouchingItsStamp() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())
        let legacy = try await plantLegacyMealBackup(identity: identity, database: database)

        let summary = try await service.reconcile(
            corpus: .meal,
            ids: [legacy.id],
            verifyingContentHashes: false
        ) { _ in legacy.plaintext }
        #expect(summary.uploaded == 0)
        #expect(summary.skipped == 1)

        let manifest = try await committedManifest(identity: identity, database: database)
        let entry = try #require(manifest.entries.first)
        #expect(entry.contentHash == legacy.legacyDigest,
                "the ambient pass rewrote a digest it never computed")
        #expect(entry.hashVersion == 1)
        #expect(manifest.minimumEntryHashVersion == 1,
                "an unread entry was counted as proven, so the corpus claims a cleanliness it has not earned")
    }

    /// ...and the same rule on the UNION leg, where it bites hardest: a verifying pass on a device
    /// that does not hold the photo — the other phone's, or one whose bytes this device never had —
    /// routes the entry through the carry-forward, reads no plaintext, and must leave the stamp
    /// exactly where it found it. "This pass verified hashes" is not the same fact as "this pass
    /// verified THIS entry", and only the second one licenses a promotion.
    @Test func aVerifyingPassThatNeverReadThePlaintextDoesNotPromoteTheStamp() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())
        let legacy = try await plantLegacyMealBackup(identity: identity, database: database)

        let summary = try await service.reconcile(
            corpus: .meal,
            ids: [],
            verifyingContentHashes: true
        ) { _ in nil }
        #expect(summary.uploaded == 0)

        let manifest = try await committedManifest(identity: identity, database: database)
        let entry = try #require(manifest.entries.first)
        #expect(entry.id == legacy.id, "the union dropped an id this device simply does not hold")
        #expect(entry.contentHash == legacy.legacyDigest)
        #expect(entry.hashVersion == 1,
                "a verifying pass promoted an entry whose plaintext it never read")
    }

    /// The third rung that appends an entry verbatim, and the one where "we're verifying, so stamp
    /// it" is most tempting: a full pass whose `photo` closure cannot hand over the bytes (locked
    /// keychain, a file the migration has not re-sealed yet) KEEPS the committed entry rather than
    /// dropping a good cloud copy — and keeps it whole. The pass verified nothing about THIS photo,
    /// because it never saw a byte of it, so promoting the stamp here would launder an unread legacy
    /// digest into the zero-proof on the exact photos the pass failed to check.
    @Test func aVerifyingPassKeepsAnUnreadablePhotosEntryVerbatim() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())
        let legacy = try await plantLegacyMealBackup(identity: identity, database: database)

        let summary = try await service.reconcile(
            corpus: .meal,
            ids: [legacy.id],
            verifyingContentHashes: true
        ) { _ in nil }
        #expect(summary.unreadable == 1)
        #expect(summary.uploaded == 0)

        let manifest = try await committedManifest(identity: identity, database: database)
        let entry = try #require(manifest.entries.first)
        #expect(entry.id == legacy.id, "an unreadable local file dropped a good cloud copy")
        #expect(entry.contentHash == legacy.legacyDigest)
        #expect(entry.hashVersion == 1,
                "a photo the pass could not read was stamped as proven — the verification never happened")
        #expect(manifest.minimumEntryHashVersion == 1)
    }

    /// The decode default, and the floor it feeds. Every manifest already sitting in a user's iCloud
    /// predates the marker, so a missing field must decode as legacy/unproven for EVERY entry — an
    /// undercount of proven-v2, never an overcount of clean, which is the only direction that keeps
    /// `minimumEntryHashVersion >= 2` usable as a proof. That aggregate is a floor rather than an
    /// average: one unproven entry holds the whole corpus back, while a corpus with nothing
    /// committed is vacuously clean.
    @Test func aManifestWrittenBeforeTheMarkerDecodesAsLegacyThroughout() throws {
        let json = legacyManifestJSON(entries: [
            (id: UUID(), contentHash: Data(SHA256.hash(data: Data("one".utf8)))),
            (id: UUID(), contentHash: Data(SHA256.hash(data: Data("two".utf8))))
        ])
        let decoded = try JSONDecoder().decode(SealedPhotoManifest.self, from: json)
        #expect(decoded.entries.map(\.hashVersion) == [1, 1],
                "a missing field decoded as proven-v2 — every pre-marker manifest would claim to be clean")
        #expect(decoded.minimumEntryHashVersion == 1)

        let mixed = SealedPhotoManifest(corpus: .meal, entries: [
            SealedPhotoManifest.Entry(id: UUID(), contentHash: Data([0x01]), hashVersion: 1),
            SealedPhotoManifest.Entry(id: UUID(), contentHash: Data([0x02]), hashVersion: 2)
        ])
        #expect(mixed.minimumEntryHashVersion == 1, "one unproven entry must hold the whole corpus back")
        #expect(SealedPhotoManifest(corpus: .meal, entries: []).minimumEntryHashVersion == 2,
                "no entries means vacuously no legacy digest")

        // The field really is WRITTEN, not merely defaulted on the way in: a marker that only ever
        // decoded would fall back to 1 on every rewrite and no corpus would ever finish healing.
        let stamped = SealedPhotoManifest.Entry(id: UUID(), contentHash: Data([0x03]), hashVersion: 2)
        let roundTripped = try JSONDecoder().decode(
            SealedPhotoManifest.Entry.self,
            from: try JSONEncoder().encode(stamped)
        )
        #expect(roundTripped == stamped)
        #expect(roundTripped.hashVersion == 2)
    }

    // MARK: - 9. Format-migration policy (crypto standardization Phase 2.1)
    //
    // Phase 2.1 adds no healing mechanism — §8 above already pins the heal. What it adds is the
    // POLICY around it: bounded passes, a completion latch that attests exactly one honest
    // sentence, and the invalidation rules that keep the sentence true. Every test below drives
    // the REAL coordinator over the mock database, so what is asserted is the policy a device
    // would actually execute.

    /// The Phase 2.1 latch over the SAME isolated defaults the coordinator was built with — a test
    /// must never read or write the device's real completion state.
    private func migrationLatch(_ defaults: UserDefaults) -> SealedPhotoBackupMigrationLatch {
        SealedPhotoBackupMigrationLatch(defaults: defaults)
    }

    /// Plants a corpus's committed cloud state: one sealed body per id, plus the manifest whose
    /// plaintext is `manifestJSON` — hand-built by the caller, so the pre-marker shape no build
    /// that still exists can write (§8's `legacyManifestJSON`) is reachable.
    private func plantMealBackup(
        identity: IdentityService,
        database: MockPhotoRecordDatabase,
        bodies: [UUID: Data],
        manifestJSON: Data,
        corpus: SealedPhotoCorpus = .meal,
        generation: Int64 = 1
    ) async throws {
        let cloud = makeCloud(database)
        for (id, plaintext) in bodies {
            try await cloud.saveSealedPhoto(try SealedPhotoCrypto.seal(
                plaintext,
                corpus: corpus,
                slot: .photo(id),
                identityService: identity,
                generation: generation,
                keySalt: Data(repeating: 0x11, count: 32)
            ))
        }
        try await cloud.saveSealedPhoto(try SealedPhotoCrypto.seal(
            manifestJSON,
            corpus: corpus,
            slot: .manifest,
            identityService: identity,
            generation: generation,
            keySalt: Data(repeating: 0x11, count: 32)
        ))
    }

    /// Plants the LOCAL half of a healable corpus: the same id the manifest names, holding the
    /// exact plaintext its planted body was sealed from. `restoreSealedPhoto` is the restore
    /// path's own writer, so the bytes come back byte-identical (§3's pin) and the pass's recompute
    /// really does match the digest the manifest committed.
    private func plantLocalMealPhoto(_ plaintext: Data, id: UUID, in documents: URL) {
        #expect(mealStore(in: documents).restoreSealedPhoto(plaintext, forID: id),
                "the local half of the fixture was refused — the planted bytes are not a valid image")
    }

    /// The generation stamped on a corpus's committed manifest record. Every commit mints the next
    /// one, so this is the cheapest honest count of how many reconciles actually committed — which
    /// is how these tests tell a one-pass run from a healed-then-confirmed two-pass run.
    private func committedManifestGeneration(
        corpus: SealedPhotoCorpus = .meal,
        database: MockPhotoRecordDatabase
    ) async throws -> Int64 {
        let record = try #require(try await makeCloud(database).sealedPhoto(corpus: corpus, slot: .manifest))
        return record.generation
    }

    /// One corpus's format verdict out of a pass — the evidence the latch decision is made from.
    private func verdict(
        _ corpus: SealedPhotoCorpus,
        in pass: OwnPhotoBackupCoordinator.PassResult
    ) throws -> SealedPhotoCorpusFormatVerdict {
        try #require(pass.corpusVerdicts?.first { $0.corpus == corpus })
    }

    /// The latched state P5 / P7 / P8 each start from: §8's legacy meal backup, its plaintext
    /// planted locally, and one wrapper run — which heals on pass 1 and latches on the confirming
    /// pass. The host comes back with the coordinator because the coordinator holds it `unowned`.
    private func latchedMealRoute(
        identity: IdentityService,
        database: MockPhotoRecordDatabase,
        defaults: UserDefaults,
        device: URL
    ) async throws -> (
        coordinator: OwnPhotoBackupCoordinator,
        host: RecordingOwnPhotoHost,
        id: UUID,
        plaintext: Data
    ) {
        let id = UUID()
        let plaintext = jpeg(width: 120, height: 90)
        try await plantMealBackup(
            identity: identity,
            database: database,
            bodies: [id: plaintext],
            manifestJSON: legacyManifestJSON(entries: [
                (id: id, contentHash: Data(SHA256.hash(data: plaintext)))
            ])
        )
        plantLocalMealPhoto(plaintext, id: id, in: device)
        let (coordinator, host) = makeCoordinator(
            documents: device, identity: identity, database: database, defaults: defaults
        )
        _ = await coordinator.synchronizeFullyVerified(preferenceOverride: true)
        #expect(migrationLatch(defaults).isComplete, "the shared fixture never reached the latched state")
        return (coordinator, host, id, plaintext)
    }

    /// P1 — THE loop, end to end over a corpus this device can fully heal: pass 1 rewrites the
    /// pre-marker entry with the v2 digest and stamps it, and the LATCH waits for pass 2, which
    /// re-opens the manifest from CloudKit and finds it already clean. That ordering is the whole
    /// soundness claim: `isClean` requires `healedEntries == 0`, so a pass that converted anything
    /// can never be its own proof, and every heal is confirmed by a genuine read-back.
    @Test func aCleanRunOverAnAllHealableCorpusSetsTheLatchOnTheConfirmingPass() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let defaults = isolatedDefaults()
        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }

        let route = try await latchedMealRoute(
            identity: identity, database: database, defaults: defaults, device: device
        )

        let manifest = try await committedManifest(identity: identity, database: database)
        #expect(manifest.entries.map(\.hashVersion) == [2])
        #expect(manifest.entries.first?.contentHash == SealedPhotoBackupService.contentHash(route.plaintext))
        #expect(manifest.minimumEntryHashVersion == 2)
        let generation = try await committedManifestGeneration(database: database)
        #expect(generation == 3,
                "the heal latched without a confirming pass that re-opened the manifest from iCloud")
        #expect(!route.coordinator.lastFullPassBlockedOnlyByOtherDevices)
    }

    /// P1a — the deliberately-scoped half of that read-back claim. A FRESH enable has no prior
    /// manifest, so every entry is brand-new; a brand-new entry is not a heal, the first pass is
    /// clean, and the latch sets in ONE pass. Its digests were computed from plaintext that same
    /// pass read, so nothing is vouched for by bytes nobody looked at — and requiring a confirming
    /// pass here would double the whole-library main-actor cost of every first enable for no
    /// soundness at all. The one-pass shape is policy, so it is pinned rather than left to luck.
    @Test func aFreshEnableWithNoPriorManifestLatchesInOnePass() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let defaults = isolatedDefaults()
        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }
        _ = try #require(mealStore(in: device).save(jpeg(width: 120, height: 90)))

        // Bound, not discarded: `OwnPhotoBackupCoordinator` holds its host `unowned` (it is owned
        // by `FernletStore` in production, which outlives it), so a `_` here drops the only strong
        // reference and the first `host.record…` inside a pass traps on a destroyed object. The
        // `defer` keeps it alive past every coordinator call in the test.
        let (coordinator, host) = makeCoordinator(
            documents: device, identity: identity, database: database, defaults: defaults
        )
        defer { withExtendedLifetime(host) {} }
        let pass = await coordinator.synchronizeFullyVerified(preferenceOverride: true)

        #expect(migrationLatch(defaults).isComplete)
        let generation = try await committedManifestGeneration(database: database)
        #expect(generation == 1, "a corpus born clean this pass paid for a confirming pass it does not need")
        let manifest = try await committedManifest(identity: identity, database: database)
        #expect(manifest.minimumEntryHashVersion == 2)
        #expect(try verdict(.meal, in: pass).healedEntries == 0, "a brand-new entry was counted as a heal")
    }

    /// P2 — "I could not look" never latches. A photo the pass could not read may be missing from
    /// the backup entirely, or stale under a stamp that describes bytes some earlier pass saw —
    /// so `unreadable > 0` blocks, exactly as the own-photo key migration's indeterminate bucket
    /// does. And the entry itself is carried VERBATIM: §8's rule, re-asserted from the migrator's
    /// altitude, because this is where a "we're verifying, so stamp it" edit would look harmless.
    @Test func theLatchDoesNotSetWhileAPhotoIsUnreadable() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let defaults = isolatedDefaults()
        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }

        let healable = UUID()
        let unreadable = UUID()
        let good = jpeg(width: 120, height: 90)
        let junk = Data(repeating: 0xAB, count: 512)
        try await plantMealBackup(
            identity: identity,
            database: database,
            bodies: [healable: good, unreadable: junk],
            manifestJSON: legacyManifestJSON(entries: [
                (id: healable, contentHash: Data(SHA256.hash(data: good))),
                (id: unreadable, contentHash: Data(SHA256.hash(data: junk)))
            ])
        )
        plantLocalMealPhoto(good, id: healable, in: device)
        // The unreadable half: a file this install cannot open sitting beside one it can, so the
        // corpus is non-empty AND not all-stranded — the pass goes to the upload leg and fails to
        // read exactly one photo.
        try junk.write(to: OwnPhotoCorpusLayout.mealPhotosDirectory(in: device)
            .appendingPathComponent("\(unreadable.uuidString).jpg"))

        let (coordinator, host) = makeCoordinator(
            documents: device, identity: identity, database: database, defaults: defaults
        )
        _ = await coordinator.synchronizeFullyVerified(preferenceOverride: true)

        #expect(!migrationLatch(defaults).isComplete, "a pass that could not read a photo latched anyway")
        #expect(host.verifiedUnreadableCounts.last == 1)
        let manifest = try await committedManifest(identity: identity, database: database)
        let kept = try #require(manifest.entries.first { $0.id == unreadable })
        #expect(kept.contentHash == Data(SHA256.hash(data: junk)),
                "an unreadable photo's committed digest was rewritten from bytes nobody read")
        #expect(kept.hashVersion == 1)
        #expect(manifest.entries.first { $0.id == healable }?.hashVersion == 2,
                "the readable photo was not healed, so the pass did less than it could")
    }

    /// P3 — the state this device can never fix, and must therefore never claim to have fixed: a
    /// manifest entry carried forward from the user's OTHER phone, whose plaintext lives on that
    /// phone. The latch stays closed on the truth of the corpus until that device heals its own
    /// entries; the loop stops rather than spinning (no forward progress on pass 2); and the
    /// session verdict says "blocked by another device", so the UI never renders a Retry
    /// invitation that structurally cannot succeed.
    @Test func aForeignCarriedForwardLegacyEntryKeepsTheLatchClosed() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let defaults = isolatedDefaults()
        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }

        let mine = UUID()
        let theirs = UUID()
        let myPhoto = jpeg(width: 120, height: 90)
        let theirBytes = Data("the other phone's photo".utf8)
        try await plantMealBackup(
            identity: identity,
            database: database,
            bodies: [mine: myPhoto, theirs: theirBytes],
            manifestJSON: legacyManifestJSON(entries: [
                (id: mine, contentHash: Data(SHA256.hash(data: myPhoto))),
                (id: theirs, contentHash: Data(SHA256.hash(data: theirBytes)))
            ])
        )
        plantLocalMealPhoto(myPhoto, id: mine, in: device)

        // Bound, not discarded: `OwnPhotoBackupCoordinator` holds its host `unowned` (it is owned
        // by `FernletStore` in production, which outlives it), so a `_` here drops the only strong
        // reference and the first `host.record…` inside a pass traps on a destroyed object. The
        // `defer` keeps it alive past every coordinator call in the test.
        let (coordinator, host) = makeCoordinator(
            documents: device, identity: identity, database: database, defaults: defaults
        )
        defer { withExtendedLifetime(host) {} }
        _ = await coordinator.synchronizeFullyVerified(preferenceOverride: true)

        #expect(!migrationLatch(defaults).isComplete,
                "a corpus still carrying another device's legacy digest was scored as proven")
        let manifest = try await committedManifest(identity: identity, database: database)
        #expect(manifest.entries.first { $0.id == mine }?.hashVersion == 2)
        #expect(manifest.entries.first { $0.id == mine }?.contentHash
                == SealedPhotoBackupService.contentHash(myPhoto))
        #expect(manifest.entries.first { $0.id == theirs }?.hashVersion == 1)
        #expect(manifest.entries.first { $0.id == theirs }?.contentHash
                == Data(SHA256.hash(data: theirBytes)),
                "this device rewrote a digest for bytes it has never held")
        #expect(manifest.minimumEntryHashVersion == 1)
        let generation = try await committedManifestGeneration(database: database)
        #expect(generation == 3, "the loop did not consume both funded passes before stopping")
        #expect(coordinator.lastFullPassBlockedOnlyByOtherDevices,
                "the only blocker was another device's entry, and the UI was not told")
    }

    /// P4 — a corpus whose manifest could not be READ is indeterminate, not clean. The manifest is
    /// the sole authority on membership, so a pass that never saw it has no standing to say
    /// anything about the corpus's format — and (the §2 rule this inherits) it must not rewrite
    /// the list either.
    @Test func anUnreadableManifestBlocksTheLatch() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let defaults = isolatedDefaults()
        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }

        let id = UUID()
        let plaintext = jpeg(width: 120, height: 90)
        try await plantMealBackup(
            identity: identity,
            database: database,
            bodies: [id: plaintext],
            manifestJSON: legacyManifestJSON(entries: [
                (id: id, contentHash: Data(SHA256.hash(data: plaintext)))
            ])
        )
        plantLocalMealPhoto(plaintext, id: id, in: device)
        database.unfetchableRecordNames = ["sealed-photo.meal.manifest"]

        // Bound, not discarded: `OwnPhotoBackupCoordinator` holds its host `unowned` (it is owned
        // by `FernletStore` in production, which outlives it), so a `_` here drops the only strong
        // reference and the first `host.record…` inside a pass traps on a destroyed object. The
        // `defer` keeps it alive past every coordinator call in the test.
        let (coordinator, host) = makeCoordinator(
            documents: device, identity: identity, database: database, defaults: defaults
        )
        defer { withExtendedLifetime(host) {} }
        let pass = await coordinator.synchronizeFullyVerified(preferenceOverride: true)

        #expect(!migrationLatch(defaults).isComplete)
        let mealVerdict = try verdict(.meal, in: pass)
        #expect(!mealVerdict.committed)
        #expect(!mealVerdict.examined, "a leg that never reached the manifest reported an answer")
        #expect(pass.uploadFailed)
        database.unfetchableRecordNames = []
        let generation = try await committedManifestGeneration(database: database)
        #expect(generation == 1, "a manifest this device could not read was rewritten anyway")
    }

    /// P5 — the second run over a latched route is short-circuited by the loop (no healing, no
    /// second funded pass) and changes nothing: `run()` is idempotent, and a pass over an
    /// already-converted corpus is the read-only sweep that lets a confirming pass double as proof.
    @Test func aSecondRunOverALatchedRouteShortCircuitsAndStaysIdempotent() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let defaults = isolatedDefaults()
        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }

        let route = try await latchedMealRoute(
            identity: identity, database: database, defaults: defaults, device: device
        )
        let bodyBefore = try #require(database.ciphertext(named: "sealed-photo.meal.\(route.id.uuidString)"))

        _ = await route.coordinator.synchronizeFullyVerified(preferenceOverride: true)

        #expect(migrationLatch(defaults).isComplete, "a clean second run un-latched a proven route")
        #expect(database.ciphertext(named: "sealed-photo.meal.\(route.id.uuidString)") == bodyBefore,
                "an idempotent pass re-uploaded a photo it had already committed")
        let generation = try await committedManifestGeneration(database: database)
        #expect(generation == 4, "the latched branch funded more than the one full pass the user asked for")
        let manifest = try await committedManifest(identity: identity, database: database)
        #expect(manifest.minimumEntryHashVersion == 2)
    }

    /// P6 — the second heal shape, which uploads not one byte: a pre-marker entry whose committed
    /// digest ALREADY is the v2 pre-image. The matched-unchanged rung proves it (the recompute
    /// matches) and stamps it, and that stamp upgrade is forward progress in its own right — a
    /// loop that only counted re-uploads would stop one pass short and never latch this corpus.
    @Test func aStampUpgradeWithoutReuploadCountsAsHealing() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let defaults = isolatedDefaults()
        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }

        let id = UUID()
        let plaintext = jpeg(width: 100, height: 100)
        // The digest is the CURRENT one; only the marker is missing, so the entry decodes as
        // legacy/unproven and one recompute is enough to prove it.
        try await plantMealBackup(
            identity: identity,
            database: database,
            bodies: [id: plaintext],
            manifestJSON: legacyManifestJSON(entries: [
                (id: id, contentHash: SealedPhotoBackupService.contentHash(plaintext))
            ])
        )
        plantLocalMealPhoto(plaintext, id: id, in: device)
        let bodyBefore = try #require(database.ciphertext(named: "sealed-photo.meal.\(id.uuidString)"))

        // Bound, not discarded: `OwnPhotoBackupCoordinator` holds its host `unowned` (it is owned
        // by `FernletStore` in production, which outlives it), so a `_` here drops the only strong
        // reference and the first `host.record…` inside a pass traps on a destroyed object. The
        // `defer` keeps it alive past every coordinator call in the test.
        let (coordinator, host) = makeCoordinator(
            documents: device, identity: identity, database: database, defaults: defaults
        )
        defer { withExtendedLifetime(host) {} }
        _ = await coordinator.synchronizeFullyVerified(preferenceOverride: true)

        #expect(migrationLatch(defaults).isComplete,
                "a stamp upgrade was not counted as progress, so the loop stopped before it could latch")
        #expect(database.ciphertext(named: "sealed-photo.meal.\(id.uuidString)") == bodyBefore,
                "the stamp upgrade re-uploaded a body whose bytes had not changed")
        let manifest = try await committedManifest(identity: identity, database: database)
        #expect(manifest.minimumEntryHashVersion == 2)
        let generation = try await committedManifestGeneration(database: database)
        #expect(generation == 3)
    }

    /// P7 — how another device's pre-marker write reaches this one: at the next pass that OPENS
    /// the manifest. A pre-marker build re-encodes manifests with no `hashVersion` field at all, so
    /// its write silently drops the corpus minimum back to 1; a latch set before that would then be
    /// attesting something no longer true. Every pass shape observes — the ambient one included,
    /// at zero added cost, because the reconcile already opens the manifest.
    @Test func observingAForeignLegacyManifestWriteResetsTheLatch() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let defaults = isolatedDefaults()
        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }

        let route = try await latchedMealRoute(
            identity: identity, database: database, defaults: defaults, device: device
        )

        // "The other phone", running a pre-marker build: it re-commits the manifest it opened, and
        // its encoder has no `hashVersion` field to write.
        try await plantMealBackup(
            identity: identity,
            database: database,
            bodies: [:],
            manifestJSON: legacyManifestJSON(entries: [
                (id: route.id, contentHash: Data(SHA256.hash(data: route.plaintext)))
            ]),
            generation: 9
        )

        let audit = AuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // The AMBIENT shape (`fullVerification: false`) — the launch pass, which reads almost
        // nothing and is never routed through the migrator. `preferenceOverride` stands in for the
        // persisted preference so the test never depends on process-global storage settings.
        _ = await route.coordinator.synchronize(preferenceOverride: true)

        #expect(!migrationLatch(defaults).isComplete,
                "a latch kept attesting a corpus another device had just written back to legacy")
        #expect(audit.contains("sealedPhoto.hashMigration.invalidatedByForeignWrite"),
                "the invalidation was silent")
    }

    /// P8 — the latch must never eat the user's verification. Retry after latching still runs a
    /// REAL full pass, so a photo replaced in place under the same id is re-read, re-hashed and
    /// re-uploaded. A short-circuit that skipped the pass would turn the one remedy the banner
    /// offers into a no-op.
    @Test func retryAfterTheLatchStillRunsARealFullPass() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let defaults = isolatedDefaults()
        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }

        let route = try await latchedMealRoute(
            identity: identity, database: database, defaults: defaults, device: device
        )
        let bodyBefore = try #require(database.ciphertext(named: "sealed-photo.meal.\(route.id.uuidString)"))

        // The same id, different bytes — the in-place replacement only a full pass notices.
        let replacement = jpeg(width: 80, height: 140, color: .systemPink)
        plantLocalMealPhoto(replacement, id: route.id, in: device)

        _ = await route.coordinator.synchronizeFullyVerified(preferenceOverride: true)

        #expect(database.ciphertext(named: "sealed-photo.meal.\(route.id.uuidString)") != bodyBefore,
                "the latch ate the user's verification — the replaced photo never reached iCloud")
        let manifest = try await committedManifest(identity: identity, database: database)
        #expect(manifest.entries.first?.contentHash == SealedPhotoBackupService.contentHash(replacement))
        #expect(migrationLatch(defaults).isComplete)
    }

    /// P9 — teardown destroys the manifests the latch makes a claim about, so the latch goes with
    /// them. Keeping it would carry a proof about deleted objects onto a future re-enable's
    /// brand-new lineage — the deliberate mirror-image of the own-photo key latch, which is KEPT
    /// because its subject (the re-sealed local files) survives the wipe.
    @Test func teardownForDeleteAllClearsTheLatch() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let defaults = isolatedDefaults()
        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }
        migrationLatch(defaults).markComplete()

        // Bound, not discarded: `OwnPhotoBackupCoordinator` holds its host `unowned` (it is owned
        // by `FernletStore` in production, which outlives it), so a `_` here drops the only strong
        // reference and the first `host.record…` inside a pass traps on a destroyed object. The
        // `defer` keeps it alive past every coordinator call in the test.
        let (coordinator, host) = makeCoordinator(
            documents: device, identity: identity, database: database, defaults: defaults
        )
        defer { withExtendedLifetime(host) {} }
        #expect(await coordinator.tearDownForDeleteAll())

        #expect(!migrationLatch(defaults).isComplete,
                "a proof about manifests this call just deleted survived the teardown")
    }

    /// P11 — the no-op pass shape, which three different situations produce (the preference is
    /// off, the DEBUG skip env is set, or the between-pass teardown guard fired). It carries no
    /// verdicts, so it is never clean and never progress: the loop stops after one, and nothing
    /// latches. `PassResult()`'s defaults include `routeCommitted == true`, which is exactly why
    /// "verdicts present" — not that Bool — has to be the gate.
    @Test func aNoOpPassIsNeverCleanAndNeverProgress() async throws {
        let defaults = isolatedDefaults()
        let noOp = SealedPhotoBackupMigrationPassResult(pass: OwnPhotoBackupCoordinator.PassResult())
        #expect(!noOp.isClean, "a pass that never ran scored as proof")
        #expect(!noOp.madeForwardProgress)

        let migrator = SealedPhotoBackupFormatMigrator(latch: migrationLatch(defaults)) {
            OwnPhotoBackupCoordinator.PassResult()
        }
        #expect(await migrator.run() == false)
        #expect(migrator.underlyingPasses.count == 1, "a no-op pass funded a second identical one")
        #expect(!migrationLatch(defaults).isComplete)
    }

    /// P12 — the service-level bookkeeping the whole policy reads, on both pass shapes and both
    /// legs. Every value is arithmetic over what the pass already had in its hands (the manifest it
    /// opened, the entries it was about to encode), which is what keeps the migrator's evidence
    /// free of a single added fetch or decrypt.
    @Test func theSummaryCarriesManifestMinimaAndHealsOnBothRungs() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }

        // A FULL pass: it reads the plaintext, so it may (and does) heal.
        let healing = MockPhotoRecordDatabase()
        let healingService = makeService(identity: identity, database: healing, defaults: isolatedDefaults())
        let healable = try await plantLegacyMealBackup(identity: identity, database: healing)
        let full = try await healingService.reconcile(
            corpus: .meal, ids: [healable.id], verifyingContentHashes: true
        ) { _ in healable.plaintext }
        #expect(full.openedManifestMinimumHashVersion == 1)
        #expect(full.committedManifestMinimumHashVersion == 2)
        #expect(full.healedEntries == 1)
        #expect(full.uploaded == 1)

        // The AMBIENT pass over the same fixture reads nothing, so it heals nothing — and says so.
        let ambientDatabase = MockPhotoRecordDatabase()
        let ambientService = makeService(identity: identity, database: ambientDatabase, defaults: isolatedDefaults())
        let untouched = try await plantLegacyMealBackup(identity: identity, database: ambientDatabase)
        let ambient = try await ambientService.reconcile(
            corpus: .meal, ids: [untouched.id], verifyingContentHashes: false
        ) { _ in untouched.plaintext }
        #expect(ambient.openedManifestMinimumHashVersion == 1)
        #expect(ambient.committedManifestMinimumHashVersion == 1,
                "an ambient pass re-committed a manifest with a minimum it never earned")
        #expect(ambient.healedEntries == 0)

        // ...and the RESTORE leg's half: the minimum of the manifest it decoded. It is the only
        // honest source of that number for a corpus the reconcile never reaches.
        let restoreDatabase = MockPhotoRecordDatabase()
        let restoreService = makeService(identity: identity, database: restoreDatabase, defaults: isolatedDefaults())
        _ = try await plantLegacyMealBackup(identity: identity, database: restoreDatabase)
        let restored = try #require(try await restoreService.restore(corpus: .meal) { _, _ in true })
        #expect(restored.manifestMinimumEntryHashVersion == 1)
    }

    /// P13 — the merge semantics, at the one irreversible decision point the route has. The
    /// confirming pass exists only for the latch policy, so its transient failure must never
    /// un-prove the healing pass that committed: `setEnabled` still returns true (a `false` snaps
    /// the toggle off over a backup that IS in iCloud, and leaves it unmaintained — no ambient
    /// passes, no banner), the commit proof the key-binding gate reads still stands, and the
    /// banner is not told "your photos may not be in iCloud" about photos this run committed. The
    /// failure maps to one place only: the latch stays closed.
    @Test func aFailedConfirmingPassNeverUnprovesACommittedHealingPass() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let defaults = isolatedDefaults()
        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }

        let id = UUID()
        let plaintext = jpeg(width: 120, height: 90)
        try await plantMealBackup(
            identity: identity,
            database: database,
            bodies: [id: plaintext],
            manifestJSON: legacyManifestJSON(entries: [
                (id: id, contentHash: Data(SHA256.hash(data: plaintext)))
            ])
        )
        plantLocalMealPhoto(plaintext, id: id, in: device)

        let (coordinator, host) = makeCoordinator(
            documents: device, identity: identity, database: database, defaults: defaults
        )
        // Pass 1 gets its two writes (the healed body, then the manifest); every later save throws,
        // so the confirming pass fails its commit exactly the way a transport blip would. The
        // budget is relative to `saveCallCount` because the plant above already spent saves on the
        // same mock — an absolute 2 would fail pass 1's FIRST write, making this an honestly failed
        // enable rather than the merge scenario under test.
        database.failSavesAfterCallCount = database.saveCallCount + 2

        #expect(await coordinator.setEnabled(true),
                "a transient confirming pass vetoed an enable whose healing pass committed")
        #expect(OwnPhotoEscrowCommitLedger(defaults: defaults).isCommitted,
                "the binding gate's proof was withdrawn by a pass that only exists to read")
        #expect(host.uploadFailures.last == false, "the banner blamed the upload for a latch-only failure")
        #expect(!migrationLatch(defaults).isComplete, "a run whose confirming pass failed latched anyway")

        // ...and pass 1's heal is really in iCloud: that is what makes the merge honest.
        database.failSavesAfterCallCount = nil
        let manifest = try await committedManifest(identity: identity, database: database)
        #expect(manifest.minimumEntryHashVersion == 2)
        let generation = try await committedManifestGeneration(database: database)
        #expect(generation == 2, "the healing pass's commit is what the merge is vouching for")
    }

    /// P14 — the corpus this device stopped looking at. An emptied-after-upload corpus (the user
    /// deleted their photos; the ledger is present but empty) is skipped by the ambient upload
    /// guard forever, so without the full-pass admission its cloud manifest — possibly carrying
    /// another device's legacy entries — would never be observed again: the latch could neither
    /// honestly set nor ever become satisfiable, i.e. a permanent nudge treadmill. A full pass runs
    /// its provably inert reconcile (`ids = []`, nothing prunable) purely so the corpus is EXAMINED
    /// and can block on the truth.
    @Test func anEmptiedCorpusOverALiveForeignLegacyManifestBlocksTheLatchAndIsExamined() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let defaults = isolatedDefaults()
        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }

        let theirs = UUID()
        let theirBytes = Data("the other phone's photo".utf8)
        try await plantMealBackup(
            identity: identity,
            database: database,
            bodies: [theirs: theirBytes],
            manifestJSON: legacyManifestJSON(entries: [
                (id: theirs, contentHash: Data(SHA256.hash(data: theirBytes)))
            ])
        )
        // The emptied-after-upload state: this device uploaded once, then the user deleted every
        // meal photo, so the ledger is PRESENT and empty.
        OwnPhotoUploadLedger(defaults: defaults).recordUploaded([], for: .meal)

        // Bound, not discarded: `OwnPhotoBackupCoordinator` holds its host `unowned` (it is owned
        // by `FernletStore` in production, which outlives it), so a `_` here drops the only strong
        // reference and the first `host.record…` inside a pass traps on a destroyed object. The
        // `defer` keeps it alive past every coordinator call in the test.
        let (coordinator, host) = makeCoordinator(
            documents: device, identity: identity, database: database, defaults: defaults
        )
        defer { withExtendedLifetime(host) {} }
        let pass = await coordinator.synchronizeFullyVerified(preferenceOverride: true)

        let mealVerdict = try verdict(.meal, in: pass)
        #expect(mealVerdict.examined, "the corpus was never looked at, so its latch state is a guess")
        #expect(mealVerdict.committed)
        #expect(mealVerdict.observedMinima.contains(1))
        #expect(!migrationLatch(defaults).isComplete)
        let manifest = try await committedManifest(identity: identity, database: database)
        #expect(manifest.entries.map(\.id) == [theirs], "the inert reconcile dropped an entry it must carry")
        #expect(manifest.entries.first?.contentHash == Data(SHA256.hash(data: theirBytes)))
        #expect(manifest.entries.first?.hashVersion == 1)
    }

    /// P15 — the emptiest possible user is not indeterminate forever. With nothing local and
    /// nothing committed, every corpus is examined by the restore leg (a nil `service.restore`
    /// return is the ONE honest source of "no manifest exists") and observes no minimum at all, so
    /// the pass is vacuously clean and latches. Vacuousness is evidence-based here — read off what
    /// the pass actually did, never inferred from a ledger.
    @Test func aZeroPhotoUserWithNoManifestsLatchesVacuously() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let defaults = isolatedDefaults()
        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }

        // Bound, not discarded: `OwnPhotoBackupCoordinator` holds its host `unowned` (it is owned
        // by `FernletStore` in production, which outlives it), so a `_` here drops the only strong
        // reference and the first `host.record…` inside a pass traps on a destroyed object. The
        // `defer` keeps it alive past every coordinator call in the test.
        let (coordinator, host) = makeCoordinator(
            documents: device, identity: identity, database: database, defaults: defaults
        )
        defer { withExtendedLifetime(host) {} }
        let pass = await coordinator.synchronizeFullyVerified(preferenceOverride: true)

        #expect(migrationLatch(defaults).isComplete, "a user with nothing to prove could never finish proving it")
        let verdicts = try #require(pass.corpusVerdicts)
        #expect(verdicts.count == SealedPhotoCorpus.allCases.count)
        // Closure rather than the `\.examined` key path: `#expect` decomposes its expression, and
        // a key-path-as-function argument makes the `rethrows` analysis of `allSatisfy` fail to
        // compile inside the expansion. Same assertion, and the same spelling as the line below.
        #expect(verdicts.allSatisfy { $0.examined })
        #expect(verdicts.allSatisfy { $0.observedMinima.isEmpty })
        #expect(database.recordNames(withPrefix: "sealed-photo.").isEmpty,
                "an empty device wrote a manifest, which is the clobber the upload guard exists to stop")
    }

    /// P16 — an unlistable corpus directory fails CLOSED. `storedPhotoIDs()` maps that state to
    /// `[]` while `isEmptyForRestore()` deliberately reads it as non-empty, so a reconcile fed the
    /// empty id view would carry everything forward unread and score clean — and, with a non-empty
    /// prunable set, would prune this device's own committed entries while their files sit intact
    /// on disk. So the reconcile is skipped entirely and the corpus is indeterminate.
    @Test func anUnlistableCorpusDirectoryBlocksTheLatchAndSkipsItsReconcile() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let defaults = isolatedDefaults()
        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }

        // A corpus that would otherwise latch on its first pass: local photo, and a committed
        // manifest already carrying the current digest and marker.
        let id = UUID()
        let plaintext = jpeg(width: 120, height: 90)
        let cleanManifest = try JSONEncoder().encode(SealedPhotoManifest(
            corpus: .meal,
            entries: [SealedPhotoManifest.Entry(
                id: id,
                contentHash: SealedPhotoBackupService.contentHash(plaintext),
                hashVersion: SealedPhotoManifest.Entry.currentHashVersion
            )]
        ))
        try await plantMealBackup(
            identity: identity, database: database, bodies: [id: plaintext], manifestJSON: cleanManifest
        )
        plantLocalMealPhoto(plaintext, id: id, in: device)

        // Deny listing on the directory itself (the `OwnPhotoKeyMigrationTests` idiom, one level
        // up), restored before the teardown below can run.
        let mealDirectory = OwnPhotoCorpusLayout.mealPhotosDirectory(in: device)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: mealDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mealDirectory.path)
        }

        let audit = AuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // Bound, not discarded: `OwnPhotoBackupCoordinator` holds its host `unowned` (it is owned
        // by `FernletStore` in production, which outlives it), so a `_` here drops the only strong
        // reference and the first `host.record…` inside a pass traps on a destroyed object. The
        // `defer` keeps it alive past every coordinator call in the test.
        let (coordinator, host) = makeCoordinator(
            documents: device, identity: identity, database: database, defaults: defaults
        )
        defer { withExtendedLifetime(host) {} }
        let pass = await coordinator.synchronizeFullyVerified(preferenceOverride: true)

        #expect(!migrationLatch(defaults).isComplete,
                "a corpus whose files could not even be counted was scored as proven")
        let mealVerdict = try verdict(.meal, in: pass)
        #expect(!mealVerdict.committed)
        #expect(!mealVerdict.examined)
        #expect(audit.contains("sealedPhoto.reconcileSkippedUnlistableCorpus"), "the skip was silent")
        let generation = try await committedManifestGeneration(database: database)
        #expect(generation == 1,
                "the committed manifest was rewritten from an empty id view of a corpus that holds files")
    }

    /// P18 — the restore leg observes too. A corpus this device RESTORES never reaches the
    /// reconcile, so threading the observation through only the upload leg would leave a
    /// restore-only pass unable to see a foreign legacy write at all — the latch would keep
    /// attesting a corpus another device had already written back.
    @Test func aRestoreLegObservationOfALegacyManifestResetsTheLatch() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let defaults = isolatedDefaults()
        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }
        migrationLatch(defaults).markComplete()

        // The RECIPE corpus: empty locally and never uploaded from here, so this pass restores it
        // rather than reconciling it.
        let id = UUID()
        let plaintext = jpeg(width: 90, height: 90, color: .systemPink)
        try await plantMealBackup(
            identity: identity,
            database: database,
            bodies: [id: plaintext],
            manifestJSON: legacyManifestJSON(
                corpus: .recipe,
                entries: [(id: id, contentHash: Data(SHA256.hash(data: plaintext)))]
            ),
            corpus: .recipe
        )

        let audit = AuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // Bound, not discarded: `OwnPhotoBackupCoordinator` holds its host `unowned` (it is owned
        // by `FernletStore` in production, which outlives it), so a `_` here drops the only strong
        // reference and the first `host.record…` inside a pass traps on a destroyed object. The
        // `defer` keeps it alive past every coordinator call in the test.
        let (coordinator, host) = makeCoordinator(
            documents: device, identity: identity, database: database, defaults: defaults
        )
        defer { withExtendedLifetime(host) {} }
        _ = await coordinator.synchronize(preferenceOverride: true)

        #expect(!migrationLatch(defaults).isComplete,
                "a restore-only pass saw a legacy manifest and left the latch attesting the opposite")
        #expect(audit.contains("sealedPhoto.hashMigration.invalidatedByForeignWrite"))
    }

    // MARK: - 9. The Phase 3 gate readout's manifest FORMAT accessor

    /// A manifest with proven entries reports its four format facts.
    ///
    /// This accessor is what makes the sealed-photo Phase 3 gate readable from the phone at all: the
    /// gate is `minimumEntryHashVersion >= 2` per corpus, and nothing in the app rendered that number
    /// anywhere before it. It is a SECOND caller of the existing private `openManifest`, deliberately
    /// not a second reader with its own copy of the fail-closed corpus re-check.
    @Test func theManifestFormatAccessorReportsProvenEntries() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())

        try await service.addPhoto(Data("photo A".utf8), id: UUID(), corpus: .meal)
        try await service.addPhoto(Data("photo B".utf8), id: UUID(), corpus: .meal)

        let reading = try #require(try await service.manifestFormatReading(corpus: .meal))
        #expect(reading.entryCount == 2)
        #expect(reading.minimumEntryHashVersion == 2)
        #expect(reading.unprovenEntryCount == 0)
        #expect(reading.generation >= 1)
    }

    /// The PRE-MARKER fixture reads minimum 1 with a NON-ZERO unproven count — "not proven", which
    /// the readout is careful never to render as "legacy entries found".
    @Test func theManifestFormatAccessorReadsAPreMarkerManifestAsUnproven() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        _ = try await plantLegacyMealBackup(identity: identity, database: database)
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())

        let reading = try #require(try await service.manifestFormatReading(corpus: .meal))
        #expect(reading.entryCount == 1)
        #expect(reading.minimumEntryHashVersion == 1)
        #expect(reading.unprovenEntryCount == 1)
    }

    /// An EMPTY manifest reads minimum 2 with `entryCount == 0` — the vacuous case, re-pinned through
    /// the accessor because that is precisely where it becomes a RENDERING hazard: a caller reading
    /// the minimum alone would see the gate's own number and call the surface proven.
    @Test func theManifestFormatAccessorReadsAnEmptyManifestAsVacuousTwo() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let cloud = makeCloud(database)
        try await cloud.saveSealedPhoto(
            try SealedPhotoCrypto.seal(
                try JSONEncoder().encode(SealedPhotoManifest(corpus: .recipe, entries: [])),
                corpus: .recipe,
                slot: .manifest,
                identityService: identity,
                generation: 1,
                keySalt: Data(repeating: 0x22, count: 32)
            )
        )
        let service = makeService(identity: identity, database: database, defaults: isolatedDefaults())

        let reading = try #require(try await service.manifestFormatReading(corpus: .recipe))
        #expect(reading.entryCount == 0)
        #expect(reading.minimumEntryHashVersion == 2, "an empty manifest is vacuously 2")
        #expect(reading.unprovenEntryCount == 0)
    }

    /// A missing manifest record returns nil rather than a fabricated reading. "No record came back"
    /// is not "no manifest exists", and it is certainly not a zero.
    @Test func theManifestFormatAccessorReturnsNilForAMissingManifest() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let service = makeService(identity: identity, database: MockPhotoRecordDatabase(),
                                  defaults: isolatedDefaults())
        #expect(try await service.manifestFormatReading(corpus: .progress) == nil)
    }

    /// It WRITES NOTHING: the injected generation store's high-water mark is unchanged after the
    /// call. `restore` raises it via `recordAcceptedPhoto`; this accessor must not.
    @Test func theManifestFormatAccessorRaisesNoHighWaterMark() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let defaults = isolatedDefaults()
        let service = makeService(identity: identity, database: database, defaults: defaults)
        try await service.addPhoto(Data("photo".utf8), id: UUID(), corpus: .meal)

        let before = SealedBackupGenerationStore(defaults: defaults).lastSeenPhoto(for: .meal)
        _ = try await service.manifestFormatReading(corpus: .meal)
        #expect(SealedBackupGenerationStore(defaults: defaults).lastSeenPhoto(for: .meal) == before,
                "the format accessor raised the high-water mark — it must never write")
    }

    /// The correction the Phase 3 readout's design turned on: a LATCHED-device
    /// `synchronizeFullyVerified` still leaves `lastFullPassVerdicts` populated.
    ///
    /// The latch guard returns before `lastTally` is ever computed, so retaining the verdicts there
    /// would have left them permanently nil on exactly the healthy latched device a Phase 3 sitting
    /// is taken from. They come from the RETURNED `PassResult.corpusVerdicts` instead, which
    /// `synchronize(preferenceOverride:fullVerification:)` sets and both legs reach. A test that only
    /// exercised the unlatched path would have passed against the broken site, so this one asserts
    /// the latched path specifically.
    @Test func aLatchedFullPassStillRetainsItsPerCorpusVerdicts() async throws {
        let (identity, keychainService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: keychainService) }
        let database = MockPhotoRecordDatabase()
        let defaults = isolatedDefaults()
        let device = temporaryDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: device) }

        let route = try await latchedMealRoute(
            identity: identity, database: database, defaults: defaults, device: device
        )
        #expect(migrationLatch(defaults).isComplete, "this test is only meaningful on a latched device")

        _ = await route.coordinator.synchronizeFullyVerified(preferenceOverride: true)
        let verdicts = try #require(route.coordinator.lastFullPassVerdicts,
                                    "the latched leg left the retained verdicts nil")
        #expect(verdicts.count == SealedPhotoCorpus.allCases.count)
        #expect(route.coordinator.lastFullPassCompletedAt != nil)

        // ...and they die with the manifests they describe.
        _ = await route.coordinator.tearDownForDeleteAll()
        #expect(route.coordinator.lastFullPassVerdicts == nil)
        #expect(route.coordinator.lastFullPassCompletedAt == nil)
    }
}

// MARK: - Test doubles
//
// `AlwaysAvailableAccountProvider` is shared with `SealedBackupPayloadCoverageTests`.

/// Captures the non-silent status the coordinator publishes, so a test can assert that a failure
/// reached the user's banner instead of being swallowed.
@MainActor
private final class RecordingOwnPhotoHost: OwnPhotoBackupContext {
    private(set) var outcomes: [SealedBackupRestoreOutcome] = []
    /// The upload-side status, which the restore vocabulary above cannot express — a device that
    /// HAS photos never enters the restore branch, so this is the only signal a totally failed
    /// backup produces.
    private(set) var uploadFailures: [Bool] = []
    /// The third upload-side status: how many photos the last FULL pass could not read. The manifest
    /// still committed, so neither of the two above says anything about it — a pass reported as clean
    /// while photos are missing from (or stale in) the backup is exactly the gap verification exists
    /// to find.
    private(set) var verifiedUnreadableCounts: [Int] = []

    func recordOwnPhotoBackupOutcome(_ outcome: SealedBackupRestoreOutcome) {
        outcomes.append(outcome)
    }

    func recordOwnPhotoBackupUploadFailed(_ failed: Bool) {
        uploadFailures.append(failed)
    }

    func recordOwnPhotoBackupVerifiedUnreadable(_ count: Int) {
        verifiedUnreadableCounts.append(count)
    }
}

/// Collects the audit trail for one test, so a "nothing silent" rule can be asserted rather than
/// assumed. Handlers accumulate in `FernletAuditLog`'s registry, so installing one never displaces
/// another suite's — but it must still be removed on teardown.
private final class AuditCapture {
    private let lock = NSLock()
    private var storedEvents: [String] = []
    private var token: UUID?

    func install() {
        token = FernletAuditLog.addCaptureHandler { [weak self] event, _ in
            guard let self else { return }
            self.lock.lock()
            self.storedEvents.append(event)
            self.lock.unlock()
        }
    }

    func uninstall() {
        if let token {
            FernletAuditLog.removeCaptureHandler(token)
            self.token = nil
        }
    }

    func contains(_ event: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storedEvents.contains(event)
    }
}

/// In-memory `CloudKitRecordDatabase` for the photo route, with the one production fidelity these
/// tests depend on: an incoming `CKAsset` is copied to a stable URL, because the real service
/// deletes its temp file as soon as the save returns.
private final class MockPhotoRecordDatabase: CloudKitRecordDatabase {
    private(set) var records: [CKRecord] = []
    /// When true every `saveRecords` throws — the offline / signed-out / over-quota / record-type-
    /// not-in-Production family, all of which surface to the service as a throwing save.
    var failSaves = false
    /// Record names whose fetch throws, modelling a transient CloudKit failure confined to one
    /// record while everything else works.
    var unfetchableRecordNames: Set<String> = []
    /// How many `saveRecords` calls succeed before every LATER one throws, or nil for no limit.
    /// `failSaves` is all-or-nothing for a whole run, so it cannot express the one shape a
    /// multi-pass migration run needs: a first pass that commits and a second that fails.
    var failSavesAfterCallCount: Int?
    /// `saveRecords` calls that have succeeded so far — what `failSavesAfterCallCount` counts.
    private(set) var saveCallCount = 0

    /// The failure `failSaves` / `failSavesAfterCallCount` / `unfetchableRecordNames` inject.
    struct InjectedFailure: Error {}

    func recordZoneIDs() async throws -> [CKRecordZone.ID] {
        var seen = Set<String>()
        return records.compactMap { record in
            let zoneID = record.recordID.zoneID
            return seen.insert("\(zoneID.ownerName):\(zoneID.zoneName)").inserted ? zoneID : nil
        }
    }

    func recordIDs(matching recordType: String, in zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID] {
        records.filter { $0.recordType == recordType && $0.recordID.zoneID == zoneID }.map(\.recordID)
    }

    func records(for recordIDs: [CKRecord.ID]) async throws -> [CKRecord] {
        let requested = Set(recordIDs.map(\.recordName))
        if !unfetchableRecordNames.isDisjoint(with: requested) { throw InjectedFailure() }
        return records.filter { requested.contains($0.recordID.recordName) }
    }

    func saveRecords(_ incoming: [CKRecord]) async throws {
        if failSaves { throw InjectedFailure() }
        if let failSavesAfterCallCount, saveCallCount >= failSavesAfterCallCount { throw InjectedFailure() }
        saveCallCount += 1
        for record in incoming {
            if let asset = record["encryptedBlob"] as? CKAsset, let sourceURL = asset.fileURL {
                let stableURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("fernlet-sealed-photo-test")
                try FileManager.default.copyItem(at: sourceURL, to: stableURL)
                record["encryptedBlob"] = CKAsset(fileURL: stableURL)
            }
            overwrite(record)
        }
    }

    func deleteRecords(with recordIDs: [CKRecord.ID]) async throws {
        let names = Set(recordIDs.map(\.recordName))
        records.removeAll { names.contains($0.recordID.recordName) }
    }

    // MARK: Inspection helpers

    func overwrite(_ record: CKRecord) {
        records.removeAll { $0.recordID == record.recordID }
        records.append(record)
    }

    func record(named name: String) -> CKRecord? {
        records.first { $0.recordID.recordName == name }
    }

    func remove(named name: String) {
        records.removeAll { $0.recordID.recordName == name }
    }

    func recordNames(withPrefix prefix: String) -> [String] {
        records.map(\.recordID.recordName).filter { $0.hasPrefix(prefix) }.sorted()
    }

    /// The stored ciphertext bytes behind a record's `CKAsset`, so a test can assert a record was
    /// left byte-identical across another record's write.
    func ciphertext(of record: CKRecord) -> Data? {
        guard let asset = record["encryptedBlob"] as? CKAsset, let url = asset.fileURL else { return nil }
        return try? Data(contentsOf: url)
    }

    func ciphertext(named name: String) -> Data? {
        record(named: name).flatMap(ciphertext(of:))
    }

    /// Swaps one record's ciphertext for another's, modelling a substituted body that is itself
    /// validly sealed (which is why only the manifest's content hash can catch it).
    func replaceCiphertext(named name: String, with ciphertext: Data) {
        guard let record = record(named: name) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("fernlet-sealed-photo-test")
        try? ciphertext.write(to: url)
        record["encryptedBlob"] = CKAsset(fileURL: url)
    }
}
