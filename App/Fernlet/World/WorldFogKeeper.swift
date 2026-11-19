import FernletFoundation
import Foundation
import UIKit
import WorldMapStore

/// Decides whether a location reading lifts the fog, and keeps the lifted cells (World app plan step
/// 5a; design page answers 4, 10 and 21).
///
/// A reading lifts the cells within ``liftRadius`` of it only when all of these hold: "Uncover the map
/// as you go" is on (`WorldMapPreferences`, default on), the person allowed precise location, and the
/// reading is accurate to ``maxAccuracy``. Approximate location places the companion in the area and
/// lifts nothing.
///
/// **In a car** (round 7, `nf-car`; width the owner's pick 2026-10-30, option B) a reading lifts ``driveRadius``
/// either side of the road, joined to the drive's last reading every ``joinStep`` so the lane has no gaps (up to
/// ``maxJoin`` apart), not the 50-m circle (``handle(_:saveNow:thinLine:)``; the store passes whether car
/// detection says the person is driving). Walks and bike rides keep the circle.
///
/// **Driven, not walked** (owner 2026-11-09: "driven should be mostly transparent but still there, then you fully unlock
/// when you walk"): the cells a drive newly uncovers are also kept as ``drivenCells`` (`DrivenFogStore`), which the
/// map draws as see-through fog; walking or riding a bike through one makes it fully clear for good. Every uncovered
/// cell stays in the fog store, so the passport, the city card's share and roads crossed, and furthest from home
/// count a drive as before; only the week's new corner needs walking (``currentCorner(home:now:)``). What was
/// uncovered before this stays clear. While the phone is locked a drive's cells wait in their own buffer and are
/// merged at the next load with what was walked meanwhile.
///
/// **Duress.** In a decoy session nothing is read from or written to the store: the map shows only the
/// cells lifted during the decoy itself, held in memory and dropped when the decoy ends, so a coerced
/// unlock reveals no history and leaves none behind. The silent wipe and Delete everything reach
/// ``clearAll()`` through `FernletStore.resetAll()`; the recovery lock through its own purge hook.
///
/// **The map widget's picture** (round 6b, owner's Q36) goes with the history: ``clearAll()`` (every wipe,
/// the recovery lock and "Delete map history") and entering a decoy delete it and reload the widget, which
/// then draws no map (a decoy's map is none). ``widgetMapGeneration`` moves each time, so a picture rendered
/// across one of them is never written (`WorldWidgetMapWriter`).
///
/// **The drive widget** (owner's pick 2026-11-13, the CarPlay small widget): ``driveWidget`` counts a drive's new
/// tiles, those also while the phone is locked if the history was read before it locked, and goes with the picture.
/// The widget runs on the iPhone like the rest of Fernlet, so it saves no battery itself: what a drive costs is the
/// trace's (`WorldLocationSource`).
///
/// **Inside an airport's grounds only walking clears** (owner 2026-11-02, decided 2026-11-13): a reading there faster
/// than walking (the plane train, a people mover, a taxiing plane, a car on the airport's roads) lifts nothing, so
/// the terminals and concourses walked through clear under the grounds' see-through fog and the ones passed under or
/// by do not.
///
/// **Faster than a car, off a drive, is no walk** (owner 2026-11-15): walking a moving ferry's deck or a train's aisle
/// ends the drive (Motion says walking) while the readings still go by at the boat's speed. A reading faster than
/// `WorldRideWatch.carSpeed` by CoreLocation's own speed lifts the drive's see-through lane instead of the walked
/// circle (``ridesOffADrive(_:)``), so the crossing shows as driven and only walking on land clears it.
///
/// **The passport and the odd hidden tiles** (round 7). ``atlas`` reads only the readings this keeper accepts,
/// only while the phone is unlocked and never in a decoy, and goes with every wipe through ``clearAll()``.
/// A lift also lifts any single cell it left fogged with all six neighbours open (`FogGapCloser`), in a
/// decoy's own cells too.
///
/// **The week's new corner** (round 7, spec §5). ``cornerNudge`` picks it only from the loaded history, through
/// ``currentCorner(home:now:)``, hears every lift (its gap closings included) so a corner walked into goes at
/// once, shows none in a decoy, and goes with every wipe through ``clearAll()``.
///
/// **A road trip** (owner-approved 2026-11-10, World-RoadTrip-Spec PR 1). ``roadTrip`` keeps the trip on now and its
/// timed line: every reading this keeper accepts also joins the line while this iPhone maps (``handle(_:saveNow:thinLine:)``,
/// the store's readings and the locked launch's alike), under the buffer key, so it grows with the phone locked. It
/// follows the decoy (``setDecoy(_:)``), writes with ``flush()`` and goes with every wipe through ``clearAll()``. The
/// road friends hand over at a catch-up (PR 2) lifts as driven cells through ``liftReceivedRoad(_:)``.
///
/// **Frequent roads** (option B, owner 2026-11-15). A walk, an airport ride, a decoy or 10 minutes without a drive
/// reading ends a drive trip, which saves and publishes ``wornWays``. A road friends hand over never counts.
///
/// **Ferry and train paths** (owner 2026-11-15, World-Transit-Paths-Exploration §9). A drive trip keeps its readings
/// in memory, thinned to ``rideSpacing`` (`WorldFogKeeper+WornTrips.swift`), and counts nothing until it ends. Then
/// `WornRideClassifier` (off the main actor, over ``transitGeography``; none means a road) splits it into road, rail
/// and ferry stretches; each is kept as a `WornTrip` in the sealed `WornTripStore` (forever, until forgotten or the
/// map is cleared) and the cells of its thinned line count once under its kind in the ``WornWayStore`` (its locked
/// buffer while the phone is locked). A ride in progress is checkpointed every ``rideCheckpointEvery`` so a suspended
/// app keeps it. An unsure guess becomes ``transitQuestion``, at most once a day. Fog lifting is unchanged: a train or
/// a ferry still lifts the see-through driven lane.
///
/// **A locked phone.** The store's key works only while the phone is unlocked, so readings that
/// arrive while it is locked (a walk with the screen off, Always mode's visits) go into the
/// locked-phone buffer and are merged on the next ``load()``.
@MainActor
@Observable
final class WorldFogKeeper {
    /// How far around a precise reading the fog lifts, in metres.
    static let liftRadius = 50.0
    /// How far either side of the road a drive lifts, in metres (owner 2026-10-30: "~50–60 m", option B; the
    /// one cell under each reading was too small).
    static let driveRadius = 25.0
    /// How far apart the points joining two drive readings are, in metres (closer than ``driveRadius``, so the
    /// circles overlap into one lane).
    static let joinStep = 15.0
    /// Drive readings further apart than this are not joined (a tunnel, a jump), in metres.
    static let maxJoin = 500.0
    /// The most joining points between two readings (a bound; ``maxJoin`` ÷ ``joinStep`` is fewer).
    static let maxJoinSteps = 40
    /// The worst accuracy a reading may have and still lift the fog, in metres.
    static let maxAccuracy = 65.0
    /// New cells between saves while the app is open (saves also happen on ``flush()``).
    static let saveEvery = 40
    /// On a drive, the least time between two of those saves, in seconds (location power, owner 2026-11-17, option F):
    /// a drive reaches ``saveEvery`` every few readings, and each save reseals the whole history on the main thread.
    /// Leaving the front, a walk, a trip's end and a locked phone still write at once, so an app killed mid-drive
    /// loses at most this long of driven cells.
    static let driveSaveGap: TimeInterval = 60
    /// How far apart a drive's centre line is sampled when counting worn roads, in metres: under a hex's 17.5 m
    /// radius, so no cell the line crosses is skipped (``WornFootpaths/sampleStep``).
    static let wornStep = WornFootpaths.sampleStep
    /// The most samples between two drive readings on the centre line (``maxJoin`` ÷ ``wornStep`` is fewer).
    static let maxWornSteps = 64
    /// Drive readings further apart in time than this start a new trip for the worn-road count, in seconds.
    static let tripGap: TimeInterval = 10 * 60
    /// How far apart a ride's kept readings are at least, in metres (doubled each time a long ride reaches
    /// `WornRideClassifier.maxSamples`).
    static let rideSpacing = 25.0
    /// How often a ride in progress is written to its checkpoint, in seconds of the ride.
    static let rideCheckpointEvery: TimeInterval = 3 * 60
    /// How many days back an unsure ride may still be asked about (today and yesterday).
    static let questionDays: UInt16 = 1

