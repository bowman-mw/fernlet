import FernletFoundation
import Foundation
import Observation
import WorldMapStore

/// Notes the places the person stops at, for "Where you've been" in Private (World build step 5c;
/// `b2-where-been`; owner's option A, 2026-10-24). It captures; Private reads, under the hub key.
///
/// - **While Fernlet is open** (a precise reading of 50 m or better, the app in front), **once the person has
///   stopped** (W-13: stayed within 50 m for three minutes, or three readings slower than walking over a
///   minute after walking; W-14: after a drive, five minutes within 30 m, decided where they dwelt;
///   ``WorldStopWatch``; readings on the way are passed by): a reading within 75 m of a place already known is
///   a visit there. Otherwise, at most once per 150 m moved or 30
///   minutes, the place lookup (``WorldPlaceLooking``) is asked about where the person stands, and the
///   device decides at that moment (``PlaceClassifier/visitVerdict(_:)``): an everyday place (food and drink,
///   gyms, parks, beaches, campgrounds) is learned with the person's own point and the lookup's reference to
///   it (a place already known by that reference is a visit there); anything else, a doctor's office, a
///   lawyer or a therapist above all, is not kept. Nothing from the lookup is stored but that: never the
///   place's name or kind (World build round 5, the MapKit terms).
/// - **With background mapping on**, iOS's low-power visits are matched on the phone against the places
///   already known, and nothing else: no lookup ever runs in the background, so a stop at a new place is
///   learned only once the person opens the map there.
/// - **Walks and runs** recorded on the map join the timeline with their length, and **bike rides**
///   Fernlet logged with theirs when known (Refinements group 19, `ref-ride-timeline`).
///
/// **Round 6** (owner-approved 2026-10-25):
/// - **Remember this place** (`ref-tag-home`; round 7, draft 2: anywhere the person stays): once they have
///   stopped somewhere for more than 2 minutes that isn't a home, a hotel or a place they keep, the spot is
///   offered in memory only (``rememberSpot``, ``WorldRememberSpot``) until they move on. Nothing is kept
///   unless they add it (``remember(_:named:at:date:)``); "Not here" keeps a quiet "don't ask here"
///   (``WorldPlaceMarks``) except at a spot Fernlet won't name, where it only hides the button.
/// - **Homes and hotels** (`ref-home-*`): every reading and visit is checked against them on the phone
///   (``observeHomes(_:at:departed:)``); leaving and getting back join the timeline, getting home after an
///   hour away leaves Sprout a greeting, and no visit is ever noted at a home or a hotel.
/// - **Places to eat** ("Remember places I eat out", `b1-qs-food`): a visit the device decides is at a
///   food-and-drink place (by Apple's reference) is held in memory (``eatingVisit``), and meals logged
///   during it are noted there (``noteMeals(_:now:)``).
///
/// With "Remember places I stop at" off (Settings › Home map, ``WorldMapPreferences/remembersPlaces(in:)``)
/// nothing new is noted in Where you've been; with "Remember places I eat out" off no meal is noted. A lookup
/// runs only while one of them is on. What is already kept stays until it is deleted.
///
/// Captures wait in the device side (``PlaceDeviceState``, sealed under the map vault's buffer key) until
/// Private folds them under the hub key. Visits to one place within three hours count once.
///
/// **Duress.** In a decoy nothing is read or written (``setDecoy(_:)``); a lookup that returns after a decoy
/// opened is dropped. The wipes remove the files with the vault.
@MainActor
@Observable
final class WorldPlacesKeeper {
    /// The worst accuracy a reading may have and still place a visit, in metres.
    static let maxAccuracy = 50.0
    /// How far the person must move from the last lookup before another, in metres.
    static let lookupMove = 150.0
    /// How long after the last lookup another may run where the person still stands.
    static let lookupSpacing: TimeInterval = 30 * 60
    /// The worst accuracy a background visit may have and still match a known place, in metres.
    static let maxVisitAccuracy = 200.0
    /// The worst accuracy a reading may have and still say whether the person is home, in metres.
    static let maxHomeAccuracy = 100.0
    /// How far from the offered spot the person moves before "Remember this place" goes, in metres.
    static let rememberReach = 50.0

