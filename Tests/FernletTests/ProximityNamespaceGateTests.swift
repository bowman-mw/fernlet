// ProximityNamespaceGateTests.swift
// FernletTests
//
// ProximityKit plan step A0.3 (Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md §4 A0.3; owner
// decision 5 on PR #1): ProximityKit refuses an unsound host namespace at run time, failing closed with
// a named audit event, and a manager refuses to start its radio under an identity of another
// namespace. A namespace judges itself once, when it is built (`ProximityNamespace.soundness`,
// `ProximityNamespaceSoundnessTests`); this suite holds each door that acts on that verdict to its
// error, its audit line and what it leaves undone:
//
// 1. **The identity.** Under an unsound namespace `ensureProvisioned()` throws every violation before
//    it reads or writes a keychain row, on every call, and `encryptGroupKey(_:for:)`, which needs no
//    provisioned key, throws them before it wraps anything; each writes `identity.namespace.unsound`
//    with its door.
// 2. **The radios.** The mesh, presence and recipe-share radios each refuse to start under an unsound
//    namespace before they mint, listen or advertise, with `mesh.quic.namespaceUnsound`,
//    `presence.quic.namespaceUnsound` and `recipe.quic.namespaceUnsound`.
// 3. **The audit line.** It carries the door, the violation count and the first violation's case name,
//    never a field path or a value; every violation case has a name, and the name is the case's own.
// 4. **One namespace per manager.** The mesh, presence and recipe-share managers each construct over an
//    identity of another namespace, audit `<area>.identity.namespaceMismatch` once at construction and
//    refuse every start of their radio with it, and the mesh manager every founding of a mesh, before it
//    signs or seals anything; over an identity of their own namespace they audit nothing and start, and
//    the mesh manager founds.
// 5. **A sound namespace passes.** The identity provisions and wraps a group key another identity of
//    the namespace opens, the recipe-share radio comes up, and the mesh and presence radios hold the
//    sound verdict their starts read. Tier 1 cannot bring those two up for real (a live listener, and
//    the Local Network permission with it); their refusal cells prove the starts read that verdict.
// 6. **The pair-secret door.** A declared feature salt that repeats a protocol label makes the
//    namespace unsound, so its identity refuses to provision and the salt derives nothing.
//    `pairSecret(with:purpose:)` refuses, with `undeclaredPurpose` and before it reads a key, every
//    purpose its namespace does not declare as a feature salt (one never declared, the protocol's own
//    salt, a signature label, the declared salt's bytes in another role), throws `notProvisioned`
//    for a declared salt before provisioning, and derives under a declared salt the key both members
//    of a pair derive, writing no audit line and no keychain row.
//
// Every namespace here is built from literals that belong to no shipping app ("gate"), the way
// `ProximityNamespaceSoundnessTests` builds its fixtures: sound as written, and unsound with two
// literals broken. The managers' host is the app's own store, built through `makeTestStore()`, whose
// namespace is Fernlet's: a manager is only ever built over a host, and that is the host whose
// identity seam the mismatch guards. Audit lines are captured the way `ProximityAuditBridgeTests`
// captures them, through `FernletAuditLog`'s capture registry, scoped to the cell's own calls by a
// task-local mark, so no line from a suite running beside this one is counted.

import CryptoKit
import FernletFoundation
import Foundation
import os
import Testing
@testable import FernletCrypto
@testable import FernletSocial
@testable import ProximityKit
@testable import Fernlet

// MARK: - The suite

/// ProximityKit's run-time refusal of an unsound namespace and its one-namespace-per-manager check, by
/// door: what each throws, what it audits, and that it does nothing else; and the pair-secret door,
/// which derives only under a feature salt its namespace declares.
@MainActor
@Suite(.serialized)
struct ProximityNamespaceGateTests {

    // MARK: The identity

