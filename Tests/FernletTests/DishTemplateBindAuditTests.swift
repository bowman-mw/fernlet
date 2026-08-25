// DishTemplateBindAuditTests.swift
// FernletTests
//
// The gate on §26 fixes 1.1 + 1.2 + 1.3 + 1.4 of
// Docs/Food-Search-And-Community-Database-Research-2026-08-22.md — §30 row 2 states 1.1/1.2's gate in
// one line ("Test over all 29 templates"); row 3 states 1.3/1.4's ("Replay each edited search string").
//
// WHAT THIS SUITE IS. `DishTemplates.json` holds 29 dish templates whose components are catalog
// SEARCH STRINGS, not food ids. Before fix 1.2 the tier bound each one through the UNSCORED
// `FoodCatalog.results(for:limit:1).first` — the only tier in the five-tier quick-log cascade with no
// quality gate — and `MealResolutionService` then stamped the result `.high` unconditionally, so a
// component that bound to the wrong food auto-committed to the diary with no review sheet. That is
// the "costco cheese pizza slice" bug: the pizza template's `mozzarella cheese` component used to bind
// *Mozzarella sticks, breaded, baked, or fried* at score **58**, against
// `FoodItemSearch.confidentBindScore = 250`, while a correct mozzarella row sat unreached in the same
// catalog.
//
// So this suite replays EVERY component of EVERY template against the shipped
// `FoodCatalog.sqlite` and pins what it binds to and what it scores. Three different things are held
// still here, and they belong to three different fixes:
//
//   • The BIND-QUALITY half (1.1/1.2): the tier binds through `scoredResults`, drops a component
//     whose top hit is below `minimumBindScore`, and derives its confidence from the binds instead of
//     asserting `.high`. `templateConfidenceFollowsItsWeakestBind` and the in-memory fixtures below are
//     the behavioural pins for that.
//
//   • The DATA half (1.3, THIS increment): the pins now record the POST-repair reality — and "repair"
//     happened in TWO passes on the same day. The first pass fixed every pin whose bound row was the
//     WRONG FOOD or NO ROW AT ALL (49 wrongFood + 9 noCatalogRow), collapsing `verdict` to
//     `.defensible` across the board. An ADVERSARIAL REVIEW of that first pass then found a second,
//     narrower defect the `verdict` enum has no word for: a handful of pins were confident and named
//     the right FOOD but the wrong VARIETY or PREPARATION of it — 8 templates' shared rice search bound
//     GLUTINOUS (mochi) rice, not the long-grain rice a person means by "rice" (26% fewer calories per
//     gram); `tomato soup` bound double-strength CONDENSED soup, not the prepared-to-eat row (~1.9×
//     real calories); `burger`/`cheeseburger`'s hamburger-bun search was picked because its SCORE
//     cleared 250, not because it was the food-correct generic row over an equally-plausible neighbor.
//     Repairing those (documented per-pin below, and in `confidentDescriptions`' doc comment) is what
//     this suite now pins — 95 pins (`fried rice` collapsed from 3 components to 1 in the same round;
//     see `burgerNoLongerDropsAnyComponent`; a SECOND adversarial-review pass then gave `vegetable
//     fried rice` its own per-alias override onto its own catalog row instead of sharing the generic
//     bind — see `namedFriedRiceVariantsBindPerVariantOrFallBackHonestly`), all `.defensible` (see
//     `bindFloorPopulationsAreMeasuredNotInherited`). A pin is still not an automatic endorsement of
//     PRECISION — several defensible binds are honest best-efforts pending research item 13's FNDDS
//     import: ramen's noodles/egg, pizza's crust (the SPEC ASKED FOR a baked crust and this bind is raw
//     dough, a genuine miss recorded at its pin, not silently accepted), curry's sauce, nigiri/sushi
//     roll/poke bowl's rice (plain long-grain standing in for short-grain SEASONED sushi rice), and
//     `fried rice`'s `chicken`/`shrimp` variant aliases (no matching catalog row exists for either, so
//     both stay on the generic bind rather than reaching for a wrong one); each pin's surrounding
//     comment names which. A bind that moves WITHOUT a `DishTemplates.json` edit is the regression this
//     suite exists to catch — re-run the dump, paste the new pins, re-decide the verdicts.
//
//   • AUDIT HARDENING (found by the same adversarial review, in TWO passes): everything above
//     discriminates on SEARCH STRINGS only. A mutation to a component's `gramsPerUnit` or a template's
//     `defaultCount` — e.g. burger's beef patty 113 g → 1130 g, a silent ~3200 kcal `.high` commit, or
//     taco's `defaultCount` 2 → 9 — moved nothing this suite would catch; all 20 tests stayed green
//     under both mutations in the review's own reproduction. `templatePortionShapeIsPinned` below
//     closes that gap: it pins `unit` + `defaultCount` + every component's `gramsPerUnit`, in file
//     order, for all 29 templates, independent of which catalog row a search string binds to. A SECOND
//     pass found the shape table's own blind spot: it only looked at BASE components, so mutating
//     `cheeseburger`'s override cheese 21 g → 210 g (the file's only override at the time) still moved
//     nothing — `DishTemplateShapePin.overrideGrams` closes that second axis. Proven non-vacuous both
//     times the same way the review found it: mutate one value, rebuild, confirm the new test goes RED
//     (and ONLY that test), revert, rebuild, confirm green again — recorded in this round's report, not
//     re-run automatically on every CI pass. The failure format was also tightened (a THIRD finding):
//     the original `live == Self.shapePins` whole-array comparison dumped ~6 KB of both 29-element
//     arrays into one failure message; it is now compared per-template-per-field so a failure names
//     the one thing that moved.
//
//   • The COUNT half (1.4): `DishTemplateLexicon.fallbackCount` now treats a bare mention of the
//     template's own unit word ("pizza slice", not "2 pizza slices") as count = 1 instead of the old
//     `defaultCount` guess — closing the silent doubling `theTesterQueryNowRoutesToReviewNamingCostco`
//     measures (120/80/60 g → 60/40/30 g for one slice).
//
//   • The UNMATCHED-BRAND-TOKEN half (1.5, THIS increment): `DishTemplateLexicon.resolve` now names a
//     brand/retailer token the matched template key didn't cover ("costco" out of "cheese pizza"
//     matching only "cheese pizza") as an unmatched item, which forces review a second, independent
//     way. See `theTesterQueryNowRoutesToReviewNamingCostco` and
//     `brandTokenInsideATemplateAliasDoesNotFalsePositive`.
//
//   • 1.5's ADVERSARIAL REVIEW (same day) found and fixed six more findings before the round closed:
//     F1 — a possessive apostrophe ("wendy's") normalized to two tokens and silently missed 12 of 43
//     chain entries; fixed inside `FoodBrandLexicon.matchedChainTokens` only, `queryContainsBrandToken`
//     left byte-unchanged (§37 Q7 stays open). F3 — the chip showed the lexicon's own sentence-cased
//     spelling ("Costco") instead of the user's typed text; now a verbatim slice of the original item
//     name, recovered word-span by word-span. F6 — the MEAL's own persisted confidence stamp was
//     computed before the brand flag folded in, so a meal with a brand chip could still stamp "Food
//     match"; the fold now happens inside `assemble` before the stamp. F9 — the longest-substring
//     tie-break was hash-order nondeterministic, now a deterministic lexicographic tuple compare. F2 —
//     an ordinary food word that collides with a chain's lexicon spelling ("chipotle" the pepper,
//     "chilis" the vegetable) still false-positives; PINNED, not fixed — see
//     `foodWordCollisionWithAChainNameIsPinnedNotFixed` and §37 Q7. F7 — a theoretical double-naming
//     risk (a brand chip AND the same item's whole raw text both landing in `unmatchedItems`) is closed
//     by construction: the brand check is now recorded only on the successful-assembly path.
//
// THE FLOOR IS NOT RELAXED TO MAKE THIS GREEN. `confidentBindScore` stays 250; genuinely weak-but-
// correct binds are still pinned weak and their templates still pinned as not-auto-committing.
// Confidence only rose where a component's search string was repaired to actually name the right food.
//
// WHAT THIS FIX DOES NOT YET KEEP, IN ONE NAMED CASE. Everything the template tier declines lands on
// the candidate-constrained plan in `MealResolutionService.highConfidenceResolution`, which hardcodes
// `.high` exactly as this tier used to — so a fall-through relocates the defect one rung down rather
// than ending it:
//
//   • `burger and fries` (an item this tier knows beside one it does not) still returns nil by
//     design, and the plan tier answers with a Burger King burger plus chili fries at `.high`, with
//     `unmatchedItems == []` — MORE confident and LESS disclosed than the partial this tier would
//     have produced. `deterministicPlan` reports an unmatched item only when NOTHING was produced for
//     it, so the disclosure that makes the narrow boundary defensible does not exist downstream yet.
//
// (`tomato soup`, the other case this paragraph used to name, is now a real, confident, correctly-bound
// single-component resolution FROM THIS TIER as of fix 1.3 — it no longer falls through to the plan
// tier at all, so its half of the old defect is closed, not merely relocated.)
//
// **CLOSED 2026-08-23** by the 1.6/1.7a/1.8 increment, which the note above was waiting on.
// `MealResolutionService` no longer hardcodes `.high` on the plan tier: `bindConfidence(for:candidates:)`
// derives it by scoring each split item's bound food against the WHOLE item name and requiring
// every one to clear `confidentBindScore` with nothing left unmatched. What that does and does not
// close is pinned at `planTierConfidenceNowFollowsItsBinds` and — for the case this note originally
// named — `planTierStillCommitsBurgerAndFriesAtHighConfidence`, which records that `burger and fries`
// still resolves `.high` because both of its binds clear 250 on the +250 substring bonus alone.
//
// COSTCO CHEESE PIZZA SLICE, DIRECT TEMPLATE AUDIT POST-1.5: fix 1.3 alone reopened auto-commit for
// the template result (`.high`, no review) — a genuine improvement over 1.1/1.2's ACCIDENTAL safety
// net (a bad score standing in for brand disclosure), but not an acceptable stopping point on its
// own: the template-only meal (~390 kcal, still pinned below) runs roughly HALF a real Costco
// food-court slice (699–760 kcal, §31), with nothing on screen saying so. The live quick-log end state
// now short-circuits earlier at item 1.12's whole-description probe; this paragraph records the direct
// lexicon seam. Fix 1.5 closes that seam's disclosure gap: `DishTemplateLexicon.resolve`
// now names "costco" as an unmatched brand token whenever the template match's key didn't cover it,
// which forces `needsReview` a second, independent way (`NutritionModels.swift:625`'s
// `!unmatchedItems.isEmpty` clause) on top of the confidence dropping to `.low`
// (`DishTemplateBindQuality.confidence` counts the token as a drop). §31's promise — "costco" appears
// as an unmatched item, flipping `needsReview`" — is now DELIVERED for this exact query, with the
// otherwise-correct three-component decomposition intact. See
// `theTesterQueryNowRoutesToReviewNamingCostco` for the full accounting.
//
// Read-only and self-contained: opens the shipped catalog read-only, writes nothing, shares no
// mutable fixture with any other suite. Re-pin with:
//
//     TEST_RUNNER_DISH_TEMPLATE_BIND_DUMP=1 xcodebuild test-without-building … \
//       -only-testing:FernletTests/DishTemplateBindAuditTests

import Foundation
import Testing
import AIProviders
import FernletDomainModel
import FoodCatalog
@testable import Fernlet

/// Whether a template component's measured bind is the food the template meant.
///
/// Recorded per component so fix 1.3's data repair is a deliberate, reviewable verdict flip rather
/// than a silent re-baseline.
enum DishTemplateBindVerdict: String, Sendable {
    /// The bound row is a defensible stand-in for the component.
    case defensible
    /// The bound row is the wrong food — the template's search string names something the catalog
    /// does not carry under that name, or ranking hands it to a prepared dish (a whole grilled-cheese
    /// sandwich standing in for 42 g of American cheese).
    case wrongFood
    /// The search string matches no catalog row at all: the FTS prefix-AND gate returns nothing, so
    /// the component has contributed nothing to the meal since long before this fix.
    case noCatalogRow
}

/// One dish-template component's measured bind against the shipped catalog: which row it binds to,
/// what that bind scores, and whether the row is the right food.
///
/// Keyed by the DESCRIPTION `DishTemplateLexicon.resolve` is called with, not by template name,
/// because those differ: an alias carrying `componentOverrides` (`cheeseburger`) resolves a
/// different component list from its base template (`burger`), and the override only applies when
/// the alias is the text being resolved. Keying by template name silently folded the override into
/// the base template's verdict, so repairing one and not the other would have reported a failure
/// against the wrong row.
struct DishTemplateBindPin: Equatable, Sendable {
    let description: String
    let query: String
    let boundName: String
    let score: Int
    let verdict: DishTemplateBindVerdict

