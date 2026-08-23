import Foundation
import Testing
import FernletDomainModel

/// The fix-1.14 plausibility + completeness gate: the five internal-consistency checks, the
/// completeness half, the 21 CFR 101.9(j)(4) exemption, and the outer absurdity ceilings.
///
/// The tests that matter most here are the ABSENT-VERSUS-ZERO ones. A gate that treats a field the
/// scanner never read as a claim of zero passes exactly the entries it exists to catch, and the
/// mistake is invisible from the outside: the numbers all look plausible. Every check below that
/// pairs a `nil` case with a `0` case is pinning that distinction down.
struct NutritionPlausibilityTests {

    // MARK: - (a) Non-negativity — FAO/INFOODS 2012

    @Test func negativeValueIsReported() {
        let facts = NutritionFacts(calories: 100, protein: 5, carbs: -3, fat: 2)
        let findings = NutritionPlausibility.checkValuesAreReadableAndNonNegative(facts)
        #expect(findings == [.negativeValue(.carbs, value: -3)])
    }

    @Test func zeroIsNotNegative() {
        let facts = NutritionFacts(calories: 0, protein: 0, carbs: 0, fat: 0)
        #expect(NutritionPlausibility.checkValuesAreReadableAndNonNegative(facts).isEmpty)
    }

    @Test func nonFiniteValueIsUnreadableRatherThanNegative() {
        let facts = NutritionFacts(protein: Double.nan, carbs: Double.infinity)
        let findings = NutritionPlausibility.checkValuesAreReadableAndNonNegative(facts)
        #expect(findings == [.unreadableValue(.protein), .unreadableValue(.carbs)])
    }

    @Test func absentValuesAreNeverCheckedForSign() {
        #expect(NutritionPlausibility.checkValuesAreReadableAndNonNegative(NutritionFacts()).isEmpty)
    }

    @Test func aNegativeValueShortCircuitsTheArithmeticChecks() {
        // 4/4/9 on a negative carb figure would produce a second, meaningless finding.
        let facts = NutritionFacts(calories: 900, protein: 5, carbs: -300, fat: 2)
        let report = NutritionPlausibility.report(for: facts)
        #expect(report.findings == [.negativeValue(.carbs, value: -300)])
        #expect(report.isImplausible)
    }

    // MARK: - (b) Not all zero, and the absent/zero distinction it turns on

    @Test func everyReportedValueZeroIsAFinding() {
        let facts = NutritionFacts(calories: 0, protein: 0, carbs: 0, fat: 0, hasServingSize: true)
        #expect(NutritionPlausibility.report(for: facts).findings == [.allReportedValuesZero])
    }

    @Test func nothingReportedIsIncompleteNotAllZero() {
        // The distinction Rand et al. (1991) insist on: MISSING is not ZERO. A record that reported
        // nothing has not claimed that the food contains nothing.
        let report = NutritionPlausibility.report(for: NutritionFacts())
        #expect(report.findings.isEmpty)
        #expect(report.isIncomplete)
        #expect(report.missingFields == NutritionPlausibility.coreFields)
    }

    @Test func oneNonZeroValueClearsTheAllZeroCheck() {
        let facts = NutritionFacts(calories: 0, protein: 0, carbs: 0, fat: 0, sodium: 140)
        #expect(NutritionPlausibility.checkNotAllZero(facts, exemption: .none).isEmpty)
    }

    // MARK: - The 21 CFR 101.9(j)(4) water/tea exemption

    @Test func waterAndTeaAreExemptFromTheAllZeroRule() {
        let facts = NutritionFacts(calories: 0, protein: 0, carbs: 0, fat: 0, hasServingSize: true)
        #expect(NutritionPlausibility.checkNotAllZero(facts, exemption: .insignificantNutrients).isEmpty)
        #expect(NutritionPlausibility.report(for: facts, exemption: .insignificantNutrients).findings.isEmpty)
    }