    /// The cells the map draws: the whole lifted history, or in a decoy session only the decoy's own.
    private(set) var visibleCells: Set<HexCell> = []
    /// Those of them only driven past, never walked, which the map draws as see-through fog (owner 2026-11-09); the
    /// history's, or in a decoy session the decoy's own.
    private(set) var drivenCells: Set<HexCell> = []
    /// The kept trips (ferry and train build, owner 2026-11-15: every drive-speed ride, kept until forgotten or the map
    /// is cleared), newest first, without their lines (a forever history never sits in memory as lines; ask
    /// ``trips(through:)`` for those). Empty in a decoy session.
    var wornTrips: [WornTripSummary] = []
    /// The trip Home asks about ("Was that a train?", owner's C1: at most once a day), or nil.
    var transitQuestion: WornTrip?
    /// The ground under a trip (shore pack, atlas roads, rail pack) for telling a ferry or a train from a drive; set
    /// once the packs load. Nil classifies every trip as a road.
    @ObservationIgnored var transitGeography: (any WornTransitGeography)?
    /// Whether a decoy session is showing.
    private(set) var isDecoy = false
    /// The frequent roads the map draws: each way's trip count and last day (option B, owner 2026-11-15), published
    /// when a drive's trip ends, on ``flush()`` and after the unlock merge (not on every reading, to keep redraws rare).
    /// Empty in a decoy session.
    private(set) var wornWays: [WornWayKey: WornTally] = [:]
    /// The drive's last lifted reading, which the next joins; nil off a drive.
    @ObservationIgnored private var laneFrom: GeoPoint?

