import FernletFoundation
import Foundation
import WorldMapStore

/// Ferry and train paths (owner 2026-11-15, World-Transit-Paths-Exploration §9): a drive trip's readings, its
/// classification when it ends, the kept trips, and the actions the map's sheet and Home's question call (C1, C2).
///
/// - **A ride** keeps its accepted drive readings in memory (``noteRide(_:)``), at least ``WorldFogKeeper/rideSpacing``
///   apart, at most `WornRideClassifier.maxSamples` (a longer ride keeps every other reading and doubles the spacing),
///   with each reading's speed and whether a car was connected. Every ``WorldFogKeeper/rideCheckpointEvery`` of ride
///   time it is written to `worn-trip-ride.bin` under the buffer key, so a suspended or ended app keeps it: the next
///   ``WorldFogKeeper/load()`` resumes it, or keeps it as ended when its last reading is older than
///   ``WorldFogKeeper/tripGap``.
/// - **When the ride ends** (``endTrip(classifyNow:)``) `WornRideClassifier.segments` splits it off the main actor over
///   ``WorldFogKeeper/transitGeography`` (none: one road). Each stretch is kept as a `WornTrip` and the cells of its
///   thinned line count once under its kind (`WornFootpaths.cells(along:)`, the same cells a change or a forget takes
///   back out); with the phone locked they wait in the counter's buffer. Learned rail is the counter's rail cells at
///   level 1 or more.
/// - **Home's question**: the newest unconfirmed unsure ride of today or yesterday, at most one a calendar day (the
///   day kept in the trip store's own file), never in a decoy.
/// - **A decoy** keeps nothing and shows nothing; the wipe forgets it all (``forgetTrips()``).
extension WorldFogKeeper {
    // MARK: The UI's actions

    /// The kept trips whose way passes through `cell`, newest first (the tap-a-path sheet).
    func trips(through cell: HexCell) -> [WornTrip] {
        guard !isDecoy, tripStore.isLoaded else { return [] }
        do {
            return try tripStore.trips(through: cell)
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
            try tripStore.update(id, kind: kind, confirmed: true)
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

    /// Answers Home's question about ``transitQuestion``: a kind, or nil for "Not sure" (kept as guessed, not asked
    /// again).
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
        wornTrips = tripStore.summaries
        if let id, transitQuestion?.id == id { transitQuestion = nil }
        if let question = transitQuestion, !wornTrips.contains(where: { $0.id == question.id }) { transitQuestion = nil }
        flush()
    }

    // MARK: The ride

    /// Keeps an accepted drive reading in the ride (never in a decoy; the caller checks).
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
    /// or here with `classifyNow`).
    func endTrip(classifyNow: Bool = false) {
        lastDriveAt = nil
        var samples = rideSamples
        if let last = rideLast, samples.last != last { samples.append(last) }
        rideSamples = []
        rideLast = nil
        rideSpacingNow = Self.rideSpacing
        rideCheckpointAt = nil
        guard !samples.isEmpty, !isDecoy else { return }
        keepRide(samples, classifyNow: classifyNow)
    }

    /// Drops the ride in progress without keeping it (entering or leaving a decoy after it ended).
    func dropRide() {
        rideSamples = []
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

    /// Classifies `samples` and keeps the result: here with no geography or with `classifyNow`, else off the main actor.
    private func keepRide(_ samples: [WornRideSample], classifyNow: Bool) {
        let thinned = WornRideClassifier.thin(samples)
        guard let geography = transitGeography else {
            keep([WornRideSegment(range: 0..<thinned.count, verdict: .road)], of: thinned)
            return
        }
        let learned = learnedRailCells()
        if classifyNow {
            keep(WornRideClassifier.segments(thinned, geography: geography, learnedRail: { learned.contains($0) }), of: thinned)
            return
        }
        let generation = tripGeneration
        let id = UUID()
        tripRides[id] = thinned
        tripTasks[id] = Task { [weak self] in
            let segments = await Task.detached(priority: .utility) {
                WornRideClassifier.segments(thinned, geography: geography, learnedRail: { learned.contains($0) })
            }.value
            guard let self else { return }
            self.tripTasks[id] = nil
            self.tripRides[id] = nil
            guard self.tripGeneration == generation, !self.isDecoy else { return }
            self.keep(segments, of: thinned)
        }
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
        for samples in rides.values.sorted(by: { ($0.first?.at ?? .distantPast) < ($1.first?.at ?? .distantPast) }) {
            keepRide(samples, classifyNow: true)
        }
    }

    /// The counter's rail cells at level 1 or more today: the person's own lines (T2).
    private func learnedRailCells() -> Set<HexCell> {
        guard worn.isLoaded else { return [] }
        let today = WornDay.number(for: now())
        var cells = Set<HexCell>()
        // Bounded: the counter holds at most FogCellStore.maxCells ways.
        for (key, tally) in worn.tallies where key.kind == .rail {
            if let level = tally.level(today: today, thresholds: .forKind(.rail)), level >= .one { cells.insert(key.cell) }
        }
        return cells
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
        if rideSamples.isEmpty { vault.remove(.wornTripRide) } else { writeRideCheckpoint(at: rideLast?.at ?? now()) }
        wornTrips = tripStore.summaries
        refreshTransitQuestion()
        flush()
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
        restoreRide()
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
    /// ``WorldFogKeeper/tripGap`` (or older than this launch's ride), else resumed as the ride in progress.
    private func restoreRide() {
        guard !rideRestored else { return }
        let saved: [WornRideSample]
        do {
            guard let data = try vault.read(.wornTripRide) else {
                rideRestored = true
                return
            }
            saved = WornRideCheckpointCodec.decode(data, limit: WornRideClassifier.maxSamples + 1) ?? []
        } catch WorldMapVault.VaultError.keyUnavailable {
            return
        } catch {
            vault.remove(.wornTripRide)
            saved = []
        }
        rideRestored = true
        guard let savedLast = saved.last else {
            vault.remove(.wornTripRide)
            return
        }
        let resumeBefore = rideSamples.first?.at ?? now()
        if resumeBefore.timeIntervalSince(savedLast.at) > Self.tripGap || !rideSamples.isEmpty {
            keepRide(saved, classifyNow: false)
            return
        }
        rideSamples = Array(saved.prefix(WornRideClassifier.maxSamples))
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
            try vault.write(WornRideCheckpointCodec.encode(samples), to: .wornTripRide)
            rideCheckpointAt = date
        } catch {
            FernletAuditLog.log("worldMap.trips.checkpointUnsaved")
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
        tripStore.forget()
        wornTrips = []
        transitQuestion = nil
    }
}