    /// An identity of an unsound namespace refuses to provision: `ensureProvisioned()` throws every
    /// violation its namespace recorded and writes exactly one line, `identity.namespace.unsound` at
    /// `provision`, before any keychain row is read or written, and refuses the same way when asked
    /// again. It holds no key afterwards, and its keychain service holds no row.
    @Test func anIdentityOfAnUnsoundNamespaceRefusesToProvisionAndWritesNoRow() {
        let service = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: service) }
        let identity = IdentityService(namespace: GateFixtureApp.unsound(), keychainService: service)
        // R2: two attempts.
        for _ in 1...2 {
            Self.expectRefusal("identity.namespace.unsound", at: "provision") { try identity.ensureProvisioned() }
        }
        #expect(identity.localFingerprint.isEmpty, "the refused identity holds a signing key")
        #expect(identity.localKeyAgreementPublicKey.isEmpty, "the refused identity holds a key-agreement key")
        #expect(KeychainItem.loadAll(service: service).isEmpty, "the refused identity wrote a keychain row")
    }

    /// An identity of an unsound namespace refuses to wrap a group key. The wrap needs no provisioned
    /// key, so the provisioning refusal cannot cover it: `encryptGroupKey(_:for:)` throws every
    /// violation itself and writes `identity.namespace.unsound` at `groupKeyWrap`, and nothing else.
    @Test func anIdentityOfAnUnsoundNamespaceRefusesToWrapAGroupKey() {
        let service = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: service) }
        let identity = IdentityService(namespace: GateFixtureApp.unsound(), keychainService: service)
        let recipient = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        Self.expectRefusal("identity.namespace.unsound", at: "groupKeyWrap") {
            _ = try identity.encryptGroupKey(Data(repeating: 0x5A, count: 32), for: recipient)
        }
    }

    // MARK: The radios

    /// The mesh radio keeps its namespace's verdict and refuses to start under an unsound one: it
    /// throws every violation and writes `mesh.quic.namespaceUnsound` at `start`, and nothing else,
    /// before it mints a certificate or brings a listener up, so it never reads as running.
    @Test func theMeshRadioRefusesToStartUnderAnUnsoundNamespace() {
        let radio = NetworkMeshSession(namespace: GateFixtureApp.unsound())
        defer { radio.stop() }
        #expect(radio.namespaceSoundness == .unsound(GateFixtureApp.unsoundViolations),
                "the mesh radio keeps \(radio.namespaceSoundness), not its namespace's verdict")
        Self.expectRefusal("mesh.quic.namespaceUnsound", at: "start") {
            try radio.start(discoveryInfo: ["v": "1", "sid": "gate"])
        }
        #expect(!radio.isRunning, "the refused mesh radio reads as running")
    }

    /// The presence radio keeps its namespace's verdict and refuses to start under an unsound one:
    /// handed a posture, it throws every violation and writes `presence.quic.namespaceUnsound` at
    /// `start`, and nothing else, before it wears the posture or brings a listener up.
    @Test func thePresenceRadioRefusesToStartUnderAnUnsoundNamespace() throws {
        let unsound = GateFixtureApp.unsound()
        let radio = NetworkPresenceSession(namespace: unsound)
        defer { radio.stop() }
        #expect(radio.namespaceSoundness == .unsound(GateFixtureApp.unsoundViolations),
                "the presence radio keeps \(radio.namespaceSoundness), not its namespace's verdict")
        let posture = try PresenceEpochPosture.minted(
            at: Date(), instanceNamePrefix: unsound.family.radios.presenceInstanceNamePrefix,
            commonName: unsound.family.radios.tlsCommonName)
        Self.expectRefusal("presence.quic.namespaceUnsound", at: "start") {
            try radio.start(posture: posture, discoveryInfo: [:])
        }
        #expect(!radio.isRunning, "the refused presence radio reads as running")
    }

    /// The recipe-share radio keeps its namespace's verdict and refuses to start under an unsound one:
    /// its start, reached here with no listener or browser, throws every violation and writes
    /// `recipe.quic.namespaceUnsound` at `start`, and nothing else, before it mints a posture.
    @Test func theRecipeShareRadioRefusesToStartUnderAnUnsoundNamespace() {
        let radio = NetworkRecipeShareSession(namespace: GateFixtureApp.unsound())
        defer { radio.stop() }
        #expect(radio.namespaceSoundness == .unsound(GateFixtureApp.unsoundViolations),
                "the recipe-share radio keeps \(radio.namespaceSoundness), not its namespace's verdict")
        Self.expectRefusal("recipe.quic.namespaceUnsound", at: "start") { try radio.runWithoutRadiosForTesting() }
        #expect(!radio.isRunning, "the refused recipe-share radio reads as running")
        #expect(radio.advertisedSessionID.isEmpty, "the refused recipe-share radio minted a posture")
    }

    // MARK: The audit line

    /// The audit line names the refusal and never a value. Each of the twenty violation cases is
    /// written as its own case name, which carries nothing of the fields the case names; each door's
    /// `at` is its frozen token; a refusal's line holds the door, the count and the first case and
    /// nothing else, whatever the first case carries; and a sound verdict passes every door silently.
    @Test func theAuditLineNamesTheDoorTheCountAndTheFirstCaseNeverAValue() {
        let field = "family.vocabulary.capabilities.wire2"
        // R2: bounded by the twenty cases.
        for (violation, name) in Self.namedViolations(carrying: field) {
            let audited = ProximityNamespaceGate.caseName(of: violation)
            let spelled = String(String(describing: violation).prefix { $0 != "(" })
            #expect(audited == name && audited == spelled, "\(violation) is audited as \(audited)")
        }
        #expect(Set(Self.namedViolations(carrying: field).map(\.name)).count == 20, "a violation case is listed twice")
        let doors: [(site: ProximityNamespaceGate.Site, token: String)] = [
            (.provision, "provision"), (.groupKeyWrap, "groupKeyWrap"), (.start, "start"), (.construction, "construction")
        ]
        let violations: [ProximityNamespace.Violation] = [.unknownToken(field: field), .malformedCommonName]
        // R2: bounded by the four doors.
        for door in doors {
            #expect(door.site.rawValue == door.token, "the \(door.token) door is audited as \(door.site.rawValue)")
            let lines = GateAuditLines.delivered {
                #expect(throws: ProximityNamespaceError(violations: violations),
                        "the \(door.token) door let an unsound verdict by") {
                    try ProximityNamespaceGate.refuseUnsound(.unsound(violations), event: "gate.audit.probe", at: door.site)
                }
            }
            #expect(lines == [GateAuditLines.Line(event: "gate.audit.probe",
                                            context: ["at": door.token, "violations": "2", "first": "unknownToken"])],
                    "the \(door.token) door wrote \(lines)")
            let silent = GateAuditLines.delivered {
                #expect(throws: Never.self, "the \(door.token) door refused a sound verdict") {
                    try ProximityNamespaceGate.refuseUnsound(.sound, event: "gate.audit.probe", at: door.site)
                }
            }
            #expect(silent.isEmpty, "the \(door.token) door wrote \(silent) for a sound verdict")
        }
    }

    // MARK: One namespace per manager

    /// The mesh manager handed an identity of another namespace constructs, writes
    /// `mesh.identity.namespaceMismatch` once at `construction`, and refuses every start of its radio
    /// with it at `start`: its radio is never started and it never reads as searching. Handed an
    /// identity of its own namespace on the same kind of host, it writes no such line and starts.
    @Test func theMeshManagerRefusesToStartItsRadioUnderAnIdentityOfAnotherNamespace() throws {
        let event = "mesh.identity.namespaceMismatch"
        let services = [Self.isolatedIdentityService(), Self.isolatedIdentityService()]
        defer { services.forEach { KeychainItem.deleteAll(service: $0) } }

        let store = makeTestStore()
        let radio = FakeMeshTransportSession()
        var built: MeshNetworkManager?
        let construction = GateAuditLines.delivered {
            built = MeshNetworkManager(
                store: store, transport: radio,
                identity: IdentityService(namespace: GateFixtureApp.sound(), keychainService: services[0]))
        }
        let mismatched = try #require(built, "the mesh manager did not construct")
        let starts = GateAuditLines.delivered {
            mismatched.startJoin()
            mismatched.startJoin()
        }
        #expect(Self.contexts(of: event, in: construction) == [["at": "construction"]],
                "construction wrote \(construction)")
        #expect(Self.contexts(of: event, in: starts) == [["at": "start"], ["at": "start"]], "two starts wrote \(starts)")
        #expect(radio.startedDiscoveryInfo.isEmpty, "the mesh manager started its radio under two namespaces")
        #expect(!mismatched.isSearching, "the refused mesh manager reads as searching")
        mismatched.stopJoin()
        withExtendedLifetime(store) {}   // `MeshNetworkManager.store` is `unowned`

        let ownStore = makeTestStore()
        let ownRadio = FakeMeshTransportSession()
        var ownBuilt: MeshNetworkManager?
        let ownLines = GateAuditLines.delivered {
            ownBuilt = MeshNetworkManager(
                store: ownStore, transport: ownRadio,
                identity: IdentityService(namespace: ownStore.proximityNamespace, keychainService: services[1]))
            ownBuilt?.startJoin()
        }
        let matched = try #require(ownBuilt, "the mesh manager did not construct")
        #expect(ownLines.allSatisfy { $0.event != event }, "a mesh manager of its own namespace wrote \(event)")
        #expect(ownRadio.startedDiscoveryInfo.count == 1 && matched.isSearching,
                "a mesh manager of its own namespace did not start its radio")
        matched.stopJoin()
        withExtendedLifetime(ownStore) {}
    }

    /// The mesh manager handed an identity of another namespace refuses every founding of a mesh with
    /// `mesh.identity.namespaceMismatch` at `start`, first thing: each `startNewMesh(name:)` writes that
    /// one line and nothing else, and leaves no mesh and no ledger (so it signed no founder admission or
    /// key advertisement), no session context sealed into its host's storage and no radio started.
    /// Handed an identity of its own namespace on the same kind of host, the same call writes no such
    /// line, founds a mesh whose ledger holds its own admission, seals that mesh's context and starts
    /// its radio.
    @Test func theMeshManagerRefusesToFoundAMeshUnderAnIdentityOfAnotherNamespace() throws {
        let event = "mesh.identity.namespaceMismatch"
        let services = [Self.isolatedIdentityService(), Self.isolatedIdentityService()]
        defer { services.forEach { KeychainItem.deleteAll(service: $0) } }

        let store = makeTestStore()
        let radio = FakeMeshTransportSession()
        let mismatched = MeshNetworkManager(
            store: store, transport: radio,
            identity: IdentityService(namespace: GateFixtureApp.sound(), keychainService: services[0]))
        let foundings = DeviceBindingID.$testOverride.withValue(.identifier(Self.installBinding)) {
            GateAuditLines.delivered {
                mismatched.startNewMesh(name: "Gate Meadow")
                mismatched.startNewMesh(name: "Gate Meadow")
            }
        }
        let refusal = GateAuditLines.Line(event: event, context: ["at": "start"])
        #expect(foundings == [refusal, refusal], "two refused foundings wrote \(foundings)")
        #expect(mismatched.currentMesh == nil && mismatched.membershipVerifier == nil,
                "the refused mesh manager founded a mesh")
        var sealedNothing = false
        if case .absent = MeshSessionStore(scope: store.meshSessionStorage).load() { sealedNothing = true }
        #expect(sealedNothing, "the refused mesh manager sealed a session context into its host's storage")
        #expect(radio.startedDiscoveryInfo.isEmpty && !mismatched.isSearching,
                "the refused mesh manager started its radio")
        withExtendedLifetime(store) {}   // `MeshNetworkManager.store` is `unowned`

        let ownStore = makeTestStore()
        defer { MeshSessionStore.wipeForDeleteAll(scope: ownStore.meshSessionStorage) }
        let ownRadio = FakeMeshTransportSession()
        let matched = MeshNetworkManager(
            store: ownStore, transport: ownRadio,
            identity: IdentityService(namespace: ownStore.proximityNamespace, keychainService: services[1]))
        let ownLines = DeviceBindingID.$testOverride.withValue(.identifier(Self.installBinding)) {
            GateAuditLines.delivered { matched.startNewMesh(name: "Own Meadow") }
        }
        #expect(ownLines.allSatisfy { $0.event != event }, "a mesh manager of its own namespace wrote \(event)")
        let founded = try #require(matched.currentMesh, "a mesh manager of its own namespace founded no mesh")
        #expect(matched.membershipVerifier?.roster.memberCount == 1, "its ledger does not hold its own admission")
        #expect(Self.sealedMeshID(in: ownStore) == founded.meshID, "it sealed no context for the mesh it founded")
        #expect(ownRadio.startedDiscoveryInfo.count == 1 && matched.isSearching,
                "a mesh manager of its own namespace did not start its radio")
        matched.leaveMesh()
        withExtendedLifetime(ownStore) {}
    }

    /// The presence manager handed an identity of another namespace constructs, writes
    /// `presence.identity.namespaceMismatch` once at `construction`, and refuses every start of its
    /// radio with it at `start`: it mints no posture, starts no radio and never reads as listening.
    /// Handed an identity of its own namespace, it writes no such line and starts.
    @Test func thePresenceManagerRefusesToStartItsRadioUnderAnIdentityOfAnotherNamespace() throws {
        let event = "presence.identity.namespaceMismatch"
        let services = [Self.isolatedIdentityService(), Self.isolatedIdentityService()]
        defer { services.forEach { KeychainItem.deleteAll(service: $0) } }

        let store = makeTestStore()
        let radio = FakePresenceRadioSession()
        var built: PresenceManager?
        let construction = GateAuditLines.delivered {
            built = PresenceManager(
                store: store, ledger: ProximityHeartLedger(fileURL: Self.scratchLedgerURL()),
                identity: IdentityService(namespace: GateFixtureApp.sound(), keychainService: services[0]))
        }
        let mismatched = try #require(built, "the presence manager did not construct")
        mismatched.makeSession = { radio }
        let starts = GateAuditLines.delivered {
            mismatched.start()
            mismatched.start()
        }
        #expect(Self.contexts(of: event, in: construction) == [["at": "construction"]],
                "construction wrote \(construction)")
        #expect(Self.contexts(of: event, in: starts) == [["at": "start"], ["at": "start"]], "two starts wrote \(starts)")
        #expect(radio.advertised.isEmpty, "the presence manager started its radio under two namespaces")
        #expect(mismatched.presencePosture == nil, "the refused presence manager minted a posture")
        #expect(!mismatched.isListening, "the refused presence manager reads as listening")
        withExtendedLifetime(store) {}   // `PresenceManager.store` is `unowned`

        let ownStore = makeTestStore()
        let ownRadio = FakePresenceRadioSession()
        let ownIdentity = IdentityService(namespace: ownStore.proximityNamespace, keychainService: services[1])
        try ownIdentity.ensureProvisioned()
        var ownBuilt: PresenceManager?
        let ownLines = GateAuditLines.delivered {
            ownBuilt = PresenceManager(
                store: ownStore, ledger: ProximityHeartLedger(fileURL: Self.scratchLedgerURL()), identity: ownIdentity)
            ownBuilt?.makeSession = { ownRadio }
            ownBuilt?.start()
        }
        let matched = try #require(ownBuilt, "the presence manager did not construct")
        #expect(ownLines.allSatisfy { $0.event != event }, "a presence manager of its own namespace wrote \(event)")
        #expect(ownRadio.advertised.count == 1 && matched.isListening,
                "a presence manager of its own namespace did not start its radio")
        matched.stop()
        withExtendedLifetime(ownStore) {}
    }

    /// The recipe-share manager handed an identity of another namespace constructs, writes
    /// `recipeShare.identity.namespaceMismatch` once at `construction`, and refuses every start of its
    /// radio with it at `start`: its radio is never started and it never reads as listening. Handed an
    /// identity of its own namespace, it writes no such line and starts.
    @Test func theRecipeShareManagerRefusesToStartItsRadioUnderAnIdentityOfAnotherNamespace() throws {
        let event = "recipeShare.identity.namespaceMismatch"
        let services = [Self.isolatedIdentityService(), Self.isolatedIdentityService()]
        defer { services.forEach { KeychainItem.deleteAll(service: $0) } }

        let store = makeTestStore()
        let radio = FakeRecipeShareRadioSession()
        var built: ProximityRecipeShareManager?
        let construction = GateAuditLines.delivered {
            built = ProximityRecipeShareManager(
                store: store, makeSession: { radio },
                identity: IdentityService(namespace: GateFixtureApp.sound(), keychainService: services[0]))
        }
        let mismatched = try #require(built, "the recipe-share manager did not construct")
        let starts = GateAuditLines.delivered {
            mismatched.start()
            mismatched.start()
        }
        #expect(Self.contexts(of: event, in: construction) == [["at": "construction"]],
                "construction wrote \(construction)")
        #expect(Self.contexts(of: event, in: starts) == [["at": "start"], ["at": "start"]], "two starts wrote \(starts)")
        #expect(!radio.isStarted && radio.advertised.isEmpty,
                "the recipe-share manager started its radio under two namespaces")
        #expect(!mismatched.isListening, "the refused recipe-share manager reads as listening")
        withExtendedLifetime(store) {}   // `ProximityRecipeShareManager.store` is `unowned`

        let ownStore = makeTestStore()
        let ownRadio = FakeRecipeShareRadioSession()
        var ownBuilt: ProximityRecipeShareManager?
        let ownLines = GateAuditLines.delivered {
            ownBuilt = ProximityRecipeShareManager(
                store: ownStore, makeSession: { ownRadio },
                identity: IdentityService(namespace: ownStore.proximityNamespace, keychainService: services[1]))
            ownBuilt?.start()
        }
        let matched = try #require(ownBuilt, "the recipe-share manager did not construct")
        #expect(ownLines.allSatisfy { $0.event != event }, "a recipe-share manager of its own namespace wrote \(event)")
        #expect(ownRadio.isStarted && matched.isListening,
                "a recipe-share manager of its own namespace did not start its radio")
        matched.stop()
        withExtendedLifetime(ownStore) {}
    }

    // MARK: The pair-secret door

    /// An identity of a namespace whose declared feature salt repeats a protocol label refuses to
    /// provision as under any unsound namespace: `ensureProvisioned()` throws the one violation, a
    /// duplicate label naming both fields, and writes `identity.namespace.unsound` at `provision`
    /// with that first case, before any keychain row is read or written. So the declared salt derives
    /// nothing: the pair-secret door throws `notProvisioned` under it and writes nothing.
    @Test func aFeatureSaltThatRepeatsAProtocolLabelLeavesItsIdentityUnprovisioned() {
        let service = Self.isolatedIdentityService()
        defer { KeychainItem.deleteAll(service: service) }
        let repeated = ProximityCryptographicPurpose.featureKeyDerivationSalt("gate.proximity.v1")
        let namespace = GateFixtureApp.declaring(ProximityNamespace.FeaturePurposes(["pairV1": repeated]))
        let violations: [ProximityNamespace.Violation] = [
            .duplicateLabel(field: "family.purposes.keyDerivation.proximityTransportV1",
                            otherField: "family.purposes.feature.pairV1")
        ]
        #expect(namespace.soundness == .unsound(violations), "the namespace records \(namespace.soundness)")
        let identity = IdentityService(namespace: namespace, keychainService: service)
        var thrown: ProximityNamespaceError?
        let lines = GateAuditLines.delivered {
            thrown = #expect(throws: ProximityNamespaceError.self, "the identity provisioned") {
                try identity.ensureProvisioned()
            }
        }
        #expect(thrown?.violations == violations, "threw \(String(describing: thrown?.violations))")
        let line = GateAuditLines.Line(
            event: "identity.namespace.unsound",
            context: ["at": "provision", "violations": "1", "first": "duplicateLabel"])
        #expect(lines == [line], "provisioning wrote \(lines)")
        #expect(identity.localKeyAgreementPublicKey.isEmpty, "the refused identity holds a key-agreement key")
        #expect(KeychainItem.loadAll(service: service).isEmpty, "the refused identity wrote a keychain row")
        let peer = Curve25519.KeyAgreement.PrivateKey().publicKey
        let derived = GateAuditLines.delivered {
            #expect(throws: IdentityError.notProvisioned, "a salt of an unsound family derived a pair secret") {
                _ = try identity.pairSecret(with: peer, purpose: repeated)
            }
        }
        #expect(derived.isEmpty, "the pair-secret door wrote \(derived)")
    }

    /// The door derives under a feature salt its identity's namespace declares and under nothing
    /// else, refusing with `undeclaredPurpose` before it reads a key: a salt minted and never
    /// declared, the namespace's own protocol salt (a key-derivation salt it declares outside its
    /// feature group), a label it declares in another role (its envelope's signature label), and the
    /// declared salt's bytes in another role. The declaration is checked first, so an identity not yet
    /// provisioned refuses each of those the same way, and only a declared salt meets `notProvisioned`
    /// there. Every refusal writes no audit line and no keychain row.
    @Test func thePairSecretDoorRefusesAPurposeItsNamespaceDoesNotDeclare() throws {
        let services = [Self.isolatedIdentityService(), Self.isolatedIdentityService()]
        defer { services.forEach { KeychainItem.deleteAll(service: $0) } }
        let namespace = GateFixtureApp.declaring(GateFixtureApp.features)
        #expect(namespace.soundness == .sound, "the declaring fixture is unsound: \(namespace.soundness)")
        let provisioned = IdentityService(namespace: namespace, keychainService: services[0])
        try provisioned.ensureProvisioned()
        let unprovisioned = IdentityService(namespace: namespace, keychainService: services[1])
        let peer = Curve25519.KeyAgreement.PrivateKey().publicKey
        let purposes = namespace.family.purposes
        let undeclared: [(name: String, purpose: ProximityCryptographicPurpose)] = [
            ("a salt it never declares", .featureKeyDerivationSalt("example.feature.undeclared.v1")),
            ("its protocol transport salt", purposes.keyDerivation.proximityTransportV1),
            ("its envelope's signature label", purposes.signature.identityEnvelopeV2),
            ("the declared salt's bytes as an AAD", ProximityCryptographicPurpose("gate.feature.pair.v1",
                                                                                 role: .aeadAssociatedData))
        ]
        let lines = GateAuditLines.delivered {
            // R2: bounded by the four purposes and the two identities.
            for (name, purpose) in undeclared {
                for identity in [provisioned, unprovisioned] {
                    #expect(throws: IdentityError.undeclaredPurpose, "\(name) reached the key agreement") {
                        _ = try identity.pairSecret(with: peer, purpose: purpose)
                    }
                }
            }
            #expect(throws: IdentityError.notProvisioned, "an unprovisioned identity derived a pair secret") {
                _ = try unprovisioned.pairSecret(with: peer, purpose: GateFixtureApp.pairSalt)
            }
        }
        #expect(lines.isEmpty, "the pair-secret door wrote \(lines)")
        #expect(KeychainItem.loadAll(service: services[1]).isEmpty, "the door wrote a keychain row")
    }

    /// The door derives under a declared salt: X25519 between the two keys, then HKDF-SHA256 with the
    /// salt's bytes, empty info and 32 bytes, so a derivation written here from a peer's side, with the
    /// salt's literal, gives the same key, and two identities of the namespace derive one key from
    /// either side. A second declared salt derives a second key. Nothing is audited.
    @Test func thePairSecretDoorDerivesUnderADeclaredSaltFromEitherSide() throws {
        let services = [Self.isolatedIdentityService(), Self.isolatedIdentityService()]
        defer { services.forEach { KeychainItem.deleteAll(service: $0) } }
        let tagSalt = ProximityCryptographicPurpose.featureKeyDerivationSalt("gate.feature.tag.v1")
        let namespace = GateFixtureApp.declaring(ProximityNamespace.FeaturePurposes([
            "pairV1": GateFixtureApp.pairSalt, "tagV1": tagSalt
        ]))
        #expect(namespace.soundness == .sound, "the declaring fixture is unsound: \(namespace.soundness)")
        let alice = IdentityService(namespace: namespace, keychainService: services[0])
        let bob = IdentityService(namespace: namespace, keychainService: services[1])
        try alice.ensureProvisioned()
        try bob.ensureProvisioned()
        let alicePublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: alice.localKeyAgreementPublicKey)
        let bobPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bob.localKeyAgreementPublicKey)
        let peer = Curve25519.KeyAgreement.PrivateKey()
        var derived: [Data] = []
        let lines = try GateAuditLines.delivered {
            derived = [
                Self.bytes(of: try alice.pairSecret(with: peer.publicKey, purpose: GateFixtureApp.pairSalt)),
                Self.bytes(of: try alice.pairSecret(with: bobPublic, purpose: GateFixtureApp.pairSalt)),
                Self.bytes(of: try bob.pairSecret(with: alicePublic, purpose: GateFixtureApp.pairSalt)),
                Self.bytes(of: try alice.pairSecret(with: bobPublic, purpose: tagSalt))
            ]
        }
        let byHand = Self.bytes(of: try peer.sharedSecretFromKeyAgreement(with: alicePublic).hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data("gate.feature.pair.v1".utf8), sharedInfo: Data(), outputByteCount: 32))
        try #require(derived.count == 4)
        #expect(derived[0] == byHand && byHand.count == 32, "the door's key is not the declared salt's HKDF")
        #expect(derived[1] == derived[2], "the two members of a pair derive different keys")
        #expect(derived[3] != derived[1] && derived[3].count == 32, "a second declared salt derives the same key")
        #expect(lines.isEmpty, "the pair-secret door wrote \(lines)")
    }

    // MARK: A sound namespace passes

    /// An identity of a sound namespace passes both of its doors: it provisions, and the group key it
    /// wraps opens for another identity of the namespace, with no refusal line written.
    @Test func aSoundNamespacePassesTheIdentitysDoors() throws {
        let sound = GateFixtureApp.sound()
        #expect(sound.soundness == .sound, "the sound fixture is unsound: \(sound.soundness)")
        let services = [Self.isolatedIdentityService(), Self.isolatedIdentityService()]
        defer { services.forEach { KeychainItem.deleteAll(service: $0) } }
        let identity = IdentityService(namespace: sound, keychainService: services[0])
        let peer = IdentityService(namespace: sound, keychainService: services[1])
        let groupKey = Data((0..<32).map { UInt8($0) })
        var bundle = Data()
        let lines = try GateAuditLines.delivered {
            try identity.ensureProvisioned()
            try peer.ensureProvisioned()
            bundle = try identity.encryptGroupKey(groupKey, for: peer.localKeyAgreementPublicKey)
        }
        #expect(!identity.localFingerprint.isEmpty, "the identity of a sound namespace did not provision")
        #expect(try peer.decryptGroupKey(bundle) == groupKey, "the group key wrapped under a sound namespace does not open")
        #expect(lines.allSatisfy { $0.event != "identity.namespace.unsound" },
                "a sound namespace's identity wrote \(lines)")
    }

    /// The radios of a sound namespace pass their doors. The recipe-share radio comes up (with no
    /// listener or browser) and writes no refusal. The mesh and presence radios cannot be brought up
    /// at tier 1, so each is held to the verdict its start reads, which is sound, and the door that
    /// start runs passes that verdict without a line; the refusal cells above prove the starts run it.
    @Test func aSoundNamespacePassesTheRadiosDoors() throws {
        let sound = GateFixtureApp.sound()
        let recipe = NetworkRecipeShareSession(namespace: sound)
        defer { recipe.stop() }
        var posture: RecipeSharePosture?
        let recipeLines = try GateAuditLines.delivered { posture = try recipe.runWithoutRadiosForTesting() }
        #expect(posture != nil && recipe.isRunning, "the recipe-share radio of a sound namespace did not start")
        #expect(recipeLines.allSatisfy { !$0.event.hasSuffix(".namespaceUnsound") }, "it wrote \(recipeLines)")

        let mesh = NetworkMeshSession(namespace: sound)
        let presence = NetworkPresenceSession(namespace: sound)
        #expect(mesh.namespaceSoundness == .sound && presence.namespaceSoundness == .sound,
                "the radios of a sound namespace keep \(mesh.namespaceSoundness) and \(presence.namespaceSoundness)")
        let doorLines = GateAuditLines.delivered {
            #expect(throws: Never.self, "the mesh radio's door refused a sound namespace") {
                try ProximityNamespaceGate.refuseUnsound(
                    mesh.namespaceSoundness, event: "mesh.quic.namespaceUnsound", at: .start)
            }
            #expect(throws: Never.self, "the presence radio's door refused a sound namespace") {
                try ProximityNamespaceGate.refuseUnsound(
                    presence.namespaceSoundness, event: "presence.quic.namespaceUnsound", at: .start)
            }
        }
        #expect(doorLines.isEmpty, "the radios' doors wrote \(doorLines) for a sound namespace")
    }

    // MARK: Helpers

    /// Expects `call`, made under ``GateFixtureApp/unsound()``, to be refused at `door`: it throws the
    /// namespace's two violations, exactly as its soundness records them, and writes one line, `event`,
    /// whose context names the door, the count and the first violation's case (a malformed label) and
    /// nothing else.
    private static func expectRefusal(
        _ event: String, at door: String, sourceLocation: SourceLocation = #_sourceLocation,
        of call: () throws -> Void
    ) {
        var thrown: ProximityNamespaceError?
        let lines = GateAuditLines.delivered {
            thrown = #expect(
                throws: ProximityNamespaceError.self, "\(event): not refused", sourceLocation: sourceLocation
            ) {
                try call()
            }
        }
        #expect(thrown?.violations == GateFixtureApp.unsoundViolations,
                "\(event): threw \(String(describing: thrown?.violations))", sourceLocation: sourceLocation)
        let line = GateAuditLines.Line(event: event, context: ["at": door, "violations": "2", "first": "malformedLabel"])
        #expect(lines == [line], "\(event): wrote \(lines)", sourceLocation: sourceLocation)
    }

    /// The contexts of the `event` lines among `lines`, in the order they were written.
    private static func contexts(of event: String, in lines: [GateAuditLines.Line]) -> [[String: String]] {
        lines.filter { $0.event == event }.map(\.context)
    }

    /// A symmetric key's bytes, to compare two keys.
    private static func bytes(of key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    /// Every violation case, each carrying `field` wherever it names one, beside the name its audit
    /// line spells.
    static func namedViolations(carrying field: String) -> [(violation: ProximityNamespace.Violation, name: String)] {
        [
            (.malformedLabel(field: field), "malformedLabel"),
            (.duplicateLabel(field: field, otherField: field), "duplicateLabel"),
            (.labelIsPrefix(shorter: field, longer: field), "labelIsPrefix"),
            (.malformedServiceType(field: field), "malformedServiceType"),
            (.malformedALPN(field: field), "malformedALPN"),
            (.duplicateRadioValue(field: field, otherField: field), "duplicateRadioValue"),
            (.malformedHeartbeat, "malformedHeartbeat"),
            (.malformedURLScheme, "malformedURLScheme"),
            (.malformedKeychainName(field: field), "malformedKeychainName"),
            (.duplicateKeychainName(field: field, otherField: field), "duplicateKeychainName"),
            (.malformedPathComponent(field: field), "malformedPathComponent"),
            (.duplicateFileName(field: field, otherField: field), "duplicateFileName"),
            (.emptyLogSubsystem, "emptyLogSubsystem"),
            (.malformedToken(field: field), "malformedToken"),
            (.duplicateToken(field: field, otherField: field), "duplicateToken"),
            (.unknownToken(field: field), "unknownToken"),
            (.malformedSummaryTitle(field: field), "malformedSummaryTitle"),
            (.malformedInstanceNamePrefix(field: field), "malformedInstanceNamePrefix"),
            (.malformedCommonName, "malformedCommonName"),
            (.malformedPeerNames(field: field), "malformedPeerNames")
        ]
    }

    /// A keychain service no other test uses, in the `.test.` family the wipe wall's discovery skips.
    static func isolatedIdentityService() -> String {
        "com.fernlet.identity.test.namespacegate.\(UUID().uuidString)"
    }

    /// The install binding the founding cell seals and opens session contexts under, pinned so no cell
    /// here reads or mints the device's own binding row.
    static let installBinding = Data(repeating: 0x6A, count: 16)

    /// The mesh id of the session context sealed into `store`'s storage, opened under
    /// ``installBinding``; nil when no context opens there.
    static func sealedMeshID(in store: FernletStore) -> UUID? {
        let load = DeviceBindingID.$testOverride.withValue(.identifier(installBinding)) {
            MeshSessionStore(scope: store.meshSessionStorage).load()
        }
        guard case .loaded(let context, _) = load else { return nil }
        return context.meshID
    }

    /// A heart-ledger file in a scratch directory of its own.
    static func scratchLedgerURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NamespaceGate-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("HeartLedger.json")
    }
}

