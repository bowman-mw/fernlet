// PrivacyWipeIdentityEffectTests.swift
// FernletTests
//
// Owner-calls item 4c (2026-09-22), the third priced hardening of the deletion round: the wipe wall
// (`PrivacyWipeCoverageTests`) pins that each proximity manager HAS a `wipeIdentityForDeleteAll()`
// and that `FernletStore.deleteAllData` CALLS all three — never what the call DOES. The cutover
// round watched a wipe leg's retirement go red nowhere for exactly that reason (plan §28.8). These
// cells pin the EFFECT, one per conformer, on a keychain service of the cell's own:
//
//   1. the wiped instance holds no key in RAM (`localFingerprint` is empty), so nothing in this
//      process can sign as the old identity until relaunch;
//   2. the keychain holds no row a FRESH instance could load — it mints a different identity;
//   3. the wiped instance re-provisions from the keychain like any other, not from a cached key.
//
// A manager whose door forgot to wipe (or wiped the keychain but kept its cache) fails 1–3.
//
// Every manager here is built on an INJECTED identity. The test bundle runs inside the app on the
// Simulator and shares its keychain, so a manager on the default identity would wipe the test
// host's real one — which is why `ProximityRecipeShareManager` gained the `identity:` seam in the
// same commit.

import Foundation
import Testing
import FernletFoundation
@testable import ProximityKit
@testable import Fernlet

/// The wipe's effect, per conformer — the value half the wipe wall's source needles cannot see.
@MainActor
@Suite(.serialized)
struct PrivacyWipeIdentityEffectTests {

    /// A real store to host the managers, built through the house helper so it owns EVERY
    /// per-instance isolation seam and every repository is in-memory.
    ///
    /// Until 2026-09-24 this was a direct store construction that passed five of the seams and left
    /// the AI-call quota on `.standard` and the share-extension recipe inbox on the real app-group
    /// file — both of which any concurrent `deleteAllData` in the process resets. Because this file
    /// names that funnel, `PhotoDirectoryIsolationTests` demanded both arguments and failed two of
    /// its cells on main. Its walls cannot see the rest of what the direct form defaulted — the
    /// saved-recipe, custom-item, coin and milestone repositories on the shared on-disk Core Data
    /// store, the food-search correction memory on `.standard`, the bundled food catalog.
    /// `makeTestStore()` isolates all of it, and a seam added later reaches this file through the
    /// helper rather than through a new wall.
    private func makeStore() -> FernletStore {
        makeTestStore()
    }

    /// A provisioned identity on a keychain service nobody else uses, and that service's name.
    private func mintIdentity(_ label: String) throws -> (IdentityService, String) {
        let service = "com.fernlet.test.wipe-effect.\(label).\(UUID().uuidString)"
        let identity = IdentityService(keychainService: service)
        try identity.ensureProvisioned()
        return (identity, service)
    }

    /// What a wipe must have done to `identity`, whose fingerprint was `before`, on `service`.
    ///
    /// The probe runs BEFORE the wiped instance re-provisions, so the new rows it finds can only be
    /// its own mint: had the old rows survived, `ensureProvisioned()` would have loaded them and
    /// answered `before`.
    private func expectIdentityDestroyed(_ identity: IdentityService, service: String, before: String) throws {
        #expect(!before.isEmpty, "the fixture really provisioned an identity to destroy")
        #expect(identity.localFingerprint.isEmpty, "the wiped instance holds no signing key in RAM")
        let probe = IdentityService(keychainService: service)
        try probe.ensureProvisioned()
        #expect(probe.localFingerprint != before, "no keychain row survived: a fresh instance mints a NEW identity")
        try identity.ensureProvisioned()
        #expect(identity.localFingerprint == probe.localFingerprint,
                "and the wiped instance re-provisions from the keychain, not from a cached key")
    }

    /// The mesh manager's door destroys the identity it was built on.
    @Test func theMeshManagersWipeDestroysItsIdentity() throws {
        let (identity, service) = try mintIdentity("mesh")
        defer { KeychainItem.deleteAll(service: service) }
        let store = makeStore()
        let manager = MeshNetworkManager(store: store, transport: FakeMeshTransportSession(), identity: identity)
        let before = identity.localFingerprint
        try manager.wipeIdentityForDeleteAll()
        try expectIdentityDestroyed(identity, service: service, before: before)
    }

    /// The presence manager's door destroys the identity it was built on.
    @Test func thePresenceManagersWipeDestroysItsIdentity() throws {
        let (identity, service) = try mintIdentity("presence")
        defer { KeychainItem.deleteAll(service: service) }
        let store = makeStore()
        let ledger = ProximityHeartLedger(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("wipe-effect-ledger-\(UUID().uuidString).json")
        )
        let manager = PresenceManager(store: store, ledger: ledger, identity: identity)
        let before = identity.localFingerprint
        try manager.wipeIdentityForDeleteAll()
        try expectIdentityDestroyed(identity, service: service, before: before)
    }

    /// The recipe-share manager's door destroys the identity it was built on — reachable only
    /// through the `identity:` seam this item added.
    @Test func theRecipeShareManagersWipeDestroysItsIdentity() throws {
        let (identity, service) = try mintIdentity("recipe")
        defer { KeychainItem.deleteAll(service: service) }
        let store = makeStore()
        let radio = FakeRecipeShareRadioSession()
        let manager = ProximityRecipeShareManager(store: store, makeSession: { radio }, identity: identity)
        let before = identity.localFingerprint
        try manager.wipeIdentityForDeleteAll()
        try expectIdentityDestroyed(identity, service: service, before: before)
    }
}