    @Test func exemptionCoverageIsPinnedAndHonestlyLimited() {
        // The list is a fixed set of English strings and that is the whole mechanism. Pinned here so
        // it cannot quietly shrink, and so the misses below stay visible as a known ceiling rather
        // than being rediscovered as a bug. Every miss costs one dismissible warning, never a block.
        #expect(NutritionPlausibility.insignificantNutrientNames.count == 15)
        for covered in ["water", "tea", "green tea", "black coffee", "espresso"] {
            #expect(NutritionPlausibility.exemption(forFoodNamed: covered) == .insignificantNutrients)
        }
        // Known, accepted misses: near-neighbours the list does not carry...
        for missed in ["iced tea", "decaf", "hot water", "americano", "chai"] {
            #expect(NutritionPlausibility.exemption(forFoodNamed: missed) == .none)
        }
        // ...and every non-English name, permanently — the list is a frozen matching input, so this
        // is not a gap awaiting translation.
        for foreign in ["agua", "thé", "wasser", "café"] {
            #expect(NutritionPlausibility.exemption(forFoodNamed: foreign) == .none)
        }
    }

    @Test func exemptionResolvesOnWholeNamesOnly() {
        #expect(NutritionPlausibility.exemption(forFoodNamed: "Water") == .insignificantNutrients)
        #expect(NutritionPlausibility.exemption(forFoodNamed: "  green tea ") == .insignificantNutrients)
        #expect(NutritionPlausibility.exemption(forFoodNamed: "Black Coffee") == .insignificantNutrients)
        // Substring matches would wrongly exempt real foods, so matching is on the whole name.
        #expect(NutritionPlausibility.exemption(forFoodNamed: "sweet tea") == .none)
        #expect(NutritionPlausibility.exemption(forFoodNamed: "tea cake") == .none)
        #expect(NutritionPlausibility.exemption(forFoodNamed: "coffee ice cream") == .none)
        #expect(NutritionPlausibility.exemption(forFoodNamed: "") == .none)
    }

    // MARK: - (c) The energy identity — Atwater / 21 CFR 101.9(c)(1)(i)(B)

    @Test func caloriesFarBelowTheMacroSumAreReported() {
        // The lost-decimal-point case: 580 kcal of macros declared as 300. Sugars and fibre are both
        // unreported, so the low-energy target is 4P + 9F + 2C = 200 + 180 + 100 = 480; 300 is
        // outside both windows.
        let facts = NutritionFacts(calories: 300, protein: 50, carbs: 50, fat: 20)
        let findings = NutritionPlausibility.checkEnergyMatchesMacros(facts)
        #expect(findings.count == 1)
        guard case .caloriesDisagreeWithMacros(let declared, let nearest, let tolerance) = findings.first else {
            Issue.record("expected an energy-identity finding, got \(findings)")
            return
        }
        #expect(declared == 300)
        #expect(nearest == 480)          // the closer of the two targets, not an interval end
        #expect(tolerance == 30)         // max(10% of 300, derived floor 13.5)
        #expect(NutritionPlausibility.energyTargets(for: facts) == [480, 580])
    }

    @Test func caloriesExactlyAtTheToleranceEdgePass() {
        // 5P + 5C + 1F. General factors = 20 + 20 + 9 = 49. Derived floor at a >50 kcal declaration:
        // 5 + 4(0.5) + 4(0.5) + 9(0.25) = 11.25, and 10% of 60 is 6, so the window is 49 ± 11.25.
        let base = NutritionFacts(protein: 5, carbs: 5, fat: 1)
        var high = base
        high.calories = 60.25
        var low = base
        low.calories = 52     // still inside the general-factors window; see the low target below
        #expect(NutritionPlausibility.checkEnergyMatchesMacros(high).isEmpty)
        #expect(NutritionPlausibility.checkEnergyMatchesMacros(low).isEmpty)
    }

    @Test func caloriesJustOutsideTheToleranceEdgeFail() {
        // Just past the high window's edge (49 + 11.25 = 60.25), and below the low window's floor
        // (39 − 8.75 = 30.25 at a ≤50 kcal declaration).
        let base = NutritionFacts(protein: 5, carbs: 5, fat: 1)
        var justHigh = base
        justHigh.calories = 60.5
        var wellBelow = base
        wellBelow.calories = 26
        #expect(NutritionPlausibility.checkEnergyMatchesMacros(justHigh).count == 1)
        #expect(NutritionPlausibility.checkEnergyMatchesMacros(wellBelow).count == 1)
    }

