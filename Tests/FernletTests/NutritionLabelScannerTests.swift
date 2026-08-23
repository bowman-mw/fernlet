import Foundation
import Testing
@testable import Fernlet

#if canImport(UIKit)
import UIKit
import FernletDomainModel
import AppServices

struct NutritionLabelScannerTests {
    @MainActor
    @Test func recognizeTextStartsVisionWorkOffMainThread() async throws {
        let image = Self.diagnosticNutritionLabelImage()
        let capture = ThreadCapture()

        _ = try await NutritionLabelScanner.recognizeText(in: image) {
            capture.record(isMainThread: Thread.isMainThread)
        }

        #expect(capture.value == false)
    }

    @MainActor
    @Test func parsesStandardUSLabel() {
        let lines = [
            "Nutrition Facts",
            "Serving size 2/3 cup (55g)",
            "Servings per container 8",
            "Amount per serving",
            "Calories 230",
            "Total Fat 8g",
            "Saturated Fat 1g",
            "Trans Fat 0g",
            "Cholesterol 0mg",
            "Sodium 160mg",
            "Total Carbohydrate 37g",
            "Dietary Fiber 4g",
            "Total Sugars 12g",
            "Protein 3g",
            "Vitamin D 2mcg",
            "Calcium 260mg",
            "Iron 8mg",
            "Potassium 235mg"
        ]

        let result = NutritionLabelScanner.parse(lines: lines)

        #expect(result.servingSize == "2/3 cup (55g)")
        #expect(result.servingsPerContainer == 8)
        #expect(result.calories == 230)
        #expect(result.fat == 8)
        #expect(result.saturatedFat == 1.0)
        #expect(result.transFat == 0.0)
        #expect(result.cholesterol == 0.0)
        #expect(result.sodium == 160.0)
        #expect(result.carbs == 37)
        #expect(result.fiber == 4.0)
        #expect(result.sugar == 12.0)
        #expect(result.protein == 3)
        #expect(result.vitaminD == 2.0)
        #expect(result.calcium == 260.0)
        #expect(result.iron == 8.0)
        #expect(result.potassium == 235.0)
    }

    @MainActor
    @Test func ignoresDailyValuePercentages() {
        let result = NutritionLabelScanner.parse(lines: [
            "Serving size 1 cup (240ml)",
            "Calories 150",
            "Total Fat 8g 10%",
            "Saturated Fat 5g 25%",
            "Sodium 105mg 5%",
            "Total Carbohydrate 13g 5%",
            "Protein 8g",
            "Calcium 300mg 25%"
        ])

        #expect(result.fat == 8)
        #expect(result.saturatedFat == 5.0)
        #expect(result.sodium == 105.0)
        #expect(result.carbs == 13)
        #expect(result.protein == 8)
        #expect(result.calcium == 300.0)
    }

    @MainActor
    @Test func handlesDecimalAndSpacedUnits() {
        let result = NutritionLabelScanner.parse(lines: [
            "Total Fat 2.5g",
            "Dietary Fiber 0.5g",
            "Protein 25 g",
            "Sodium 480 mg",
            "Iron 1.8mg"
        ])

        #expect(result.fat == 3)
        #expect(result.fiber == 0.5)
        #expect(result.protein == 25)
        #expect(result.sodium == 480.0)
        #expect(result.iron == 1.8)
    }

    @MainActor
    @Test func convertsMicronutrients() {
        var result = NutritionLabelResult()
        result.fiber = 4.0
        result.sodium = 160.0
        result.calcium = 260.0
        result.iron = 8.0
        result.vitaminD = 2.0
        result.vitaminC = 15.0
        result.niacin = 16.0
        result.phosphorus = 125.0

        let micronutrients = result.micronutrients()

        #expect(micronutrients.fiber == 4.0)
        #expect(micronutrients.sodium == 160.0)
        #expect(micronutrients.calcium == 260.0)
        #expect(micronutrients.iron == 8.0)
        #expect(micronutrients.vitaminD == 2.0)
        #expect(micronutrients.vitaminC == 15.0)
        #expect(micronutrients.niacin == 16.0)
        #expect(micronutrients.phosphorus == 125.0)
        #expect(micronutrients.sugar == nil)
        #expect(micronutrients.zinc == nil)
        #expect(micronutrients.omega3 == nil)
    }

