//
//  SillyFurthestFromHome.swift
//  Fernlet
//
//  The number behind "Furthest from home" (Refinements group 12, owner-approved 2026-10-26): the
//  straight line from the nearest home to the furthest bit of map the person has uncovered.
//

import Foundation
import WorldMapStore

/// Works out Furthest from home from the map's lifted cells and the person's homes.
///
/// **Nothing new is kept.** The map's history is already sealed on this iPhone (``WorldFogKeeper``, never
/// synced, backed up, exported, shared or sent) and so are the homes (the places file's device side); this
/// reads both where they already are, in memory, and hands the tally one number that is never written
/// down (``SillyStatsTally`` is rebuilt on every read). Deleting the map history or the homes takes the stat
/// with them. A decoy has no homes and only its own cells, so it never shows the stat. The hotel is never a
/// home here: a stay is a trip, and the trip is what this measures.
nonisolated enum SillyFurthestFromHome {
    /// The furthest any of `cells` lies from the nearest of `homes`, in metres; nil with no home or no cell.
    static func meters(cells: Set<HexCell>, homes: [GeoPoint]) -> Double? {
        guard !homes.isEmpty, !cells.isEmpty else { return nil }
        var furthest = 0.0
        for cell in cells {
            let point = MercatorHexGrid.centreGeo(of: cell)
            let nearest = homes.map { point.distance(to: $0) }.min() ?? 0
            if nearest > furthest { furthest = nearest }
        }
        return furthest
    }

    /// What the last answer was worked out from: the cells only grow, so their count and the homes' points
    /// say whether it still holds.
    struct Basis: Equatable, Sendable {
        let cellCount: Int
        let homes: [GeoPoint]
    }
}

extension SillyStatsService {
    /// Furthest from home for `store` now: the answer worked out last, while the map and the homes are as
    /// they were, else worked out again away from the main thread. Nil in a decoy, without a home, or before
    /// the map history has been read.
    func furthestFromHome(store: FernletStore) async -> Double? {
        let homes = store.worldHomes.homes.map(\.point)
        let cells = store.worldFog.visibleCells
        guard !store.duressSessionActive, !homes.isEmpty, !cells.isEmpty else { return nil }
        let basis = SillyFurthestFromHome.Basis(cellCount: cells.count, homes: homes)
        if let known = furthestKnown, known.basis == basis { return known.meters }
        let meters = await Task.detached(priority: .utility) { SillyFurthestFromHome.meters(cells: cells, homes: homes) }.value
        // A decoy that opened while it ran never sees the number.
        guard !store.duressSessionActive, let meters else { return nil }
        furthestKnown = (basis, meters)
        return meters
    }
}