    /// The World passport (round 7): the first visits the accepted readings make, sealed in the vault.
    @ObservationIgnored let atlas: WorldAtlasKeeper
    /// The weekly new corner (round 7, spec §5), sealed in the vault; Home asks ``currentCorner(home:now:)``.
    @ObservationIgnored let cornerNudge: WorldCornerNudgeKeeper
    /// The road trip on now and the line this iPhone records while it maps (owner-approved 2026-11-10), sealed in the
    /// vault under the buffer key.
    @ObservationIgnored let roadTrip: RoadTripKeeper
    @ObservationIgnored let store: FogCellStore
    /// The cells only driven past (owner 2026-11-09), beside the fog store, which still holds every lifted cell.
    @ObservationIgnored private let driven: DrivenFogStore
    /// The frequent-roads counter (option B), beside the fog: one count per cell per drive trip, with its last day.
    @ObservationIgnored let worn: WornWayStore
    /// The kept trips (ferry and train build), sealed under the buffer key so a ride ending locked is kept.
    @ObservationIgnored let tripStore: WornTripStore
    /// This ride's readings so far, at least ``rideSpacing`` apart (more apart on a long ride), oldest first.
    @ObservationIgnored var rideSamples: [WornRideSample] = []
    /// The ride's newest reading, kept or not (the ride's end).
    @ObservationIgnored var rideLast: WornRideSample?
    /// The spacing the ride's readings are kept at now.
    @ObservationIgnored var rideSpacingNow = WorldFogKeeper.rideSpacing
    /// The ride time the checkpoint was last written at.
    @ObservationIgnored var rideCheckpointAt: Date?
    /// Whether the checkpoint left by an earlier launch was looked at.
    @ObservationIgnored var rideRestored = false
    /// Moves with every wipe, so a ride classified across one is never kept.
    @ObservationIgnored var tripGeneration = 0
    /// Rides being classified off the main actor (tests await them through ``settleTrips()``).
    @ObservationIgnored var tripTasks: [UUID: Task<Void, Never>] = [:]
    /// Those rides' samples, so a decoy starting can keep them at once (``setDecoy(_:)``).
    @ObservationIgnored var tripRides: [UUID: [WornRideSample]] = [:]
    /// Today's date (tests set a clock).
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }
    /// When this trip's last accepted drive reading was taken; nil off a drive.
    @ObservationIgnored var lastDriveAt: Date?
    /// Whether ``worn`` holds counts ``wornWays`` doesn't show yet.
    @ObservationIgnored var wornUnpublished = false
    @ObservationIgnored let vault: WorldMapVault
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let isProtectedDataAvailable: @MainActor () -> Bool
    @ObservationIgnored private var decoyCells: Set<HexCell> = []
    @ObservationIgnored private var decoyDriven: Set<HexCell> = []
    @ObservationIgnored private var sinceSave = 0
    /// When the last save a drive reading made was taken (``driveSaveGap``); nil before one.
    @ObservationIgnored private var lastDriveSave: Date?
    /// The map widget's picture in the app group (tests point it at their own folder).
    @ObservationIgnored var widgetMap: WorldWidgetMapFile
    /// Reloads the map widget once its picture is gone (tests count the calls).
    @ObservationIgnored var widgetMapReload: @MainActor () -> Void
    /// Moves each time the widget's picture is deleted (a wipe, Delete map history, a decoy).
    @ObservationIgnored private(set) var widgetMapGeneration = 0
    /// The drive widget's count and file (tests point it at their own folder).
    @ObservationIgnored var driveWidget = WorldDriveWidgetKeeper()
    /// Cells a drive uncovered while the phone was locked, counted once until the unlock merges them.
    @ObservationIgnored private var lockedFresh: Set<HexCell> = []
    /// How many cells the last lift newly uncovered (counted also while locked, against the history read before).
    @ObservationIgnored private var lastFresh = 0

    /// A keeper over `vault`. `isProtectedDataAvailable` reports whether the phone is unlocked (the
    /// app's `UIApplication` answer by default; tests inject one).
    init(vault: WorldMapVault, defaults: UserDefaults = .standard,
         isProtectedDataAvailable: (@MainActor () -> Bool)? = nil) {
        self.vault = vault
        self.store = FogCellStore(vault: vault)
        self.driven = DrivenFogStore(vault: vault)
        self.worn = WornWayStore(vault: vault)
        self.tripStore = WornTripStore(vault: vault)
        self.atlas = WorldAtlasKeeper(vault: vault, openAtlas: WorldAtlasKeeper.bundledPack { try WorldAtlas(data: $0) },
                                      openAtlasOffMain: WorldAtlasKeeper.bundledPackOffMain { try WorldAtlas(data: $0) },
                                      openLandmarks: WorldAtlasKeeper.bundledLandmarks(),
                                      openShore: WorldAtlasKeeper.bundledShore())
        self.cornerNudge = WorldCornerNudgeKeeper(vault: vault)
        self.roadTrip = RoadTripKeeper(vault: vault)
        self.defaults = defaults
        self.isProtectedDataAvailable = isProtectedDataAvailable ?? { UIApplication.shared.isProtectedDataAvailable }
        self.widgetMap = WorldWidgetMapFile()
        self.widgetMapReload = { WorldWidgetMap.reload() }
        roadTrip.uncoveredCount = { [weak self] in self?.uncoveredCellCount }
    }

    /// How many tiles the history holds now (a road trip's summary counts its new tiles from it, PR 4); nil in a
    /// decoy and before the history is read.
    var uncoveredCellCount: Int? {
        guard !isDecoy, store.isLoaded else { return nil }
        return store.cells.count
    }

    /// Reads the lifted history (and merges the locked-phone buffer) when the phone is unlocked and no
    /// decoy is showing. Safe to call on every foreground.
    ///
    /// The history is read once. Each later call keeps the cells in memory: it saves any not yet written
    /// and merges the buffer. Cells lifted under a panel are therefore never thrown back to the disk copy
    /// (location keeps running under panels, W-09), and Home coming to the front decrypts nothing.
    func load() {
        // The road trip's book is under the buffer key, so it reads with the phone locked too (never in a decoy), and a
        // trip seven days without a catch-up ends here at its mark (PR 4).
        roadTrip.load()
        roadTrip.endIfQuiet()
        // The kept trips and a ride an earlier launch left are under the buffer key too, so they read locked.
        loadTrips()
        guard !isDecoy, isProtectedDataAvailable() else { return }
        guard !store.isLoaded else {
            mergeWhileLoaded()
            atlas.load()
            return
        }
        do {
            try store.load()
            try driven.load()
            try mergeDriven()
            try worn.load()
            try mergeWorn()
        } catch {
            FernletAuditLog.log("worldMap.fog.loadDeferred")
            return
        }
        visibleCells = store.cells
        drivenCells = driven.cells
        publishWorn()
        refreshTransitQuestion()
        atlas.load()
    }

    /// Folds what the phone buffered while locked into the driven cells (owner 2026-11-09): what was walked meanwhile
    /// (the fog buffer the store just drained) is walked, and a drive's buffered cells join the fog, driven unless
    /// they were walked before or meanwhile. The buffer is emptied only after the fog and the driven cells are saved
    /// (release review F3): a failed save leaves it for the next unlock, and merging it twice is harmless.
    private func mergeDriven() throws {
        guard driven.isLoaded else { return }
        driven.remove(store.lastDrained)
        let pending = try driven.pending()
        if !pending.isEmpty {
            let walked = store.cells.subtracting(driven.cells)
            store.lift(Array(pending))
            driven.add(Array(pending.subtracting(walked)))
            try store.save()
        }
        try driven.save()
        if !driven.clearPending() { FernletAuditLog.log("worldMap.fog.drivenBufferKept") }
    }

    /// Counts the ways a drive passed while the phone was locked (each with its day, oldest first), saves, and only
    /// then empties the buffer, so a failed save leaves it for the next unlock.
    private func mergeWorn() throws {
        guard worn.isLoaded else { return }
        let pending = try worn.pending()
        guard !pending.isEmpty else {
            worn.clearPending()
            return
        }
        var byDayAndKind: [UInt16: [WornWayKind: [HexCell]]] = [:]
        // Bounded: the buffer holds at most FogCellStore.maxPendingCells records.
        for (key, day) in pending.prefix(FogCellStore.maxPendingCells) {
            byDayAndKind[day, default: [:]][key.kind, default: []].append(key.cell)
        }
        // Bounded: one group per (day, kind) in the buffer.
        for day in byDayAndKind.keys.sorted() {
            for kind in WornWayKind.allCases {
                if let cells = byDayAndKind[day]?[kind] { worn.record(cells, kind: kind, on: day) }
            }
        }
        wornUnpublished = true
        try worn.save()
        if !worn.clearPending() { FernletAuditLog.log("worldMap.fog.wornBufferKept") }
    }

    /// Lifts the fog around `fix` when the rules allow; returns how many cells were new. With `saveNow`
    /// (a reading delivered while the app isn't active: background mapping, a walk with Maps in front) new
    /// cells are written at once rather than at the next 40, since iOS may end a suspended app first (W-09 B2).
    /// With `thinLine` (driving, `nf-car`) the drive's lane lifts: ``driveRadius`` around the reading, joined
    /// to the drive's last reading. An accepted reading also joins a road trip's line while this iPhone maps
    /// (``roadTrip``), written at once with `saveNow`.
    @discardableResult
    func handle(_ fix: WorldFix, saveNow: Bool = false, thinLine: Bool = false) -> Int {
        let added: Int
        let accepted = accepts(fix)
        lastFresh = 0
        if Self.ridesThroughAirport(fix) {
            // The plane train, a people mover, a car on the airport's roads: nothing lifts, and no lane joins across.
            laneFrom = nil
            endTrip()
            added = 0
        } else if thinLine || Self.ridesOffADrive(fix) {
            if let lastDriveAt, fix.at.timeIntervalSince(lastDriveAt) > Self.tripGap { endTrip() }
            added = lift(fix, cells: Self.lane(from: laneFrom, to: fix.point), driving: true)
            if accepted {
                laneFrom = fix.point
                lastDriveAt = fix.at
                if !isDecoy { noteRide(fix) }
            }
        } else {
            laneFrom = nil
            endTrip()
            added = lift(fix, cells: MercatorHexGrid.cells(around: fix.point, within: Self.liftRadius), driving: false)
        }
        if accepted { roadTrip.record(fix, saveNow: saveNow) }
        if saveNow, added > 0 { flush() }
        if accepted, !isDecoy { driveWidget.note(driving: thinLine, newTiles: thinLine ? lastFresh : 0, at: fix.at) }
        return added
    }

    /// Whether `fix` is inside an airport's grounds faster than walking: it lifts nothing (only walking clears there).
    static func ridesThroughAirport(_ fix: WorldFix) -> Bool {
        fix.atAirport && (fix.speed ?? 0) > WorldRideWatch.walkingSpeed
    }

    /// Whether `fix`, not on a drive, went faster than a car's speed by CoreLocation's own reading (owner 2026-11-15): a
    /// ferry's deck or a train's aisle walked while Motion says walking. It lifts the drive's see-through lane, never the
    /// walked circle; a run or a bike ride below a car's speed keeps the circle.
    static func ridesOffADrive(_ fix: WorldFix) -> Bool {
        (fix.speed ?? 0) > WorldRideWatch.carSpeed
    }

    /// The cells a drive reading at `point` lifts: ``driveRadius`` around it and around the points every
    /// ``joinStep`` back to `from` (the drive's last reading) when that is within ``maxJoin``.
    static func lane(from: GeoPoint?, to point: GeoPoint) -> [HexCell] {
        guard let from, from.distance(to: point) <= maxJoin else {
            return MercatorHexGrid.cells(around: point, within: driveRadius)
        }
        let steps = max(1, min(maxJoinSteps, Int((from.distance(to: point) / joinStep).rounded(.up))))
        var cells = Set<HexCell>()
        for step in 1...steps {
            cells.formUnion(MercatorHexGrid.cells(around: from.lerp(to: point, Double(step) / Double(steps)), within: driveRadius))
        }
        return cells.sorted()
    }

    /// The cells under a drive's centre line from `from` (the drive's last reading) to `point`: the cell containing
    /// `point`, and those containing the points every ``wornStep`` back to `from` when that is within ``maxJoin``: the
    /// cells a ride's line passes, as `WornFootpaths.cells(along:)` counts them at the trip's end, not the 25 m lane
    /// either side.
    static func centreLine(from: GeoPoint?, to point: GeoPoint) -> [HexCell] {
        guard let from, from.distance(to: point) <= maxJoin else { return [MercatorHexGrid.cell(containing: point)] }
        let steps = max(1, min(maxWornSteps, Int((from.distance(to: point) / wornStep).rounded(.up))))
        var cells = Set<HexCell>()
        for step in 1...steps {
            cells.insert(MercatorHexGrid.cell(containing: from.lerp(to: point, Double(step) / Double(steps))))
        }
        return cells.sorted()
    }

    /// Whether the rules let `fix` lift the fog: "Uncover the map as you go" on, precise, accurate enough.
    private func accepts(_ fix: WorldFix) -> Bool {
        WorldMapPreferences.uncoverAsYouGo(in: defaults) && fix.isPrecise && fix.accuracy <= Self.maxAccuracy
            && fix.point.isValid
    }

    /// Lifts `cells` (around `fix`) when the rules allow `fix`; returns how many cells were new. `driving`: the cells
    /// it newly uncovers are only driven past (see-through fog, owner 2026-11-09), and the week's corner isn't walked
    /// into; otherwise every cell it reaches is walked, driven no more. A drive's ways count when its trip ends.
    private func lift(_ fix: WorldFix, cells: [HexCell], driving: Bool) -> Int {
        guard accepts(fix) else { return 0 }
        guard !isDecoy else { return liftDecoy(cells, driving: driving) }
        guard isProtectedDataAvailable(), store.isLoaded else {
            if driving, store.isLoaded { countLockedFresh(cells) }
            bufferWhileLocked(cells, driving: driving)
            return 0
        }
        let fresh = cells.filter { !store.cells.contains($0) }
        let lifted = store.lift(cells)
        let gaps = FogGapCloser.closing(around: cells, in: store.cells)
        let added = lifted + store.lift(gaps)
        if driving { lastFresh = added }
        if driving { driven.add(fresh + gaps) } else { driven.remove(cells + gaps) }
        // Inside the grounds just landed at, the passport waits for the person to leave (the flight gate).
        if !fix.atLandedAirport { atlas.observe(point: fix.point, at: fix.at) }
        if !driving { cornerNudge.noteRevealed(cells + gaps) }
        // Published only when they changed (option F): each publish re-runs Home's body, and a copy shared with the
        // fog's tiles makes the next lift copy the whole history.
        if added > 0 { visibleCells = store.cells }
        if driven.cells.count != drivenCells.count { drivenCells = driven.cells }
        sinceSave += added
        if Self.savesNow(unsaved: sinceSave, driving: driving, at: fix.at, lastDriveSave: lastDriveSave) {
            if driving { lastDriveSave = fix.at }
            flush()
        }
        return added
    }

    /// Whether `unsaved` new cells are written now: at ``saveEvery`` on foot; on a drive (`driving`, a reading taken
    /// `at`) also only once ``driveSaveGap`` has passed since `lastDriveSave`.
    static func savesNow(unsaved: Int, driving: Bool, at: Date, lastDriveSave: Date?) -> Bool {
        guard unsaved >= saveEvery else { return false }
        guard driving, let lastDriveSave else { return true }
        return at.timeIntervalSince(lastDriveSave) >= driveSaveGap || at < lastDriveSave
    }

    /// A road trip's road received at a catch-up (World-RoadTrip-Spec §2.6: "Every phone's fog lifts along its stretch
    /// as driven cells"): the drive's lane along `points` (oldest first; ``driveRadius`` either side, joined every
    /// ``joinStep`` up to ``maxJoin``) lifts as **driven** cells, never walked, so it shows see-through like any drive;
    /// what was uncovered before stays as it was. Only with "Uncover the map as you go" on, never in a decoy; with the
    /// phone locked the cells wait in the driven buffer. Nothing reaches the passport or the week's corner (the
    /// readings were a friend's phone's). Written at once. How many cells were new.
    func liftReceivedRoad(_ points: [GeoPoint]) -> Int {
        guard !isDecoy, WorldMapPreferences.uncoverAsYouGo(in: defaults), !points.isEmpty else { return 0 }
        var lane = Set<HexCell>()
        var from: GeoPoint?
        // R2: bounded by the line's own bound.
        for point in points.prefix(RoadTripLine.maxPoints) where point.isValid {
            lane.formUnion(Self.lane(from: from, to: point))
            from = point
        }
        let cells = Array(lane)
        guard !cells.isEmpty else { return 0 }
        guard isProtectedDataAvailable(), store.isLoaded else {
            bufferWhileLocked(cells, driving: true)
            return 0
        }
        let fresh = cells.filter { !store.cells.contains($0) }
        let lifted = store.lift(cells)
        let gaps = FogGapCloser.closing(around: cells, in: store.cells)
        let added = lifted + store.lift(gaps)
        driven.add(fresh + gaps)
        visibleCells = store.cells
        drivenCells = driven.cells
        flush()
        return added
    }

    /// A decoy's own lift, in memory only: the same rules over its own cells.
    private func liftDecoy(_ cells: [HexCell], driving: Bool) -> Int {
        let before = decoyCells.count
        let fresh = cells.filter { !decoyCells.contains($0) }
        decoyCells.formUnion(cells)
        let gaps = FogGapCloser.closing(around: cells, in: decoyCells)
        decoyCells.formUnion(gaps)
        if driving { decoyDriven.formUnion(fresh + gaps) } else { decoyDriven.subtract(cells + gaps) }
        visibleCells = decoyCells
        drivenCells = decoyDriven
        return decoyCells.count - before
    }

    /// Writes unsaved cells and a road trip's unsaved points (the app leaving the foreground, or a walk ending).
    func flush() {
        guard !isDecoy else { return }
        roadTrip.flush()
        do {
            try store.save()
            try driven.save()
            try worn.save()
            sinceSave = 0
        } catch {
            FernletAuditLog.log("worldMap.fog.saveDeferred")
        }
        publishWorn()
    }

    /// Shows the counter's tallies on the map when they changed since last shown (never in a decoy).
    func publishWorn() {
        guard !isDecoy, wornUnpublished || wornWays.count != worn.tallies.count else { return }
        wornWays = worn.tallies
        wornUnpublished = false
    }

    /// Enters or leaves a decoy session. Entering hides the history; leaving drops the decoy's own
    /// cells and shows the history again.
    func setDecoy(_ on: Bool) {
        guard on != isDecoy else { return }
        if on {
            // The real rides end before the decoy shows, classified here so nothing is written once it does.
            keepClassifyingRidesNow()
            endTrip(classifyNow: true)
            flush()
            // The decoy's map widget has no map: the real picture goes before anything of the decoy shows.
            if !removeWidgetMap() { FernletAuditLog.log("worldMap.widgetMap.decoyDeleteFailed") }
            if !driveWidget.clear() { FernletAuditLog.log("worldMap.widgetDrive.decoyDeleteFailed") }
        }
        lockedFresh = []
        isDecoy = on
        atlas.setDecoy(on)
        cornerNudge.setDecoy(on)
        roadTrip.setDecoy(on)
        decoyCells = []
        decoyDriven = []
        dropRide()
        lastDriveAt = nil
        visibleCells = on ? [] : store.cells
        drivenCells = on ? [] : driven.cells
        wornWays = on ? [:] : worn.tallies
        wornUnpublished = false
        wornTrips = on ? [] : tripStore.summaries
        if on { transitQuestion = nil } else { refreshTransitQuestion() }
    }

    /// The wipe: forgets the cells and the road trips and deletes every World map file and key, and the map widget's
    /// picture. Whether it all went.
    func clearAll() -> Bool {
        store.forget()
        driven.forget()
        worn.forget()
        roadTrip.forget()
        decoyCells = []
        decoyDriven = []
        visibleCells = []
        drivenCells = []
        wornWays = [:]
        wornUnpublished = false
        forgetTrips()
        lastDriveAt = nil
        sinceSave = 0
        lastDriveSave = nil
        let pictureGone = removeWidgetMap()
        let driveGone = driveWidget.clear()
        lockedFresh = []
        let passportGone = atlas.clearAll()
        let cornerGone = cornerNudge.clearAll()
        let vaultGone = vault.clearAll()
        return vaultGone && pictureGone && driveGone && passportGone && cornerGone
    }

    /// This week's new corner near `home` (the person's first home, `HomeBook.homes.first?.point`), picked
    /// from the loaded history; nil in a decoy, before the history is read, or with no home.
    func currentCorner(home: GeoPoint?, now: Date = Date()) -> HexCell? {
        guard !isDecoy, store.isLoaded else { return nil }
        // Only walking reaches the corner (owner 2026-11-09): a cell only driven past is still one to walk into.
        return cornerNudge.current(home: home, revealed: store.cells.subtracting(driven.cells), now: now, isWater: atlas.isWater)
    }

    /// Deletes the map widget's picture and reloads the widget; whether the picture is gone.
    private func removeWidgetMap() -> Bool {
        widgetMapGeneration &+= 1
        let removed = widgetMap.delete()
        widgetMapReload()
        return removed
    }

    /// ``load()`` once the history is read: saves the unsaved cells, merges the locked-phone buffer, and
    /// shows what it added.
    private func mergeWhileLoaded() {
        lockedFresh = []
        flush()
        do {
            try store.drainPending()
            if !driven.isLoaded { try driven.load() }
            try mergeDriven()
            if !worn.isLoaded { try worn.load() }
            try mergeWorn()
            visibleCells = store.cells
            drivenCells = driven.cells
            publishWorn()
            refreshTransitQuestion()
        } catch {
            FernletAuditLog.log("worldMap.fog.loadDeferred")
        }
    }

    /// Counts the cells of a drive while the phone is locked that the history (read before it locked) doesn't hold and
    /// that weren't counted since: the drive widget's new tiles. Bounded by WorldDriveWidget/maxLockedCells.
    private func countLockedFresh(_ cells: [HexCell]) {
        guard lockedFresh.count < WorldDriveWidget.maxLockedCells else { return }
        let fresh = cells.filter { !store.cells.contains($0) && !lockedFresh.contains($0) }
        lockedFresh.formUnion(fresh)
        lastFresh = fresh.count
    }

    /// Puts cells lifted while the phone is locked into the buffer for the next unlock: a drive's into the driven
    /// store's own buffer (they join the fog at the merge), anything else into the fog's.
    private func bufferWhileLocked(_ cells: [HexCell], driving: Bool) {
        do {
            if driving { try driven.appendPending(cells) } else { try store.appendPending(cells) }
        } catch {
            FernletAuditLog.log("worldMap.fog.bufferUnavailable")
        }
    }

}
