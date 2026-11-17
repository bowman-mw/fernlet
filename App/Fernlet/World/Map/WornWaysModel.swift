import Foundation
import Observation
import os
import WorldMapStore

/// What one worn-ways update works from (``FernletStore/wornWaysRequest(trails:trailStamp:now:defaults:)``).
nonisolated struct WornWaysRequest: Sendable {
    /// Whether worn ways show at all ("Show worn paths" on, no decoy).
    var shows: Bool
    /// The workouts whose saved lines wear footpaths (empty while Save new routes is off).
    var routeIDs: Set<UUID>
    /// The road counter.
    var roads: [WornWayKey: WornTally]
    /// Today's ``WornDay`` number, for fading.
    var today: UInt16
    /// Home's saved trails, to cut where a footpath shows.
    var trails: [[GeoPoint]]
    /// Which reading of Home's trails these are.
    var trailStamp: Int
}

/// Home's worn paths and frequent roads, worked out off the main actor as ``WorldCrossedRoadsModel`` does: nothing is
/// stored, so a wipe, a decoy and a fresh history each give their own answer. One update runs at a time; a request
/// while one runs waits, only the newest kept.
///
/// The footpath index grows: each new saved line is read (on the main actor: the route store is the vault's) and
/// folded in off it, in batches of ``readBatch``, so the first build after launch never holds the main actor for long
/// and a new walk later costs one file. A removed line or a switch turned off starts it again.
@MainActor
@Observable
final class WornWaysModel {
    /// The lines read on the main actor before each fold off it.
    static let readBatch = 24

    /// What the map draws.
    private(set) var drawing = WornWaysDrawing.none

    @ObservationIgnored private let box = WornFootpathIndexBox()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pending: WornWaysRequest?
    /// Workouts with a line but no diary entry (left out until the index starts again, so no update reads the whole
    /// history for them twice).
    @ObservationIgnored private var orphans = Set<UUID>()
    @ObservationIgnored private weak var store: FernletStore?

    /// An update still running ends with the model (the memory wall's ML1).
    isolated deinit {
        task?.cancel()
    }

    /// Works the drawing out for `request`, reading new lines through `store`.
    func update(_ request: WornWaysRequest, store: FernletStore) {
        self.store = store
        guard task == nil else {
            pending = request
            return
        }
        run(request)
    }

    /// One update, then the newest waiting one.
    private func run(_ request: WornWaysRequest) {
        task = Task { [weak self] in
            await self?.work(request)
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            guard let next = self.pending else { return }
            self.pending = nil
            self.run(next)
        }
    }

    /// Brings the index up to `request`'s lines and works the drawing out.
    private func work(_ request: WornWaysRequest) async {
        let started = ContinuousClock.now
        guard request.shows else {
            box.index = WornFootpathIndex()
            orphans = []
            drawing = WornWaysDrawing(generation: drawing.generation &+ 1, footpaths: [], roads: [], trails: request.trails,
                                      trailStamp: request.trailStamp, contentHash: 0)
            return
        }
        let mainTime = await fold(request.routeIDs)
        guard !Task.isCancelled else { return }
        let box = self.box, generation = drawing.generation &+ 1
        let made = await Task.detached(priority: .utility) {
            WornWaysBuilder.make(index: box.index, ways: request.roads, today: request.today, trails: request.trails,
                                 trailStamp: request.trailStamp, generation: generation)
        }.value
        guard !Task.isCancelled else { return }
        drawing = made
        Self.log(started: started, mainTime: mainTime, routes: box.index.days.count, drawing: made)
    }

    /// Folds the lines of `ids` not yet in the index into it, oldest first (starting again when one went away or a
    /// new one is older than the newest folded). What the main actor spent, reading. Bounded: at most
    /// ``WornFootpaths/maxRoutes`` lines, in batches.
    private func fold(_ ids: Set<UUID>) async -> Duration {
        var mainTime = Duration.zero
        guard let store else { return mainTime }
        var clock = ContinuousClock.now
        if !box.index.days.keys.allSatisfy(ids.contains) {
            box.index = WornFootpathIndex()
            orphans = []
        }
        var missing = ids.subtracting(box.index.days.keys).subtracting(orphans)
        var days = store.wornRouteDays(for: missing)
        if let oldest = days.values.min(), !box.index.takesInOrder(oldest) {
            box.index = WornFootpathIndex()
            missing = ids.subtracting(orphans)
            days = store.wornRouteDays(for: missing)
        }
        orphans.formUnion(missing.filter { days[$0] == nil })
        let order = days.sorted { ($0.value, $0.key.uuidString) < ($1.value, $1.key.uuidString) }.prefix(WornFootpaths.maxRoutes)
        mainTime += ContinuousClock.now - clock
        let box = self.box
        for start in stride(from: order.startIndex, to: order.endIndex, by: Self.readBatch) {
            guard !Task.isCancelled else { break }
            clock = ContinuousClock.now
            let batch = order[start..<min(start + Self.readBatch, order.endIndex)].map { entry in
                (id: entry.key, day: entry.value, line: store.worldRoute(for: entry.key)?.map(\.point) ?? [])
            }
            mainTime += ContinuousClock.now - clock
            await Task.detached(priority: .utility) {
                for route in batch { box.index.add(route.id, day: route.day, line: route.line) }
            }.value
        }
        return mainTime
    }

    /// DEBUG: how long an update took, and how much of it on the main actor.
    private static func log(started: ContinuousClock.Instant, mainTime: Duration, routes: Int, drawing: WornWaysDrawing) {
        #if DEBUG
        let total = ContinuousClock.now - started
        Logger(subsystem: "com.fernlet", category: "wornWays").debug(
            "worn ways: \(routes) lines, \(drawing.footpaths.count) path pieces, \(drawing.roads.count) road pieces in \(total), main \(mainTime)")
        #endif
    }
}
