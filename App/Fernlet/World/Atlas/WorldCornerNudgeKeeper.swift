import FernletFoundation
import Foundation
import WorldMapStore

/// Keeps the weekly "one new corner" (round 7, spec §5, owner's option 1: on Home, from Sprout): once a week
/// the nearest still-fogged patch within about 1 km of home, a walk away (`FogCornerNudge`), kept sealed in
/// the map's vault (`FogCornerStore`, `corner.bin`) so the week's pick survives a relaunch. No streak, no
/// penalty: a corner is done when the person walks into it, or lapses at the end of the week, and nothing
/// counts either way. The Today card and the notification (options 2 and 3) are not built.
///
/// **Who calls it.** `WorldFogKeeper` owns this keeper: Home asks ``current(home:revealed:now:)`` with the
/// person's first home (`HomeBook.homes.first`, never the hotel) and the fog keeper's loaded history (the
/// stored cells, never an empty set before the history is read, or a decoy's cells), on appearing and each
/// foreground, so a new week picks again. The fog keeper calls ``noteRevealed(_:)`` with every lift, so the
/// corner goes the moment it is walked into. ``corner`` is what Home draws (the dashed gold hex) and what
/// VoiceOver reads (`FogCornerNudge.bearingAndDistance(from:to:)`).
///
/// **Duress.** A decoy (``setDecoy(_:)``) shows no corner and keeps nothing: no file is read or written.
/// Every wipe reaches ``clearAll()`` through `WorldFogKeeper.clearAll()`, and the file lives in the vault's
/// folder, which `WorldMapVault.clearAll()` removes with its keys. A locked phone (the store key can't be
/// read) shows no corner and picks nothing, so a pick is never written over one it could not read.
@MainActor
@Observable
final class WorldCornerNudgeKeeper {
    /// The corner Home shows now: this week's, not yet walked into; nil when there is none.
    private(set) var corner: HexCell?
    /// Whether a decoy session is showing.
    private(set) var isDecoy = false
    /// The calendar whose time zone a week runs in (Monday to Monday whatever its first weekday).
    @ObservationIgnored var calendar: Calendar

    /// A week and home cell for which nothing could be picked: the fog only ever lifts within a session,
    /// so the answer stays nil until the week, the home or the history (``clearAll()``) changes.
    private struct NoPick: Equatable {
        /// The week (`FogCornerNudge.weekIndex(of:)`).
        let week: Int64
        /// The cell under the home point.
        let home: HexCell
    }

    @ObservationIgnored private let store: FogCornerStore
    @ObservationIgnored private var state: FogCornerState?
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var noPick: NoPick?

    /// A keeper over `vault`, its weeks in `calendar` (the device's, by default; tests pass a fixed one).
    init(vault: WorldMapVault, calendar: Calendar = .autoupdatingCurrent) {
        self.store = FogCornerStore(vault: vault)
        self.calendar = calendar
    }

    /// This week's corner near `home`, loading the kept one or picking and saving a new one, and nil when
    /// there is none: no home, a decoy, a locked phone, the week's corner already walked into, or no fogged
    /// patch within 1 km. `revealed` must be the loaded fog history. A corner kept for a past week, or for a
    /// home since moved more than 1 km away, gives way to a new pick (moving on from last week's when it can).
    @discardableResult
    func current(home: GeoPoint?, revealed: Set<HexCell>, now: Date = Date(),
                 isWater: (HexCell) -> Bool = { _ in false }) -> HexCell? {
        guard !isDecoy, let home, home.isValid, loadState() else {
            corner = nil
            return nil
        }
        let weekStart = FogCornerNudge.weekStart(for: now, calendar: calendar)
        let week = FogCornerNudge.weekIndex(of: weekStart)
        if let kept = state, FogCornerNudge.weekIndex(of: kept.weekStart) == week,
           FogCornerNudge.isCorner(kept.cell, of: home) {
            if !kept.reached, revealed.contains(kept.cell) { markReached() }
            corner = state?.reached == false ? state?.cell : nil
            return corner
        }
        let miss = NoPick(week: week, home: MercatorHexGrid.cell(containing: home))
        guard miss != noPick,
              let cell = FogCornerNudge.pick(home: home, revealed: revealed, weekStart: weekStart,
                                             avoiding: state?.cell, isWater: isWater) else {
            noPick = miss
            corner = nil
            return nil
        }
        keep(FogCornerState(weekStart: weekStart, cell: cell))
        corner = cell
        return cell
    }

    /// Marks the kept corner reached when `cells` (one lift, its gap closings included) holds it, so Home
    /// stops showing it at once. Bounded by the lift's cells. Nothing in a decoy or while the phone is locked
    /// (``current(home:revealed:now:)`` then notices the lifted corner in the history instead).
    func noteRevealed(_ cells: [HexCell]) {
        guard !isDecoy, !cells.isEmpty, loadState(), let kept = state, !kept.reached,
              cells.contains(kept.cell) else { return }
        markReached()
        if corner == kept.cell { corner = nil }
    }

    /// Enters or leaves a decoy session. Either way no corner shows until the next
    /// ``current(home:revealed:now:)``, which in a decoy stays nil.
    func setDecoy(_ on: Bool) {
        guard on != isDecoy else { return }
        isDecoy = on
        corner = nil
    }

    /// The wipe: forgets the corner and removes its file. Whether the file is gone.
    func clearAll() -> Bool {
        corner = nil
        state = nil
        noPick = nil
        isLoaded = true
        return store.removeAll()
    }

    /// Reads the kept corner if it hasn't been read this session; whether it is readable now.
    private func loadState() -> Bool {
        guard !isLoaded else { return true }
        do {
            state = try store.load()
        } catch {
            FernletAuditLog.log("worldMap.corner.loadDeferred")
            return false
        }
        isLoaded = true
        return true
    }

    /// Marks the kept corner reached and saves it. A failed save is logged; the corner stays reached in
    /// memory, and the next launch finds it lifted in the history again.
    private func markReached() {
        guard var kept = state, !kept.reached else { return }
        kept.reached = true
        keep(kept)
    }

    /// Holds `next` as the kept corner and saves it; a failed save is logged and the pick still shows (the
    /// same week, home and history pick the same cell again after a relaunch).
    private func keep(_ next: FogCornerState) {
        state = next
        do {
            try store.save(next)
        } catch {
            FernletAuditLog.log("worldMap.corner.saveDeferred")
        }
    }
}
