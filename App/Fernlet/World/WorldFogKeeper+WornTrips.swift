import FernletFoundation
import Foundation
import WorldMapStore

/// Ferry and train paths (owner 2026-11-15, World-Transit-Paths-Exploration §9): a drive trip's readings, its
/// classification when it ends, the kept trips, and the actions the map's sheet and Home's question call (C1, C2).
///
/// - **Only with background mapping on** (F13 1A, owner 2026-11-19, the approved privacy policy): a ride is followed and
///   kept only while ``WorldFogKeeper/countsRides`` says background mapping is on (the switch, or for the locked
///   launch's keeper its marker). Turning it off drops a ride in progress and its checkpoint (``followRide(_:onDrive:)``);
///   fog lifting is unchanged. "Show worn paths" only shows or hides what was counted.
/// - **A ride** keeps its accepted drive readings in memory (``noteRide(_:)``), at least ``WorldFogKeeper/rideSpacing``
///   apart, at most `WornRideClassifier.maxSamples` (a longer ride keeps every other reading and doubles the spacing),
///   with each reading's speed and whether a car was connected. Every ``WorldFogKeeper/rideCheckpointEvery`` of ride
///   time it is written to `worn-trip-ride.bin` under the buffer key, so a suspended or ended app keeps it: the next
///   ``WorldFogKeeper/load()`` resumes it, or keeps it as ended when its last reading is older than
///   ``WorldFogKeeper/tripGap``. The checkpoint also says whether the ride watch ever called the ride a drive.
/// - **When the ride ends** (``endTrip(classifyNow:)``) it is kept only when it lasted
///   ``WornRideClassifier/minRideSeconds`` and ``WornRideClassifier/minRideMetres`` and overlaps no cycling workout in
///   the log (``WorldFogKeeper/cyclingWorkouts``: Fernlet's own logged bike rides, and Health's cycling workouts from
///   any app when Health's workouts are read in; F13 2B). Then
///   `WornRideClassifier.segments` splits it off the main actor over ``WorldFogKeeper/transitGeography``. Each stretch
///   is kept as a `WornTrip` and the cells of its thinned line count once under its kind (`WornFootpaths.cells(along:)`,
///   the same cells a change or a forget takes back out); with the phone locked they wait in the counter's buffer. A
///   ride the ride watch never called a drive keeps only its ferry and rail stretches. Learned rail comes only from the
///   rides the person marked Train (`WornRideClassifier.learnedRailCells(from:)`, F13 3B).
/// - **No ground yet** (a locked launch, or a background launch before the packs open; F13 4B): the finished ride waits
///   unsorted in the sealed queue `worn-trip-queue.bin` (under the buffer key, at most `WornRideQueueCodec.maxRides`),
///   and is sorted when the ground arrives (``sortQueuedRides()``). A full or unwritable queue keeps it as a road, as
///   before.
/// - **A Watch workout syncs late**: each load forgets the unconfirmed rides of the last ``WorldFogKeeper/cyclingRecheck``
///   that a cycling workout now in the log overlaps (``forgetRidesOverlappingCycling()``).
/// - **Home's question**: the newest unconfirmed unsure ride of today or yesterday, at most one a calendar day (the
///   day kept in the trip store's own file), never in a decoy.
/// - **A decoy** keeps nothing and shows nothing; the wipe forgets it all (``forgetTrips()``).
extension WorldFogKeeper {
    // MARK: The UI's actions

    /// The kept trips whose way passes through `cell`, newest first (the tap-a-path sheet). Never a subway hop: its
    /// straight line crosses ways it never used, and it has its own sheet.
    func trips(through cell: HexCell) -> [WornTrip] {
        guard !isDecoy, tripStore.isLoaded else { return [] }
        do {
            return try tripStore.trips(through: cell).filter { $0.kind != .subway }
        } catch {
            FernletAuditLog.log("worldMap.trips.readFailed")
            return []
        }
    }

