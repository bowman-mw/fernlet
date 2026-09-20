//
//  MeshFlowDriver.swift
//  Fernlet
//
//  DEBUG-only launch hook for the P2 migration's Lane C *app-flow* runs (see
//  Docs/Mesh-Network-Feasibility-Runbook.md). The rejection matrix proved the QUIC tunnel is
//  selective; this drives the layers ABOVE it — slot commit, capability exchange, chat, photos,
//  the clothing shop — between two Simulators with no UI navigation and no hardware, and echoes
//  what each side observed so a `--console-pty` transcript is the evidence.
//
//  The whole file is compiled out of release builds. Its only caller is the DEBUG half of
//  MeshRejectionMatrixHarness.install(manager:).
//

#if DEBUG

import CoreGraphics
import FernletDomainModel
import Foundation
import ProximityKit
import UIKit

// MARK: - MeshFlowVerb

/// One app-layer flow a Lane C run can ask for.
///
/// Frozen automation tokens parsed from a DEBUG-only environment variable: never localized, never
/// persisted, never on a wire. Unrecognized tokens in the list are ignored rather than fatal, so a
/// stale run script degrades to fewer flows instead of no run.
///
/// Committing a peer's slot is **not** one of these. It is unconditional once any flow is asked
/// for, because every other flow needs a committed slot to be reachable at all; ``commit`` names a
/// run that wants only that.
enum MeshFlowVerb: String, CaseIterable, Sendable {

    /// Commit the peer's slot and report, driving nothing else.
    case commit

    /// Report the capability list the peer advertised in its signed identity introduction.
    case capabilities

    /// Send one temporary session message, with the 13+ chat gate open.
    case chat

    /// Send one temporary session message with the 13+ chat gate **closed**, so the refusal and the
    /// withheld `messages` capability are both observable over QUIC.
    case chatAgeGated

    /// Add one friend photo, which broadcasts it to every active committed slot.
    case photo

    /// Exchange clothing-shop catalogs. Nothing is sent by hand: the manager offers a catalog once
    /// per slot at commit, so this verb supplies a catalog to offer and then observes.
    case shop

    /// Send one in-session heart to the first trusted session peer (P6 item 10).
    ///
    /// Needs three things a fresh Simulator does not have: the nearby-hearts opt-in on
    /// (``MeshMatrixDebugOptions/allowsHearts``, applied before `startJoin()`), a trust-vault row
    /// for the peer (a previous session's keep — ``MeshMatrixDebugOptions/autoKeepsFriends``), and
    /// a committed slot. Missing any of them, the verb says which and sends nothing.
    case heart
}

// MARK: - MeshMatrixRole

/// The membership shape a Lane C node plays in a pair run (P3 item 9).
///
/// Frozen automation tokens parsed from a DEBUG-only environment variable: never localized, never
/// persisted, never on a wire. ``none`` is the state every Lane C run before item 9 was in — a
/// seeded descriptor and no ledger at all — and it is what an absent or unrecognized variable means.
///
/// The roles are asymmetric on purpose. The QUIC transport is members-only by construction, so the
/// seeded descriptor is the only thing that can open the first tunnel; the ``founder`` collapses
/// that descriptor to itself and arms the real ledger once the tunnel is up, and the ``joiner``
/// then travels the shipping admission path to get onto it.
enum MeshMatrixRole: String, CaseIterable, Sendable {

    /// No membership role: seed, connect, drive flows. The pre-item-9 behaviour.
    case none

    /// Arm the founder ledger once a slot commits, then admit whoever asks.
    case founder

    /// Ask the founder for admission once a slot commits, then adopt what it is sent.
    case joiner
}

// MARK: - MeshFlowRunState

/// What the driver has already done, and what it last reported.
///
/// The poll runs at 1 Hz for minutes; echoing every tick would bury the four lines that matter in a
/// transcript of nothing happening. Every counter here is "the last value that was printed", so a
/// line is emitted exactly when something changed.
struct MeshFlowRunState {

    /// Flows already fired. Each fires once per run.
    var fired: Set<MeshFlowVerb> = []

    /// Slots already asked to commit, so a commit that has not landed yet is not asked twice.
    var asked: Set<UUID> = []

    /// The slot summary at the last report.
    var slots = ""

    /// The peer capability summary at the last report.
    var capabilities = ""

    /// Messages received from a peer at the last report.
    var messagesIn = -1

