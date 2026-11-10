import FernletConnections
import FernletFoundation
import FernletSocial
import Foundation
import ProximityKit
import WorldMapStore

/// The road trip's mesh exchange, the store's side (World-RoadTrip-Spec PR 2, "Mesh exchange", owner-approved
/// 2026-11-10): FernletSocial's ``RoadTripExchange`` wired to the trip's keeper (`worldFog.roadTrip`), the fog and
/// Home's moments (``roadTripMesh``).
///
/// - **Start and join** (`rt-start`, `rt-join`): ``startRoadTrip(name:members:now:)`` begins the trip here and sends
///   the invite to each friend in the hangout; each friend's phone holds it for Join or Not this time
///   (``answerRoadTripInvite(join:)``). A Join starts the trip there and runs a first catch-up at once, so every
///   phone hears every phone's mapper state before the road; Not this time takes them off the others' copies.
/// - **The swap** (`rt-catchup`): at every hangout commit with a member, and on Catch up now, the exchange asks
///   ``roadTripCatchUp(for:tripID:isReply:now:)`` for the road the member was there for (``RoadTripPresence``) and
///   this phone's mapper state; a received catch-up (``receiveRoadTripCatchUp(_:from:now:)``) adds the road this
///   phone was there for to its line and lifts its fog along it as driven cells, then records the catch-up, decides
///   who maps from every member's state and ends the trip when the friend's had ended (``RoadTripCatchUpRules``).
/// - **One tap** (``catchUpRoadTrip(with:now:)``): with no hangout, a member presence hears nearby is caught up with
///   through a short hangout — the tap hand-off's window, which runs discovery on Home and commits that friend's
///   slot — left once the swap is done.
/// - **Decoy:** the exchange's gate is closed, so nothing is sent or received; every entry point here refuses too,
///   and the keeper reads and writes nothing. Wipes reach the trips through `worldFog.clearAll()`, and Home's
///   moments through ``roadTripMesh``'s `forget()`.
extension FernletStore {

    /// Wires ``RoadTripExchange``'s gate, provider and sinks to this store (the mesh composition's builder calls it).
    func wireRoadTripExchange(_ exchange: RoadTripExchange) {
        exchange.isEnabledProvider = { [weak self] in self.map { !$0.duressSessionActive } ?? false }
        exchange.catchUpProvider = { [weak self] fingerprint, tripID, isReply in
            self?.roadTripCatchUp(for: fingerprint, tripID: tripID, isReply: isReply)
        }
        exchange.onInvite = { [weak self] fingerprint, invite in self?.receiveRoadTripInvite(invite, from: fingerprint) }
        exchange.onJoinAnswer = { [weak self] fingerprint, answer in self?.receiveRoadTripAnswer(answer, from: fingerprint) }
        exchange.onCatchUp = { [weak self] fingerprint, catchUp in self?.receiveRoadTripCatchUp(catchUp, from: fingerprint) }
        // PR 3: a friend's trip photo, whole and checked; every piece that lands holds Home's note for the transfer.
        exchange.onPhoto = { [weak self] fingerprint, photo in self?.receiveRoadTripPhoto(photo, from: fingerprint) }
        exchange.onPhotoActivity = { [weak self] _ in self?.roadTripMesh.notePhotoActivity() }
    }

    /// This iPhone's member id: its mesh signing fingerprint, lowercased like every member id.
    var roadTripSelfID: String { RoadTripMembers.id(meshNetworkManager.localFingerprint) }

    // MARK: Start and join

    /// The friends Start a road trip would invite now: the hangout's other people when there are one to four, every
    /// one a kept friend linked directly with this phone that understands road trips; nil when the menu offers no
    /// Start (a decoy, a trip already on, no hangout, or anyone else in it).
    func roadTripStartCandidates() -> [RoadTripMember]? {
        guard !duressSessionActive, meshNetworkManager.isInSession, worldFog.roadTrip.active == nil else { return nil }
        let others = meshNetworkManager.sessionParticipants.filter { !$0.isLocal }
        guard (1..<RoadTrip.maxMembers).contains(others.count) else { return nil }
        let reachable = Set(meshFeatures.roadTrip.reachableFriends().map(RoadTripMembers.id))
        let members = others.map {
            RoadTripMember(id: RoadTripMembers.id($0.fingerprint),
                           firstName: PeerNameDisplay.firstName($0.displayName, fingerprint: $0.fingerprint, placeholder: .met, in: .fernlet))
        }
        guard members.allSatisfy({ reachable.contains($0.id) && $0.isValid }) else { return nil }
        return members
    }

    /// "Start the road trip": the trip starts on this iPhone with `members` (``roadTripStartCandidates()``), named
    /// `name` (empty: the default), and the invite goes to each of them. Whether it started.
    func startRoadTrip(name: String, members: [RoadTripMember], now: Date = Date()) -> Bool {
        guard !duressSessionActive, !members.isEmpty else { return false }
        let selfID = roadTripSelfID
        let me = RoadTripMember(id: selfID, firstName: PeerNameDisplay.firstName(
            resolvedProximityDisplayName, fingerprint: selfID, placeholder: .met, in: .fernlet))
        let everyone = Array(([me] + members.filter { $0.id != selfID }).prefix(RoadTrip.maxMembers))
        let ids = everyone.map(\.id)
        let own = roadTripDeviceState()
        let mapper = RoadTripMapperRule.ruleAnswer(members: ids, starter: selfID, states: [selfID: own]) ?? selfID
        let trip = RoadTrip(id: UUID(), name: RoadTripMembers.tripName(name), startedAt: now, starterID: selfID, selfID: selfID,
                            members: everyone, mapperID: mapper, mapperOverride: nil, lastCatchUp: now, endedAt: nil,
                            leftAt: nil, atStart: ids, ledger: nil, states: [selfID: own], endToTell: nil)
        guard worldFog.roadTrip.start(trip) else { return false }
        let invited = meshFeatures.roadTrip.sendInvite(RoadTripWire.invite(for: trip), to: Array(ids.dropFirst()))
        FernletAuditLog.log("worldMap.roadTrip.started", context: ["members": "\(ids.count)", "invited": "\(invited)"])
        return true
    }

