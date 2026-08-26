import FernletExchange
import Foundation

/// Persists a valid containing-app deep link until the launch shell can safely present its review.
/// The URL carries only an opaque App Group inbox target; packet bytes remain in protected storage.
nonisolated enum FernletMessagesRecipeImportRequest {
    static let requestNotification = Notification.Name("fernlet.messages.importRequest")
    private static let destinationDefaultsKey = "fernlet.messages.pendingInboxDestination"
    private static let inboxIDDefaultsKey = "fernlet.messages.pendingInboxID"
    private static let legacyRecipeIDDefaultsKey = "fernlet.messages.pendingRecipeInboxID"

    static func request(from url: URL) -> Bool {
        guard let target = FernletMessagesInboxLink.target(from: url) else { return false }
        UserDefaults.standard.set(target.destination.rawValue, forKey: destinationDefaultsKey)
        UserDefaults.standard.set(target.inboxID.uuidString, forKey: inboxIDDefaultsKey)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: requestNotification, object: nil)
        }
        return true
    }

    static func consume() -> FernletMessagesInboxTarget? {
        let defaults = UserDefaults.standard
        let destinationText = defaults.string(forKey: destinationDefaultsKey)
        let inboxIDText = defaults.string(forKey: inboxIDDefaultsKey)
        defaults.removeObject(forKey: destinationDefaultsKey)
        defaults.removeObject(forKey: inboxIDDefaultsKey)
        if let destinationText, let inboxIDText,
           let destination = FernletMessagesInboxDestination(rawValue: destinationText),
           let inboxID = UUID(uuidString: inboxIDText) {
            return FernletMessagesInboxTarget(destination: destination, inboxID: inboxID)
        }
        guard let legacyID = defaults.string(forKey: legacyRecipeIDDefaultsKey) else { return nil }
        defaults.removeObject(forKey: legacyRecipeIDDefaultsKey)
        guard let inboxID = UUID(uuidString: legacyID) else { return nil }
        return FernletMessagesInboxTarget(destination: .recipe, inboxID: inboxID)
    }
}

/// Narrow app-level gateway for the Messages inbox. It never creates or exposes a Fernlet store.
@MainActor
struct FernletMessagesRecipeInboxCoordinator {
    private let recipeInbox: FernletMessagesInboxStore?
    private let workoutInbox: FernletMessagesWorkoutInboxStore?

    init(directory: URL? = nil) {
        if let directory {
            recipeInbox = FernletMessagesInboxStore(directory: directory)
            workoutInbox = FernletMessagesWorkoutInboxStore(directory: directory)
        } else if let directory = FernletMessagesInboxStore.productionDirectory() {
            recipeInbox = FernletMessagesInboxStore(directory: directory)
            workoutInbox = FernletMessagesWorkoutInboxStore(directory: directory)
        } else {
            recipeInbox = nil
            workoutInbox = nil
        }
    }

    func record(id: UUID) throws -> FernletMessagesInboxRecord? {
        guard let recipeInbox else { throw ExchangeIntentServiceError.storeUnavailable }
        return try recipeInbox.record(id: id)
    }

    func consume(id: UUID) -> Bool {
        recipeInbox?.remove(id) ?? false
    }

    func workoutRecord(id: UUID) throws -> FernletMessagesWorkoutInboxRecord? {
        guard let workoutInbox else { throw ExchangeIntentServiceError.storeUnavailable }
        return try workoutInbox.record(id: id)
    }

    func consumeWorkout(id: UUID) -> Bool {
        workoutInbox?.remove(id) ?? false
    }

    func purgeExpired() -> Bool {
        guard let recipeInbox, let workoutInbox else { return false }
        return recipeInbox.purgeExpired() && workoutInbox.purgeExpired()
    }

    /// Clears both review queues for the containing app's delete-everything funnel. The inboxes
    /// can otherwise re-open a pre-wipe recipe or plan after the canonical store is empty.
    func clear() -> Bool {
        guard let recipeInbox, let workoutInbox else { return false }
        return recipeInbox.clear() && workoutInbox.clear()
    }
}