    /// Messages this device put on the wire at the last report.
    var messagesOut = -1

    /// Photos received from a peer at the last report.
    var photosIn = -1

    /// Peer catalogs held at the last report.
    var catalogs = -1

    /// The derived-roster summary at the last report — the membership audit line (P3 item 9).
    var membership = ""

    /// Whether the founder has already armed its ledger. Once, per run.
    var armedFounder = false

    /// Whether the founder has already filed its removal record. Once, per run.
    var seededRemoval = false

    /// The poll at which the joiner last asked for admission, so the ask repeats on a schedule
    /// rather than every second while it waits for the founder to arm.
    var askedAdmissionAt = -1

    /// The heart summary — vault size, received hearts, ledger load state, send state — at the last
    /// report (P6 item 10). One string for the same reason ``membership`` is one: four counters that
    /// move together are one transcript line.
    var hearts = ""
}

// MARK: - MeshFlowDriver

/// Drives and observes the app-layer mesh flows on one Simulator, headlessly.
///
/// ## What it drives, and what it only watches
///
/// It commits the peer's slot (`commitManualProximity`, the non-UWB path a Simulator is always on),
/// then calls the same **public** entry points the UI calls — `sendTempMessage`, `addPhoto`. It
/// never reaches inside the manager, never forges a slot, and never touches the transport: the code
/// under observation is the shipping code, exactly as in ``MeshRejectionMatrixHarness``.
///
/// Two seams it does set, and why. ``MeshNetworkManager/chatAllowedProvider`` stands in for a
/// completed age determination, which a fresh Simulator has no way to reach and which no
/// self-attestation can open (`AgeGate.chat.allowsSelfAttestation` is false) — and setting it
/// *closed* is how the 13+ gate's enforcement point is observed rather than assumed. The clothing
/// shop's two providers stand in for the `allowNearbyClothingShares` setting and a designed
/// catalog. Both are set **before** `startJoin()`, because a peer's capability list is snapshotted
/// when its coordinator is built and a provider flipped afterwards would not reach the wire.
///
/// Nothing here is persisted: the catalog is synthesized in memory for one launch and the provider
/// closures die with the process, so this owes no row on the persisted-surface wipe ledger.
@MainActor
enum MeshFlowDriver {

    /// Frozen console tag, distinct from `[mesh-matrix]` and the transport's `[mesh-quic]`, so a
    /// transcript can be grepped down to the app-layer observations. Never shown in the UI.
    static let consolePrefix = "[mesh-flow]"

    /// Seconds between polls. One shared poll rather than a watcher per flow — the same reason the
    /// QUIC radio has one.
    static let pollIntervalSeconds: TimeInterval = 1

    /// Polls a run makes before it stops on its own: five minutes at 1 Hz, comfortably inside the
    /// coordinator's own 5-minute proximity-gate timeout. Bounded rather than `while true`
    /// (Power of 10 rule 2).
    static let maxTicks = 300

    /// Side of the synthesized photo, in pixels. Random noise at this size re-encodes to a JPEG of
    /// a few hundred kilobytes, which is what makes the run exercise the per-transfer stream path
    /// (`MeshTransferStreamTable.bulkFloorBytes`) rather than the control stream.
    static let noiseImageSide = 600

    /// JPEG quality for the synthesized photo. High on purpose: the point is a realistically large
    /// payload, not a small one.
    static let noiseImageQuality: CGFloat = 0.9

    /// The message text a `chat` run sends. A frozen token so the peer's transcript can be grepped
    /// for it; deliberately not prose, and never localized.
    static let chatText = "flow-chat"

