import Foundation

/// The passport's land rules with the shore mask (Docs/World-Atlas-Pack.md, "The rules the reader applies"; owner's
/// pick, 2026-11-03): where the map draws real land, the passport treats it as land too. These rules only add to what
/// ``WorldAtlas/visit(at:)`` answers, and without a mask they answer exactly what it answers:
///
/// - **Terrain** follows the mask both ways, so it matches the map.
/// - **Continent:** on the mask's land where the atlas names none, the nearest `CONT` cell within
///   ``continentReachCells``. Never the country's own continent, which is wrong for Russia east of 60°E and for
///   France overseas.
/// - **Country:** the outlines answer first. On the mask's land with none, the nearest country within
///   ``shoreCountryReachMetres``, when no other sovereign state lies within ``shoreCountryRivalMetres`` and real water
///   within ``shoreWaterReachMetres``. A wrong stamp can never be taken back, so past any of those the fix keeps
///   today's answer: on a hard list of 76 gap islands this was 25 right, 0 wrong, 51 none, while 5 km already reads
///   Greek Kastellorizo as Turkey. The water test keeps the rule to coasts, so Bir Tawil and Kashmir's unassigned strip
///   stay no one's. The passport's excluded countries stay excluded.
/// - **Ocean, sea, city and landmark** do not change: a fix with no country in its outlines still counts every city.
///
/// Bounded: see each function. Mask reads decode at most two tiles each, into the mask's bounded cache.
extension WorldAtlas {
    /// How far a country's outline may lie from the mask's land and still name it: 3 km (owner's pick, 2026-11-03).
    public static let shoreCountryReachMetres = 3_000.0
    /// How near another sovereign state must be to refuse the country: 6 km (owner's pick, 2026-11-03).
    public static let shoreCountryRivalMetres = 6_000.0
    /// How near real water must be for a gap to be a coast's: 3 km (owner's pick, 2026-11-03).
    public static let shoreWaterReachMetres = 3_000.0
    /// How many atlas cells ``nearbyContinent(at:)`` searches either side: 5, about 55 km at the shipped 0.1°.
    public static let continentReachCells = 5
    /// The rings the water test walks outward, each this far beyond the last.
    private static let shoreWaterRingMetres = 500.0
    /// The bearings the water test reads on each ring.
    private static let shoreWaterBearings = 16

    /// Everything one accepted fix counts toward, read with `shore` (the rules above). With no `shore`, or an invalid
    /// point, exactly ``visit(at:)``.
    public func visit(at point: GeoPoint, shore: WorldShoreMask?) -> AtlasVisit {
        var visit = visit(at: point)
        guard let shore, point.isValid else { return visit }
        guard shore.isLand(at: point) else {
            visit.terrain = .water
            return visit
        }
        visit.terrain = AtlasTerrainClassifier(atlas: self).landTerrain(at: point)
        if visit.continent == nil { visit.continent = nearbyContinent(at: point) }
        // A fix inside an excluded country has no code either, and its outline has answered: no fallback there.
        if visit.countryCode == nil, country(at: point) == nil, let found = countryOnShore(at: point, shore: shore),
           !Self.isExcludedFromPassport(found) {
            visit.countryCode = found.code
            visit.sovereignCode = found.sovereignCode
        }
        return visit
    }

    /// The continent of the `CONT` cell under `point`, or else of the nearest non-zero one within
    /// ``continentReachCells`` cells, searched outward ring by ring; nil when there is none. Bounded: at most
    /// (2 × ``continentReachCells`` + 1)² raster reads.
    public func nearbyContinent(at point: GeoPoint) -> AtlasContinent? {
        guard point.isValid else { return nil }
        let spot = grid.spot(of: point)
        if let here = AtlasContinent(packCode: continents[grid.index(row: spot.row, col: spot.col)]) { return here }
        for reach in 1...Self.continentReachCells {
            for row in (spot.row - reach)...(spot.row + reach) where row >= 0 && row < grid.rows {
                let onEdge = abs(row - spot.row) == reach
                // A ring: the whole row at its top and bottom, its two ends between.
                for col in stride(from: spot.col - reach, through: spot.col + reach, by: onEdge ? 1 : 2 * reach) {
                    if let found = AtlasContinent(packCode: continents[grid.index(row: row, col: col)]) { return found }
                }
            }
        }
        return nil
    }

    /// The country the shore rule gives `point`, which `shore` calls land and no outline holds, or nil.
    func countryOnShore(at point: GeoPoint, shore: WorldShoreMask) -> AtlasCountry? {
        let near = countries(near: point, within: Self.shoreCountryRivalMetres)
        guard let nearest = near.first, nearest.metres <= Self.shoreCountryReachMetres else { return nil }
        guard near.allSatisfy({ $0.country.sovereignCode == nearest.country.sovereignCode }) else { return nil }
        guard hasWater(near: point, shore: shore) else { return nil }
        return nearest.country
    }

    /// Every country whose outline lies within `metres` of `point`, nearest first (by code on a tie), with its
    /// distance. Bounded: the countries listed in the one-degree cells of the reach's corners and centre, which are all
    /// the cells it touches while it spans under a degree (up to about 87° for the shipped reach), each country tested
    /// once (at most `WorldAtlasLayers.maxCountries`).
    func countries(near point: GeoPoint, within metres: Double) -> [(country: AtlasCountry, metres: Double)] {
        guard point.isValid, metres.isFinite, metres >= 0 else { return [] }
        let north = metres / GeoPoint.metresPerDegree, east = metres / max(point.metresPerDegreeLongitude, 1)
        var seen = Set<UInt16>(), found: [(country: AtlasCountry, metres: Double)] = []
        // Bounded: five corners of the reach.
        for (up, right) in [(0.0, 0.0), (1, 1), (1, -1), (-1, 1), (-1, -1)] {
            let corner = GeoPoint(min(max(point.latitude + up * north, -90), 90),
                                  AtlasGrid.normalised(point.longitude + right * east))
            for index in countryBoxes.candidates(at: corner)
            where seen.insert(index).inserted && countries.indices.contains(Int(index)) {
                let country = countries[Int(index)]
                guard let distance = country.polygon.distance(from: point, within: metres) else { continue }
                found.append((country, distance))
            }
        }
        return found.sorted { ($0.metres, $0.country.code) < ($1.metres, $1.country.code) }
    }

    /// Whether `shore` puts water within ``shoreWaterReachMetres`` of `point`. Bounded: at most 6 rings of
    /// 16 bearings, so 96 mask reads.
    func hasWater(near point: GeoPoint, shore: WorldShoreMask) -> Bool {
        guard point.isValid else { return false }
        let rings = Int(Self.shoreWaterReachMetres / Self.shoreWaterRingMetres)
        for ring in 1...rings {
            let metres = Double(ring) * Self.shoreWaterRingMetres
            for step in 0..<Self.shoreWaterBearings {
                let bearing = Double(step) / Double(Self.shoreWaterBearings) * 2 * .pi
                let reading = GeoPoint(point.latitude + metres * cos(bearing) / GeoPoint.metresPerDegree,
                                       AtlasGrid.normalised(point.longitude + metres * sin(bearing)
                                           / max(point.metresPerDegreeLongitude, 1)))
                if reading.isValid, !shore.isLand(at: reading) { return true }
            }
        }
        return false
    }
}