// MARK: - The audit lines one call writes

/// The audit lines one synchronous call writes, captured as `ProximityAuditBridgeTests` captures them:
/// the handler records only while a task-local mark bound around that call is visible, so no line from
/// a suite running beside this one is counted, and the capture is read the moment the call returns.
private enum GateAuditLines {

    /// One line as a capture handler saw it.
    struct Line: Equatable, Sendable {
        /// The event name.
        let event: String
        /// The context.
        let context: [String: String]
    }

    /// The mark, bound only around the call being captured.
    @TaskLocal static var emitter: UUID?

    /// Every line written while `emit` ran under this call's own mark, in order.
    ///
    /// - Parameter emit: The synchronous call.
    /// - Returns: The lines it wrote.
    static func delivered(during emit: () throws -> Void) rethrows -> [Line] {
        let mark = UUID()
        let seen = OSAllocatedUnfairLock<[Line]>(initialState: [])
        let token = FernletAuditLog.addCaptureHandler { event, context in
            guard Self.emitter == mark else { return }
            seen.withLock { $0.append(Line(event: event, context: context)) }
        }
        defer { FernletAuditLog.removeCaptureHandler(token) }
        try Self.$emitter.withValue(mark) { try emit() }
        return seen.withLock { $0 }
    }
}

// MARK: - The gate app