    /// The sealed log and device side.
    @ObservationIgnored let store: PlaceLogStore
    /// "Not here" and the places the person remembered (round 7).
    @ObservationIgnored let marks: WorldPlaceMarksStore
    @ObservationIgnored let lookup: any WorldPlaceLooking
    /// Whether "Remember places I stop at" is on now.
    @ObservationIgnored let remembersPlaces: () -> Bool
    /// Whether "Remember places I eat out" is on now.
    @ObservationIgnored let remembersEatingOut: () -> Bool
    @ObservationIgnored private var lastLookup: (point: GeoPoint, at: Date)?
    @ObservationIgnored private var isLookingUp = false
    /// Whether the person has stopped (W-13); in memory only.
    @ObservationIgnored private(set) var stopWatch = WorldStopWatch()
    /// The check that runs once the person may have stayed long enough, with no new reading to say so (the
    /// map's 10 m filter sends none while they sit still).
    @ObservationIgnored private var stopCheck: Task<Void, Never>?
    /// Whether that check may run when it comes due: the store's gate for a reading (the map's own location,
    /// the app in front, no decoy). Nil (a test) schedules none.
    @ObservationIgnored var mayRecheck: (() -> Bool)?
    /// Whether each place's reference read as food and drink when asked this session (in memory only).
    @ObservationIgnored var eatsAt: [String: Bool] = [:]
    /// Whether a decoy session is showing.
    private(set) var isDecoy = false
    /// The spot "Remember this place" offers while the person stays (`ref-tag-home`); in memory only.
    var rememberSpot: WorldRememberSpot?
    /// A spot Fernlet won't name whose button "Not here" hid until the person leaves (in memory only).
    @ObservationIgnored var hiddenSpot: GeoPoint?
    /// The places the person remembered, as last read or saved (the map draws a restaurant's or gym's icon).
    var keptPlaces: [WorldKeptPlace] = []
    /// The homes and hotel as last read or saved (the map draws them).
    var homes: HomeBook = .empty
    /// The places to eat as last read or saved (the map draws the favourites).
    var eatingPlaces: [EatingPlace] = []
    /// The place to eat the person is at now, while the map follows them (in memory only).
    @ObservationIgnored var eatingVisit: WorldEatingVisit?
    /// The favourite places to eat's names as Apple Maps gave them again by reference while the map was
    /// open, by place id (in memory only; the MapKit terms).
    var eatingNames: [UUID: String] = [:]

    /// A keeper over `vault`, asking `lookup` about new places while `remembersPlaces` or
    /// `remembersEatingOut` says so (by default, the Home map switches on this iPhone).
    init(vault: WorldMapVault, lookup: any WorldPlaceLooking,
         remembersPlaces: @escaping () -> Bool = { WorldMapPreferences.remembersPlaces() },
         remembersEatingOut: @escaping () -> Bool = { WorldMapPreferences.remembersEatingOut() }) {
        store = PlaceLogStore(vault: vault)
        marks = WorldPlaceMarksStore(vault: vault)
        self.lookup = lookup
        self.remembersPlaces = remembersPlaces
        self.remembersEatingOut = remembersEatingOut
    }

    /// The stop check goes with the keeper.
    isolated deinit {
        stopCheck?.cancel()
    }

    /// Enters or leaves a decoy session: nothing is read or written while one shows, and no name is held.
    func setDecoy(_ on: Bool) {
        isDecoy = on
        forget()
        if !on { reloadDeviceSide() }
    }