    init(_ description: String, _ query: String, _ boundName: String, _ score: Int, _ verdict: DishTemplateBindVerdict) {
        self.description = description
        self.query = query
        self.boundName = boundName
        self.score = score
        self.verdict = verdict
    }

    /// Whether this bind clears `FoodItemSearch.confidentBindScore` — the floor at or above which the
    /// template tier is allowed to auto-commit without a review sheet.
    var isConfident: Bool { boundName.isEmpty == false && score >= FoodItemSearch.confidentBindScore }

    /// Whether the FTS gate returns no row at all for this search string.
    var bindsToNothing: Bool { boundName.isEmpty }

    /// Whether fix 1.2's floor drops this component from its meal: either nothing matched, or the
    /// top hit scored below `FoodItemSearch.minimumBindScore` (matched via category/tags only).
    var isDropped: Bool { bindsToNothing || score < FoodItemSearch.minimumBindScore }

    static func == (lhs: DishTemplateBindPin, rhs: DishTemplateBindPin) -> Bool {
        lhs.description == rhs.description && lhs.query == rhs.query
            && lhs.boundName == rhs.boundName && lhs.score == rhs.score
    }
}

struct DishTemplateBindAuditTests {
    /// Row count of the shipped `FoodCatalog.sqlite`, so a missing database fails the suite instead of
    /// letting it pass vacuously (the failure mode §25 names in the two pre-existing catalog tests).
    static let shippedRowCount = 118_317

    /// Every template component, in file order, with its measured bind against the shipped catalog.
    ///
    /// Measured 2026-08-22 on branch `claude/food-search-2026-08-22`. `verdict` is a judgement about
    /// the FOOD, made by reading each bound row against what the template asked for; the name and
    /// score beside it are machine-measured facts. Regenerate the facts with the dump below; the
    /// verdicts are re-decided by hand when fix 1.3 edits a search string.
    static let pins: [DishTemplateBindPin] = [
        DishTemplateBindPin("nigiri", "raw fish raw", "Fish, bluefish, raw", 330, .defensible),
        DishTemplateBindPin("nigiri", "rice white long grain regular enriched cooked", "Rice, white, long-grain, regular, enriched, cooked", 2170, .defensible), // N8: plain long-grain stands in for short-grain SEASONED sushi rice (~140 kcal/100g vs. this row's 124) — no seasoned-sushi-rice row in the shipped catalog; item-13
        DishTemplateBindPin("sashimi", "raw fish raw", "Fish, bluefish, raw", 330, .defensible),
        DishTemplateBindPin("sushi roll", "raw fish raw", "Fish, bluefish, raw", 330, .defensible),
        DishTemplateBindPin("sushi roll", "rice white long grain regular enriched cooked", "Rice, white, long-grain, regular, enriched, cooked", 2170, .defensible), // N8: same sushi-rice stand-in as nigiri's
        DishTemplateBindPin("poke bowl", "raw tuna raw", "Fish, tuna, fresh, bluefin, raw", 329, .defensible),
        DishTemplateBindPin("poke bowl", "rice white long grain regular enriched cooked", "Rice, white, long-grain, regular, enriched, cooked", 2170, .defensible), // N8: same sushi-rice stand-in as nigiri's
        DishTemplateBindPin("poke bowl", "avocado raw", "Avocado, Hass, peeled, raw", 269, .defensible),
        DishTemplateBindPin("poke bowl", "edamame", "Edamame, frozen, prepared", 808, .defensible),
        DishTemplateBindPin("grilled cheese", "bread white commercially prepared includes soft bread crumbs", "Bread, white, commercially prepared (includes soft bread crumbs)", 2230, .defensible),
        DishTemplateBindPin("grilled cheese", "cheese american restaurant", "Cheese, American, restaurant", 1930, .defensible),
        DishTemplateBindPin("grilled cheese", "butter salted", "Butter, salted", 1870, .defensible),
        DishTemplateBindPin("tuna sandwich", "bread white commercially prepared includes soft bread crumbs", "Bread, white, commercially prepared (includes soft bread crumbs)", 2230, .defensible),
        DishTemplateBindPin("tuna sandwich", "canned tuna canned water", "Fish, tuna, light, canned in water, drained solids", 388, .defensible),
        DishTemplateBindPin("tuna sandwich", "salad dressing mayonnaise regular", "Salad dressing, mayonnaise, regular", 1990, .defensible),
        DishTemplateBindPin("tuna melt", "bread white commercially prepared includes soft bread crumbs", "Bread, white, commercially prepared (includes soft bread crumbs)", 2230, .defensible),
        DishTemplateBindPin("tuna melt", "canned tuna canned water", "Fish, tuna, light, canned in water, drained solids", 388, .defensible),
        DishTemplateBindPin("tuna melt", "cheese cheddar", "Cheese, cheddar", 1870, .defensible),
        DishTemplateBindPin("tuna melt", "salad dressing mayonnaise regular", "Salad dressing, mayonnaise, regular", 1990, .defensible),
        DishTemplateBindPin("BLT", "bread white commercially prepared includes soft bread crumbs", "Bread, white, commercially prepared (includes soft bread crumbs)", 2230, .defensible),
        DishTemplateBindPin("BLT", "pork cured bacon cooked baked", "Pork, cured, bacon, cooked, baked", 2200, .defensible),
        DishTemplateBindPin("BLT", "lettuce iceberg raw", "Lettuce, iceberg, raw", 2080, .defensible),
        DishTemplateBindPin("BLT", "tomatoes red ripe raw", "Tomatoes, red, ripe, raw, year round average", 1138, .defensible),
        DishTemplateBindPin("BLT", "salad dressing mayonnaise regular", "Salad dressing, mayonnaise, regular", 1990, .defensible),
        DishTemplateBindPin("burger", "beef ground 80 lean meat 20 fat patty cooked broiled", "Beef, ground, 80% lean meat / 20% fat, patty, cooked, broiled", 2350, .defensible),
        DishTemplateBindPin("burger", "rolls hamburger or hotdog plain", "Rolls, hamburger or hotdog, plain", 2050, .defensible),
        DishTemplateBindPin("burger", "lettuce iceberg raw", "Lettuce, iceberg, raw", 2080, .defensible),
        DishTemplateBindPin("burger", "tomatoes red ripe raw", "Tomatoes, red, ripe, raw, year round average", 1138, .defensible),
        DishTemplateBindPin("cheeseburger", "beef ground 80 lean meat 20 fat patty cooked broiled", "Beef, ground, 80% lean meat / 20% fat, patty, cooked, broiled", 2350, .defensible),
        DishTemplateBindPin("cheeseburger", "rolls hamburger or hotdog plain", "Rolls, hamburger or hotdog, plain", 2050, .defensible),
        DishTemplateBindPin("cheeseburger", "lettuce iceberg raw", "Lettuce, iceberg, raw", 2080, .defensible),
        DishTemplateBindPin("cheeseburger", "tomatoes red ripe raw", "Tomatoes, red, ripe, raw, year round average", 1138, .defensible),
        DishTemplateBindPin("cheeseburger", "cheese american restaurant", "Cheese, American, restaurant", 1930, .defensible),
        DishTemplateBindPin("burrito", "tortillas ready to bake or fry flour", "Tortillas, ready-to-bake or -fry, flour, refrigerated", 1169, .defensible), // N3: ties with the "...shelf stable" row at the same score; "refrigerated" wins alphabetically — calorically identical, so the tie is inert
        DishTemplateBindPin("burrito", "grilled chicken breast grilled", "Chicken, broiler or fryers, breast, skinless, boneless, meat only, cooked, grilled", 385, .defensible),
        DishTemplateBindPin("burrito", "rice white long grain regular enriched cooked", "Rice, white, long-grain, regular, enriched, cooked", 2170, .defensible),
        DishTemplateBindPin("burrito", "beans black cooked", "Beans, black, mature seeds, cooked, boiled, with salt", 177, .defensible),
        DishTemplateBindPin("burrito", "cheese cheddar", "Cheese, cheddar", 1870, .defensible),
        DishTemplateBindPin("burrito bowl", "grilled chicken breast grilled", "Chicken, broiler or fryers, breast, skinless, boneless, meat only, cooked, grilled", 385, .defensible),
        DishTemplateBindPin("burrito bowl", "rice white long grain regular enriched cooked", "Rice, white, long-grain, regular, enriched, cooked", 2170, .defensible),
        DishTemplateBindPin("burrito bowl", "beans black cooked", "Beans, black, mature seeds, cooked, boiled, with salt", 177, .defensible),
        DishTemplateBindPin("burrito bowl", "cheese cheddar", "Cheese, cheddar", 1870, .defensible),
        DishTemplateBindPin("taco", "cooked beef ground cooked", "Beef, ground, 93% lean meat / 7% fat, loaf, cooked, baked", 238, .defensible),
        DishTemplateBindPin("taco", "tortilla corn", "Tortilla, blue corn, Sakwavikaviki (Hopi)", 117, .defensible),
        DishTemplateBindPin("taco", "cheese cheddar", "Cheese, cheddar", 1870, .defensible),
        DishTemplateBindPin("taco", "lettuce iceberg raw", "Lettuce, iceberg, raw", 2080, .defensible),
        DishTemplateBindPin("quesadilla", "tortillas ready to bake or fry flour", "Tortillas, ready-to-bake or -fry, flour, refrigerated", 1169, .defensible), // N3: ties with the "...shelf stable" row at the same score; "refrigerated" wins alphabetically — calorically identical, so the tie is inert
        DishTemplateBindPin("quesadilla", "cheese cheddar", "Cheese, cheddar", 1870, .defensible),
        DishTemplateBindPin("quesadilla", "grilled chicken breast grilled", "Chicken, broiler or fryers, breast, skinless, boneless, meat only, cooked, grilled", 385, .defensible),
        DishTemplateBindPin("stir fry", "chicken breast cooked roasted", "Chicken, broilers or fryers, breast, meat only, cooked, roasted", 387, .defensible),
        DishTemplateBindPin("stir fry", "broccoli cooked", "Broccoli, cooked, boiled, drained, with salt", 867, .defensible),
        DishTemplateBindPin("stir fry", "rice white long grain regular enriched cooked", "Rice, white, long-grain, regular, enriched, cooked", 2170, .defensible),
        DishTemplateBindPin("fried rice", "rice fried", "Rice, fried, NFS", 1020, .defensible),
        DishTemplateBindPin("vegetable fried rice", "rice fried meatless", "Rice, fried, meatless", 2080, .defensible), // N5: per-alias override REPLACES the generic component — chicken/shrimp variants have no catalog row and stay on "Rice, fried, NFS" (item-13 dependency)
        DishTemplateBindPin("pad thai", "rice noodle cooked", "Rice noodles, cooked", 120, .defensible),
        DishTemplateBindPin("pad thai", "egg whole raw", "Egg, whole, raw, fresh", 1080, .defensible),
        DishTemplateBindPin("pad thai", "cooked shrimp cooked", "Cooked Shrimp", 180, .defensible),
        DishTemplateBindPin("pad thai", "dry roasted peanuts", "Peanuts, all types, dry-roasted, with salt", 328, .defensible),
        DishTemplateBindPin("bibimbap", "rice white long grain regular enriched cooked", "Rice, white, long-grain, regular, enriched, cooked", 2170, .defensible),
        DishTemplateBindPin("bibimbap", "cooked beef sirloin cooked", "Beef, top sirloin, steak, separable lean only, trimmed to 0\" fat, choice, cooked, broiled", 234, .defensible),
        DishTemplateBindPin("bibimbap", "fried egg whole cooked", "Egg, whole, cooked, fried", 390, .defensible),
        DishTemplateBindPin("bibimbap", "spinach cooked", "Spinach, cooked, boiled, drained, with salt", 867, .defensible),
        DishTemplateBindPin("pho", "rice noodle cooked", "Rice noodles, cooked", 120, .defensible),
        DishTemplateBindPin("pho", "raw beef round raw", "Beef, round, top round, boneless, choice, raw", 388, .defensible),
        DishTemplateBindPin("pho", "broth beef ready to serve", "Soup, beef broth or bouillon canned, ready-to-serve", 297, .defensible),
        DishTemplateBindPin("ramen", "egg noodles cooked", "Noodles, egg, enriched, cooked", 179, .defensible),
        DishTemplateBindPin("ramen", "cooked pork belly cooked", "Fully Cooked Pork Belly", 240, .defensible),
        DishTemplateBindPin("ramen", "egg whole cooked hard boiled", "Egg, whole, cooked, hard-boiled", 2050, .defensible),
        DishTemplateBindPin("ramen", "broth chicken ready to serve", "Soup, chicken broth, ready-to-serve", 300, .defensible),
        DishTemplateBindPin("avocado toast", "bread whole grain", "Bread, multi-grain (includes whole-grain)", 178, .defensible),
        DishTemplateBindPin("avocado toast", "avocado raw", "Avocado, Hass, peeled, raw", 269, .defensible),
        DishTemplateBindPin("spaghetti bolognese", "pasta cooked enriched", "Pasta, cooked, enriched, with added salt", 928, .defensible),
        DishTemplateBindPin("spaghetti bolognese", "cooked beef ground cooked", "Beef, ground, 93% lean meat / 7% fat, loaf, cooked, baked", 238, .defensible),
        DishTemplateBindPin("spaghetti bolognese", "tomato sauce", "Tomato sauce, canned, no salt added", 868, .defensible),
        DishTemplateBindPin("caesar salad", "romaine lettuce raw", "Lettuce, cos or romaine, raw", 330, .defensible),
        DishTemplateBindPin("caesar salad", "grilled chicken breast grilled", "Chicken, broiler or fryers, breast, skinless, boneless, meat only, cooked, grilled", 385, .defensible),
        DishTemplateBindPin("caesar salad", "caesar dressing regular", "Salad dressing, caesar dressing, regular", 429, .defensible),
        DishTemplateBindPin("caesar salad", "cheese parmesan grated", "Cheese, parmesan, grated", 1930, .defensible),
        DishTemplateBindPin("pizza", "pizza dough", "Pizza Dough", 1870, .defensible), // spec target MISSED: §26 asked for a BAKED crust; raw dough is the honest best bind — see the file header's item-13 note
        DishTemplateBindPin("pizza", "low moisture part skim mozzarella cheese", "Cheese, mozzarella, low moisture, part-skim", 360, .defensible),
        DishTemplateBindPin("pizza", "tomato sauce", "Tomato sauce, canned, no salt added", 868, .defensible),
        DishTemplateBindPin("shawarma", "chicken thigh cooked roasted", "Chicken, broilers or fryers, thigh, meat only, cooked, roasted", 387, .defensible),
        DishTemplateBindPin("shawarma", "pita bread", "Bread, pita, whole-wheat", 119, .defensible),
        DishTemplateBindPin("shawarma", "tomatoes red ripe raw", "Tomatoes, red, ripe, raw, year round average", 1138, .defensible),
        DishTemplateBindPin("curry", "chicken breast cooked roasted", "Chicken, broilers or fryers, breast, meat only, cooked, roasted", 387, .defensible),
        DishTemplateBindPin("curry", "coconut milk canned", "Nuts, coconut milk, canned (liquid expressed from grated meat and water)", 574, .defensible),
        DishTemplateBindPin("curry", "rice white long grain regular enriched cooked", "Rice, white, long-grain, regular, enriched, cooked", 2170, .defensible),
        // 1379 → 1319: fix 1.6 strips the function word "with", which costs this bind one +60 token
        // hit. The +500/+250 phrase bonuses are INTACT because `phraseScore` scores the typed phrase
        // as well as the stripped one and keeps the better — without that, this component lost 750
        // points and was handed to a *bisque* row on a name tie-break.
        DishTemplateBindPin("tomato soup", "soup tomato canned prepared with equal volume water", "Soup, tomato, canned, prepared with equal volume water, commercial", 1319, .defensible),
        DishTemplateBindPin("chicken noodle soup", "chicken breast meat only cooked stewed", "Chicken, broilers or fryers, breast, meat only, cooked, stewed", 358, .defensible),
        // REPAIRED IN THE DATA. `pasta noodle cooked` named a food the catalog does not have under
        // that name, and §26 fix 1.8's floor turned that latent defect into a visible one: the string
        // had been reaching *Pasta, cooked* through the category/tags, with no "noodle" in the name
        // at all. The fix is the one `ramen` already uses for the same ingredient, so the two dishes
        // now bind their noodles identically instead of one of them guessing.
        DishTemplateBindPin("chicken noodle soup", "egg noodles cooked", "Noodles, egg, enriched, cooked", 179, .defensible),
        DishTemplateBindPin("chicken noodle soup", "broth chicken ready to serve", "Soup, chicken broth, ready-to-serve", 300, .defensible),
        DishTemplateBindPin("oatmeal", "oatmeal", "Oatmeal, NFS", 810, .defensible),
        DishTemplateBindPin("smoothie", "banana", "Bananas, raw", 750, .defensible),
        DishTemplateBindPin("smoothie", "milk whole", "Milk, whole, 3.25% milkfat, with added vitamin D", 866, .defensible),
        DishTemplateBindPin("smoothie", "protein powder whey", "Beverages, Protein powder whey based", 428, .defensible),
    ]