/// An app that does not exist, "gate", its namespace built entirely from literals that belong to no
/// shipping app, the way `ProximityNamespaceSoundnessTests` builds its fixtures. It has no legacy peers,
/// so its legacy pair is `.refused`, and it shares no label, radio value, token or name with Fernlet.
/// As written it declares no feature salt; the pair-secret cells declare theirs.
private enum GateFixtureApp {

    /// The namespace as written: every rule passes.
    static func sound() -> ProximityNamespace {
        ProximityNamespace(family: family(identityEnvelopeV2: "gate.canonical.identity-envelope.v2"),
                           installation: installation(logSubsystem: "org.example.gate"))
    }

    /// The namespace as written, declaring `feature`: sound unless a declared salt repeats or prefixes
    /// a label.
    static func declaring(_ feature: ProximityNamespace.FeaturePurposes) -> ProximityNamespace {
        ProximityNamespace(family: family(identityEnvelopeV2: "gate.canonical.identity-envelope.v2", feature: feature),
                           installation: installation(logSubsystem: "org.example.gate"))
    }

    /// The salt the gate app's one feature derives its pair secrets under.
    static let pairSalt = ProximityCryptographicPurpose.featureKeyDerivationSalt("gate.feature.pair.v1")

    /// The gate app's feature group: its one pair salt.
    static let features = ProximityNamespace.FeaturePurposes(["pairV1": pairSalt])