    /// A reading taken while Fernlet is open and in front: home or away, then a visit at a known
    /// place, or a lookup when the rules allow one. `recheck`: no new reading, only the check that the
    /// person is still where the last one was (`scheduleStopCheck`). Whether a visit was noted.
    @discardableResult
    func handleForeground(_ fix: WorldFix, now: Date = Date(), recheck: Bool = false) async -> Bool {
        guard !isDecoy, fix.point.isValid else { return false }
        if fix.isPrecise, fix.accuracy <= Self.maxHomeAccuracy { observeHomes(fix.point, at: now) }
        followEatingVisit(fix.point, now: now)
        followRememberSpot(fix.point)
        guard remembersPlaces() || remembersEatingOut(), fix.isPrecise, fix.accuracy <= Self.maxAccuracy else { return false }
        // W-13, W-14: only where the person has stopped, decided at the stop's own spot (after a drive, where
        // they dwelt). Readings on the way (a drive and its red lights, a walk past a pharmacy) look nothing
        // up, note no visit and leave the lookup spacing alone.
        let stopped = recheck ? stopWatch.isStopped(at: now) : stopWatch.observe(fix.point, speed: fix.speed, inCar: fix.inCar, at: now)
        guard stopped, let point = stopWatch.stopPoint else {
            scheduleStopCheck(fix, now: now)
            return false
        }
        guard !isLookingUp, homes.base(near: point) == nil else { return false }
        if let noted = noteKnownVisit(at: point, now: now) { return noted }
        guard lookupIsDue(at: point, now: now) else { return false }
        isLookingUp = true
        let nearby = await lookup.nearbyPlaces(around: point)
        isLookingUp = false
        lastLookup = (point, now)
        let verdict = nearby.map(PlaceClassifier.visitVerdict)
        // The outcome's shape only (never a name, a reference or a point), for the device pass.
        FernletAuditLog.log("worldMap.places.lookup", context: ["answered": nearby == nil ? "no" : "yes",
                                                                 "places": "\(nearby?.count ?? 0)",
                                                                 "verdict": Self.token(verdict)])
        guard !isDecoy else { return false }
        if let verdict { offerSpot(WorldRememberSpot.kind(for: verdict, nearby: nearby ?? []), at: point, now: now) }
        var noted = false
        if remembersPlaces(), case .allowed(let placeID) = verdict {
            noted = update { state in
                if let known = state.knownPlace(withPlaceID: placeID) { return state.recordingVisit(to: known.id, at: now) }
                guard state.knownPlace(near: point) == nil else { return state }
                return state.learning(PlaceRecord(placeID: placeID, point: point), at: now)
            }
        }
        // After the visit is learned, so a place to eat shares its place's id.
        startEatingVisit(nearby.flatMap(PlaceClassifier.eatingPlaceID), at: point, now: now)
        return noted
    }

    /// A low-power visit from iOS: home or away, then a visit noted only at a place already known.
    @discardableResult
    func handleVisit(_ visit: WorldVisit) -> Bool {
        guard !isDecoy, visit.accuracy <= Self.maxVisitAccuracy else { return false }
        if visit.accuracy <= Self.maxHomeAccuracy { observeHomes(visit.point, at: visit.arrived, departed: visit.departed) }
        // Round 7 (`ref-tag-how`, background mapping on): still there, the stay counts from the arrival.
        if visit.departed == nil, visit.accuracy <= Self.maxHomeAccuracy { stopWatch.seed(visit.point, since: visit.arrived) }
        guard remembersPlaces(), homes.base(near: visit.point) == nil else { return false }
        return noteKnownVisit(at: visit.point, now: visit.arrived) ?? false
    }

    /// A walk or run recorded on the map, or a bike ride Fernlet logged (Refinements group 19), joins the
    /// timeline (`at` is when it started). A walk or run needs its length; a ride's is optional (nil when the
    /// readings couldn't say).
    @discardableResult
    func recordOuting(_ kind: PlaceStop.Kind, at date: Date, metres: Double?, workoutID: UUID?) -> Bool {
        guard !isDecoy, remembersPlaces(), kind == .walk || kind == .run || kind == .ride else { return false }
        guard kind == .ride || metres?.isFinite == true else { return false }
        let length = metres.flatMap { $0.isFinite ? max(0, $0) : nil }
        return update { $0.appending(PlaceStop(kind: kind, at: date, metres: length, workoutID: workoutID)) }
    }

    /// Takes the waiting walk, run or bike ride whose workout is `workoutID` off the timeline (a bike ride's
    /// note's Undo). Nothing in a decoy. Whether one was removed.
    @discardableResult
    func removeOuting(workoutID: UUID) -> Bool {
        guard !isDecoy else { return false }
        return update { $0.removingOuting(workoutID: workoutID) }
    }