    /// Changes trip `id` to `kind`, moving its passes in the counter to the new kind, and marks it confirmed.
    func changeTrip(_ id: UUID, to kind: WornWayKind) {
        guard canChangeTrips, let summary = tripStore.summaries.first(where: { $0.id == id }) else { return }
        do {
            if summary.kind != kind, let trip = try tripStore.trip(id) {
                worn.move(WornFootpaths.cells(along: trip.line), from: summary.kind, to: kind, on: trip.day)
                wornUnpublished = true
            }
            try tripStore.update(id, kind: kind, confirmed: true, markedTrain: kind == .rail)
        } catch {
            FernletAuditLog.log("worldMap.trips.changeFailed")
        }
        afterTripsChanged(id)
    }

    /// Forgets trip `id`: its record goes and its passes come out of the counter.
    func forgetTrip(_ id: UUID) {
        guard canChangeTrips, let summary = tripStore.summaries.first(where: { $0.id == id }) else { return }
        do {
            if let trip = try tripStore.trip(id) {
                worn.unrecord(WornFootpaths.cells(along: trip.line), kind: summary.kind)
                wornUnpublished = true
            }
            try tripStore.delete(id)
        } catch {
            FernletAuditLog.log("worldMap.trips.forgetFailed")
        }
        afterTripsChanged(id)
    }

    /// Forgets every kept trip of `kind` through `cell` ("Forget this path"): their records go, their passes come out
    /// of the counter, and whatever count `cell` still holds for `kind` (passes from before trips were kept) goes too.
    func forgetPath(through cell: HexCell, kind: WornWayKind) {
        guard canChangeTrips else { return }
        do {
            // Bounded: the trips through one cell, at most WornTripStore.maxTrips.
            for trip in try tripStore.trips(through: cell) where trip.kind == kind {
                worn.unrecord(WornFootpaths.cells(along: trip.line), kind: kind)
                try tripStore.delete(trip.id)
            }
        } catch {
            FernletAuditLog.log("worldMap.trips.forgetFailed")
        }
        worn.remove(WornWayKey(cell: cell, kind: kind))
        wornUnpublished = true
        afterTripsChanged(nil)
    }

    /// Answers Home's question about ``transitQuestion``: a kind ("Train" marks it, so it may teach learned rail), or nil
    /// for "Not sure" (kept as guessed, not asked again, and never teaching).
    func answerTransitQuestion(_ kind: WornWayKind?) {
        guard let question = transitQuestion else { return }
        transitQuestion = nil
        if let kind {
            changeTrip(question.id, to: kind)
        } else if let summary = tripStore.summaries.first(where: { $0.id == question.id }) {
            do {
                try tripStore.update(question.id, kind: summary.kind, confirmed: true)
            } catch {
                FernletAuditLog.log("worldMap.trips.changeFailed")
            }
            afterTripsChanged(question.id)
        }
        do {
            try tripStore.recordAsked(day: tripStore.lastAskedDay, trip: nil)
        } catch {
            FernletAuditLog.log("worldMap.trips.askedUnsaved")
        }
    }

    /// Whether the UI's changes can reach the counter now: no decoy, both stores read, the phone unlocked.
    private var canChangeTrips: Bool {
        !isDecoy && tripStore.isLoaded && worn.isLoaded && isProtectedDataAvailable()
    }

    /// Saves and shows what a change did; the question goes when it was about trip `id`.
    private func afterTripsChanged(_ id: UUID?) {
        learnedRail = nil
        wornTrips = tripStore.summaries
        if let id, transitQuestion?.id == id { transitQuestion = nil }
        if let question = transitQuestion, !wornTrips.contains(where: { $0.id == question.id }) { transitQuestion = nil }
        flush()
    }

    // MARK: The ride

    /// Follows an accepted drive-speed reading (never in a decoy; the caller checks): kept in the ride while background
    /// mapping is on, `onDrive` when the ride watch says driving; with it off, a ride in progress is dropped (F13 1A). A
    /// keeper that never loaded (the locked launch's) first takes over a ride an earlier launch checkpointed, so its own
    /// ride never writes over it.
    func followRide(_ fix: WorldFix, onDrive: Bool) {
        guard countsRides() else {
            if rideLast != nil { abandonRide() }
            return
        }
        if !rideRestored { restoreRide() }
        if onDrive { rideSawDrive = true }
        noteRide(fix)
    }

