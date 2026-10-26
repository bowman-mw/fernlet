import AppIntents
import FernletDomainModel
import FernletExchange
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Exports one canonical recipe as Fernlet's bounded, photo-free exchange packet.
struct ExportRecipeIntent: AppIntent {
    static let title: LocalizedStringResource = "Export recipe"
    static let description = IntentDescription("Exports a recipe as a Fernlet recipe file.")
    static let supportedModes: IntentModes = [.background]

    @AppDependency var exchange: ExchangeIntentService
    @Parameter(title: "Recipe") var recipe: RecipeEntity
    @Parameter(title: "Include notes", default: false) var includesNotes: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let file = try await exchange.exportRecipe(recipe, includesNotes: includesNotes)
        return .result(value: file)
    }
}

/// Imports a validated recipe exchange packet after an explicit system-owned confirmation.
struct ImportRecipeIntent: AppIntent {
    static let title: LocalizedStringResource = "Import recipe"
    static let description = IntentDescription("Imports a Fernlet recipe file after showing its details.")
    static let supportedModes: IntentModes = [.background]

    @AppDependency var exchange: ExchangeIntentService
    @Parameter(title: "Recipe file") var file: IntentFile
    @Parameter(title: "Duplicate policy", default: .skipExactDuplicate) var duplicatePolicy: RecipeDuplicatePolicy

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<RecipeEntity> {
        let data = try await ExchangeIntentFileReader.data(from: file, type: .fernletRecipe,
                                                            maximumBytes: RecipeLimits.maxShareTextUTF8Bytes)
        let packet = try RecipeExchangePacket.decode(data)
        try await requestConfirmation(actionName: .add, dialog: "Import this recipe?", showDialogAsPrompt: true) {
            RecipeExchangeConfirmation(packet: packet)
        }
        let imported = try await exchange.importRecipe(packet, policy: duplicatePolicy)
        return .result(value: imported)
    }
}

/// Exports a single planned workout as a one-day `CoachPlan` exchange packet.
struct ExportWorkoutPlanIntent: AppIntent {
    static let title: LocalizedStringResource = "Export workout plan"
    static let description = IntentDescription("Exports a planned workout as a Fernlet plan file.")
    static let supportedModes: IntentModes = [.background]

    @AppDependency var exchange: ExchangeIntentService
    @Parameter(title: "Planned workout") var workout: PlannedWorkoutEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let file = try await exchange.exportWorkoutPlan(workout)
        return .result(value: file)
    }
}

/// Imports a bounded coach-plan packet through Fernlet's existing safety and collision analysis.
struct ImportWorkoutPlanIntent: AppIntent {
    static let title: LocalizedStringResource = "Import workout plan"
    static let description = IntentDescription("Reviews and imports a Fernlet workout plan file.")
    static let supportedModes: IntentModes = [.background]

    @AppDependency var exchange: ExchangeIntentService
    @Parameter(title: "Workout plan file") var file: IntentFile
    @Parameter(title: "Collision policy", default: .keepExistingWorkouts) var collisionPolicy: WorkoutPlanCollisionPolicy
    @Parameter(title: "Start date") var startDate: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<WorkoutPlanImportResultEntity> {
        let data = try await ExchangeIntentFileReader.data(from: file, type: .fernletWorkoutPlan,
                                                            maximumBytes: CoachPlanLimits.maxPastedBytes)
        let packet = try WorkoutPlanExchangePacket.decode(data)
        let firstPreview = try await exchange.workoutPreview(packet: packet, startDate: startDate, policy: collisionPolicy)
        try await confirm(firstPreview)
        let updatedPreview = try await exchange.workoutPreview(packet: packet, startDate: startDate, policy: collisionPolicy)
        if !updatedPreview.matches(firstPreview) {
            try await confirm(updatedPreview)
        }
        let result = try await exchange.importWorkoutPlan(updatedPreview)
        return .result(value: result)
    }

    @MainActor
    private func confirm(_ preview: WorkoutPlanImportPreview) async throws {
        try await requestConfirmation(actionName: .add, dialog: "Add this workout plan?", showDialogAsPrompt: true) {
            WorkoutPlanExchangeConfirmation(preview: preview)
        }
    }
}

// The two confirmations' views — `RecipeExchangeConfirmation` and `WorkoutPlanExchangeConfirmation`,
// Fernlet's card inside Shortcuts' prompt — are in World/Shortcuts/ExchangeSnippetViews.swift
// (World Review Batch 4, `b4-sc-recipe`, `b4-sc-plan`).

/// Reads an `IntentFile` only after checking an in-place file's size. In-memory files have no
/// separately observable length, so their bounded `Data` is checked immediately after loading.
enum ExchangeIntentFileReader {
    static func data(from file: IntentFile, type: UTType, maximumBytes: Int) async throws -> Data {
        guard maximumBytes > 0 else { throw ExchangeIntentServiceError.invalidPacket }
        if let fileURL = file.fileURL {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size >= 0, size <= maximumBytes else {
                throw ExchangePacketError.tooLarge
            }
        }
        let data = try await file.data(contentType: type)
        guard data.count <= maximumBytes else { throw ExchangePacketError.tooLarge }
        return data
    }
}
