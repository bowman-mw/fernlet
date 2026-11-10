// RoadTripExchange.swift
// FernletSocial/RoadTrip
//
// Road trip mode, PR 2 "Mesh exchange" (Docs/World-RoadTrip-Spec.md, owner-approved 2026-11-10): the road trip's
// mesh wiring. The `.roadTrip` handler, registered through the mesh's payload token door, which hands a vault-
// trusted, unblocked friend's well-formed invite, answer or catch-up to the app (and, since PR 3, their trip photos,
// put back together from their pieces); the commit-time catch-up offer to such a friend; and the sends the app asks
// for (an invite, an answer, a catch-up, this phone's trip photos in pieces), through the mesh's captured-slot
// feature send, sealed, never as a routed row (the spec's transport decision: no ProximityKit release, no server).
//
// The mesh calls none of it directly. The handler reaches it through the payload registry, the capability through
// the list the composition advertises (`FernletMeshCapabilities`), and the commit through FernletSocial's mesh
// composition (`FernletMeshFeatures`), whose session observer calls the commit leg last. What a trip is, who is on
// it and which road each member was there for is the app's (this module may not import WorldMapStore): the app
// wires the gate, the provider and the three sinks.

import Foundation
import FernletDomainModel
import FernletFoundation
import ProximityKit

/// The road trip's mesh adapter (`rt-start`, `rt-join`, `rt-catchup`): the invite, the join answer and the catch-up
/// swap between kept friends linked in a hangout.
///
/// - **Who it talks to:** only a committed slot whose transport-verified peer is a vault-trusted (kept), unblocked
///   friend that advertises the `roadTrip` capability, both ways (``reachableFriends()``); every send is sealed to
///   that peer's verified key.
/// - **The swap:** at each commit the app's ``catchUpProvider`` is asked for an offer for that friend (nil when they
///   share no trip, which sends nothing). A received offer is answered by one reply, computed before the offer is
///   handed to the app (so the reply carries the road from before this catch-up) and at most once per friend every
///   ``replyIntervalSeconds``, so a hostile friend cannot use offers to make this phone send its road again and
///   again. A reply is never answered. Because each side offers at its own commit and answers the other's, the
///   swap completes whichever phone committed first (a frame on a slot not yet committed is dropped by the mesh).
/// - **Photos** (PR 3, `rt-photos`): after a swap the app hands ``sendPhotos(_:to:bytes:done:)`` the photos the friend
///   is owed (its own, the ones they were there for and don't hold yet); they go one photo at a time, in pieces
///   (``RoadTripPhotoChunker``), each read only when its turn comes, stopping if the friend goes out of reach or a
///   decoy begins. A photo already sent to a friend in this hangout is not sent again in it. Received pieces are put
///   back together and checked (``RoadTripPhotoAssembler``) before the whole photo reaches ``onPhoto``; every piece
///   that lands tells ``onPhotoActivity`` (so Home's note and a short hangout wait for the transfer). Who took a photo
///   is always the verified sender, so a received photo can't be passed on as someone else's.
/// - **Gate:** ``isEnabledProvider`` (the app: never in a decoy) gates every receive and every send; nil means no.
///
/// Built by the composition (``FernletMeshFeatures``) over its mesh, held weakly, and the features' host holder,
/// which answers the trust and block questions, carries the namespace the capability is read in and pins the host
/// for a spawned send. `@MainActor`, like the mesh and the frames that drive it. Bounded (Power of 10): the reply
/// clock remembers at most ``maxRemembered`` friends, the photos sent at most ``maxSentRemembered``, and the
/// assembler its own bounds; all are cleared when a session ends.
@MainActor
public final class RoadTripExchange {

