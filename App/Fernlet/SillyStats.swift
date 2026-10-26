//
//  SillyStats.swift
//  Fernlet
//
//  Silly stats: lifetime totals turned into deliberately useless comparisons ("You've climbed 2.3
//  Eiffel Towers", "Your CPD is 0.8"). They exist to be funny, not to measure anything, so the
//  feature keeps three promises: every stat is a running total plus a comparison — no goals, rates
//  to beat, streaks, badges, coins or friends to compare against; nothing reads calories, body
//  weight, cycle or intimate data, or what a journal says; and numbers that come from Apple Health
//  are computed on the phone and never stored anywhere that syncs.
//
//  This file holds the vocabulary (the nineteen kinds, the tally, the comparison units) and the
//  engine (reveal rules, derived numbers, comparison ladders). The tally is built by
//  `SillyStatsTallier`, the words come from `SillyStatsCopy`, and the companion's every-few-days
//  mention is paced by `SillyStatsCompanionPacer`.
//

import Foundation

/// The nineteen silly stats, in page order.
///
/// `rawValue` is a frozen token: ``SillyStatsCompanionPacer`` persists the last-mentioned kind and
/// each kind's last-mentioned value under it in device-local `UserDefaults`, and every stamp in the
/// stamp book is keyed by it (``SillyStampEntry``), so renaming a case would make the companion
/// forget what it last said and strand the stat's stamp (pinned by `SillyStatsTests.frozenKindTokens`).
/// Display copy lives in ``SillyStatsCopy`` and ``SillyStampCopy``.
enum SillyStatKind: String, CaseIterable, Codable, Sendable {
    case cookiesPerDay
    case bananasForScale
    case eggonomics
    case pizzaPieChart
    case bathtubIndex
    case coffeeTower
    case signatureDish
    case totalTonnage
    case moonwalk
    case stairwayToSomewhere
    case grandTours
    case shakespeareSteps
    case koalaDays
    case dreamCinema
    case flossRope
    case brushMarathon
    case showerConcerts
    case patsGiven
    case gastrotrichLifetimes
}

/// The homemade recipe logged most often, for the Signature Dish stat.
///
/// `name` is the user's own recipe name, shown verbatim; it never leaves the device through this
/// feature.
struct SillySignatureDish: Equatable, Sendable {
    var name: String
    var count: Int
}

/// Lifetime totals the silly stats are computed from — plain numbers, held in memory only.
///
/// Built by ``SillyStatsTallier`` from the diary, the Apple Health step total and the device-local
/// pat count. Nothing here is persisted: the Health-derived fields (`steps`, sleep hours Health
/// supplied, `remMinutes`) must never reach synced state, so the tally is rebuilt on read instead
/// of cached.
struct SillyStatsTally: Equatable, Sendable {
    /// Days from the first day with anything logged through today, inclusive (at least 1).
    var daysKnown = 1
    var cookieEquivalents = 0.0
    var bananas = 0.0
    var eggs = 0.0
    var pizzaSlices = 0.0
    var waterLiters = 0.0
    var coffeeCups = 0.0
    var signatureDish: SillySignatureDish?
    var liftedKilograms = 0.0
    var steps = 0
    /// Walking, running and hiking distance from logged workouts — the fallback when Health
    /// supplies no steps (a walk's distance is already inside its steps otherwise).
    var workoutFootKilometers = 0.0
    var stairMeters = 0.0
    var swimKilometers = 0.0
    var cycleKilometers = 0.0
    var sleepHours = 0.0
    var remMinutes = 0.0
    var flossCount = 0
    var brushCount = 0
    var showerCount = 0
    var pats = 0
}

/// A thing to compare a total against: a dachshund, a grand piano, a bathtub, Hamlet.
///
/// Display vocabulary only — never persisted. `size` is in the ladder's base unit (meters,
/// kilograms, liters, minutes or words); ``SillyStatsCopy/phrase(_:locale:)`` supplies the words.
enum SillyUnit: Equatable, Sendable {
    case dachshund, giraffe, schoolBus, statueOfLiberty, eiffelTower, burjKhalifa, everest, spaceStation
    case goldenRetriever, grandPiano, elephant, blueWhale
    case bucket, bathtub, hotTub
    case sitcomEpisode, featureFilm, crossCountryFlight
    case hamlet, completeShakespeare

    /// The unit's size in its ladder's base unit.
    var size: Double {
        switch self {
        case .dachshund: 0.6
        case .giraffe: 5.5
        case .schoolBus: 12
        case .statueOfLiberty: 93
        case .eiffelTower: 330
        case .burjKhalifa: 828
        case .everest: 8_849
        case .spaceStation: 408_000
        case .goldenRetriever: 30
        case .grandPiano: 450
        case .elephant: 6_000
        case .blueWhale: 150_000
        case .bucket: 10
        case .bathtub: 150
        case .hotTub: 1_500
        case .sitcomEpisode: 22
        case .featureFilm: 120
        case .crossCountryFlight: 360
        case .hamlet: 30_557
        case .completeShakespeare: 884_421
        }
    }
}

