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

    /// The cells the map draws: the whole lifted history, or in a decoy session only the decoy's own.
    private(set) var visibleCells: Set<HexCell> = []
    /// Those of them only driven past, never walked, which the map draws as see-through fog (owner 2026-11-09); the
    /// history's, or in a decoy session the decoy's own.
    private(set) var drivenCells: Set<HexCell> = []
    /// Whether a decoy session is showing.
    private(set) var isDecoy = false
    /// The drive's last lifted reading, which the next joins; nil off a drive.
    @ObservationIgnored private var laneFrom: GeoPoint?

    /// The World passport (round 7): the first visits the accepted readings make, sealed in the vault.
    @ObservationIgnored let atlas: WorldAtlasKeeper
    /// The weekly new corner (round 7, spec §5), sealed in the vault; Home asks ``currentCorner(home:now:)``.
    @ObservationIgnored let cornerNudge: WorldCornerNudgeKeeper
    /// The road trip on now and the line this iPhone records while it maps (owner-approved 2026-11-10), sealed in the
    /// vault under the buffer key.
    @ObservationIgnored let roadTrip: RoadTripKeeper
    @ObservationIgnored private let store: FogCellStore
    /// The cells only driven past (owner 2026-11-09), beside the fog store, which still holds every lifted cell.
    @ObservationIgnored private let driven: DrivenFogStore
    @ObservationIgnored private let vault: WorldMapVault
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isProtectedDataAvailable: @MainActor () -> Bool
    @ObservationIgnored private var decoyCells: Set<HexCell> = []
    @ObservationIgnored private var decoyDriven: Set<HexCell> = []
    @ObservationIgnored private var sinceSave = 0
    /// The map widget's picture in the app group (tests point it at their own folder).
    @ObservationIgnored var widgetMap: WorldWidgetMapFile
    /// Reloads the map widget once its picture is gone (tests count the calls).
    @ObservationIgnored var widgetMapReload: @MainActor () -> Void
    /// Moves each time the widget's picture is deleted (a wipe, Delete map history, a decoy).
    @ObservationIgnored private(set) var widgetMapGeneration = 0

    /// A keeper over `vault`. `isProtectedDataAvailable` reports whether the phone is unlocked (the
    /// app's `UIApplication` answer by default; tests inject one).
    init(vault: WorldMapVault, defaults: UserDefaults = .standard,
         isProtectedDataAvailable: (@MainActor () -> Bool)? = nil) {
        self.vault = vault
        self.store = FogCellStore(vault: vault)
        self.driven = DrivenFogStore(vault: vault)
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
    }

    /// Reads the lifted history (and merges the locked-phone buffer) when the phone is unlocked and no
    /// decoy is showing. Safe to call on every foreground.
    ///
    /// The history is read once. Each later call keeps the cells in memory: it saves any not yet written
    /// and merges the buffer. Cells lifted under a panel are therefore never thrown back to the disk copy
    /// (location keeps running under panels, W-09), and Home coming to the front decrypts nothing.
    func load() {
        // The road trip's book is under the buffer key, so it reads with the phone locked too (never in a decoy).
        roadTrip.load()
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
        } catch {
            FernletAuditLog.log("worldMap.fog.loadDeferred")
            return
        }
        visibleCells = store.cells
        drivenCells = driven.cells
        atlas.load()
    }

    /// Folds what the phone buffered while locked into the driven cells (owner 2026-11-09): what was walked meanwhile
    /// (the fog buffer the store just drained) is walked, and a drive's buffered cells join the fog, driven unless
    /// they were walked before or meanwhile.
    private func mergeDriven() throws {
        guard driven.isLoaded else { return }
        driven.remove(store.lastDrained)
        let pending = try driven.takePending()
        if !pending.isEmpty {
            let walked = store.cells.subtracting(driven.cells)
            store.lift(Array(pending))
            driven.add(Array(pending.subtracting(walked)))
            try store.save()
        }
        try driven.save()
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
        if thinLine {
            added = lift(fix, cells: Self.lane(from: laneFrom, to: fix.point), driving: true)
            if accepted { laneFrom = fix.point }
        } else {
            laneFrom = nil
            added = lift(fix, cells: MercatorHexGrid.cells(around: fix.point, within: Self.liftRadius), driving: false)
        }
        if accepted { roadTrip.record(fix, saveNow: saveNow) }
        if saveNow, added > 0 { flush() }
        return added
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

    /// Whether the rules let `fix` lift the fog: "Uncover the map as you go" on, precise, accurate enough.
    private func accepts(_ fix: WorldFix) -> Bool {
        WorldMapPreferences.uncoverAsYouGo(in: defaults) && fix.isPrecise && fix.accuracy <= Self.maxAccuracy
            && fix.point.isValid
    }

    /// Lifts `cells` (around `fix`) when the rules allow `fix`; returns how many cells were new. `driving`: the cells
    /// it newly uncovers are only driven past (see-through fog, owner 2026-11-09), and the week's corner isn't walked
    /// into; otherwise every cell it reaches is walked, driven no more.
    private func lift(_ fix: WorldFix, cells: [HexCell], driving: Bool) -> Int {
        guard accepts(fix) else { return 0 }
        guard !isDecoy else { return liftDecoy(cells, driving: driving) }
        guard isProtectedDataAvailable(), store.isLoaded else {
            bufferWhileLocked(cells, driving: driving)
            return 0
        }
        let fresh = cells.filter { !store.cells.contains($0) }
        let lifted = store.lift(cells)
        let gaps = FogGapCloser.closing(around: cells, in: store.cells)
        let added = lifted + store.lift(gaps)
        if driving { driven.add(fresh + gaps) } else { driven.remove(cells + gaps) }
        // Inside the grounds just landed at, the passport waits for the person to leave (the flight gate).
        if !fix.atLandedAirport { atlas.observe(point: fix.point, at: fix.at) }
        if !driving { cornerNudge.noteRevealed(cells + gaps) }
        visibleCells = store.cells
        drivenCells = driven.cells
        sinceSave += added
        if sinceSave >= Self.saveEvery { flush() }
        return added
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
            sinceSave = 0
        } catch {
            FernletAuditLog.log("worldMap.fog.saveDeferred")
        }
    }

    /// Enters or leaves a decoy session. Entering hides the history; leaving drops the decoy's own
    /// cells and shows the history again.
    func setDecoy(_ on: Bool) {
        guard on != isDecoy else { return }
        if on {
            flush()
            // The decoy's map widget has no map: the real picture goes before anything of the decoy shows.
            if !removeWidgetMap() { FernletAuditLog.log("worldMap.widgetMap.decoyDeleteFailed") }
        }
        isDecoy = on
        atlas.setDecoy(on)
        cornerNudge.setDecoy(on)
        roadTrip.setDecoy(on)
        decoyCells = []
        decoyDriven = []
        visibleCells = on ? [] : store.cells
        drivenCells = on ? [] : driven.cells
    }

    /// The wipe: forgets the cells and the road trips and deletes every World map file and key, and the map widget's
    /// picture. Whether it all went.
    func clearAll() -> Bool {
        store.forget()
        driven.forget()
        roadTrip.forget()
        decoyCells = []
        decoyDriven = []
        visibleCells = []
        drivenCells = []
        sinceSave = 0
        let pictureGone = removeWidgetMap()
        let passportGone = atlas.clearAll()
        let cornerGone = cornerNudge.clearAll()
        let vaultGone = vault.clearAll()
        return vaultGone && pictureGone && passportGone && cornerGone
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
        flush()
        do {
            try store.drainPending()
            if !driven.isLoaded { try driven.load() }
            try mergeDriven()
            visibleCells = store.cells
            drivenCells = driven.cells
        } catch {
            FernletAuditLog.log("worldMap.fog.loadDeferred")
        }
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
