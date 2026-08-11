import CryptoKit
import Foundation
import Security
import Testing
import UIKit
import PrivateMediaStore
@testable import Fernlet

/// Security-hardening Phase 5, step 5c: the own-photos at-rest key becomes **device-bound**, and the
/// read-path dual-open fallback goes away with it.
///
/// This suite exists because the flip is the one step in Phase 5 that can destroy user data. Binding
/// a key whose corpus is not fully migrated turns the stragglers into permanently unreadable bytes,
/// with no error, on a phone the user still owns; binding a key on a device with no cross-device
/// route silently deletes the user's only path onto a replacement phone. So the tests pin the gate's
/// **closed** directions at least as hard as its open one, and the end-to-end case proves the
/// property the whole phase is for: no own photo becomes unreadable across the flip.
///
/// Everything here runs against the REAL keychain rows (an isolated `UserDefaults` suite carries the
/// latch and the consent), because the thing under test is a keychain attribute — a mocked row would
/// prove nothing. Two consequences shape how the assertions are written:
/// - The suite is `@MainActor` and every test is synchronous, so parallel execution cannot interleave
///   two mutations of the same row.
/// - Nothing asserts "the real row is NOT bound": another test in this bundle may legitimately have
///   bound it already, and there is deliberately no un-bind path in shipping code. Refusals assert
///   the outcome plus *the row's class is unchanged across the call*, which is order-independent and
///   is the property that actually matters.
@MainActor
struct OwnPhotoKeyBindingTests {

    // MARK: - Fixtures