/// A total expressed in one unit: "1.6 grand pianos" is `(.grandPiano, 1.6)`.
struct SillyComparison: Equatable, Sendable {
    var unit: SillyUnit
    var count: Double
}

/// The silly stats' rules: when each stat appears, the number the companion tracks, and the
/// derived figures and comparisons the copy reads.
///
/// Pure and clock-free. A stat stays hidden until its total is big enough to be worth a sentence:
/// the very long journeys (the Moon, the English Channel, the Tour de France) wait for 0.1% of the
/// trip, the companion's age waits for one gastrotrich lifetime, and everything else appears as
/// soon as something countable is logged.
enum SillyStatsEngine {
    /// The fixed figures behind every comparison. Approximate on purpose — that is the joke.
    enum Constant {
        static let strideKilometers = 0.000762
        static let moonKilometers = 384_400.0
        static let earthKilometers = 40_075.0
        static let englishChannelKilometers = 33.3
        static let tourDeFranceKilometers = 3_400.0
        /// A very long trip's stat appears at a tenth of a percent of it: the trip divided by this.
        /// A divisor rather than a 0.001 multiplier because `384_400 * 0.001` rounds to just over
        /// 384.4, which would make the stat wait a hair past the tenth of a percent.
        static let longTripRevealDivisor = 1_000.0
        static let henEggsPerYear = 300.0
        static let slicesPerPizza = 8.0
        static let bananaMeters = 0.18
        static let coffeeCupMeters = 0.12
        static let flossMeters = 0.45
        static let brushMinutes = 2.0
        static let songsPerShower = 3
        static let koalaSleepHours = 20.0
        static let filmMinutes = 120.0
        static let gastrotrichDays = 3.0
        static let stairMetersPerMinute = 10.0
        static let shininessPercentPerPat = 0.02
        static let signatureDishMinimum = 3
    }

    static let lengthLadder: [SillyUnit] = [
        .dachshund, .giraffe, .schoolBus, .statueOfLiberty, .eiffelTower, .burjKhalifa, .everest, .spaceStation,
    ]
    static let heightLadder: [SillyUnit] = [.statueOfLiberty, .eiffelTower, .burjKhalifa, .everest, .spaceStation]
    static let massLadder: [SillyUnit] = [.goldenRetriever, .grandPiano, .elephant, .blueWhale]
    static let volumeLadder: [SillyUnit] = [.bucket, .bathtub, .hotTub]
    static let durationLadder: [SillyUnit] = [.sitcomEpisode, .featureFilm, .crossCountryFlight]
    static let wordLadder: [SillyUnit] = [.hamlet, .completeShakespeare]

    /// The stats with enough behind them to show, in page order.
    static func revealed(in tally: SillyStatsTally) -> [SillyStatKind] {
        SillyStatKind.allCases.filter { isRevealed($0, in: tally) }
    }

    /// Whether `kind` has enough behind it to show.
    static func isRevealed(_ kind: SillyStatKind, in tally: SillyStatsTally) -> Bool {
        switch kind {
        case .moonwalk:
            return footKilometers(tally) >= Constant.moonKilometers / Constant.longTripRevealDivisor
        case .grandTours:
            return showsChannel(tally) || showsTour(tally)
        case .shakespeareSteps:
            return Double(tally.steps) >= SillyUnit.hamlet.size
        case .koalaDays:
            return tally.sleepHours >= Constant.koalaSleepHours
        case .dreamCinema:
            return tally.remMinutes >= Constant.filmMinutes
        case .gastrotrichLifetimes:
            return Double(tally.daysKnown) >= Constant.gastrotrichDays
        case .signatureDish:
            return (tally.signatureDish?.count ?? 0) >= Constant.signatureDishMinimum
        default:
            return value(kind, in: tally) > 0
        }
    }

    /// The one number the companion compares between mentions — when it has not moved, there is
    /// nothing new to say about the stat.
    static func value(_ kind: SillyStatKind, in tally: SillyStatsTally) -> Double {
        switch kind {
        case .cookiesPerDay: tally.cookieEquivalents
        case .bananasForScale: tally.bananas
        case .eggonomics: tally.eggs
        case .pizzaPieChart: tally.pizzaSlices
        case .bathtubIndex: tally.waterLiters
        case .coffeeTower: tally.coffeeCups
        case .signatureDish: Double(tally.signatureDish?.count ?? 0)
        case .totalTonnage: tally.liftedKilograms
        case .moonwalk: footKilometers(tally)
        case .stairwayToSomewhere: tally.stairMeters
        case .grandTours: tally.swimKilometers + tally.cycleKilometers
        case .shakespeareSteps: Double(tally.steps)
        case .koalaDays: tally.sleepHours
        case .dreamCinema: tally.remMinutes
        case .flossRope: Double(tally.flossCount)
        case .brushMarathon: Double(tally.brushCount)
        case .showerConcerts: Double(tally.showerCount)
        case .patsGiven: Double(tally.pats)
        case .gastrotrichLifetimes: Double(tally.daysKnown)
        }
    }