    /// Keeps an accepted drive reading in the ride.
    func noteRide(_ fix: WorldFix) {
        let speed = fix.speed.flatMap { $0 >= 0 && $0.isFinite ? $0 : nil }
        let sample = WornRideSample(point: fix.point, at: fix.at, speed: speed, inCar: fix.carLinked)
        rideLast = sample
        if let kept = rideSamples.last, kept.point.distance(to: sample.point) < rideSpacingNow { return }
        rideSamples.append(sample)
        if rideSamples.count > WornRideClassifier.maxSamples {
            // Bounded: halves a ride of maxSamples + 1 readings.
            rideSamples = rideSamples.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
            rideSpacingNow *= 2
        }
        let since = rideCheckpointAt ?? rideSamples.first?.at ?? sample.at
        if sample.at.timeIntervalSince(since) >= Self.rideCheckpointEvery { writeRideCheckpoint(at: sample.at) }
    }

    /// Ends the ride: the next drive reading starts a new one, and this one is classified and kept (off the main actor,
    /// or here with `classifyNow`) while background mapping is on.
    func endTrip(classifyNow: Bool = false) {
        lastDriveAt = nil
        var samples = rideSamples
        if let last = rideLast, samples.last != last { samples.append(last) }
        let sawDrive = rideSawDrive
        dropRide()
        guard !samples.isEmpty, !isDecoy else { return }
        guard countsRides() else {
            vault.remove(.wornTripRide)
            return
        }
        keepRide(WornRideCheckpoint(samples: samples, sawDrive: sawDrive), classifyNow: classifyNow)
    }

    /// Drops the ride in progress and its checkpoint without keeping it (background mapping turned off).
    func abandonRide() {
        dropRide()
        vault.remove(.wornTripRide)
        FernletAuditLog.log("worldMap.trips.rideDropped")
    }

    /// Writes the ride in progress to its checkpoint now, so a keeper loaded later resumes it (the locked launch's
    /// keeper handing over to the store's, F13 4B). Nothing in a decoy or without a ride.
    func checkpointRide() {
        guard !isDecoy, let last = rideLast else { return }
        writeRideCheckpoint(at: last.at)
    }

    /// Drops the ride in progress without keeping it (entering or leaving a decoy after it ended).
    func dropRide() {
        rideSamples = []
        rideSawDrive = false
        rideLast = nil
        rideSpacingNow = Self.rideSpacing
        rideCheckpointAt = nil
    }

    /// Waits for the rides being classified (tests).
    func settleTrips() async {
        // Bounded: each pass awaits the tasks started so far; a ride ends at most once per reading.
        for _ in 0..<100 {
            guard let task = tripTasks.values.first else { return }
            await task.value
        }
    }

    /// Keeps `ride` when it is big enough and no cycling workout overlaps it: classified here with `classifyNow`, else
    /// off the main actor; queued unsorted when the ground isn't known yet.
    private func keepRide(_ ride: WornRideCheckpoint, classifyNow: Bool) {
        let thinned = WornRideClassifier.thin(ride.samples)
        guard WornRideClassifier.isLongEnough(thinned), !overlapsCyclingWorkout(thinned) else {
            FernletAuditLog.log("worldMap.trips.notKept")
            settleCheckpoint()
            return
        }
        let sawDrive = ride.sawDrive
        guard let geography = transitGeography else {
            queueUnsorted(WornRideCheckpoint(samples: thinned, sawDrive: sawDrive))
            return
        }
        let learned = learnedRailCells()
        if classifyNow {
            let segments = WornRideClassifier.segments(thinned, geography: geography, learnedRail: { learned.contains($0) })
            keep(Self.kept(segments, sawDrive: sawDrive), of: thinned)
            return
        }
        let generation = tripGeneration
        let id = UUID()
        tripRides[id] = WornRideCheckpoint(samples: thinned, sawDrive: sawDrive)
        tripTasks[id] = Task { [weak self] in
            let segments = await Task.detached(priority: .utility) {
                WornRideClassifier.segments(thinned, geography: geography, learnedRail: { learned.contains($0) })
            }.value
            guard let self else { return }
            self.tripTasks[id] = nil
            self.tripRides[id] = nil
            guard self.tripGeneration == generation, !self.isDecoy else { return }
            self.keep(Self.kept(segments, sawDrive: sawDrive), of: thinned)
        }
    }

