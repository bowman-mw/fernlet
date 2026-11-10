import FernletFoundation
import Foundation
import WorldMapStore

/// This iPhone's side of a road trip (World-RoadTrip-Spec, owner-approved 2026-11-10; PR 1, "Trip core"): the trip on
/// now, who maps, and the timed line this iPhone records while it maps. Owned by the fog keeper
/// (`WorldFogKeeper.roadTrip`), like the passport and the week's corner, so it hears exactly the readings the fog
/// accepts, follows the decoy and goes with every wipe.
///
/// - **Recording** (``record(_:saveNow:)``): while a trip is on and this iPhone maps, each reading the fog keeper
///   accepted (precise, within 65 m) joins the line, thinned to ``RoadTripLine/minSpacing``. The store's readings and
///   the locked launch's (`WorldLockedMapping`) both reach it through the fog keeper, so the line grows with the phone
///   in a pocket: it is sealed under the buffer key (`RoadTripStore`). With the app in front, the open piece is
///   written every ``saveEvery`` points and when the app leaves the front (the fog keeper's flush); with the app
///   behind (`saveNow`), at once, since iOS may end a suspended app.
/// - **Passengers** (``isPassenger``): a trip on that another member's iPhone maps. ``onPassengerChanged`` tells the
///   location source, which then traces no drive (`WorldLocationSource.setRoadTripPassenger(_:)`).
/// - **Who maps** (``mapFromThisPhone(states:now:)``, ``applyMapperRule(states:)``): ``RoadTripMapperRule``. A
///   catch-up (PR 2) feeds the other members' states through ``change(_:_:)`` and ``RoadTripCatchUpRules``.
/// - **Leave and End** (``leave(now:)``, ``end(now:)``): the record and its line stay, sealed, for the passport's trips
///   (PR 4), until map history is deleted. An end is owed to every other member until a catch-up tells them (PR 2).
/// - **The swap** (PR 2): ``trip(sharedWith:id:)`` finds the trip a catch-up is about, ``linePoints(of:after:through:)``
///   reads the road to send, and ``appendReceived(_:to:)`` adds received road to the line by its own rules.
/// - **Duress:** a decoy (``setDecoy(_:)``) shows no trip, records nothing and reads or writes no file; the real book
///   is dropped from memory while it lasts.
/// - **Wipes:** ``forget()`` drops everything in memory, unsaved points included; the vault's ``WorldMapVault/clearAll()``
///   removes the files.
///
/// Bounded (Power of 10): one open piece of at most ``RoadTripLine/chunkSize`` points in memory, at most
/// ``RoadTripLine/maxChunks`` pieces a trip (past it a point is refused and counted) and ``RoadTripBook/maxTrips`` trips.
@MainActor
@Observable
final class RoadTripKeeper {
    /// The worst accuracy a reading may have to join the line, in metres (the fog's own limit).
    static let maxAccuracy = WorldFogKeeper.maxAccuracy
    /// New points between writes of the open piece while the app is in front.
    static let saveEvery = 20

    /// The trips as last read or saved; empty in a decoy.
    private(set) var book: RoadTripBook = .empty
    /// Whether the book has been read this session (never in a decoy).
    private(set) var isLoaded = false
    /// Whether a decoy session is showing.
    private(set) var isDecoy = false
    /// Points refused because the line was full (an audit count; never shown).
    @ObservationIgnored private(set) var refusedCount = 0
    /// Called when this iPhone becomes a passenger (true) or stops being one (false).
    @ObservationIgnored var onPassengerChanged: ((Bool) -> Void)?

    @ObservationIgnored private let store: RoadTripStore
    @ObservationIgnored private var toldPassenger = false
    @ObservationIgnored private var line = OpenLine()

    /// The trip's line as this keeper holds it: the open (last) piece, and what came before it once asked for.
    private struct OpenLine {
        /// The trip the line belongs to; nil before it is opened.
        var trip: UUID?
        /// The open piece's number.
        var chunk = 0
        /// The open piece's points.
        var tail: [RoadTripPoint] = []
        /// Points in the open piece not yet written.
        var unsaved = 0
        /// The last kept point, which the next is measured from.
        var last: RoadTripPoint?
        /// The pieces before the open one: their length and last point, read the first time the length is asked.
        var finished: (metres: Double, last: RoadTripPoint?)?
    }

