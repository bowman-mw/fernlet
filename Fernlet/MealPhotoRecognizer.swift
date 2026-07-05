import Foundation

#if canImport(UIKit)
import UIKit
import FernletDomainModel
import AppServices

/// Read-side context the photo recognizer needs from the app store — the
/// `MealResolutionContext` host-protocol pattern, so tests can drive the flow
/// with a fake host instead of a full `FernletStore`.
@MainActor
protocol MealPhotoRecognitionHost: AnyObject {
    var settings: FernletSettings { get }
    func resolveMeals(from description: String, type: MealType?, date: String?) async -> MealResolution
}

extension FernletStore: MealPhotoRecognitionHost {}

enum MealPhotoRecognitionOutcome {
    /// Inference is off (`settings.aiStatus == .off`) — the entry point should not even be offered.
    case aiOff
    /// The classifier saw nothing food-like — offer the gentle "want to type it?" fallback.
    case nothingRecognized
    /// The composed description and the cascade's resolution — always shown in the review sheet.
    case resolved(description: String, resolution: MealResolution)
}

/// "Identify from photo": on-device Vision classification filtered to food labels composes a short
/// text description that feeds the EXISTING `resolveMeals` cascade; the result always pauses at the
/// normal pre-log review sheet (a photo guess never commits silently). Gated on `aiStatus` like the
/// other inference paths. No new AI surface: the image never leaves the device and never reaches a
/// language model — only the composed text enters the already-audited cascade.
@MainActor
struct MealPhotoRecognizer {
    var classifier: any FoodImageClassifying = VisionFoodImageClassifier()

    func identify(photo: UIImage, type: MealType?, host: any MealPhotoRecognitionHost) async -> MealPhotoRecognitionOutcome {
        guard host.settings.aiStatus != .off else { return .aiOff }
        let classifications = (try? await classifier.classifications(in: photo)) ?? []
        guard let description = FoodImageTaxonomy.mealDescription(from: classifications) else {
            return .nothingRecognized
        }
        let resolution = await host.resolveMeals(from: description, type: type, date: nil)
        return .resolved(description: description, resolution: resolution)
    }
}

#endif
