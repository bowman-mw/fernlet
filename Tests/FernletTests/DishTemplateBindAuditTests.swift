// DishTemplateBindAuditTests.swift
// FernletTests
//
// The gate on §26 fixes 1.1 + 1.2 of Docs/Food-Search-And-Community-Database-Research-2026-08-22.md
// — §30 row 2 states it in one line: "Test over all 29 templates".
//
// WHAT THIS SUITE IS. `DishTemplates.json` holds 29 dish templates whose components are catalog
// SEARCH STRINGS, not food ids. Until fix 1.2 the tier bound each one through the UNSCORED
// `FoodCatalog.results(for:limit:1).first` — the only tier in the five-tier quick-log cascade with no
// quality gate — and `MealResolutionService` then stamped the result `.high` unconditionally, so a
// component that bound to the wrong food auto-committed to the diary with no review sheet. That is
// the "costco cheese pizza slice" bug: the pizza template's `mozzarella cheese` component binds to
// *Mozzarella sticks, breaded, baked, or fried* at score **58**, against
// `FoodItemSearch.confidentBindScore = 250`, while an exact-name `Mozzarella Cheese` row sits in the
// same catalog.
//
// So this suite replays EVERY component of EVERY template against the shipped
// `FoodCatalog.sqlite` and pins what it binds to and what it scores. Two different things are being
// held still, and they belong to two different fixes:
//
//   • The CODE half (1.1/1.2, this increment): the tier now binds through `scoredResults`, drops a
//     component whose top hit is below `minimumBindScore`, and derives its confidence from the binds
//     instead of asserting `.high`. `templateConfidenceFollowsItsWeakestBind` and the in-memory
//     fixtures below are the behavioural pins for that.
//
//   • The DATA half (1.3, NOT this increment): the pins record today's reality, including the binds
//     that are plainly wrong. A pin is not an endorsement — `verdict` says which is which. Fix 1.3
//     repairs the search strings, and its diff is exactly: edit `DishTemplates.json`, re-run this
//     suite's dump, paste the new pins, flip the verdicts. A bind that moves WITHOUT such an edit is
//     the regression this suite exists to catch.
//
// THE FLOOR IS NOT RELAXED TO MAKE THIS GREEN. `confidentBindScore` stays 250; the weak binds are
// pinned as weak and their templates are pinned as no-longer-auto-committing. Making them confident
// again is a data repair, not a threshold edit.
//
// WHAT THIS FIX DOES NOT YET KEEP, IN TWO NAMED CASES. Everything this tier declines lands on the
// candidate-constrained plan in `MealResolutionService.highConfidenceResolution`, which hardcodes
// `.high` exactly as this tier used to — so a fall-through relocates the defect one rung down rather
// than ending it. Both measured:
//
//   • `tomato soup` no longer logs 244 g of *Pork with chili and tomatoes* from here — but the plan
//     tier commits that same row silently.
//   • `burger and fries` (an item this tier knows beside one it does not) still returns nil by
//     design, and the plan tier answers with a Burger King burger plus chili fries at `.high`, with
//     `unmatchedItems == []` — MORE confident and LESS disclosed than the partial this tier would
//     have produced. `deterministicPlan` reports an unmatched item only when NOTHING was produced for
//     it, so the disclosure that makes the narrow boundary defensible does not exist downstream yet.
//
// Both repairs are the score floor (research §26 fix 1.8), which lands with 1.6 and 1.7a as one
// measured unit at order-5/6/7. Recorded here so §31's promise is not read as delivered for
// multi-item descriptions. (`oatmeal`, the other fall-through, resolved to nothing before this fix
// too and genuinely improves.)
//
// Read-only and self-contained: opens the shipped catalog read-only, writes nothing, shares no
// mutable fixture with any other suite. Re-pin with:
//
//     TEST_RUNNER_DISH_TEMPLATE_BIND_DUMP=1 xcodebuild test-without-building … \
//       -only-testing:FernletTests/DishTemplateBindAuditTests