    /// Applies the seams a run needs **before** the radios start.
    ///
    /// Ordering is the whole contract: `localCapabilities()` is read when a peer's coordinator is
    /// built, so a provider set after `startJoin()` would never reach a peer's capability list.
    static func prepare(manager: MeshNetworkManager, store: FernletStore) {
        // P6 item 10: the hearts opt-in ships OFF and `.hearts` is advertised only when it is on,
        // so this must land before `startJoin()` too — and it is applied whether or not a flow was
        // asked for, because a session-1 run that only keeps friends still wants the capability on
        // the wire. It writes the user's own setting through the shipping door.
        if MeshMatrixDebugOptions.allowsHearts {
            store.setAllowNearbyHearts(true)
            echo("hearts on=true")
        }
        let flows = MeshMatrixDebugOptions.flows
        guard !flows.isEmpty else { return }
        echo("flows requested=[\(flows.map(\.rawValue).joined(separator: ","))]")
        // Fail closed on purpose: a run that asks for both gets the gated behaviour.
        let chatAllowed = flows.contains(.chat) && !flows.contains(.chatAgeGated)
        if flows.contains(.chat) || flows.contains(.chatAgeGated) {
            manager.chatAllowedProvider = { chatAllowed }
            echo("ageGate chatAllowed=\(chatAllowed)")
        }
        guard flows.contains(.shop) else { return }
        let catalog = ClothingCatalogPayload(
            designerID: UUID(),
            displayName: "matrix",
            items: []
        )
        manager.clothingShop.isSharingEnabledProvider = { true }
        manager.clothingShop.localCatalogProvider = { catalog }
        echo("shop sharing=on catalogItems=\(catalog.items.count)")
    }

    /// Polls between a joiner's admission asks. The founder arms its ledger on its own first
    /// committed slot, which the joiner cannot see, so the ask repeats until it lands.
    static let admissionRetryTicks = 5

    /// Starts the run's poll. A no-op when no flow and no membership role was asked for, which is
    /// the behaviour this file had before it existed.
    static func start(manager: MeshNetworkManager, store: FernletStore) {
        guard !MeshMatrixDebugOptions.flows.isEmpty || MeshMatrixDebugOptions.role != .none else { return }
        Task { @MainActor [weak manager, weak store] in
            guard let manager, let store else { return }
            await run(manager: manager, store: store)
        }
    }

    /// The bounded poll: commit what is waiting, fire what is due, report what changed.
    private static func run(manager: MeshNetworkManager, store: FernletStore) async {
        var state = MeshFlowRunState()
        for tick in 0..<maxTicks {
            do {
                try await Task.sleep(for: .seconds(pollIntervalSeconds))
            } catch {
                return
            }
            commitPendingSlots(manager: manager, state: &state)
            report(manager: manager, store: store, state: &state)
            driveRole(manager: manager, state: &state, tick: tick)
            fireDueFlows(manager: manager, store: store, state: &state, tick: tick)
            autoKeepFriendsIfDue(manager: manager, store: store)
            guard MeshMatrixDebugOptions.leaveAfterSeconds != tick else {
                await leave(manager: manager)
                // The departer's poll ends inside `leave`, and `pendingFriendReview` is promoted by
                // the session end that departure causes — so a poll-only check would never see the
                // batch it exists for (P6 item 10).
                autoKeepFriendsIfDue(manager: manager, store: store)
                report(manager: manager, store: store, state: &state)
                return
            }
        }
        echo("run ended: poll budget spent")
    }

    /// Keeps every candidate of a promoted friend-review batch, then consumes the batch.
    ///
    /// Stands in for `ConnectView.finalizeFriendKeeps()`'s one tap: both doors below are the
    /// shipping ones, and the batch is only ever promoted by a real session end. The trust-vault
    /// row it writes is what makes a peer heart-eligible in a LATER session — which is why the
    /// hearts script needs two of them (P6 item 10).
    private static func autoKeepFriendsIfDue(manager: MeshNetworkManager, store: FernletStore) {
        guard MeshMatrixDebugOptions.autoKeepsFriends,
              let batch = manager.pendingFriendReview else { return }
        let kept = Set(batch.entries.map(\.fingerprint))
        store.keepProximityFriends(from: batch.entries, keptFingerprints: kept)
        manager.completeFriendReview(batch.id)
        echo("friends kept=\(kept.count) vault=\(store.trustedProximityPeers.count)")
    }

    // MARK: - Membership roles (P3 item 9)

    /// The role's synchronous half, plus the membership audit line every run prints.
    ///
    /// Synchronous by design: `inout` state cannot cross an `await`, and the only asynchronous
    /// step a role takes is the departure, which ends the run and is driven by ``run(manager:)``.
    private static func driveRole(manager: MeshNetworkManager, state: inout MeshFlowRunState, tick: Int) {
        switch MeshMatrixDebugOptions.role {
        case .none: break
        case .founder: driveFounder(manager: manager, state: &state, tick: tick)
        case .joiner: driveJoiner(manager: manager, state: &state, tick: tick)
        }
        reportMembership(manager: manager, state: &state)
    }

