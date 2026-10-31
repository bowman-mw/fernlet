import Foundation
import WorldMapStore

/// The fog's tile sets (World-Exploration-Spec §1 "Terrain sets", `ex-biomes`; the mockup's `BIO` in
/// `World-Exploration-terrain.js`): one per kind of land, each with its own three-shade ground and pieces.
///
/// Grassland (`meadow`) and temperate forest (`forest`) are exactly the approved nature fog. Which set a hex
/// takes comes from the atlas (``init(_:urban:)``, the lane's mapping): savanna and shrubland draw the meadow
/// ground with the classifier's own flora, and cropland has no source in the pack, so nothing selects `crops`
/// yet (its art exists for when one does).
nonisolated enum TerrainSet: String, CaseIterable, Hashable {
    case water, desert, mountain, forest, tropical, boreal, meadow, crops, urban, tundra, ice

    /// The set for the atlas's terrain class `terrain`; `urban` (a land hex inside an urban boundary) wins on land.
    init(_ terrain: AtlasTerrain, urban: Bool) {
        guard terrain == .water || !urban else {
            self = .urban
            return
        }
        self = switch terrain {
        case .water: .water
        case .ice: .ice
        case .tundra: .tundra
        case .mountain: .mountain
        case .borealForest: .boreal
        case .temperateForest: .forest
        case .tropicalForest: .tropical
        case .grassland, .savanna, .shrubland: .meadow
        case .desert: .desert
        }
    }

    /// Grassland and temperate forest: the approved nature fog's ground, kinds and trees.
    var isApproved: Bool { self == .meadow || self == .forest }
    /// The sets the seasons change (spec "Seasons": grassland, temperate forest and cropland only).
    var hasSeasons: Bool { isApproved || self == .crops }
    /// The sea: no seams, wave marks, a sand line where it meets land, nothing standing on it.
    var isWater: Bool { self == .water }
    /// The set whose candidates a stand is weighed against: meadow and forest are one wild, as approved.
    var standFamily: TerrainSet { isApproved ? .meadow : self }
}

/// The plants the climate band lets grow (spec "Flora", `ex-flora`), from the classifier's `flora(of:)`.
nonisolated struct TerrainFlora: OptionSet, Hashable {
    let rawValue: UInt8

    /// Palms (the tropics only, and the classifier's warm temperate coasts).
    static let palms = TerrainFlora(rawValue: 1)
    /// Pines (the cold north and high ground).
    static let conifers = TerrainFlora(rawValue: 2)
    /// Round trees: broadleaf, jungle, birch and olive.
    static let broad = TerrainFlora(rawValue: 4)
    /// Cacti (the Americas' dry bands).
    static let cacti = TerrainFlora(rawValue: 8)
    /// Wildflower mixes (temperate grass).
    static let flowers = TerrainFlora(rawValue: 16)
    /// Everything: the approved fog grows all of it.
    static let everything: TerrainFlora = [.palms, .conifers, .broad, .cacti, .flowers]

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The pieces `plants` allow.
    init(_ plants: [AtlasFlora]) {
        var flora: TerrainFlora = []
        for plant in plants {
            switch plant {
            case .palms: flora.insert(.palms)
            case .conifers: flora.insert(.conifers)
            case .broadleaf, .jungle, .birches, .olives: flora.insert(.broad)
            case .cacti: flora.insert(.cacti)
            case .wildflowers: flora.insert(.flowers)
            case .succulents, .dryScrub, .grasses, .heather, .mossLichen, .ice: break
            }
        }
        self = flora
    }
}

/// The palette one hex paints with: its set (forest shares the meadow's) and the season it shows.
nonisolated struct TerrainLook: Hashable {
    let set: TerrainSet
    let season: AtlasSeason

    /// The approved nature fog's look: the meadow in summer.
    static let approved = TerrainLook(set: .meadow, season: .summer)
}

/// What one fog hex is drawn as: its set, the season it shows, and the plants its climate allows.
nonisolated struct TerrainHex: Hashable {
    let set: TerrainSet
    /// The season drawn: summer for a set the seasons never change, and in the tropics.
    let season: AtlasSeason
    let flora: TerrainFlora
    /// Whether the flora picks the pieces: every set but grassland and temperate forest, and the savanna and
    /// shrubland that draw the meadow's ground.
    let floraPicks: Bool

    /// Today's nature fog: what every hex is with no atlas.
    static let approved = TerrainHex(set: .meadow, season: .summer, flora: .everything, floraPicks: false)

    /// The palette key.
    var look: TerrainLook { TerrainLook(set: set.isApproved ? .meadow : set, season: season) }

    /// Whether this hex grows exactly the approved fog's pieces (its season aside).
    var followsApproved: Bool { self.set.isApproved && !floraPicks }

    /// The hex for the atlas's answers: `terrain` and `plants` under it, whether it is `urban`, its `latitude`
    /// and the `season` there today (the drawn season is summer where the set or the latitude has none, unless
    /// `forced`, the DEBUG screenshot override).
    static func classify(terrain: AtlasTerrain, urban: Bool, plants: [AtlasFlora], latitude: Double,
                         season: AtlasSeason, forced: Bool = false) -> TerrainHex {
        let set = TerrainSet(terrain, urban: urban)
        let seasonal = set.hasSeasons && (forced || AtlasSeason.hasFourSeasons(latitude: latitude))
        let picks = !set.isApproved || terrain == .savanna || terrain == .shrubland
        return TerrainHex(set: set, season: seasonal ? season : .summer, flora: TerrainFlora(plants), floraPicks: picks)
    }
}