import Foundation
import Testing
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
        DishTemplateBindPin("nigiri", "steamed rice white cooked", "", 0, .noCatalogRow),
        DishTemplateBindPin("sashimi", "raw fish raw", "Fish, bluefish, raw", 330, .defensible),
        DishTemplateBindPin("sushi roll", "raw fish raw", "Fish, bluefish, raw", 330, .defensible),
        DishTemplateBindPin("sushi roll", "steamed rice white cooked", "", 0, .noCatalogRow),
        DishTemplateBindPin("poke bowl", "raw tuna raw", "Fish, tuna, fresh, bluefin, raw", 329, .defensible),
        DishTemplateBindPin("poke bowl", "rice white cooked", "Rice, white, glutinous, unenriched, cooked", 178, .defensible),
        DishTemplateBindPin("poke bowl", "avocado", "Sushi roll, avocado", 309, .wrongFood),
        DishTemplateBindPin("poke bowl", "edamame", "Edamame, frozen, prepared", 808, .defensible),
        DishTemplateBindPin("grilled cheese", "bread white", "Chili hot dog sandwich, on white bread", 117, .wrongFood),
        DishTemplateBindPin("grilled cheese", "cheese american", "Grilled cheese sandwich, American cheese, on wheat bread", 116, .wrongFood),
        DishTemplateBindPin("grilled cheese", "butter", "Peanut butter and jelly sandwich, NFS", 307, .wrongFood),
        DishTemplateBindPin("tuna sandwich", "bread white", "Chili hot dog sandwich, on white bread", 117, .wrongFood),
        DishTemplateBindPin("tuna sandwich", "canned tuna canned water", "Fish, tuna, light, canned in water, drained solids", 388, .defensible),
        DishTemplateBindPin("tuna sandwich", "mayonnaise", "Salad dressing, NFS, for sandwiches", -2, .defensible),
        DishTemplateBindPin("tuna melt", "bread white", "Chili hot dog sandwich, on white bread", 117, .wrongFood),
        DishTemplateBindPin("tuna melt", "canned tuna canned water", "Fish, tuna, light, canned in water, drained solids", 388, .defensible),
        DishTemplateBindPin("tuna melt", "cheddar cheese", "Sausage, pork and beef, with cheddar cheese, smoked", 366, .wrongFood),
        DishTemplateBindPin("tuna melt", "mayonnaise", "Salad dressing, NFS, for sandwiches", -2, .defensible),
        DishTemplateBindPin("BLT", "bread white", "Chili hot dog sandwich, on white bread", 117, .wrongFood),
        DishTemplateBindPin("BLT", "cooked bacon cooked", "Canadian bacon, cooked, pan-fried", 179, .wrongFood),
        DishTemplateBindPin("BLT", "lettuce", "Broccoli slaw salad", -1, .wrongFood),
        DishTemplateBindPin("BLT", "tomato", "Pork with chili and tomatoes", 248, .wrongFood),
        DishTemplateBindPin("BLT", "mayonnaise", "Salad dressing, NFS, for sandwiches", -2, .defensible),
        DishTemplateBindPin("burger", "grilled beef patty ground", "", 0, .noCatalogRow),
        DishTemplateBindPin("burger", "hamburger bun", "Double hamburger, on wheat bun, 2 large patties", 116, .wrongFood),
        DishTemplateBindPin("burger", "lettuce", "Broccoli slaw salad", -1, .wrongFood),
        DishTemplateBindPin("burger", "tomato", "Pork with chili and tomatoes", 248, .wrongFood),
        DishTemplateBindPin("cheeseburger", "grilled beef patty ground", "", 0, .noCatalogRow),
        DishTemplateBindPin("cheeseburger", "hamburger bun", "Double hamburger, on wheat bun, 2 large patties", 116, .wrongFood),
        DishTemplateBindPin("cheeseburger", "lettuce", "Broccoli slaw salad", -1, .wrongFood),
        DishTemplateBindPin("cheeseburger", "tomato", "Pork with chili and tomatoes", 248, .wrongFood),
        DishTemplateBindPin("cheeseburger", "cheese american", "Grilled cheese sandwich, American cheese, on wheat bread", 116, .wrongFood),
        DishTemplateBindPin("burrito", "tortilla flour", "Snacks, tortilla chips, nacho-flavor, made with enriched masa flour", 114, .wrongFood),
        DishTemplateBindPin("burrito", "grilled chicken grilled", "McDONALD'S, Bacon Ranch Salad with Grilled Chicken", 327, .wrongFood),
        DishTemplateBindPin("burrito", "rice white cooked", "Rice, white, glutinous, unenriched, cooked", 178, .defensible),
        DishTemplateBindPin("burrito", "beans black cooked", "Beans, black, mature seeds, cooked, boiled, with salt", 177, .defensible),
        DishTemplateBindPin("burrito", "cheese shredded", "Cheese, parmesan, shredded", 119, .wrongFood),
        DishTemplateBindPin("burrito bowl", "grilled chicken grilled", "McDONALD'S, Bacon Ranch Salad with Grilled Chicken", 327, .wrongFood),
        DishTemplateBindPin("burrito bowl", "rice white cooked", "Rice, white, glutinous, unenriched, cooked", 178, .defensible),
        DishTemplateBindPin("burrito bowl", "beans black cooked", "Beans, black, mature seeds, cooked, boiled, with salt", 177, .defensible),
        DishTemplateBindPin("burrito bowl", "cheese shredded", "Cheese, parmesan, shredded", 119, .wrongFood),
        DishTemplateBindPin("taco", "cooked beef ground cooked", "Beef, ground, 93% lean meat / 7% fat, loaf, cooked, baked", 238, .defensible),
        DishTemplateBindPin("taco", "tortilla corn", "Tortilla, blue corn, Sakwavikaviki (Hopi)", 117, .defensible),
        DishTemplateBindPin("taco", "cheese shredded", "Cheese, parmesan, shredded", 119, .wrongFood),
        DishTemplateBindPin("taco", "lettuce", "Broccoli slaw salad", -1, .wrongFood),
        DishTemplateBindPin("quesadilla", "tortilla flour", "Snacks, tortilla chips, nacho-flavor, made with enriched masa flour", 114, .wrongFood),
        DishTemplateBindPin("quesadilla", "cheese shredded", "Cheese, parmesan, shredded", 119, .wrongFood),
        DishTemplateBindPin("quesadilla", "grilled chicken grilled", "McDONALD'S, Bacon Ranch Salad with Grilled Chicken", 327, .wrongFood),
        DishTemplateBindPin("stir fry", "cooked chicken breast cooked", "Chicken breast tenders, breaded, cooked, microwaved", 238, .wrongFood),
        DishTemplateBindPin("stir fry", "broccoli cooked", "Broccoli, cooked, boiled, drained, with salt", 867, .defensible),
        DishTemplateBindPin("stir fry", "rice white cooked", "Rice, white, glutinous, unenriched, cooked", 178, .defensible),
        DishTemplateBindPin("fried rice", "fried rice white cooked", "", 0, .noCatalogRow),
        DishTemplateBindPin("fried rice", "egg whole", "Egg burrito", 60, .wrongFood),
        DishTemplateBindPin("fried rice", "soy sauce", "Chow mein or chop suey, meatless, no noodles", -4, .wrongFood),
        DishTemplateBindPin("pad thai", "rice noodle cooked", "Rice noodles, cooked", 120, .defensible),
        DishTemplateBindPin("pad thai", "egg whole", "Egg burrito", 60, .wrongFood),
        DishTemplateBindPin("pad thai", "cooked shrimp cooked", "Cooked Shrimp", 180, .defensible),
        DishTemplateBindPin("pad thai", "peanut", "Peanut butter and jelly sandwich, NFS", 807, .wrongFood),
        DishTemplateBindPin("bibimbap", "rice white cooked", "Rice, white, glutinous, unenriched, cooked", 178, .defensible),
        DishTemplateBindPin("bibimbap", "cooked beef sirloin cooked", "Beef, top sirloin, steak, separable lean only, trimmed to 0\" fat, choice, cooked, broiled", 234, .defensible),
        DishTemplateBindPin("bibimbap", "egg fried", "Wonton, dumpling or pot sticker, fried", 207, .wrongFood),
        DishTemplateBindPin("bibimbap", "spinach cooked", "Spinach, cooked, boiled, drained, with salt", 867, .defensible),
        DishTemplateBindPin("pho", "rice noodle cooked", "Rice noodles, cooked", 120, .defensible),
        DishTemplateBindPin("pho", "raw beef round raw", "Beef, round, top round, boneless, choice, raw", 388, .defensible),
        DishTemplateBindPin("pho", "beef broth", "Ramen bowl with beef", 59, .wrongFood),
        DishTemplateBindPin("ramen", "noodle wheat cooked", "", 0, .noCatalogRow),
        DishTemplateBindPin("ramen", "cooked pork belly cooked", "Fully Cooked Pork Belly", 240, .defensible),
        DishTemplateBindPin("ramen", "egg soft boiled", "", 0, .noCatalogRow),
        DishTemplateBindPin("ramen", "chicken broth", "Ramen bowl with chicken", 59, .wrongFood),
        DishTemplateBindPin("avocado toast", "bread whole grain", "Bread, multi-grain (includes whole-grain)", 178, .defensible),
        DishTemplateBindPin("avocado toast", "avocado", "Sushi roll, avocado", 309, .wrongFood),
        DishTemplateBindPin("spaghetti bolognese", "spaghetti pasta cooked", "Spaghetti squash, cooked", 120, .wrongFood),
        DishTemplateBindPin("spaghetti bolognese", "cooked beef ground cooked", "Beef, ground, 93% lean meat / 7% fat, loaf, cooked, baked", 238, .defensible),
        DishTemplateBindPin("spaghetti bolognese", "tomato sauce", "Tomato sauce, canned, no salt added", 868, .defensible),
        DishTemplateBindPin("caesar salad", "romaine lettuce", "Caesar salad, with romaine, no dressing", 58, .wrongFood),
        DishTemplateBindPin("caesar salad", "grilled chicken breast grilled", "Chicken, broiler or fryers, breast, skinless, boneless, meat only, cooked, grilled", 385, .defensible),
        DishTemplateBindPin("caesar salad", "caesar dressing", "Caesar salad, with romaine, no dressing", 118, .wrongFood),
        DishTemplateBindPin("caesar salad", "parmesan cheese", "Parmesan cheese topping, fat free", 868, .wrongFood),
        DishTemplateBindPin("pizza", "pizza dough crust", "Pillsbury Pizza Dough Thin Crust", 179, .wrongFood),
        DishTemplateBindPin("pizza", "mozzarella cheese", "Mozzarella sticks, breaded, baked, or fried", 58, .wrongFood),
        DishTemplateBindPin("pizza", "tomato sauce", "Tomato sauce, canned, no salt added", 868, .defensible),
        DishTemplateBindPin("shawarma", "grilled chicken thigh cooked", "", 0, .noCatalogRow),
        DishTemplateBindPin("shawarma", "pita bread", "Bread, pita, whole-wheat", 119, .defensible),
        DishTemplateBindPin("shawarma", "tomato", "Pork with chili and tomatoes", 248, .wrongFood),
        DishTemplateBindPin("curry", "cooked chicken breast cooked", "Chicken breast tenders, breaded, cooked, microwaved", 238, .wrongFood),
        DishTemplateBindPin("curry", "tomato cream sauce", "Cheese Ravioli With Sun-Dried Tomato Cream Sauce, Sun-Dried Tomato Cream Sauce", 293, .wrongFood),
        DishTemplateBindPin("curry", "rice white cooked", "Rice, white, glutinous, unenriched, cooked", 178, .defensible),
        DishTemplateBindPin("tomato soup", "tomato soup", "Pork with chili and tomatoes", -2, .wrongFood),
        DishTemplateBindPin("chicken noodle soup", "cooked chicken cooked", "Bratwurst, chicken, cooked", 180, .wrongFood),
        DishTemplateBindPin("chicken noodle soup", "pasta noodle cooked", "Pasta, cooked", 120, .defensible),
        DishTemplateBindPin("chicken noodle soup", "chicken broth", "Ramen bowl with chicken", 59, .wrongFood),
        DishTemplateBindPin("oatmeal", "oatmeal cooked oats", "", 0, .noCatalogRow),
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

    /// The descriptions whose every component clears `confidentBindScore` — the set still allowed to
    /// resolve at `.high` and auto-commit. Derived from `pins`, asserted live.
    ///
    /// **It is two of the thirty.** That is the audit's headline, and it is a statement about
    /// `DishTemplates.json` and the catalog, not about this fix: 49 of the 96 component binds land on
    /// the wrong food and 9 match nothing at all.
    ///
    /// What this fix actually MOVES is smaller than that, and the difference matters because it is
    /// the fix's justification. Measured pre-fix (see `preFixReviewRoutingIsAttributedCorrectly`):
    /// **9 of these 30 descriptions were already routed to review** by the pre-existing 4,000-kcal
    /// plausibility gate, because their totals run 16k–46k kcal — a serving-unit defect recorded for
    /// research fix 2.5 / order-12, not something 1.1 addresses. So the real delta is
    /// **17 newly reviewed + 2 that now fall through + 2 still auto-committing + 9 already
    /// reviewed = 30**.
    static var confidentDescriptions: Set<String> {
        let unconfident = Set(pins.filter { !$0.isConfident }.map(\.description))
        return Set(pins.map(\.description)).subtracting(unconfident)
    }

    /// The descriptions that resolve to nothing at all now that fix 1.2 drops sub-floor binds: every
    /// component is dropped, so the tier returns nil and the cascade falls to its next rung.
    ///
    /// `tomato soup` is the one this fix moves — its single component bound *Pork with chili and
    /// tomatoes* at **−2** and logged 244 g of it as a bowl of soup. `oatmeal` already resolved to
    /// nothing before this fix (its search string matches no row).
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
        #expect(Self.auditedDescriptions.count == 30, "29 template names plus the one override alias")
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
    /// Measured 2026-08-22 over the 96 component binds of the 30 audited descriptions (29 template
    /// names + the `cheeseburger` override alias, whose four base components are counted again
    /// because `resolve` binds them again): **9 match no catalog row at all, 9 more bind below
    /// `minimumBindScore` (negative scores — a tag-only match), 52 bind weakly (1–249), and 26 bind
    /// confidently (≥ 250).** Fix 1.2 therefore drops 18 component binds that were previously being
    /// logged. These are the input to fix 1.3's data audit; the floor is not moved to make them
    /// smaller.
    @Test func bindFloorPopulationsAreMeasuredNotInherited() throws {
        let noRow = Self.pins.filter(\.bindsToNothing)
        let dropped = Self.pins.filter { !$0.bindsToNothing && $0.score < FoodItemSearch.minimumBindScore }
        let weak = Self.pins.filter { !$0.isDropped && !$0.isConfident }
        let confident = Self.pins.filter(\.isConfident)
        #expect(Self.pins.count == 96, "96 component binds across the 30 audited descriptions")
        #expect(noRow.count == 9, "search strings that match nothing: \(noRow.map(\.query))")
        #expect(dropped.count == 9, "binds below the drop floor: \(dropped.map(\.query))")
        #expect(weak.count == 52)
        #expect(confident.count == 26)
        #expect(noRow.count + dropped.count + weak.count + confident.count == Self.pins.count)

        // The verdicts, likewise derived. 49 of 96 binds land on the WRONG FOOD — the defect fix 1.3
        // owns, and the reason this fix is a confidence change and not a correctness claim.
        #expect(Self.pins.filter { $0.verdict == .wrongFood }.count == 49)
        #expect(Self.pins.filter { $0.verdict == .defensible }.count == 38)
        #expect(Self.pins.filter { $0.verdict == .noCatalogRow }.count == noRow.count)

        // The ten binds a score floor structurally CANNOT catch: confidently scored, and wrong. A
        // template made only of these would still auto-commit after this fix — which is exactly why
        // 1.3 is the next item and not an optional follow-up.
        let confidentlyWrong = Self.pins.filter { $0.verdict == .wrongFood && $0.isConfident }
        #expect(confidentlyWrong.count == 10, "confident-but-wrong binds: \(confidentlyWrong.map(\.query))")
        #expect(Self.confidentDescriptions == ["sashimi", "smoothie"],
                "only these two descriptions bind cleanly enough to auto-commit")
    }

    /// The behavioural pin for fix 1.1: a description resolves `.high` if and only if every component
    /// `resolve` binds for it cleared the floor. Replayed for all 30 audited descriptions against the
    /// shipped catalog — including `cheeseburger`, which binds a component `burger` never does.
    @Test func templateConfidenceFollowsItsWeakestBind() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        #expect(Self.fallThroughDescriptions == ["tomato soup", "oatmeal"])
        for description in Self.auditedDescriptions {
            let resolved = DishTemplateLexicon.resolve(description: description, mealType: nil, catalog: catalog)
            guard Self.fallThroughDescriptions.contains(description) == false else {
                #expect(resolved == nil, "\(description) has no bindable component left — the tier must fall through")
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

    /// What this fix actually MOVED, separated from what was already being caught.
    ///
    /// The pre-existing 4,000-kcal plausibility gate (`MealResolutionService.plausibilityGated`)
    /// already downgraded some template resolutions to `.low` while the tier was still asserting
    /// `.high` — so "27 of 29 templates newly pause at review" would have over-claimed this fix. This
    /// replays the PRE-fix path (hardcoded `.high` → merge → gate) for every audited description and
    /// pins the split. The eight already-gated descriptions run 16k–46k kcal, a serving-unit defect
    /// (`RecipeIngredient.scale`'s identity fallback, research fix 2.5) recorded for order-12.
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
        #expect(alreadyReviewed.sorted() == [
            "BLT", "burger", "cheeseburger", "fried rice", "grilled cheese", "pad thai", "ramen", "tuna melt", "tuna sandwich"
        ], "already caught by the 4,000-kcal gate before this fix: \(alreadyReviewed.sorted())")
        #expect(newlyReviewed.count == 17, "newly routed to review by fix 1.1: \(newlyReviewed.sorted())")
        #expect(Self.confidentDescriptions.count == 2)
        #expect(Self.fallThroughDescriptions.count == 2)
    }

    /// Fix 1.2's drop, observed end to end on the shipped catalog: the BLT template declares five
    /// components, two of which (`lettuce` → *Broccoli slaw salad* at −1, `mayonnaise` → *Salad
    /// dressing, NFS, for sandwiches* at −2) match on tags alone. They are dropped, the meal carries
    /// three, and the drop is what forces the review sheet rather than being hidden inside it.
    @Test func subFloorComponentsAreDroppedFromTheShippedTemplates() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        let resolved = try #require(DishTemplateLexicon.resolve(description: "BLT", mealType: nil, catalog: catalog))
        let names = resolved.meals.first?.componentSnapshots.map(\.name) ?? []
        #expect(names.count == 3, "two of the BLT's five components bind below the floor: \(names)")
        #expect(names.contains("Broccoli slaw salad") == false)
        #expect(resolved.confidence == .low)
        // …and the two that vanished are NAMED, so the review sheet's "Couldn't find" card shows them
        // instead of presenting a three-row BLT as complete.
        #expect(resolved.unmatchedItems == ["Lettuce", "Mayonnaise"])
    }

    /// A dropped component is never silent: the burger loses its patty (no catalog row) and its
    /// lettuce (tag-only match at −1) — 62% of the declared mass — and fried rice loses the rice
    /// itself. Both must arrive in `unmatchedItems`, which `MealResolution.needsReview` already keys
    /// off and the review sheet already renders.
    @Test func droppedComponentsAreNamedForTheReviewSheet() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        let burger = try #require(DishTemplateLexicon.resolve(description: "burger", mealType: nil, catalog: catalog))
        #expect(burger.unmatchedItems == ["Grilled beef patty ground", "Lettuce"])
        #expect(burger.meals.first?.componentSnapshots.count == 2)

        // The preparation belongs in the name: what fried rice failed to find is FRIED rice.
        let friedRice = try #require(DishTemplateLexicon.resolve(description: "fried rice", mealType: nil, catalog: catalog))
        #expect(friedRice.unmatchedItems == ["Fried rice white cooked", "Soy sauce"])

        // The card only renders a non-empty list, so the visible half is what `MealResolution` carries.
        let resolution = MealResolution(
            meals: burger.meals, createdRecipes: [], confidence: burger.confidence,
            isFallback: false, unmatchedItems: burger.unmatchedItems
        )
        #expect(resolution.unmatchedItems.isEmpty == false)
        #expect(resolution.needsReview)
    }

    /// One unbuildable dish no longer destroys its siblings.
    ///
    /// "smoothie and tomato soup" splits into two items. The smoothie is the tier's ONE clean
    /// three-component resolution; `tomato soup`'s only component drops. Before this fix the whole
    /// call returned nil, the description fell to the candidate-plan tier, and that tier answered with
    /// a peach-mango juice plus the same pork chili — at `.high`, auto-committed. Now the smoothie
    /// survives, the soup is named, and the meal pauses for review.
    @Test func multiItemDescriptionKeepsTheDishesItCanBuild() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        let resolved = try #require(DishTemplateLexicon.resolve(
            description: "smoothie and tomato soup",
            mealType: nil,
            catalog: catalog
        ), "the good half must survive")
        #expect(resolved.meals.count == 1, "one meal per buildable item")
        #expect(resolved.meals.first?.componentSnapshots.count == 3, "the smoothie's three components are intact")
        #expect(resolved.unmatchedItems == ["tomato soup"], "the failed item is surfaced verbatim")
        #expect(resolved.confidence == .low, "an item we could not build is a drop, and a drop is never high")

        let resolution = MealResolution(
            meals: resolved.meals, createdRecipes: [], confidence: resolved.confidence,
            isFallback: false, unmatchedItems: resolved.unmatchedItems
        )
        #expect(resolution.needsReview)
    }

    /// Two dishes that drop the SAME component name it once.
    ///
    /// "burger and BLT" both lose their lettuce. The review sheet renders this list with
    /// `ForEach(id: \.self)`, where a duplicate element is undefined behaviour in SwiftUI — and
    /// "Lettuce, Lettuce" would be absurd copy even if it rendered. First-seen order is preserved.
    @Test func repeatedDropsAreNamedOnce() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        let resolved = try #require(DishTemplateLexicon.resolve(description: "burger and BLT", mealType: nil, catalog: catalog))
        #expect(resolved.meals.count == 2)
        #expect(resolved.unmatchedItems == ["Grilled beef patty ground", "Lettuce", "Mayonnaise"])
        #expect(Set(resolved.unmatchedItems).count == resolved.unmatchedItems.count, "no duplicate ForEach id")
    }

    /// An item the lexicon does not know at all still hands the WHOLE description to the next tier,
    /// unchanged by this fix: there is no good half to preserve, and a later tier can see all of it.
    @Test func unknownItemStillFallsThroughWithTheWholeDescription() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        #expect(DishTemplateLexicon.resolve(description: "smoothie and a cup of coffee", mealType: nil, catalog: catalog) == nil)
    }

    /// The same three cases end to end through the real cascade — `FernletStore.resolveMeals`, whose
    /// `aiStatus` is `.off` by default so the deterministic template tier is the rung that answers.
    /// This is what the quick-log Save button actually calls, and `needsReview` is the bit `FoodView`
    /// branches on to open the "Check this meal" sheet.
    @MainActor
    @Test func quickLogPathRoutesToReviewAndNamesWhatWasLost() async throws {
        let store = makeTestStore(foodCatalog: FoodCatalog.bundled())
        try #require(store.settings.aiStatus == AIStatus.off, "the deterministic tier must be the rung under test")
        try #require(store.foodCatalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")

        // The query that started the round.
        let tester = await store.resolveMeals(from: "costco cheese pizza slice")
        #expect(tester.confidence == .low)
        #expect(tester.needsReview)

        // One unbuildable dish keeps its sibling and names itself.
        let multi = await store.resolveMeals(from: "smoothie and tomato soup")
        #expect(multi.meals.count == 1)
        #expect(multi.meals.first?.componentSnapshots.count == 3)
        #expect(multi.unmatchedItems == ["tomato soup"])
        #expect(multi.needsReview)

        // A dropped component reaches the sheet's "Couldn't find" card.
        let burger = await store.resolveMeals(from: "burger")
        #expect(burger.unmatchedItems == ["Grilled beef patty ground", "Lettuce"])
        #expect(burger.needsReview)
    }

    // MARK: - The query that started the round

    /// "costco cheese pizza slice" must no longer auto-commit.
    ///
    /// The decomposition itself is unchanged — three components, 120/80/60 g — which is the point:
    /// 1.1/1.2 do not make the answer right, they stop it being asserted. §31's row for this tier
    /// promises exactly this and no more.
    @Test func theTesterQueryNoLongerAutoCommits() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        let resolved = try #require(DishTemplateLexicon.resolve(
            description: "costco cheese pizza slice",
            mealType: nil,
            catalog: catalog
        ), "the template tier must still recognise the dish — falling through is a different bug")
        #expect(resolved.confidence == .low)
        #expect(resolved.meals.count == 1)
        let components = resolved.meals.first?.componentSnapshots ?? []
        #expect(components.count == 3, "still the three-component decomposition")
        #expect(components.map(\.quantity) == [120, 80, 60],
                "grams unchanged — `defaultCount: 2` still doubles the slice, which is fix 1.4's job, not this one")
        #expect(components.map(\.name) == [
            "Pillsbury Pizza Dough Thin Crust",
            "Mozzarella sticks, breaded, baked, or fried",
            "Tomato sauce, canned, no salt added"
        ], "still the same three wrong-ish rows — fix 1.3 owns the template data")

        let resolution = MealResolution(meals: resolved.meals, createdRecipes: [], confidence: resolved.confidence, isFallback: false)
        #expect(resolution.needsReview, "the 'Check this meal' sheet must open before this counts toward the day")
    }

    /// Plain "cheese pizza" — a query that genuinely IS the template — gets the same verdict today,
    /// and that is correct rather than collateral damage: the downgrade is about the template's own
    /// `mozzarella cheese` bind (58), not about the brand token the tester typed. Fix 1.3 repairs the
    /// search string and this row flips to `.high`; it is pinned here so that flip is visible.
    @Test func plainCheesePizzaCarriesTheSameWeakBind() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        let resolved = try #require(DishTemplateLexicon.resolve(description: "cheese pizza", mealType: nil, catalog: catalog))
        #expect(resolved.confidence == .low)
        let mozzarella = catalog.scoredResults(for: "mozzarella cheese", limit: 1).first
        #expect((mozzarella?.score ?? 0) < FoodItemSearch.confidentBindScore, "the component that causes the downgrade")
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

    /// One weakly-bound component (name tokens hit, no substring hit → 120, under the 250 floor) is
    /// enough to downgrade the whole resolution. This is the mozzarella case, isolated.
    @Test func oneWeakComponentDowngradesTheWholeResolution() throws {
        var items = Self.tacoComponents()
        items.removeAll { $0.name == "Cheese shredded" }
        items.append(Self.food(name: "Shredded cheese blend", tags: ["cheese", "shredded"]))
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource(items))
        let resolved = try #require(DishTemplateLexicon.resolve(description: "taco", mealType: nil, catalog: catalog))
        let weak = try #require(catalog.scoredResults(for: "cheese shredded", limit: 1).first)
        #expect(weak.score < FoodItemSearch.confidentBindScore)
        #expect(weak.score >= FoodItemSearch.minimumBindScore, "it binds — it is just not confident")
        #expect(resolved.confidence == .low)
        #expect(resolved.meals.first?.componentSnapshots.count == 4, "a weak component is kept, not dropped")
        #expect(resolved.meals.first?.confidence == MealConfidence.roughEstimate.token, "and the meal says so")
    }

    /// A component whose best hit matches on tags alone is DROPPED — it contributes no macros — and
    /// the drop forces `.low`, so a meal that is quietly missing an ingredient can never auto-commit.
    @Test func unbindableComponentIsDroppedAndForcesReview() throws {
        var items = Self.tacoComponents()
        items.removeAll { $0.name == "Lettuce" }
        items.append(Self.food(name: "Wrap", tags: ["lettuce"]))
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource(items))
        let dropped = catalog.scoredResults(for: "lettuce", limit: 1).first
        try #require((dropped?.score ?? Int.max) < FoodItemSearch.minimumBindScore, "fixture must sit below the drop floor")
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
            let aliased = (template.aliasOverrides ?? []).flatMap {
                group($0.alias, template.components + $0.componentOverrides)
            }
            return base + aliased
        }
    }

    /// A four-row in-memory catalog whose names are exact matches for the taco template's four
    /// component queries, so every bind scores in the confident band.
    private static func tacoComponents() -> [FoodItem] {
        [
            food(name: "Cooked beef ground cooked", tags: ["cooked", "beef", "ground"]),
            food(name: "Tortilla corn", tags: ["tortilla", "corn"]),
            food(name: "Cheese shredded", tags: ["cheese", "shredded"]),
            food(name: "Lettuce", tags: ["lettuce"])
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
