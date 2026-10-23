import FernletDomainModel
import Foundation

/// Everything the World Home's status bar shows, read from the same sources today's Home uses
/// (World app plan step 2a; data parity is a hard requirement).
///
/// | Piece | Source (unchanged) |
/// |---|---|
/// | Hearts | `FernletStore.liveCareScore`: `score` plus gold hearts, in `HealthBar`'s 12 steps |
/// | Gold hearts | `ProximityHeartLedger`, in-person hearts under 12 hours old, at most 2 (`GoldHeartRules`) |
/// | Protein, carbs, fat | `macroTotals` against `nutritionTargets`, as `MacroCard` |
/// | Water | `day.bottleCount` against `settings.hydrationTarget` (bottles, default 4) |
///
/// That is the whole bar the owner approved (batch 1, 2026-10-23): no clock, weather or coins up top.
/// The time of day and the weather show only on the map (its tint, rain and snow), and coins stay in
/// Customize and the friend shop, as today.
///
/// A plain value: the view draws it, tests build it with ``make(score:goldHearts:macros:targets:bottles:bottleTarget:)``.
struct WorldStatus: Equatable {
    /// One macro's progress: grams today against the day's target.
    struct Macro: Equatable {
        let grams: Int
        let target: Int

        /// How full the bar is, 0...1 (an unset target reads as empty, never full).
        var fraction: Double {
            guard target > 0, grams > 0 else { return 0 }
            return min(1, Double(grams) / Double(target))
        }
    }

    /// How the water row reads (the batch 1 design's rule).
    enum Water: Equatable {
        /// One drop per bottle of the target, `filled` of them full, plus `extra` past the target.
        case drops(filled: Int, total: Int, extra: Int)
        /// "n / target": for a target above ``maxDrops``, or at accessibility text sizes.
        case count(bottles: Int, target: Int)
    }

    /// The most drops the row draws before it switches to "n / target".
    static let maxDrops = 8

    /// The care score with gold hearts, in `HealthBar`'s 12 steps (two per heart of six).
    let heartSteps: Int
    /// The care score without the boost, 0...100: what VoiceOver says first ("Care score 58 percent").
    let carePercent: Int
    /// The care score with the boost, 0...100.
    let livePercent: Int
    /// Gold hearts showing, 0...2.
    let goldHearts: Int
    let protein: Macro
    let carbs: Macro
    let fat: Macro
    /// Bottles of water today.
    let bottles: Int
    /// The day's bottle target (settings; 0 means none set).
    let bottleTarget: Int

    /// The status for these readings.
    static func make(score: Double, goldHearts: Int, macros: MacroTotals, targets: NutritionTargets,
                     bottles: Int, bottleTarget: Int) -> WorldStatus {
        let gold = min(max(goldHearts, 0), GoldHeartRules.maxActive)
        let base = score.isFinite ? min(1, max(0, score)) : 0
        let live = GoldHeartRules.boosted(score: base, goldHearts: gold)
        return WorldStatus(
            heartSteps: Int((live * 12).rounded()), carePercent: Int((base * 100).rounded()),
            livePercent: Int((live * 100).rounded()), goldHearts: gold,
            protein: Macro(grams: max(macros.protein, 0), target: targets.protein),
            carbs: Macro(grams: max(macros.carbs, 0), target: targets.carbs),
            fat: Macro(grams: max(macros.fat, 0), target: targets.fat),
            bottles: max(bottles, 0), bottleTarget: max(bottleTarget, 0))
    }

    /// The status from the store, now.
    @MainActor
    static func current(store: FernletStore, date: Date = Date()) -> WorldStatus {
        make(score: store.score, goldHearts: store.goldHeartCount(at: date), macros: store.macroTotals,
             targets: store.nutritionTargets, bottles: store.day.bottleCount,
             bottleTarget: store.settings.hydrationTarget)
    }

    /// How the water row reads, at the standard text sizes or (`accessibilitySize`) the largest.
    func water(accessibilitySize: Bool) -> Water {
        guard !accessibilitySize, bottleTarget > 0, bottleTarget <= Self.maxDrops else {
            return .count(bottles: bottles, target: bottleTarget)
        }
        return .drops(filled: min(bottles, bottleTarget), total: bottleTarget, extra: max(0, bottles - bottleTarget))
    }

    /// How full heart `index` is, 0...1, when the 12 steps are drawn as `hearts` hearts: six with
    /// halves at standard text sizes, four with thirds at the largest (the batch 1 design). Any count
    /// that doesn't divide 12 draws nothing.
    func heartFill(at index: Int, of hearts: Int) -> Double {
        guard hearts > 0, 12 % hearts == 0, (0..<hearts).contains(index) else { return 0 }
        let perHeart = 12 / hearts
        return Double(min(perHeart, max(0, heartSteps - perHeart * index))) / Double(perHeart)
    }
}
