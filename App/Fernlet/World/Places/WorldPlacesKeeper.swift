import FernletFoundation
import Foundation
import WorldMapStore

/// Notes the places the person stops at, for "Where you've been" in Private (World build step 5c;
/// `b2-where-been`; owner's option A, 2026-10-24). It captures; Private reads, under the hub key.
///
/// - **While the map is open** (a precise reading of 50 m or better, the app in front): a reading within
///   75 m of a place already known is a visit there. Otherwise, at most once per 150 m moved or 30
///   minutes, the place lookup (``WorldPlaceLooking``) is asked about where the person stands, and the
///   device decides at that moment (``PlaceClassifier/visitVerdict(_:)``): an everyday place (food and drink,
///   gyms, parks, beaches, campgrounds) is learned with its name as the label it starts with and the
///   person's own point; anything else, a doctor's office, a lawyer or a therapist above all, is neither
///   named nor kept. Nothing from the lookup is stored but that.
/// - **With background mapping on**, iOS's low-power visits are matched on the phone against the places
///   already known, and nothing else: no lookup ever runs in the background, so a stop at a new place is
///   learned only once the person opens the map there.
/// - **Walks and runs** recorded on the map join the timeline with their length.
///
/// Captures wait in the device side (``PlaceDeviceState``, sealed under the map vault's buffer key) until
/// Private folds them under the hub key. Visits to one place within three hours count once.
///
/// **Duress.** In a decoy nothing is read or written (``setDecoy(_:)``); a lookup that returns after a decoy
/// opened is dropped. The wipes remove the files with the vault.
@MainActor
final class WorldPlacesKeeper {
    /// The worst accuracy a reading may have and still place a visit, in metres.
    static let maxAccuracy = 50.0
    /// How far the person must move from the last lookup before another, in metres.
    static let lookupMove = 150.0
    /// How long after the last lookup another may run where the person still stands.
    static let lookupSpacing: TimeInterval = 30 * 60
    /// The worst accuracy a background visit may have and still match a known place, in metres.
    static let maxVisitAccuracy = 200.0

    /// The sealed log and device side.
    let store: PlaceLogStore
    private let lookup: any WorldPlaceLooking
    private var lastLookup: (point: GeoPoint, at: Date)?
    private var isLookingUp = false
    /// Whether a decoy session is showing.
    private(set) var isDecoy = false

    /// A keeper over `vault`, asking `lookup` about new places.
    init(vault: WorldMapVault, lookup: any WorldPlaceLooking) {
        store = PlaceLogStore(vault: vault)
        self.lookup = lookup
    }

    /// Enters or leaves a decoy session: nothing is read or written while one shows.
    func setDecoy(_ on: Bool) {
        isDecoy = on
        lastLookup = nil
    }

    /// A reading taken while the map is open and the app in front: a visit at a known place, or a lookup
    /// when the rules allow one. Whether a visit was noted.
    @discardableResult
    func handleForeground(_ fix: WorldFix, now: Date = Date()) async -> Bool {
        guard !isDecoy, !isLookingUp, fix.isPrecise, fix.accuracy <= Self.maxAccuracy, fix.point.isValid else { return false }
        if let noted = noteKnownVisit(at: fix.point, now: now) { return noted }
        guard lookupIsDue(at: fix.point, now: now) else { return false }
        isLookingUp = true
        let nearby = await lookup.nearbyPlaces(around: fix.point)
        isLookingUp = false
        lastLookup = (fix.point, now)
        let verdict = nearby.map(PlaceClassifier.visitVerdict)
        // The outcome's shape only (never a name or a point), for the device pass.
        FernletAuditLog.log("worldMap.places.lookup", context: ["answered": nearby == nil ? "no" : "yes",
                                                                 "places": "\(nearby?.count ?? 0)",
                                                                 "verdict": Self.token(verdict)])
        guard !isDecoy, case .allowed(let category, let name) = verdict else { return false }
        return update { $0.knownPlace(near: fix.point) == nil
            ? $0.learning(PlaceRecord(name: name, category: category, point: fix.point), at: now)
            : $0 }
    }

    /// A low-power visit from iOS: noted only at a place already known.
    @discardableResult
    func handleVisit(_ visit: WorldVisit) -> Bool {
        guard !isDecoy, visit.accuracy <= Self.maxVisitAccuracy else { return false }
        return noteKnownVisit(at: visit.point, now: visit.arrived) ?? false
    }

    /// A walk or run recorded on the map joins the timeline (`at` is when it started).
    @discardableResult
    func recordOuting(_ kind: PlaceStop.Kind, at date: Date, metres: Double, workoutID: UUID?) -> Bool {
        guard !isDecoy, kind != .visit, metres.isFinite else { return false }
        return update { $0.appending(PlaceStop(kind: kind, at: date, metres: max(0, metres), workoutID: workoutID)) }
    }

    /// A verdict's audit token: its kind alone.
    static func token(_ verdict: PlaceVerdict?) -> String {
        switch verdict {
        case .allowed(let category, _): "allowed.\(category.rawValue)"
        case .refused: "refused"
        case .unnamed: "unnamed"
        case nil: "none"
        }
    }

    /// Forgets the in-memory lookup spacing (the wipes).
    func forget() {
        lastLookup = nil
    }

    /// A visit at the known place within 75 m of `point`, if there is one: true when it was noted, false
    /// when it counts as the visit already noted, nil when no known place is that near (or none can be read).
    private func noteKnownVisit(at point: GeoPoint, now: Date) -> Bool? {
        let state: PlaceDeviceState
        do {
            state = try store.deviceState()
        } catch {
            return nil
        }
        guard let place = state.knownPlace(near: point) else { return nil }
        lastLookup = (point, now)
        let next = state.recordingVisit(to: place.id, at: now)
        guard next != state else { return false }
        return save(next)
    }

    /// Whether a lookup may run at `point` now: the first, or after moving far enough, or after long enough.
    private func lookupIsDue(at point: GeoPoint, now: Date) -> Bool {
        guard let lastLookup else { return true }
        return lastLookup.point.distance(to: point) >= Self.lookupMove || now.timeIntervalSince(lastLookup.at) >= Self.lookupSpacing
    }

    /// Reads the device side, applies `change` and saves it when it changed. Whether it was saved.
    private func update(_ change: (PlaceDeviceState) -> PlaceDeviceState) -> Bool {
        do {
            let state = try store.deviceState()
            let next = change(state)
            guard next != state else { return false }
            return save(next)
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
}
