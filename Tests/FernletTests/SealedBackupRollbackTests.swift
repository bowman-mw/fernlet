import ProximityKit
import Foundation
import Security
import CryptoKit
import FernletFoundation
import Testing
import FernletDomainModel
import CloudKitSync
@testable import Fernlet

/// Regression suite for code-review finding 14 (sealed backups replayable / rollback-able).
///
/// Two halves are tested separately because they defend different attacks:
/// 1. **AAD binding** — `generation` and `updatedAt` are authenticated, so an attacker cannot edit
///    the metadata on a record to make an old backup look current.
/// 2. **High-water mark** — a wholesale substitution of an older, validly sealed generation is
///    authentic by construction, so only the device-local `SealedBackupGenerationStore` can catch it.
///
/// Both are required: the AAD alone cannot detect rollback, and the counter alone would be
/// meaningless if the counter itself were editable.
@MainActor
@Suite(.serialized)
struct SealedBackupRollbackTests {
    private func makeSealingIdentity(_ serviceID: String) throws -> IdentityService {
        let identity = IdentityService(keychainService: serviceID)
        try identity.ensureProvisioned()
        identity.provisionBackupEscrowKeyForSealing()
        return identity
    }

    /// An isolated defaults suite so the high-water mark never leaks between tests or into the
    /// developer's own `.standard` domain. Returns the suite name so the caller can tear it down.
    private func makeSuite() -> (UserDefaults, String) {
        let name = "fernlet.tests.sealedbackup.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    // MARK: - AAD binding

    @Test func editingGenerationBreaksAuthentication() throws {
        let serviceID = "com.fernlet.sealed-backup.rollback.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: serviceID) }
        let identity = try makeSealingIdentity(serviceID)

        var record = try SealedBackupCrypto.seal(
            Data("private archive".utf8),
            payloadType: .periodData,
            identityService: identity,
            generation: 7
        )
        // The attack the fix exists to stop: relabel an old backup as a newer generation so the
        // high-water check waves it through. Before the fix this field was unauthenticated.
        record.generation = 99

        #expect(throws: SealedBackupError.malformedRecord) {
            try SealedBackupCrypto.open(record, identityService: identity)
        }
    }