    /// The least time between two replies to one friend, in seconds.
    static let replyIntervalSeconds: TimeInterval = 20
    /// The most friends the reply clock remembers (well over one phone's direct links).
    static let maxRemembered = 16
    /// The most slots read for one send (the mesh's own slot cap is far lower).
    static let maxSlotsRead = 32
    /// The most (friend, photo) sends remembered in one hangout (a full trip's rolls to every member).
    static let maxSentRemembered = 256

    /// Whether road trips may be exchanged at all (the app: never in a decoy session); nil means no.
    public var isEnabledProvider: (() -> Bool)?

    /// The catch-up to send `fingerprint`'s friend: at a commit (`tripID` nil, an offer) or in answer to their offer
    /// for `tripID` (`isReply` true). Nil when they share no trip with this phone, which sends nothing.
    public var catchUpProvider: ((_ fingerprint: String, _ tripID: UUID?, _ isReply: Bool) -> RoadTripCatchUpPayload?)?

    /// A friend's invite, with their verified fingerprint.
    public var onInvite: ((String, RoadTripInvitePayload) -> Void)?

    /// A friend's Join or Not this time, with their verified fingerprint.
    public var onJoinAnswer: ((String, RoadTripJoinPayload) -> Void)?

    /// A friend's catch-up, with their verified fingerprint (after this phone's reply was computed).
    public var onCatchUp: ((String, RoadTripCatchUpPayload) -> Void)?

    /// A friend's trip photo, whole and checked, with their verified fingerprint (PR 3).
    public var onPhoto: ((String, RoadTripReceivedPhoto) -> Void)?

    /// A piece of a friend's photo landed (whole or not), with their verified fingerprint: a transfer is under way.
    public var onPhotoActivity: ((String) -> Void)?

    /// Test seam: every send this exchange starts, with the recipient's fingerprint (no radio behind test slots).
    var onSendForTesting: ((String, RoadTripPayload) -> Void)?

    /// The mesh the handler is registered on and the sends go through. Weak: the composition owns the mesh.
    private weak var mesh: MeshNetworkManager?

    /// The host the trust and block questions are put to, the namespace the capability is read in, and the one
    /// helper that pins the host for a spawned send.
    private let meshHost: FernletMeshHost

    /// When each friend was last sent a reply (the amplification guard).
    private var repliedAt: [String: Date] = [:]

    /// The friends' photos still being put back together.
    private var assembler = RoadTripPhotoAssembler()

    /// The (friend, photo) pairs sent in this hangout, so a photo goes to a friend once per hangout.
    private var sentPhotos: Set<String> = []

    /// The clock.
    private let now: () -> Date

    /// An exchange over `mesh` and `meshHost`.
    ///
    /// - Parameters:
    ///   - mesh: The composition's mesh, held weakly.
    ///   - meshHost: The features' host holder.
    ///   - now: The clock (tests pass their own).
    init(mesh: MeshNetworkManager, meshHost: FernletMeshHost, now: @escaping () -> Date = Date.init) {
        self.mesh = mesh
        self.meshHost = meshHost
        self.now = now
    }

    // MARK: - Inbound

    /// Registers the `.roadTrip` handler on the mesh's payload token door. The committed-slot gate has run; the
    /// handler requires a verified, vault-trusted, unblocked sender and a well-formed body within its byte bound,
    /// then dispatches by kind. Sealed (in Fernlet's `payloads.sealingRequired`). The handler holds this exchange
    /// weakly, so the mesh retaining it forms no cycle.
    ///
    /// - Parameter mesh: The mesh to register on: the composition's, while it is built.
    func registerHandler(on mesh: MeshNetworkManager) {
        mesh.registerPayloadHandler(forToken: PayloadType.roadTrip.rawValue) { [weak self] _, plaintext, peer in
            guard let self, let peer else { return }
            self.receive(plaintext, from: peer)
        }
    }

