import Foundation

/// The words of Sprout's discovery lines (World-Exploration-Spec §4: all 66 approved, three per category, Sprout
/// taking turns), the mockup's `LINES` verbatim. Catalog keys `worldLines.<category>.<1…3>` (the category's frozen
/// token); a line that fills in the place's name takes it as its one argument. The Spanish is the mockup's own,
/// drafted in `r7-explore-ui-es-lines.json` for the usual review. The airports' six (World-Airports-Spec §3, §6.3)
/// are the spec's drafts, their Spanish in `r7-airports-ui-es-home.json`.
nonisolated enum WorldDiscoveryLinesCopy {
    /// Line `index` (0…2, wrapping) of `category`, with `name` filled in where the line has one.
    static func line(_ category: WorldLineCategory, index: Int, name: String) -> String {
        let all = lines(category, name: name)
        guard !all.isEmpty else { return "" }
        let turn = ((index % all.count) + all.count) % all.count
        return all[turn]
    }

    /// The category's three lines.
    static func lines(_ category: WorldLineCategory, name: String) -> [String] {
        switch category.board {
        case .land: land(category, name: name)
        case .open: open(category, name: name)
        case .towns: towns(category, name: name)
        case .marks: marks(category, name: name)
        case .world: world(category, name: name)
        case .airports: airports(category)
        }
    }

    /// The land's lines (1–15).
    private static func land(_ category: WorldLineCategory, name: String) -> [String] {
        switch category {
        case .desert:
            [
                String(localized: "worldLines.desert.1", defaultValue: "Sand! Everything's so quiet here.",
                       comment: "Sprout's line on first reaching a new place: desert, line 1 of 3"),
                String(localized: "worldLines.desert.2", defaultValue: "A desert. I'll stay in your shadow.",
                       comment: "Sprout's line on first reaching a new place: desert, line 2 of 3"),
                String(localized: "worldLines.desert.3", defaultValue: "It's warm right down to my roots.",
                       comment: "Sprout's line on first reaching a new place: desert, line 3 of 3"),
            ]
        case .mountain:
            [
                String(localized: "worldLines.mountain.1", defaultValue: "A mountain! I can see so far.",
                       comment: "Sprout's line on first reaching a new place: mountain, line 1 of 3"),
                String(localized: "worldLines.mountain.2", defaultValue: "Up we go, one step at a time.",
                       comment: "Sprout's line on first reaching a new place: mountain, line 2 of 3"),
                String(localized: "worldLines.mountain.3", defaultValue: "The air tastes different up here.",
                       comment: "Sprout's line on first reaching a new place: mountain, line 3 of 3"),
            ]
        case .temperateForest:
            [
                String(localized: "worldLines.temperateForest.1", defaultValue: "Trees all around. I feel tiny.",
                       comment: "Sprout's line on first reaching a new place: temperate forest, line 1 of 3"),
                String(localized: "worldLines.temperateForest.2", defaultValue: "Listen: leaves.",
                       comment: "Sprout's line on first reaching a new place: temperate forest, line 2 of 3"),
                String(localized: "worldLines.temperateForest.3", defaultValue: "A forest! Let's go slowly.",
                       comment: "Sprout's line on first reaching a new place: temperate forest, line 3 of 3"),
            ]
        case .tropicalForest:
            [
                String(localized: "worldLines.tropicalForest.1", defaultValue: "It's so green it's almost loud.",
                       comment: "Sprout's line on first reaching a new place: tropical forest, line 1 of 3"),
                String(localized: "worldLines.tropicalForest.2", defaultValue: "Everything here is growing at once.",
                       comment: "Sprout's line on first reaching a new place: tropical forest, line 2 of 3"),
                String(localized: "worldLines.tropicalForest.3", defaultValue: "Palms! I'd like to be one.",
                       comment: "Sprout's line on first reaching a new place: tropical forest, line 3 of 3"),
            ]
        case .borealForest:
            [
                String(localized: "worldLines.borealForest.1", defaultValue: "Pines everywhere. It smells like winter.",
                       comment: "Sprout's line on first reaching a new place: boreal forest, line 1 of 3"),
                String(localized: "worldLines.borealForest.2", defaultValue: "A quiet forest. Let's whisper.",
                       comment: "Sprout's line on first reaching a new place: boreal forest, line 2 of 3"),
                String(localized: "worldLines.borealForest.3", defaultValue: "So many needles, all pointing up.",
                       comment: "Sprout's line on first reaching a new place: boreal forest, line 3 of 3"),
            ]
        default:
            []
        }
    }

    /// Open ground, water and cold (16–30).
    private static func open(_ category: WorldLineCategory, name: String) -> [String] {
        switch category {
        case .grassland:
            [
                String(localized: "worldLines.grassland.1", defaultValue: "Grass as far as I can see.",
                       comment: "Sprout's line on first reaching a new place: grassland, line 1 of 3"),
                String(localized: "worldLines.grassland.2", defaultValue: "Room to roll around in.",
                       comment: "Sprout's line on first reaching a new place: grassland, line 2 of 3"),
                String(localized: "worldLines.grassland.3", defaultValue: "Wildflowers! Don't step on them.",
                       comment: "Sprout's line on first reaching a new place: grassland, line 3 of 3"),
            ]
        case .cropland:
            [
                String(localized: "worldLines.cropland.1", defaultValue: "Fields! Someone grew all this.",
                       comment: "Sprout's line on first reaching a new place: cropland, line 1 of 3"),
                String(localized: "worldLines.cropland.2", defaultValue: "Rows and rows. I counted three.",
                       comment: "Sprout's line on first reaching a new place: cropland, line 2 of 3"),
                String(localized: "worldLines.cropland.3", defaultValue: "It smells like bread out here.",
                       comment: "Sprout's line on first reaching a new place: cropland, line 3 of 3"),
            ]
        case .shore:
            [
                String(localized: "worldLines.shore.1", defaultValue: "The water! It's bigger than I thought.",
                       comment: "Sprout's line on first reaching a new place: sea or lake shore, line 1 of 3"),
                String(localized: "worldLines.shore.2", defaultValue: "Waves keep coming back to say hi.",
                       comment: "Sprout's line on first reaching a new place: sea or lake shore, line 2 of 3"),
                String(localized: "worldLines.shore.3", defaultValue: "Salt in the air. I like it.",
                       comment: "Sprout's line on first reaching a new place: sea or lake shore, line 3 of 3"),
            ]
        case .tundra:
            [
                String(localized: "worldLines.tundra.1", defaultValue: "Wide and windy. Hold on to me.",
                       comment: "Sprout's line on first reaching a new place: tundra, line 1 of 3"),
                String(localized: "worldLines.tundra.2", defaultValue: "Tiny flowers, brave ones.",
                       comment: "Sprout's line on first reaching a new place: tundra, line 2 of 3"),
                String(localized: "worldLines.tundra.3", defaultValue: "It's very open up here.",
                       comment: "Sprout's line on first reaching a new place: tundra, line 3 of 3"),
            ]
        case .ice:
            [
                String(localized: "worldLines.ice.1", defaultValue: "Ice! My feet are cold.",
                       comment: "Sprout's line on first reaching a new place: ice, line 1 of 3"),
                String(localized: "worldLines.ice.2", defaultValue: "Everything's sparkling.",
                       comment: "Sprout's line on first reaching a new place: ice, line 2 of 3"),
                String(localized: "worldLines.ice.3", defaultValue: "Careful, it's slippy.",
                       comment: "Sprout's line on first reaching a new place: ice, line 3 of 3"),
            ]
        default:
            []
        }
    }

    /// Towns and cities, by size (31–45).
    private static func towns(_ category: WorldLineCategory, name: String) -> [String] {
        switch category {
        case .village:
            [
                String(localized: "worldLines.village.1", defaultValue: "A little village. Everyone waves here.",
                       comment: "Sprout's line on first reaching a new place: village, line 1 of 3"),
                String(localized: "worldLines.village.2", defaultValue: "\(name)! Small and sweet.",
                       comment: "Sprout's line on first reaching a new place: village, line 2 of 3; the place's name"),
                String(localized: "worldLines.village.3", defaultValue: "A few roofs and a lot of sky.",
                       comment: "Sprout's line on first reaching a new place: village, line 3 of 3"),
            ]
        case .town:
            [
                String(localized: "worldLines.town.1", defaultValue: "\(name)! Let's find the bakery.",
                       comment: "Sprout's line on first reaching a new place: town, line 1 of 3; the place's name"),
                String(localized: "worldLines.town.2", defaultValue: "A new town. I like the windows.",
                       comment: "Sprout's line on first reaching a new place: town, line 2 of 3"),
                String(localized: "worldLines.town.3", defaultValue: "\(name). Busy, but friendly.",
                       comment: "Sprout's line on first reaching a new place: town, line 3 of 3; the place's name"),
            ]
        case .city:
            [
                String(localized: "worldLines.city.1", defaultValue: "\(name)! So many streets to learn.",
                       comment: "Sprout's line on first reaching a new place: city, line 1 of 3; the place's name"),
                String(localized: "worldLines.city.2", defaultValue: "A city. Stay close.",
                       comment: "Sprout's line on first reaching a new place: city, line 2 of 3"),
                String(localized: "worldLines.city.3", defaultValue: "Look up: buildings!",
                       comment: "Sprout's line on first reaching a new place: city, line 3 of 3"),
            ]
        case .bigCity:
            [
                String(localized: "worldLines.bigCity.1", defaultValue: "\(name)! It goes on and on.",
                       comment: "Sprout's line on first reaching a new place: big city, line 1 of 3; the place's name"),
                String(localized: "worldLines.bigCity.2", defaultValue: "So many people. Hi, everyone.",
                       comment: "Sprout's line on first reaching a new place: big city, line 2 of 3"),
                String(localized: "worldLines.bigCity.3", defaultValue: "A big city. One street at a time.",
                       comment: "Sprout's line on first reaching a new place: big city, line 3 of 3"),
            ]
        case .megacity:
            [
                String(localized: "worldLines.megacity.1", defaultValue: "\(name)! I don't think it ends.",
                       comment: "Sprout's line on first reaching a new place: megacity, line 1 of 3; the place's name"),
                String(localized: "worldLines.megacity.2", defaultValue: "This is the biggest place I've seen.",
                       comment: "Sprout's line on first reaching a new place: megacity, line 2 of 3"),
                String(localized: "worldLines.megacity.3", defaultValue: "Lights everywhere. Wow.",
                       comment: "Sprout's line on first reaching a new place: megacity, line 3 of 3"),
            ]
        default:
            []
        }
    }

    /// A landmark, a new country, a new continent (46–54).
    private static func marks(_ category: WorldLineCategory, name: String) -> [String] {
        switch category {
        case .landmark:
            [
                String(localized: "worldLines.landmark.1", defaultValue: "\(name)! I've heard about this.",
                       comment: "Sprout's line on first reaching a new place: landmark, line 1 of 3; the place's name"),
                String(localized: "worldLines.landmark.2", defaultValue: "Let's remember this one.",
                       comment: "Sprout's line on first reaching a new place: landmark, line 2 of 3"),
                String(localized: "worldLines.landmark.3", defaultValue: "A famous spot. Smile!",
                       comment: "Sprout's line on first reaching a new place: landmark, line 3 of 3"),
            ]
        case .country:
            [
                String(localized: "worldLines.country.1", defaultValue: "A new country! \(name).",
                       comment: "Sprout's line on first reaching a new place: new country, line 1 of 3; the place's name"),
                String(localized: "worldLines.country.2", defaultValue: "\(name). Everything's a little different.",
                       comment: "Sprout's line on first reaching a new place: new country, line 2 of 3; the place's name"),
                String(localized: "worldLines.country.3", defaultValue: "New stamp! Welcome to \(name).",
                       comment: "Sprout's line on first reaching a new place: new country, line 3 of 3; the place's name"),
            ]
        case .continent:
            [
                String(localized: "worldLines.continent.1", defaultValue: "A whole new continent!",
                       comment: "Sprout's line on first reaching a new place: new continent, line 1 of 3"),
                String(localized: "worldLines.continent.2", defaultValue: "\(name)! We came so far.",
                       comment: "Sprout's line on first reaching a new place: new continent, line 2 of 3; the place's name"),
                String(localized: "worldLines.continent.3", defaultValue: "Another continent. Look at us.",
                       comment: "Sprout's line on first reaching a new place: new continent, line 3 of 3"),
            ]
        default:
            []
        }
    }

    /// Oceans, seas and the two specials (55–66).
    private static func world(_ category: WorldLineCategory, name: String) -> [String] {
        switch category {
        case .ocean:
            [
                String(localized: "worldLines.ocean.1", defaultValue: "The \(name)! Hello, big water.",
                       comment: "Sprout's line on first reaching a new place: new ocean, line 1 of 3; the place's name"),
                String(localized: "worldLines.ocean.2", defaultValue: "A new ocean. It's very blue.",
                       comment: "Sprout's line on first reaching a new place: new ocean, line 2 of 3"),
                String(localized: "worldLines.ocean.3", defaultValue: "The \(name). Listen to it.",
                       comment: "Sprout's line on first reaching a new place: new ocean, line 3 of 3; the place's name"),
            ]
        case .sea:
            [
                String(localized: "worldLines.sea.1", defaultValue: "The \(name)! A whole new sea.",
                       comment: "Sprout's line on first reaching a new place: new sea, line 1 of 3; the place's name"),
                String(localized: "worldLines.sea.2", defaultValue: "\(name). The water feels different here.",
                       comment: "Sprout's line on first reaching a new place: new sea, line 2 of 3; the place's name"),
                String(localized: "worldLines.sea.3", defaultValue: "A new sea. Hello, waves.",
                       comment: "Sprout's line on first reaching a new place: new sea, line 3 of 3"),
            ]
        case .allContinents:
            [
                String(localized: "worldLines.allContinents.1", defaultValue: "All seven continents. You did that!",
                       comment: "Sprout's line on first reaching a new place: all seven continents, line 1 of 3"),
                String(localized: "worldLines.allContinents.2", defaultValue: "Every continent. I'm so proud of us.",
                       comment: "Sprout's line on first reaching a new place: all seven continents, line 2 of 3"),
                String(localized: "worldLines.allContinents.3", defaultValue: "The whole world, one step at a time.",
                       comment: "Sprout's line on first reaching a new place: all seven continents, line 3 of 3"),
            ]
        case .allOceans:
            [
                String(localized: "worldLines.allOceans.1", defaultValue: "All five oceans. That's all the sea!",
                       comment: "Sprout's line on first reaching a new place: all five oceans, line 1 of 3"),
                String(localized: "worldLines.allOceans.2", defaultValue: "Every ocean. My feet are salty.",
                       comment: "Sprout's line on first reaching a new place: all five oceans, line 2 of 3"),
                String(localized: "worldLines.allOceans.3", defaultValue: "The whole world's water. Wow.",
                       comment: "Sprout's line on first reaching a new place: all five oceans, line 3 of 3"),
            ]
        default:
            []
        }
    }

    /// A new airport's lines and a landing's (World-Airports-Spec §3, §6.3; drafts for the owner's string review).
    private static func airports(_ category: WorldLineCategory) -> [String] {
        switch category {
        case .airport:
            [
                String(localized: "worldLines.airport.1", defaultValue: "An airport! Are we going somewhere?",
                       comment: "Sprout's line on first finding an airport, line 1 of 3"),
                String(localized: "worldLines.airport.2", defaultValue: "So many planes. Which one is ours?",
                       comment: "Sprout's line on first finding an airport, line 2 of 3"),
                String(localized: "worldLines.airport.3", defaultValue: "Leaf packed. Let's fly!",
                       comment: "Sprout's line on first finding an airport, line 3 of 3 (Sprout's leaf is packed)"),
            ]
        case .landing:
            [
                String(localized: "worldLines.landing.1", defaultValue: "We flew! My leaf's all fluffy.",
                       comment: "Sprout's line just after a flight lands, line 1 of 3"),
                String(localized: "worldLines.landing.2", defaultValue: "Touchdown! Where are we?",
                       comment: "Sprout's line just after a flight lands, line 2 of 3"),
                String(localized: "worldLines.landing.3", defaultValue: "That was a long nap.",
                       comment: "Sprout's line just after a flight lands, line 3 of 3"),
            ]
        default:
            []
        }
    }
}