    private func jpeg(width: Int = 100, height: Int = 100) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.jpegData(compressionQuality: 0.7)!
    }

    private func sealed(_ plaintext: Data, under key: SymmetricKey) throws -> Data {
        try #require(try AES.GCM.seal(plaintext, using: key).combined)
    }

    /// Opens a sealed file the way the stores do, for the one artifact with no store-level reader
    /// that distinguishes "empty" from "unreadable" (the progress index).
    private func opens(_ url: URL, under key: SymmetricKey) -> Data? {
        guard let stored = try? Data(contentsOf: url),
              let box = try? AES.GCM.SealedBox(combined: stored) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    /// An isolated defaults suite: the migration latch and the binding consent must never be read
    /// from — or written to — the device's real state.
    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let name = "OwnPhotoKeyBindingTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func makeDocumentsDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwnPhotoKeyBindingTests-\(UUID().uuidString)", isDirectory: true)
        for directory in OwnPhotoCorpusLayout.sealedLocations(in: root).directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return root
    }

    private func bytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    /// The real own-photos row's current accessibility class — the thing the flip changes.
    private func ownRowAccessibility() -> String? {
        KeychainPrivateMediaKeyProvider.ownPhotoRowAccessibility()
    }

    private var deviceBoundClass: String { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String }

    // MARK: - The gate's closed directions

    // MARK: The load-bearing refusal: until `OwnPhotoMigrationLatch` proves every own file is sealed
    // under the own key, binding is refused even with the escrow route on — because a file still
    // under the pre-split key would become unreadable the moment the fallback that opens it goes.
    @Test func bindingIsRefusedUntilTheMigrationLatchIsSet() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let before = ownRowAccessibility()
        let outcome = OwnPhotoKeyBinder(escrowRouteCommitted: true, defaults: defaults).bindIfEligible()
        #expect(outcome == .refusedMigrationIncomplete)
        #expect(ownRowAccessibility() == before, "a refused bind changed the row's custody anyway")
    }

    // MARK: The second half of the gate: a fully migrated corpus is still not bound when the user has
    // neither the escrow photo backup on nor a recorded consent. Binding there would trade away their
    // phone swap without asking.
    @Test func bindingIsRefusedWithoutACrossDeviceRoute() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        OwnPhotoMigrationLatch(defaults: defaults).markComplete()

        let before = ownRowAccessibility()
        let binder = OwnPhotoKeyBinder(escrowRouteCommitted: false, defaults: defaults)
        #expect(!binder.hasCrossDeviceRoute)
        #expect(!binder.isEligible)
        #expect(binder.bindIfEligible() == .refusedNoRecoveryRoute)
        #expect(ownRowAccessibility() == before, "a refused bind changed the row's custody anyway")
    }

    // MARK: A refusal must never cost the user their answer: consent is a durable decision, so a
    // ceremony that runs while the migration is still going records it and binds on a later pass.
    // Re-asking would be the wrong remedy for a transient state.
    @Test func consentSurvivesARefusedBind() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let outcome = OwnPhotoKeyBinder(escrowRouteCommitted: false, defaults: defaults).recordConsentAndBind()
        #expect(outcome == .refusedMigrationIncomplete)
        #expect(OwnPhotoDeviceBindingConsent(defaults: defaults).isRecorded)
        // ...and the recorded consent is what makes the NEXT evaluation eligible.
        OwnPhotoMigrationLatch(defaults: defaults).markComplete()
        #expect(OwnPhotoKeyBinder(escrowRouteCommitted: false, defaults: defaults).isEligible)
    }

    // MARK: - The gate's open directions

    // MARK: Latch set + escrow route on ⇒ the row is device-bound. This is the assertion the whole
    // phase builds toward.
    @Test func theEscrowRouteUnlocksTheFlip() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        OwnPhotoMigrationLatch(defaults: defaults).markComplete()

        let outcome = OwnPhotoKeyBinder(escrowRouteCommitted: true, defaults: defaults).bindIfEligible()
        #expect(outcome == .bound)
        #expect(OwnPhotoKeyBinder.isOwnPhotoKeyDeviceBound())
        #expect(ownRowAccessibility() == deviceBoundClass)
    }

    // MARK: Explicit consent substitutes for the escrow route — the branch for users who want the
    // binding without paying iCloud quota for it, and who have been told what it costs.
    @Test func recordedConsentSubstitutesForTheEscrowRoute() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        OwnPhotoMigrationLatch(defaults: defaults).markComplete()

        let outcome = OwnPhotoKeyBinder(escrowRouteCommitted: false, defaults: defaults).recordConsentAndBind()
        #expect(outcome == .bound)
        #expect(ownRowAccessibility() == deviceBoundClass)
    }

    // MARK: Idempotence: a second evaluation on an already-bound row is a read, not a re-write, and
    // it must NOT disturb the key material (a delete-then-add re-store would have a crash window
    // that destroys every own photo — the reason the flip goes through `SecItemUpdate`).
    @Test func bindingIsIdempotentAndNeverChangesTheKeyMaterial() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        OwnPhotoMigrationLatch(defaults: defaults).markComplete()
        let binder = OwnPhotoKeyBinder(escrowRouteCommitted: true, defaults: defaults)

        #expect(binder.bindIfEligible() == .bound)
        let afterFirst = try #require(KeychainPrivateMediaKeyProvider(role: .ownPhotos).mediaKey())
        #expect(binder.bindIfEligible() == .bound)
        let afterSecond = try #require(KeychainPrivateMediaKeyProvider(role: .ownPhotos).mediaKey())
        #expect(bytes(afterFirst) == bytes(afterSecond), "re-binding rotated the own-photos key")
        #expect(ownRowAccessibility() == deviceBoundClass)
    }

    // MARK: - The property the phase exists for

    // MARK: End to end, on the real rows: a corpus sealed under the PRE-SPLIT key is migrated, the
    // key is bound, the dual-open fallback is dropped — and every photo still opens, byte-identical.
    // If the flip could strand a photo, this is where it would show.
    @Test func noOwnPhotoBecomesUnreadableAcrossTheFlip() throws {
        let root = try makeDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyKey = try #require(KeychainPrivateMediaKeyProvider(role: .friendWall).mediaKey())
        let ownKeyBefore = try #require(KeychainPrivateMediaKeyProvider(role: .ownPhotos).mediaKey())

        // One legacy-sealed photo in every own corpus, plus the sealed progress index.
        let locations = OwnPhotoCorpusLayout.sealedLocations(in: root)
        var photos: [(directory: URL, id: UUID, plaintext: Data)] = []
        for directory in locations.directories {
            let plaintext = jpeg()
            let id = UUID()
            try sealed(plaintext, under: legacyKey)
                .write(to: directory.appendingPathComponent("\(id.uuidString).jpg"))
            photos.append((directory, id, plaintext))
        }
        let indexURL = try #require(locations.files.first)
        let indexPlaintext = Data("[]".utf8)
        try sealed(indexPlaintext, under: legacyKey).write(to: indexURL)

        // Binding is refused while those files are still legacy — the latch has not been earned yet.
        #expect(OwnPhotoKeyBinder(escrowRouteCommitted: true, defaults: defaults).bindIfEligible()
                == .refusedMigrationIncomplete)

        // The eager pass earns it.
        #expect(OwnPhotoKeyMigrator.standard(documentsDirectory: root, defaults: defaults).run(),
                "the migration did not reach a clean pass")
        #expect(OwnPhotoKeyBinder(escrowRouteCommitted: true, defaults: defaults).bindIfEligible() == .bound)
        #expect(ownRowAccessibility() == deviceBoundClass)

        // The key is the same key, in a stricter row — otherwise nothing below could open.
        let ownKeyAfter = try #require(KeychainPrivateMediaKeyProvider(role: .ownPhotos).mediaKey())
        #expect(bytes(ownKeyAfter) == bytes(ownKeyBefore), "the flip rotated the own-photos key")

        // Read back exactly the way the app reads once bound: the real store types, own key only,
        // `legacyKeyProvider: nil`. Legacy-plaintext upgrade stays OFF so nothing can be laundered
        // into a pass — only genuine ciphertext under the bound key may satisfy these.
        for photo in photos {
            let store = MealPhotoStore(
                directory: photo.directory,
                keyProvider: KeychainPrivateMediaKeyProvider(role: .ownPhotos),
                allowsLegacyPlaintextUpgrade: false,
                legacyKeyProvider: nil
            )
            #expect(store.imageData(for: photo.id) == photo.plaintext,
                    "a \(photo.directory.lastPathComponent) photo became unreadable across the binding flip")
        }
        #expect(opens(indexURL, under: ownKeyAfter) == indexPlaintext,
                "the sealed progress index became unreadable across the binding flip")
    }

    // MARK: - Wiring

    // MARK: The fallback drop is the half that makes the binding mean anything, and it is a
    // biconditional, not a one-way door: `FernletStore` must inject the pre-split key exactly when
    // the own key is NOT bound. Asserted against the real wiring so the two can't drift.
    @Test func theDualOpenFallbackIsPresentExactlyWhileTheKeyIsUnbound() {
        let bound = OwnPhotoKeyBinder.isOwnPhotoKeyDeviceBound()
        let fallback = FernletStore.ownPhotoLegacyKeyProvider()
        #expect((fallback == nil) == bound,
                "the own read path's legacy fallback does not track the key's binding state")
        if let fallback {
            #expect(fallback.role == .friendWall)
            #expect(!fallback.mintsIfAbsent, "a fallback probe must never CREATE the friend-wall row")
        }
    }

    // MARK: An absent/unreadable row answers "not bound", which KEEPS the fallback — the safe
    // direction. Pinned by construction: the accessor compares against the device-bound class, so
    // a nil attribute can only ever read as unbound.
    @Test func anUnreadableRowReadsAsUnbound() {
        #expect(OwnPhotoKeyBinder.isOwnPhotoKeyDeviceBound()
                == (KeychainPrivateMediaKeyProvider.ownPhotoRowAccessibility() == deviceBoundClass))
    }
}