    /// One received body from `peer`, through the gates, to the app.
    ///
    /// - Parameters:
    ///   - plaintext: The opened body.
    ///   - peer: The transport-verified sender.
    func receive(_ plaintext: Data, from peer: ProximityCoordinator.PeerIdentity) {
        guard isEnabledProvider?() == true else { return }
        guard isKeptFriend(peer) else {
            FernletAuditLog.log("mesh.roadTrip.droppedUntrustedSender")
            return
        }
        guard let payload = RoadTripPayload.decoded(from: plaintext) else {
            FernletAuditLog.log("mesh.roadTrip.droppedMalformed")
            return
        }
        switch payload.kind {
        case .invite:
            if let invite = payload.invite { onInvite?(peer.fingerprint, invite) }
        case .join:
            if let join = payload.join { onJoinAnswer?(peer.fingerprint, join) }
        case .catchUp:
            if let catchUp = payload.catchUp { receiveCatchUp(catchUp, from: peer.fingerprint) }
        case .photo:
            if let piece = payload.photo { receivePhotoPiece(piece, from: peer.fingerprint) }
        }
    }

    /// A piece of a friend's photo: gathered, and the whole photo handed to the app once it is in and checked.
    private func receivePhotoPiece(_ piece: RoadTripPhotoChunkPayload, from fingerprint: String) {
        switch assembler.accept(piece, from: fingerprint, now: now()) {
        case .gathering:
            onPhotoActivity?(fingerprint)
        case .complete(let photo):
            onPhotoActivity?(fingerprint)
            onPhoto?(fingerprint, photo)
        case .refused(let refusal):
            FernletAuditLog.log("mesh.roadTrip.photoPieceRefused", context: ["reason": "\(refusal)"])
        }
    }

    /// A friend's catch-up: an offer's reply is computed first (the road from before this catch-up), then the offer
    /// goes to the app, then the reply is sent.
    private func receiveCatchUp(_ catchUp: RoadTripCatchUpPayload, from fingerprint: String) {
        let reply = catchUp.isReply ? nil : replyIfDue(to: fingerprint, tripID: catchUp.tripID)
        onCatchUp?(fingerprint, catchUp)
        guard let reply, send(.catchUp(reply), to: [fingerprint]) == 0 else { return }
        FernletAuditLog.log("mesh.roadTrip.replyUnreachable")
    }

    /// The reply owed to `fingerprint`'s offer for `tripID`, when none was sent to them in the last
    /// ``replyIntervalSeconds``; the reply clock moves only when there is one.
    private func replyIfDue(to fingerprint: String, tripID: UUID) -> RoadTripCatchUpPayload? {
        let instant = now()
        if let last = repliedAt[fingerprint], instant.timeIntervalSince(last) < Self.replyIntervalSeconds {
            FernletAuditLog.log("mesh.roadTrip.replyRateLimited")
            return nil
        }
        guard let reply = catchUpProvider?(fingerprint, tripID, true) else { return nil }
        if repliedAt.count >= Self.maxRemembered { repliedAt.removeAll() }
        repliedAt[fingerprint] = instant
        return reply
    }

    // MARK: - The session's moments (called by the composition's session observer)

    /// The catch-up offer at a slot commit: when the peer is a kept friend that advertises `roadTrip` and the app
    /// has a catch-up for them (they share a trip), it is sent to the slot as captured, in a task of its own.
    ///
    /// - Parameters:
    ///   - slot: The committed seat, as it stood at the commit.
    ///   - peerIdentity: Its peer's verified identity.
    func offerCatchUp(to slot: PeerSlot, peer peerIdentity: ProximityCoordinator.PeerIdentity) {
        guard isEnabledProvider?() == true, supportsRoadTrips(peerIdentity), isKeptFriend(peerIdentity),
              let offer = catchUpProvider?(peerIdentity.fingerprint, nil, false) else { return }
        let payload = RoadTripPayload.catchUp(offer)
        onSendForTesting?(peerIdentity.fingerprint, payload)
        meshHost.spawnHostPinned { [weak self] in await self?.deliver(payload, via: slot) }
    }