    /// A keeper over `vault`. Call ``load()`` before reading the trip.
    init(vault: WorldMapVault) {
        store = RoadTripStore(vault: vault)
    }

    /// The trip on now; nil with none, before the book is read, and in a decoy.
    var active: RoadTrip? { isDecoy ? nil : book.active }
    /// Whether this iPhone maps the trip on now.
    var isMapping: Bool { active?.isMapping ?? false }
    /// Whether a trip is on that another member's iPhone maps.
    var isPassenger: Bool { active.map { !$0.isMapping } ?? false }
    /// How many points the trip's line has on this iPhone.
    var pointCount: Int {
        guard let trip = active, line.trip == trip.id else { return 0 }
        return line.chunk * RoadTripLine.chunkSize + line.tail.count
    }

    /// Reads the book and opens the trip's line, once; a no-op in a decoy. While the key can't be read (before the
    /// first unlock since the phone started) it waits for the next call.
    func load() {
        guard !isLoaded, !isDecoy else { return }
        do {
            book = try store.readBook()
        } catch {
            FernletAuditLog.log("worldMap.roadTrip.loadDeferred")
            return
        }
        isLoaded = true
        openLine()
        tellPassenger()
    }

    /// Writes what is unsaved and reads everything again (the store adopting the locked launch's location, whose own
    /// keeper wrote the line meanwhile).
    func reload() {
        flush()
        isLoaded = false
        line = OpenLine()
        load()
    }

    /// A reading the fog keeper accepted: it joins the line while a trip is on and this iPhone maps. With `saveNow`
    /// (the app isn't in front) the open piece is written at once.
    func record(_ fix: WorldFix, saveNow: Bool = false) {
        guard !isDecoy, fix.isPrecise, fix.accuracy.isFinite, fix.accuracy <= Self.maxAccuracy else { return }
        load()
        guard let trip = active, trip.isMapping, append(RoadTripPoint(point: fix.point, at: fix.at), to: trip) else { return }
        guard saveNow || line.unsaved >= Self.saveEvery else { return }
        flush()
    }

    /// Adds `points` to the trip's line, by the same rules as a reading, and writes them; how many were kept. Used for
    /// a catch-up's road (``appendReceived(_:to:)``) and to stage a trip (DEBUG); a decoy or no trip keeps none.
    func appendLine(_ points: [RoadTripPoint]) -> Int {
        guard !isDecoy, let trip = active else { return 0 }
        var kept = 0
        for point in points.prefix(RoadTripLine.maxPoints) where append(point, to: trip) { kept += 1 }
        flush()
        return kept
    }

    /// Writes the open piece when it has unsaved points (the app leaving the front, a trip ending, a decoy starting).
    func flush() {
        guard !isDecoy, !saveTail() else { return }
        FernletAuditLog.log("worldMap.roadTrip.flushDeferred")
    }

    /// Starts `trip` on this iPhone (PR 2's Start and Join; the DEBUG scene). Whether it started: refused in a decoy,
    /// while another trip is on, when the trip isn't valid or the book is full, or when it couldn't be written.
    func start(_ trip: RoadTrip) -> Bool {
        guard !isDecoy else { return false }
        load()
        guard isLoaded, let next = book.adding(trip), store.saveBook(next) else { return false }
        book = next
        openLine()
        tellPassenger()
        return true
    }

    /// "Map from this iPhone": this iPhone maps from now, until a stop where the rule answers otherwise. `states` is
    /// what is known of the members' phones (PR 1: this one's). Whether it changed anything.
    func mapFromThisPhone(states: [String: RoadTripDeviceState], now: Date = Date()) -> Bool {
        guard let trip = active, !trip.isMapping else { return false }
        let answer = RoadTripMapperRule.ruleAnswer(members: trip.memberIDs, starter: trip.starterID, states: states) ?? trip.starterID
        return changeActive { trip in
            trip.mapperID = trip.selfID
            trip.mapperOverride = RoadTripMapperOverride(memberID: trip.selfID, at: now, ruleAnswer: answer)
        }
    }

