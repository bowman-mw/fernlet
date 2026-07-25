import Testing
import Foundation
@testable import FernletDomainModel
import FernletScoring
import AppServices

/// F2 DV-table reconciliation (§3.6): the single shared `FDADailyValues` table, both
/// consumers reading it, and the pinned "the change can only lower scores" direction note.
@MainActor
struct FDADailyValuesTests {

    @Test func sharedTableCarriesVerifiedFDAValues() {
        // The two "update" rows (§3.6) and a sample of the "keep" rows.
        #expect(FDADailyValues.calciumMilligrams == 1_300)   // was 1,000 (stale NASEM)
        #expect(FDADailyValues.potassiumMilligrams == 4_700) // was 3,400 (stale NASEM)
        #expect(FDADailyValues.fiberGrams == 28)
        #expect(FDADailyValues.vitaminCMilligrams == 90)
        #expect(FDADailyValues.vitaminDMicrograms == 20)
        #expect(FDADailyValues.vitaminB12Micrograms == 2.4)
        #expect(FDADailyValues.folateMicrogramsDFE == 400)
        #expect(FDADailyValues.ironMilligrams == 18)
        #expect(FDADailyValues.magnesiumMilligrams == 420)
        #expect(FDADailyValues.zincMilligrams == 11)
        // FDA has no omega-3 DV — kept as the NASEM ALA Adequate Intake.
        #expect(FDADailyValues.omega3ALAGrams == 1.6)
        // Limit-style DRVs.
        #expect(FDADailyValues.sodiumLimitMilligrams == 2_300)
        #expect(FDADailyValues.saturatedFatLimitGrams == 20)
        #expect(FDADailyValues.addedSugarsLimitGrams == 50)
    }

    @Test func trackedNutrientsReadTheSharedTable() {
        func amount(_ key: String) -> Double? {
            MicronutrientGapAnalyzer.trackedNutrients.first { $0.key == key }?.recommendedDailyAmount
        }
        // Consumer 1: the gap analyzer now matches the shared table exactly.
        #expect(amount("calcium") == FDADailyValues.calciumMilligrams)
        #expect(amount("potassium") == FDADailyValues.potassiumMilligrams)
        #expect(amount("fiber") == FDADailyValues.fiberGrams)
        #expect(amount("vitaminC") == FDADailyValues.vitaminCMilligrams)
        #expect(amount("vitaminD") == FDADailyValues.vitaminDMicrograms)
        #expect(amount("vitaminB12") == FDADailyValues.vitaminB12Micrograms)
        #expect(amount("folate") == FDADailyValues.folateMicrogramsDFE)
        #expect(amount("iron") == FDADailyValues.ironMilligrams)
        #expect(amount("magnesium") == FDADailyValues.magnesiumMilligrams)
        #expect(amount("zinc") == FDADailyValues.zincMilligrams)
        #expect(amount("omega3") == FDADailyValues.omega3ALAGrams)
    }

    @Test func scannerBackSolvesFromTheSameTable() {
        // Consumer 2: the label scanner back-solves a printed "%DV" using the same table.
        // No explicit mg on the line, so the %DV path (not the absolute path) is exercised.
        let result = NutritionLabelScanner.parse(lines: [
            "Calcium 10%",
            "Potassium 20%"
        ])
        #expect(result.calcium == FDADailyValues.calciumMilligrams * 0.10)     // 130
        #expect(result.potassium == FDADailyValues.potassiumMilligrams * 0.20) // 940
    }

    @Test func raisedDenominatorsDropPotassiumOutOfCovered() {
        // A fixed potassium intake the STALE DV (3,400) called "covered" is no longer
        // covered under the FDA DV (4,700): 2,000/day over 14 days →
        //   old ratio = 28000 / (3400*14) = 0.588  (>= 0.5 → covered)
        //   new ratio = 28000 / (4700*14) = 0.4255 (0.25 < r < 0.5 → neither → dropped)
        // Calcium stays a gap but deeper: 200/day → old 0.20, new 0.1538 (both < 0.25).
        let days: [(String, FernletDay)] = (1...14).map { d in
            let key = "2026-05-\(String(format: "%02d", d))"
            let meal = Meal(
                name: "Test", mealType: .lunch, macros: Macros(protein: 20, carbs: 30, fat: 10),
                micronutrientSnapshot: Micronutrients(fiber: 14, vitaminC: 90, calcium: 200, iron: 9, potassium: 2000),
                quality: .good, confidence: "Manual", note: "", source: "Manual"
            )
            return (key, FernletDay(date: key, meals: [meal]))
        }
        let gaps = MicronutrientGapAnalyzer.gaps(from: days, windowDays: 14)

        // Potassium is no longer covered under the raised denominator (dropped entirely).
        #expect(gaps.contains { $0.nutrientKey == "potassium" } == false)
        let potassiumOldRatio = (2000.0 * 14) / (3_400 * 14)
        #expect(potassiumOldRatio >= 0.5) // it WOULD have been covered before — direction is down.

        // Calcium is a gap and its coverage ratio is lower than under the stale DV.
        let calcium = gaps.first { $0.nutrientKey == "calcium" }
        #expect(calcium?.status == .gap)
        let calciumNewRatio = (200.0 * 14) / (FDADailyValues.calciumMilligrams * 14)
        let calciumOldRatio = (200.0 * 14) / (1_000 * 14)
        #expect(calciumNewRatio < calciumOldRatio)
    }

    @Test func modifierMovesOnlyDownwardAndRespectsCaps() {
        func covered(_ key: String) -> NutrientGap {
            NutrientGap(nutrientKey: key, nutrientName: key, unit: "mg", windowDays: 7, coverageRatio: 0.9, dataCoverageRatio: 1.0, status: .covered)
        }
        func gap(_ key: String) -> NutrientGap {
            NutrientGap(nutrientKey: key, nutrientName: key, unit: "mg", windowDays: 7, coverageRatio: 0.1, dataCoverageRatio: 1.0, status: .gap)
        }
        // Removing a nutrient from the covered set (what raising a DV does) lowers the bonus.
        let withPotassium = [covered("vitaminC"), covered("iron"), covered("potassium")]
        let withoutPotassium = [covered("vitaminC"), covered("iron")]
        #expect(FernletScoring.micronutrientModifier(from: withoutPotassium)
                < FernletScoring.micronutrientModifier(from: withPotassium))

        // Caps hold: many covered → +0.03 max, many gaps → −0.05 max.
        let manyCovered = ["a", "b", "c", "d", "e"].map(covered)
        let manyGaps = ["a", "b", "c", "d", "e"].map(gap)
        #expect(FernletScoring.micronutrientModifier(from: manyCovered) == 0.03)
        #expect(FernletScoring.micronutrientModifier(from: manyGaps) == -0.05)
    }
}