    /// The session ended: the reply clock is forgotten, so the next stop's swap is answered at once, and so are the
    /// photos sent in it and every photo still incomplete (the next catch-up sends those again whole).
    func forgetReplies() {
        repliedAt.removeAll()
        forgetPhotoTransfers()
    }

    /// Drops every friend's photo still being put back together and which photos went to whom in this hangout (the
    /// session ended; the app: a decoy began or ended, or a wipe).
    public func forgetPhotoTransfers() {
        assembler.removeAll()
        sentPhotos.removeAll()
    }

    /// How many friends' photos are being put back together now.
    var photosInFlight: Int { assembler.inFlight }

    // MARK: - Outbound (the app's)

    /// The friends a road trip can reach now: the verified fingerprints of the committed slots whose peer is a kept,
    /// unblocked friend that advertises `roadTrip`, in the mesh's slot order.
    public func reachableFriends() -> [String] {
        reachableSlots().map(\.fingerprint)
    }

    /// Sends `invite` to each of `fingerprints` this phone can reach now (``reachableFriends()``). How many it went to.
    public func sendInvite(_ invite: RoadTripInvitePayload, to fingerprints: [String]) -> Int {
        guard invite.isWellFormed else { return 0 }
        return send(.invite(invite), to: fingerprints)
    }

    /// Sends Join or Not this time to each of `fingerprints` this phone can reach now. How many it went to.
    public func sendJoinAnswer(_ answer: RoadTripJoinPayload, to fingerprints: [String]) -> Int {
        send(.join(answer), to: fingerprints)
    }

    /// Sends a catch-up offer ("Catch up now") to each of `fingerprints` this phone can reach now that the app has
    /// one for. How many it went to.
    public func offerCatchUp(to fingerprints: [String]) -> Int {
        guard isEnabledProvider?() == true else { return 0 }
        var sent = 0
        // R2: bounded by one trip's members.
        for fingerprint in fingerprints.prefix(RoadTripPayload.maxMembers) {
            guard let offer = catchUpProvider?(fingerprint, nil, false) else { continue }
            sent += send(.catchUp(offer), to: [fingerprint])
        }
        return sent
    }

    /// Sends `photos` (this phone's own, which the app chose for this friend) to `fingerprint`'s friend when they are
    /// reachable now: at most ``RoadTripPayload/maxPhotosPerMember``, leaving out any sent to them already in this
    /// hangout, one photo at a time and in pieces, each photo's bytes read from `bytes` only when its turn comes (a
    /// photo `bytes` can't give is skipped). `done` runs once the sends are over (or nothing was sent). How many
    /// photos were queued.
    public func sendPhotos(_ photos: [RoadTripOutgoingPhoto], to fingerprint: String,
                           bytes: @escaping (UUID) -> Data?, done: @escaping () -> Void) -> Int {
        guard isEnabledProvider?() == true,
              let target = reachableSlots().first(where: { IdentityService.fingerprintsMatch($0.fingerprint, fingerprint) }) else {
            done()
            return 0
        }
        let recipient = target.fingerprint, slot = target.slot
        let fresh = Array(photos.prefix(RoadTripPayload.maxPhotosPerMember)
            .filter { !sentPhotos.contains(Self.sentKey(recipient, $0.photoID)) })
        guard !fresh.isEmpty else {
            done()
            return 0
        }
        if sentPhotos.count + fresh.count > Self.maxSentRemembered { sentPhotos.removeAll() }
        for photo in fresh { sentPhotos.insert(Self.sentKey(recipient, photo.photoID)) }
        meshHost.spawnHostPinned { [weak self] in
            await self?.deliverPhotos(fresh, to: recipient, via: slot, bytes: bytes)
            done()
        }
        return fresh.count
    }

