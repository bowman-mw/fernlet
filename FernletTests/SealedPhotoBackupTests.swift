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
        KeychainItem.store(
            escrowRaw ?? Data((0..<32).map { UInt8($0 &+ 3) }),
            account: "backupEscrowPrivateKey",
            service: service,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            synchronizable: false
        )
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
        await coordinatorTwo.synchronize(preferenceOverride: true, requiringSync: false)
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
        await coordinatorThree.synchronize(preferenceOverride: true, requiringSync: false)

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
        await coordinator.synchronize(preferenceOverride: true, requiringSync: false)

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
}

// MARK: - Test doubles
//
// `AlwaysAvailableAccountProvider` is shared with `SealedBackupPayloadCoverageTests`.

/// Captures the non-silent status the coordinator publishes, so a test can assert that a failure
/// reached the user's banner instead of being swallowed.
@MainActor
private final class RecordingOwnPhotoHost: OwnPhotoBackupContext {
    private(set) var outcomes: [SealedBackupRestoreOutcome] = []

    func recordOwnPhotoBackupOutcome(_ outcome: SealedBackupRestoreOutcome) {
        outcomes.append(outcome)
    }
}

/// In-memory `CloudKitRecordDatabase` for the photo route, with the one production fidelity these
/// tests depend on: an incoming `CKAsset` is copied to a stable URL, because the real service
/// deletes its temp file as soon as the save returns.
private final class MockPhotoRecordDatabase: CloudKitRecordDatabase {
    private(set) var records: [CKRecord] = []

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
        return records.filter { requested.contains($0.recordID.recordName) }
    }

    func saveRecords(_ incoming: [CKRecord]) async throws {
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
