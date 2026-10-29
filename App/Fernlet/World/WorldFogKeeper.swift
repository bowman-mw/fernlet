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
/// **A locked phone.** The store's key works only while the phone is unlocked, so readings that
/// arrive while it is locked (a walk with the screen off, Always mode's visits) go into the
/// locked-phone buffer and are merged on the next ``load()``.
@MainActor
@Observable
final class WorldFogKeeper {
    /// How far around a precise reading the fog lifts, in metres.
    static let liftRadius = 50.0
    /// The worst accuracy a reading may have and still lift the fog, in metres.
    static let maxAccuracy = 65.0
    /// New cells between saves while the app is open (saves also happen on ``flush()``).
    static let saveEvery = 40

    /// The cells the map draws: the whole lifted history, or in a decoy session only the decoy's own.
    private(set) var visibleCells: Set<HexCell> = []
    /// Whether a decoy session is showing.
    private(set) var isDecoy = false

    /// The World passport (round 7): the first visits the accepted readings make, sealed in the vault.
    @ObservationIgnored let atlas: WorldAtlasKeeper
    /// The weekly new corner (round 7, spec §5), sealed in the vault; Home asks ``currentCorner(home:now:)``.
    @ObservationIgnored let cornerNudge: WorldCornerNudgeKeeper
    @ObservationIgnored private let store: FogCellStore
    @ObservationIgnored private let vault: WorldMapVault
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isProtectedDataAvailable: @MainActor () -> Bool
    @ObservationIgnored private var decoyCells: Set<HexCell> = []
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
        self.atlas = WorldAtlasKeeper(vault: vault, openAtlas: WorldAtlasKeeper.bundledPack { try WorldAtlas(data: $0) },
                                      openLandmarks: WorldAtlasKeeper.bundledLandmarks())
        self.cornerNudge = WorldCornerNudgeKeeper(vault: vault)
        self.defaults = defaults
        self.isProtectedDataAvailable = isProtectedDataAvailable ?? { UIApplication.shared.isProtectedDataAvailable }
        self.widgetMap = WorldWidgetMapFile()
        self.widgetMapReload = { WorldWidgetMap.reload() }
    }

    /// Reads the lifted history (and merges the locked-phone buffer) when the phone is unlocked and no
    /// decoy is showing. Safe to call on every foreground.
    func load() {
        guard !isDecoy, isProtectedDataAvailable() else { return }
        do {
            try store.load()
        } catch {
            FernletAuditLog.log("worldMap.fog.loadDeferred")
            return
        }
        visibleCells = store.cells
        atlas.load()
    }

    /// Lifts the fog around `fix` when the rules allow; returns how many cells were new. With `saveNow`
    /// (a reading delivered while the app isn't active: background mapping, a walk with Maps in front) new
    /// cells are written at once rather than at the next 40, since iOS may end a suspended app first (W-09 B2).
    @discardableResult
    func handle(_ fix: WorldFix, saveNow: Bool = false) -> Int {
        let added = lift(fix)
        if saveNow, added > 0 { flush() }
        return added
    }

    /// Lifts the fog around `fix` when the rules allow; returns how many cells were new.
    private func lift(_ fix: WorldFix) -> Int {
        guard WorldMapPreferences.uncoverAsYouGo(in: defaults), fix.isPrecise,
              fix.accuracy <= Self.maxAccuracy, fix.point.isValid else { return 0 }
        let cells = MercatorHexGrid.cells(around: fix.point, within: Self.liftRadius)
        if isDecoy {
            let before = decoyCells.count
            decoyCells.formUnion(cells)
            decoyCells.formUnion(FogGapCloser.closing(around: cells, in: decoyCells))
            visibleCells = decoyCells
            return decoyCells.count - before
        }
        guard isProtectedDataAvailable(), store.isLoaded else {
            bufferWhileLocked(cells)
            return 0
        }
        let lifted = store.lift(cells)
        let gaps = FogGapCloser.closing(around: cells, in: store.cells)
        let added = lifted + store.lift(gaps)
        atlas.observe(point: fix.point, at: fix.at)
        cornerNudge.noteRevealed(cells + gaps)
        visibleCells = store.cells
        sinceSave += added
        if sinceSave >= Self.saveEvery { flush() }
        return added
    }

    /// Writes unsaved cells (the app leaving the foreground, or a walk ending).
    func flush() {
        guard !isDecoy else { return }
        do {
            try store.save()
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
        decoyCells = []
        visibleCells = on ? [] : store.cells
    }

    /// The wipe: forgets the cells and deletes every World map file and key, and the map widget's picture.
    /// Whether it all went.
    func clearAll() -> Bool {
        store.forget()
        decoyCells = []
        visibleCells = []
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
        return cornerNudge.current(home: home, revealed: store.cells, now: now, isWater: atlas.isWater)
    }

    /// Deletes the map widget's picture and reloads the widget; whether the picture is gone.
    private func removeWidgetMap() -> Bool {
        widgetMapGeneration &+= 1
        let removed = widgetMap.delete()
        widgetMapReload()
        return removed
    }

    /// Puts cells lifted while the phone is locked into the buffer for the next unlock.
    private func bufferWhileLocked(_ cells: [HexCell]) {
        do {
            try store.appendPending(cells)
        } catch {
            FernletAuditLog.log("worldMap.fog.bufferUnavailable")
        }
    }
}
