import Foundation

/// The plants a map cell's art may draw (a frozen token: the passport and the art key on it, so it stays
/// English and never changes).
public nonisolated enum AtlasFlora: String, CaseIterable, Codable, Sendable {
    case palms, jungle, broadleaf, conifers, birches, cacti, succulents, dryScrub, grasses, wildflowers, heather,
         mossLichen, olives, ice
}

/// Terrain and flora for a point or a fog cell, from the atlas's coastline mask and climate bands (the owner's
/// coarse model): water from `LAND` (a coast cell from its sub-mask), else a class from the Köppen-Geiger code
/// and the latitude, and a few plants from the class, the latitude and the region.
///
/// **The mapping** (Beck et al. 2018 codes; Fernlet's documented choices, 2026-10-29):
/// - Af, Am → tropical forest; Aw → savanna.
/// - BWh, BWk → desert; BSh (hot steppe) → savanna; BSk (cold steppe) → grassland.
/// - Csa → shrubland (the Mediterranean scrub); Csb, Csc → temperateForest (the cool dry-summer coasts:
///   the Pacific Northwest, northern Spain and Chile are conifer and oak country, not scrub).
/// - Cfa, Cfb, Cwa, Cwb → temperate forest; Cfc (subpolar oceanic: the Faroes, Tierra del Fuego) → grassland, it
///   is treeless; Cwc (only on high tropical plateaus) → mountain.
/// - Dfc, Dfd, Dwc, Dwd, Dsc, Dsd → boreal forest, except equatorward of ``borealLowLatitude`` (40°), where a
///   subarctic climate can only be altitude (the Rockies' high country, the Atlas, the Tibetan rim) → mountain;
///   every other D climate → temperate forest.
/// - ET → tundra poleward of ``tundraLatitude`` (60°), mountain otherwise (the Alps' and Andes' alpine zone).
/// - EF → ice.
/// - Land the source gives no climate (code 0, a sliver it misses) → ice south of the Antarctic line, tundra
///   poleward of 60°, grassland elsewhere.
///
/// Nothing is cached: every answer is a raster index or two on the immutable atlas.
public nonisolated struct AtlasTerrainClassifier: Sendable {
    /// Poleward of this, ET is tundra; equatorward, mountain.
    public static let tundraLatitude = 60.0
    /// Equatorward of this, a boreal (subarctic) D climate reads as mountain.
    public static let borealLowLatitude = 40.0
    /// Equatorward of this, a C climate's forest carries palms (Florida, southern China, coastal Brazil).
    public static let palmLatitude = 32.0
    /// The most plants one place is given.
    public static let maxFlora = 3

    /// The atlas the lookups read.
    public let atlas: WorldAtlas

    /// A classifier reading `atlas`.
    public init(atlas: WorldAtlas) {
        self.atlas = atlas
    }

    /// The terrain under `point` (water for an invalid point).
    public func terrain(at point: GeoPoint) -> AtlasTerrain {
        guard point.isValid, atlas.isLand(at: point) else { return .water }
        return Self.terrain(climateCode: atlas.climateCode(at: point), latitude: point.latitude)
    }

    /// The terrain at the centre of fog cell `cell`.
    public func terrain(of cell: HexCell) -> AtlasTerrain {
        terrain(at: MercatorHexGrid.centreGeo(of: cell))
    }

    /// The plants at `point`, at most ``maxFlora``, most characteristic first (none on water).
    public func flora(at point: GeoPoint) -> [AtlasFlora] {
        guard point.isValid else { return [] }
        return Self.flora(for: terrain(at: point), climateCode: atlas.climateCode(at: point), at: point)
    }

    /// The plants at the centre of fog cell `cell`.
    public func flora(of cell: HexCell) -> [AtlasFlora] {
        flora(at: MercatorHexGrid.centreGeo(of: cell))
    }

    /// The land terrain class for Köppen-Geiger `climateCode` at `latitude` (the mapping above).
    public static func terrain(climateCode: UInt8, latitude: Double) -> AtlasTerrain {
        let poleward = latitude.isFinite ? abs(latitude) : 0
        switch climateCode {
        case 1, 2: return .tropicalForest
        case 3, 6: return .savanna
        case 4, 5: return .desert
        case 7, 16: return .grassland
        case 8: return .shrubland
        case 9, 10: return .temperateForest
        case 11, 12, 14, 15: return .temperateForest
        case 13: return .mountain
        case 19, 20, 23, 24, 27, 28: return poleward < borealLowLatitude ? .mountain : .borealForest
        case 17, 18, 21, 22, 25, 26: return .temperateForest
        case 29: return poleward >= tundraLatitude ? .tundra : .mountain
        case 30: return .ice
        default:
            guard latitude >= WorldAtlas.antarcticaLatitude else { return .ice }
            return poleward >= tundraLatitude ? .tundra : .grassland
        }
    }

    /// The plants for `terrain` (with its Köppen-Geiger `climateCode`) at `point`: cacti only in the Americas,
    /// succulents in the world's other dry lands, olives only round the Mediterranean, heather on the North
    /// Atlantic's moors and tundra. At most ``maxFlora``, most characteristic first.
    public static func flora(for terrain: AtlasTerrain, climateCode: UInt8, at point: GeoPoint) -> [AtlasFlora] {
        let dryPlant: AtlasFlora = isAmericas(point) ? .cacti : .succulents
        let poleward = point.latitude.isFinite ? abs(point.latitude) : 0
        let plants: [AtlasFlora]
        switch terrain {
        case .water: plants = []
        case .ice: plants = [.ice]
        case .tundra: plants = isNorthAtlantic(point) ? [.mossLichen, .heather, .grasses] : [.mossLichen, .grasses, .wildflowers]
        case .mountain:
            plants = poleward < AtlasSeason.tropicsLatitude ? [.grasses, .wildflowers, .broadleaf] : [.conifers, .mossLichen, .wildflowers]
        case .borealForest: plants = [.conifers, .birches, .mossLichen]
        case .temperateForest: plants = poleward < palmLatitude ? [.broadleaf, .palms, .wildflowers] : [.broadleaf, .conifers, .wildflowers]
        case .tropicalForest: plants = [.jungle, .palms, .broadleaf]
        case .savanna: plants = climateCode == 6 ? [.grasses, .dryScrub, dryPlant] : [.grasses, .broadleaf, .palms]
        case .grassland: plants = grassland(climateCode: climateCode, point: point)
        case .desert: plants = [dryPlant, .dryScrub]
        case .shrubland: plants = isMediterranean(point) ? [.olives, .dryScrub, .wildflowers] : [.dryScrub, .wildflowers, dryPlant]
        }
        return Array(plants.prefix(maxFlora))
    }

    /// A grassland's plants: cold steppe dry, subpolar oceanic heath-like, the rest meadow.
    private static func grassland(climateCode: UInt8, point: GeoPoint) -> [AtlasFlora] {
        guard climateCode != 7 else { return [.grasses, .dryScrub, .wildflowers] }
        guard climateCode != 16 else { return isNorthAtlantic(point) ? [.grasses, .heather, .mossLichen] : [.grasses, .mossLichen] }
        return [.grasses, .wildflowers]
    }

    /// The Americas, for cacti: longitude 170°W to 25°W (Greenland falls inside but is never dry).
    static func isAmericas(_ point: GeoPoint) -> Bool {
        guard point.isValid else { return false }
        return point.longitude >= -170 && point.longitude <= -25
    }

    /// The Mediterranean basin, for olives: 29°N to 47°N, 10°W to 42°E.
    static func isMediterranean(_ point: GeoPoint) -> Bool {
        guard point.isValid else { return false }
        return point.latitude >= 29 && point.latitude <= 47 && point.longitude >= -10 && point.longitude <= 42
    }

    /// The North Atlantic's heaths, for heather: 48°N to 72°N, 30°W to 40°E (Iceland, the British Isles,
    /// Scandinavia).
    static func isNorthAtlantic(_ point: GeoPoint) -> Bool {
        guard point.isValid else { return false }
        return point.latitude >= 48 && point.latitude <= 72 && point.longitude >= -30 && point.longitude <= 40
    }
}
