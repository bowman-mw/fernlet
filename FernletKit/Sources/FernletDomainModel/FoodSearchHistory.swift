// FoodSearchHistory.swift
// FernletDomainModel
//
// Research §26 fix 1.9 (Docs/Food-Search-And-Community-Database-Research-2026-08-22.md, §30 row 9):
// history-first ranking. The foods this person has actually logged are ranked above everything else
// in `FoodItemSearch`'s comparator, ordered among themselves by a `log(1 + count)` frequency term
// and an exponential recency decay — §26's prescription, verbatim.
//
// DERIVED, NOT PERSISTED — the one deliberate divergence from §26's data note, recorded here at the
// seam it affects. §26 offers two sources: `FernletStore.dedupedRecentMeals` or "a new per-
// `foodItemId` usage ledger in `DiaryStore`", and its Risk column and §30 row 9's gate both assume
// the second ("a new persisted surface → needs a `Docs/PrivacyWipeCoverage.md` disposition row").
// This takes the FIRST. `DiaryStore.recentMeals` — the rolling 50-meal window already in the synced
// snapshot — already carries everything a usage ledger would hold: `MealComponentSnapshot.foodItemId`
// is the bound food and `Meal.loggedAt` is the timestamp. A parallel ledger would be a second copy of
// facts the blob already stores, able to disagree with it, and would need its own wipe leg, its own
// resurrection audit and its own migration. So there is NO new persisted surface, no new
// `UserDefaults` key, and nothing for `Docs/PrivacyWipeCoverage.md` to add a row for: the profile is
// recomputed from `recentMeals` whenever `recentMeals` changes, which means the existing wipe of the
// diary IS the wipe of this feature (`DiaryStore.resetDiary` sets `recentMeals = []`, and the same
// `didSet` that publishes a profile publishes the empty one).
//
// THE HORIZON IS THE 50-MEAL WINDOW, and it is a good fit rather than a compromise. §11's outcome
// evidence (Harvey et al. 2019) measures successful loggers re-entering **2.4–2.7 times a day**, so
// 50 meals is roughly 19 days of logging — inside the τ ≈ 14–30 day decay band §26 prescribes, which
// is to say the window ends at about the point the decay would have made a row's weight negligible
// anyway.

import Foundation

