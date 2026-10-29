import Foundation

// The world view's lines on hex edges (World-Exploration-Spec, "The closest zoom": "the state line … drawn on
// the hex edges"). Each world-view hex is named by the place at its centre; an edge between two hexes carries
// a country line where their countries differ and a state line where, in one country, their plate groups
// differ, so Britain's council areas, which share the group England, draw no line between them.

/// What an edge between two world-view hexes carries (a frozen token).
public nonisolated enum AtlasHexBorder: String, CaseIterable, Codable, Sendable {
    /// No line: the same place, the sea, or a side the pack names no state for.
    case none
    /// A state or province line: one country, two plate groups.
    case region
    /// A country line: two countries.
    case country
}

extension AtlasZoomLevel {
    /// Whether this level draws `border`: country lines from Country in, state lines from State in.
    public func draws(_ border: AtlasHexBorder) -> Bool {
        switch border {
        case .none: false
        case .region: showsAdmin1Lines
        case .country: showsCountryLines
        }
    }
}

extension WorldViewHexGrid {
    /// The place at `hex`'s centre.
    public func centreGeo(of hex: HexCell) -> GeoPoint {
        let centre = centre(of: hex)
        return WebMercator.geo(x: centre.x, y: centre.y)
    }

    /// The six hexes that share an edge with `hex` (the same axial neighbours as the fog's grid).
    public func neighbours(of hex: HexCell) -> [HexCell] {
        MercatorHexGrid.neighbours(of: hex)
    }
}

extension WorldAtlas {
    /// The place naming world-view hex `hex` of `grid`: ``placeName(at:)`` at its centre, so one lookup a hex
    /// (about 0.1 ms on a Mac). A hex's place never changes, so the screen keeps it per hex ID.
    public func placeName(of hex: HexCell, in grid: WorldViewHexGrid) -> AtlasPlaceName? {
        placeName(at: grid.centreGeo(of: hex))
    }

    /// What the edge between two hexes named `a` and `b` carries: a country line where both have a country
    /// and they differ; a state line where they share a country and both have plate groups that differ;
    /// otherwise none (the sea, or a side with no state, draws no state line). Pure and constant time.
    public static func border(between a: AtlasPlaceName?, and b: AtlasPlaceName?) -> AtlasHexBorder {
        guard let a, let b else { return .none }
        guard a.countryCode == b.countryCode else { return .country }
        guard let left = a.regionToken, let right = b.regionToken, left != right else { return .none }
        return .region
    }
}
