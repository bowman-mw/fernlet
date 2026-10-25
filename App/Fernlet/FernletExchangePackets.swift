import FernletExchange
import UniformTypeIdentifiers

/// App-facing file declarations for portable packets owned by `FernletExchange`.
///
/// The package deliberately has no UniformTypeIdentifiers dependency, so this remains the small
/// containing-app adapter while packet construction and validation stay extension-safe.
extension UTType {
    static let fernletRecipe = UTType(exportedAs: "com.mbo.fernlet.recipe", conformingTo: .json)
    static let fernletWorkoutPlan = UTType(exportedAs: "com.mbo.fernlet.workout-plan", conformingTo: .json)
}
