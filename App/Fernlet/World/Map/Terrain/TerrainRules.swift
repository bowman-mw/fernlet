import Foundation
import WorldMapStore

/// What stands over several hexes (spec "Multi-hex pieces follow the approved trees"): the approved round
/// tree and pine, and the terrain's palm, cactus and mountain peak. The seasons turn a temperate round tree
/// bare in winter or into blossom in spring, and snow the pines.
nonisolated enum TerrainStandKind: Hashable {
    case round, pine, palm, cactus, peak
}

/// A piece a hex may stand, before the wildness check: its kind, size, the key that decides between
/// neighbouring candidates (the larger wins, as the meadow's trees) and its shape variant.
nonisolated struct TerrainStand: Hashable {
    let kind: TerrainStandKind
    let big: Bool
    let key: UInt32
    let variant: Int
}

/// The terrain's rules for what grows where, from a hex's odd-r offset (col, row) and its ``TerrainHex``: the
/// mockup's `kindFor`, `standCand` and `standAt`, with the approved meadow and forest kept exactly as
/// ``NatureFogRules`` grows them.
nonisolated enum TerrainRules {
    /// Each set's ground cover, weights out of 100 by `hash(col+1000, row+1000) % 100` (the mockup's `kinds`).
    static func kinds(_ set: TerrainSet) -> [(NatureHexKind, Int)] {
        switch set {
        case .tropical: [(.short, 30), (.long, 45), (.flowers, 25)]
        case .boreal: [(.short, 55), (.long, 35), (.boulder, 10)]
        case .desert: [(.short, 52), (.ripples, 26), (.long, 14), (.boulder, 8)]
        case .mountain: [(.short, 44), (.scree, 34), (.long, 14), (.boulder, 8)]
        case .crops: [(.crops, 72), (.short, 24), (.long, 4)]
        case .urban: [(.roof, 58), (.short, 28), (.long, 14)]
        case .tundra: [(.short, 42), (.lichen, 28), (.long, 18), (.boulder, 12)]
        case .ice: [(.short, 58), (.crack, 26), (.snow, 16)]
        case .water: [(.waves, 62), (.short, 38)]
        case .meadow, .forest: []
        }
    }

    /// How often a set's hex starts a stand (per mille of `hash(col+3000, row+3000)`), and which kinds by weight.
    static func stands(_ set: TerrainSet) -> (chance: Double, kinds: [(TerrainStandKind, Int)]) {
        switch set {
        case .tropical: (0.34, [(.palm, 55), (.round, 45)])
        case .boreal: (0.42, [(.pine, 88), (.round, 12)])
        case .desert: (0.09, [(.cactus, 100)])
        case .mountain: (0.16, [(.peak, 70), (.pine, 30)])
        case .crops: (0.03, [(.round, 100)])
        case .urban: (0.05, [(.round, 100)])
        case .meadow, .forest, .tundra, .ice, .water: (0, [])
        }
    }

    /// The ground cover of a wild, non-edge hex. Meadow and forest keep the approved `kindAt`, with the
    /// season's flowers (spring adds them, autumn keeps a fifth, winter none) and, where the flora picks, no
    /// wildflowers outside their climate.
    static func ground(_ land: TerrainHex, col: Int, row: Int) -> NatureHexKind {
        let hash = NatureFogNoise.hash(col + 1_000, row + 1_000)
        guard land.set.isApproved else {
            let roll = Int(hash % 100)
            var total = 0
            for (kind, weight) in kinds(land.set) {
                total += weight
                if roll < total { return kind }
            }
            return .short
        }
        var kind = NatureFogRules.ground(col, row)
        if let share = flowerShare(land.season), kind == .flowers || kind == .long {
            let roll = Double((hash >> 9) % 100)
            if kind == .flowers && roll >= share * 100 { kind = .long }
            if kind == .long && share > 1 && roll < 30 { kind = .flowers }
        }
        if land.floraPicks && kind == .flowers && !land.flora.contains(.flowers) { kind = .long }
        return kind
    }

    /// The season's flower share (the mockup's `SEASON[…].flowers`): nil in summer, as approved.
    static func flowerShare(_ season: AtlasSeason) -> Double? {
        switch season {
        case .spring: 2
        case .summer: nil
        case .autumn: 0.2
        case .winter: 0
        }
    }

    /// The mockup's `standCand`: meadow and forest stand the approved `treeCand`; the other sets by their chance.
    static func candidate(_ set: TerrainSet, col: Int, row: Int) -> TerrainStand? {
        if set.isApproved {
            guard let tree = NatureFogRules.treeCandidate(col, row) else { return nil }
            return TerrainStand(kind: tree.pine ? .pine : .round, big: tree.big, key: tree.key, variant: tree.variant)
        }
        let plan = stands(set), key = NatureFogNoise.hash(col + 3_000, row + 3_000)
        guard let first = plan.kinds.first, Double(key % 1_000) / 1_000 < plan.chance else { return nil }
        let roll = Int((key >> 10) % 100)
        var kind = first.0, total = 0
        for (candidate, weight) in plan.kinds {
            total += weight
            if roll < total {
                kind = candidate
                break
            }
        }
        return TerrainStand(kind: kind, big: (key >> 17) % 100 < 45, key: key, variant: Int((key >> 20) % 4))
    }

    /// The mockup's `standAt`: a candidate no neighbouring candidate of the same wild outranks, then shaped by
    /// the flora. `neighbours` are the six neighbours' hexes in the order of the hex's sides (SE, SW, W, NW, NE,
    /// E; a missing one counts as the approved meadow). With every hex the approved meadow this is exactly
    /// ``NatureFogRules/tree(_:_:)``.
    static func stand(_ land: TerrainHex, col: Int, row: Int, neighbours: [TerrainHex]) -> TerrainStand? {
        guard let mine = candidate(land.set, col: col, row: row) else { return nil }
        let deltas = row & 1 == 1 ? NatureFogRules.oddRowSides : NatureFogRules.evenRowSides
        for (index, delta) in deltas.enumerated() {
            let other = neighbours.indices.contains(index) ? neighbours[index] : .approved
            guard other.set.standFamily == land.set.standFamily,
                  let rival = candidate(other.set, col: col + delta.0, row: row + delta.1) else { continue }
            if rival.key > mine.key { return nil }
        }
        return land.followsApproved ? mine : adapted(mine, to: land)
    }

    /// A stand reshaped by the climate's flora (spec "Flora"): palms only where palms grow, pines only in the cold
    /// north and on high ground, cacti in the Americas' dry bands (a third as many as trees would be), else
    /// nothing. Peaks always stand.
    static func adapted(_ stand: TerrainStand, to land: TerrainHex) -> TerrainStand? {
        let flora = land.flora
        func reshaped(_ kind: TerrainStandKind) -> TerrainStand {
            TerrainStand(kind: kind, big: stand.big, key: stand.key, variant: stand.variant)
        }
        let cactus: TerrainStand? = flora.contains(.cacti) && (stand.key >> 5) % 3 == 0 ? reshaped(.cactus) : nil
        switch stand.kind {
        case .peak: return stand
        case .cactus: return flora.contains(.cacti) ? stand : nil
        case .palm: return flora.contains(.palms) ? stand : nil
        case .pine:
            if flora.contains(.conifers) { return stand }
            if land.set == .meadow && flora.contains(.palms) { return reshaped(.palm) }
            return flora.contains(.broad) ? reshaped(.round) : cactus
        case .round:
            if flora.contains(.broad) { return stand }
            return flora.contains(.palms) ? reshaped(.palm) : cactus
        }
    }
}