    /// The segments a ride keeps: all of them when the ride watch called it a drive, else only its ferry and rail
    /// stretches (a fast bike burst or a GPS spike is no road, F13 2B).
    static func kept(_ segments: [WornRideSegment], sawDrive: Bool) -> [WornRideSegment] {
        sawDrive ? segments : segments.filter { $0.verdict.kind != .road }
    }

    /// Whether a cycling workout in the log overlaps the ride `samples` (F13 2B, the owner's idea).
    private func overlapsCyclingWorkout(_ samples: [WornRideSample]) -> Bool {
        guard let first = samples.first, let last = samples.last else { return false }
        return !cyclingWorkouts(DateInterval(start: first.at, end: max(first.at, last.at))).isEmpty
    }

    /// Keeps the rides still being classified off the main actor here and now (a decoy is starting), and drops the
    /// off-main results when they arrive.
    func keepClassifyingRidesNow() {
        let rides = tripRides
        tripGeneration &+= 1
        tripTasks.values.forEach { $0.cancel() }
        tripTasks = [:]
        tripRides = [:]
        // Bounded: one ride per ended trip still being classified.
        for ride in rides.values.sorted(by: { ($0.samples.first?.at ?? .distantPast) < ($1.samples.first?.at ?? .distantPast) }) {
            keepRide(ride, classifyNow: true)
        }
    }

    /// The person's own rail cells: from the rides they marked Train, on at least two different days (F13 3B), read
    /// once and kept until a trip changes.
    private func learnedRailCells() -> Set<HexCell> {
        if let learnedRail { return learnedRail }
        guard tripStore.isLoaded else { return [] }
        do {
            let cells = WornRideClassifier.learnedRailCells(from: try tripStore.markedTrainTrips(limit: WornRideClassifier.maxLearningTrips))
            learnedRail = cells
            return cells
        } catch {
            FernletAuditLog.log("worldMap.trips.learnedUnread")
            return []
        }
    }

    /// Keeps each of `segments` of the ride `samples` as a trip and counts its cells under its kind; then saves,
    /// shows, and maybe asks.
    private func keep(_ segments: [WornRideSegment], of samples: [WornRideSample]) {
        if !tripStore.isLoaded { loadTripStore() }
        let unlocked = isProtectedDataAvailable() && store.isLoaded && worn.isLoaded
        // Bounded: a ride has at most maxSamples samples, so at most that many segments.
        for segment in segments where !segment.range.isEmpty && segment.range.upperBound <= samples.count {
            // Each stretch starts at the last reading of the one before, so the ways join.
            let stretch = samples[max(0, segment.range.lowerBound - 1)..<segment.range.upperBound]
            guard let first = stretch.first, let last = stretch.last else { continue }
            let trip = WornTrip(kind: segment.verdict.kind, confirmed: false, day: WornDay.number(for: first.at),
                                start: first.at, end: last.at, line: WornTripCodec.quantized(Self.tripLine(stretch.map(\.point))))
            do {
                if !(try tripStore.append(trip, unsure: segment.verdict.confidence == .unsure)) {
                    FernletAuditLog.log("worldMap.trips.refused")
                }
            } catch {
                FernletAuditLog.log("worldMap.trips.unsaved")
            }
            let cells = WornFootpaths.cells(along: trip.line)
            if unlocked {
                if worn.record(cells, kind: trip.kind, on: trip.day) > 0 { wornUnpublished = true }
            } else {
                do {
                    try worn.appendPending(Array(cells), kind: trip.kind, on: trip.day)
                } catch {
                    FernletAuditLog.log("worldMap.fog.bufferUnavailable")
                }
            }
        }
        settleCheckpoint()
        wornTrips = tripStore.summaries
        refreshTransitQuestion()
        flush()
    }

    /// After a ride was kept or let go: the checkpoint goes, or holds the ride in progress since. A checkpoint an earlier
    /// launch left and this keeper hasn't read yet stays.
    private func settleCheckpoint() {
        if !rideSamples.isEmpty {
            writeRideCheckpoint(at: rideLast?.at ?? now())
        } else if rideRestored {
            vault.remove(.wornTripRide)
        }
    }

