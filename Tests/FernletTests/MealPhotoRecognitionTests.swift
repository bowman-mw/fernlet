import Foundation
import Testing
@testable import Fernlet

#if canImport(UIKit)
import UIKit
import FernletDomainModel
import AppServices

/// Batch E meal-photo recognition: the food-taxonomy filter/composition that turns Vision
/// classifications into a resolvable text description, and the recognizer's plumbing into the
/// existing `resolveMeals` cascade (aiStatus gating, empty-result fallback) — all driven through
/// the `FoodImageClassifying` seam with a fake classifier.
struct MealPhotoRecognitionTests {
    // MARK: - Fakes

    private struct FakeClassifier: FoodImageClassifying {
        var results: [FoodImageClassification] = []
        var error: Error?

        func classifications(in image: UIImage) async throws -> [FoodImageClassification] {
            if let error { throw error }
            return results
        }
    }

    @MainActor
    private final class FakeHost: MealPhotoRecognitionHost {
        var settings = FernletSettings()
        var resolvedDescriptions: [String] = []
        var resolvedTypes: [MealType?] = []
        var cannedResolution = MealResolution(
            meals: [
                Meal(
                    name: "Banana", mealType: .snack, macros: Macros(protein: 1, carbs: 27, fat: 0),
                    quality: .ok, confidence: "High", note: "", source: MealLogSource.manual
                )
            ],
            createdRecipes: [], confidence: .high, isFallback: false
        )

        func resolveMeals(from description: String, type: MealType?, date: String?) async -> MealResolution {
            resolvedDescriptions.append(description)
            resolvedTypes.append(type)
            return cannedResolution
        }
    }

    private static func label(_ identifier: String, _ confidence: Double) -> FoodImageClassification {
        FoodImageClassification(identifier: identifier, confidence: confidence)
    }

    // MARK: - Taxonomy filter + description composition

    @Test func mealDescriptionKeepsConfidentFoodLabelsOnly() {
        let description = FoodImageTaxonomy.mealDescription(from: [
            Self.label("banana", 0.9),
            Self.label("laptop", 0.8),          // not food
            Self.label("coffee", 0.4),
            Self.label("pizza", 0.1)            // below the floor
        ])
        #expect(description == "banana and coffee")
    }

    @Test func mealDescriptionOrdersByConfidenceAndCapsAtThree() {
        let description = FoodImageTaxonomy.mealDescription(from: [
            Self.label("rice", 0.5),            // lowest-confidence food — dropped by the cap
            Self.label("salmon", 0.9),
            Self.label("broccoli", 0.7),
            Self.label("lemon", 0.6)
        ])
        #expect(description == "salmon and broccoli and lemon")
    }

    @Test func mealDescriptionNormalizesCompoundIdentifiers() {
        // Compounds match via their food tokens and read naturally in the description.
        let description = FoodImageTaxonomy.mealDescription(from: [
            Self.label("french_fries", 0.8),
            Self.label("ice_cream", 0.6)
        ])
        #expect(description == "french fries and ice cream")
        #expect(FoodImageTaxonomy.isFoodIdentifier("fruit_salad"))
        #expect(FoodImageTaxonomy.isFoodIdentifier("laptop_computer") == false)
    }

    @Test func mealDescriptionDropsGenericAndNonFoodPhotos() {
        // Generic buckets deliberately don't compose a description — better the gentle fallback
        // than resolving garbage.
        #expect(FoodImageTaxonomy.mealDescription(from: [Self.label("food", 0.9), Self.label("dessert", 0.8)]) == nil)
        #expect(FoodImageTaxonomy.mealDescription(from: [Self.label("bicycle", 0.95)]) == nil)
        #expect(FoodImageTaxonomy.mealDescription(from: []) == nil)
    }

    // MARK: - Recognizer plumbing (fake classifier → resolveMeals)

    @MainActor
    @Test func identifyFeedsComposedDescriptionIntoResolveMeals() async {
        let host = FakeHost()
        host.settings.aiStatus = .ready
        let recognizer = MealPhotoRecognizer(classifier: FakeClassifier(results: [
            Self.label("banana", 0.9),
            Self.label("yogurt", 0.7)
        ]))

        let outcome = await recognizer.identify(photo: UIImage(), type: .breakfast, host: host)

        guard case .resolved(let description, let resolution) = outcome else {
            Issue.record("expected .resolved, got \(outcome)")
            return
        }
        #expect(description == "banana and yogurt")
        #expect(host.resolvedDescriptions == ["banana and yogurt"])
        #expect(host.resolvedTypes == [.breakfast])
        #expect(resolution.meals.first?.name == "Banana")
        #expect(resolution.confidence == .high)
    }

    @MainActor
    @Test func identifyIsGatedOnAIStatus() async {
        let host = FakeHost()
        host.settings.aiStatus = .off
        let recognizer = MealPhotoRecognizer(classifier: FakeClassifier(results: [Self.label("banana", 0.9)]))

        let outcome = await recognizer.identify(photo: UIImage(), type: nil, host: host)

        guard case .aiOff = outcome else {
            Issue.record("expected .aiOff, got \(outcome)")
            return
        }
        #expect(host.resolvedDescriptions.isEmpty)
    }

    @MainActor
    @Test func identifyFallsBackGentlyWhenNothingFoodLike() async {
        let host = FakeHost()
        host.settings.aiStatus = .ready
        let recognizer = MealPhotoRecognizer(classifier: FakeClassifier(results: [
            Self.label("laptop", 0.9),
            Self.label("desk", 0.7)
        ]))

        let outcome = await recognizer.identify(photo: UIImage(), type: nil, host: host)

        guard case .nothingRecognized = outcome else {
            Issue.record("expected .nothingRecognized, got \(outcome)")
            return
        }
        #expect(host.resolvedDescriptions.isEmpty)
    }

    @MainActor
    @Test func identifyTreatsClassifierErrorsAsNothingRecognized() async {
        struct ClassifierError: Error {}
        let host = FakeHost()
        host.settings.aiStatus = .ready
        let recognizer = MealPhotoRecognizer(classifier: FakeClassifier(error: ClassifierError()))

        let outcome = await recognizer.identify(photo: UIImage(), type: nil, host: host)

        guard case .nothingRecognized = outcome else {
            Issue.record("expected .nothingRecognized, got \(outcome)")
            return
        }
        #expect(host.resolvedDescriptions.isEmpty)
    }
}

#endif