    @MainActor
    @Test func ignoresUnrelatedText() {
        let result = NutritionLabelScanner.parse(lines: [
            "Best Before: 12/25",
            "Store in a cool dry place",
            "Made in USA"
        ])

        #expect(result.protein == nil)
        #expect(result.carbs == nil)
        #expect(result.fat == nil)
    }

    @MainActor
    @Test func parsesHyphenatedVitaminB12() {
        let result = NutritionLabelScanner.parse(lines: ["Vitamin B-12 2.4mcg"])

        #expect(result.vitaminB12 == 2.4)
    }

    @MainActor
    @Test func convertsDailyValueOnlyVitaminC() {
        let result = NutritionLabelScanner.parse(lines: ["Vitamin C 15%"])

        #expect(result.vitaminC == 13.5)
    }

    @MainActor
    @Test func prefersAbsoluteValueOverDailyValue() {
        let result = NutritionLabelScanner.parse(lines: ["Calcium 260mg 20%"])

        #expect(result.calcium == 260.0)
    }

    @MainActor
    @Test func parsesAddedSugars() {
        let result = NutritionLabelScanner.parse(lines: ["Added Sugars 12g"])

        #expect(result.addedSugar == 12.0)
    }

    @MainActor
    @Test func parsesTransFatZero() {
        let result = NutritionLabelScanner.parse(lines: ["Trans Fat 0g"])

        #expect(result.transFat == 0.0)
    }

    @MainActor
    @Test func parsesOmega3MilligramsAsGrams() {
        let result = NutritionLabelScanner.parse(lines: ["Omega-3 500mg"])

        #expect(result.omega3 == 0.5)
    }

    @MainActor
    @Test func parsesAdditionalFortificationNutrients() {
        let result = NutritionLabelScanner.parse(lines: [
            "Niacin 16mg",
            "Thiamin 0.6mg",
            "Riboflavin 0.65mg",
            "Phosphorus 125mg"
        ])

        #expect(result.niacin == 16.0)
        #expect(result.thiamin == 0.6)
        #expect(result.riboflavin == 0.65)
        #expect(result.phosphorus == 125.0)
    }

    @MainActor
    @Test func fuzzyMatchesCommonOCRErrors() {
        let result = NutritionLabelScanner.parse(lines: [
            "Totai Fat 8g",
            "Sodiurn 480mg",
            "Vitarnin D 2mcg",
            "lron 8mg"
        ])

        #expect(result.fat == 8)
        #expect(result.sodium == 480.0)
        #expect(result.vitaminD == 2.0)
        #expect(result.iron == 8.0)
    }

    @MainActor
    @Test func recoversSplitSaturatedFatValue() {
        let result = NutritionLabelScanner.parse(lines: [
            "Saturated Fat",
            "3g"
        ])

        #expect(result.saturatedFat == 3.0)
    }

    @MainActor
    @Test func recoversSplitCaloriesValue() {
        let result = NutritionLabelScanner.parse(lines: [
            "Calories",
            "Total Fat 7g",
            "Total Carbohydrate 18g",
            "180"
        ])

        #expect(result.calories == 180)
    }

    @MainActor
    @Test func capsSaturatedFatAtTotalFat() {
        let result = NutritionLabelScanner.parse(lines: [
            "Total Fat 10g",
            "Saturated Fat 15g"
        ])

        #expect(result.fat == 10)
        #expect(result.saturatedFat == 10.0)
    }

    private static func diagnosticNutritionLabelImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 160))
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 160))

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24, weight: .semibold),
                .foregroundColor: UIColor.black
            ]
            NSString(string: "Nutrition Facts\nCalories 120\nProtein 8g").draw(
                in: CGRect(x: 18, y: 18, width: 284, height: 124),
                withAttributes: attributes
            )
        }
    }
}