    /// Arms the ledger on the first committed slot, admits whoever asks, and — when the run asked
    /// for one — files the removal record.
    ///
    /// The admission loop iterates a COPY: `allowAdmission` mutates the published array.
    private static func driveFounder(manager: MeshNetworkManager, state: inout MeshFlowRunState, tick: Int) {
        if !state.armedFounder, committedSlotCount(manager) > 0 {
            state.armedFounder = true
            let armed = manager.armFounderLedgerForHarness()
            echo("founder armed=\(armed) \(manager.harnessMembershipSummary)")
        }
        guard state.armedFounder else { return }
        for request in Array(manager.pendingAdmissionRequests) {
            echo("admitting \(request.requesterFingerprint)")
            manager.allowAdmission(request)
        }
        guard MeshMatrixDebugOptions.removeAfterSeconds == tick, !state.seededRemoval else { return }
        state.seededRemoval = true
        guard let target = removalTargetFingerprint(manager) else {
            echo("removal NOT filed: no seeded member other than this device")
            return
        }
        let filed = manager.seedRemovalRecordForHarness(targetFingerprint: target)
        echo("removal filed=\(filed) target=\(target) \(manager.harnessMembershipSummary)")
    }

    /// Asks for admission, on a repeat, until this device holds a ledger of its own.
    private static func driveJoiner(manager: MeshNetworkManager, state: inout MeshFlowRunState, tick: Int) {
        guard !manager.harnessHasLedger, committedSlotCount(manager) > 0 else { return }
        guard tick - state.askedAdmissionAt >= admissionRetryTicks else { return }
        state.askedAdmissionAt = tick
        echo("requesting admission asked=\(manager.requestAdmissionForHarness())")
    }

    /// The first seeded member key that is not this device — the removal row's target.
    private static func removalTargetFingerprint(_ manager: MeshNetworkManager) -> String? {
        for key in MeshMatrixDebugOptions.seededMemberKeys where key != manager.localSigningPublicKey {
            return IdentityService.fingerprint(of: key)
        }
        return nil
    }

    /// Leaves through the clean-departure verb, so the signed ending is on the wire before the
    /// transport is torn down. On a roster larger than two that is `member-departure.v1`; on a
    /// roster of exactly two `MeshDevelopmentPlan` makes it `terminated.v1` (plan §10.6).
    private static func leave(manager: MeshNetworkManager) async {
        echo("leaving via leaveSessionAfterNotifyingPeers \(manager.harnessMembershipSummary)")
        await manager.leaveSessionAfterNotifyingPeers()
        echo("left \(manager.harnessMembershipSummary)")
    }

    /// Echoes the derived roster + epoch head when either moves — the one line that makes
    /// membership convergence readable in a `--console-pty` transcript.
    private static func reportMembership(manager: MeshNetworkManager, state: inout MeshFlowRunState) {
        let summary = manager.harnessMembershipSummary
        guard summary != state.membership else { return }
        echo("membership \(summary)")
        state.membership = summary
    }

    /// Commits every slot sitting at a proximity gate.
    ///
    /// **Both gates, not just the manual one.** A Simulator's `NIRangingSession` reports hardware
    /// support, so the friend handshake lands at `awaitingProximityCommit` — and the 15 cm UWB dwell
    /// behind it can never complete without a real radio, so the slot would sit there until the
    /// coordinator's 5-minute gate timeout. `commitManualProximity` accepts both states, which is
    /// exactly how the app's own debug "Force" control commits a stuck UWB gate; this stands in for
    /// that control, not for a user's consent decision.
    ///
    /// Each device commits its **own** slot; there is no remote commit. Asked once per slot, because
    /// the commit lands a tick later and a second ask would only add a line to the transcript.
    /// Bounded by the manager's slot cap.
    private static func commitPendingSlots(manager: MeshNetworkManager, state: inout MeshFlowRunState) {
        for slot in manager.slots where !state.asked.contains(slot.id) {
            switch slot.coordinator.state {
            case .awaitingManualCommit, .awaitingProximityCommit:
                state.asked.insert(slot.id)
                echo("committing slot gate=\(slot.coordinator.state.debugLabel)")
                manager.commitManualProximity(slotID: slot.id)
            default:
                continue
            }
        }
    }

