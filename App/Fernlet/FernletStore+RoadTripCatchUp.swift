import FernletConnections
import FernletDomainModel
import FernletFoundation
import FernletSocial
import Foundation
import ProximityKit
import WorldMapStore

/// The road trip's catch-up swap, the store's side (World-RoadTrip-Spec §2.6, `rt-catchup`, owner-approved
/// 2026-11-10): what this iPhone sends a member at a stop, what it does with what a member sends, Catch up now, the
/// one-tap catch-up from presence and the note Home asks with. See `FernletStore+RoadTripMesh.swift` for the whole.
///
/// **Proof of presence** is applied both ways: a member is sent only this phone's road after the last catch-up the
/// two shared (``RoadTripPresence/sendWindow(to:in:now:)``), and this phone keeps only road from its own first
/// presence (``RoadTripPresence/acceptWindow(in:now:)``). **Road** received is added to the line by its own rules and
/// lifts this phone's fog along it as driven cells, never walked, never in a decoy.
///
/// **Photos** (PR 3, `rt-photos`): each catch-up names the member's own photos this iPhone already holds
/// (`heldPhotos`); once a member's catch-up is applied, the trip's photos with no place yet are placed from the road
/// that came, and this iPhone's own photos the member was there for and lacks go to them in pieces
/// (`FernletStore+RoadTripPhotos.swift`). Home's note waits for the photos to settle and counts them.
extension FernletStore {

    /// The catch-up for `fingerprint`'s member: at a commit or Catch up now (`tripID` nil), or in answer to their
    /// offer for `tripID`. Nil in a decoy, when they share no trip with this phone, when they said they left it (PR 4:
    /// they get no road from after they went), or when the line can't be read right now (nothing is sent rather than a
    /// road with a hole in it).
    func roadTripCatchUp(for fingerprint: String, tripID: UUID?, isReply: Bool, now: Date = Date()) -> RoadTripCatchUpPayload? {
        guard !duressSessionActive else { return nil }
        let member = RoadTripMembers.id(fingerprint), keeper = worldFog.roadTrip
        guard let trip = keeper.trip(sharedWith: member, id: tripID), !(trip.othersLeft ?? []).contains(member) else { return nil }
        var segments: [RoadTripWireSegment] = []
        if let window = RoadTripPresence.sendWindow(to: member, in: trip, now: now) {
            guard let points = keeper.linePoints(of: trip, after: window.after, through: window.through) else { return nil }
            segments = RoadTripWire.segments(points)
        }
        return RoadTripCatchUpPayload(tripID: trip.id, isReply: isReply, segments: segments,
                                      mapper: RoadTripWire.mapperState(own: roadTripDeviceState(), takeover: trip.mapperOverride),
                                      endedAt: trip.endedAt.map(RoadTripPayload.seconds),
                                      heldPhotos: roadTripHeldPhotos(of: trip, from: member))
    }

    /// A member's catch-up: the road this phone was there for joins its line and lifts its fog as driven cells, the
    /// catch-up is recorded, who maps is decided from every member's state, a friend's end ends the trip here, photos
    /// are placed from the new road and this iPhone's photos the member is owed go to them, and Home says "Caught up"
    /// once those settle. An offer for a trip this phone is not on (it left, or never joined) is answered Not this
    /// time, so their copy drops this phone; one for an invite still waiting here is not.
    func receiveRoadTripCatchUp(_ catchUp: RoadTripCatchUpPayload, from fingerprint: String, now: Date = Date()) {
        guard !duressSessionActive else { return }
        let member = RoadTripMembers.id(fingerprint), keeper = worldFog.roadTrip
        guard let trip = keeper.trip(sharedWith: member, id: catchUp.tripID) else {
            guard !catchUp.isReply, roadTripMesh.invite?.id != catchUp.tripID else { return }
            // PR 4: a trip this phone left is answered as left, so their copy counts this phone as gone.
            let left: Bool? = keeper.hasLeft(catchUp.tripID, sharedWith: member) ? true : nil
            let answered = meshFeatures.roadTrip.sendJoinAnswer(RoadTripJoinPayload(tripID: catchUp.tripID, joins: false, left: left),
                                                                to: [fingerprint])
            FernletAuditLog.log("worldMap.roadTrip.catchUpNotOnTrip", context: ["answered": "\(answered)"])
            return
        }
        let road = acceptedRoad(catchUp, in: trip, now: now)
        let kept = keeper.appendReceived(road, to: trip.id)
        let metres = keeper.lineMetres()   // before a friend's end closes the line
        let lifted = worldFog.liftReceivedRoad(road.map(\.point))
        let received = RoadTripWire.received(catchUp), own = roadTripDeviceState()
        let applied = keeper.change(trip.id) {
            $0 = RoadTripCatchUpRules.applying(received, from: member, to: $0, own: own, now: now)
        }
        let placed = resolveRoadTripPhotoPlaces(in: trip)
        let photos = sendRoadTripPhotos(of: keeper.trip(sharedWith: member, id: trip.id) ?? trip, to: fingerprint,
                                        held: catchUp.heldPhotos ?? [], now: now)
        FernletAuditLog.log("worldMap.roadTrip.caughtUp", context: [
            "points": "\(road.count)", "kept": "\(kept)", "cells": "\(lifted)", "saved": "\(applied)",
            "placed": "\(placed)", "photosOut": "\(photos)"
        ])
        let tripID = trip.id
        roadTripMesh.didCatchUp(with: member, metres: metres, now: now,
                                photos: { [weak self] in self?.roadTripPhotoCount(of: tripID) ?? 0 },
                                leave: { [weak self] in await self?.leaveRoadTripHangout() })
    }

