import FernletFoundation
import Foundation
import WorldMapStore

/// The visit to a place to eat the person is on now (in memory only, never kept): the place's id and
/// Apple's reference, where they stood, when the visit began and when they were last seen there. Meals
/// logged from a little before it began until an hour and a half after the last sighting count there.
nonisolated struct WorldEatingVisit: Equatable, Sendable {
    /// How long before the visit began a meal still counts (logged at the door).
    static let leadIn: TimeInterval = 15 * 60
    /// How long after the last sighting a meal still counts (logged at the table, map closed).
    static let tail: TimeInterval = 90 * 60

    let id: UUID
    let placeID: String
    let point: GeoPoint
    let since: Date
    var lastSeen: Date

    /// Whether a meal logged at `date` was logged during this visit.
    func covers(_ date: Date) -> Bool {
        date >= since.addingTimeInterval(-Self.leadIn) && date <= lastSeen.addingTimeInterval(Self.tail)
    }
}

/// A meal as the keeper notes it at a place to eat: its id, its name and when it was logged.
nonisolated struct WorldLoggedMeal: Equatable, Sendable {
    let id: UUID
    let name: String
    let loggedAt: Date
}

extension WorldPlacesKeeper {
    // MARK: Homes and hotels (ref-home-*, ref-hotel)

    /// Checks a reading or a visit against the homes and hotel: leaving and getting back join the timeline
    /// (with "Remember places I stop at" on), getting home after an hour away leaves Sprout a greeting, and
    /// getting home ends a hotel stay. Nothing without a home or hotel, nothing in a decoy.
    func observeHomes(_ point: GeoPoint, at date: Date, departed: Date? = nil) {
        guard !isDecoy else { return }
        let stopsToo = remembersPlaces()
        update { state in
            guard !state.homeBook.bases.isEmpty else { return state }
            let seen = state.homeBook.observing(point, at: date, departed: departed)
            var next = state.withHomes(seen.book)
            for move in seen.moves where stopsToo {
                next = next.appending(PlaceStop(kind: move.left ? .leftHome : .cameHome, at: move.at, placeID: move.placeID))
            }
            return next
        }
    }

    /// The greeting waiting for the map while the person is still there, with its home or hotel; it is
    /// said once (taken off the device side). Nil in a decoy or with none waiting.
    func takeGreeting() -> (greeting: HomeGreeting, place: HomePlace)? {
        guard !isDecoy, homes.presence.greeting != nil else { return nil }
        var taken: (greeting: HomeGreeting, place: HomePlace)?
        update { state in
            let result = state.homeBook.takingGreeting()
            guard let greeting = result.greeting, let place = result.book.place(greeting.placeID) else { return state }
            taken = (greeting, place)
            return state.withHomes(result.book)
        }
        return taken
    }

    /// Saves `home` (a new one, or one moved or renamed), replacing the home `replacing` when two are kept.
    /// Whether it was saved.
    @discardableResult
    func saveHome(_ home: HomePlace, replacing: UUID? = nil) -> Bool {
        guard !isDecoy else { return false }
        return update { $0.withHomes($0.homeBook.savingHome(home, replacing: replacing)) }
    }

    /// Checks in at `hotel` (or renames or moves the current one). Whether it was saved.
    @discardableResult
    func checkIn(_ hotel: HomePlace) -> Bool {
        guard !isDecoy else { return false }
        return update { $0.withHomes($0.homeBook.checkingIn(hotel)) }
    }

    /// Ends the hotel stay; the hotel is remembered for a welcome back. Whether it changed.
    @discardableResult
    func checkOut() -> Bool {
        guard !isDecoy else { return false }
        return update { $0.withHomes($0.homeBook.checkedOut) }
    }

    /// Removes the home or hotel `id` (forgotten, not remembered). Whether it changed.
    @discardableResult
    func removeHome(_ id: UUID) -> Bool {
        guard !isDecoy else { return false }
        return update { $0.withHomes($0.homeBook.removing(id)) }
    }

    // MARK: A place the person adds (ref-tag-name, ref-tag-photo)