    /// `points` cut to at most `WornTrip.maxLinePoints` by keeping every n-th (and the last).
    static func tripLine(_ points: [GeoPoint]) -> [GeoPoint] {
        guard points.count > WornTrip.maxLinePoints else { return points }
        let stride = (points.count + WornTrip.maxLinePoints - 2) / (WornTrip.maxLinePoints - 1)
        var line = Swift.stride(from: 0, to: points.count - 1, by: stride).map { points[$0] }
        line = Array(line.prefix(WornTrip.maxLinePoints - 1))
        if let last = points.last { line.append(last) }
        return line
    }

    // MARK: Loading, the checkpoint and the question

    /// Reads the kept trips once (they're under the buffer key, so this works locked) and resumes or keeps a ride an
    /// earlier launch left. Nothing in a decoy.
    func loadTrips() {
        guard !isDecoy else { return }
        if !tripStore.isLoaded { loadTripStore() }
        guard tripStore.isLoaded else { return }
        wornTrips = tripStore.summaries
        learnedRail = nil
        restoreRide()
        sortQueuedRides()
    }

    /// Reads the trip store, logging when its key can't be read yet.
    private func loadTripStore() {
        do {
            try tripStore.load()
        } catch {
            FernletAuditLog.log("worldMap.trips.loadDeferred")
        }
    }

    /// The ride an earlier launch checkpointed: kept as ended when its last reading is older than
    /// ``WorldFogKeeper/tripGap`` (or older than this launch's ride), else resumed as the ride in progress. Dropped
    /// with background mapping off.
    private func restoreRide() {
        guard !rideRestored else { return }
        let saved: WornRideCheckpoint?
        do {
            guard let data = try vault.read(.wornTripRide) else {
                rideRestored = true
                return
            }
            saved = WornRideCheckpointCodec.decode(data, limit: WornRideClassifier.maxSamples + 1)
        } catch let error as WorldMapVault.VaultError where error.isTryAgainLater {
            FernletAuditLog.log("worldMap.trips.rideDeferred", context: ["error": "\(error)"])
            return
        } catch {
            saved = nil
        }
        rideRestored = true
        guard let saved, let savedLast = saved.samples.last, countsRides() else {
            vault.remove(.wornTripRide)
            return
        }
        let resumeBefore = rideSamples.first?.at ?? now()
        if resumeBefore.timeIntervalSince(savedLast.at) > Self.tripGap || !rideSamples.isEmpty {
            keepRide(saved, classifyNow: false)
            return
        }
        rideSamples = Array(saved.samples.prefix(WornRideClassifier.maxSamples))
        rideSawDrive = saved.sawDrive
        rideLast = savedLast
        lastDriveAt = savedLast.at
        rideCheckpointAt = savedLast.at
    }

    /// Writes the ride so far to its checkpoint (under the buffer key, so also locked).
    private func writeRideCheckpoint(at date: Date) {
        var samples = rideSamples
        if let last = rideLast, samples.last != last { samples.append(last) }
        guard !samples.isEmpty else { return }
        do {
            try vault.write(WornRideCheckpointCodec.encode(WornRideCheckpoint(samples: samples, sawDrive: rideSawDrive)),
                           to: .wornTripRide)
            rideCheckpointAt = date
        } catch {
            FernletAuditLog.log("worldMap.trips.checkpointUnsaved")
        }
    }

    // MARK: Rides waiting for the ground (F13 4B)

    /// Puts `ride` (thinned) in the unsorted queue until the ground is known. A full or unwritable queue keeps it as a
    /// road, as before the queue (a ride never called a drive keeps nothing).
    private func queueUnsorted(_ ride: WornRideCheckpoint) {
        if let queued = readQueue() {
            let next = WornRideQueueCodec.encode(queued + [ride])
            if queued.count < WornRideQueueCodec.maxRides, next.count <= WornRideQueueCodec.maxBytes {
                do {
                    try vault.write(next, to: .wornTripQueue)
                    settleCheckpoint()
                    return
                } catch {
                    FernletAuditLog.log("worldMap.trips.queueUnsaved")
                }
            } else {
                FernletAuditLog.log("worldMap.trips.queueFull")
            }
        }
        let road = [WornRideSegment(range: 0..<ride.samples.count, verdict: .road)]
        keep(Self.kept(road, sawDrive: ride.sawDrive), of: ride.samples)
    }

