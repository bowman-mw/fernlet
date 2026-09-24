import CryptoKit
import FernletDomainModel
import Foundation

/// Portable limits shared by Files, Shortcuts, and Messages. The Messages maximum is deliberately
/// independent from the file maxima; Phase 0's two-device measurement remains a release gate.
public nonisolated enum ExchangeLimits {
    public static let maxRecipePacketBytes = 64 * 1024
    public static let maxWorkoutPlanPacketBytes = CoachPlanLimits.maxPastedBytes
    /// The largest VERSION-1 envelope whose data URL still fits ``maxMessageURLCharacters``.
    ///
    /// Derived, not chosen: the URL is a 50-character `data:` prefix followed by the envelope in
    /// base64, which spends 4 characters on every 3 bytes, so (5,000 − 50) / 4 × 3 = 3,711.
    /// `FernletExchangeTests` pins that the bound is tight. It was 16 KiB until 2026-09-23 — over
    /// four times what Apple documents — so a large recipe passed every check here and then failed
    /// inside `MSConversation.insert` as an unexplained "couldn't insert", instead of meeting the
    /// "too large for Messages, export a file" answer this bound exists to give. Version 1 is read,
    /// never written, since 2026-09-24; ``maxMessageFrameBytes`` is the version-2 bound.
    public static let maxMessageEnvelopeBytes = 3_711
    /// The largest VERSION-2 frame whose data URL still fits ``maxMessageURLCharacters``.
    ///
    /// Derived, not chosen: the URL is the 41-character prefix
    /// `data:application/vnd.fernlet.exchange.v2,` followed by the frame in unpadded base64url —
    /// 4 characters for every 3 bytes, rounded up — so ⌊(5,000 − 41) × 3 / 4⌋ = 3,719.
    /// `ExchangeMessageEnvelopeV2Tests` pins that the bound is tight. The frame is 4 header bytes
    /// and then deflated JSON, so this is a bound on COMPRESSED bytes: what it carries depends on
    /// the content, and the capacity tests there measure it on realistic recipes.
    public static let maxMessageFrameBytes = 3_719
    /// The largest packet a Messages card may carry, in either wire version.
    ///
    /// Equal to the review inbox's per-record cap (``FernletMessagesInboxLimits/maxPacketBytes`` is
    /// defined from it), so a card that decodes can always be handed to Fernlet for review — a
    /// larger one would open in the bubble and then fail at "Review in Fernlet".
    public static let maxMessagePacketBytes = 12 * 1024
    /// The inflate-bomb bound: the most bytes a version-2 frame may declare, and so the most it may
    /// inflate to.
    ///
    /// DEFLATE reaches about 1,032:1, so without this a 3.7 KB frame could claim almost 4 MB inside
    /// a process Messages hosts. One packet at ``maxMessagePacketBytes`` plus the document's own
    /// keys (about 120 bytes; 1 KiB is the margin), and not a byte more.
    public static let maxMessageDocumentBytes = maxMessagePacketBytes + 1_024
    /// Apple's documented ceiling on `MSMessage.url`: "the URL cannot be longer than 5,000
    /// characters" (Messages framework, `MSMessage.url`, checked 2026-09-23). A longer URL fails
    /// with `MSMessageErrorCode.urlExceedsMaxSize`. Raise this only against a measurement on the
    /// current iOS release (`Docs/MessagesExtensionReleaseChecklist.md`, first item), never against
    /// the file limits above.
    public static let maxMessageURLCharacters = 5_000
    public static let maxCardTitleCharacters = 120
    public static let maxCardSenderCharacters = 80
}