    /// The pieces of each of `photos`, in order, to `slot`: each photo read when its turn comes; the sends stop when
    /// the gate closes or the friend is out of reach.
    private func deliverPhotos(_ photos: [RoadTripOutgoingPhoto], to recipient: String, via slot: PeerSlot,
                               bytes: (UUID) -> Data?) async {
        // R2: bounded by one roll (30 photos), each by its pieces (at most ten).
        for photo in photos.prefix(RoadTripPayload.maxPhotosPerMember) {
            guard let data = bytes(photo.photoID) else { continue }
            for piece in RoadTripPhotoChunker.chunks(of: data, for: photo) {
                guard isEnabledProvider?() == true,
                      reachableSlots().contains(where: { IdentityService.fingerprintsMatch($0.fingerprint, recipient) }) else {
                    FernletAuditLog.log("mesh.roadTrip.photoSendCut")
                    return
                }
                let payload = RoadTripPayload.photo(piece)
                onSendForTesting?(recipient, payload)
                await deliver(payload, via: slot)
            }
        }
    }

    /// The key a (friend, photo) send is remembered by.
    private static func sentKey(_ fingerprint: String, _ photo: UUID) -> String {
        fingerprint.lowercased() + ":" + photo.uuidString
    }

    // MARK: - Sending

    /// Sends `payload` to each reachable slot whose fingerprint is one of `fingerprints`, sealed; how many.
    private func send(_ payload: RoadTripPayload, to fingerprints: [String]) -> Int {
        guard isEnabledProvider?() == true, payload.isWellFormed else { return 0 }
        let wanted = fingerprints.prefix(Self.maxSlotsRead)
        var sent = 0
        // R2: bounded by the slots read.
        for target in reachableSlots() where wanted.contains(where: { IdentityService.fingerprintsMatch($0, target.fingerprint) }) {
            onSendForTesting?(target.fingerprint, payload)
            let slot = target.slot
            meshHost.spawnHostPinned { [weak self] in await self?.deliver(payload, via: slot) }
            sent += 1
        }
        return sent
    }

    /// The one send: `payload` to `slot`, sealed to its verified key.
    private func deliver(_ payload: RoadTripPayload, via slot: PeerSlot) async {
        guard let mesh else { return }
        await mesh.sendFeatureEnvelope(PayloadType.roadTrip.rawValue, encodable: payload, via: slot, sealed: true)
    }

    /// The committed slots whose peer a road trip can reach, with their verified fingerprints.
    private func reachableSlots() -> [(slot: PeerSlot, fingerprint: String)] {
        guard let mesh else { return [] }
        return mesh.slots.prefix(Self.maxSlotsRead).compactMap { slot in
            guard let fingerprint = slot.fingerprint, let peer = Self.connectedPeer(slot.coordinator.state),
                  IdentityService.fingerprintsMatch(peer.fingerprint, fingerprint),
                  supportsRoadTrips(peer), isKeptFriend(peer) else { return nil }
            return (slot, fingerprint)
        }
    }

    /// The identity of a connected (committed) coordinator; nil in any other state.
    private static func connectedPeer(_ state: ProximityCoordinator.State) -> ProximityCoordinator.PeerIdentity? {
        switch state {
        case .connected(let peer), .transferring(let peer, _): return peer
        default: return nil
        }
    }

    /// Whether `peer` advertises the `roadTrip` capability in the host's namespace.
    private func supportsRoadTrips(_ peer: ProximityCoordinator.PeerIdentity) -> Bool {
        peer.supports(ProximityCapability.roadTrip.rawValue, in: meshHost.namespace.family.vocabulary.capabilities)
    }

    /// Whether `peer` is a kept (vault-trusted), unblocked friend, by key and by fingerprint.
    private func isKeptFriend(_ peer: ProximityCoordinator.PeerIdentity) -> Bool {
        meshHost.host.isTrustedUnblockedPeer(signingPublicKey: peer.signingPublicKey, fingerprint: peer.fingerprint)
    }
}
