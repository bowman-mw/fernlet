// RecipeNameDisclosureTests.swift
// FernletTests
//
// SEC-L29 (owner 2026-11-13, option c): the recipe radio stops advertising your name. Kept friends still
// see it, because their phones match a rotating friend tag the two of you can derive and read the name
// from their own records; strangers see none. "Show my name to everyone" (Settings › Nearby friends) is
// the opt-in, off by default.
//
// What the cells hold:
//   - the setting is off by default, and a settings blob written before it existed decodes it off;
//   - the recipe friend tag is mutual, per epoch, and never the presence tag for the same pair and epoch,
//     so the two radios' records cannot be joined by a shared token;
//   - the manager advertises one tag per kept friend and names a browsed record by the friend's own tag,
//     a blocked friend neither advertised nor matched, and the switch reaches the pair session;
//   - Settings search finds the switch, in English and in Spanish.

import CryptoKit
import FernletConnections
@testable import FernletCrypto
import FernletDomainModel
import FernletFoundation
@testable import FernletSocial
import Foundation
@testable import ProximityKit
import Testing
@testable import Fernlet

/// The recipe radio's name disclosure, Fernlet's half (SEC-L29).
@MainActor
@Suite(.serialized)
struct RecipeNameDisclosureTests {

    /// **Off by default, and off for a blob written before the switch existed.**
    @Test func theSwitchIsOffByDefaultAndForAnOlderBlob() throws {
        #expect(!FernletSettings().advertiseNameToEveryoneNearby, "a fresh install shows its name to everyone")
        var model = FernletSettings()
        model.advertiseNameToEveryoneNearby = true
        let data = try JSONEncoder().encode(model)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["advertiseNameToEveryoneNearby"] as? Bool == true, "the switch does not round-trip")
        object.removeValue(forKey: "advertiseNameToEveryoneNearby")
        let older = try JSONDecoder().decode(
            FernletSettings.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(!older.advertiseNameToEveryoneNearby, "a blob from before the switch decodes it on")
    }