    /// Decides who maps from `states` (a catch-up's, in PR 2), keeping an override the rule still agrees with.
    /// Whether it was written.
    func applyMapperRule(states: [String: RoadTripDeviceState]) -> Bool {
        guard let trip = active,
              let decided = RoadTripMapperRule.mapper(members: trip.memberIDs, starter: trip.starterID, states: states,
                                                      override: trip.mapperOverride) else { return false }
        return changeActive { trip in
            trip.mapperID = decided.mapper
            trip.mapperOverride = decided.override
        }
    }

    /// "Leave the road trip": this iPhone leaves; the map and photos so far stay, and so do the record and its line.
    /// Whether it was written.
    func leave(now: Date = Date()) -> Bool {
        flush()
        guard changeActive({ $0.leftAt = max(now, $0.startedAt) }) else { return false }
        line = OpenLine()
        return true
    }

    /// "End the road trip": it ends on this iPhone now, owed to every other member until a catch-up tells them.
    /// Whether it was written.
    func end(now: Date = Date()) -> Bool {
        flush()
        guard changeActive({ $0 = RoadTripCatchUpRules.ending($0, now: now) }) else { return false }
        line = OpenLine()
        return true
    }

    // MARK: The swap (PR 2)

    /// The trip a catch-up with `member` is about (``RoadTripBook/trip(sharedWith:id:)``); nil in a decoy and before
    /// the book can be read.
    func trip(sharedWith member: String, id: UUID? = nil) -> RoadTrip? {
        guard !isDecoy else { return nil }
        load()
        guard isLoaded else { return nil }
        return book.trip(sharedWith: member, id: id)
    }

    /// Changes the trip `id` with `change` and writes the book; whether it was written (refused in a decoy, without
    /// the trip, or when the change leaves it invalid). A trip on now that the change ends has its line written and
    /// closed first, and the passenger gate follows the change.
    func change(_ id: UUID, _ change: (inout RoadTrip) -> Void) -> Bool {
        guard !isDecoy else { return false }
        load()
        let wasOn = book.active?.id == id
        if wasOn { flush() }
        guard isLoaded, let next = book.changing(id, change), store.saveBook(next) else { return false }
        book = next
        if wasOn, book.active?.id != id { line = OpenLine() }
        tellPassenger()
        return true
    }

    /// The points of `trip`'s line on this iPhone after `after` and through `through`, oldest first, at most
    /// ``RoadTripLine/maxPoints``: the open piece as it is in memory, the others read. Pieces wholly before `after` are
    /// skipped. Nil in a decoy and when a piece can't be read right now.
    func linePoints(of trip: RoadTrip, after: Date, through: Date) -> [RoadTripPoint]? {
        guard !isDecoy, isLoaded else { return nil }
        flush()
        do {
            var points: [RoadTripPoint] = []
            // R2: bounded by the line's pieces.
            for chunk in try store.chunks(of: trip.id).prefix(RoadTripLine.maxChunks) {
                let piece: [RoadTripPoint]
                if line.trip == trip.id, chunk == line.chunk { piece = line.tail } else { piece = try store.readChunk(chunk, of: trip.id) }
                guard let last = piece.last, last.at > after else { continue }
                points += RoadTripPresence.points(piece, after: after, through: through)
                    .prefix(RoadTripLine.maxPoints - points.count)
            }
            return points
        } catch {
            FernletAuditLog.log("worldMap.roadTrip.readDeferred")
            return nil
        }
    }

    /// Received road for the trip `id`: added to the trip on now's line by the line's own rules (in time order, 25 m
    /// apart, none before the start) and written. How many points were kept; none in a decoy or for another trip.
    func appendReceived(_ points: [RoadTripPoint], to id: UUID) -> Int {
        guard !isDecoy, active?.id == id else { return 0 }
        return appendLine(points)
    }

    /// The length of the trip's line on this iPhone, in metres: the earlier pieces read once, then the open one.
    func lineMetres() -> Double {
        guard isLoaded, let trip = active else { return 0 }
        if line.trip != trip.id { openLine() }
        guard line.trip == trip.id else { return 0 }
        if line.finished == nil { line.finished = readFinished(trip.id) }
        let finished = line.finished ?? (0, nil)
        return finished.metres + RoadTripLine.length(of: line.tail, from: finished.last)
    }