/// Builds the portable recipe arm without importing the app's Proximity or private-media code.
///
/// Two forms, one per reader population (multipart recipes, 2026-09-24):
/// - ``payload(for:foodItems:)`` is the form EVERY build reads. It is byte-identical to earlier builds
///   for a one-part recipe; a multipart recipe comes out flattened, with section-labelled steps and no
///   `components` key. The hash-covered v1 ``RecipeExchangePacket`` uses it, because an older reader
///   re-hashes the decoded recipe and an unknown key would fail that hash.
/// - ``componentPayload(for:foodItems:)`` is the same payload plus the `components` partition, for the
///   wires where an unknown key is ignored (pasted share text, the mesh `.local` arm) and for a packet
///   format that versions its own hash.
public nonisolated enum ExchangeRecipePayloadBuilder {
    public static func payload(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> SharedRecipePayload {
        componentPayload(for: recipe, foodItems: foodItems).droppingComponents()
    }

    /// The payload with the multipart partition. A one-part recipe (or one whose parts resolve to fewer
    /// than two non-empty groups) takes the original path unchanged: flat ingredients in stored order,
    /// `steps` passed through verbatim. A multipart recipe resolves each part's ingredients on its own,
    /// so an ingredient dropped as unresolvable shrinks only its own part's count.
    public static func componentPayload(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> SharedRecipePayload {
        let parts = recipe.resolvedComponents
        guard parts.count >= RecipeComponentLimits.minComponents else {
            return SharedRecipePayload(
                name: recipe.name,
                servings: recipe.servings,
                notes: recipe.notes,
                ingredients: sharedIngredients(for: recipe.ingredients, foodItems: foodItems),
                steps: recipe.steps
            )
        }
        let contents = parts.map { part in
            SharedRecipeComponentContent(name: part.name ?? "",
                                         ingredients: sharedIngredients(for: part.ingredients, foodItems: foodItems),
                                         steps: part.steps)
        }
        return SharedRecipePayload.assembled(name: recipe.name, servings: recipe.servings, notes: recipe.notes,
                                             parts: contents)
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

/// The additional recipe constraints historically enforced by the app-side share codec, plus the
/// multipart partition's shape when a payload carries one.
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
        guard ingredientsAreValid(payload.ingredients), stepsAreValid(payload.steps ?? []),
              componentsAreValid(payload) else {
            throw ExchangePacketError.invalidPayload
        }
    }

    /// A payload built in-process never passed the decoder's partition gate, so check it here too: no
    /// partition, or one that matches the flat arrays exactly.
    private static func componentsAreValid(_ payload: SharedRecipePayload) -> Bool {
        guard let components = payload.components else { return true }
        return SharedRecipeComponent.isValidPartition(
            components, ingredientCount: payload.ingredients.count, stepCount: payload.steps?.count ?? 0
        )
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
        guard packet.includesNotes == !packet.recipe.notes.isEmpty else {
            throw ExchangePacketError.invalidPayload
        }
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

/// The standalone, serverless `MSMessage.url` payload: one packet plus the bounded card that
/// describes it. It has a far smaller size budget than a file packet, so an item too large for a
/// card falls back to the `.fernletrecipe` / `.fernletplan` file workflow.
///
/// **Two wire versions, both read.** Version 2, written since 2026-09-24, nests the packet as raw
/// JSON in a small document that ``ExchangeMessageWireV2`` deflates and base64url-encodes once, and
/// carries no card — the receiver derives it. Version 1, written by the 2026-09-23 build, is this
/// type's own JSON (the packet base64'd into `packetData`, the card alongside) base64'd again into
/// the URL; a card already sitting in a conversation must keep opening, so it is still read. The
/// URL prefix picks the reader, and each reader accepts only its own encoding.
///
/// The stored properties are the decoded, validated value either way. `formatVersion` records the
/// wire an envelope came from or will be written to, and an envelope whose `formatVersion` is 1
/// still encodes exactly as the 2026-09-23 build did — the tests mint legacy bubbles that way; no
/// production path does. The `Codable` conformance IS the version-1 wire and must not change.
public nonisolated struct ExchangeMessageEnvelope: Codable, Equatable, Sendable {
    public static let format = "fernlet.exchange.message"
    /// The wire version this build writes.
    public static let formatVersion = 2
    /// The 2026-09-23 wire. Read, never written.
    public static let legacyFormatVersion = 1
    private static let legacyDataURLPrefix = "data:application/vnd.fernlet.exchange+json;base64,"

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

    /// The wire bytes for this envelope's own version: a version-2 frame (at most
    /// ``ExchangeLimits/maxMessageFrameBytes``) or the version-1 JSON (at most
    /// ``ExchangeLimits/maxMessageEnvelopeBytes``). ``ExchangePacketError/tooLarge`` means the item
    /// needs a file instead of a card.
    public func encodedData() throws -> Data {
        try validate()
        guard formatVersion == Self.legacyFormatVersion else {
            return try ExchangeMessageWireV2.frame(document: ExchangeCoder.encode(currentDocument()))
        }
        let data = try ExchangeCoder.encode(self)
        guard data.count <= ExchangeLimits.maxMessageEnvelopeBytes else { throw ExchangePacketError.tooLarge }
        return data
    }

    public func messageURL() throws -> URL {
        let data = try encodedData()
        let urlText = formatVersion == Self.legacyFormatVersion
            ? Self.legacyDataURLPrefix + data.base64EncodedString()
            : ExchangeMessageWireV2.dataURLPrefix + ExchangeMessageWireV2.base64URLEncoded(data)
        guard urlText.utf8.count <= ExchangeLimits.maxMessageURLCharacters,
              let url = URL(string: urlText) else { throw ExchangePacketError.invalidMessageURL }
        return url
    }

    /// Reads either version's wire bytes. Version-1 JSON always opens with `{`; anything else must
    /// be a version-2 frame, whose own header check rejects it otherwise.
    public static func decode(_ data: Data) throws -> ExchangeMessageEnvelope {
        guard !data.isEmpty else { throw ExchangePacketError.invalidPayload }
        guard data.first == UInt8(ascii: "{") else { return try decodeCurrent(frame: data) }
        return try decodeLegacy(data)
    }

    /// Reads a card's URL. The prefix picks the version, and each version's reader accepts only its
    /// own encoding — version-2 base64url behind the version-2 prefix, version-1 JSON in standard
    /// base64 behind the version-1 prefix — so no URL has two readings.
    public static func decode(messageURL: URL) throws -> ExchangeMessageEnvelope {
        let text = messageURL.absoluteString
        guard text.utf8.count <= ExchangeLimits.maxMessageURLCharacters else { throw ExchangePacketError.invalidMessageURL }
        if text.hasPrefix(ExchangeMessageWireV2.dataURLPrefix) {
            let body = String(text.dropFirst(ExchangeMessageWireV2.dataURLPrefix.count))
            return try decodeCurrent(frame: ExchangeMessageWireV2.base64URLDecoded(body))
        }
        guard text.hasPrefix(legacyDataURLPrefix) else { throw ExchangePacketError.invalidMessageURL }
        let encoded = String(text.dropFirst(legacyDataURLPrefix.count))
        guard let data = Data(base64Encoded: encoded) else { throw ExchangePacketError.invalidMessageURL }
        return try decodeLegacy(data)
    }

    private static func decodeLegacy(_ data: Data) throws -> ExchangeMessageEnvelope {
        guard data.count <= ExchangeLimits.maxMessageEnvelopeBytes else { throw ExchangePacketError.tooLarge }
        let envelope = try ExchangeCoder.decode(ExchangeMessageEnvelope.self, from: data)
        guard envelope.formatVersion == legacyFormatVersion else { throw ExchangePacketError.invalidPayload }
        try envelope.validate()
        return envelope
    }

    /// Bounded inflate first (``ExchangeMessageWireV2``), then the document, then the ordinary
    /// initializer — which re-validates the nested packet through its own `decode`, hash included,
    /// and derives the card from it.
    private static func decodeCurrent(frame: Data) throws -> ExchangeMessageEnvelope {
        let bytes = try ExchangeMessageWireV2.document(fromFrame: frame)
        let document = try ExchangeCoder.decode(ExchangeMessageDocument.self, from: bytes)
        guard document.format == format, document.formatVersion == formatVersion else {
            throw ExchangePacketError.unsupportedFormat
        }
        switch (document.recipe, document.workoutPlan) {
        case (let recipe?, nil):
            guard document.scheduledStartDayKey == nil else { throw ExchangePacketError.invalidPayload }
            return try ExchangeMessageEnvelope(recipe: recipe)
        case (nil, let plan?):
            return try ExchangeMessageEnvelope(workoutPlan: plan, scheduledStartDayKey: document.scheduledStartDayKey)
        default:
            throw ExchangePacketError.invalidPayload
        }
    }

    /// The version-2 document for this envelope's already-validated packet.
    private func currentDocument() throws -> ExchangeMessageDocument {
        switch try validatedPayload() {
        case .recipe(let packet):
            return ExchangeMessageDocument(format: Self.format, formatVersion: Self.formatVersion,
                                           recipe: packet, workoutPlan: nil, scheduledStartDayKey: nil)
        case .workoutPlan(let packet):
            return ExchangeMessageDocument(format: Self.format, formatVersion: Self.formatVersion, recipe: nil,
                                           workoutPlan: packet, scheduledStartDayKey: scheduledStartDayKey)
        }
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
        guard format == Self.format,
              formatVersion == Self.formatVersion || formatVersion == Self.legacyFormatVersion,
              !packetData.isEmpty, card.kind == kind else { throw ExchangePacketError.invalidPayload }
        guard packetData.count <= packetByteLimit else { throw ExchangePacketError.tooLarge }
        try card.validate()
        let canonicalCard = try canonicalCardMetadata()
        guard card == canonicalCard,
              kind == .workoutPlan || scheduledStartDayKey == nil else {
            throw ExchangePacketError.invalidPayload
        }
    }

    /// Version 1 packed the packet into a URL-sized envelope; version 2 carries any packet the
    /// review inbox accepts, and the frame bound then decides whether it compresses small enough.
    private var packetByteLimit: Int {
        formatVersion == Self.legacyFormatVersion
            ? ExchangeLimits.maxMessageEnvelopeBytes
            : ExchangeLimits.maxMessagePacketBytes
    }
}

/// The JSON document a version-2 Messages frame deflates.
///
/// The packet travels as raw JSON under the key named for its kind — exactly one of `recipe` and
/// `workoutPlan` — rather than as base64 bytes inside a string, which is what version 1 paid a
/// second base64 pass for. There is deliberately no card: the receiver derives it from the packet
/// (version 1 carried one only to reject it when it disagreed). `scheduledStartDayKey` is the
/// envelope's one field of its own, and only a workout plan may carry it.
///
/// Decoded only after ``ExchangeMessageWireV2`` has bounded the inflate, and a nested packet decoded
/// here is not yet trusted: ``ExchangeMessageEnvelope`` re-encodes it canonically and runs it
/// through the packet type's own `decode` — bounds, format version and content hash — before the
/// envelope exists. The field set is part of the version-2 wire; changing it needs a version 3.
private nonisolated struct ExchangeMessageDocument: Codable {
    var format: String
    var formatVersion: Int
    var recipe: RecipeExchangePacket?
    var workoutPlan: WorkoutPlanExchangePacket?
    var scheduledStartDayKey: String?
}

/// The decoded, fully validated contents of an ``ExchangeMessageEnvelope``.
///
/// Produced only by ``ExchangeMessageEnvelope/validatedPayload()``, which re-decodes the inner
/// `packetData` through the packet type's own `decode` — so holding a value of this type means the
/// nested packet already passed its size, format-version, and content-hash checks. The case set
/// mirrors ``ExchangePacketKind`` one-for-one; adding a kind means adding a case here.
public nonisolated enum ExchangeMessagePayload: Equatable, Sendable {
    case recipe(RecipeExchangePacket)
    case workoutPlan(WorkoutPlanExchangePacket)
}

/// The single JSON encode/decode seam for every exchange packet and envelope in this file.
///
/// Pins the *canonical* encoding the wire format depends on: `.sortedKeys` makes key order a
/// function of the key names alone, and `.withoutEscapingSlashes` keeps text byte-identical across
/// encodes. Both flags are load-bearing rather than cosmetic — `ExchangeHasher` digests the bytes
/// this produces, so a re-encode of the same value must reproduce them exactly or every previously
/// issued `contentHash` stops verifying. Dates are deliberately absent from these types, which is
/// why no date strategy is set here (the Messages inbox/catalog coders, which do carry dates, pin
/// `.iso8601` themselves).
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

/// Computes the lowercase-hex SHA-256 `contentHash` both packet types carry.
///
/// Integrity, not authentication: an unkeyed digest detects a truncated or edited file, but proves
/// nothing about who produced it (signing/trust lives in the `Proximity` subtree). The digest is
/// taken over `ExchangeCoder`'s canonical bytes, so its stability is exactly that encoder's
/// stability, and the lowercase `%02x` formatting is itself part of the wire value — `contentHash`
/// is compared as a string on decode.
private nonisolated enum ExchangeHasher {
    static func hexDigest<T: Encodable>(of value: T) throws -> String {
        let data = try ExchangeCoder.encode(value)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The frozen pre-image of ``RecipeExchangePacket/contentHash``.
///
/// A separate type from the packet purely so the hash covers every field *except* the hash itself.
/// Its field set, names, and types are **frozen**: they are encoded by `ExchangeCoder` and
/// digested by `ExchangeHasher`, so adding, removing, renaming, or retyping a property here
/// changes the digest of already-exported `.fernletrecipe` files, which then fail
/// ``ExchangePacketError/invalidHash`` on decode. Note `version` maps to the packet's
/// `formatVersion` — that name difference is likewise part of the frozen encoding.
private nonisolated struct RecipeHashInput: Codable {
    var format: String
    var version: Int
    var packetID: UUID
    var originContentID: UUID
    var includesNotes: Bool
    var recipe: SharedRecipePayload
}

/// The frozen pre-image of ``WorkoutPlanExchangePacket/contentHash``.
///
/// Same contract as `RecipeHashInput`: everything the packet carries except `contentHash`, with a
/// field set frozen because it *is* the hashed encoding. It transitively freezes `CoachPlan`'s own
/// coding keys too, since the whole plan is nested inside the digest — plan files exported by the
/// first Shortcut release must keep verifying.
private nonisolated struct WorkoutPlanHashInput: Codable {
    var format: String
    var version: Int
    var packetID: UUID
    var originContentID: UUID
    var plan: CoachPlan
}
