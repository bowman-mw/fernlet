import FernletFoundation
import FernletSocial
import Foundation
import UIKit
import WorldMapStore

/// The road trip's side of the store (World-RoadTrip-Spec PR 1, "Trip core", owner-approved 2026-11-10): the trip's
/// keeper (`worldFog.roadTrip`, ``RoadTripKeeper``) wired to the map's location, this iPhone's state for the mapper
/// rule, Trip info's rows and actions, and the DEBUG scene that stages a trip. PR 2's mesh exchange (Start a road
/// trip, Join, the catch-up swap) is `FernletStore+RoadTripMesh.swift` and `FernletStore+RoadTripCatchUp.swift`.
///
/// - **The passenger gate:** ``wireWorldRoadTrip(to:adopted:)`` tells the location source whether this iPhone is a
///   passenger now and whenever that changes, so a passenger traces no drive.
/// - **Recording** needs no wiring here: the fog keeper hands the trip every reading it accepts.
/// - **Decoy and wipes** are the fog keeper's: a decoy shows no trip and records nothing; every wipe and Delete map
///   history remove the trips with the vault.
extension FernletStore {
    /// Wires the road trip's keeper to `source`: the book read (again, after the store adopted a locked launch's
    /// source, whose own keeper wrote meanwhile), and the passenger gate told now and on every change.
    func wireWorldRoadTrip(to source: WorldLocationSource, adopted: Bool) {
        let trip = worldFog.roadTrip
        if adopted { trip.reload() } else { trip.load() }
        // At launch, a trip seven days without a catch-up ends at its mark (PR 4), before the gate is told.
        trip.endIfQuiet()
        trip.onPassengerChanged = { [weak source] passenger in source?.setRoadTripPassenger(passenger) }
        source.setRoadTripPassenger(trip.isPassenger)
    }

    /// This iPhone's state for the mapper rule now (`rt-mapper`): CarPlay connected (the car keeper's route) and
    /// plugged in (the battery, read with monitoring on for the moment only).
    func roadTripDeviceState() -> RoadTripDeviceState {
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        if !wasMonitoring { device.isBatteryMonitoringEnabled = true }
        let battery = device.batteryState
        if !wasMonitoring { device.isBatteryMonitoringEnabled = false }
        let carPlay = worldLocation.cars.connected.contains { $0.kind == .carPlay }
        return RoadTripDeviceState(onCarPlay: carPlay, isCharging: battery == .charging || battery == .full)
    }

    /// Trip info's rows now; nil with no trip on, and in a decoy.
    func roadTripInfo(now: Date = Date()) -> RoadTripInfo? {
        let keeper = worldFog.roadTrip
        guard !duressSessionActive, let trip = keeper.active else { return nil }
        let reach = roadTripCatchUpMembers()
        return RoadTripInfo(title: RoadTripCopy.name(of: trip), mapperName: trip.mapper?.firstName,
                            lastCatchUp: trip.lastCatchUp, metres: keeper.lineMetres(),
                            photos: RoadTripTestScenes.photoCount ?? roadTripPhotoCount(of: trip.id), isMapping: trip.isMapping,
                            canCatchUp: !reach.linked.isEmpty || !reach.nearby.isEmpty)
    }

    /// "Map from this iPhone": this iPhone maps from now, the rule's answer read over every member's state as last
    /// heard (this phone's fresh). Whether it changed anything.
    func mapRoadTripFromThisPhone(now: Date = Date()) -> Bool {
        let keeper = worldFog.roadTrip
        guard !duressSessionActive, let trip = keeper.active else { return false }
        var states = trip.states ?? [:]
        states[trip.selfID] = roadTripDeviceState()
        return keeper.mapFromThisPhone(states: states, now: now)
    }

    /// "Leave the road trip": this iPhone leaves, and the members linked in this hangout hear it at once (PR 4: a
    /// Not this time that says it left); the others hear it when they next offer a catch-up. Whether it was written.
    func leaveRoadTrip(now: Date = Date()) -> Bool {
        guard !duressSessionActive, let trip = worldFog.roadTrip.active else { return false }
        let linked = roadTripCatchUpMembers().linked
        guard worldFog.roadTrip.leave(now: now) else { return false }
        let told = linked.isEmpty ? 0 : meshFeatures.roadTrip.sendJoinAnswer(
            RoadTripJoinPayload(tripID: trip.id, joins: false, left: true), to: linked)
        FernletAuditLog.log("worldMap.roadTrip.left", context: ["told": "\(told)"])
        return true
    }

    /// "End the road trip": it ends here, and for everyone at their next catch-up — at once for the members linked in
    /// this hangout. Whether it was written.
    func endRoadTrip(now: Date = Date()) -> Bool {
        guard !duressSessionActive else { return false }
        let linked = roadTripCatchUpMembers().linked
        guard worldFog.roadTrip.end(now: now) else { return false }
        let told = linked.isEmpty ? 0 : meshFeatures.roadTrip.offerCatchUp(to: linked)
        FernletAuditLog.log("worldMap.roadTrip.ended", context: ["told": "\(told)"])
        return true
    }

    /// DEBUG ``RoadTripTestScenes`` (`roadTrip`, `roadTripPassenger`): with no trip on, starts the staged one and its
    /// staged line, written to the vault like a real trip, so the chip, Trip info, recording and the passenger gate
    /// can be tried. Never in a decoy; a no-op without the scene (always in release builds, whose scene list is empty).
    func stageRoadTripTestScene(now: Date = Date()) {
        guard RoadTripTestScenes.stagesTrip, !duressSessionActive else { return }
        let keeper = worldFog.roadTrip
        keeper.load()
        guard keeper.active == nil else { return }
        let trip = RoadTripTestScenes.trip(now: now, passenger: RoadTripTestScenes.asPassenger)
        guard keeper.start(trip) else {
            FernletAuditLog.log("worldMap.roadTrip.testSceneRefused")
            return
        }
        let kept = keeper.appendLine(RoadTripTestScenes.line(startingAt: trip.startedAt.addingTimeInterval(15 * 60)))
        FernletAuditLog.log("worldMap.roadTrip.testSceneStaged", context: ["points": "\(kept)"])
    }
}