/// The fix-1.14 gate as it sees an OCR result: absent stays absent all the way from the scanner's
/// optionals into ``NutritionFacts``, so a label line the scanner never read is never mistaken for a
/// claim that the product contains none of that nutrient.
struct NutritionLabelPlausibilityTests {

    @Test func unreadFieldsSurviveTheConversionAsNil() {
        var scan = NutritionLabelResult()
        scan.protein = 8
        let facts = scan.nutritionFacts
        #expect(facts.protein == 8)
        #expect(facts.calories == nil)
        #expect(facts.carbs == nil)
        #expect(facts.fat == nil)
        #expect(facts.fiber == nil)
        #expect(facts.hasServingSize == false)
        // Poly/mono are not parsed off the panel, so they are absent rather than zero.
        #expect(facts.polyunsaturatedFat == nil)
        #expect(facts.monounsaturatedFat == nil)
    }

    @Test func aZeroOnTheLabelSurvivesAsAZero() {
        var scan = NutritionLabelResult()
        scan.calories = 0
        scan.protein = 0
        scan.carbs = 0
        scan.fat = 0
        let facts = scan.nutritionFacts
        #expect(facts.calories == 0)
        #expect(facts.protein == 0)
        // A reported zero IS a claim, so the not-all-zero rule fires — unlike the all-absent case.
        #expect(scan.plausibilityReport(foodName: "Mystery bar").findings == [.allReportedValuesZero])
    }

    @Test func aBlankServingSizeDoesNotCountAsReported() {
        var scan = NutritionLabelResult()
        scan.servingSize = "   "
        #expect(scan.nutritionFacts.hasServingSize == false)
        scan.servingSize = "2 cookies (30g)"
        #expect(scan.nutritionFacts.hasServingSize == true)
    }

    @Test func anEmptyScanIsIncompleteRatherThanImplausible() {
        let report = NutritionLabelResult().plausibilityReport()
        #expect(report.findings.isEmpty)
        #expect(report.missingFields == NutritionPlausibility.coreFields)
        #expect(report.needsReview)
    }

    @Test func aLostDecimalPointOnTheCaloriesLineIsCaught() {
        // 30 g carb + 12 g fat + 4 g protein is ~244 kcal; the panel read "24".
        var scan = NutritionLabelResult()
        scan.servingSize = "1 bar (55g)"
        scan.calories = 24
        scan.protein = 4
        scan.carbs = 30
        scan.fat = 12
        let report = scan.plausibilityReport(foodName: "Hazelnut oat bar")
        #expect(report.isImplausible)
        #expect(report.missingFields.isEmpty)
        #expect(report.findings.contains { finding in
            if case .caloriesDisagreeWithMacros = finding { return true }
            return false
        })
    }

    @Test func aCleanPanelPassesEveryCheck() {
        var scan = NutritionLabelResult()
        scan.servingSize = "1 bar (55g)"
        scan.calories = 244
        scan.protein = 4
        scan.carbs = 30
        scan.fat = 12
        scan.saturatedFat = 5
        scan.transFat = 0
        scan.fiber = 3
        scan.sugar = 14
        scan.sodium = 95
        #expect(scan.plausibilityReport(foodName: "Hazelnut oat bar") == .clean)
    }

    @Test func plainTeaIsExemptFromTheAllZeroRule() {
        var scan = NutritionLabelResult()
        scan.servingSize = "1 cup (240mL)"
        scan.calories = 0
        scan.protein = 0
        scan.carbs = 0
        scan.fat = 0
        #expect(scan.plausibilityReport(foodName: "Green tea") == .clean)
        #expect(scan.plausibilityReport(foodName: "Sweet tea").findings == [.allReportedValuesZero])
    }
}

private final class ThreadCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool?

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func record(isMainThread: Bool) {
        lock.lock()
        storedValue = isMainThread
        lock.unlock()
    }
}
#endif