    /// The namespace with two literals broken: its envelope label holds spaces, and its log subsystem
    /// is empty.
    static func unsound() -> ProximityNamespace {
        ProximityNamespace(family: family(identityEnvelopeV2: "gate canonical identity envelope v2"),
                           installation: installation(logSubsystem: ""))
    }

    /// What ``unsound()`` records, in rule order: the malformed label, named by its field path, then
    /// the empty log subsystem.
    static let unsoundViolations: [ProximityNamespace.Violation] = [
        .malformedLabel(field: "family.purposes.signature.identityEnvelopeV2"),
        .emptyLogSubsystem
    ]

    /// The family, its identity envelope label and its feature salts given.
    static func family(
        identityEnvelopeV2: StaticString, feature: ProximityNamespace.FeaturePurposes = .none
    ) -> ProximityNamespace.Family {
        ProximityNamespace.Family(
            purposes: ProximityNamespace.Purposes(
                signature: signature(identityEnvelopeV2: identityEnvelopeV2), keyDerivation: keyDerivation(),
                aead: aead(), hash: hash(), feature: feature),
            radios: ProximityNamespace.Radios(
                mesh: ProximityNamespace.Radio(serviceType: "_gate-mesh._udp", alpn: "gate-mesh-v1"),
                presence: ProximityNamespace.Radio(serviceType: "_gate-near._udp", alpn: "gate-near-v1"),
                recipeShare: ProximityNamespace.Radio(serviceType: "_gate-recipe._udp", alpn: "gate-recipe-v1"),
                meshHeartbeat: Data("gate-heartbeat".utf8),
                meshInstanceNamePrefix: "gate-link-", presenceInstanceNamePrefix: "gt-", tlsCommonName: "gate-link"),
            verifyQR: ProximityNamespace.VerifyQR(urlScheme: "gate"),
            vocabulary: vocabulary())
    }