    // MARK: - Derived figures

    static func cookiesPerDay(_ tally: SillyStatsTally) -> Double {
        tally.cookieEquivalents / Double(max(tally.daysKnown, 1))
    }

    /// Distance on foot: steps at an average stride, or logged walks/runs/hikes when Health
    /// supplies fewer steps than those workouts cover.
    static func footKilometers(_ tally: SillyStatsTally) -> Double {
        max(Double(tally.steps) * Constant.strideKilometers, tally.workoutFootKilometers)
    }

    static func moonFraction(_ tally: SillyStatsTally) -> Double {
        footKilometers(tally) / Constant.moonKilometers
    }

    static func earthLaps(_ tally: SillyStatsTally) -> Double {
        footKilometers(tally) / Constant.earthKilometers
    }

    static func channelFraction(_ tally: SillyStatsTally) -> Double {
        tally.swimKilometers / Constant.englishChannelKilometers
    }

    static func tourFraction(_ tally: SillyStatsTally) -> Double {
        tally.cycleKilometers / Constant.tourDeFranceKilometers
    }

    static func showsChannel(_ tally: SillyStatsTally) -> Bool {
        tally.swimKilometers >= Constant.englishChannelKilometers / Constant.longTripRevealDivisor
    }

    static func showsTour(_ tally: SillyStatsTally) -> Bool {
        tally.cycleKilometers >= Constant.tourDeFranceKilometers / Constant.longTripRevealDivisor
    }

    static func henYearFraction(_ tally: SillyStatsTally) -> Double {
        tally.eggs / Constant.henEggsPerYear
    }

    static func pizzas(_ tally: SillyStatsTally) -> Double {
        tally.pizzaSlices / Constant.slicesPerPizza
    }

    static func showerSongs(_ tally: SillyStatsTally) -> Int {
        tally.showerCount * Constant.songsPerShower
    }

    static func koalaDays(_ tally: SillyStatsTally) -> Double {
        tally.sleepHours / Constant.koalaSleepHours
    }

    static func dreamFilms(_ tally: SillyStatsTally) -> Double {
        tally.remMinutes / Constant.filmMinutes
    }

    static func gastrotrichLifetimes(_ tally: SillyStatsTally) -> Double {
        Double(tally.daysKnown) / Constant.gastrotrichDays
    }

    static func furShininessPercent(_ tally: SillyStatsTally) -> Double {
        Double(tally.pats) * Constant.shininessPercentPerPat
    }

    // MARK: - Comparisons

    /// The ladder comparison a stat's copy reads; nil for stats whose copy is not ladder-shaped
    /// (CPD, eggs, pizza, the Moon, the Channel, sleep, showers, pats, the gastrotrich, the dish).
    static func comparison(for kind: SillyStatKind, in tally: SillyStatsTally) -> SillyComparison? {
        switch kind {
        case .bananasForScale: comparison(tally.bananas * Constant.bananaMeters, ladder: lengthLadder)
        case .coffeeTower: comparison(tally.coffeeCups * Constant.coffeeCupMeters, ladder: lengthLadder)
        case .flossRope: comparison(Double(tally.flossCount) * Constant.flossMeters, ladder: lengthLadder)
        case .stairwayToSomewhere: comparison(tally.stairMeters, ladder: heightLadder)
        case .totalTonnage: comparison(tally.liftedKilograms, ladder: massLadder)
        case .bathtubIndex: comparison(tally.waterLiters, ladder: volumeLadder)
        case .brushMarathon: comparison(Double(tally.brushCount) * Constant.brushMinutes, ladder: durationLadder)
        case .shakespeareSteps: comparison(Double(tally.steps), ladder: wordLadder)
        default: nil
        }
    }

    /// `value` in the largest unit of `ladder` it reaches at least once — or, below the first
    /// rung, as a fraction of it ("0.4 giraffes").
    static func comparison(_ value: Double, ladder: [SillyUnit]) -> SillyComparison? {
        guard value.isFinite, value >= 0, let first = ladder.first else { return nil }
        var chosen = first
        for unit in ladder where value >= unit.size {
            chosen = unit
        }
        return SillyComparison(unit: chosen, count: value / chosen.size)
    }
}