    @Test func editingUpdatedAtBreaksAuthentication() throws {
        let serviceID = "com.fernlet.sealed-backup.rollback.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: serviceID) }
        let identity = try makeSealingIdentity(serviceID)

        var record = try SealedBackupCrypto.seal(
            Data("private archive".utf8),
            payloadType: .sensitiveNotes,
            identityService: identity,
            generation: 1
        )
        record.updatedAt = record.updatedAt.addingTimeInterval(86_400)

        #expect(throws: SealedBackupError.malformedRecord) {
            try SealedBackupCrypto.open(record, identityService: identity)
        }
    }

    /// Guards the whole-second rounding in the AAD: a timestamp carrying sub-second precision must
    /// still round-trip, or every real backup would fail to open after a CloudKit round trip.
    @Test func subSecondTimestampPrecisionStillOpens() throws {
        let serviceID = "com.fernlet.sealed-backup.rollback.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: serviceID) }
        let identity = try makeSealingIdentity(serviceID)
        let plaintext = Data("private archive".utf8)

        var record = try SealedBackupCrypto.seal(
            plaintext,
            payloadType: .periodData,
            identityService: identity,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000.75),
            generation: 3
        )
        // Same whole second, different fractional part — as a CloudKit round trip may deliver it.
        record.updatedAt = Date(timeIntervalSince1970: 1_800_000_000.25)

        #expect(try SealedBackupCrypto.open(record, identityService: identity) == plaintext)
    }

    @Test func sameGenerationDifferentPayloadTypesStayIndependent() throws {
        let serviceID = "com.fernlet.sealed-backup.rollback.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: serviceID) }
        let identity = try makeSealingIdentity(serviceID)

        var record = try SealedBackupCrypto.seal(
            Data("private archive".utf8),
            payloadType: .periodData,
            identityService: identity,
            generation: 4
        )
        record.payloadType = .sensitiveNotes

        #expect(throws: SealedBackupError.malformedRecord) {
            try SealedBackupCrypto.open(record, identityService: identity)
        }
    }

    // MARK: - High-water mark

    @Test func mintedGenerationsAreMonotonic() {
        let (defaults, name) = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        var store = SealedBackupGenerationStore(defaults: defaults)

        #expect(store.lastSeen(for: .periodData) == 0)
        #expect(store.mintNext(for: .periodData) == 1)
        #expect(store.mintNext(for: .periodData) == 2)
        #expect(store.mintNext(for: .periodData) == 3)
        #expect(store.lastSeen(for: .periodData) == 3)
    }

    @Test func payloadTypesHaveIndependentCounters() {
        let (defaults, name) = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        var store = SealedBackupGenerationStore(defaults: defaults)

        _ = store.mintNext(for: .periodData)
        _ = store.mintNext(for: .periodData)
        #expect(store.mintNext(for: .sensitiveNotes) == 1)
        #expect(store.lastSeen(for: .periodData) == 2)
    }

    /// A fresh device has no history, so it must accept whatever it first finds — otherwise a
    /// legitimate cross-device restore would be impossible.
    @Test func freshDeviceAcceptsAnyGeneration() {
        let (defaults, name) = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let store = SealedBackupGenerationStore(defaults: defaults)

        #expect(store.lastSeen(for: .periodData) == 0)
    }

    @Test func acceptingOnlyEverMovesForward() {
        let (defaults, name) = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        var store = SealedBackupGenerationStore(defaults: defaults)

        store.recordAccepted(9, for: .periodData)
        #expect(store.lastSeen(for: .periodData) == 9)
        // A restore of an older generation must never lower the floor.
        store.recordAccepted(4, for: .periodData)
        #expect(store.lastSeen(for: .periodData) == 9)
        // A newer one from another device does raise it.
        store.recordAccepted(12, for: .periodData)
        #expect(store.lastSeen(for: .periodData) == 12)
    }

    /// The wipe path must clear the mark, or a post-wipe backup (which restarts at generation 1)
    /// would be rejected as a rollback of the user's own deleted data.
    @Test func resetClearsEveryPayloadType() {
        let (defaults, name) = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        var store = SealedBackupGenerationStore(defaults: defaults)

        _ = store.mintNext(for: .periodData)
        _ = store.mintNext(for: .sensitiveNotes)
        store.reset()

        for payloadType in SealedBackupPayloadType.allCases {
            #expect(store.lastSeen(for: payloadType) == 0)
        }
        // And minting starts over, below the pre-wipe mark — which is only safe because the records
        // it protected were deleted in the same operation.
        #expect(store.mintNext(for: .periodData) == 1)
    }

    /// The exact rollback scenario end to end, at the value level: generation 5 is seen, then an
    /// authentic generation-2 record is presented. It opens (it is genuinely ours) but must be
    /// rejected on the high-water comparison.
    @Test func authenticOlderGenerationIsRejectedAfterNewerSeen() throws {
        let serviceID = "com.fernlet.sealed-backup.rollback.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: serviceID) }
        let identity = try makeSealingIdentity(serviceID)
        let (defaults, name) = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        var store = SealedBackupGenerationStore(defaults: defaults)

        let old = try SealedBackupCrypto.seal(
            Data("superseded archive".utf8),
            payloadType: .periodData,
            identityService: identity,
            generation: 2
        )
        store.recordAccepted(5, for: .periodData)

        // It authenticates — this is the point. Rollback is invisible to the AEAD.
        #expect(throws: Never.self) {
            try SealedBackupCrypto.open(old, identityService: identity)
        }
        // Only the remembered high-water mark catches it.
        #expect(old.generation < store.lastSeen(for: .periodData))
    }

    // MARK: - Every payload type, including the two added in Phase 3

    /// The rollback defense is per-payload-type, and a payload added later inherits it only through
    /// `allCases`. This walks every case so a new payload cannot ship with an un-exercised counter:
    /// each one mints monotonically and keeps its own independent high-water mark.
    @Test func generationsAreMonotonicAndIndependentForEveryPayloadType() {
        let (defaults, name) = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        var store = SealedBackupGenerationStore(defaults: defaults)

        for payloadType in SealedBackupPayloadType.allCases {
            #expect(store.lastSeen(for: payloadType) == 0, "\(payloadType.rawValue) did not start at zero")
            #expect(store.mintNext(for: payloadType) == 1)
            #expect(store.mintNext(for: payloadType) == 2)
            #expect(store.lastSeen(for: payloadType) == 2)
        }
        // Independent, not shared: minting on one payload never moved another's mark.
        for payloadType in SealedBackupPayloadType.allCases {
            #expect(store.lastSeen(for: payloadType) == 2)
        }
    }

    /// The substitution attack, run against the two new payloads: an authentic but OLDER generation
    /// opens cleanly (rollback is invisible to the AEAD) and is caught only by the high-water mark.
    @Test func authenticOlderGenerationIsRejectedForTheNewPayloadTypes() throws {
        let serviceID = "com.fernlet.sealed-backup.rollback.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: serviceID) }
        let identity = try makeSealingIdentity(serviceID)
        let (defaults, name) = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        var store = SealedBackupGenerationStore(defaults: defaults)

        for payloadType in [SealedBackupPayloadType.journalNarratives, .intimacyLogs] {
            let old = try SealedBackupCrypto.seal(
                Data("superseded \(payloadType.rawValue)".utf8),
                payloadType: payloadType,
                identityService: identity,
                generation: 2
            )
            store.recordAccepted(5, for: payloadType)
            #expect(throws: Never.self) {
                try SealedBackupCrypto.open(old, identityService: identity)
            }
            #expect(old.generation < store.lastSeen(for: payloadType),
                    "\(payloadType.rawValue) would have accepted a rolled-back backup")
        }
    }
}