    @Test func theTwoTargetsAreSeparateWindowsAndNotTheirHull() {
        // The defect this design replaces: one interval spanning both targets passes EVERYTHING
        // between them, and the gap widens with exactly the foods the second target exists for.
        //
        // 40 g of carbohydrate, 30 g of it fibre: the two permitted calculations give 80 and 160
        // kcal. A hull would run 68…172 and wave through every value in between; two windows of
        // ±12 leave 92…148 live.
        var facts = NutritionFacts(calories: 80, protein: 0, carbs: 40, fat: 0, fiber: 30)
        #expect(NutritionPlausibility.energyTargets(for: facts) == [80, 160])
        #expect(NutritionPlausibility.checkEnergyMatchesMacros(facts).isEmpty)
        facts.calories = 160
        #expect(NutritionPlausibility.checkEnergyMatchesMacros(facts).isEmpty)
        // Matches NEITHER calculation. Inside the hull, outside both windows — this is the case a
        // single-interval band returns fully clean.
        facts.calories = 120
        #expect(NutritionPlausibility.checkEnergyMatchesMacros(facts).count == 1)

        // The same shape at supplement scale: targets 16 and 32, honest declaration 20, and a
        // calorie figure that lost its decimal point reads 2.
        let supplement = NutritionFacts(calories: 20, protein: 0, carbs: 8, fat: 0, fiber: 6)
        #expect(NutritionPlausibility.energyTargets(for: supplement) == [16, 32])
        #expect(NutritionPlausibility.checkEnergyMatchesMacros(supplement).isEmpty)
        var mistyped = supplement
        mistyped.calories = 2
        #expect(NutritionPlausibility.checkEnergyMatchesMacros(mistyped).count == 1)
    }

    @Test func sugarAlcoholProductsPassWithoutAPolyolField() {
        // 15 g of maltitol declares 15 g carbohydrate, 0 g sugars, no fibre and about 35 kcal
        // (maltitol's own factor is 2.1 cal/g under 21 CFR 101.9(c)(1)(i)(F)). The parser has no
        // polyol field, so the unaccounted carbohydrate carries THIS GATE'S 2.0 kcal/g midpoint of
        // that per-polyol table — not a "general factor", which the regulation does not give for an
        // unlisted polyol: the low target is 30, and 35 is inside its window.
        let facts = NutritionFacts(calories: 35, protein: 0, carbs: 15, fat: 0, sugar: 0)
        #expect(NutritionPlausibility.energyTargets(for: facts) == [30, 60])
        #expect(NutritionPlausibility.checkEnergyMatchesMacros(facts).isEmpty)
        // And its lost decimal still fires.
        var mistyped = facts
        mistyped.calories = 3.5
        #expect(NutritionPlausibility.checkEnergyMatchesMacros(mistyped).count == 1)
    }

    // MARK: - The derived rounding floor (21 CFR 101.9 declaration increments)

