import AppIntents
import CryptoKit
import FernletDomainModel
import FernletExchange
import FernletFoundation
import FoodCatalog
import Foundation
import SwiftUI
import UIKit

/// The only store acquisition path used by both the UI loader and background exchange intents.
///
/// Main-actor isolation serializes exchange mutations with normal UI mutations. It also coalesces a
/// cold background launch and the scene loader, so they cannot build competing `FernletStore`s over
/// the same repositories.
@MainActor
final class FernletStoreAccess: @unchecked Sendable {
    static let shared = FernletStoreAccess()

    private var store: FernletStore?
    private var loadingStore: Task<FernletStore, Error>?

    func install(_ store: FernletStore) {
        self.store = store
    }

    func load(statusUpdate: @escaping @MainActor (String) -> Void = { _ in }) async throws -> FernletStore {
        try requireProtectedData()
        if let store { return store }
        if let loadingStore { return try await loadingStore.value }
        let task = Task { @MainActor [weak self] () throws -> FernletStore in
            guard let self else { throw ExchangeIntentServiceError.storeUnavailable }
            let store = try await FernletStore.load(statusUpdate: statusUpdate)
            await store.loadBundledFoodItemsForLaunch()
            self.store = store
            return store
        }
        loadingStore = task
        do {
            let loaded = try await task.value
            loadingStore = nil
            return loaded
        } catch {
            loadingStore = nil
            throw error
        }
    }

    private func requireProtectedData() throws {
        guard UIApplication.shared.isProtectedDataAvailable else {
            throw ExchangeIntentServiceError.deviceLocked
        }
    }
}

/// Main-process dependency for App Intents that exchange recipe and workout-plan files.
///
/// This never creates repositories directly. A warm app installs its existing store; a background
/// launch coalesces through `FernletStoreAccess` and uses the normal selected repository stack.
@MainActor
final class ExchangeIntentService: @unchecked Sendable {
    static let shared = ExchangeIntentService()
    private let storeAccess: FernletStoreAccess

    init(storeAccess: FernletStoreAccess? = nil) {
        self.storeAccess = storeAccess ?? FernletStoreAccess.shared
    }

    static func registerAppDependency() {
        AppDependencyManager.shared.add(dependency: {
            await MainActor.run { ExchangeIntentService.shared }
        })
    }

    func install(store: FernletStore) {
        storeAccess.install(store)
    }

    func loadStoreForUI(statusUpdate: @escaping @MainActor (String) -> Void) async throws -> FernletStore {
        try await storeAccess.load(statusUpdate: statusUpdate)
    }

    func recipeEntities() async throws -> [RecipeEntity] {
        let store = try await storeAccess.load()
        let local = store.recipes.map(RecipeEntity.init(recipe:))
        let saved = store.savedRecipes.map(RecipeEntity.init(recipe:))
        return Array((local + saved).prefix(ExchangeIntentLimits.maxEntityResults))
    }

    func recipeEntity(id: UUID) async throws -> RecipeEntity? {
        let store = try await storeAccess.load()
        return recipe(in: store, id: id).map(RecipeEntity.init(recipe:))
    }

    func exportRecipe(_ entity: RecipeEntity, includesNotes: Bool) async throws -> IntentFile {
        let store = try await storeAccess.load()
        guard let recipe = recipe(in: store, id: entity.id) else { throw ExchangeIntentServiceError.notFound }
        let packet = try RecipeExchangePacket(recipe: recipe, foodItems: store.foodCatalog.items(forRecipe: recipe),
                                               includesNotes: includesNotes)
        let data = try packet.encodedData()
        return IntentFile(data: data, filename: sanitizedFilename(recipe.name, suffix: "fernletrecipe"), type: .fernletRecipe)
    }

    func importRecipe(_ packet: RecipeExchangePacket, policy: RecipeDuplicatePolicy) async throws -> RecipeEntity {
        let store = try await storeAccess.load()
        if let existing = try existingRecipe(for: packet, store: store, policy: policy) {
            return RecipeEntity(recipe: existing)
        }
        let payloadData = try JSONEncoder().encode(packet.recipe)
        guard let payloadText = String(data: payloadData, encoding: .utf8) else {
            throw ExchangeIntentServiceError.invalidPacket
        }
        let importedID = policy == .keepAnotherCopy ? UUID() : packet.originContentID
        let imported = try store.importRecipe(from: payloadText, id: importedID)
        guard store.flushPendingSnapshotSave() else { throw ExchangeIntentServiceError.persistenceFailed }
        store.activateMessagesCatalog()
        try ExchangeImportLedger.shared.record(packetID: packet.packetID, hash: packet.contentHash,
                                               resultID: imported.id.uuidString, kind: .recipe)
        return RecipeEntity(recipe: imported)
    }

