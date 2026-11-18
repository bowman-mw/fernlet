import Foundation

/// A stretch of one trip and what it was: the samples in ``range`` count under ``verdict``.
public nonisolated struct WornRideSegment: Sendable, Equatable {
    /// The samples (indices into the classified, thinned samples).
    public let range: Range<Int>
    /// What the stretch was.
    public let verdict: WornRideVerdict

    /// A segment.
    public init(range: Range<Int>, verdict: WornRideVerdict) {
        self.range = range
        self.verdict = verdict
    }
}

/// Tells a ferry or a train from a drive (Docs/World-Transit-Paths-Exploration-2026-11-15.md §2, §3 and §9; owner
/// 2026-11-15). Pure and nonisolated: the fog keeper runs it off the main actor when a drive-speed trip ends.
///
/// **Ferry** (owner's F1 draft rules, F4 any boat): a run of samples over water (``WornTransitGeography/isWater(_:)``)
/// covering at least ``ferryMinWaterMetres`` (1 km), whose median speed is between ``ferryMinSpeed`` and
/// ``ferryMaxSpeed`` (8–70 km/h), with fewer than ``bridgeMaxRoadShare`` (20 %) of its samples within
/// ``bridgeRoadMetres`` (1 km) of a major road (more is a bridge). Up to ``ferryLandGap`` land samples inside a run
/// (a pier, a shore-pack sliver) don't break it. A car connected on the water is still a ferry: the car is on it.
/// It is sure when the run starts and ends slowly (docking: a sample at or under ``dockingSpeed`` within
/// ``dockingReach`` samples of each end) or when at least ``ferryRouteShare`` (half) of it lies within
/// ``ferryRouteMetres`` (2 km) of a bundled ferry route; otherwise unsure.
///
/// **Train** (needs a car never connected: any sample with `inCar == true` is a road). Three strong signals:
/// - at least ``railShare`` (80 %) of the samples within ``railMetres`` (1 km) of a rail line;
/// - at least ``learnedShare`` (60 %) of the samples on cells learned as rail (the person's own lines, T2; a sample's
///   cell or one of its six neighbours, for GPS drift);
/// - at least ``fastSeconds`` (3 minutes) above ``fastSpeed`` (36 m/s, 130 km/h).
///
/// And two supporting ones: few, long-spaced stops (at least one stop, on average ``trainStopSpacing`` (2 km) or more
/// apart), and a stretch of ``awayStretchMetres`` (2 km) with every sample more than ``awayFromRoadMetres`` (300 m)
/// from any major road. A stop is a gap of at least ``stopSeconds`` (20 s) between samples crossed at under
/// ``stopSpeed`` (1.5 m/s). Bus-like stopping (at least ``busMinStops`` (4) stops, on average under
/// ``busStopSpacing`` (800 m) apart) caps the verdict at unsure. Rides shorter than ``minTrainMetres`` (2 km) are never
/// trains.
///
/// - two strong signals, or one strong and both supporting, and not bus-like: a train, **sure**;
/// - otherwise one strong signal: a train, **unsure** (Home may ask, at most once a day);
/// - no strong signal: a **road**, sure. Supporting signals alone never make a train: a car on a country road is far
///   from the atlas's roads and stops rarely too.
///
/// **Anything else** is a road, sure. Conservative on purpose: a bus or a car must not become rail on weak evidence.
public nonisolated enum WornRideClassifier {
    /// The most samples looked at (``WornTrip/maxLinePoints`` × 4); more are thinned evenly first.
    public static let maxSamples = WornTrip.maxLinePoints * 4

    // MARK: Ferry (F1)

    /// The shortest run over water a ferry needs, in metres.
    public static let ferryMinWaterMetres = 1_000.0
    /// The slowest median speed of a ferry's run, in m/s (8 km/h).
    public static let ferryMinSpeed = 2.2
    /// The fastest median speed of a ferry's run, in m/s (70 km/h): faster is a bridge crossed at road speed.
    public static let ferryMaxSpeed = 19.4
    /// How near a major road a sample over water must be to count as on a bridge, in metres. Natural Earth's roads sit
    /// up to several hundred metres off the real road in cities (Interstate 5's line is 729 m from the Marquam Bridge in
    /// the source), so the doc's 150 m would miss real bridges; a short ferry that hugs a road counts as a drive instead.
    public static let bridgeRoadMetres = 1_000.0
    /// The share of a run's samples on a bridge at which it is a bridge, not a boat.
    public static let bridgeMaxRoadShare = 0.2
    /// Land samples a run over water may hold in a row and go on (a pier, a sliver of the shore pack).
    public static let ferryLandGap = 2
    /// A sample at or under this speed near a run's end is docking, in m/s (about 7 km/h).
    public static let dockingSpeed = 2.0
    /// How many samples either side of a run's end are looked at for docking.
    public static let dockingReach = 4
    /// How near a bundled ferry route a sample must be to follow it, in metres.
    public static let ferryRouteMetres = 2_000.0
    /// The share of a run's samples near a ferry route that makes it sure.
    public static let ferryRouteShare = 0.5

    // MARK: Train

    /// How near a rail line a sample must be, in metres (Natural Earth's lines can be hundreds of metres off).
    public static let railMetres = 1_000.0
    /// The share of samples near rail that is a strong signal.
    public static let railShare = 0.8
    /// The share of samples on learned rail cells that is a strong signal.
    public static let learnedShare = 0.6
    /// A speed only trains hold for minutes, in m/s (130 km/h).
    public static let fastSpeed = 36.0
    /// How long above ``fastSpeed`` is a strong signal, in seconds.
    public static let fastSeconds = 180.0
    /// Under this speed across a gap between samples is a stop, in m/s.
    public static let stopSpeed = 1.5
    /// The shortest gap that is a stop, in seconds.
    public static let stopSeconds = 20.0
    /// Stops on average closer than this are a bus's, in metres.
    public static let busStopSpacing = 800.0
    /// The fewest stops that can look like a bus.
    public static let busMinStops = 4
    /// Stops on average at least this far apart are a train's, in metres.
    public static let trainStopSpacing = 2_000.0
    /// How far from any major road a sample must be to be away from roads, in metres.
    public static let awayFromRoadMetres = 300.0
    /// The stretch away from roads that is a supporting signal, in metres.
    public static let awayStretchMetres = 2_000.0
    /// The shortest ride that can be a train, in metres.
    public static let minTrainMetres = 2_000.0
    /// The shortest stretch of land beside a ferry that is its own segment, in metres (shorter joins the ferry).
    public static let minLandSegmentMetres = 300.0

    /// What `samples` (one trip, oldest first) were: a ferry when any stretch was a ferry (the surest such stretch),
    /// else a train or a road by the rules above. `learnedRail` says whether a cell is one of the person's own rail
    /// cells.
    public static func classify(_ samples: [WornRideSample], geography: some WornTransitGeography,
                                learnedRail: (HexCell) -> Bool) -> WornRideVerdict {
        let thinned = thin(samples)
        guard thinned.count >= 2 else { return .road }
        let runs = ferryRuns(thinned, geography: geography)
        if !runs.isEmpty {
            let sure = runs.contains { $0.confidence == .sure }
            return WornRideVerdict(kind: .ferry, confidence: sure ? .sure : .unsure)
        }
        return landVerdict(thinned[...], geography: geography, learnedRail: learnedRail)
    }

    /// `samples` split at each ferry crossing: the crossings are ferry segments, and the land before, between and after
    /// (a drive to the terminal and on) is judged by itself; land shorter than ``minLandSegmentMetres`` joins the
    /// crossing beside it. The ranges index ``thin(_:)``'s result, cover it in order and never overlap.
    public static func segments(_ samples: [WornRideSample], geography: some WornTransitGeography,
                                learnedRail: (HexCell) -> Bool) -> [WornRideSegment] {
        let thinned = thin(samples)
        guard thinned.count >= 2 else { return thinned.isEmpty ? [] : [WornRideSegment(range: 0..<thinned.count, verdict: .road)] }
        let runs = ferryRuns(thinned, geography: geography)
        var segments: [WornRideSegment] = []
        var landStart = 0
        // Bounded: one pass over the runs, at most maxSamples of them.
        for run in runs {
            var lower = run.range.lowerBound
            if lower > landStart {
                let land = landStart..<lower
                if length(thinned[land]) >= minLandSegmentMetres {
                    segments.append(WornRideSegment(range: land, verdict: landVerdict(thinned[land], geography: geography,
                                                                                          learnedRail: learnedRail)))
                } else {
                    lower = landStart
                }
            }
            segments.append(WornRideSegment(range: lower..<run.range.upperBound,
                                            verdict: WornRideVerdict(kind: .ferry, confidence: run.confidence)))
            landStart = run.range.upperBound
        }
        if landStart < thinned.count {
            let land = landStart..<thinned.count
            if let last = segments.last, length(thinned[(land.lowerBound - 1)..<land.upperBound]) < minLandSegmentMetres {
                segments[segments.count - 1] = WornRideSegment(range: last.range.lowerBound..<land.upperBound, verdict: last.verdict)
            } else {
                segments.append(WornRideSegment(range: land, verdict: landVerdict(thinned[land], geography: geography,
                                                                                      learnedRail: learnedRail)))
            }
        }
        return segments
    }

    /// `samples` cut to at most ``maxSamples`` by keeping every n-th (and always the last), so a long ride is judged
    /// along its whole length.
    public static func thin(_ samples: [WornRideSample]) -> [WornRideSample] {
        guard samples.count > maxSamples else { return samples }
        let stride = (samples.count + maxSamples - 1) / maxSamples
        var kept: [WornRideSample] = []
        kept.reserveCapacity(maxSamples)
        // Bounded: samples.count / stride ≤ maxSamples.
        for index in Swift.stride(from: 0, to: samples.count, by: stride) { kept.append(samples[index]) }
        if let last = samples.last, kept.last != last {
            if kept.count >= maxSamples { kept.removeLast() }
            kept.append(last)
        }
        return kept
    }

    // MARK: Ferry runs

    /// One crossing: the samples over water and how sure.
    struct FerryRun {
        let range: Range<Int>
        let confidence: WornRideConfidence
    }

    /// The runs over water in `samples` that pass the ferry rules, in order.
    static func ferryRuns(_ samples: [WornRideSample], geography: some WornTransitGeography) -> [FerryRun] {
        let water = samples.map { geography.isWater($0.point) }
        let speeds = speeds(samples[...])
        var runs: [FerryRun] = []
        var index = 0
        // Bounded: index only moves forward, at most samples.count steps in all.
        while index < samples.count {
            guard water[index] else {
                index += 1
                continue
            }
            let start = index
            var end = index + 1
            var gap = 0
            while end < samples.count {
                if water[end] {
                    gap = 0
                } else {
                    gap += 1
                    if gap > ferryLandGap { break }
                }
                end += 1
            }
            // Trim the land samples the gap allowance took past the run's last water sample.
            while end > start + 1, !water[end - 1] { end -= 1 }
            if let run = ferryRun(start..<end, samples: samples, speeds: speeds, geography: geography) { runs.append(run) }
            index = end
        }
        return runs
    }

    /// The crossing over `range`, when it is one.
    private static func ferryRun(_ range: Range<Int>, samples: [WornRideSample], speeds: [Double?],
                                 geography: some WornTransitGeography) -> FerryRun? {
        guard range.count >= 2, length(samples[range]) >= ferryMinWaterMetres else { return nil }
        guard let median = median(range.compactMap { speeds[$0] }), median >= ferryMinSpeed, median <= ferryMaxSpeed else { return nil }
        let onRoad = range.filter { geography.isNearMajorRoad(samples[$0].point, within: bridgeRoadMetres) }.count
        guard Double(onRoad) < bridgeMaxRoadShare * Double(range.count) else { return nil }
        let nearRoute = range.filter { geography.isNearFerryRoute(samples[$0].point, within: ferryRouteMetres) }.count
        let followsRoute = Double(nearRoute) >= ferryRouteShare * Double(range.count)
        let docksAtStart = docks(around: range.lowerBound, speeds: speeds)
        let docksAtEnd = docks(around: range.upperBound - 1, speeds: speeds)
        return FerryRun(range: range, confidence: followsRoute || (docksAtStart && docksAtEnd) ? .sure : .unsure)
    }

    /// Whether a sample within ``dockingReach`` of `edge` (on both sides of it) went at docking speed.
    private static func docks(around edge: Int, speeds: [Double?]) -> Bool {
        let low = max(0, edge - dockingReach), high = min(speeds.count - 1, edge + dockingReach)
        guard low <= high else { return false }
        return (low...high).contains { index in
            guard let speed = speeds[index] else { return false }
            return speed <= dockingSpeed
        }
    }

    // MARK: Trains

    /// The verdict for a stretch of land: a train by the rules above, else a road.
    static func landVerdict(_ samples: ArraySlice<WornRideSample>, geography: some WornTransitGeography,
                            learnedRail: (HexCell) -> Bool) -> WornRideVerdict {
        guard samples.count >= 2, !samples.contains(where: { $0.inCar == true }) else { return .road }
        let total = length(samples)
        guard total >= minTrainMetres else { return .road }
        let count = Double(samples.count)
        let nearRail = samples.filter { geography.isNearRail($0.point, within: railMetres) }.count
        let learned = samples.filter { onLearnedRail($0.point, learnedRail) }.count
        var strong = 0
        if Double(nearRail) >= railShare * count { strong += 1 }
        if Double(learned) >= learnedShare * count { strong += 1 }
        if fastTime(samples) >= fastSeconds { strong += 1 }
        guard strong > 0 else { return .road }
        let stops = stopCount(samples)
        let busLike = stops >= busMinStops && total / Double(stops) < busStopSpacing
        let spacedStops = stops >= 1 && total / Double(stops) >= trainStopSpacing
        let awayFromRoads = longestAwayStretch(samples, geography: geography) >= awayStretchMetres
        let sure = !busLike && (strong >= 2 || (spacedStops && awayFromRoads))
        return WornRideVerdict(kind: .rail, confidence: sure ? .sure : .unsure)
    }

    /// Whether `point`'s cell, or one beside it, is learned rail.
    private static func onLearnedRail(_ point: GeoPoint, _ learnedRail: (HexCell) -> Bool) -> Bool {
        let cell = MercatorHexGrid.cell(containing: point)
        return learnedRail(cell) || MercatorHexGrid.neighbours(of: cell).contains(where: learnedRail)
    }

    /// Seconds spent between two samples both above ``fastSpeed``.
    private static func fastTime(_ samples: ArraySlice<WornRideSample>) -> TimeInterval {
        let speeds = speeds(samples)
        var seconds: TimeInterval = 0
        var previous: (at: Date, fast: Bool)?
        // Bounded: one pass.
        for (offset, sample) in samples.enumerated() {
            let fast = (speeds[offset] ?? 0) > fastSpeed
            if let previous, previous.fast, fast { seconds += max(0, sample.at.timeIntervalSince(previous.at)) }
            previous = (sample.at, fast)
        }
        return seconds
    }

    /// How many stops: gaps of at least ``stopSeconds`` crossed at under ``stopSpeed`` (a run of them is one stop).
    private static func stopCount(_ samples: ArraySlice<WornRideSample>) -> Int {
        var stops = 0
        var stopped = false
        var previous: WornRideSample?
        // Bounded: one pass.
        for sample in samples {
            defer { previous = sample }
            guard let previous else { continue }
            let seconds = sample.at.timeIntervalSince(previous.at)
            let isStop = seconds >= stopSeconds && previous.point.distance(to: sample.point) / seconds < stopSpeed
            if isStop, !stopped { stops += 1 }
            stopped = isStop
        }
        return stops
    }

    /// The longest stretch, in metres, whose samples are all more than ``awayFromRoadMetres`` from a major road.
    private static func longestAwayStretch(_ samples: ArraySlice<WornRideSample>, geography: some WornTransitGeography) -> Double {
        var longest = 0.0, current = 0.0
        var previous: GeoPoint?
        // Bounded: one pass.
        for sample in samples {
            if geography.isNearMajorRoad(sample.point, within: awayFromRoadMetres) {
                current = 0
                previous = nil
                continue
            }
            if let previous { current += previous.distance(to: sample.point) }
            longest = max(longest, current)
            previous = sample.point
        }
        return longest
    }

    // MARK: Shared

    /// Each sample's speed: CoreLocation's when it gave a valid one, else the pace from the sample before (or after,
    /// for the first); nil when neither is known.
    static func speeds(_ samples: ArraySlice<WornRideSample>) -> [Double?] {
        let list = Array(samples)
        return list.indices.map { index in
            if let speed = list[index].speed, speed >= 0, speed.isFinite { return speed }
            let other = index > 0 ? index - 1 : index + 1
            guard other < list.count else { return nil }
            let seconds = abs(list[index].at.timeIntervalSince(list[other].at))
            guard seconds > 0 else { return nil }
            return list[index].point.distance(to: list[other].point) / seconds
        }
    }

    /// The length along `samples`, in metres.
    static func length(_ samples: ArraySlice<WornRideSample>) -> Double {
        zip(samples.dropLast(), samples.dropFirst()).reduce(0) { $0 + $1.0.point.distance(to: $1.1.point) }
    }

    /// The median of `values`, or nil when empty.
    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