/// The foods this device's own user has logged recently, weighted for ranking — research §26 fix 1.9.
///
/// A pure value derived from `DiaryStore.recentMeals` (see this file's header for why nothing new is
/// persisted), published into the catalog and read by ``FoodItemSearch``'s comparator as its TOP key:
/// any food carrying a weight outranks every food that carries none, and among weighted foods the
/// larger weight wins.
///
/// **It re-ranks; it never injects.** Every row it reorders has already passed the FTS gate, fix
/// 1.8's name-carriage floor AND the `minimumBindScore` floor — a history weight cannot put a row in
/// front of the user that the cold pipeline would have refused, and cannot reach a row that retrieval
/// never fetched. That is the property that keeps the fix behind every review gate, and it is the
/// structural difference from fix 1.10's correction alias, which deliberately DOES inject by id.
///
/// **Empty by default, everywhere.** ``empty`` is the default on every `FoodItemSearch` entry point,
/// so a catalog nobody has hydrated — every unit test, and the 57-query corpus instrument — measures
/// the cold path exactly as before.
public nonisolated struct FoodSearchHistory: Sendable, Equatable {
    /// The cold profile: nothing logged, nothing promoted. The default on every search entry point.
    public static let empty = FoodSearchHistory(weights: [:])

    /// τ, the exponential recency decay constant in days — the midpoint of §26's prescribed 14–30 day
    /// band. A food last eaten τ days ago keeps 1/e ≈ 37% of its frequency weight.
    ///
    /// Only orders foods WITHIN the history tier: tier membership is decay-independent (see
    /// ``scaledWeight(count:lastLoggedAt:now:)``, which floors a logged food at 1), because §14's
    /// published hierarchy is that history rows "will always show up at the top", not that they fade
    /// out of it. The 50-meal source window is what actually bounds staleness.
    public static let recencyDecayDays = 21.0

    /// Weights are integers so the comparator can never be handed a NaN and never depends on float
    /// equality: the continuous weight is multiplied by this and rounded. Equal weights fall through
    /// to the next comparator key deterministically.
    public static let weightScale = 1_000.0

    /// R3 growth bound on the derivation's input. `DiaryStore.appendMeal` already caps `recentMeals`
    /// at 50; this re-applies the cap at the READ side so a hand-edited or older-build snapshot cannot
    /// hand the ranker an unbounded profile — the same posture as `DiaryStore.boundedDailyScores`.
    public static let maximumTrackedMeals = 50

    /// R2/R3 bound on components inspected in any one meal. Logged meals are normally far smaller;
    /// this read-side cap protects derivation from an oversized restored or hand-edited snapshot.
    public static let maximumComponentsPerMeal = 100

    /// Clamp on the decay's age term. Nothing in a 50-meal window is realistically this old, so this
    /// exists only to keep `exp` and the `Int` conversion in a range that can never produce a
    /// non-finite value or an overflow — Power-of-10's "no silent traps".
    private static let maximumDecayDays = 3_650.0

    /// The sufficient statistics retained for a derived profile. Decay is deliberately NOT stored:
    /// it is evaluated against one captured instant when a search runs, so an idle app cannot keep
    /// yesterday's weights until the next diary mutation.
    private struct Usage: Sendable, Equatable {
        let count: Int
        let lastLoggedAt: Date
    }

    private let usage: [UUID: Usage]
    /// Exact synthetic weights are a narrow deterministic test seam. Production construction uses
    /// `usage`, so its weights always decay at query time.
    private let exactWeights: [UUID: Int]

    /// Creates a profile from already-computed weights for deterministic comparator tests. Production
    /// uses ``from(recentMeals:)`` so it retains sufficient statistics and decays at query time.
    public init(weights: [UUID: Int]) {
        self.usage = [:]
        self.exactWeights = weights
    }

    private init(usage: [UUID: Usage]) {
        self.usage = usage
        self.exactWeights = [:]
    }

    /// Whether this profile promotes nothing — true for ``empty`` and for a user who has logged no
    /// meal whose components bound to a catalog food.
    public var isEmpty: Bool { usage.isEmpty && exactWeights.isEmpty }

    /// How many distinct foods carry a weight. Drives test preconditions, so a bank cannot pass
    /// vacuously against a profile that turned out to be empty.
    public var trackedFoodCount: Int { usage.count + exactWeights.count }

    /// This food's ranking weight, or 0 when the user has never logged it.
    public func weight(for foodItemID: UUID, now: Date = Date()) -> Int {
        if let exact = exactWeights[foodItemID] { return exact }
        guard let entry = usage[foodItemID] else { return 0 }
        return Self.scaledWeight(count: entry.count, lastLoggedAt: entry.lastLoggedAt, now: now)
    }

    /// Derives the profile from the meal history — the ONLY production constructor.
    ///
    /// One meal contributes at most one count per food (a food appearing twice in the same log is one
    /// eating, not two), and a food's decay is measured from the most recent meal that contained it.
    /// Components with no `foodItemId` — the keyword-fallback tier's fabricated rows, which bound to
    /// no catalog food at all — contribute nothing, because there is no row for them to promote.
    ///
    /// - Parameters:
    ///   - meals: newest-first `recentMeals`. Only the first ``maximumTrackedMeals`` are read.
    public static func from(recentMeals meals: [Meal]) -> FoodSearchHistory {
        var usage: [UUID: Usage] = [:]
        // R2: both loops have explicit read-side caps, independent of snapshot provenance.
        for meal in meals.prefix(maximumTrackedMeals) {
            var seenInThisMeal = Set<UUID>()
            for component in meal.componentSnapshots.prefix(maximumComponentsPerMeal) {
                guard let foodItemID = component.foodItemId, seenInThisMeal.insert(foodItemID).inserted else { continue }
                let previous = usage[foodItemID]
                usage[foodItemID] = Usage(
                    count: (previous?.count ?? 0) + 1,
                    lastLoggedAt: max(previous?.lastLoggedAt ?? meal.loggedAt, meal.loggedAt)
                )
            }
        }
        return FoodSearchHistory(usage: usage)
    }

    /// `round(weightScale · log(1 + count) · exp(-days / τ))`, floored at 1 — §26's formula.
    ///
    /// **The floor at 1 is the tier, and it is deliberate.** Without it a food last eaten long enough
    /// ago rounds to 0 and silently leaves the history tier, which would make "is this in my history"
    /// depend on the clock. With it, a logged food always outranks an unlogged one and the decay does
    /// what §26 asks of it — orders history against itself.
    ///
    /// Every input is clamped so the arithmetic cannot trap: a negative age (a meal stamped in the
    /// future by clock skew or a restored backup) reads as 0, an absurd age is capped, and a
    /// non-finite result — unreachable through those clamps, guarded anyway — reads as the floor.
    ///
    /// `public` so `FoodSearchHistoryTests` can pin §26's formula against the values it prescribes,
    /// directly, instead of inferring the curve from meal fixtures and a ranking.
    public static func scaledWeight(count: Int, lastLoggedAt: Date, now: Date) -> Int {
        guard count > 0 else { return 0 }
        let days = min(max(0, now.timeIntervalSince(lastLoggedAt)) / 86_400, maximumDecayDays)
        let weight = weightScale * log(1 + Double(count)) * exp(-days / recencyDecayDays)
        guard weight.isFinite else { return 1 }
        return max(1, Int(weight.rounded()))
    }
}
