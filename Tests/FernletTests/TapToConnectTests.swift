// TapToConnectTests.swift
// FernletTests
//
// World Friends (2026-10-31): meeting someone new by tapping phones on Home. The run policy's new row
// (the tap rendezvous listens only with Home in front of a foreground app, the switch on, no Low Power
// Mode, no decoy and no hangout), the hand-off's discovery exception on Home, the seams' new verb, and
// the controller's mesh doors (kept friends and tap matches, nobody else). The rendezvous's own privacy
// cells (nothing identifying before both say yes; rotation) live in ProximityKit's TapRendezvousTests.

import Foundation
import SwiftUI
import Testing
import FernletConnections
import FernletDomainModel
import LocalPersistence
import ProximityKit
@testable import Fernlet

/// Inputs over the tap row's facts, everything else at a neutral value.
private func tapInput(
    phase: ScenePhase = .active, tab: FernletTab = .home, session: ProximitySessionPresence = .absent,
    allow: Bool = true, lowPower: Bool = false, homeFront: Bool = true, pending: Bool = false, duress: Bool = false
) -> ProximityRunPolicy.Input {
    ProximityRunPolicy.Input(
        scenePhase: phase, selectedTab: tab, duressSessionActive: duress, protectedDataAvailable: true,
        belowMinimumAge: false, deleteAllInProgress: false, continuation: .notRequested, session: session,
        allowNearbyPresence: false, allowNearbyRecipeShares: false, sessionPhotoReviewBlocksDiscovery: false,
        allowConnectByTapping: allow, lowPowerMode: lowPower, homeIsFrontmost: homeFront, tapHangoutPending: pending
    )
}

/// The tap rendezvous's run-policy row and the hand-off's discovery exception, over their whole product.
struct TapToConnectRunPolicyTests {

    @Test func theRendezvousRunsOnlyWithHomeInFrontAndTheSwitchOn() {
        var rows = 0
        var wrong: [String] = []
        let phases: [ScenePhase] = [.active, .inactive, .background]
        let sessions: [ProximitySessionPresence] = [.absent, .meshHeld, .peerCommitted]
        // R2: bounded by 3 × 5 × 3 × 2⁵ rows.
        for phase in phases {
            for tab in FernletTab.allCases {
                for session in sessions {
                    for bits in 0..<32 {
                        let allow = bits & 1 != 0, lowPower = bits & 2 != 0, homeFront = bits & 4 != 0
                        let pending = bits & 8 != 0, duress = bits & 16 != 0
                        let input = tapInput(phase: phase, tab: tab, session: session, allow: allow,
                                             lowPower: lowPower, homeFront: homeFront, pending: pending, duress: duress)
                        let runs = phase != .background && tab == .home && session == .absent && allow
                            && !lowPower && homeFront && !pending && !duress
                        let state = ProximityRunPolicy.verdict(for: input).tapRendezvous
                        rows += 1
                        if state != (runs ? .foregroundOnly : .stop) { wrong.append("\(phase) \(tab) \(session) \(bits)") }
                    }
                }
            }
        }
        #expect(rows == 3 * FernletTab.allCases.count * 3 * 32)
        #expect(wrong.isEmpty, "the tap rendezvous ran, or failed to run, on these rows")
    }

    @Test func neverInTheBackgroundADecoyOrLowPowerMode() {
        let background = ProximityRunPolicy.verdict(for: tapInput(phase: .background)).tapRendezvous
        let decoy = ProximityRunPolicy.verdict(for: tapInput(duress: true)).tapRendezvous
        let lowPower = ProximityRunPolicy.verdict(for: tapInput(lowPower: true)).tapRendezvous
        let switchOff = ProximityRunPolicy.verdict(for: tapInput(allow: false)).tapRendezvous
        let covered = ProximityRunPolicy.verdict(for: tapInput(homeFront: false)).tapRendezvous
        #expect([background, decoy, lowPower, switchOff, covered] == [.stop, .stop, .stop, .stop, .stop])
        #expect(ProximityRunPolicy.verdict(for: tapInput()).tapRendezvous == .foregroundOnly)
    }

    @Test func aTapHandOffSearchesOnHomeOnlyUntilAPeerCommits() {
        let pending = ProximityRunPolicy.verdict(for: tapInput(pending: true))
        let committed = ProximityRunPolicy.verdict(for: tapInput(session: .peerCommitted, pending: true))
        let background = ProximityRunPolicy.verdict(for: tapInput(phase: .background, pending: true))
        let none = ProximityRunPolicy.verdict(for: tapInput())
        let food = ProximityRunPolicy.verdict(for: tapInput(tab: .food, pending: true))
        #expect(pending.discovery == .foregroundOnly && pending.tapRendezvous == .stop)
        #expect(committed.discovery == .hold)
        #expect(!background.discovery.isRunning && !food.discovery.isRunning && !none.discovery.isRunning)
    }