    /// Every description this audit resolves: each template's own name, plus every alias that carries
    /// `componentOverrides` (only `cheeseburger` today). In `pins` order, deduplicated.
    static var auditedDescriptions: [String] {
        var seen: Set<String> = []
        return pins.map(\.description).filter { seen.insert($0).inserted }
    }

    /// The descriptions whose every component clears `confidentBindScore` — the set allowed to
    /// resolve at `.high` and auto-commit. Derived from `pins`, asserted live.
    ///
    /// **It is twenty of the thirty-one, up from two before fix 1.3.** Fix 1.1/1.2 (the prior
    /// increment) only changed how a bad bind is HANDLED — it never made a wrong bind right, so only
    /// `sashimi` and `smoothie` (already-clean templates) auto-committed. Fix 1.3's FIRST pass repaired
    /// the wrongFood/noCatalogRow binds to defensible food — including `pizza`, the round's origin
    /// story, whose mozzarella and crust components no longer bind to a mozzarella-sticks snack and a
    /// Pillsbury dough product — which brought 12 more into the confident set. An ADVERSARIAL REVIEW
    /// pass on that first draft (2026-08-22, same day) then found five defensible-but-not-food-correct
    /// binds masquerading as fine — `nigiri`/`sushi roll`/`poke bowl`/`burrito`/`burrito
    /// bowl`/`stir fry`/`bibimbap`/`curry`'s shared rice search bound the GLUTINOUS (mochi) variety, a
    /// distinct food scoring 26% fewer calories per gram than the plain long-grain rice a person means
    /// by "rice"; `burger`/`cheeseburger`'s bun bind was picked because the SCORE happened to clear 250,
    /// not because it was the right generic row; `tomato soup` bound the double-strength CONDENSED
    /// product (committing ~1.9× real calories) instead of the prepared-to-eat one — repairing those
    /// (without loosening the floor) newly cleared `nigiri`, `sushi roll`, `poke bowl`, `stir fry` and
    /// `curry` (whose only weak link was the rice bind); `burrito`/`burrito bowl`/`bibimbap` stayed
    /// short of confident because THEIR remaining weak component (`beans black cooked` / `cooked beef
    /// sirloin cooked`) was never a rice problem. A SECOND adversarial-review pass then found `fried
    /// rice`'s named variants (`chicken fried rice`, `shrimp fried rice`, `vegetable fried rice`) all
    /// silently sharing the generic bind with no distinction — `vegetable fried rice` got its own
    /// per-alias override onto *Rice, fried, meatless* (confident, `replacesBaseComponents: true` so it
    /// REPLACES rather than adds to the generic component), which is the twentieth confident
    /// description; `chicken`/`shrimp fried rice` have no catalog row of their own and stay on the
    /// generic bind honestly (item-13 dependency), so they are not separately audited descriptions.
    ///
    /// Every remaining pin is a genuinely correct food that simply does not clear the 250 floor (a
    /// generic SR-Legacy row like "Tortilla, blue corn, Sakwavikaviki (Hopi)" scores low on relevance
    /// even though it is the right food) — see `bindFloorPopulationsAreMeasuredNotInherited`, where the
    /// wrongFood/noCatalogRow verdict populations both fall to zero.
    static var confidentDescriptions: Set<String> {
        let unconfident = Set(pins.filter { !$0.isConfident }.map(\.description))
        return Set(pins.map(\.description)).subtracting(unconfident)
    }

    /// The descriptions that resolve to nothing at all: every component is dropped (or matches no
    /// catalog row at all), so the tier returns nil and the cascade falls to its next rung.
    ///
    /// **Empty as of fix 1.3.** Before it, `tomato soup`'s single component bound *Pork with chili and
    /// tomatoes* at **−2** (below `minimumBindScore`) and `oatmeal`'s search string matched no row at
    /// all; both are now real, correctly-bound, CONFIDENT single-component templates (`tomato soup` →
    /// *Soup, tomato, canned, prepared with equal volume water, commercial* at 1379 — the PREPARED row,
    /// not the double-strength condensed one an adversarial review caught; `oatmeal` → *Oatmeal, NFS*
    /// at 810). The property is kept — and still measured live, not hardcoded — because a future edit
    /// to `DishTemplates.json` could reintroduce a fully-unbindable template, and this is the test that
    /// would catch it.
    static var fallThroughDescriptions: Set<String> {
        let byDescription = Dictionary(grouping: pins, by: \.description)
        return Set(byDescription.filter { _, pins in pins.allSatisfy(\.isDropped) }.keys)
    }

    // MARK: - The audit

    /// The pinned component list must be exactly the components the shipped JSON declares.
    ///
    /// This is what makes the audit an audit: adding, removing or re-wording a component in
    /// `DishTemplates.json` without re-pinning fails here, so fix 1.3 cannot land unmeasured.
    @Test func everyTemplateComponentIsPinned() throws {
        let live = Self.liveComponents()
        #expect(DishTemplateLexicon.allTemplates.count == 29, "DishTemplates.json is pinned at 29 templates")
        #expect(Self.auditedDescriptions.count == 31, "29 template names plus the two override aliases (cheeseburger, vegetable fried rice)")
        #expect(live.count == Self.pins.count, "component count moved: \(live.count) declared, \(Self.pins.count) pinned")
        for (index, component) in live.enumerated() where index < Self.pins.count {
            #expect(Self.pins[index].description == component.description, "resolved description moved at index \(index)")
            #expect(Self.pins[index].query == component.query, "component query moved at index \(index)")
        }
    }