    /// A verdict's audit token: its kind alone (never the place's kind, name or reference).
    static func token(_ verdict: PlaceVerdict?) -> String {
        switch verdict {
        case .allowed(let placeID): placeID == nil ? "allowed.noReference" : "allowed"
        case .refused: "refused"
        case .unnamed: "unnamed"
        case nil: "none"
        }
    }

    /// Forgets what is held in memory: the lookup spacing, the offered spot, the visit to a place to eat,
    /// the homes and places drawn, and every place name asked for again (the wipes, Delete all of it, a
    /// decoy).
    func forget() {
        lastLookup = nil
        stopWatch = WorldStopWatch()
        stopCheck?.cancel()
        stopCheck = nil
        rememberSpot = nil
        hiddenSpot = nil
        keptPlaces = []
        eatingVisit = nil
        eatsAt = [:]
        homes = .empty
        eatingPlaces = []
        eatingNames = [:]
        lookup.forgetNames()
    }

    /// The name and kind of `place` as the lookup gives them again by its reference (in memory only), or
    /// nil: no reference, no answer, or a decoy.
    func name(of place: PlaceRecord) async -> WorldPlaceName? {
        guard !isDecoy, let placeID = place.placeID else { return nil }
        return await lookup.placeName(for: placeID)
    }

    /// A visit at the known place within 75 m of `point`, if there is one: true when it was noted, false
    /// when it counts as the visit already noted (or "Remember places I stop at" is off), nil when no known
    /// place is that near (or none can be read).
    private func noteKnownVisit(at point: GeoPoint, now: Date) -> Bool? {
        let state: PlaceDeviceState
        do {
            state = try store.deviceState()
        } catch {
            return nil
        }
        guard let place = state.knownPlace(near: point) else { return nil }
        lastLookup = (point, now)
        offerKnownSpot(place, at: point, now: now)
        knownPlaceVisited(place, at: point, now: now)
        guard remembersPlaces() else { return false }
        let next = state.recordingVisit(to: place.id, at: now)
        guard next != state else { return false }
        return save(next)
    }

    /// Asks again once the person will have stayed at `fix` long enough to count as stopped, in case no
    /// reading comes to say so; a newer reading replaces the check. Runs only under the store's gate.
    private func scheduleStopCheck(_ fix: WorldFix, now: Date) {
        stopCheck?.cancel()
        stopCheck = nil
        guard let mayRecheck, let wait = stopWatch.timeToStop(at: now) else { return }
        stopCheck = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(wait + 1))
            } catch {
                return
            }
            guard let self, mayRecheck() else { return }
            let still = WorldFix(point: fix.point, accuracy: fix.accuracy, at: Date(), isPrecise: fix.isPrecise)
            await self.handleForeground(still, recheck: true)
        }
    }

    /// Whether a lookup may run at `point` now: the first, or after moving far enough, or after long enough.
    private func lookupIsDue(at point: GeoPoint, now: Date) -> Bool {
        guard let lastLookup else { return true }
        return lastLookup.point.distance(to: point) >= Self.lookupMove || now.timeIntervalSince(lastLookup.at) >= Self.lookupSpacing
    }

    /// Reads the device side, applies `change` and saves it when it changed. Whether it was saved.
    @discardableResult
    func update(_ change: (PlaceDeviceState) -> PlaceDeviceState) -> Bool {
        do {
            let state = try store.deviceState()
            let next = change(state)
            guard next != state else { return false }
            guard save(next) else { return false }
            homes = next.homeBook
            eatingPlaces = next.eatingPlaces
            return true
        } catch {
            FernletAuditLog.log("worldMap.places.captureDeferred")
            return false
        }
    }

    /// Seals `state`. Whether it was written.
    private func save(_ state: PlaceDeviceState) -> Bool {
        do {
            try store.saveDeviceState(state)
            return true
        } catch {
            FernletAuditLog.log("worldMap.places.captureDeferred")
            return false
        }
    }

    /// Reads the homes and places to eat again (the map coming to the front); none in a decoy.
    func reloadDeviceSide() {
        guard !isDecoy else { return }
        do {
            let state = try store.deviceState()
            homes = state.homeBook
            eatingPlaces = state.eatingPlaces
        } catch {
            FernletAuditLog.log("worldMap.places.readDeferred")
        }
        if let read = marks.read() { keptPlaces = read.kept }
    }
}