    /// The road in `catchUp` this phone keeps for `trip` at `now`: valid points within its own presence.
    private func acceptedRoad(_ catchUp: RoadTripCatchUpPayload, in trip: RoadTrip, now: Date) -> [RoadTripPoint] {
        guard let window = RoadTripPresence.acceptWindow(in: trip, now: now) else { return [] }
        return RoadTripPresence.points(RoadTripWire.points(catchUp.segments), from: window.from, through: window.through)
    }

    // MARK: Catch up now and one tap

    /// The members a catch-up can reach now: in the hangout and linked (`RoadTripExchange/reachableFriends()`), or
    /// heard nearby by presence; of the trip on now, or of the newest trip still owing them its end. Empty in a decoy.
    func roadTripCatchUpMembers() -> (linked: [String], nearby: [String]) {
        guard !duressSessionActive, let trip = roadTripTripToCatchUp() else { return ([], []) }
        let members = roadTripMembersToCatchUp(in: trip)
        let linked = Set(meshFeatures.roadTrip.reachableFriends().map(RoadTripMembers.id))
        let nearby = Set(presenceManager.nearbyFriendFingerprints.map(RoadTripMembers.id))
        return (members.filter(linked.contains), members.filter { nearby.contains($0) && !linked.contains($0) })
    }

    /// "Catch up now": the members linked in this hangout are offered a catch-up now; with none, the first member
    /// heard nearby is caught up with through a short hangout (``catchUpRoadTrip(with:now:)``). Whether one began.
    func catchUpRoadTripNow() -> Bool {
        let reach = roadTripCatchUpMembers()
        if !reach.linked.isEmpty { return meshFeatures.roadTrip.offerCatchUp(to: reach.linked) > 0 }
        guard let member = reach.nearby.first else { return false }
        return catchUpRoadTrip(with: member)
    }

    /// The catch-up note's **Catch up** (`rt-catchup`: "One tap opens a short hangout, swaps the road and photos, and
    /// closes it."): with `member` already linked in this hangout, the swap runs now; with no hangout, a short one
    /// opens through the tap hand-off (discovery on Home, the friend's slot committed once their introduction
    /// arrives, nobody touching phones), the commit's own catch-up does the swap, and the hangout is left once it
    /// is done. Their phone asks them the same and needs their Catch up too. Whether it began.
    func catchUpRoadTrip(with member: String, now: Date = Date()) -> Bool {
        guard !duressSessionActive else { return false }
        let exchange = meshFeatures.roadTrip
        if exchange.reachableFriends().contains(where: { RoadTripMembers.id($0) == member }) {
            return exchange.offerCatchUp(to: [member]) > 0
        }
        guard !meshNetworkManager.isInSession,
              let friend = trustedProximityPeers.first(where: {
                  RoadTripMembers.id($0.fingerprint) == member && $0.blockedAt == nil && $0.revokedAt == nil
              }),
              tapToConnect.beginKeptFriendHandOff(signingPublicKey: friend.signingPublicKey, fingerprint: friend.fingerprint)
        else { return false }
        roadTripMesh.beginHandOff(member: member, now: now) { [weak self] in await self?.leaveRoadTripHangout() }
        return true
    }

    /// Leaves the short hangout a one-tap catch-up opened: only while every other person in it is on this phone's
    /// trip (a hangout the person widened is theirs to leave).
    func leaveRoadTripHangout() async {
        guard meshNetworkManager.isInSession, let trip = roadTripTripToCatchUp() else { return }
        let members = Set(trip.memberIDs)
        let others = meshNetworkManager.sessionParticipants.filter { !$0.isLocal }
        guard others.allSatisfy({ members.contains(RoadTripMembers.id($0.fingerprint)) }) else { return }
        await meshNetworkManager.leaveSessionAfterNotifyingPeers()
    }

    /// Re-decides who Home's note asks about (`rt-catchup`, ask once): `isFrontmost` is Home in front of an open app.
    func refreshRoadTripQuestion(isFrontmost: Bool) {
        let trip = duressSessionActive ? nil : roadTripTripToCatchUp()
        let members = trip.map(roadTripMembersToCatchUp(in:)) ?? []
        let isFree = isFrontmost && !meshNetworkManager.isInSession && !tapToConnect.isHangoutPending
        roadTripMesh.refreshQuestion(members: members, nearby: Set(presenceManager.nearbyFriendFingerprints.map(RoadTripMembers.id)),
                                     isFree: isFree)
    }

    /// The first name of `member` on the trip a catch-up is about; nil when they are not on it.
    func roadTripMemberName(_ member: String) -> String? {
        roadTripTripToCatchUp()?.members.first { $0.id == member }?.firstName
    }

    /// The trip a catch-up is about now: the trip on now, else the newest one still owing its end to someone.
    private func roadTripTripToCatchUp() -> RoadTrip? {
        let keeper = worldFog.roadTrip
        if let trip = keeper.active { return trip }
        guard let last = keeper.book.trips.last, last.leftAt == nil, last.endedAt != nil, !(last.endToTell ?? []).isEmpty else { return nil }
        return last
    }

    /// The members of `trip` to catch up with: the others still on it while it is on (PR 4: not those who said they
    /// left), those still owed its end after.
    private func roadTripMembersToCatchUp(in trip: RoadTrip) -> [String] {
        trip.isActive ? trip.othersOnTrip.map(\.id) : (trip.endToTell ?? [])
    }
}