    @Test func roundingSlackFollowsTheRegulationsTwoRegimes() {
        // Calories: 5-cal increments up to and including 50, 10-cal above — so ±2.5 then ±5.
        #expect(NutritionPlausibility.calorieRoundingSlackKcal(declaredCalories: 40) == 2.5)
        #expect(NutritionPlausibility.calorieRoundingSlackKcal(declaredCalories: 50) == 2.5)
        #expect(NutritionPlausibility.calorieRoundingSlackKcal(declaredCalories: 50.5) == 5)
        // Fat, 21 CFR 101.9(c)(2): 0.5-g increments below 5 g, 1-g increments above — ±0.25 then ±0.5.
        #expect(NutritionPlausibility.declarationSlackGrams(
            forGrams: 4.9, regime: .halfGramIncrementsBelowFiveGrams) == 0.25)
        #expect(NutritionPlausibility.declarationSlackGrams(
            forGrams: 5, regime: .halfGramIncrementsBelowFiveGrams) == 0.5)
        // Carbohydrate (c)(6) and protein (c)(7) are "expressed to the nearest gram" at EVERY
        // amount — no small-amount half-gram tier — so a flat ±0.5 g. Reading the fat rule onto them
        // is the defect this regime parameter exists to prevent; a 1 g protein figure is ±0.5, not
        // ±0.25.
        #expect(NutritionPlausibility.declarationSlackGrams(forGrams: 0, regime: .nearestGram) == 0.5)
        #expect(NutritionPlausibility.declarationSlackGrams(forGrams: 1, regime: .nearestGram) == 0.5)
        #expect(NutritionPlausibility.declarationSlackGrams(forGrams: 4.9, regime: .nearestGram) == 0.5)
        #expect(NutritionPlausibility.declarationSlackGrams(forGrams: 30, regime: .nearestGram) == 0.5)
        // Worked totals for the two CALORIE regimes, exactly as the doc comment derives them. The
        // small one is 2.5 + 4(0.5) + 4(0.5) + 9(0.25): only the fat term drops to a quarter gram.
        #expect(NutritionPlausibility.declarationRoundingSlackKcal(
            declaredCalories: 40, protein: 1, carbs: 1, fat: 1) == 8.75)
        #expect(NutritionPlausibility.declarationRoundingSlackKcal(
            declaredCalories: 300, protein: 10, carbs: 30, fat: 8) == 13.5)
    }

    @Test func theFloorDoesNotSwallowALargeRelativeErrorOnASmallServing() {
        // The regression this derivation replaces: a flat 15-kcal floor let a 50-kcal item be wrong
        // by 30% and pass. 2P + 4C + 1F = 33 kcal; declared 43 is 30% high and now fires.
        //
        // This is also the case that keeps the (c)(6)/(c)(7) nearest-gram regime honest: every macro
        // here is under 5 g, so the floor is the widest it ever gets on a small serving —
        // 2.5 + 4(0.5) + 4(0.5) + 9(0.25) = 8.75 kcal — and the 10-kcal error still clears it. The
        // floor is pinned rather than merely implied, because reading the fat rule onto protein and
        // carbohydrate would narrow it to 6.75 without flipping this assertion.
        let facts = NutritionFacts(calories: 43, protein: 2, carbs: 4, fat: 1, sugar: 4)
        #expect(NutritionPlausibility.energyTargets(for: facts) == [33, 33])
        #expect(NutritionPlausibility.declarationRoundingSlackKcal(
            declaredCalories: 43, protein: 2, carbs: 4, fat: 1) == 8.75)
        #expect(NutritionPlausibility.checkEnergyMatchesMacros(facts).count == 1)
    }

    @Test func caloriesReportedAsZeroWithRealMacrosIsAFinding() {
        // The OCR failure this check exists for: the calories line was misread as 0 while the macros
        // came through. A zero here is a CLAIM, and it contradicts 165 kcal of macros.
        let facts = NutritionFacts(calories: 0, protein: 10, carbs: 20, fat: 5)
        #expect(NutritionPlausibility.checkEnergyMatchesMacros(facts).count == 1)
    }

    @Test func absentCaloriesAreNotEvaluatedAgainstMacros() {
        // Same food, but the calories line was never read. Absent is not a claim, so the identity
        // stands down and the completeness half names the gap instead.
        let facts = NutritionFacts(protein: 10, carbs: 20, fat: 5, hasServingSize: true)
        #expect(NutritionPlausibility.checkEnergyMatchesMacros(facts).isEmpty)
        #expect(NutritionPlausibility.report(for: facts).missingFields == [.calories])
    }

    @Test func absentMacroStandsTheIdentityDownRatherThanCountingAsZero() {
        // Only protein was read. Substituting 0 for carbs and fat would manufacture a 660-kcal
        // disagreement out of missing data.
        let facts = NutritionFacts(calories: 700, protein: 10)
        #expect(NutritionPlausibility.checkEnergyMatchesMacros(facts).isEmpty)
        #expect(NutritionPlausibility.report(for: facts).missingFields == [.servingSize, .carbs, .fat])
    }

    @Test func highFibreFoodsPassAtEitherPermittedTarget() {
        // 3P + 40C (30 g of it fibre) + 1F: general factors give 181 kcal, and the low-energy
        // carbohydrate method gives 101. Both are permitted calculations, so both pass.
        var facts = NutritionFacts(calories: 101, protein: 3, carbs: 40, fat: 1, fiber: 30)
        #expect(NutritionPlausibility.energyTargets(for: facts) == [101, 181])
        #expect(NutritionPlausibility.checkEnergyMatchesMacros(facts).isEmpty)
        facts.calories = 181
        #expect(NutritionPlausibility.checkEnergyMatchesMacros(facts).isEmpty)
    }

    @Test func theStatedFalsePositiveOnAZeroFactorFibreLabelIsPinned() {
        // The documented, bounded cost of two narrow windows: a label that computed the same food
        // with the low-energy bucket at 0 kcal/g rather than 2 lands between them (61 kcal here) and
        // draws a dismissible warning. Pinned so the trade-off is visible rather than discovered.
        let facts = NutritionFacts(calories: 61, protein: 3, carbs: 40, fat: 1, fiber: 30)
        #expect(NutritionPlausibility.checkEnergyMatchesMacros(facts).count == 1)
    }

    // MARK: - (d) Total fat covers its reported fractions — FAO/INFOODS 2012, Haytowitz 2009 Tbl. 4

    @Test func fattyAcidFractionsExceedingTotalFatAreReported() {
        let facts = NutritionFacts(fat: 10, saturatedFat: 8, transFat: 5)
        let findings = NutritionPlausibility.checkFatCoversItsFractions(facts)
        #expect(findings == [.fatBelowReportedFractions(totalFat: 10, fractionSum: 13)])
    }

    @Test func fatFractionSumExactlyAtTheRoundingSlackPasses() {
        // Two reported fractions plus the total: 0.5 g of declaration slack each = 1.5 g.
        let atBoundary = NutritionFacts(fat: 10, saturatedFat: 6.5, transFat: 5)
        let justOver = NutritionFacts(fat: 10, saturatedFat: 6.6, transFat: 5)
        #expect(NutritionPlausibility.checkFatCoversItsFractions(atBoundary).isEmpty)
        #expect(NutritionPlausibility.checkFatCoversItsFractions(justOver).count == 1)
    }

    @Test func absentFractionsContributeNothingToTheFatSum() {
        let facts = NutritionFacts(fat: 1, saturatedFat: 1)
        #expect(NutritionPlausibility.checkFatCoversItsFractions(facts).isEmpty)
        // With no fraction reported at all there is nothing to compare against.
        #expect(NutritionPlausibility.checkFatCoversItsFractions(NutritionFacts(fat: 1)).isEmpty)
        // And with no total fat reported, reported fractions raise no finding either.
        #expect(NutritionPlausibility.checkFatCoversItsFractions(NutritionFacts(saturatedFat: 40)).isEmpty)
    }

    // MARK: - (e) Total carbohydrate covers its components — Rand et al. 1991, 21 CFR 101.9(c)(6)

    @Test func fibreAndSugarsExceedingTotalCarbsAreReported() {
        let facts = NutritionFacts(carbs: 20, fiber: 12, sugar: 14)
        let findings = NutritionPlausibility.checkCarbsCoverTheirComponents(facts)
        #expect(findings == [.carbsBelowReportedComponents(totalCarbs: 20, componentSum: 26)])
    }

    @Test func carbComponentSumExactlyAtTheRoundingSlackPasses() {
        let atBoundary = NutritionFacts(carbs: 20, fiber: 12.5, sugar: 9)
        let justOver = NutritionFacts(carbs: 20, fiber: 12.6, sugar: 9)
        #expect(NutritionPlausibility.checkCarbsCoverTheirComponents(atBoundary).isEmpty)
        #expect(NutritionPlausibility.checkCarbsCoverTheirComponents(justOver).count == 1)
    }

    @Test func absentCarbComponentsContributeNothing() {
        #expect(NutritionPlausibility.checkCarbsCoverTheirComponents(NutritionFacts(carbs: 0)).isEmpty)
        #expect(NutritionPlausibility.checkCarbsCoverTheirComponents(NutritionFacts(fiber: 90)).isEmpty)
    }

    // MARK: - The outer absurdity guard (Evenepoel 2020) — a backstop, not a standard

    @Test func portionCeilingsFireOnlyAboveTheCeiling() {
        #expect(NutritionPlausibility.checkPortionCeilings(NutritionFacts(calories: 1_500)).isEmpty)
        let over = NutritionPlausibility.checkPortionCeilings(NutritionFacts(calories: 1_500.1))
        #expect(over == [.exceedsPortionCeiling(.calories, value: 1_500.1, ceiling: 1_500)])
    }

    @Test func everyPublishedCeilingIsCarried() {
        let expected: [NutrientField: Double] = [
            .calories: 1_500, .carbs: 95, .fat: 92, .protein: 52,
            .fiber: 22, .sugar: 70, .cholesterol: 600, .sodium: 3_600,
        ]
        #expect(NutritionPlausibility.portionCeilings.count == expected.count)
        for entry in NutritionPlausibility.portionCeilings {
            #expect(expected[entry.field] == entry.ceiling)
        }
    }

    @Test func ceilingsCannotSeeAnAbsentValue() {
        // The structural reason the ceilings are an outer guard and not the gate: an upper bound is
        // blind to omission. Nothing reported, nothing to exceed.
        #expect(NutritionPlausibility.checkPortionCeilings(NutritionFacts()).isEmpty)
    }

    @Test func ceilingFindingsAreAdvisoryAndArithmeticOnesAreNot() {
        // A curve-fitted ceiling must never be presented as a contradiction in the user's numbers;
        // the split is what lets the UI title the two differently.
        #expect(NutritionPlausibilityFinding.exceedsPortionCeiling(.sodium, value: 4_000, ceiling: 3_600).isAdvisory)
        #expect(!NutritionPlausibilityFinding.allReportedValuesZero.isAdvisory)
        #expect(!NutritionPlausibilityFinding.negativeValue(.fat, value: -1).isAdvisory)
        #expect(!NutritionPlausibilityFinding.unreadableValue(.fat).isAdvisory)
        #expect(!NutritionPlausibilityFinding.caloriesDisagreeWithMacros(declared: 1, nearestTarget: 2, tolerance: 0).isAdvisory)
        #expect(!NutritionPlausibilityFinding.fatBelowReportedFractions(totalFat: 1, fractionSum: 9).isAdvisory)
        #expect(!NutritionPlausibilityFinding.carbsBelowReportedComponents(totalCarbs: 1, componentSum: 9).isAdvisory)
    }

    @Test func aCeilingAloneIsAdvisoryAndDoesNotMakeARecordImplausible() {
        // 60 g of protein in one serving trips the outer ceiling, but 4/4/9 is satisfied and nothing
        // contradicts. The record needs a look; it is not broken.
        let facts = NutritionFacts(calories: 240, protein: 60, carbs: 0, fat: 0, sugar: 0, hasServingSize: true)
        let report = NutritionPlausibility.report(for: facts)
        #expect(report.contradictions.isEmpty)
        #expect(report.advisories.count == 1)
        #expect(!report.isImplausible)
        #expect(report.needsReview)
    }

    @Test func contradictionsAndAdvisoriesPartitionTheFindings() {
        let facts = NutritionFacts(calories: 100, protein: 60, carbs: 1, fat: 1, hasServingSize: true)
        let report = NutritionPlausibility.report(for: facts)
        #expect(report.contradictions.count + report.advisories.count == report.findings.count)
        #expect(!report.contradictions.isEmpty)
        #expect(!report.advisories.isEmpty)
        // Check order puts the arithmetic ahead of the heuristic, so a truncated list keeps the
        // important half.
        #expect(report.findings.last?.isAdvisory == true)
    }

    // MARK: - Truncation is never silent

    @Test func truncatedFindingListsSayHowManyWereHidden() {
        let findings: [NutritionPlausibilityFinding] = [
            .allReportedValuesZero,
            .fatBelowReportedFractions(totalFat: 1, fractionSum: 9),
            .carbsBelowReportedComponents(totalCarbs: 1, componentSum: 9),
            .exceedsPortionCeiling(.sodium, value: 4_000, ceiling: 3_600),
            .exceedsPortionCeiling(.sugar, value: 90, ceiling: 70),
        ]
        let message = NutritionPlausibilityReport.message(for: findings, limit: 3)
        #expect(message?.contains("2") == true)
        #expect(message?.split(separator: "\n").count == 4)   // three findings plus the tail
        // Nothing hidden means no tail at all.
        let short = NutritionPlausibilityReport.message(for: Array(findings.prefix(2)), limit: 3)
        #expect(short?.split(separator: "\n").count == 2)
        #expect(NutritionPlausibilityReport.message(for: [], limit: 3) == nil)
        #expect(NutritionPlausibilityReport.message(for: findings, limit: 0) == nil)
    }

    // MARK: - Completeness

    @Test func missingCoreFieldsMatchesTheDeclaredCoreFieldList() {
        // Pins the hand-written checks in `missingCoreFields` to the public `coreFields` list, in
        // order, so the two cannot drift apart.
        #expect(NutritionPlausibility.missingCoreFields(NutritionFacts()) == NutritionPlausibility.coreFields)
    }

    @Test func aZeroIsReportedDataAndNeverCountsAsMissing() {
        let facts = NutritionFacts(calories: 0, protein: 0, carbs: 0, fat: 0, hasServingSize: true)
        #expect(NutritionPlausibility.missingCoreFields(facts).isEmpty)
    }

    @Test func partialScanNamesExactlyWhatIsMissing() {
        let facts = NutritionFacts(protein: 8, fat: 3, hasServingSize: true)
        #expect(NutritionPlausibility.missingCoreFields(facts) == [.calories, .carbs])
    }

    @Test func aCompleteConsistentFoodProducesACleanReport() {
        let facts = NutritionFacts(
            calories: 165, protein: 10, carbs: 20, fat: 5,
            saturatedFat: 2, fiber: 3, sugar: 6, sodium: 210, hasServingSize: true
        )
        let report = NutritionPlausibility.report(for: facts)
        #expect(report == .clean)
        #expect(!report.needsReview)
    }

    @Test func needsReviewCoversBothHalvesOfTheGate() {
        let incomplete = NutritionPlausibility.report(for: NutritionFacts(protein: 8, hasServingSize: true))
        #expect(!incomplete.isImplausible)
        #expect(incomplete.isIncomplete)
        #expect(incomplete.needsReview)

        let implausible = NutritionPlausibility.report(for: NutritionFacts(
            calories: 100, protein: 1, carbs: 1, fat: 1, hasServingSize: true
        ))
        #expect(implausible.isImplausible)
        #expect(!implausible.isIncomplete)
        #expect(implausible.needsReview)
    }

    @Test func missingFieldsMessageNamesTheFieldsOrIsAbsent() {
        let complete = NutritionPlausibilityReport(findings: [], missingFields: [])
        #expect(complete.missingFieldsMessage == nil)
        let partial = NutritionPlausibilityReport(findings: [], missingFields: [.calories, .fat])
        let message = partial.missingFieldsMessage
        #expect(message?.contains(NutrientField.calories.displayName) == true)
        #expect(message?.contains(NutrientField.fat.displayName) == true)
    }

    // MARK: - Frozen tokens

    @Test func nutrientFieldTokensAreFrozenEnglish() {
        // These rawValues are matching/diagnostic identifiers, not display text. Editing one is a
        // silent break for anything that matched on it, so the wall is here rather than in review.
        #expect(NutrientField.calories.rawValue == "calories")
        #expect(NutrientField.protein.rawValue == "protein")
        #expect(NutrientField.carbs.rawValue == "carbs")
        #expect(NutrientField.fat.rawValue == "fat")
        #expect(NutrientField.saturatedFat.rawValue == "saturatedFat")
        #expect(NutrientField.transFat.rawValue == "transFat")
        #expect(NutrientField.polyunsaturatedFat.rawValue == "polyunsaturatedFat")
        #expect(NutrientField.monounsaturatedFat.rawValue == "monounsaturatedFat")
        #expect(NutrientField.fiber.rawValue == "fiber")
        #expect(NutrientField.sugar.rawValue == "sugar")
        #expect(NutrientField.sodium.rawValue == "sodium")
        #expect(NutrientField.cholesterol.rawValue == "cholesterol")
        #expect(NutrientField.servingSize.rawValue == "servingSize")
        #expect(NutrientField.allCases.count == 13)
    }

    @Test func exemptionTokensAreFrozenEnglish() {
        #expect(NutrientSignificanceExemption.none.rawValue == "none")
        #expect(NutrientSignificanceExemption.insignificantNutrients.rawValue == "insignificantNutrients")
    }

    // MARK: - The CustomIngredientUpsert seam

    @Test func upsertSeamReportsAnUntouchedRowAsAllZero() {
        var ingredient = ManualRecipeIngredientInput()
        ingredient.name = "Mystery bar"
        let report = CustomIngredientUpsert.plausibility(of: ingredient)
        #expect(report.findings == [.allReportedValuesZero])
        #expect(report.needsReview)
    }

    @Test func upsertSeamPassesAConsistentHandTypedRow() {
        var ingredient = ManualRecipeIngredientInput()
        ingredient.name = "House tofu crumble"
        ingredient.quantity = 125
        ingredient.protein = 18
        ingredient.carbs = 6
        ingredient.fat = 9
        // No declared calories: `Macros.calories` is derived 4/4/9, so the identity would compare a
        // number with itself. The energy check correctly stands down.
        let report = CustomIngredientUpsert.plausibility(of: ingredient)
        #expect(report.findings.isEmpty)
        // And completeness is NOT reported at this seam: the editor row cannot express absence, so a
        // gap list here would say the same thing about every row ever saved.
        #expect(report.missingFields.isEmpty)
        #expect(report == .clean)
    }

    @Test func completenessScopeDecidesWhetherGapsAreReportedAtAll() {
        let facts = NutritionFacts(protein: 8, hasServingSize: false)
        #expect(NutritionPlausibility.missingFields(facts, scope: .corePanel)
                == [.servingSize, .calories, .carbs, .fat])
        #expect(NutritionPlausibility.missingFields(facts, scope: .notApplicable).isEmpty)
        #expect(NutritionPlausibility.report(for: facts, completeness: .notApplicable).isIncomplete == false)
        #expect(NutritionPlausibility.report(for: facts, completeness: .corePanel).isIncomplete)
        #expect(NutritionCompletenessScope.corePanel.rawValue == "corePanel")
        #expect(NutritionCompletenessScope.notApplicable.rawValue == "notApplicable")
    }

    @Test func upsertSeamCatchesAScannedPanelThatContradictsItself() {
        var ingredient = ManualRecipeIngredientInput()
        ingredient.name = "Granola"
        ingredient.quantity = 1
        ingredient.protein = 5
        ingredient.carbs = 30
        ingredient.fat = 10
        ingredient.scannedMicronutrients = Micronutrients(fiber: 20, sugar: 18)
        let report = CustomIngredientUpsert.plausibility(of: ingredient, declaredCalories: 230)
        #expect(report.findings == [.carbsBelowReportedComponents(totalCarbs: 30, componentSum: 38)])
    }

    @Test func upsertSeamHonoursTheInsignificantNutrientExemption() {
        var ingredient = ManualRecipeIngredientInput()
        ingredient.name = "Water"
        ingredient.quantity = 1
        #expect(CustomIngredientUpsert.plausibility(of: ingredient).findings.isEmpty)
    }

    @Test func upsertSeamPreservesTheDomainAdapterUnits() {
        var ingredient = ManualRecipeIngredientInput()
        ingredient.name = "Salted crackers"
        ingredient.quantity = 1
        ingredient.protein = 2
        ingredient.carbs = 11
        ingredient.fat = 3
        ingredient.scannedMicronutrients = Micronutrients(sodium: 3_700)
        // Sodium is milligrams on both sides of the adapter, so the 3,600 mg outer ceiling fires.
        let report = CustomIngredientUpsert.plausibility(of: ingredient)
        #expect(report.findings == [.exceedsPortionCeiling(.sodium, value: 3_700, ceiling: 3_600)])
    }
}
