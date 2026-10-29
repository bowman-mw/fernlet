import FernletFoundation
import Foundation
import WorldMapStore

extension PlaceDeviceState {
    /// This state with the place `id`, still waiting for Private's fold, given the person's own `label`;
    /// unchanged with no label or when the place is already folded (only Private, open, renames it there).
    func labelling(_ id: UUID, _ label: String?) -> PlaceDeviceState {
        guard let label, let index = newPlaces.firstIndex(where: { $0.id == id }) else { return self }
        var next = self
        next.newPlaces[index].label = label
        return next
    }

    /// Whether the place `id` still waits for Private's fold.
    func isPending(_ id: UUID) -> Bool {
        newPlaces.contains { $0.id == id }
    }
}

extension WorldPlacesKeeper {
    // MARK: Remember this place, anywhere (round 7: ref-tag-home d2, ref-tag-how, ref-tag-named)

    /// The offered spot while it shows: the person has stayed there more than 2 minutes and stands within
    /// ``rememberReach`` of it. Nil otherwise, or in a decoy.
    func shownRememberSpot(near point: GeoPoint?, now: Date) -> WorldRememberSpot? {
        guard !isDecoy, let spot = rememberSpot, let point, spot.point.distance(to: point) <= Self.rememberReach,
              spot.isDue(at: now) else { return nil }
        return spot
    }

    /// The offered spot when it is one Fernlet won't name, as draft 1 held it: its point and when the stay
    /// began. Nil anywhere else.
    var refusedSpot: (point: GeoPoint, at: Date)? {
        guard let spot = rememberSpot, spot.kind == .refused else { return nil }
        return (spot.point, spot.since)
    }

    /// A reading: more than ``rememberReach`` from the offered spot, it goes (nothing kept), and a spot
    /// "Not here" hid is free to ask again once the person has left it.
    func followRememberSpot(_ point: GeoPoint) {
        if let spot = rememberSpot, spot.point.distance(to: point) > Self.rememberReach { rememberSpot = nil }
        if let hidden = hiddenSpot, hidden.distance(to: point) > Self.rememberReach { hiddenSpot = nil }
    }

    /// Offers the spot at `point` where the person has stopped, as a lookup decided it (`kind`): never with
    /// "Remember places I stop at" off, never at a home or hotel (the caller's guard), a place they keep (one
    /// they remembered, or a favourite place to eat with its icon), a "Not here" spot, or one "Not here" hid.
    /// A spot already offered there stays as it is.
    func offerSpot(_ kind: WorldRememberSpot.Kind, at point: GeoPoint, now: Date) {
        guard !isDecoy, remembersPlaces() else { return }
        if let spot = rememberSpot, spot.point.distance(to: point) <= Self.rememberReach { return }
        guard mayOffer(at: point) else { return }
        rememberSpot = WorldRememberSpot(point: point, since: stopWatch.stayStart ?? now, kind: kind)
    }

    /// Offers a known place the person stopped at again: by Apple's reference, its name asked for again
    /// (held in memory only, the MapKit terms) so the sheet can fill it in. A known place with no reference
    /// is one the person added themselves, so it is kept already and nothing is offered.
    func offerKnownSpot(_ place: KnownPlace, at point: GeoPoint, now: Date) {
        guard let placeID = place.placeID else { return }
        let before = rememberSpot?.id
        offerSpot(.named(placeID: placeID, name: nil, category: nil), at: point, now: now)
        // Asked once, when the spot is first offered (every reading at a known place comes this way).
        guard let offered = rememberSpot, offered.id != before, offered.placeID == placeID else { return }
        let lookup = lookup
        Task { [weak self] in
            let named = await lookup.placeName(for: placeID)
            guard let self, !self.isDecoy, self.rememberSpot?.id == offered.id else { return }
            self.rememberSpot?.kind = .named(placeID: placeID, name: named?.name, category: named?.category)
        }
    }

    /// "Not here" (✕) on the offered spot: it goes, and at a spot Fernlet could name a quiet "don't ask
    /// here" is kept on this iPhone; at a spot it won't name, nothing can be kept, so it is only hidden until
    /// the person leaves. Nothing in a decoy.
    func dismissRememberSpot() {
        guard !isDecoy, let spot = rememberSpot else { return }
        rememberSpot = nil
        hiddenSpot = spot.point
        guard spot.isNameable, let current = marks.read() else { return }
        marks.save(current.addingQuiet(spot.point))
    }