    /// Enters or leaves a decoy session: entering writes what is unsaved and drops the real book from memory; leaving
    /// reads it again.
    func setDecoy(_ on: Bool) {
        guard on != isDecoy else { return }
        if on { flush() }
        isDecoy = on
        line = OpenLine()
        book = .empty
        isLoaded = false
        if !on { load() }
        tellPassenger()
    }

    /// The wipe: forgets every trip and point in memory, unsaved ones included (the vault's ``WorldMapVault/clearAll()``
    /// removes the files).
    func forget() {
        book = .empty
        line = OpenLine()
        isLoaded = !isDecoy
        refusedCount = 0
        tellPassenger()
    }

    // MARK: The line

    /// Opens the trip on now's line: its last piece read as the open one. Nothing open when no trip is on or the key
    /// can't be read right now.
    private func openLine() {
        line = OpenLine()
        guard let trip = book.active else { return }
        do {
            let chunks = try store.chunks(of: trip.id)
            line.trip = trip.id
            guard let last = chunks.last else {
                line.finished = (0, nil)
                return
            }
            line.chunk = last
            line.tail = try store.readChunk(last, of: trip.id)
            line.last = line.tail.last
            if last == 0 { line.finished = (0, nil) }
        } catch {
            FernletAuditLog.log("worldMap.roadTrip.lineDeferred")
            line = OpenLine()
        }
    }

    /// Adds `point` to `trip`'s line when the thinning keeps it, starting a new piece when the open one is full.
    /// Whether it was kept.
    private func append(_ point: RoadTripPoint, to trip: RoadTrip) -> Bool {
        if line.trip != trip.id { openLine() }
        guard line.trip == trip.id, point.at >= trip.startedAt, RoadTripLine.keeps(point, after: line.last) else { return false }
        if line.tail.count >= RoadTripLine.chunkSize {
            guard line.chunk + 1 < RoadTripLine.maxChunks else {
                refusedCount += 1
                return false
            }
            guard saveTail() else { return false }
            if let finished = line.finished {
                line.finished = (finished.metres + RoadTripLine.length(of: line.tail, from: finished.last), line.tail.last)
            }
            line.chunk += 1
            line.tail = []
        }
        line.tail.append(point)
        line.last = point
        line.unsaved += 1
        return true
    }

    /// Writes the open piece when it has unsaved points; whether nothing is left unsaved.
    private func saveTail() -> Bool {
        guard line.unsaved > 0 else { return true }
        guard let trip = line.trip, store.saveChunk(line.tail, chunk: line.chunk, of: trip) else { return false }
        line.unsaved = 0
        return true
    }

    /// The length and last point of the pieces before the open one; nil when one can't be read right now.
    private func readFinished(_ trip: UUID) -> (metres: Double, last: RoadTripPoint?)? {
        var metres = 0.0
        var last: RoadTripPoint?
        for chunk in 0..<min(line.chunk, RoadTripLine.maxChunks) {
            do {
                let points = try store.readChunk(chunk, of: trip)
                metres += RoadTripLine.length(of: points, from: last)
                last = points.last ?? last
            } catch {
                FernletAuditLog.log("worldMap.roadTrip.lengthDeferred")
                return nil
            }
        }
        return (metres, last)
    }

    // MARK: The book

    /// Changes the trip on now with `change` and writes the book; whether it was written (refused in a decoy, with no
    /// trip on, or when the change leaves the trip invalid).
    private func changeActive(_ change: (inout RoadTrip) -> Void) -> Bool {
        guard !isDecoy else { return false }
        load()
        guard isLoaded, let next = book.changingActive(change), store.saveBook(next) else { return false }
        book = next
        tellPassenger()
        return true
    }

    /// Tells ``onPassengerChanged`` when being a passenger differs from what it was last told.
    private func tellPassenger() {
        let passenger = isPassenger
        guard passenger != toldPassenger else { return }
        toldPassenger = passenger
        onPassengerChanged?(passenger)
    }
}