    /// Fires each requested flow once, as soon as a committed slot exists to carry it and the
    /// run's `FERNLET_MESH_FLOWS_AFTER` poll has arrived.
    ///
    /// The poll gate is P6 item 10's, and it is the difference between observing the founding
    /// window and observing a routed delivery. The first tick with a committed slot is the tick a
    /// `founder` run collapses its seeded descriptor to itself, so the derived roster is 1 and every
    /// routed mint answers `.noDestinations`; the admission grant lands several polls later. With
    /// the variable absent the gate is poll 0 — today's behaviour exactly, and the founding-window
    /// refusal is then the observation rather than an accident.
    private static func fireDueFlows(
        manager: MeshNetworkManager, store: FernletStore, state: inout MeshFlowRunState, tick: Int
    ) {
        guard tick >= MeshMatrixDebugOptions.flowsAfterPolls else { return }
        guard committedSlotCount(manager) > 0 else { return }
        for verb in MeshMatrixDebugOptions.flows where !state.fired.contains(verb) {
            state.fired.insert(verb)
            fire(verb, manager: manager, store: store)
        }
    }

    /// One flow. `commit`, `capabilities` and `shop` drive nothing — they are observed by
    /// ``report(manager:state:)`` — so they only say that their moment arrived.
    private static func fire(_ verb: MeshFlowVerb, manager: MeshNetworkManager, store: FernletStore) {
        switch verb {
        case .heart:
            fireHeart(manager: manager, store: store)
        case .commit, .capabilities, .shop:
            echo("armed \(verb.rawValue)")
        case .chat, .chatAgeGated:
            echo("sending chat isChatAllowed=\(manager.isChatAllowed)")
            // Since P6 item 4 this is a ROUTED flow: the send mints an item and answers what it
            // did, so the lane log carries the outcome instead of inferring it from silence.
            let outcome = manager.sendTempMessage("\(chatText)-\(MeshMatrixDebugOptions.label)")
            echo("chat outcome=\(outcome)")
        case .photo:
            guard let data = noiseJPEG(side: noiseImageSide) else {
                echo("photo NOT sent: the synthesized image could not be encoded")
                return
            }
            echo("sending photo jpegBytes=\(data.count)")
            manager.addPhoto(data)
        }
    }

    /// One in-session heart, through the same three lines the camera's heart button uses.
    ///
    /// The trust-vault lookup is the whole point: `sendSessionHeart(to:)` takes a
    /// `ProximityTrustedPeerRecord`, and the receiver's ceremony asks
    /// `isHeartEligibleFriend(_:in:)`, which requires that row on the OTHER device too — so a run
    /// that has not kept the peer in a previous session says so and sends nothing, rather than
    /// producing a refusal that looks like a defect. It stands in for one tap and no consent
    /// decision (P6 item 10).
    private static func fireHeart(manager: MeshNetworkManager, store: FernletStore) {
        guard let peer = manager.sessionParticipants.first(where: { !$0.isLocal }) else {
            echo("heart NOT sent: no remote participant in this session")
            return
        }
        guard let friend = store.trustedProximityPeers.first(where: {
            IdentityService.fingerprintsMatch($0.fingerprint, peer.fingerprint)
                && $0.blockedAt == nil && $0.revokedAt == nil
        }) else {
            echo("heart NOT sent: no trust-vault row for \(peer.fingerprint)")
            return
        }
        echo("sending heart to=\(friend.fingerprint) "
            + "canSendSessionHeart=\(manager.canSendSessionHeart(toFingerprint: friend.fingerprint))")
        manager.sendSessionHeart(to: friend)
    }

    // MARK: - Observation

    /// Echoes every counter that moved since the last poll, and nothing that did not.
    private static func report(
        manager: MeshNetworkManager, store: FernletStore, state: inout MeshFlowRunState
    ) {
        let slots = slotSummary(manager)
        if slots != state.slots {
            echo("slots \(slots)")
            state.slots = slots
        }
        let capabilities = peerCapabilitySummary(manager)
        if capabilities != state.capabilities {
            echo("capabilities peer=[\(capabilities)]")
            state.capabilities = capabilities
        }
        reportPayloads(manager: manager, state: &state)
        reportHearts(manager: manager, store: store, state: &state)
    }