    /// Nineteen signature labels, the envelope's given, and no legacy pair.
    static func signature(identityEnvelopeV2: StaticString) -> ProximityNamespace.Signature {
        ProximityNamespace.Signature(
            identityEnvelopeV2: identityEnvelopeV2,
            meshAdmissionTokenV2: "gate.canonical.mesh-admission-token.v2",
            meshChannelIntroductionV1: "gate.mesh.channel-introduction.v1",
            meshMemberDepartureV1: "gate.mesh.member-departure.v1",
            meshMemberRemovalV1: "gate.mesh.member-removal.v1",
            meshTerminatedV1: "gate.mesh.terminated.v1",
            meshInventoryDigestV1: "gate.mesh.inventory-digest.v1",
            meshEpochHeadsV1: "gate.mesh.epoch-heads.v1",
            meshRemovalProposalV1: "gate.mesh.removal-proposal.v1",
            meshRemovalVoteV1: "gate.mesh.removal-vote.v1",
            meshKeyAgreementV1: "gate.mesh.key-agreement.v1",
            meshRoutedManifestV1: "gate.mesh.routed-manifest.v1",
            meshRoutedChunkV1: "gate.mesh.routed-chunk.v1",
            meshCustodyReceiptV1: "gate.mesh.custody-receipt.v1",
            meshRecipientReceiptV1: "gate.mesh.recipient-receipt.v1",
            meshRoutedInventoryDigestV1: "gate.mesh.routed-inventory-digest.v1",
            meshRoutedDrainAnswerV1: "gate.mesh.routed-drain-answer.v1",
            proximityQRIdentityV1: "gate.verify.qr.v1",
            proximityQRResponseV1: "gate.verify.response.v1",
            legacyV1: .refused
        )
    }

