import CryptoKit
import FernletDomainModel
import Foundation

/// Portable limits shared by Files, Shortcuts, and Messages. The Messages maximum is deliberately
/// independent from the file maxima; Phase 0's two-device measurement remains a release gate.
public nonisolated enum ExchangeLimits {
    public static let maxRecipePacketBytes = 64 * 1024
    public static let maxWorkoutPlanPacketBytes = CoachPlanLimits.maxPastedBytes
    public static let maxMessageEnvelopeBytes = 16 * 1024
    public static let maxMessageURLCharacters = 22 * 1024
    public static let maxCardTitleCharacters = 120
    public static let maxCardSenderCharacters = 80
}

/// Builds the portable recipe arm without importing the app's Proximity or private-media code.
public nonisolated enum ExchangeRecipePayloadBuilder {
    public static func payload(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> SharedRecipePayload {
        SharedRecipePayload(
            name: recipe.name,
            servings: recipe.servings,
            notes: recipe.notes,
            ingredients: sharedIngredients(for: recipe.ingredients, foodItems: foodItems),
            steps: recipe.steps
        )
    }

    private static func sharedIngredients(
        for ingredients: [RecipeIngredient],
        foodItems: [FoodItem]
    ) -> [SharedRecipeIngredient] {
        ingredients.compactMap { ingredient in
            guard let foodItem = foodItems.first(where: { $0.id == ingredient.foodItemId }),
                  let conversion = ingredient.servingConversion(using: foodItem) else { return nil }
            let macros = conversion.scaledMacros(for: foodItem)
            return SharedRecipeIngredient(name: foodItem.name, quantity: ingredient.quantity, unit: ingredient.unit,
                                          protein: macros.protein, carbs: macros.carbs, fat: macros.fat)
        }
    }
}

/// The additional recipe constraints historically enforced by the app-side share codec.
public nonisolated enum ExchangeRecipePayloadValidator {
    public static func validate(_ payload: SharedRecipePayload) throws {
        guard payload.format == "fernlet.recipe", payload.version == 1 else {
            throw ExchangePacketError.unsupportedFormat
        }
        guard payload.servings >= 1, payload.servings <= 24,
              payload.name.count <= 200, payload.notes.count <= 4_000,
              payload.ingredients.count <= 100, (payload.steps?.count ?? 0) <= 60 else {
            throw ExchangePacketError.invalidPayload
        }
        guard ingredientsAreValid(payload.ingredients), stepsAreValid(payload.steps ?? []) else {
            throw ExchangePacketError.invalidPayload
        }
    }

    private static func ingredientsAreValid(_ ingredients: [SharedRecipeIngredient]) -> Bool {
        ingredients.allSatisfy { ingredient in
            ingredient.quantity.isFinite && ingredient.quantity > 0 && ingredient.quantity <= 10_000
                && ingredient.protein >= 0 && ingredient.carbs >= 0 && ingredient.fat >= 0
        }
    }

    private static func stepsAreValid(_ steps: [RecipeStep]) -> Bool {
        steps.allSatisfy { step in
            step.text.count <= 2_000 && (step.durationSeconds ?? 0) <= 240 * 60
        }
    }
}

/// Builds the single-day portable plan used by both the file-based Shortcut export and Messages.
/// It accepts a domain value only; repositories and collision/import policy remain in the app.
public nonisolated enum ExchangeWorkoutPlanBuilder {
    public static func oneDayPlan(from workout: PlannedWorkout, dayKey: String) -> CoachPlan {
        let kind = workout.mode == .activity ? SessionKind.cardio.rawValue : SessionKind.strength.rawValue
        let conditioning = workout.exercises.isEmpty ? workout.notes : workout.exercises
        let session = CoachSession(
            title: workout.name,
            kind: kind,
            notes: workout.notes.isEmpty ? nil : workout.notes,
            conditioning: conditioning,
            exercises: []
        )
        let day = CoachPlanDay(dayIndex: 1, title: workout.name, sessions: [session])
        return CoachPlan(
            planID: workout.id,
            title: workout.name,
            coachDisplayName: "Fernlet",
            startPolicy: .fixedDate(dayKey: dayKey),
            days: [day]
        )
    }
}

/// One recipe exchange file. Its wire keys and canonical hash intentionally remain unchanged from
/// the app-target implementation so existing `.fernletrecipe` files stay compatible.
public nonisolated struct RecipeExchangePacket: Codable, Equatable, Sendable {
    public static let format = "fernlet.exchange.recipe"
    public static let formatVersion = 1

    public var format: String
    public var formatVersion: Int
    public var packetID: UUID
    public var originContentID: UUID
    public var includesNotes: Bool
    public var recipe: SharedRecipePayload
    public var contentHash: String

    public init(recipe definition: RecipeDefinition, foodItems: [FoodItem], includesNotes: Bool) throws {
        var payload = ExchangeRecipePayloadBuilder.payload(for: definition, foodItems: foodItems)
        if !includesNotes { payload.notes = "" }
        format = Self.format
        formatVersion = Self.formatVersion
        packetID = definition.id
        originContentID = definition.id
        self.includesNotes = includesNotes && !payload.notes.isEmpty
        recipe = payload
        contentHash = try Self.hash(format: format, version: formatVersion, packetID: packetID,
                                    originContentID: originContentID, includesNotes: self.includesNotes, recipe: recipe)
        try ExchangeRecipePayloadValidator.validate(recipe)
    }

    public func encodedData() throws -> Data {
        let data = try ExchangeCoder.encode(self)
        guard data.count <= ExchangeLimits.maxRecipePacketBytes else { throw ExchangePacketError.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> RecipeExchangePacket {
        guard data.count <= ExchangeLimits.maxRecipePacketBytes else { throw ExchangePacketError.tooLarge }
        let packet = try ExchangeCoder.decode(RecipeExchangePacket.self, from: data)
        guard packet.format == format, packet.formatVersion == formatVersion else {
            throw ExchangePacketError.unsupportedFormat
        }
        let expected = try hash(format: packet.format, version: packet.formatVersion, packetID: packet.packetID,
                                originContentID: packet.originContentID, includesNotes: packet.includesNotes, recipe: packet.recipe)
        guard packet.contentHash == expected else { throw ExchangePacketError.invalidHash }
        try ExchangeRecipePayloadValidator.validate(packet.recipe)
        return packet
    }

    private static func hash(
        format: String, version: Int, packetID: UUID, originContentID: UUID,
        includesNotes: Bool, recipe: SharedRecipePayload
    ) throws -> String {
        let input = RecipeHashInput(format: format, version: version, packetID: packetID,
                                    originContentID: originContentID, includesNotes: includesNotes, recipe: recipe)
        return try ExchangeHasher.hexDigest(of: input)
    }
}

/// One portable coach-plan exchange file. Its schema and canonical hash match the first file-based
/// Shortcut release exactly, enabling the shared core to read all already-exported plan files.
public nonisolated struct WorkoutPlanExchangePacket: Codable, Equatable, Sendable {
    public static let format = "fernlet.exchange.workout-plan"
    public static let formatVersion = 1

    public var format: String
    public var formatVersion: Int
    public var packetID: UUID
    public var originContentID: UUID
    public var plan: CoachPlan
    public var contentHash: String

    public init(plan: CoachPlan) throws {
        format = Self.format
        formatVersion = Self.formatVersion
        packetID = plan.planID
        originContentID = plan.planID
        self.plan = plan
        contentHash = try Self.hash(format: format, version: formatVersion, packetID: packetID,
                                    originContentID: originContentID, plan: plan)
    }

    public func encodedData() throws -> Data {
        let data = try ExchangeCoder.encode(self)
        guard data.count <= ExchangeLimits.maxWorkoutPlanPacketBytes else { throw ExchangePacketError.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> WorkoutPlanExchangePacket {
        guard data.count <= ExchangeLimits.maxWorkoutPlanPacketBytes else { throw ExchangePacketError.tooLarge }
        let packet = try ExchangeCoder.decode(WorkoutPlanExchangePacket.self, from: data)
        guard packet.format == format, packet.formatVersion == formatVersion else {
            throw ExchangePacketError.unsupportedFormat
        }
        let expected = try hash(format: packet.format, version: packet.formatVersion, packetID: packet.packetID,
                                originContentID: packet.originContentID, plan: packet.plan)
        guard packet.contentHash == expected else { throw ExchangePacketError.invalidHash }
        return packet
    }

    private static func hash(
        format: String, version: Int, packetID: UUID, originContentID: UUID, plan: CoachPlan
    ) throws -> String {
        try ExchangeHasher.hexDigest(of: WorkoutPlanHashInput(format: format, version: version, packetID: packetID,
                                                               originContentID: originContentID, plan: plan))
    }
}

/// Packet failures intentionally contain no persistence or UI policy, so both host processes can
/// reject invalid bytes before they consider opening a repository or showing a card.
public nonisolated enum ExchangePacketError: Error, Equatable {
    case tooLarge
    case unsupportedFormat
    case invalidHash
    case invalidPayload
    case invalidMessageURL
    case invalidCardMetadata
}

/// The packet kind bound into a versioned Messages envelope.
public nonisolated enum ExchangePacketKind: String, Codable, Equatable, Sendable {
    case recipe
    case workoutPlan
}

/// Bounded visual metadata for a rich message card. It is never used as import data; consumers
/// independently validate `packetData` and derive their canonical import preview from that packet.
public nonisolated struct ExchangeCardMetadata: Codable, Equatable, Sendable {
    public var kind: ExchangePacketKind
    public var title: String
    public var senderLabel: String?
    public var servings: Int?
    public var ingredientCount: Int?
    public var stepCount: Int?
    public var workoutCount: Int?
    public var durationMinutes: Int?
    /// The sender's suggested first day for a workout plan. It stays display-only until the
    /// recipient explicitly approves it in Fernlet's import review.
    public var scheduledStartDayKey: String?

    public static func recipe(from packet: RecipeExchangePacket) throws -> ExchangeCardMetadata {
        try ExchangeCardMetadata(kind: .recipe, title: packet.recipe.name, servings: packet.recipe.servings,
                                 ingredientCount: packet.recipe.ingredients.count,
                                 stepCount: packet.recipe.steps?.count)
    }

    public static func workoutPlan(
        from packet: WorkoutPlanExchangePacket,
        scheduledStartDayKey: String? = nil
    ) throws -> ExchangeCardMetadata {
        let sender = packet.plan.coachDisplayName.isEmpty ? nil : packet.plan.coachDisplayName
        return try ExchangeCardMetadata(kind: .workoutPlan, title: packet.plan.title, senderLabel: sender,
                                        workoutCount: packet.plan.sessionCount,
                                        scheduledStartDayKey: scheduledStartDayKey)
    }

    public init(
        kind: ExchangePacketKind, title: String, senderLabel: String? = nil, servings: Int? = nil,
        ingredientCount: Int? = nil, stepCount: Int? = nil,
        workoutCount: Int? = nil, durationMinutes: Int? = nil, scheduledStartDayKey: String? = nil
    ) throws {
        self.kind = kind
        self.title = title
        self.senderLabel = senderLabel
        self.servings = servings
        self.ingredientCount = ingredientCount
        self.stepCount = stepCount
        self.workoutCount = workoutCount
        self.durationMinutes = durationMinutes
        self.scheduledStartDayKey = scheduledStartDayKey
        try validate()
    }

    public func validate() throws {
        guard title.count <= ExchangeLimits.maxCardTitleCharacters,
              senderLabel?.count ?? 0 <= ExchangeLimits.maxCardSenderCharacters,
              countIsValid(servings), countIsValid(ingredientCount), countIsValid(stepCount),
              countIsValid(workoutCount), countIsValid(durationMinutes),
              scheduledStartDayKey.map(Self.isWellFormedDayKey) ?? true else {
            throw ExchangePacketError.invalidCardMetadata
        }
    }

    private func countIsValid(_ value: Int?) -> Bool {
        guard let value else { return true }
        return value >= 0 && value <= 10_000
    }

    private static func isWellFormedDayKey(_ value: String) -> Bool {
        guard value.utf8.count == 10 else { return false }
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 10, scalars[4] == "-", scalars[7] == "-" else { return false }
        for index in [0, 1, 2, 3, 5, 6, 8, 9] {
            guard CharacterSet.decimalDigits.contains(scalars[index]) else { return false }
        }
        return true
    }
}

/// The standalone, serverless `MSMessage.url` payload. It has a stricter provisional size budget
/// than a file packet, so a large plan can fall back to the existing `.fernletplan` workflow.
public nonisolated struct ExchangeMessageEnvelope: Codable, Equatable, Sendable {
    public static let format = "fernlet.exchange.message"
    public static let formatVersion = 1
    private static let dataURLPrefix = "data:application/vnd.fernlet.exchange+json;base64,"

    public var format: String
    public var formatVersion: Int
    public var kind: ExchangePacketKind
    public var packetData: Data
    public var card: ExchangeCardMetadata
    /// A sender-supplied date suggestion, bound into the envelope but revalidated against the
    /// recipient's calendar immediately before any import.
    public var scheduledStartDayKey: String?

    public init(recipe packet: RecipeExchangePacket) throws {
        format = Self.format
        formatVersion = Self.formatVersion
        kind = .recipe
        packetData = try packet.encodedData()
        card = try ExchangeCardMetadata.recipe(from: packet)
        scheduledStartDayKey = nil
        try validate()
    }

    public init(
        workoutPlan packet: WorkoutPlanExchangePacket,
        scheduledStartDayKey: String? = nil
    ) throws {
        format = Self.format
        formatVersion = Self.formatVersion
        kind = .workoutPlan
        packetData = try packet.encodedData()
        card = try ExchangeCardMetadata.workoutPlan(from: packet, scheduledStartDayKey: scheduledStartDayKey)
        self.scheduledStartDayKey = scheduledStartDayKey
        try validate()
    }

    public func encodedData() throws -> Data {
        try validate()
        let data = try ExchangeCoder.encode(self)
        guard data.count <= ExchangeLimits.maxMessageEnvelopeBytes else { throw ExchangePacketError.tooLarge }
        return data
    }

    public func messageURL() throws -> URL {
        let urlText = Self.dataURLPrefix + (try encodedData()).base64EncodedString()
        guard urlText.utf8.count <= ExchangeLimits.maxMessageURLCharacters,
              let url = URL(string: urlText) else { throw ExchangePacketError.invalidMessageURL }
        return url
    }

    public static func decode(_ data: Data) throws -> ExchangeMessageEnvelope {
        guard data.count <= ExchangeLimits.maxMessageEnvelopeBytes else { throw ExchangePacketError.tooLarge }
        let envelope = try ExchangeCoder.decode(ExchangeMessageEnvelope.self, from: data)
        try envelope.validate()
        return envelope
    }

    public static func decode(messageURL: URL) throws -> ExchangeMessageEnvelope {
        let text = messageURL.absoluteString
        guard text.hasPrefix(dataURLPrefix), text.utf8.count <= ExchangeLimits.maxMessageURLCharacters else {
            throw ExchangePacketError.invalidMessageURL
        }
        let encoded = String(text.dropFirst(dataURLPrefix.count))
        guard let data = Data(base64Encoded: encoded) else { throw ExchangePacketError.invalidMessageURL }
        return try decode(data)
    }

    public func validatedPayload() throws -> ExchangeMessagePayload {
        switch kind {
        case .recipe: return .recipe(try RecipeExchangePacket.decode(packetData))
        case .workoutPlan: return .workoutPlan(try WorkoutPlanExchangePacket.decode(packetData))
        }
    }

    public func canonicalCardMetadata() throws -> ExchangeCardMetadata {
        switch try validatedPayload() {
        case .recipe(let packet): return try .recipe(from: packet)
        case .workoutPlan(let packet):
            return try .workoutPlan(from: packet, scheduledStartDayKey: scheduledStartDayKey)
        }
    }

    private func validate() throws {
        guard format == Self.format, formatVersion == Self.formatVersion,
              packetData.count > 0, packetData.count <= ExchangeLimits.maxMessageEnvelopeBytes,
              card.kind == kind else { throw ExchangePacketError.invalidPayload }
        try card.validate()
        let canonicalCard = try canonicalCardMetadata()
        guard card == canonicalCard,
              kind == .workoutPlan || scheduledStartDayKey == nil else {
            throw ExchangePacketError.invalidPayload
        }
    }
}

public nonisolated enum ExchangeMessagePayload: Equatable, Sendable {
    case recipe(RecipeExchangePacket)
    case workoutPlan(WorkoutPlanExchangePacket)
}

private nonisolated enum ExchangeCoder {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

private nonisolated enum ExchangeHasher {
    static func hexDigest<T: Encodable>(of value: T) throws -> String {
        let data = try ExchangeCoder.encode(value)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private nonisolated struct RecipeHashInput: Codable {
    var format: String
    var version: Int
    var packetID: UUID
    var originContentID: UUID
    var includesNotes: Bool
    var recipe: SharedRecipePayload
}

private nonisolated struct WorkoutPlanHashInput: Codable {
    var format: String
    var version: Int
    var packetID: UUID
    var originContentID: UUID
    var plan: CoachPlan
}