    /// The hearts run's four counters, as one line, only for a run that asked about hearts.
    ///
    /// Gated rather than unconditional because `store.heartLedger` is lazy and reading it loads a
    /// sidecar off disk; a matrix run that never mentions hearts should not pay for that every
    /// second (P6 item 10).
    private static func reportHearts(
        manager: MeshNetworkManager, store: FernletStore, state: inout MeshFlowRunState
    ) {
        guard MeshMatrixDebugOptions.allowsHearts
                || MeshMatrixDebugOptions.autoKeepsFriends
                || MeshMatrixDebugOptions.flows.contains(.heart) else { return }
        let summary = "vault friends=\(store.trustedProximityPeers.count) "
            + "heartsReceived=\(store.heartLedger.receivedHearts.count) "
            + "ledgerLoaded=\(store.heartLedger.isLoaded) "
            + "heartState=\(manager.sessionHeartState)"
        guard summary != state.hearts else { return }
        echo(summary)
        state.hearts = summary
    }

    /// The three receive-side counters a flow run is read off.
    private static func reportPayloads(manager: MeshNetworkManager, state: inout MeshFlowRunState) {
        let messages = manager.sessionMessages.messages
        let incoming = messages.filter { !$0.isOutgoing }.count
        let outgoing = messages.count - incoming
        if incoming != state.messagesIn || outgoing != state.messagesOut {
            echo("chat received=\(incoming) sent=\(outgoing) isChatAllowed=\(manager.isChatAllowed)")
            state.messagesIn = incoming
            state.messagesOut = outgoing
        }
        let photosIn = manager.meshPhotos.filter { $0.senderFingerprint != manager.localFingerprint }.count
        if photosIn != state.photosIn {
            echo("photos received=\(photosIn) held=\(manager.meshPhotos.count)")
            state.photosIn = photosIn
        }
        let catalogs = manager.clothingShop.peerCatalogs.count
        if catalogs != state.catalogs {
            echo("shop peerCatalogs=\(catalogs)")
            state.catalogs = catalogs
        }
    }

    /// Committed slots — a slot whose peer completed the signed identity introduction and the
    /// proximity gate, so it carries a transport-verified fingerprint.
    private static func committedSlotCount(_ manager: MeshNetworkManager) -> Int {
        manager.slots.filter { $0.fingerprint != nil }.count
    }

    /// How many slots exist, how many are committed, and where each one's handshake has reached.
    ///
    /// The coordinator state is the load-bearing half: a slot that is seated but stuck names the
    /// gate it is stuck at, which is the difference between "the flow is unreachable" and "the flow
    /// was never driven".
    private static func slotSummary(_ manager: MeshNetworkManager) -> String {
        let states = manager.slots.map(\.coordinator.state.debugLabel).sorted().joined(separator: ",")
        return "total=\(manager.slots.count) committed=\(committedSlotCount(manager)) states=[\(states)]"
    }

    /// The capability tokens every connected peer advertised, sorted and de-duplicated.
    ///
    /// Read through the coordinator's public `.connected(peer:)` state rather than the slot's
    /// internal copy, because that is the surface an app-target caller actually has.
    private static func peerCapabilitySummary(_ manager: MeshNetworkManager) -> String {
        var tokens: Set<String> = []
        for slot in manager.slots {
            guard case .connected(let peer) = slot.coordinator.state else { continue }
            tokens.formUnion(peer.capabilities ?? [])
        }
        return tokens.sorted().joined(separator: ",")
    }

    // MARK: - The synthesized photo

    /// A square of random noise, JPEG-encoded.
    ///
    /// Noise rather than a flat colour deliberately: a solid image compresses to a few kilobytes and
    /// would ride the control stream, proving nothing about the per-transfer path. Noise at 600 px
    /// does not compress, so the sealed envelope lands well above
    /// `MeshTransferStreamTable.bulkFloorBytes` — which is the whole point of the photo row.
    /// Internal rather than private since P9 item 3: `RecipeShareLaneHarness` needs the same
    /// incompressible bytes for the picture half of its own transfer-stream row, and a second
    /// generator would be a second thing to keep honest.
    static func noiseJPEG(side: Int) -> Data? {
        let bytesPerPixel = 4
        let byteCount = side * side * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: byteCount)
        for index in 0..<byteCount {
            pixels[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bitsPerPixel: bytesPerPixel * 8,
                  bytesPerRow: side * bytesPerPixel,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: noiseImageQuality)
    }

    /// Mirrors one driver line to stdout, where `simctl launch --console-pty` reads it.
    private static func echo(_ message: String) {
        print("\(consolePrefix) \(message)")
    }
}

#endif