    /// The six key-derivation labels.
    static func keyDerivation() -> ProximityNamespace.KeyDerivation {
        ProximityNamespace.KeyDerivation(
            proximityTransportV1: "gate.proximity.v1",
            meshGroupKeyWrapV1: "gate.mesh.groupkey.v1",
            meshTLSExporterV1: "gate.mesh.tls-exporter.v1",
            meshRoutedContentKeyWrapV1: "gate.mesh.routed.content-key.v1",
            meshSessionContextV1: "gate.mesh.session-context.v1",
            meshRoutedStoreV1: "gate.mesh.routed-store.v1"
        )
    }

    /// The five AEAD labels.
    static func aead() -> ProximityNamespace.AEAD {
        ProximityNamespace.AEAD(
            proximityTransportV2: "gate.proximity.transport.aead.v2",
            meshGroupKeyWrapV2: "gate.mesh.groupkey.wrap.aead.v2",
            meshEncryptedMetadataV2: "gate.mesh.encrypted-metadata.aead.v2",
            meshRoutedContentKeyWrapV1: "gate.mesh.routed.content-key.wrap.aead.v1",
            meshRoutedItemV1: "gate.mesh.routed.item.aead.v1"
        )
    }

    /// The seven hash labels.
    static func hash() -> ProximityNamespace.Hash {
        ProximityNamespace.Hash(
            meshInventoryDigestV1: "gate.mesh.inventory-digest.hash.v1",
            meshRoutedContentV1: "gate.mesh.routed-content.hash.v1",
            meshRoutedChunkV1: "gate.mesh.routed-chunk.hash.v1",
            meshRoutedChunkIDV1: "gate.mesh.routed-chunk-id.hash.v1",
            meshCustodyReceiptIDV1: "gate.mesh.custody-receipt-id.hash.v1",
            meshRecipientReceiptIDV1: "gate.mesh.recipient-receipt-id.hash.v1",
            meshEpochIDV1: "gate.mesh.epoch.v1"
        )
    }