    func plannedWorkoutEntities() async throws -> [PlannedWorkoutEntity] {
        let store = try await storeAccess.load()
        let start = FernletDate.dayKey(for: Date())
        var entities: [PlannedWorkoutEntity] = []
        for offset in 0..<ExchangeIntentLimits.maxPlannedWorkoutDays {
            guard let dayKey = FernletStore.dayKey(startingOn: start, offsetBy: offset) else { break }
            for workout in store.loadDay(for: dayKey).plannedWorkouts {
                entities.append(PlannedWorkoutEntity(dayKey: dayKey, workout: workout))
                if entities.count == ExchangeIntentLimits.maxEntityResults { return entities }
            }
        }
        return entities
    }

    func plannedWorkoutEntity(id: String) async throws -> PlannedWorkoutEntity? {
        let components = id.split(separator: "|", maxSplits: 1).map(String.init)
        guard components.count == 2, let workoutID = UUID(uuidString: components[1]) else { return nil }
        let store = try await storeAccess.load()
        guard let workout = store.loadDay(for: components[0]).plannedWorkouts.first(where: { $0.id == workoutID }) else {
            return nil
        }
        return PlannedWorkoutEntity(dayKey: components[0], workout: workout)
    }

    func exportWorkoutPlan(_ entity: PlannedWorkoutEntity) async throws -> IntentFile {
        let store = try await storeAccess.load()
        guard let workout = plannedWorkout(in: store, entity: entity) else { throw ExchangeIntentServiceError.notFound }
        let plan = ExchangeWorkoutPlanBuilder.oneDayPlan(from: workout, dayKey: entity.dayKey)
        let packet = try WorkoutPlanExchangePacket(plan: plan)
        let data = try packet.encodedData()
        return IntentFile(data: data, filename: sanitizedFilename(workout.name, suffix: "fernletplan"), type: .fernletWorkoutPlan)
    }

    func workoutPreview(
        packet: WorkoutPlanExchangePacket,
        startDate: Date?,
        policy: WorkoutPlanCollisionPolicy
    ) async throws -> WorkoutPlanImportPreview {
        let store = try await storeAccess.load()
        let startDayKey = resolvedStartDayKey(for: packet.plan, requestedStartDate: startDate)
        let review = store.reviewCoachPlan(packet.plan, startingOn: startDayKey)
        guard review.isImportable else { throw ExchangeIntentServiceError.invalidPacket }
        let revision = calendarRevision(store: store, review: review, startDayKey: startDayKey)
        return WorkoutPlanImportPreview(packet: packet, review: review, startDayKey: startDayKey,
                                        policy: policy, calendarRevision: revision, expiresAt: Date().addingTimeInterval(120))
    }

    func importWorkoutPlan(_ preview: WorkoutPlanImportPreview) async throws -> WorkoutPlanImportResultEntity {
        let store = try await storeAccess.load()
        if let ledger = try ExchangeImportLedger.shared.result(for: preview.packet.packetID, hash: preview.packet.contentHash) {
            return WorkoutPlanImportResultEntity.replayed(id: ledger.resultID, plan: preview.packet.plan)
        }
        let current = try await workoutPreview(packet: preview.packet, startDate: preview.startDate, policy: preview.policy)
        guard current.matches(preview) else { throw ExchangeIntentServiceError.reviewChanged }
        guard let result = store.applyCoachPlan(current.review, startingOn: current.startDayKey,
                                                struckExerciseKeys: [], collisionPolicy: current.policy.storePolicy) else {
            throw ExchangeIntentServiceError.invalidPacket
        }
        guard store.flushPendingSnapshotSave() else { throw ExchangeIntentServiceError.persistenceFailed }
        store.activateMessagesCatalog()
        let resultID = preview.packet.packetID.uuidString
        try ExchangeImportLedger.shared.record(packetID: preview.packet.packetID, hash: preview.packet.contentHash,
                                               resultID: resultID, kind: .workoutPlan)
        return WorkoutPlanImportResultEntity(id: resultID, plan: current.review.plan, result: result)
    }

    private func recipe(in store: FernletStore, id: UUID) -> RecipeDefinition? {
        store.recipes.first(where: { $0.id == id }) ?? store.savedRecipes.first(where: { $0.id == id })
    }

