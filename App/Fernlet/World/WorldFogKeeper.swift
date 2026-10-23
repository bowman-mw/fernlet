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

    @ObservationIgnored private let store: FogCellStore
    @ObservationIgnored private let vault: WorldMapVault
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isProtectedDataAvailable: @MainActor () -> Bool
    @ObservationIgnored private var decoyCells: Set<HexCell> = []
    @ObservationIgnored private var sinceSave = 0

    /// A keeper over `vault`. `isProtectedDataAvailable` reports whether the phone is unlocked (the
    /// app's `UIApplication` answer by default; tests inject one).
    init(vault: WorldMapVault, defaults: UserDefaults = .standard,
         isProtectedDataAvailable: (@MainActor () -> Bool)? = nil) {
        self.vault = vault
        self.store = FogCellStore(vault: vault)
        self.defaults = defaults
        self.isProtectedDataAvailable = isProtectedDataAvailable ?? { UIApplication.shared.isProtectedDataAvailable }
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
    }

    /// Lifts the fog around `fix` when the rules allow; returns how many cells were new.
    @discardableResult
    func handle(_ fix: WorldFix) -> Int {
        guard WorldMapPreferences.uncoverAsYouGo(in: defaults), fix.isPrecise,
              fix.accuracy <= Self.maxAccuracy, fix.point.isValid else { return 0 }
        let cells = MercatorHexGrid.cells(around: fix.point, within: Self.liftRadius)
        if isDecoy {
            let before = decoyCells.count
            decoyCells.formUnion(cells)
            visibleCells = decoyCells
            return decoyCells.count - before
        }
        guard isProtectedDataAvailable(), store.isLoaded else {
            bufferWhileLocked(cells)
            return 0
        }
        let added = store.lift(cells)
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
        if on { flush() }
        isDecoy = on
        decoyCells = []
        visibleCells = on ? [] : store.cells
    }

    /// The wipe: forgets the cells and deletes every World map file and key. Whether it all went.
    func clearAll() -> Bool {
        store.forget()
        decoyCells = []
        visibleCells = []
        sinceSave = 0
        return vault.clearAll()
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