    /// **The recipe tag is mutual, rotates with the epoch, and is never the presence tag.**
    @Test func theRecipeTagIsMutualAndNeverThePresenceTag() throws {
        let (alice, idA) = try makeProvisionedService()
        defer { KeychainItem.deleteAll(service: idA) }
        let (bob, idB) = try makeProvisionedService()
        defer { KeychainItem.deleteAll(service: idB) }
        let epoch: UInt64 = 1_900_000
        let fromAlice = try alice.recipeFriendTag(for: bob.localKeyAgreementPublicKey, epoch: epoch)
        let fromBob = try bob.recipeFriendTag(for: alice.localKeyAgreementPublicKey, epoch: epoch)
        #expect(fromAlice == fromBob, "the two members of a pair derive different recipe tags")
        #expect(fromAlice.count == IdentityService.presenceTagByteCount)
        #expect(fromAlice != (try alice.recipeFriendTag(for: bob.localKeyAgreementPublicKey, epoch: epoch + 1)),
                "the recipe tag does not rotate with the epoch")
        #expect(fromAlice != (try alice.presenceTag(for: bob.localKeyAgreementPublicKey, epoch: epoch)),
                "the recipe radio would publish the presence radio's token, joining the two records")
        #expect(FernletCryptoPurpose.HMAC.recipeFriendEpochTagV1.data
                != FernletCryptoPurpose.HMAC.presenceEpochTagV1.data)
    }

    /// **The manager advertises a tag per kept friend and names a record by the friend's own tag.**
    @Test func theManagerAdvertisesKeptFriendsAndNamesThemByTheirTags() throws {
        let (me, idMe) = try makeProvisionedService()
        defer { KeychainItem.deleteAll(service: idMe) }
        let (sam, idSam) = try makeProvisionedService()
        defer { KeychainItem.deleteAll(service: idSam) }
        let (blocked, idBlocked) = try makeProvisionedService()
        defer { KeychainItem.deleteAll(service: idBlocked) }
        let host = NameDisclosureTestHost()
        let manager = ProximityRecipeShareManager(store: host, makeSession: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let epoch = IdentityService.presenceEpoch(at: now)
        var gone = record(named: "Blocked", for: blocked)
        gone.blockedAt = now
        let friends = [record(named: "Sam", for: sam), gone]

        manager.applyNameDisclosure(toEveryone: false, friends: friends, identity: me, at: now)
        #expect(!manager.advertisesNameToEveryone, "the default reached the radio as an opt-in")
        let samsTag = try sam.recipeFriendTag(for: me.localKeyAgreementPublicKey, epoch: epoch).base64EncodedString()
        let samsLateTag = try sam.recipeFriendTag(for: me.localKeyAgreementPublicKey, epoch: epoch - 1)
            .base64EncodedString()
        let blockedTag = try blocked.recipeFriendTag(for: me.localKeyAgreementPublicKey, epoch: epoch)
            .base64EncodedString()
        #expect(manager.friendName(matching: [samsTag]) == "Sam", "a kept friend's record is not named")
        #expect(manager.friendName(matching: [samsLateTag]) == "Sam", "a friend one rotation behind is not named")
        #expect(manager.friendName(matching: [blockedTag]) == nil, "a blocked friend is still recognized")
        #expect(manager.friendName(matching: ["AAAAAAAAAAA="]) == nil, "a stranger's record is named")

        manager.applyNameDisclosure(toEveryone: true, friends: friends, identity: me, at: now)
        #expect(manager.advertisesNameToEveryone, "the opt-in did not reach the radio")
    }

    /// **The store's own wiring names a kept friend (release review since build 460).**
    ///
    /// The cell above hands the manager an identity this file provisioned, so it could not see that the
    /// store's identity never was: the store built a fourth `makeProximityIdentity()` instance that
    /// nothing provisioned, every friend tag threw `notProvisioned`, and the picker named nobody. This
    /// cell goes through the real store (`makeTestStore()`, `recipeShareManager`, its
    /// `nameDisclosureInputs` closure) and checks the derivation from the friend's side, under the
    /// app's real key-agreement key, read by a fresh instance on the same keychain rows.
    @Test func theStoresOwnWiringNamesAKeptFriend() throws {
        let (sam, idSam) = try makeProvisionedService()
        defer { KeychainItem.deleteAll(service: idSam) }
        let store = makeTestStore()
        store.proximityTrustVault.trust(peerIdentity(named: "Sam", for: sam), mode: .friend)
        let audit = TagFailureAudit()
        defer { audit.stop() }
        let now = Date()
        let epoch = IdentityService.presenceEpoch(at: now)

        store.recipeShareManager.refreshNameDisclosure(at: now)

        let inputs = store.recipeNameDisclosureInputs()
        #expect(!inputs.identity.localKeyAgreementPublicKey.isEmpty,
                "the store derives friend tags under an identity nothing provisioned")
        let app = store.makeProximityIdentity()
        try app.ensureProvisioned()
        #expect(inputs.identity.localKeyAgreementPublicKey == app.localKeyAgreementPublicKey,
                "the tags derive under a key other than the app's own")
        let samsTag = try sam.recipeFriendTag(for: app.localKeyAgreementPublicKey, epoch: epoch)
            .base64EncodedString()
        #expect(store.recipeShareManager.friendName(matching: [samsTag]) == "Sam",
                "a kept friend's recipe record is not named through the store's wiring")
        #expect(audit.failures.isEmpty, "the store's tag derivation failed: \(audit.failures)")
    }

    /// **A tag that cannot be derived is logged, not swallowed (R7).**
    @Test func anUnprovisionedIdentityIsLoggedNotSwallowed() throws {
        let (sam, idSam) = try makeProvisionedService()
        defer { KeychainItem.deleteAll(service: idSam) }
        let serviceID = "com.fernlet.identity.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: serviceID) }
        let unprovisioned = IdentityService(keychainService: serviceID)
        let manager = ProximityRecipeShareManager(store: NameDisclosureTestHost(), makeSession: nil)
        let audit = TagFailureAudit()
        defer { audit.stop() }

        manager.applyNameDisclosure(toEveryone: false, friends: [record(named: "Sam", for: sam)],
                                    identity: unprovisioned, at: Date(timeIntervalSince1970: 1_800_000_000))

        let failures = audit.failures
        #expect(failures.count == 1, "a failed pass logged \(failures.count) lines, not one")
        #expect(failures.first?["failures"] == "4", "one advertised tag and three matched epochs should fail")
        #expect(failures.first?["error"] == "notProvisioned", "the line does not name the cause")
    }

    /// **Settings search finds the switch, in English and in Spanish.**
    @Test func settingsSearchFindsTheSwitch() {
        let english = SettingsSearchIndex.results(for: "my name").map(\.title)
        #expect(english.contains("Show my name to everyone"), "\"my name\" found \(english)")
        #expect(SettingsSearchSynonyms.spanish["Show my name to everyone"]?.contains("mi nombre") == true,
                "the switch has no Spanish synonyms")
    }

    // MARK: - Helpers

    private func makeProvisionedService() throws -> (IdentityService, String) {
        let serviceID = "com.fernlet.identity.test.\(UUID().uuidString)"
        let service = IdentityService(keychainService: serviceID)
        try service.ensureProvisioned()
        return (service, serviceID)
    }

    private func peerIdentity(named name: String, for identity: IdentityService) -> ProximityCoordinator.PeerIdentity {
        ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: name,
            signingPublicKey: identity.localSigningPublicKey,
            keyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            fingerprint: identity.localFingerprint,
            rangingMode: .rssi,
            firstSeenAt: Date(),
            capabilities: ProximityCapability.allCases.map(\.rawValue)
        )
    }

    private func record(named name: String, for identity: IdentityService) -> ProximityTrustedPeerRecord {
        ProximityTrustedPeerRecord(
            id: UUID(),
            displayName: name,
            fingerprint: IdentityService.fingerprint(of: identity.localSigningPublicKey),
            signingPublicKey: identity.localSigningPublicKey,
            keyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            mode: .friend,
            firstAcceptedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

/// The `recipe.nameDisclosure.tagDerivationFailed` lines the audit log captured while it was installed.
/// Locked: capture handlers run on whichever thread logs.
private final class TagFailureAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [[String: String]] = []
    private var token: UUID?

    init() {
        token = FernletAuditLog.addCaptureHandler { [weak self] event, context in
            guard let self, event == "recipe.nameDisclosure.tagDerivationFailed" else { return }
            self.lock.lock()
            self.captured.append(context)
            self.lock.unlock()
        }
    }

    var failures: [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func stop() {
        if let token { FernletAuditLog.removeCaptureHandler(token) }
    }
}

/// The smallest host a recipe manager can be built over.
private final class NameDisclosureTestHost: ProximityHost {
    var proximityDisplayName: String { "Tester" }
    let proximityTrustVault = ProximityTrustVault()
    var proximityTrustStore: any ProximityTrustStore { proximityTrustVault }
    let proximityNamespace = ProximityNamespace.fernlet
    let proximityInstallBinding: any ProximityInstallBinding = FernletDeviceBindingAdapter()
    func makeProximityTrustPolicy() -> any ProximityTrustPolicy { FriendSessionTrustPolicy(vault: proximityTrustVault) }
    func isBlockedFingerprint(_ fingerprint: String) -> Bool { proximityTrustVault.isBlockedFingerprint(fingerprint) }
    func blockProximityPeer(signingPublicKey: Data) { proximityTrustVault.block(signingPublicKey: signingPublicKey) }
}