    /// Its payload vocabulary: its own session messages and titles, four payload tokens of which one
    /// must arrive sealed and its thirty mesh messages, two capabilities with no legacy peers to assume
    /// anything for, and its own record kinds and routed types.
    static func vocabulary() -> ProximityNamespace.Vocabulary {
        let meshToken = { (name: String) in "gate.mesh.\(name).v1" }
        return ProximityNamespace.Vocabulary(
            session: ProximityNamespace.SessionMessages(
                identityIntroduction: ProximityNamespace.SessionMessage(
                    payloadType: "gate.session.hello.v1", summaryTitle: "Gate hello"),
                identityAcknowledge: ProximityNamespace.SessionMessage(
                    payloadType: "gate.session.welcome.v1", summaryTitle: "Gate welcome"),
                heartbeat: ProximityNamespace.Heartbeat(
                    payloadType: "gate.session.beat.v1", pingTitle: "Gate beat", replyTitle: "Gate beat back")),
            payloads: ProximityNamespace.PayloadRules(
                known: Set(["gate.session.hello.v1", "gate.session.welcome.v1", "gate.session.beat.v1", "gate.note.v1"]
                           + ProximityNamespace.MeshMessages.tokens(meshToken)),
                sealingRequired: ["gate.note.v1"]),
            capabilities: ProximityNamespace.Capabilities(
                known: ["gate-notes", "gate-framing"], wire2: "gate-framing", assumedForLegacyPeers: []),
            membershipRecordKinds: ProximityNamespace.MembershipRecordKinds(
                admission: "gate.member.joined.v1", departure: "gate.member.left.v1",
                removal: "gate.member.removed.v1", termination: "gate.group.ended.v1"),
            routedTypes: ProximityNamespace.RoutedTypes(
                photo: "gate.routed.picture.v1", tempMessage: "gate.routed.note.v1",
                heart: "gate.routed.wave.v1", control: "gate.routed.control.v1"),
            mesh: .spelled(meshToken)
        )
    }

    /// The installation, its log subsystem given.
    static func installation(logSubsystem: String) -> ProximityNamespace.Installation {
        ProximityNamespace.Installation(
            keychain: ProximityNamespace.Keychain(
                identity: ProximityNamespace.Keychain.IdentityRows(
                    service: "org.example.gate.identity", signingPrivateKey: "signing.private",
                    keyAgreementPrivateKey: "agreement.private", signingPublicKeyCache: "signing.public",
                    keyAgreementPublicKeyCache: "agreement.public"),
                meshSessionSealKey: ProximityNamespace.Keychain.Row(
                    service: "org.example.gate.mesh-session", account: "session.seal"),
                meshRoutedSealKey: ProximityNamespace.Keychain.Row(
                    service: "org.example.gate.mesh-routed", account: "routed.seal")),
            storage: ProximityNamespace.Storage(
                directoryName: "Gate", meshSessionContextFileName: "Session.sealed",
                meshRoutedIndexFileName: "Routed.sealed", meshRoutedChunkDirectoryName: "RoutedChunks"),
            logSubsystem: logSubsystem,
            peerNames: ProximityNamespace.PeerNames(maxLength: 24, floor: "A gate peer"))
    }
}