    /// Adds a place the person named themselves at `point` (a spot Fernlet refused, or the spot of a photo
    /// they put on the map): it joins their places as any other, with a visit at `date` (they were there),
    /// known for later visits, in Where you've been, renamed or deleted there. A place already known that
    /// near gets the visit instead. Never Apple's name; no reference. Whether it was kept.
    @discardableResult
    func remember(_ name: String, at point: GeoPoint, date: Date) -> Bool {
        guard !isDecoy, point.isValid, let label = PlaceRecord.validLabel(name) else { return false }
        refusedSpot = nil
        return update { state in
            if let known = state.knownPlace(near: point) { return state.recordingVisit(to: known.id, at: date) }
            return state.learning(PlaceRecord(label: label, point: point), at: date)
        }
    }

    // MARK: Places to eat ("Remember places I eat out")

    /// Begins (or goes on with) a visit to the place to eat Apple refers to as `placeID`, decided on the
    /// device at this moment; with none, a visit elsewhere ends it.
    func startEatingVisit(_ placeID: String?, at point: GeoPoint, now: Date) {
        guard let placeID, remembersEatingOut(), !isDecoy else { return }
        eatsAt[placeID] = true
        if var visit = eatingVisit, visit.placeID == placeID {
            visit.lastSeen = now
            eatingVisit = visit
            return
        }
        let known: KnownPlace?
        do {
            known = try store.deviceState().knownPlace(withPlaceID: placeID)
        } catch {
            known = nil
        }
        let kept = eatingPlaces.first { $0.placeID == placeID }
        eatingVisit = WorldEatingVisit(id: kept?.id ?? known?.id ?? UUID(), placeID: placeID, point: known?.point ?? point,
                                       since: now, lastSeen: now)
    }

    /// A reading on the map: still at the place to eat (seen again), or gone from it (the visit stays in
    /// memory so a meal logged soon after still counts, until another visit begins).
    func followEatingVisit(_ point: GeoPoint, now: Date) {
        guard var visit = eatingVisit, visit.point.distance(to: point) <= EatingPlace.atRadius else { return }
        visit.lastSeen = now
        eatingVisit = visit
    }

    /// A visit at a known place: when its reference is a place to eat (asked by reference once a session,
    /// held in memory only), it begins a visit there.
    func knownPlaceVisited(_ place: KnownPlace, at point: GeoPoint, now: Date) {
        guard remembersEatingOut(), !isDecoy, let placeID = place.placeID else { return }
        if let eats = eatsAt[placeID] {
            if eats { startEatingVisit(placeID, at: point, now: now) }
            return
        }
        let lookup = lookup
        Task { [weak self] in
            let name = await lookup.placeName(for: placeID)
            guard let self, !self.isDecoy else { return }
            let eats = name?.category == .foodAndDrink
            self.eatsAt[placeID] = eats
            if eats { self.startEatingVisit(placeID, at: point, now: now) }
        }
    }

    /// Notes the meals among `meals` logged during the visit to a place to eat now under way (or just
    /// ended), each once. Nothing with "Remember places I eat out" off, or in a decoy. Whether any was noted.
    @discardableResult
    func noteMeals(_ meals: [WorldLoggedMeal], now: Date = Date()) -> Bool {
        guard !isDecoy, remembersEatingOut(), let visit = eatingVisit else { return false }
        let during = meals.filter { visit.covers($0.loggedAt) && $0.loggedAt <= now }
        guard !during.isEmpty else { return false }
        return update { state in
            during.reduce(state) { next, meal in
                next.notingMeal(EatingMeal(id: meal.id, name: meal.name), at: visit.id, placeID: visit.placeID, point: visit.point)
            }
        }
    }

    /// Asks Apple Maps again, by reference, for the name of each favourite place to eat the person hasn't
    /// named, while the map is open (in memory only, at most ``EatingPlace/maxPlaces``, one at a time). A
    /// name that now reads as a place Fernlet never names is not shown.
    func resolveEatingNames() async {
        for place in eatingPlaces.prefix(EatingPlace.maxPlaces) where place.isFavourite && place.label == nil && eatingNames[place.id] == nil {
            guard !Task.isCancelled, !isDecoy else { return }
            if let name = await lookup.placeName(for: place.placeID)?.name, !isDecoy { eatingNames[place.id] = name }
        }
    }

    /// Gives the place to eat `id` the person's own name (a rename in Where you've been). Whether it changed.
    @discardableResult
    func renameEatingPlace(_ id: UUID, to name: String) -> Bool {
        guard !isDecoy else { return false }
        return update { $0.renamingEatingPlace(id, to: name) }
    }
}