    private func plannedWorkout(in store: FernletStore, entity: PlannedWorkoutEntity) -> PlannedWorkout? {
        store.loadDay(for: entity.dayKey).plannedWorkouts.first(where: { $0.id == entity.workoutID })
    }

    private func calendarRevision(
        store: FernletStore,
        review: CoachPlanImportReview,
        startDayKey: String
    ) -> String {
        let dayKeys = relevantDayKeys(for: review, startDayKey: startDayKey)
        var values: [String] = []
        for dayKey in dayKeys {
            let rows = store.loadDay(for: dayKey).plannedWorkouts
            values.append(dayKey + ":" + rows.map(workoutRevision).sorted().joined(separator: ","))
        }
        let data = Data(values.joined(separator: "|").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func relevantDayKeys(for review: CoachPlanImportReview, startDayKey: String) -> [String] {
        var keys = review.resolvedEdits.map(\.dayKey)
        for day in review.plan.days {
            guard let key = FernletStore.dayKey(startingOn: startDayKey, offsetBy: day.dayIndex - 1) else { continue }
            keys.append(key)
        }
        return Array(Set(keys)).sorted().prefix(ExchangeIntentLimits.maxCalendarDays).map { $0 }
    }

    private func workoutRevision(_ workout: PlannedWorkout) -> String {
        workout.id.uuidString + ":" + workout.name + ":" + workout.exercises + ":" + workout.notes
    }

    private func existingRecipe(
        for packet: RecipeExchangePacket,
        store: FernletStore,
        policy: RecipeDuplicatePolicy
    ) throws -> RecipeDefinition? {
        guard policy == .skipExactDuplicate else { return nil }
        if let ledger = try ExchangeImportLedger.shared.result(for: packet.packetID, hash: packet.contentHash),
           let id = UUID(uuidString: ledger.resultID), let recipe = recipe(in: store, id: id) {
            return recipe
        }
        return nil
    }

    private func resolvedStartDayKey(for plan: CoachPlan, requestedStartDate: Date?) -> String {
        if let requestedStartDate { return FernletDate.dayKey(for: requestedStartDate) }
        if case .fixedDate(let dayKey) = plan.startPolicy { return dayKey }
        return FernletDate.dayKey(for: Date())
    }

    private func sanitizedFilename(_ source: String, suffix: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Fernlet" : String(trimmed.prefix(60))
        let invalid = CharacterSet(charactersIn: "/:\\")
        return base.components(separatedBy: invalid).joined(separator: "-") + ".\(suffix)"
    }
}

/// An App Entity for selecting a canonical recipe. It stores display data only; `perform()` resolves
/// the identifier against the current canonical store before exporting.
struct RecipeEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Recipe")
    static let defaultQuery = RecipeEntityQuery()

    var id: UUID
    var name: String
    var servings: Int

    init(recipe: RecipeDefinition) {
        id = recipe.id
        name = recipe.name
        servings = recipe.servings
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(servings) serving(s)")
    }
}

struct RecipeEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [RecipeEntity] {
        guard identifiers.count <= ExchangeIntentLimits.maxEntityResults else {
            throw ExchangeIntentServiceError.invalidPacket
        }
        var resolved: [RecipeEntity] = []
        for identifier in identifiers {
            if let entity = try await ExchangeIntentService.shared.recipeEntity(id: identifier) {
                resolved.append(entity)
            }
        }
        return resolved
    }

    func suggestedEntities() async throws -> [RecipeEntity] {
        try await ExchangeIntentService.shared.recipeEntities()
    }
}

/// A selectable planned workout. The identifier carries the day key because a planned-workout UUID
/// is only meaningful within its calendar row.
struct PlannedWorkoutEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Planned workout")
    static let defaultQuery = PlannedWorkoutEntityQuery()

    var id: String { dayKey + "|" + workoutID.uuidString }
    var dayKey: String
    var workoutID: UUID
    var name: String

    init(dayKey: String, workout: PlannedWorkout) {
        self.dayKey = dayKey
        workoutID = workout.id
        name = workout.name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "Planned for \(dayKey)")
    }
}

struct PlannedWorkoutEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PlannedWorkoutEntity] {
        guard identifiers.count <= ExchangeIntentLimits.maxEntityResults else {
            throw ExchangeIntentServiceError.invalidPacket
        }
        var entities: [PlannedWorkoutEntity] = []
        for identifier in identifiers {
            if let entity = try await ExchangeIntentService.shared.plannedWorkoutEntity(id: identifier) {
                entities.append(entity)
            }
        }
        return entities
    }

    func suggestedEntities() async throws -> [PlannedWorkoutEntity] {
        try await ExchangeIntentService.shared.plannedWorkoutEntities()
    }
}