    /// The queued rides (none when there is no queue; a queue whose bytes are bad is removed); nil when the key or the
    /// file can't be read right now (a locked phone), so nothing is written over it.
    private func readQueue() -> [WornRideCheckpoint]? {
        do {
            guard let data = try vault.read(.wornTripQueue) else { return [] }
            if let rides = WornRideQueueCodec.decode(data, limit: WornRideClassifier.maxSamples) { return rides }
        } catch let error as WorldMapVault.VaultError where error.isTryAgainLater {
            // Locked or before the first unlock: the queue stays, never removed over a read that can't happen now (F3).
            FernletAuditLog.log("worldMap.trips.queueDeferred", context: ["error": "\(error)"])
            return nil
        } catch {
            FernletAuditLog.log("worldMap.trips.queueDropped")
        }
        vault.remove(.wornTripQueue)
        return []
    }

    /// Sorts the queued rides now the ground is known (off the main actor, each kept like a ride that just ended), and
    /// empties the queue. Nothing in a decoy or before the ground and the trip store are there.
    func sortQueuedRides() {
        guard transitGeography != nil, !isDecoy, tripStore.isLoaded, let rides = readQueue(), !rides.isEmpty else { return }
        vault.remove(.wornTripQueue)
        // Bounded: at most WornRideQueueCodec.maxRides.
        for ride in rides { keepRide(ride, classifyNow: false) }
    }

    /// Forgets the unconfirmed rides that ended within ``WorldFogKeeper/cyclingRecheck`` and that a cycling workout now
    /// in the log overlaps (a Watch or Strava workout reaches the log late; F13 2B). Only with both stores read and the
    /// phone unlocked; never in a decoy.
    func forgetRidesOverlappingCycling() {
        guard !isDecoy, tripStore.isLoaded, worn.isLoaded, isProtectedDataAvailable() else { return }
        let since = now().addingTimeInterval(-Self.cyclingRecheck)
        // Bounded: the newest maxRecheckedTrips trips.
        let recent = tripStore.summaries.prefix(Self.maxRecheckedTrips).filter { $0.end >= since && !$0.confirmed }
        guard let earliest = recent.map(\.start).min(), let latest = recent.map(\.end).max() else { return }
        // One look at the log for all of them.
        let workouts = cyclingWorkouts(DateInterval(start: earliest, end: max(earliest, latest)))
        guard !workouts.isEmpty else { return }
        for trip in recent where workouts.contains(where: { $0.start < trip.end && $0.end > trip.start }) {
            FernletAuditLog.log("worldMap.trips.cyclingForgotten")
            forgetTrip(trip.id)
        }
    }

    /// Sets ``transitQuestion``: the ride already asked about today while it waits for an answer, else (once a day)
    /// the newest unconfirmed unsure ride of today or yesterday. None in a decoy.
    func refreshTransitQuestion() {
        guard !isDecoy, tripStore.isLoaded else {
            transitQuestion = nil
            return
        }
        let today = WornDay.number(for: now())
        if tripStore.lastAskedDay == today {
            guard let id = tripStore.askedTripID,
                  tripStore.summaries.contains(where: { $0.id == id && !$0.confirmed }) else {
                transitQuestion = nil
                return
            }
            if transitQuestion?.id != id { transitQuestion = try? tripStore.trip(id) }
            return
        }
        guard let candidate = tripStore.summaries.first(where: { $0.unsure && !$0.confirmed }),
              Int(candidate.day) + Int(Self.questionDays) >= Int(today) else {
            transitQuestion = nil
            return
        }
        do {
            try tripStore.recordAsked(day: today, trip: candidate.id)
            transitQuestion = try tripStore.trip(candidate.id)
        } catch {
            FernletAuditLog.log("worldMap.trips.askedUnsaved")
            transitQuestion = nil
        }
    }

    /// The wipe's part: the ride, the kept trips and the question, in memory (the vault's wipe removes the files), and
    /// any ride being classified is dropped.
    func forgetTrips() {
        tripGeneration &+= 1
        tripTasks.values.forEach { $0.cancel() }
        tripTasks = [:]
        tripRides = [:]
        dropRide()
        learnedRail = nil
        tripStore.forget()
        wornTrips = []
        transitQuestion = nil
    }
}