    /// Remembers the offered `spot` under `name` at `point` (where the sheet's pin ended up), with a visit at
    /// `date`: Apple's name kept unchanged keeps only the reference (the name is asked for again when shown,
    /// round 5); a name the person typed or changed is kept as their own label. A place already known there
    /// gets the visit (and the label, while it still waits for Private). The place is marked kept, with a
    /// restaurant's or gym's icon at once. Nil when nothing was kept (no name, a decoy, unreadable).
    @discardableResult
    func remember(_ spot: WorldRememberSpot, named name: String, at point: GeoPoint, date: Date) -> WorldRememberOutcome? {
        guard !isDecoy, point.isValid, let label = PlaceRecord.validLabel(name) else { return nil }
        let placeID = spot.placeID
        let ownLabel: String? = placeID != nil && spot.appleName == label ? nil : label
        var kept: (id: UUID, point: GeoPoint, pending: Bool, isNew: Bool)?
        let saved = update { state in
            if let known = state.knownPlace(withPlaceID: placeID) ?? state.knownPlace(near: point) {
                kept = (known.id, known.point, state.isPending(known.id), false)
                return state.recordingVisit(to: known.id, at: date).labelling(known.id, ownLabel)
            }
            let record = PlaceRecord(label: ownLabel, placeID: placeID, point: point)
            kept = (record.id, point, true, true)
            return state.learning(record, at: date)
        }
        // A new place that wasn't written was not kept; a known one is kept whether or not its visit counted.
        guard let kept, saved || !kept.isNew else { return nil }
        if rememberSpot?.id == spot.id { rememberSpot = nil }
        markKept(WorldKeptPlace(id: kept.id, point: kept.point, placeID: placeID, icon: .of(spot.category), label: ownLabel))
        return WorldRememberOutcome(placeID: kept.id, pendingRename: kept.pending ? nil : ownLabel)
    }

    /// Gives the remembered place `id` the person's own name on the map too (a rename in Where you've been).
    func renameKeptPlace(_ id: UUID, to name: String) {
        guard !isDecoy, keptPlaces.contains(where: { $0.id == id }), let current = marks.read() else { return }
        let next = current.renaming(id, to: name)
        if next != current, marks.save(next) { keptPlaces = next.kept }
    }

    /// Asks Apple Maps again, by reference, for the names of the remembered restaurants and gyms the person
    /// didn't rename (in memory only, one at a time, at most ``WorldPlaceMarks/maxKept``), for their icons'
    /// name tags.
    func resolveKeptNames() async {
        for place in keptPlaces.prefix(WorldPlaceMarks.maxKept) where place.icon != nil && place.label == nil && eatingNames[place.id] == nil {
            guard !Task.isCancelled, !isDecoy else { return }
            guard let placeID = place.placeID else { continue }
            if let name = await lookup.placeName(for: placeID)?.name, !isDecoy { eatingNames[place.id] = name }
        }
    }

    /// Removes every mark ("Delete all of it", the app-lock reset). Whether the file is gone.
    @discardableResult
    func removeMarks() -> Bool {
        keptPlaces = []
        return marks.removeAll()
    }

    /// Whether the button may ask at `point`: no remembered place or favourite place to eat there, no "Not
    /// here" spot, and no spot "Not here" hid; nothing when the marks can't be read right now.
    private func mayOffer(at point: GeoPoint) -> Bool {
        if let hiddenSpot, hiddenSpot.distance(to: point) <= Self.rememberReach { return false }
        guard eatingPlaces.favourite(near: point) == nil, let read = marks.read() else { return false }
        keptPlaces = read.kept
        return !read.isKept(near: point) && !read.isQuiet(near: point)
    }

    /// Marks `place` kept, so the button won't ask there again and its icon shows at once.
    private func markKept(_ place: WorldKeptPlace) {
        guard let current = marks.read() else { return }
        let next = current.keeping(place)
        if marks.save(next) { keptPlaces = next.kept }
    }
}