    /// Every pinned bind still replays to the same row and the same score against the shipped catalog.
    @Test func everyPinnedBindReplaysToTheShippedCatalog() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded — this suite must never pass vacuously")
        for pin in Self.pins {
            let top = catalog.scoredResults(for: pin.query, limit: 1).first
            let name = top?.item.name ?? ""
            let score = top?.score ?? 0
            #expect(name == pin.boundName, "bind moved for \(pin.description) / \"\(pin.query)\"")
            #expect(score == pin.score, "bind score moved for \(pin.description) / \"\(pin.query)\"")
        }
    }

    /// The bind-floor populations, derived from the pins rather than restated as literals.
    ///
    /// Measured 2026-08-22 on branch `claude/food-search-2026-08-22`, AFTER fix 1.3's first data repair
    /// AND two same-day adversarial-review rounds (round one: rice, hamburger bun, tomato soup,
    /// tortilla, bread, beef patty, fried rice collapsed to USDA's own single-ingredient decomposition;
    /// round two: `vegetable fried rice` given its own per-alias override onto *Rice, fried, meatless* —
    /// see the file header), over the 95 component binds of the 31 audited descriptions (94 after round
    /// one; 96 before round one dropped fried rice from 3 components to 1), and RE-measured after
    /// §26 fixes 1.6/1.7a/1.8 and their adversarial review: **zero match no catalog row, zero bind
    /// below `minimumBindScore`, 14 bind weakly (1–249, but to the RIGHT food), and 81 bind
    /// confidently (≥ 250)** — the same populations as before the increment. Fix 1.8's floor exposed
    /// one latent data defect on the way (`chicken noodle soup`'s noodle component had been reaching
    /// its row through the category, with no "noodle" in the name); that string was repaired in
    /// `DishTemplates.json` rather than the floor being weakened.
    @Test func bindFloorPopulationsAreMeasuredNotInherited() throws {
        let noRow = Self.pins.filter(\.bindsToNothing)
        let dropped = Self.pins.filter { !$0.bindsToNothing && $0.score < FoodItemSearch.minimumBindScore }
        let weak = Self.pins.filter { !$0.isDropped && !$0.isConfident }
        let confident = Self.pins.filter(\.isConfident)
        #expect(Self.pins.count == 95, "95 component binds across the 31 audited descriptions")
        #expect(noRow.count == 0, "search strings that match nothing: \(noRow.map(\.query))")
        #expect(dropped.count == 0, "binds below the drop floor: \(dropped.map(\.query))")
        #expect(weak.count == 14)
        #expect(confident.count == 81)
        #expect(noRow.count + dropped.count + weak.count + confident.count == Self.pins.count)

        // The verdicts, likewise derived. Fix 1.3's whole job was to repair every wrongFood/noCatalogRow
        // bind into a defensible one — so both populations are now zero and every pin reads defensible.
        #expect(Self.pins.filter { $0.verdict == .wrongFood }.count == 0)
        #expect(Self.pins.filter { $0.verdict == .defensible }.count == 95)
        #expect(Self.pins.filter { $0.verdict == .noCatalogRow }.count == noRow.count)

        // The ten confident-but-wrong binds a score floor structurally could not catch (avocado→sushi
        // roll, butter/peanut→PB&J, cheddar→smoked sausage, grilled chicken→McDonald's salad ×3,
        // parmesan→fat-free topping, tomato cream sauce→ravioli) are gone: fix 1.3 repaired every one of
        // their search strings, so no bind is both confident AND wrong any more. The adversarial review
        // round then found — and fixed — a SECOND category the verdict enum has no word for: confident,
        // food-correct-ISH, but the WRONG VARIETY or WRONG PREPARATION of that food (glutinous vs.
        // long-grain rice; condensed vs. prepared soup) — `verdict` only ever asked "right food?", not
        // "right food AND right form?", which is why these survived the first pass's own review.
        let confidentlyWrong = Self.pins.filter { $0.verdict == .wrongFood && $0.isConfident }
        #expect(confidentlyWrong.count == 0, "confident-but-wrong binds: \(confidentlyWrong.map(\.query))")
        #expect(Self.confidentDescriptions == [
            "nigiri", "sashimi", "sushi roll", "poke bowl", "grilled cheese", "tuna sandwich", "tuna melt",
            "BLT", "burger", "cheeseburger", "quesadilla", "stir fry", "fried rice", "vegetable fried rice",
            "caesar salad", "pizza", "curry", "tomato soup", "oatmeal", "smoothie"
        ], "twenty descriptions now bind cleanly enough to auto-commit")
    }

    /// The behavioural pin for fix 1.1: a description resolves `.high` if and only if every component
    /// `resolve` binds for it cleared the floor and its declared units have source-backed conversions.
    /// An unsupported household measure must fall through instead of inheriting an unsafe scale.
    @Test func templateConfidenceFollowsItsWeakestBind() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        #expect(Self.fallThroughDescriptions == [], "fix 1.3 leaves no description without a bindable component")
        let rejected = Set(Self.auditedDescriptions.filter {
            DishTemplateLexicon.resolve(description: $0, mealType: nil, catalog: catalog) == nil
        })
        #expect(rejected == ["ramen"], "unsupported household units must fall through: \(rejected)")
        for description in Self.auditedDescriptions {
            let resolved = DishTemplateLexicon.resolve(description: description, mealType: nil, catalog: catalog)
            guard rejected.contains(description) == false else {
                #expect(resolved == nil, "\(description) has no safe conversion — the tier must fall through")
                continue
            }
            guard let resolved else {
                Issue.record("\(description) no longer resolves through its own name")
                continue
            }
            let expected: MealResolutionConfidence = Self.confidentDescriptions.contains(description) ? .high : .low
            #expect(resolved.confidence == expected, "confidence for \(description)")
        }
    }

    /// What fix 1.1 actually MOVED, separated from what was already being caught — replayed against
    /// TODAY's (post-1.3/1.4) component binds and grams, so this measures what remains true now rather
    /// than restating a historical snapshot that would silently drift as the data changed underneath it.
    ///
    /// The pre-existing 4,000-kcal plausibility gate (`MealResolutionService.plausibilityGated`)
    /// already downgraded some template resolutions to `.low` while the tier was still asserting
    /// `.high` — so "11 of the 31 non-confident descriptions newly pause at review" would have
    /// over-claimed fix 1.1's effect. This replays the PRE-fix path (hardcoded `.high` → merge → gate)
    /// for every safely buildable audited description and pins the split. `ramen` now falls through
    /// before this historical comparison: its unsupported bowl measure has no source-backed conversion.
    @MainActor
    @Test func preFixReviewRoutingIsAttributedCorrectly() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        var alreadyReviewed: [String] = []
        var newlyReviewed: [String] = []
        for description in Self.auditedDescriptions {
            guard let resolved = DishTemplateLexicon.resolve(description: description, mealType: nil, catalog: catalog) else { continue }
            guard resolved.confidence != .high else { continue }
            // The pre-fix resolution: the same meals, stamped `.high` unconditionally, with no
            // unmatched items — then merged and passed through the calorie gate exactly as before.
            let preFix = MealResolutionService.plausibilityGated(
                MealResolutionService.mergedIntoSingleMeal(
                    MealResolution(meals: resolved.meals, createdRecipes: [], confidence: .high, isFallback: false),
                    description: description
                )
            )
            if preFix.needsReview { alreadyReviewed.append(description) } else { newlyReviewed.append(description) }
        }
        #expect(alreadyReviewed.isEmpty,
                "no safely buildable description was already caught by the old calorie gate: \(alreadyReviewed.sorted())")
        #expect(newlyReviewed.count == 10, "newly routed to review by fix 1.1: \(newlyReviewed.sorted())")
        #expect(Self.confidentDescriptions.count == 20)
        #expect(Self.fallThroughDescriptions.count == 0)
    }

    /// Fix 1.3's flip, observed end to end on the shipped catalog: the BLT template's five components
    /// used to drop two (`lettuce` → *Broccoli slaw salad* at −1, `mayonnaise` → *Salad dressing, NFS,
    /// for sandwiches* at −2, both tag-only matches). Every one of those search strings was repaired —
    /// `lettuce` → `lettuce iceberg raw`, `mayonnaise` → `salad dressing mayonnaise regular` — so the
    /// BLT now keeps all five, confidently, with nothing to name in `unmatchedItems`.
    @Test func previouslySubFloorBLTComponentsNowBindConfidently() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        let resolved = try #require(DishTemplateLexicon.resolve(description: "BLT", mealType: nil, catalog: catalog))
        let names = resolved.meals.first?.componentSnapshots.map(\.name) ?? []
        #expect(names.count == 5, "fix 1.3 repairs every BLT component — nothing drops any more: \(names)")
        #expect(names.contains("Broccoli slaw salad") == false)
        #expect(resolved.confidence == .high, "all five components clear the confident floor")
        #expect(resolved.unmatchedItems.isEmpty, "nothing was dropped, so there is nothing to name")
    }

    /// The same flip for `burger` — it used to drop a component (`burger`'s patty had no catalog row at
    /// all and its lettuce matched on tags only). Fix 1.3's search-string repairs (`beef ground 80 lean
    /// meat 20 fat patty cooked broiled` — reworded again in the adversarial-review round to reach the
    /// standard 80/20 blend rather than a three-way alphabetical tie; `lettuce iceberg raw`) close every
    /// gap on the real shipped data.
    ///
    /// `fried rice` is no longer part of this test: the adversarial review found the ORIGINAL three-
    /// component decomposition double-counted — "Rice, fried, NFS" is already a COMPLETE dish (it
    /// already contains egg and oil in its own composition), so adding 50 g of raw egg and 15 g of soy
    /// sauce on top over-stated the meal. `fried rice` is now `isComposite: false`, ONE component
    /// (`rice fried`, 198 g — USDA's own "1 cup" portion for this exact row), matching research §27's
    /// "USDA's own decomposition of a restaurant dish is often a single ingredient" finding (already
    /// true for `pizza`'s eventual FNDDS answer, and applied here today because the shipped catalog
    /// already carries the single-row dish). See ``templatePortionShapeIsPinned`` for the shape pin.
    @Test func burgerNoLongerDropsAnyComponent() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        let burger = try #require(DishTemplateLexicon.resolve(description: "burger", mealType: nil, catalog: catalog))
        #expect(burger.unmatchedItems.isEmpty)
        #expect(burger.meals.first?.componentSnapshots.count == 4)
        #expect(burger.confidence == .high)

        let friedRice = try #require(DishTemplateLexicon.resolve(description: "fried rice", mealType: nil, catalog: catalog))
        #expect(friedRice.unmatchedItems.isEmpty)
        #expect(friedRice.meals.first?.componentSnapshots.count == 1, "collapsed to USDA's own single-ingredient decomposition")
        #expect(friedRice.meals.first?.componentSnapshots.first?.name == "Rice, fried, NFS")
        #expect(friedRice.confidence == .high)

        let resolution = MealResolution(
            meals: burger.meals, createdRecipes: [], confidence: burger.confidence,
            isFallback: false, unmatchedItems: burger.unmatchedItems
        )
        #expect(resolution.needsReview == false, "a fully-bound, confident template no longer pauses")
    }

    /// An adversarial review found the fried-rice collapse made a pre-existing gap starker: all three
    /// named variant aliases (`chicken fried rice`, `shrimp fried rice`, `vegetable fried rice`) shared
    /// the same generic `Rice, fried, NFS` bind with nothing to distinguish them, even though the
    /// shipped catalog carries a real per-variant row for one of them. Checked against the shipped
    /// catalog: `Rice, fried, meatless` exists (survey); no `Rice, fried, with chicken` or `...,
    /// with shrimp` row exists (only `Rice, fried, with beef`, which no current alias names).
    @Test func namedFriedRiceVariantsBindPerVariantOrFallBackHonestly() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")

        // "vegetable fried rice" has its own catalog row — the per-alias override REPLACES the generic
        // component (not adds to it), so the meal is one confident component, not a double count.
        let vegetable = try #require(DishTemplateLexicon.resolve(description: "vegetable fried rice", mealType: nil, catalog: catalog))
        #expect(vegetable.meals.first?.componentSnapshots.count == 1, "the override REPLACES the generic component, not adds to it")
        #expect(vegetable.meals.first?.componentSnapshots.first?.name == "Rice, fried, meatless")
        #expect(vegetable.confidence == .high)

        // "chicken fried rice" and "shrimp fried rice" have NO matching catalog row of their own (see
        // the file header's item-13 list) and are deliberately left on the generic bind — an honest
        // fallback, not a contorted or wrong one.
        for description in ["chicken fried rice", "shrimp fried rice"] {
            let resolved = try #require(DishTemplateLexicon.resolve(description: description, mealType: nil, catalog: catalog))
            #expect(resolved.meals.first?.componentSnapshots.first?.name == "Rice, fried, NFS",
                     "\(description) has no catalog row of its own — the generic bind is the honest answer")
            #expect(resolved.confidence == .high)
        }
    }

    /// A dropped component is still never silent — that MECHANISM (fix 1.2) is unchanged by fix 1.3,
    /// even though no real shipped template exercises it any more (see the two tests above). Replayed
    /// on a synthetic fixture, and it also pins the fix-1.3 `displayName` threading: taco's lettuce
    /// component declares `"displayName": "Lettuce"` in `DishTemplates.json`, which is what the review
    /// sheet must show — NOT the query-derived sentence-case fallback ("Lettuce iceberg raw") that
    /// would render if `displayName` were silently dropped along the way.
    @Test func droppedComponentDisplayNameComesFromTheJSONField() throws {
        var items = Self.tacoComponents()
        items.removeAll { $0.name == "Lettuce iceberg raw" }
        items.append(Self.food(name: "Wrap", tags: ["lettuce", "iceberg", "raw"]))
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource(items))
        let resolved = try #require(DishTemplateLexicon.resolve(description: "taco", mealType: nil, catalog: catalog))
        #expect(resolved.confidence == .low)
        #expect(resolved.unmatchedItems == ["Lettuce"], "the JSON displayName, not the derived query text")

        let resolution = MealResolution(
            meals: resolved.meals, createdRecipes: [], confidence: resolved.confidence,
            isFallback: false, unmatchedItems: resolved.unmatchedItems
        )
        #expect(resolution.needsReview)
    }

    /// Both halves of "smoothie and tomato soup" now build — fix 1.3's headline for `tomato soup`.
    ///
    /// Before this fix `tomato soup`'s only component bound *Pork with chili and tomatoes* at **−2**
    /// (below the drop floor), so the whole item failed to build: the smoothie survived alone, the soup
    /// was named in `unmatchedItems`, and the pair paused for review. `tomato soup` → `soup tomato
    /// canned prepared with equal volume water` now binds *Soup, tomato, canned, prepared with equal
    /// volume water, commercial* at **1379**, confidently — the PREPARED-to-eat row, not the double-
    /// strength CONDENSED one the first draft of this fix bound (an adversarial review caught it: the
    /// condensed row is ~68 kcal/100 g against the prepared row's ~36, so the original bind committed
    /// roughly 1.9× real calories at `.high`) — so both dishes build, both are confident, and nothing is
    /// unmatched.
    @Test func multiItemDescriptionNowBuildsBothDishesConfidently() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        let resolved = try #require(DishTemplateLexicon.resolve(
            description: "smoothie and tomato soup",
            mealType: nil,
            catalog: catalog
        ))
        #expect(resolved.meals.count == 2, "one meal per buildable item — now both build")
        #expect(resolved.meals.map { $0.componentSnapshots.count } == [3, 1])
        #expect(resolved.unmatchedItems.isEmpty, "nothing failed to build any more")
        #expect(resolved.confidence == .high, "every bound component in both dishes is confident")

        let resolution = MealResolution(
            meals: resolved.meals, createdRecipes: [], confidence: resolved.confidence,
            isFallback: false, unmatchedItems: resolved.unmatchedItems
        )
        #expect(resolution.needsReview == false)
    }

    /// The invariant `multiItemDescriptionNowBuildsBothDishesConfidently` used to demonstrate on real
    /// data — one dish in a multi-item description fails to build at all, and its sibling survives —
    /// still holds in the CODE (`resolve`'s per-item loop records an unresolved item and `continue`s
    /// rather than aborting). It just has no real shipped pairing left to demonstrate it on, since fix
    /// 1.3 leaves no fully-unbuildable template. Replayed on a synthetic fixture: "smoothie and sashimi"
    /// against a catalog that carries the smoothie's three exact matches and nothing that binds
    /// `sashimi`'s one component at all.
    @Test func oneUnbuildableDishStillDoesNotDestroyItsSiblings() throws {
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource(Self.smoothieComponents()))
        let resolved = try #require(DishTemplateLexicon.resolve(
            description: "smoothie and sashimi",
            mealType: nil,
            catalog: catalog
        ), "the good half must survive")
        #expect(resolved.meals.count == 1, "one meal per buildable item")
        #expect(resolved.meals.first?.componentSnapshots.count == 3, "the smoothie's three components are intact")
        #expect(resolved.unmatchedItems == ["sashimi"], "the failed item is surfaced verbatim")
        #expect(resolved.confidence == .low, "an item we could not build is a drop, and a drop is never high")

        let resolution = MealResolution(
            meals: resolved.meals, createdRecipes: [], confidence: resolved.confidence,
            isFallback: false, unmatchedItems: resolved.unmatchedItems
        )
        #expect(resolution.needsReview)
    }

    /// Two dishes that drop the SAME component name it once.
    ///
    /// "burger and BLT" both used to lose their lettuce on the real shipped catalog; fix 1.3 repaired
    /// that bind, so both templates now keep it (see `previouslySubFloorBLTComponentsNowBindConfidently`
    /// / `burgerNoLongerDropsAnyComponent`). The dedup invariant this test pins — the review
    /// sheet renders `unmatchedItems` with `ForEach(id: \.self)`, where a duplicate element is undefined
    /// behaviour in SwiftUI, and "Lettuce, Lettuce" would be absurd copy even if it rendered — is
    /// replayed on a synthetic catalog that carries every OTHER component of both templates but nothing
    /// matching `lettuce iceberg raw`, so both genuinely drop the same named ingredient once each.
    @Test func repeatedDropsAreNamedOnce() throws {
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource(Self.burgerAndBLTComponentsWithoutLettuce()))
        let resolved = try #require(DishTemplateLexicon.resolve(description: "burger and BLT", mealType: nil, catalog: catalog))
        #expect(resolved.meals.count == 2)
        #expect(resolved.unmatchedItems == ["Lettuce"])
        #expect(Set(resolved.unmatchedItems).count == resolved.unmatchedItems.count, "no duplicate ForEach id")
    }

    /// The rung BELOW this tier no longer stamps `.high` on whatever it happens to bind — the defect
    /// the file header parked here after fixes 1.1/1.2, closed by the 1.6/1.7a/1.8 increment.
    ///
    /// `burger and fries` is the case the header names: the template tier knows "burger" and not
    /// "fries", returns nil by design rather than answering half a description, and the
    /// candidate-constrained plan tier then answers the whole thing. It used to answer at `.high`
    /// with `unmatchedItems == []` — MORE confident and LESS disclosed than the partial the tier
    /// above would have produced, because `deterministicPlan` only reports an unmatched item when
    /// NOTHING was produced for it. `MealResolutionService.bindConfidence` now reads the per-item
    /// bind scores and refuses `.high` unless every split item cleared `confidentBindScore`.
    ///
    /// Driven end to end through `FernletStore.resolveMeals` with `aiStatus == .off`, on a catalog
    /// small enough to control the bind score: the shipped catalog only reaches tier 2 for
    /// descriptions the template tier declines, and pinning one of those would re-pin every time
    /// `DishTemplates.json` grows an alias. `needsReview` is the bit `FoodView` branches on to open
    /// the "Check this meal" sheet.
    @MainActor
    @Test func planTierConfidenceNowFollowsItsBinds() async throws {
        // A weakly-bound single item: both query tokens are in the name (so it binds) but there is no
        // phrase hit, which is the same 118-point shape as the mozzarella case one tier up.
        let weak = FoodCatalog(source: InMemoryBundledFoodSource([Self.food(name: "Shredded blend of cheddar and cheese", tags: [])]))
        try #require(DishTemplateLexicon.resolve(description: "cheese cheddar", mealType: nil, catalog: weak) == nil,
                     "the template tier must decline this description — that is what makes it a plan-tier test")
        let weakStore = makeTestStore(foodCatalog: weak)
        try #require(weakStore.settings.aiStatus == AIStatus.off, "the deterministic tiers must be the rungs under test")
        let weaklyBound = await weakStore.resolveMeals(from: "cheese cheddar")
        #expect(weaklyBound.meals.isEmpty == false, "the plan tier still answers — this is about confidence, not coverage")
        #expect(weaklyBound.meals.first?.componentSnapshots.isEmpty == false, "and it really did bind a food")
        #expect(weaklyBound.confidence == .low, "a bind that only cleared ADMISSION is no longer stamped high")
        #expect(weaklyBound.needsReview, "so the meal pauses at the review sheet before it counts toward the day")

        // The same path with an exact-name bind still resolves `.high`: tier 2 did not stop trusting
        // itself, it stopped trusting binds it cannot vouch for.
        let clean = FoodCatalog(source: InMemoryBundledFoodSource([Self.food(name: "Cheese cheddar", tags: [])]))
        let cleanStore = makeTestStore(foodCatalog: clean)
        let cleanlyBound = await cleanStore.resolveMeals(from: "cheese cheddar")
        #expect(cleanlyBound.confidence == .high)
        #expect(cleanlyBound.needsReview == false)
    }

    /// `bindConfidence`'s two other refusals, at the unit: an item that bound nothing, and a plan
    /// carrying an unmatched item, each independently forbid `.high`.
    @MainActor
    @Test func planTierRefusesHighForEmptyOrPartialPlans() {
        let exact = Self.food(name: "Cheese cheddar", tags: [])
        let candidates = [FoodSelectionCandidate(id: 1, foodItem: exact)]
        let items = [FoodSelectionMealItem(name: "cheese cheddar",
                                           ingredients: [FoodSelectionIngredient(candidateId: 1, foodName: exact.name,
                                                                                 quantity: 1, unit: "serving")])]
        #expect(MealResolutionService.bindConfidence(
            for: FoodSelectionPlan(mealName: "x", mealType: .lunch, items: items, unmatchedItems: []),
            candidates: candidates) == .high)
        #expect(MealResolutionService.bindConfidence(
            for: FoodSelectionPlan(mealName: "x", mealType: .lunch,
                                   items: [FoodSelectionMealItem(name: "cheese cheddar", ingredients: [])],
                                   unmatchedItems: []),
            candidates: candidates) == .low)
        #expect(MealResolutionService.bindConfidence(
            for: FoodSelectionPlan(mealName: "x", mealType: .lunch, items: items, unmatchedItems: ["Fries"]),
            candidates: candidates) == .low)
    }

    /// A candidate-constrained plan cannot use an unsafe household conversion to mint a high-confidence meal.
    ///
    /// The selected fries row has no source-backed conversion for the plan's household unit, so the
    /// plan construction fails closed and the fallback remains reviewable rather than inventing a scale.
    @MainActor
    @Test func planTierRoutesBurgerAndFriesToReviewWithoutUnsafeConversion() async throws {
        let store = makeTestStore(foodCatalog: FoodCatalog.bundled())
        try #require(store.settings.aiStatus == AIStatus.off, "the deterministic tiers must be the rungs under test")
        try #require(store.foodCatalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        try #require(DishTemplateLexicon.resolve(description: "burger and fries", mealType: nil, catalog: store.foodCatalog) == nil,
                     "the template tier still declines this description by design")

        let resolved = await store.resolveMeals(from: "burger and fries")
        #expect(resolved.confidence == .low, "an unconvertible plan must not claim high confidence")
        #expect(resolved.needsReview)
        #expect(resolved.meals.first?.name.contains("chili") == false, "the unsafe chili-fries bind must not survive")
    }

    /// An item the lexicon does not know at all still hands the WHOLE description to the next tier,
    /// unchanged by this fix: there is no good half to preserve, and a later tier can see all of it.
    @Test func unknownItemStillFallsThroughWithTheWholeDescription() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        #expect(DishTemplateLexicon.resolve(description: "smoothie and a cup of coffee", mealType: nil, catalog: catalog) == nil)
    }

    /// The same cases end to end through the real cascade — `FernletStore.resolveMeals`, whose
    /// `aiStatus` is `.off` by default so the deterministic template tier is the rung that answers.
    /// This is what the quick-log Save button actually calls, and `needsReview` is the bit `FoodView`
    /// branches on to open the "Check this meal" sheet.
    @MainActor
    @Test func quickLogPathRoutesToReviewAndNamesWhatWasLost() async throws {
        let store = makeTestStore(foodCatalog: FoodCatalog.bundled())
        try #require(store.settings.aiStatus == AIStatus.off, "the deterministic tier must be the rung under test")
        try #require(store.foodCatalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")

        // The query that started the round now short-circuits at item 1.12's whole-description probe
        // before it reaches the template whose direct accounting is still pinned below. The dropped
        // retailer remains visible, so the new one-row result retains 1.5's review guarantee.
        let tester = await store.resolveMeals(from: "costco cheese pizza slice")
        #expect(tester.confidence == .low, "the unmatched brand token counts as a drop")
        #expect(tester.unmatchedItems == ["costco"], "verbatim as typed (review finding F3) — not sentence-cased")
        #expect(tester.needsReview == true)
        #expect(tester.meals.first?.componentSnapshots.count == 1, "the portion-bearing row preempts decomposition")
        #expect(tester.meals.first?.componentSnapshots.first?.name == "PIZZA HUT 12\" Cheese Pizza, Pan Crust")
        #expect(tester.meals.first?.componentSnapshots.first?.quantity == 1)
        #expect(tester.meals.first?.componentSnapshots.first?.unit == RecipeUnit.slice.rawValue)
        #expect(tester.meals.first?.confidence == MealConfidence.roughEstimate.token,
                "review finding F6: the MEAL's own persisted stamp must also reflect the brand flag")

        // Both dishes build now that `tomato soup` binds confidently.
        let multi = await store.resolveMeals(from: "smoothie and tomato soup")
        #expect(multi.meals.count == 1, "the cascade folds multiple template meals into one diary entry")
        #expect(multi.meals.first?.componentSnapshots.count == 4, "the smoothie's 3 plus the soup's 1")
        #expect(multi.unmatchedItems.isEmpty)
        #expect(multi.needsReview == false)

        // Nothing drops from a bare "burger" any more.
        let burger = await store.resolveMeals(from: "burger")
        #expect(burger.unmatchedItems.isEmpty)
        #expect(burger.needsReview == false)
    }

    // MARK: - The query that started the round

    /// "costco cheese pizza slice", DIRECT TEMPLATE-ONLY AUDIT: §31's promise ("costco" becomes a
    /// visible unmatched item, flipping `needsReview` — a second, independent safety net") remains
    /// delivered at the lexicon seam with the otherwise-correct three-component decomposition intact.
    /// The live quick-log end state now answers earlier with item 1.12's one-row portion probe.
    ///
    /// The chain of fixes that got here, for the record: before 1.1/1.2 the three components bound to a
    /// Pillsbury dough product, a mozzarella-sticks snack (58, below the 250 floor) and tomato sauce,
    /// auto-committed `.high` with no review at all. 1.1/1.2 forced review, but for the WRONG reason (a
    /// bad score standing in for brand disclosure). 1.3 repaired the template data so all three
    /// components now bind confidently to the RIGHT foods — which, landing alone, reopened auto-commit
    /// for this query (that interim state is `Tests/FernletTests/…` history now, not a live test; see
    /// the file header's COSTCO CHEESE PIZZA SLICE note). 1.4 fixed the count: "slice" is the template's
    /// own unit word with no leading number, so it resolves to 1, not `defaultCount = 2` — grams are
    /// 60/40/30, not 120/80/60. 1.5 (this increment) closes the loop 1.3 reopened: `"costco"` is a
    /// retailer term (`FoodProductWebSearch.retailerTerms`) present in the typed text that the matched
    /// template key ("cheese pizza") does not cover, so it rides out in `unmatchedItems` — VERBATIM, as
    /// typed (review finding F3; an earlier draft of this fix sentence-cased it to "Costco", which the
    /// adversarial review correctly called a lexicon-flavored mangling, not the user's own text) — and
    /// counts as a drop, which pulls confidence down to `.low` too. Both independently force
    /// `needsReview`, and the MEAL's own persisted stamp reflects it too (review finding F6).
    ///
    /// **The honest accounting that remains, stated plainly.** The meal's OWN numbers (`calorieSnapshot`,
    /// pinned below) still run roughly **HALF** of what a real Costco food-court slice actually is —
    /// §31's own table puts three independent sources at 699–760 kcal/slice, and this template's
    /// generic-USDA components (raw dough + part-skim mozzarella + plain tomato sauce, no Costco-scale
    /// cheese and oil) land far short of that. Fix 1.5 does not correct THAT number — no government
    /// dataset can (§31's closing finding) — it makes sure the user sees "costco" flagged as unaccounted
    /// for before the estimate counts toward their day, which is the disclosure this whole round chases.
    @Test func theTesterQueryNowRoutesToReviewNamingCostco() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        let resolved = try #require(DishTemplateLexicon.resolve(
            description: "costco cheese pizza slice",
            mealType: nil,
            catalog: catalog
        ), "the template tier must still recognise the dish — falling through is a different bug")
        #expect(resolved.confidence == .low, "the unmatched brand token counts as a drop (fix 1.5)")
        #expect(resolved.unmatchedItems == ["costco"], "verbatim as typed (review finding F3), not lexicon-cased")
        #expect(resolved.meals.count == 1)
        let components = resolved.meals.first?.componentSnapshots ?? []
        #expect(components.count == 3, "still the three-component decomposition — 1.5 does not touch binding")
        #expect(components.map(\.quantity) == [60, 40, 30],
                "fix 1.4: 'slice' is the template's own unit word with no leading number, so count = 1, not defaultCount = 2")
        #expect(components.map(\.name) == [
            "Pizza Dough",
            "Cheese, mozzarella, low moisture, part-skim",
            "Tomato sauce, canned, no salt added"
        ], "the three RIGHT rows — fix 1.3's repair, still intact")
        #expect(resolved.meals.first?.confidence == MealConfidence.roughEstimate.token,
                "review finding F6: the meal's own stamp must fold in the brand flag, not just component binds")

        // The honest number this WOULD commit if the user pushes through review: roughly HALF a real
        // Costco slice (699–760 kcal per §31) — 1.5 does not fix the number, only the disclosure.
        let kcal = resolved.meals.first?.calorieSnapshot ?? -1
        #expect((350...430).contains(kcal), "committed slice calories: \(kcal) — roughly half a real Costco slice, pinned so this claim stays measured, not asserted")

        let resolution = MealResolution(meals: resolved.meals, createdRecipes: [], confidence: resolved.confidence, isFallback: false, unmatchedItems: resolved.unmatchedItems)
        #expect(resolution.needsReview == true,
                "§31's promise, delivered: \"costco\" flips needsReview a second, independent time")
    }

    /// A brand token that IS part of the template's OWN alias must not false-positive — AND the
    /// mechanism must still be demonstrably alive for a DIFFERENT, genuinely unaccounted brand word in
    /// the same item (review finding F5: an earlier draft of this test only asserted the negative,
    /// which passes identically whether fix 1.5 exists or was deleted outright — not discriminating).
    /// `burrito bowl`'s alias list includes "chipotle bowl" — an EXACT key match for the second query,
    /// so `matchedKey` equals the whole typed item and there is nothing left over for
    /// `unaccountedBrandChips` to flag from "chipotle" specifically. This is the case fix 1.5's design
    /// note calls out by construction, not by a special-cased exclusion list.
    @Test func brandTokenInsideATemplateAliasDoesNotFalsePositive() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")

        // Discriminating half: "costco" is NOT part of the matched key ("chipotle bowl"), so it must
        // still be flagged — proving the feature is alive, not merely silent. If fix 1.5 were deleted,
        // `unmatchedItems` would be empty here instead.
        let withStrayBrand = try #require(DishTemplateLexicon.resolve(
            description: "costco chipotle bowl", mealType: nil, catalog: catalog
        ))
        #expect(withStrayBrand.unmatchedItems == ["costco"],
                "costco is unaccounted; chipotle is NOT — it's inside the matched key \"chipotle bowl\"")

        // Non-false-positive half: bare "chipotle bowl" is an EXACT key match, so nothing is left over.
        let bare = try #require(DishTemplateLexicon.resolve(
            description: "chipotle bowl", mealType: nil, catalog: catalog
        ), "burrito bowl's own alias names a chain — it must still resolve, not fall through")
        #expect(bare.unmatchedItems.isEmpty,
                "the matched key IS \"chipotle bowl\" exactly — nothing to flag; false-positive would defeat the whole feature")
    }

    // MARK: - Adversarial phrasings that never reach fix 1.5 (documented, not tested)
    //
    // Two phrasings were checked and found NOT to exercise fix 1.5 at all, so a live @Test asserting
    // `resolve(...) == nil` for either would be non-discriminating — it would pass identically whether
    // fix 1.5 exists, was deleted, or was never written (review finding F5). Recorded here as comments
    // instead of tests wearing documentation:
    //
    //   • "kirkland protein bar" — no `DishTemplates.json` entry is anywhere close to "protein bar", so
    //     the template tier does not recognise the dish AT ALL and `resolve` returns nil before fix
    //     1.5's brand check ever runs. In scope, not a gap: 1.5's location column names the
    //     template/lexicon tier only, so a retailer name attached to a food the lexicon has no
    //     template for was someone else's tier's problem before this fix and stays so after.
    //
    //   • "trader joes orange chicken" — a MULTI-WORD retailer name typed with a plural/possessive
    //     ("trader joes", not the list's singular "trader joe"). `String.contains` would still find
    //     "trader joe" as a substring of "trader joes" if this phrase ever reached the check — Q7's
    //     token-BOUNDARY concern does not bite THIS phrase either way — but it never reaches the check:
    //     no template recognises "orange chicken" at all, so `resolve` returns nil first, same as the
    //     kirkland case above.

    // MARK: - Review finding F1: the possessive-apostrophe class

    /// 12 of `FoodBrandLexicon`'s 43 chain entries are spelled as the COLLAPSED possessive ("wendys",
    /// not "wendy"), but `FoodItemSearch.normalized` maps an apostrophe to a bare SPACE, so the
    /// CANONICAL possessive spelling ("wendy's") used to normalize to "wendy s" — two tokens — and
    /// silently miss the chain lexicon entirely: "wendys burger" flagged "wendys"; "wendy's burger"
    /// auto-committed. `FoodBrandLexicon.matchedChainTokens` now also checks a possessive-collapsed
    /// form (review finding F1). Both spellings are pinned for all 12 — the pre-existing (already-
    /// collapsed) spelling must still work, and the canonical possessive spelling must now ALSO work,
    /// verbatim (review finding F3: the chip is the user's own substring, apostrophe intact — "Wendy's
    /// burger" flags "Wendy's", not "wendys").
    @Test(arguments: [
        ("mcdonalds", "mcdonald's"),
        ("wendys", "wendy's"),
        ("arbys", "arby's"),
        ("applebees", "applebee's"),
        ("chilis", "chili's"),
        ("dennys", "denny's"),
        ("hardees", "hardee's"),
        ("friendlys", "friendly's"),
        ("rallys", "rally's"),
        ("dominos", "domino's"),
        ("carls jr", "carl's jr"),
        ("long john silvers", "long john silver's"),
    ])
    func possessiveChainsFlagBothSpellingsVerbatim(plain: String, possessive: String) throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")

        let plainResolved = try #require(DishTemplateLexicon.resolve(
            description: "\(plain) burger", mealType: nil, catalog: catalog
        ), "\"\(plain) burger\" must still match the burger template")
        #expect(plainResolved.unmatchedItems == [plain], "the pre-existing (already-collapsed) spelling")

        let possessiveResolved = try #require(DishTemplateLexicon.resolve(
            description: "\(possessive) burger", mealType: nil, catalog: catalog
        ), "\"\(possessive) burger\" must still match the burger template")
        #expect(possessiveResolved.unmatchedItems == [possessive],
                "F1: the canonical possessive spelling, verbatim (F3) — this used to be silently missed entirely")
    }

    /// F1's companion "verify" instruction: is `FoodProductWebSearch.retailerTerms` ALSO
    /// possessive-vulnerable? Checked, not just asserted: "trader joe" (the list's entry, no
    /// apostrophe) is a substring of "trader joe s" (what "trader joe's" normalizes to) with NO
    /// collapsing needed — the entry is already the possessive STEM, so both the bare and possessive
    /// spellings match through the existing `.contains` check unmodified. This also doubles as an F3
    /// pin: the verbatim chip recovers the FULLER "trader joe's" (apostrophe included), not just the
    /// "trader joe" the membership check happened to find, because chip extraction always works off
    /// the possessive-collapsed word spans regardless of which check found the term.
    @Test func retailerTermsAreAlreadyPossessiveSafeVerified() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        let resolved = try #require(DishTemplateLexicon.resolve(
            description: "trader joe's chicken burrito", mealType: nil, catalog: catalog
        ), "\"chicken burrito\" is a real template alias")
        #expect(resolved.unmatchedItems == ["trader joe's"],
                "no possessive-collapse needed for membership; F3 recovers the apostrophe anyway")
    }

    // MARK: - Closure-round residual 1: the character users actually type

    /// The 12-pair possessive pins above use ASCII apostrophes only. U+2019 (RIGHT SINGLE QUOTATION
    /// MARK) is the curly "smart quote" iOS text fields insert by default — the character a real user
    /// types far more often than `'` — and U+2018 is its opening twin, occasionally substituted by
    /// third-party keyboards/autocorrect. Both already work with ZERO code change: neither is a
    /// Unicode letter, so `FoodItemSearch.normalized` already treats them as a separator exactly like
    /// `'`, and the existing possessive-collapse reunites the split. Pinned for 4 representative chains
    /// (one 2-word entry included) rather than all 12 — the mechanism is `normalized()`'s CHARACTER
    /// CLASSIFICATION, not per-chain string content, so one failure here would indicate the mechanism
    /// broke for every chain simultaneously; a future normalization change silently regressing this
    /// would otherwise go undetected with only ASCII pins green.
    @Test(arguments: [
        ("wendy\u{2019}s", "wendys"),           // U+2019 RIGHT SINGLE QUOTATION MARK
        ("mcdonald\u{2019}s", "mcdonalds"),
        ("carl\u{2019}s jr", "carls jr"),        // 2-word entry
        ("wendy\u{2018}s", "wendys"),            // U+2018 LEFT SINGLE QUOTATION MARK
    ])
    func smartQuoteApostrophesFlagVerbatim(typed: String, plainEquivalent: String) throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        let resolved = try #require(DishTemplateLexicon.resolve(
            description: "\(typed) burger", mealType: nil, catalog: catalog
        ), "\"\(typed) burger\" must still match the burger template")
        #expect(resolved.unmatchedItems == [typed],
                "the curly quote (real iOS input) flags, verbatim, exactly as \"\(plainEquivalent)\" already did")
    }

    // MARK: - Closure-round residual 2: the Lm-apostrophe class

    /// U+02BC (MODIFIER LETTER APOSTROPHE) is Unicode category **Lm — a LETTER**, not punctuation, so
    /// `Character.isLetter` is true for it and `FoodItemSearch.normalized` keeps it FUSED inside its
    /// word run instead of splitting on it: "wendyʼs" (U+02BC) normalizes to the single token
    /// "wendyʼs" — neither the raw substring check nor the possessive collapse (which needs a
    /// SEPARATE trailing "s" token to reunite) can ever match that against the lexicon's "wendys".
    /// Reachable from third-party/locale keyboards and text pipelines that canonicalize the apostrophe
    /// to U+02BC. `FoodBrandLexicon.apostropheNormalized` pre-maps it (and U+02BB, U+A78C) to the ASCII
    /// apostrophe before normalization, so it now flags — through `matchedChainTokens` ONLY; neither
    /// `queryContainsBrandToken` nor `FoodItemSearch.normalized` itself was touched.
    ///
    /// **The chip is the raw lexicon spelling ("wendys"), not a verbatim "wendyʼs" slice** — an honest
    /// gap in `unaccountedBrandChips`'s span-finding, which was deliberately NOT touched (the fix is
    /// scoped to `matchedChainTokens` only): `possessiveCollapsedWordSpans` classifies characters the
    /// same `isLetter`-based way, so "wendyʼs" is still ONE span there too, and `spanOfTerm` cannot find
    /// "wendys" inside a span whose own normalized text is "wendyʼs" — `unaccountedBrandChips`'s
    /// documented fallback ("should not happen... falls back to the lexicon's own spelling") is exactly
    /// what fires. Still routes to review, which is the property that matters; the cosmetic mismatch
    /// joins the ledger's other two (trailing-apostrophe chains, sub-word containment).
    @Test func lmModifierLetterApostropheFlags() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        let resolved = try #require(DishTemplateLexicon.resolve(
            description: "wendy\u{02BC}s burger", mealType: nil, catalog: catalog
        ), "\"wendyʼs burger\" (U+02BC) must still match the burger template")
        #expect(resolved.unmatchedItems.isEmpty == false, "must flag — the property that matters")
        #expect(resolved.unmatchedItems == ["wendys"],
                "honest gap: falls back to the lexicon spelling, not a verbatim \"wendyʼs\" slice — see doc comment")
    }

    // MARK: - Review finding F2: the food-word collision class (pinned, not fixed)

    /// The SAME unanchored-substring matching that catches "costco" also catches an ordinary FOOD WORD
    /// that happens to collide with a chain's lexicon entry — "chipotle" (the pepper) and "chilis"
    /// (plural of chili, the vegetable) both match real chain entries. Building a food-word exception
    /// list would invent phrase-vs-token semantics that belong to §37 Q7's restructuring, not to this
    /// fix — recorded here as a KNOWN, ACCEPTED trade (the round's ledger), not fixed.
    @Test func foodWordCollisionWithAChainNameIsPinnedNotFixed() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")

        // "chicken taco" (12 chars) out-matches the bare "taco" (4 chars) alias, so the unaccounted
        // leftover is "chipotle" — the pepper, not the restaurant chain the lexicon assumes it is.
        let pepper = try #require(DishTemplateLexicon.resolve(
            description: "chipotle chicken taco", mealType: nil, catalog: catalog
        ))
        #expect(pepper.unmatchedItems == ["chipotle"], "false positive: this \"chipotle\" is a pepper, not the chain — Q7")

        // "quesadilla" (10 chars) is the matched key; "chilis" (the vegetable, plural of chili) is the
        // unaccounted leftover — and also, coincidentally, Chili's the restaurant chain's own entry.
        let vegetable = try #require(DishTemplateLexicon.resolve(
            description: "green chilis quesadilla", mealType: nil, catalog: catalog
        ))
        #expect(vegetable.unmatchedItems == ["chilis"], "false positive: this \"chilis\" is chili peppers, not Chili's — Q7")
    }

    // MARK: - Review finding F9: deterministic length-tie tie-break

    /// `matchDetailsWithCount`'s longest-substring `.max` used to break a LENGTH TIE using whichever
    /// key `Dictionary` iteration visited first — hash-seed-randomized per process, and no longer
    /// harmless now that `matchedKey` feeds user-visible unmatched-item text (fix 1.5). "poke" and
    /// "taco" are both real, 4-character index keys (`poke bowl`'s alias and `taco`'s name); "poke
    /// taco" ties them at length 4. Pinned deterministic: the tuple tie-break makes the
    /// lexicographically LARGER key win ("taco" > "poke") — an arbitrary but now-STABLE choice.
    @Test func lengthTiedSubstringMatchesAreDeterministic() {
        let (template, _) = DishTemplateLexicon.matchWithCount("poke taco")
        #expect(template?.name == "taco", "lexicographic tie-break: \"taco\" > \"poke\"")
    }

    /// Plain "cheese pizza" — a query that genuinely IS the template, no brand token involved — now
    /// resolves confidently. This is the round's origin story closing: the mozzarella component that
    /// used to bind *Mozzarella sticks, breaded, baked, or fried* at 58 now binds *Cheese, mozzarella,
    /// low moisture, part-skim* at 360, comfortably above `confidentBindScore`.
    @Test func plainCheesePizzaNowResolvesConfidently() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        let resolved = try #require(DishTemplateLexicon.resolve(description: "cheese pizza", mealType: nil, catalog: catalog))
        #expect(resolved.confidence == .high)
        let mozzarella = catalog.scoredResults(for: "low moisture part skim mozzarella cheese", limit: 1).first
        #expect((mozzarella?.score ?? 0) >= FoodItemSearch.confidentBindScore, "the component that used to cause the downgrade")
        #expect(mozzarella?.item.name == "Cheese, mozzarella, low moisture, part-skim")
    }

    // MARK: - Audit hardening: the portion SHAPE, independent of which row a search string binds to

    /// One template's declared portioning shape, in file order: `unit`, `defaultCount`, and every base
    /// component's `gramsPerUnit`. Everything else in this file discriminates on SEARCH STRINGS — an
    /// adversarial review found that a mutation to any of these three numbers moved nothing else here:
    /// `burger`'s beef patty `gramsPerUnit` 113 → 1130 (a silent ~3200 kcal `.high` commit that should
    /// have tripped `MealPlausibility.maxSingleLogCalories`, not stayed invisible inside this tier's own
    /// confidence stamp) and taco's `defaultCount` 2 → 9 both left all 20 pre-existing tests green. This
    /// is the missing pin.
    struct DishTemplateShapePin: Equatable {
        let name: String
        let unit: String
        let defaultCount: Double
        /// `gramsPerUnit` for the template's BASE components, in file order.
        let componentGrams: [Double]
        /// `gramsPerUnit` for every `aliasOverrides` component, flattened across all overrides, in
        /// file order — empty for the 27 templates with no override. A second adversarial-review pass
        /// found THIS axis unpinned too: mutating `cheeseburger`'s override cheese 21 → 210 g moved
        /// nothing, because the shape table only ever looked at base components. Two non-empty cases
        /// exist today: `burger`'s `cheeseburger` override (`[21]`, additive — cheese ON TOP of the
        /// four base components) and `fried rice`'s `vegetable fried rice` override (`[166]`,
        /// REPLACING the base component entirely — see `DishTemplateAliasOverride.replacesBaseComponents`
        /// in `DishTemplateLexicon.swift`). This field does not distinguish additive from replacing —
        /// that is `resolvedComponents`' job at resolve time — it only pins the raw gram values so
        /// either kind of mutation is visible here.
        let overrideGrams: [Double]

        init(_ name: String, _ unit: String, _ defaultCount: Double, _ componentGrams: [Double], _ overrideGrams: [Double] = []) {
            self.name = name
            self.unit = unit
            self.defaultCount = defaultCount
            self.componentGrams = componentGrams
            self.overrideGrams = overrideGrams
        }
    }

    /// Every template's shape, measured 2026-08-22 straight after the adversarial-review rounds' data
    /// fixes (rice, bun, tomato soup, tortilla, bread, beef patty, fried-rice collapse + per-alias
    /// vegetable-fried-rice override, sashimi `defaultCount` revert). Re-generate by hand from
    /// `DishTemplates.json` after any deliberate edit — there is no dump for this table (it is 29
    /// short lines; a print-and-paste helper would be more code than the table itself).
    static let shapePins: [DishTemplateShapePin] = [
        DishTemplateShapePin("nigiri", "piece", 1, [17, 18]),
        DishTemplateShapePin("sashimi", "piece", 1, [28]),
        DishTemplateShapePin("sushi roll", "piece", 8, [10, 20]),
        DishTemplateShapePin("poke bowl", "bowl", 1, [140, 150, 50, 40]),
        DishTemplateShapePin("grilled cheese", "sandwich", 1, [50, 42, 10]),
        DishTemplateShapePin("tuna sandwich", "sandwich", 1, [50, 85, 20]),
        DishTemplateShapePin("tuna melt", "sandwich", 1, [50, 85, 28, 15]),
        DishTemplateShapePin("BLT", "sandwich", 1, [50, 24, 15, 40, 15]),
        DishTemplateShapePin("burger", "burger", 1, [113, 50, 15, 30], [21]),
        DishTemplateShapePin("burrito", "burrito", 1, [72, 120, 100, 80, 28]),
        DishTemplateShapePin("burrito bowl", "bowl", 1, [150, 150, 90, 28]),
        DishTemplateShapePin("taco", "taco", 2, [60, 26, 14, 10]),
        DishTemplateShapePin("quesadilla", "quesadilla", 1, [60, 60, 80]),
        DishTemplateShapePin("stir fry", "serving", 1, [150, 100, 150]),
        DishTemplateShapePin("fried rice", "serving", 1, [198], [166]),
        DishTemplateShapePin("pad thai", "serving", 1, [180, 50, 80, 20]),
        DishTemplateShapePin("bibimbap", "bowl", 1, [150, 80, 50, 50]),
        DishTemplateShapePin("pho", "bowl", 1, [150, 100, 300]),
        DishTemplateShapePin("ramen", "bowl", 1, [200, 80, 50, 300]),
        DishTemplateShapePin("avocado toast", "slice", 1, [40, 75]),
        DishTemplateShapePin("spaghetti bolognese", "serving", 1, [200, 120, 80]),
        DishTemplateShapePin("caesar salad", "serving", 1, [100, 100, 30, 15]),
        DishTemplateShapePin("pizza", "slice", 2, [60, 40, 30]),
        DishTemplateShapePin("shawarma", "wrap", 1, [150, 65, 40]),
        DishTemplateShapePin("curry", "serving", 1, [150, 120, 150]),
        DishTemplateShapePin("tomato soup", "bowl", 1, [244]),
        DishTemplateShapePin("chicken noodle soup", "bowl", 1, [60, 80, 200]),
        DishTemplateShapePin("oatmeal", "bowl", 1, [234]),
        DishTemplateShapePin("smoothie", "smoothie", 1, [100, 240, 30])
    ]

    /// The non-vacuity proof this table exists to close: replays `shapePins` against the LIVE decoded
    /// JSON, so a `gramsPerUnit`/`defaultCount`/`unit` edit — the exact class of mutation the search-
    /// string pins above cannot see — fails here. Proven by hand twice this round: burger's beef patty
    /// `gramsPerUnit` 113 → 1130 (base-component axis) and `cheeseburger`'s override cheese 21 → 210
    /// (override axis) were each applied, the suite was rebuilt, this test went RED while all others
    /// stayed green, the mutation was reverted, and the suite was rebuilt green again — see the round's
    /// report for the transcript.
    ///
    /// Compared PER-TEMPLATE-PER-FIELD rather than as one `live == Self.shapePins` array equality: an
    /// adversarial review found the whole-array form dumps both complete 29-element arrays (~6 KB) into
    /// a single failure message, forcing a manual diff to find the one value that moved. This loop
    /// names the template and the field directly.
    @Test func templatePortionShapeIsPinned() throws {
        #expect(DishTemplateLexicon.allTemplates.count == 29, "shape table must cover every template")
        let live = DishTemplateLexicon.allTemplates.map { template in
            DishTemplateShapePin(
                template.name, template.unit, template.defaultCount,
                template.components.map(\.gramsPerUnit),
                (template.aliasOverrides ?? []).flatMap { $0.componentOverrides.map(\.gramsPerUnit) }
            )
        }
        #expect(live.count == Self.shapePins.count, "template count moved: \(live.count) live, \(Self.shapePins.count) pinned")
        for (index, pin) in Self.shapePins.enumerated() where index < live.count {
            let actual = live[index]
            #expect(actual.name == pin.name, "template at index \(index) moved: pinned \"\(pin.name)\", live \"\(actual.name)\"")
            #expect(actual.unit == pin.unit, "\(pin.name): unit moved — pinned \(pin.unit), live \(actual.unit)")
            #expect(actual.defaultCount == pin.defaultCount, "\(pin.name): defaultCount moved — pinned \(pin.defaultCount), live \(actual.defaultCount)")
            #expect(actual.componentGrams == pin.componentGrams, "\(pin.name): component grams moved — pinned \(pin.componentGrams), live \(actual.componentGrams)")
            #expect(actual.overrideGrams == pin.overrideGrams, "\(pin.name): override grams moved — pinned \(pin.overrideGrams), live \(actual.overrideGrams)")
        }
    }

    // MARK: - Fix 1.4: unit-word count parsing, battery

    /// The core case: a bare singular unit word with no leading number means count = 1, not the
    /// template's `defaultCount` "typical order" guess. `pizza`'s `defaultCount` is 2, so these would
    /// have silently doubled before fix 1.4.
    @Test func bareUnitWordMeansOne() {
        #expect(DishTemplateLexicon.matchWithCount("pizza slice").1 == 1)
        #expect(DishTemplateLexicon.matchWithCount("a slice of pizza").1 == 1)
    }

    /// A PLURAL unit word with no leading number is deliberately NOT flattened to 1 — it keeps
    /// `defaultCount`, since a plural mention plausibly implies more than one and `namesOwnUnit`
    /// (`DishTemplateLexicon.swift`) matches the singular form only.
    @Test func pluralUnitWordKeepsDefaultCount() {
        #expect(DishTemplateLexicon.matchWithCount("pizza slices").1 == 2, "pizza's defaultCount, unmoved by the plural")
    }

    /// A RESIDUAL, not a fix: `extractLeadingCount` (`DishTemplateLexicon.swift`) only parses NUMERIC
    /// digits via `LocaleTolerantNumber.double`, never English number words. "three slices of pizza"
    /// therefore does NOT parse as count = 3 — it falls back to `defaultCount` (2), reading exactly like
    /// the bare "pizza slices" case above and silently mismatching whatever number was actually typed.
    /// Recorded here, per an adversarial review's explicit request, so this gap is measured and visible
    /// rather than assumed closed by 1.4. Word-number parsing is NOT this fix's job.
    @Test func wordNumbersAreNotParsedAResidualNotAFix() {
        #expect(DishTemplateLexicon.matchWithCount("three slices of pizza").1 == 2,
                "word-number parsing is NOT implemented — this silently reads as defaultCount, not 3")
    }

    /// `taco`'s own name equals its `unit` ("taco"), so `namesOwnUnit` fires for the bare template NAME
    /// too, not only a dedicated unit phrase — bare "taco" resolves to count = 1, never the JSON's
    /// `defaultCount: 2`. That default is reachable only via a LEADING NUMBER ("3 tacos") or the PLURAL
    /// alias with no leading number ("tacos" — plural, so `namesOwnUnit` does not match it either, and
    /// it falls back to `defaultCount`).
    ///
    /// **The owner's call, recorded 2026-08-22:** this is CORRECT — "taco" means one taco — but it
    /// leaves `defaultCount: 2` in `DishTemplates.json` UNREACHABLE from the bare singular name: a dead
    /// value for that one input shape, still live for the plural alias and any explicit leading count.
    /// Not a bug to fix; a fact about the data worth stating rather than leaving implicit.
    @Test func bareTacoIsOneAndDefaultCountTwoIsUnreachableFromIt() {
        #expect(DishTemplateLexicon.matchWithCount("taco").1 == 1)
        #expect(DishTemplateLexicon.matchWithCount("tacos").1 == 2, "the PLURAL alias still reaches defaultCount")
        #expect(DishTemplateLexicon.matchWithCount("3 tacos").1 == 3, "a leading number always wins")
    }

    // MARK: - Ledger: componentGramBounds visibility (no fix — see the round's report)

    /// `componentGramBounds` feeds `MealDecompositionResolver`'s AI-tier gram clamping. This round's
    /// verbose, honest search strings ("beef ground 80 lean meat 20 fat patty cooked broiled") widen
    /// what a token-intersection match against the AI tier's own component names can hit — recorded as a
    /// LEDGER item (no code change: fixing it is a ranking/matching decision, not a data repair, and out
    /// of this fix's scope). This test does not judge whether the widening is a problem; it makes
    /// TODAY's bounds for `burger`'s tomato and lettuce VISIBLE, so a future change to either the search
    /// strings or the matching logic is forced through a visible diff instead of drifting unseen.
    @Test func boundedComponentGramsForBurgersTomatoAndLettuceAreVisible() throws {
        let bounds = DishTemplateLexicon.componentGramBounds(description: "burger")
        let tomato = try #require(bounds[FoodItemSearch.normalized("tomatoes red ripe raw")])
        let lettuce = try #require(bounds[FoodItemSearch.normalized("lettuce iceberg raw")])
        #expect(tomato == 15...52.5, "burger's tomato: gramsPerUnit 30 × count 1, ±the 0.5×/1.75× band")
        #expect(lettuce == 7.5...26.25, "burger's lettuce: gramsPerUnit 15 × count 1, ±the 0.5×/1.75× band")
    }

    // MARK: - The derivation itself, on fixtures that isolate one signal each

    /// A template whose every component binds by exact name still resolves `.high` and still
    /// auto-commits — the regression floor for "do not make every quick-log pause".
    @Test func cleanlyBindingTemplateStillResolvesHigh() throws {
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource(Self.tacoComponents()))
        let resolved = try #require(DishTemplateLexicon.resolve(description: "taco", mealType: nil, catalog: catalog))
        #expect(resolved.confidence == .high)
        #expect(MealResolution(meals: resolved.meals, createdRecipes: [], confidence: resolved.confidence, isFallback: false).needsReview == false)
        #expect(resolved.meals.first?.confidence == MealConfidence.foodMatch.token, "a clean bind still stamps 'matched to a food'")
    }

    /// One weakly-bound component (name tokens hit, no substring hit, under the 250 floor) is enough
    /// to downgrade the whole resolution. This is the mozzarella case, isolated.
    ///
    /// The substitute row is named *Shredded blend of cheddar and cheese* rather than the
    /// *Shredded cheddar blend* + `tags: ["cheese", "cheddar"]` it used to be, because research §26
    /// fix 1.8's floor is exactly the rule that a tag is not a name: with "cheese" reachable only
    /// through the tags, the row is no longer bound AT ALL, which tests the DROP path this test's
    /// sibling already covers rather than the weak-bind path this one is for. Both query tokens are
    /// now in the name, and the bind is still weak (two +60 token hits, no phrase hit, 118 < 250).
    @Test func oneWeakComponentDowngradesTheWholeResolution() throws {
        var items = Self.tacoComponents()
        items.removeAll { $0.name == "Cheese cheddar" }
        items.append(Self.food(name: "Shredded blend of cheddar and cheese", tags: ["cheese", "cheddar"]))
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource(items))
        let resolved = try #require(DishTemplateLexicon.resolve(description: "taco", mealType: nil, catalog: catalog))
        let weak = try #require(catalog.scoredResults(for: "cheese cheddar", limit: 1).first)
        #expect(weak.score < FoodItemSearch.confidentBindScore)
        #expect(weak.score >= FoodItemSearch.minimumBindScore, "it binds — it is just not confident")
        #expect(resolved.confidence == .low)
        #expect(resolved.meals.first?.componentSnapshots.count == 4, "a weak component is kept, not dropped")
        #expect(resolved.meals.first?.confidence == MealConfidence.roughEstimate.token, "and the meal says so")
    }

    /// A component whose best hit matches on tags alone is DROPPED — it contributes no macros — and
    /// the drop forces `.low`, so a meal that is quietly missing an ingredient can never auto-commit.
    ///
    /// As of research §26 fix 1.8 the tag-only row does not merely score below `minimumBindScore`, it
    /// is not returned at all: the search floor now asks whether the NAME carries the query, and
    /// *Wrap* carries none of "lettuce iceberg raw". The drop path being tested is unchanged — the
    /// component still contributes nothing and still forces review — but the reason it is empty moved
    /// one layer earlier, so the fixture is asserted as empty rather than as sub-floor.
    @Test func unbindableComponentIsDroppedAndForcesReview() throws {
        var items = Self.tacoComponents()
        items.removeAll { $0.name == "Lettuce iceberg raw" }
        items.append(Self.food(name: "Wrap", tags: ["lettuce", "iceberg", "raw"]))
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource(items))
        try #require(catalog.scoredResults(for: "lettuce iceberg raw", limit: 1).isEmpty,
                     "fixture must not bind: its only candidate reaches the gate on tags alone")
        #expect(!FoodItemSearch.nameCarriesQuery("Wrap", query: "lettuce iceberg raw"))
        let resolved = try #require(DishTemplateLexicon.resolve(description: "taco", mealType: nil, catalog: catalog))
        #expect(resolved.confidence == .low)
        #expect(resolved.meals.first?.componentSnapshots.count == 3, "the tag-only match contributes nothing")
    }

    /// When NO component binds, the tier returns nil and the cascade falls through to its next rung —
    /// unchanged behaviour, asserted because fix 1.2 moved the code that decides it.
    @Test func templateWithNoBindableComponentFallsThrough() {
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([Self.food(name: "Wrap", tags: ["taco"])]))
        #expect(DishTemplateLexicon.resolve(description: "taco", mealType: nil, catalog: catalog) == nil)
    }

    /// The dump: re-pins `pins` after a deliberate `DishTemplates.json` edit (fix 1.3).
    ///
    /// Assertions make it a real test rather than a print statement — one line per declared
    /// component, and no quote in a pinned string that would corrupt the paste-back.
    @Test func dumpEmitsOneLinePerTemplateComponent() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        let live = Self.liveComponents()
        let lines: [String] = live.map { component in
            let top = catalog.scoredResults(for: component.query, limit: 1).first
            // A row name can itself contain a quote — the shipped catalog carries
            // `trimmed to 0" fat` — so it is escaped for the Swift literal it is pasted back into.
            let name = (top?.item.name ?? "").replacingOccurrences(of: "\"", with: "\\\"")
            let score = top?.score ?? 0
            let pinned = Self.pins.first { $0.description == component.description && $0.query == component.query }
            let verdict = pinned?.verdict ?? .defensible
            return "        DishTemplateBindPin(\"\(component.description)\", \"\(component.query)\", \"\(name)\", \(score), .\(verdict.rawValue)),"
        }
        #expect(lines.count == live.count)
        #expect(lines.allSatisfy { $0.hasSuffix("),") && $0.contains("DishTemplateBindPin(\"") },
                "every dumped line must be a pasteable literal")
        Self.printDumpIfRequested(lines)
    }

    // MARK: - Helpers

    /// Every (resolved description, catalog query) pair the resolver would bind, in file order.
    ///
    /// One group per description `resolve` is actually called with: the template's own name binds its
    /// base components, and each override-carrying alias binds base + overrides — which is why a
    /// `cheeseburger` group repeats `burger`'s four base rows. Queries come from the resolver's own
    /// ``DishTemplateLexicon/catalogQuery(for:)`` so the audit can never measure a string the resolver
    /// does not run.
    private static func liveComponents() -> [(description: String, query: String)] {
        DishTemplateLexicon.allTemplates.flatMap { template -> [(description: String, query: String)] in
            func group(_ description: String, _ components: [DishTemplateComponent]) -> [(description: String, query: String)] {
                components.map { (description: description, query: DishTemplateLexicon.catalogQuery(for: $0)) }
            }
            let base = group(template.name, template.components)
            // Mirrors `DishTemplateMatch.resolvedComponents`: an override REPLACES the base components
            // for that alias when `replacesBaseComponents` is set (`vegetable fried rice` binding its
            // own catalog row instead of the generic one), or is appended after them by default
            // (`cheeseburger` adding cheese to `burger`'s four).
            let aliased = (template.aliasOverrides ?? []).flatMap { override -> [(description: String, query: String)] in
                let resolved = (override.replacesBaseComponents ?? false)
                    ? override.componentOverrides
                    : template.components + override.componentOverrides
                return group(override.alias, resolved)
            }
            return base + aliased
        }
    }

    /// A four-row in-memory catalog whose names are exact matches for the taco template's four
    /// component queries (post fix-1.3), so every bind scores in the confident band.
    private static func tacoComponents() -> [FoodItem] {
        [
            food(name: "Cooked beef ground cooked", tags: ["cooked", "beef", "ground"]),
            food(name: "Tortilla corn", tags: ["tortilla", "corn"]),
            food(name: "Cheese cheddar", tags: ["cheese", "cheddar"]),
            food(name: "Lettuce iceberg raw", tags: ["lettuce", "iceberg", "raw"])
        ]
    }

    /// A three-row in-memory catalog whose names are exact matches for the smoothie template's three
    /// component queries, so every bind scores in the confident band and nothing in it can accidentally
    /// bind `sashimi`'s "raw fish raw" component (no shared tokens).
    private static func smoothieComponents() -> [FoodItem] {
        [
            food(name: "Banana", tags: ["banana", "fruit"]),
            food(name: "Milk whole", tags: ["milk", "whole"]),
            food(name: "Protein powder whey", tags: ["protein", "powder", "whey"])
        ]
    }

    /// A six-row in-memory catalog with an exact-match fixture for every `burger` and `BLT` component
    /// EXCEPT the lettuce both share (`lettuce iceberg raw`) — deliberately absent so both templates
    /// genuinely drop it, for ``repeatedDropsAreNamedOnce``.
    private static func burgerAndBLTComponentsWithoutLettuce() -> [FoodItem] {
        [
            food(name: "Beef ground 80 lean meat 20 fat patty cooked broiled", tags: ["beef", "patty"]),
            food(name: "Rolls hamburger or hotdog plain", tags: ["rolls", "hamburger"]),
            food(name: "Tomatoes red ripe raw", tags: ["tomato", "raw"]),
            food(name: "Bread white commercially prepared includes soft bread crumbs", tags: ["bread", "white"]),
            food(name: "Pork cured bacon cooked baked", tags: ["pork", "bacon"]),
            food(name: "Salad dressing mayonnaise regular", tags: ["mayonnaise", "dressing"])
        ]
    }

    /// A minimal survey-type catalog row.
    private static func food(name: String, tags: [String]) -> FoodItem {
        FoodItem(
            name: name,
            servingSize: 100,
            servingUnit: "g",
            macros: Macros(protein: 8, carbs: 10, fat: 5),
            micronutrients: Micronutrients(),
            category: "Survey (FNDDS)",
            source: .usda,
            dataType: .survey,
            tags: tags
        )
    }

    private static func printDumpIfRequested(_ lines: [String]) {
        let env = ProcessInfo.processInfo.environment
        guard env["DISH_TEMPLATE_BIND_DUMP"] != nil || env["TEST_RUNNER_DISH_TEMPLATE_BIND_DUMP"] != nil else { return }
        print("// ── DishTemplates.json bind audit ────────────────────────────────")
        for line in lines { print(line) }
    }
}