    @Test func theSeamsStartAndStopTheRendezvousOnEveryEdgeAndReconcileAStrayListener() {
        let off = ProximityRunPolicy.verdict(for: tapInput(homeFront: false))
        let on = ProximityRunPolicy.verdict(for: tapInput())
        let idle = ProximityRunTransition.MeshFacts(
            isSearching: false, isInSession: false, hasCommittedPeer: false,
            presenceListening: false, recipeShareListening: false, tapRendezvousListening: false)
        let up = ProximityRunTransition.MeshFacts(
            isSearching: false, isInSession: false, hasCommittedPeer: false,
            presenceListening: false, recipeShareListening: false, tapRendezvousListening: true)
        #expect(ProximityRunTransition.actions(from: off, to: on, mesh: idle).contains(.tapRendezvous(.foregroundOnly)))
        #expect(ProximityRunTransition.actions(from: on, to: off, mesh: up).contains(.tapRendezvous(.stop)))
        #expect(ProximityRunTransition.actions(from: off, to: off, mesh: up).contains(.tapRendezvous(.stop)))
        #expect(!ProximityRunTransition.actions(from: on, to: on, mesh: up).contains { if case .tapRendezvous = $0 { true } else { false } })
    }
}

/// The controller's mesh doors, hand-off window and what Home is shown.
@MainActor
struct TapToConnectControllerTests {

    private func makeStore(_ name: String) -> FernletStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        return FernletStore(
            repository: LocalFernletRepository(fileURL: root.appendingPathComponent("db.json")),
            sensitiveVisibilityDefaults: UserDefaults(suiteName: "\(name)-\(UUID().uuidString)") ?? .standard,
            appGroupDirectory: root.appendingPathComponent("group", isDirectory: true),
            photoDocumentsDirectory: root.appendingPathComponent("photos", isDirectory: true),
            proximitySupportDirectory: root.appendingPathComponent("proximity", isDirectory: true),
            heartDropKeychainService: "com.fernlet.tests.heartdrop.\(UUID().uuidString)"
        )
    }

    private func friend(_ byte: UInt8, blocked: Bool = false, removed: Bool = false) -> ProximityTrustedPeerRecord {
        ProximityTrustedPeerRecord(
            displayName: "Sam", fingerprint: String(repeating: "a", count: 16),
            signingPublicKey: Data(repeating: byte, count: 32), keyAgreementPublicKey: Data(repeating: byte, count: 32),
            mode: .friend, revokedAt: removed ? Date() : nil, blockedAt: blocked ? Date() : nil)
    }

    @Test func theMeshDoorsAdmitKeptFriendsAndTapMatchesOnly() {
        let store = makeStore("tap-doors")
        let controller = store.tapToConnect
        controller.recordMatch(signingPublicKey: Data(repeating: 9, count: 32), fingerprint: "0123456789abcdef")
        let keys = controller.meshDoorKeys(friends: [friend(1), friend(2, blocked: true), friend(3, removed: true)])
        #expect(keys == [Data(repeating: 1, count: 32), Data(repeating: 9, count: 32)])
        #expect(controller.metByTappingFingerprints == ["0123456789abcdef"])
    }

    @Test func theFunnelNarrowsTheMeshDoorsOnEveryRun() {
        let store = makeStore("tap-funnel")
        #expect(store.meshNetworkManager.admissibleStrangerSigningKeys == nil, "a fresh manager's doors are D-4.3's")
        _ = store.reapplyProximityRunPolicy()
        #expect(store.meshNetworkManager.admissibleStrangerSigningKeys == [], "no friend and no tap: no stranger")
    }

    @Test func aMatchHoldsTheHandOffForItsWindowOnly() {
        let store = makeStore("tap-window")
        var clock = Date(timeIntervalSince1970: 10_000)
        let rendezvous = ProximityTapRendezvous(host: store, profile: .tapToConnect(in: store.proximityNamespace))
        let controller = TapToConnectController(rendezvous: rendezvous, now: { clock })
        #expect(!controller.isHangoutPending)
        controller.recordMatch(signingPublicKey: Data(repeating: 4, count: 32), fingerprint: "fedcba9876543210")
        #expect(controller.isHangoutPending)
        clock = clock.addingTimeInterval(TapToConnectController.handOffSeconds + 1)
        #expect(!controller.isHangoutPending)
        controller.endHandOff()
        #expect(controller.pendingHangout == nil)
    }

    @Test func theTapProfileIsItsOwnModeOnThePairRow() {
        let namespace = makeStore("tap-profile").proximityNamespace
        let profile = ProximityTapRendezvousProfile.tapToConnect(in: namespace)
        #expect(profile.pair.advertisementMode == "tap" && profile.pair.auditArea == "tapConnect")
        #expect(profile.pair.radio == namespace.family.radios.pair)
        #expect(profile.pair.advertisementMode != ProximityPairProfile.recipeShare(in: namespace).advertisementMode)
        #expect(profile.cardSignature.rawValue == "fernlet.tap.card.v1" && profile.sealSalt.rawValue == "fernlet.tap.seal.v1")
    }

    @Test func aDecoyRevealsTheStandardLook() throws {
        var dressed = CompanionAppearance.standard
        dressed.bodyCustomColorHex = "#FF8800"
        let decoy = try JSONDecoder().decode(CompanionAppearance.self, from: TapToConnectController.look(of: dressed, decoy: true))
        let real = try JSONDecoder().decode(CompanionAppearance.self, from: TapToConnectController.look(of: dressed, decoy: false))
        #expect(decoy == .standard && real == dressed)
    }
}