/// Background-import collision choices. The first deliberately leaves existing planned workouts
/// untouched; it does not silently add another session to a day the user has already planned.
enum WorkoutPlanCollisionPolicy: String, AppEnum, Equatable {
    case keepExistingWorkouts
    case addAlongside
    case replaceFutureConflicts

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Workout collision policy")
    static let caseDisplayRepresentations: [WorkoutPlanCollisionPolicy: DisplayRepresentation] = [
        .keepExistingWorkouts: "Keep existing workouts",
        .addAlongside: "Add alongside",
        .replaceFutureConflicts: "Replace future conflicts"
    ]

    var storePolicy: CoachPlanCollisionPolicy {
        switch self {
        case .keepExistingWorkouts: .keepExisting
        case .addAlongside: .keepBoth
        case .replaceFutureConflicts: .replaceFutureConflicts
        }
    }
}

/// The main-actor preview token binds the approval to both packet bytes and the live calendar.
struct WorkoutPlanImportPreview {
    var packet: WorkoutPlanExchangePacket
    var review: CoachPlanImportReview
    var startDayKey: String
    var policy: WorkoutPlanCollisionPolicy
    var calendarRevision: String
    var expiresAt: Date

    var startDate: Date? { FernletDate.date(fromDayKey: startDayKey) }

    func matches(_ original: WorkoutPlanImportPreview) -> Bool {
        packet.contentHash == original.packet.contentHash
            && startDayKey == original.startDayKey
            && policy == original.policy
            && calendarRevision == original.calendarRevision
            && Date() <= original.expiresAt
    }
}

/// A stable result value for Shortcuts. Its identifier is the packet UUID, allowing an automation
/// retried after the write/result-delivery gap to receive the same result rather than a duplicate.
struct WorkoutPlanImportResultEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Workout plan import")
    static let defaultQuery = WorkoutPlanImportResultQuery()

    var id: String
    var title: String
    var addedCount: Int
    var changedCount: Int
    var removedCount: Int
    var firstDayKey: String
    var lastDayKey: String

    init(id: String, plan: CoachPlan, result: CoachPlanImportResult) {
        self.id = id
        title = plan.title
        addedCount = result.plannedWorkoutCount
        changedCount = result.editedCount
        removedCount = result.deletedCount
        firstDayKey = result.firstDayKey
        lastDayKey = result.lastDayKey
    }

    static func replayed(id: String, plan: CoachPlan) -> WorkoutPlanImportResultEntity {
        WorkoutPlanImportResultEntity(id: id, title: plan.title, addedCount: 0, changedCount: 0,
                                      removedCount: 0, firstDayKey: "", lastDayKey: "")
    }

    private init(id: String, title: String, addedCount: Int, changedCount: Int,
                 removedCount: Int, firstDayKey: String, lastDayKey: String) {
        self.id = id
        self.title = title
        self.addedCount = addedCount
        self.changedCount = changedCount
        self.removedCount = removedCount
        self.firstDayKey = firstDayKey
        self.lastDayKey = lastDayKey
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(addedCount) added · \(changedCount) changed")
    }
}

struct WorkoutPlanImportResultQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WorkoutPlanImportResultEntity] { [] }
}

enum RecipeDuplicatePolicy: String, AppEnum {
    case skipExactDuplicate
    case keepAnotherCopy

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Recipe duplicate policy")
    static let caseDisplayRepresentations: [RecipeDuplicatePolicy: DisplayRepresentation] = [
        .skipExactDuplicate: "Skip exact duplicate",
        .keepAnotherCopy: "Keep another copy"
    ]
}

enum ExchangeIntentLimits {
    nonisolated static let maxEntityResults = 100
    nonisolated static let maxPlannedWorkoutDays = 90
    nonisolated static let maxCalendarDays = CoachPlanLimits.maxDays + CoachPlanLimits.maxEdits
}

enum ExchangeIntentServiceError: LocalizedError {
    case deviceLocked
    case storeUnavailable
    case notFound
    case invalidPacket
    case persistenceFailed
    case reviewChanged

    var errorDescription: String? {
        switch self {
        case .deviceLocked: "Unlock your iPhone and try again."
        case .storeUnavailable: "Fernlet couldn't open your records just now."
        case .notFound: "That item is no longer in Fernlet."
        case .invalidPacket: "Fernlet couldn't read that exchange file."
        case .persistenceFailed: "Fernlet couldn't save that import. Please try again."
        case .reviewChanged: "Your calendar changed. Review the updated plan and try again."
        }
    }
}
