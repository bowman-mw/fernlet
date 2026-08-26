import FernletDomainModel
import FernletExchange
import Foundation
import Testing

/// Portable file and Messages-envelope coverage. These tests import the narrow package product,
/// not the app implementation, to keep the extension boundary observable in the test graph.
struct FernletExchangeTests {
    @Test func recipeFileRetainsTheEstablishedWireSchema() throws {
        let packet = try recipePacket()
        let data = try packet.encodedData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == [
            "contentHash", "format", "formatVersion", "includesNotes", "originContentID", "packetID", "recipe"
        ])
        #expect(packet.format == "fernlet.exchange.recipe")
        #expect(packet.formatVersion == 1)
        #expect(try RecipeExchangePacket.decode(data) == packet)
    }

    @Test func recipeMessageEnvelopeRoundTripsItsPacketAndCard() throws {
        let packet = try recipePacket()
        let original = try ExchangeMessageEnvelope(recipe: packet)
        let recovered = try ExchangeMessageEnvelope.decode(messageURL: original.messageURL())

        guard case .recipe(let result) = try recovered.validatedPayload() else {
            Issue.record("Expected a recipe packet.")
            return
        }
        #expect(result == packet)
        #expect(try recovered.canonicalCardMetadata() == original.card)
    }

    @Test func workoutMessageEnvelopeRoundTripsItsPacketAndCard() throws {
        let packet = try workoutPacket()
        let original = try ExchangeMessageEnvelope(workoutPlan: packet, scheduledStartDayKey: "2026-09-02")
        let recovered = try ExchangeMessageEnvelope.decode(messageURL: original.messageURL())

        guard case .workoutPlan(let result) = try recovered.validatedPayload() else {
            Issue.record("Expected a workout-plan packet.")
            return
        }
        #expect(result == packet)
        #expect(recovered.scheduledStartDayKey == "2026-09-02")
        #expect(recovered.card.scheduledStartDayKey == "2026-09-02")
        #expect(try recovered.canonicalCardMetadata() == original.card)
    }

    @Test func recipeFileRejectsATamperedCanonicalHash() throws {
        var packet = try recipePacket()
        packet.contentHash = String(repeating: "0", count: 64)
        let data = try JSONEncoder().encode(packet)

        #expect(throws: ExchangePacketError.invalidHash) {
            try RecipeExchangePacket.decode(data)
        }
    }

    @Test func messagesCatalogRoundTripsThroughItsBoundedFileStore() throws {
        let entry = try FernletMessagesRecipeCatalogEntry(packet: recipePacket())
        let catalog = try FernletMessagesCatalog(recipes: [entry], workouts: [])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = FernletMessagesCatalogFileStore(directory: directory)

        try store.write(catalog)

        #expect(try store.read() == catalog)
        #expect(store.clear())
        #expect(try store.read() == nil)
    }

    @Test func messagesCatalogRejectsDataOverItsByteLimit() {
        let data = Data(repeating: 0, count: FernletMessagesCatalogLimits.maxCatalogBytes + 1)

        #expect(throws: ExchangePacketError.tooLarge) {
            try FernletMessagesCatalog.decode(data)
        }
    }

    @Test func compactRecipePickerPrioritizesTheLastSelection() throws {
        let first = try FernletMessagesRecipeCatalogEntry(packet: recipePacket(name: "First"))
        let second = try FernletMessagesRecipeCatalogEntry(packet: recipePacket(name: "Second"))
        let third = try FernletMessagesRecipeCatalogEntry(packet: recipePacket(name: "Third"))
        let fourth = try FernletMessagesRecipeCatalogEntry(packet: recipePacket(name: "Fourth"))
        let fifth = try FernletMessagesRecipeCatalogEntry(packet: recipePacket(name: "Fifth"))
        let catalog = try FernletMessagesCatalog(recipes: [first, second, third, fourth, fifth], workouts: [])

        let compact = FernletMessagesRecipePicker.compactEntries(in: catalog, lastSelectedRecipeID: fifth.packet.originContentID)

        #expect(compact.map(\.packet.originContentID) == [fifth, first, second, third].map(\.packet.originContentID))
        #expect(FernletMessagesRecipePicker.entries(matching: "third", in: catalog) == [third])
    }

    @Test func messagesInboxRoundTripsAnOpaqueRecipeReviewRequest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inbox = FernletMessagesInboxStore(directory: directory)
        let record = try inbox.enqueue(recipePacket())
        let url = try #require(FernletMessagesInboxLink.url(for: record.id))

        #expect(try inbox.record(id: record.id) == record)
        #expect(FernletMessagesInboxLink.inboxID(from: url) == record.id)
        #expect(!url.absoluteString.contains(record.packet.recipe.name))
        #expect(inbox.remove(record.id))
        #expect(try inbox.record(id: record.id) == nil)
    }

    @Test func messagesInboxPurgesExpiredRecordsAndRefusesOverflow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inbox = FernletMessagesInboxStore(directory: directory)
        let expiredAt = Date(timeIntervalSinceNow: -FernletMessagesInboxLimits.maximumAge - 1)
        let expired = try inbox.enqueue(recipePacket(), receivedAt: expiredAt)

        #expect(try inbox.record(id: expired.id) == nil)
        for _ in 0..<FernletMessagesInboxLimits.maxRecords {
            _ = try inbox.enqueue(recipePacket())
        }
        #expect(throws: ExchangePacketError.tooLarge) {
            _ = try inbox.enqueue(recipePacket())
        }
    }

    @Test func messagesWorkoutInboxRoundTripsAnOpaqueReviewRequest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inbox = FernletMessagesWorkoutInboxStore(directory: directory)
        let record = try inbox.enqueue(try workoutPacket(), suggestedStartDayKey: "2026-09-02")
        let target = FernletMessagesInboxTarget(destination: .workoutPlan, inboxID: record.id)
        let url = try #require(FernletMessagesInboxLink.url(for: target))

        #expect(try inbox.record(id: record.id) == record)
        #expect(FernletMessagesInboxLink.target(from: url) == target)
        #expect(FernletMessagesInboxLink.inboxID(from: url) == nil)
        #expect(!url.absoluteString.contains(record.packet.plan.title))
        #expect(inbox.remove(record.id))
        #expect(try inbox.record(id: record.id) == nil)
    }

    @Test func workoutCatalogBindsItsCardToTheScheduledDay() throws {
        let entry = try FernletMessagesWorkoutCatalogEntry(dayKey: "2026-09-02", packet: workoutPacket())
        let catalog = try FernletMessagesCatalog(recipes: [], workouts: [entry])

        #expect(entry.card.scheduledStartDayKey == "2026-09-02")
        #expect(FernletMessagesWorkoutPicker.compactEntries(in: catalog) == [entry])
        #expect(FernletMessagesWorkoutPicker.entries(matching: "strength", in: catalog) == [entry])
    }

    @Test func messageEnvelopeAcceptsItsExactByteLimitAndRejectsOneMoreByte() throws {
        let envelope = try ExchangeMessageEnvelope(recipe: recipePacket())
        let exactBoundary = try envelopeData(atExactLimitFor: envelope)
        var tooLarge = exactBoundary
        tooLarge.append(0)

        #expect(exactBoundary.count == ExchangeLimits.maxMessageEnvelopeBytes)
        #expect(try ExchangeMessageEnvelope.decode(exactBoundary) == envelope)
        #expect(throws: ExchangePacketError.tooLarge) {
            try ExchangeMessageEnvelope.decode(tooLarge)
        }
    }

    @Test func messagesRejectUnsupportedVersionsAndMismatchedCardMetadata() throws {
        let envelope = try ExchangeMessageEnvelope(recipe: recipePacket())
        var unsupported = envelope
        unsupported.formatVersion += 1
        var tamperedCard = envelope
        tamperedCard.card.title = "Not the packet title"

        #expect(throws: ExchangePacketError.invalidPayload) {
            try ExchangeMessageEnvelope.decode(JSONEncoder().encode(unsupported))
        }
        #expect(throws: ExchangePacketError.invalidPayload) {
            try ExchangeMessageEnvelope.decode(JSONEncoder().encode(tamperedCard))
        }
    }

    @Test func catalogEnforcesCountsAndNeverPublishesRecipeNotes() throws {
        let entry = try FernletMessagesRecipeCatalogEntry(packet: recipePacket())
        let catalog = try FernletMessagesCatalog(recipes: [entry], workouts: [])
        let overLimit = Array(repeating: entry, count: FernletMessagesCatalogLimits.maxRecipes + 1)
        let encoded = try catalog.encodedData()

        #expect(entry.packet.recipe.notes.isEmpty)
        #expect(!(String(data: encoded, encoding: .utf8) ?? "").contains("Serve warm."))
        #expect(throws: ExchangePacketError.unsupportedFormat) {
            try FernletMessagesCatalog(recipes: overLimit, workouts: [])
        }
    }

    @Test func cardStringBoundsRejectAnOversizedTitle() throws {
        let allowedTitle = String(repeating: "x", count: ExchangeLimits.maxCardTitleCharacters)
        let rejectedTitle = allowedTitle + "x"

        _ = try ExchangeCardMetadata(kind: .recipe, title: allowedTitle)
        #expect(throws: ExchangePacketError.invalidCardMetadata) {
            try ExchangeCardMetadata(kind: .recipe, title: rejectedTitle)
        }
    }

    @Test func forwardedMessagesRetainTheSameReplayIdentity() throws {
        let original = try ExchangeMessageEnvelope(workoutPlan: workoutPacket(), scheduledStartDayKey: "2026-09-02")
        let originalURL = try original.messageURL()
        let forwardedURL = try #require(URL(string: originalURL.absoluteString))
        let forwarded = try ExchangeMessageEnvelope.decode(messageURL: forwardedURL)

        guard case .workoutPlan(let originalPacket) = try original.validatedPayload(),
              case .workoutPlan(let forwardedPacket) = try forwarded.validatedPayload() else {
            Issue.record("Expected forwarded workout packets.")
            return
        }
        #expect(originalPacket.packetID == forwardedPacket.packetID)
        #expect(originalPacket.contentHash == forwardedPacket.contentHash)
    }

    @Test func coordinatedCatalogReadsAndWritesRemainValidUnderConcurrency() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let catalog = try FernletMessagesCatalog(
            recipes: [try FernletMessagesRecipeCatalogEntry(packet: recipePacket())], workouts: []
        )
        try FernletMessagesCatalogFileStore(directory: directory).write(catalog)
        let results = await concurrentCatalogOperations(directory: directory, catalog: catalog)

        #expect(results.count == 12)
        #expect(results.allSatisfy { $0 })
        #expect(try FernletMessagesCatalogFileStore(directory: directory).read() == catalog)
    }

    @Test func inboxClearAndExpiryPreventPostWipeMessagesFromReopening() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recipes = FernletMessagesInboxStore(directory: directory)
        let workouts = FernletMessagesWorkoutInboxStore(directory: directory)
        let recipe = try recipes.enqueue(recipePacket())
        let workout = try workouts.enqueue(workoutPacket(), suggestedStartDayKey: "2026-09-02")
        let expiredAt = Date(timeIntervalSinceNow: -FernletMessagesInboxLimits.maximumAge - 1)
        let expired = try workouts.enqueue(try workoutPacket(), suggestedStartDayKey: nil, receivedAt: expiredAt)

        #expect(try workouts.record(id: expired.id) == nil)
        #expect(recipes.clear())
        #expect(workouts.clear())
        #expect(try recipes.record(id: recipe.id) == nil)
        #expect(try workouts.record(id: workout.id) == nil)
    }

    private func recipePacket(name: String = "Training oats") throws -> RecipeExchangePacket {
        let foodID = UUID()
        let recipeID = UUID()
        let food = FoodItem(
            id: foodID,
            name: "Rolled oats",
            servingSize: 40,
            servingUnit: RecipeUnit.gram.rawValue,
            macros: Macros(protein: 5, carbs: 27, fat: 3),
            micronutrients: Micronutrients(),
            category: "test",
            source: .manual,
            tags: ["recipe"]
        )
        let recipe = RecipeDefinition(
            id: recipeID,
            name: name,
            servings: 2,
            ingredients: [RecipeIngredient(foodItemId: foodID, quantity: 80, unit: RecipeUnit.gram.rawValue)],
            notes: "Serve warm.",
            source: "manual",
            createdAt: Date(timeIntervalSince1970: 1_779_664_800),
            updatedAt: Date(timeIntervalSince1970: 1_779_664_800),
            steps: [RecipeStep(text: "Warm the oats.")]
        )
        return try RecipeExchangePacket(recipe: recipe, foodItems: [food], includesNotes: false)
    }

    private func workoutPacket() throws -> WorkoutPlanExchangePacket {
        let plan = CoachPlan(
            title: "Wednesday strength",
            coachDisplayName: "Fernlet Coach",
            days: [CoachPlanDay(dayIndex: 1, title: "Wednesday", sessions: [CoachSession(title: "Strength")])]
        )
        return try WorkoutPlanExchangePacket(plan: plan)
    }

    private func envelopeData(atExactLimitFor envelope: ExchangeMessageEnvelope) throws -> Data {
        let original = try envelope.encodedData()
        let prefix = Data(",\"padding\":\"".utf8)
        let suffix = Data("\"}".utf8)
        let paddingCount = ExchangeLimits.maxMessageEnvelopeBytes - original.count + 1 - prefix.count - suffix.count
        guard paddingCount >= 0 else { throw ExchangePacketError.tooLarge }
        var result = Data(original.dropLast())
        result.append(prefix)
        result.append(Data(repeating: 120, count: paddingCount))
        result.append(suffix)
        return result
    }

    private func concurrentCatalogOperations(
        directory: URL,
        catalog: FernletMessagesCatalog
    ) async -> [Bool] {
        await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for index in 0..<12 {
                group.addTask {
                    do {
                        let store = FernletMessagesCatalogFileStore(directory: directory)
                        if index.isMultiple(of: 2) {
                            try store.write(catalog)
                        } else if try store.read() == nil {
                            return false
                        }
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
    }
}