    /// A friend's invite: held for Join or Not this time when it names this iPhone and comes from its starter. With
    /// another trip already on here, it is answered Not this time at once (one trip at a time).
    func receiveRoadTripInvite(_ invite: RoadTripInvitePayload, from fingerprint: String) {
        let sender = RoadTripMembers.id(fingerprint), selfID = roadTripSelfID
        guard !duressSessionActive, invite.isWellFormed, invite.starterID == sender, sender != selfID,
              invite.members.contains(where: { $0.id == selfID }) else {
            FernletAuditLog.log("worldMap.roadTrip.inviteRefused")
            return
        }
        worldFog.roadTrip.load()
        guard let trip = worldFog.roadTrip.active else {
            roadTripMesh.offer(RoadTripPendingInvite(from: sender, invite: invite))
            return
        }
        guard trip.id != invite.tripID else { return }
        let answered = meshFeatures.roadTrip.sendJoinAnswer(RoadTripJoinPayload(tripID: invite.tripID, joins: false), to: [sender])
        FernletAuditLog.log("worldMap.roadTrip.inviteWhileOnATrip", context: ["answered": "\(answered)"])
    }

    /// Join (`join`) or Not this time for the waiting invite. A Join starts the trip on this iPhone and runs a first
    /// catch-up with the members linked now; either answer goes to every member linked now. Whether it was answered.
    func answerRoadTripInvite(join: Bool) -> Bool {
        guard !duressSessionActive, let pending = roadTripMesh.takeInvite() else { return false }
        let selfID = roadTripSelfID
        let others = pending.invite.members.map(\.id).filter { $0 != selfID }
        if join {
            guard let trip = RoadTripWire.trip(joining: pending.invite, selfID: selfID, names: roadTripKnownNames(),
                                               own: roadTripDeviceState()), worldFog.roadTrip.start(trip) else {
                FernletAuditLog.log("worldMap.roadTrip.joinRefused")
                return false
            }
        }
        let exchange = meshFeatures.roadTrip
        let answered = exchange.sendJoinAnswer(RoadTripJoinPayload(tripID: pending.invite.tripID, joins: join), to: others)
        let offered = join ? exchange.offerCatchUp(to: others) : 0
        FernletAuditLog.log("worldMap.roadTrip.answered", context: ["join": "\(join)", "answered": "\(answered)", "offered": "\(offered)"])
        return true
    }

    /// A friend's answer: Not this time takes them off this phone's copy of the trip (a Join changes nothing: the
    /// invite already named them). One that says they left (PR 4) keeps them on the record as gone instead, and the
    /// trip ends here once every other member has left (``RoadTripEndRules/markingLeft(_:in:now:)``).
    func receiveRoadTripAnswer(_ answer: RoadTripJoinPayload, from fingerprint: String, now: Date = Date()) {
        let member = RoadTripMembers.id(fingerprint)
        guard !duressSessionActive, !answer.joins,
              let trip = worldFog.roadTrip.trip(sharedWith: member, id: answer.tripID) else { return }
        let saved = worldFog.roadTrip.change(trip.id) {
            $0 = answer.saysLeft ? RoadTripEndRules.markingLeft(member, in: $0, now: now) : RoadTripCatchUpRules.removing(member, from: $0)
        }
        guard saved else {
            FernletAuditLog.log("worldMap.roadTrip.declineUnsaved")
            return
        }
        if answer.saysLeft { FernletAuditLog.log("worldMap.roadTrip.memberLeft") }
    }

    /// The first names this iPhone knows the hangout's people by, by member id.
    private func roadTripKnownNames() -> [String: String] {
        var names: [String: String] = [:]
        // R2: bounded by the mesh's member cap.
        for participant in meshNetworkManager.sessionParticipants.prefix(MeshNetworkManager.maxMeshMembers) where !participant.isLocal {
            names[RoadTripMembers.id(participant.fingerprint)] = PeerNameDisplay.firstName(
                participant.displayName, fingerprint: participant.fingerprint, placeholder: .met, in: .fernlet)
        }
        return names
    }
}

/// The road trip's small naming rules (World-RoadTrip-Spec PR 2): a member's id and a trip's name as they are kept.
nonisolated enum RoadTripMembers {
    /// A fingerprint as a member id: lowercased, so the mesh's, presence's and the vault's spellings compare equal.
    static func id(_ fingerprint: String) -> String {
        fingerprint.lowercased()
    }

    /// The name the person typed, trimmed and cut to its bound; nil (the default name) when nothing is left.
    static func tripName(_ typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(RoadTrip.maxNameLength))
    }
}
