import Foundation
import Testing
import CryptoKit
import FernletDomainModel
import FernletExchange
@testable import ProximityKit
@testable import Fernlet

/// Multipart recipes on every wire (2026-09-24). A multipart recipe rides `fernlet.recipe` VERSION 1:
/// flat arrays in part order, section-labelled steps, and one optional `components` partition. So:
/// - an older reader (mirrored below by the PRE-multipart shapes) reads a whole, flattened recipe;
/// - a newer reader rebuilds the parts exactly;
/// - a one-part recipe's bytes are identical to every earlier build's;
/// - the hash-covered exchange packet (Files, Shortcuts, Messages) carries a one-part recipe as format
///   version 1, which an older reader re-hashes exactly, and a multipart recipe as version 2 with its
///   parts (W2-messages-v2), which an older reader refuses cleanly as a format it does not know.
@MainActor
struct RecipeMultipartWireTests {

    // MARK: - Mirrors of what an OLDER build decodes

    /// The PRE-multipart `SharedRecipePayload`: deliberately has NO `components` property. Decoding a
    /// multipart payload into it is exactly what an older build's paste import and mesh receive do.
    private struct PreMultipartPayload: Codable, Equatable {
        var format: String
        var version: Int
        var name: String
        var servings: Int
        var notes: String
        var ingredients: [SharedRecipeIngredient]
        var steps: [RecipeStep]?
    }

    /// The PRE-multipart exchange packet an older build decodes, and its hash pre-image, field for field
    /// (`RecipeHashInput`'s frozen shape). An older reader re-hashes THIS, so a v1 packet verifies on
    /// older builds exactly when this re-hash equals the packet's `contentHash`.
    private struct PreMultipartPacket: Codable {
        var format: String
        var formatVersion: Int
        var packetID: UUID
        var originContentID: UUID
        var includesNotes: Bool
        var recipe: PreMultipartPayload
        var contentHash: String
    }

    /// The frozen hash pre-image an older build computes, field for field.
    private struct PreMultipartHashInput: Codable {
        var format: String
        var version: Int
        var packetID: UUID
        var originContentID: UUID
        var includesNotes: Bool
        var recipe: PreMultipartPayload
    }

    // MARK: - Goldens: the published schema, byte for byte

    @Test func theSaladComponentPayloadMatchesThePublishedGolden() throws {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let built = ExchangeRecipePayloadBuilder.componentPayload(for: salad.recipe, foodItems: salad.foodItems)

        #expect(built == RecipeMultipartFixtures.saladPayload())
        #expect(try canonicalJSON(built) == RecipeMultipartFixtures.saladPayloadGoldenJSON)
        #expect(RecipeShareCodec.payload(for: salad.recipe, foodItems: salad.foodItems) == built)
    }

    @Test func aOnePartRecipeEncodesByteIdenticallyToThePreMultipartShape() throws {
        var recipe = RecipeMultipartFixtures.saladWithHomemadeDressing().recipe
        recipe.components = nil
        let foods = RecipeMultipartFixtures.saladWithHomemadeDressing().foodItems
        let payload = ExchangeRecipePayloadBuilder.componentPayload(for: recipe, foodItems: foods)
        let json = try canonicalJSON(payload)

        #expect(payload.components == nil)
        #expect(!json.contains("components"))
        #expect(ExchangeRecipePayloadBuilder.payload(for: recipe, foodItems: foods) == payload)
        let legacy = PreMultipartPayload(format: payload.format, version: payload.version, name: payload.name,
                                         servings: payload.servings, notes: payload.notes,
                                         ingredients: payload.ingredients, steps: payload.steps)
        #expect(try canonicalJSON(legacy) == json)
        #expect(json.contains(#""text":"Whisk the lemon juice, mustard and honey.""#))   // no label on one part
    }

    // MARK: - The flattening an older reader gets

    @Test func theV1ReaderFormIsThePayloadMinusItsPartition() {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let full = ExchangeRecipePayloadBuilder.componentPayload(for: salad.recipe, foodItems: salad.foodItems)
        let flat = ExchangeRecipePayloadBuilder.payload(for: salad.recipe, foodItems: salad.foodItems)

        #expect(flat == full.droppingComponents())
        #expect(flat.components == nil)
        #expect(flat.version == 1)
        #expect(flat.ingredients.count == 9)
        #expect(flat.steps?.map(\.text).first == "Lemon-dijon dressing: Whisk the lemon juice, mustard and honey.")
        #expect(flat.steps?.map(\.text).last == "Salad: Toss the salad with the dressing just before serving.")
        #expect(flat.steps?[2].durationSeconds == 480)
    }

    @Test func anOlderBuildReadsAMultipartShareAsAWholeFlatRecipe() throws {
        let data = try JSONEncoder().encode(RecipeMultipartFixtures.saladPayload())
        let old = try JSONDecoder().decode(PreMultipartPayload.self, from: data)

        #expect(old.version == 1)
        #expect(old.ingredients.count == 9)
        #expect(old.steps?.count == 5)
        #expect(old.steps?.allSatisfy { $0.text.hasPrefix("Lemon-dijon dressing: ") || $0.text.hasPrefix("Salad: ") } == true)
        // An older build's own validator (unchanged checks; the partition is invisible to it) accepts it.
        let olderView = SharedRecipePayload(name: old.name, servings: old.servings, notes: old.notes,
                                            ingredients: old.ingredients, steps: old.steps)
        #expect(throws: Never.self) { try ExchangeRecipePayloadValidator.validate(olderView) }
    }

    @Test func aNewerReaderRebuildsThePartsExactly() throws {
        let payload = try JSONDecoder().decode(SharedRecipePayload.self,
                                               from: Data(RecipeMultipartFixtures.saladPayloadGoldenJSON.utf8))
        let parts = try #require(payload.componentSlices)

        #expect(parts.map(\.name) == [RecipeMultipartFixtures.dressingName, RecipeMultipartFixtures.saladName])
        #expect(parts.map(\.ingredients.count) == [4, 5])
        #expect(parts[0].steps == RecipeMultipartFixtures.dressingSteps)
        #expect(parts[1].steps == RecipeMultipartFixtures.saladSteps)
    }

    // MARK: - The partition gate (strict: every decode path)

    @Test func malformedPartitionsAreRefusedAtDecode() {
        let golden = RecipeMultipartFixtures.saladPayloadGoldenJSON
        let broken = [
            golden.replacingOccurrences(of: #""ingredientCount":5"#, with: #""ingredientCount":4"#),
            golden.replacingOccurrences(of: #""stepCount":3"#, with: #""stepCount":4"#),
            golden.replacingOccurrences(of: #""ingredientCount":4,"name""#, with: #""ingredientCount":-1,"name""#),
            golden.replacingOccurrences(of: #""name":"Salad","#, with: #""name":"   ","#),
            golden.replacingOccurrences(of: #""name":"Salad","#, with: #""name":"Sal\nad","#),
            golden.replacingOccurrences(of: #""name":"Salad","#,
                                        with: #""name":"\#(String(repeating: "s", count: 41))","#),
            golden.replacingOccurrences(
                of: #"{"ingredientCount":4,"name":"Lemon-dijon dressing","stepCount":2},"#, with: "")
        ]
        for text in broken {
            #expect(throws: RecipeImportError.invalidPayload) { try RecipeShareCodec.decodePayload(from: text) }
        }
    }

    @Test func partitionShapeRulesHoldForInProcessPayloadsToo() {
        let good = RecipeMultipartFixtures.saladPayload()
        #expect(throws: Never.self) { try ExchangeRecipePayloadValidator.validate(good) }

        var mismatched = good
        mismatched.ingredients.removeLast()
        #expect(throws: ExchangePacketError.invalidPayload) { try ExchangeRecipePayloadValidator.validate(mismatched) }

        let empty = SharedRecipeComponent(name: "Empty", ingredientCount: 0, stepCount: 0)
        let parts = [SharedRecipeComponent(name: "Everything", ingredientCount: 9, stepCount: 5), empty]
        #expect(!SharedRecipeComponent.isValidPartition(parts, ingredientCount: 9, stepCount: 5))
        let thirteen = Array(repeating: SharedRecipeComponent(name: "P", ingredientCount: 1, stepCount: 0), count: 13)
        #expect(!SharedRecipeComponent.isValidPartition(thirteen, ingredientCount: 13, stepCount: 0))
        let single = [SharedRecipeComponent(name: "Only", ingredientCount: 9, stepCount: 5)]
        #expect(!SharedRecipeComponent.isValidPartition(single, ingredientCount: 9, stepCount: 5))
        let huge = [SharedRecipeComponent(name: "A", ingredientCount: .max, stepCount: .max),
                    SharedRecipeComponent(name: "B", ingredientCount: 1, stepCount: 1)]
        #expect(!SharedRecipeComponent.isValidPartition(huge, ingredientCount: 0, stepCount: 0))   // no overflow trap
    }

    // MARK: - Step labels

    @Test func aLabelThatWouldBreakTheStepCapIsSkippedAndNothingIsLost() {
        let long = RecipeStep(text: String(repeating: "w", count: 1_990))
        let labelled = RecipeComponentWire.labelled(long, partName: RecipeMultipartFixtures.dressingName)
        #expect(labelled == long)
        #expect(RecipeComponentWire.unlabelled(labelled, partName: RecipeMultipartFixtures.dressingName) == long)
    }

    @Test func aStepThatAlreadyStartsWithItsLabelRoundTrips() {
        let step = RecipeStep(text: "Salad: toss everything")
        let wire = RecipeComponentWire.labelled(step, partName: "Salad")
        #expect(wire.text == "Salad: Salad: toss everything")
        #expect(RecipeComponentWire.unlabelled(wire, partName: "Salad") == step)
    }

    @Test func aStepStartingWithACombiningMarkIsLeftUnlabelledRatherThanCorrupted() {
        let step = RecipeStep(text: "\u{301}accent first")
        let wire = RecipeComponentWire.labelled(step, partName: "Salad")
        #expect(RecipeComponentWire.unlabelled(wire, partName: "Salad").text == step.text)
    }

    // MARK: - Withheld steps ("Include notes" off)

    @Test func withholdingStepsRewritesThePartitionToMatch() throws {
        var payload = RecipeMultipartFixtures.saladPayload()
        let stripped = payload.withoutSteps()
        #expect(stripped.steps == nil)
        #expect(stripped.components?.map(\.stepCount) == [0, 0])
        #expect(stripped.components?.map(\.ingredientCount) == [4, 5])
        let reread = try JSONDecoder().decode(SharedRecipePayload.self, from: JSONEncoder().encode(stripped))
        #expect(reread.componentSlices?.map(\.ingredients.count) == [4, 5])

        // A steps-only part vanishes with its steps; one part left means no partition at all.
        payload.components = [SharedRecipeComponent(name: "Everything", ingredientCount: 9, stepCount: 2),
                              SharedRecipeComponent(name: "Assemble", ingredientCount: 0, stepCount: 3)]
        #expect(payload.withoutSteps().components == nil)
    }

    @Test func aMeshShareWithNotesOffStillDecodesAndKeepsItsParts() throws {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let share = RecipeShareCodec.proximityPayload(for: salad.recipe, foodItems: salad.foodItems)
        let withheld = share.omittingShareNotes()
        let received = try JSONDecoder().decode(ProximityRecipeSharePayload.self, from: JSONEncoder().encode(withheld))

        let local = try #require(received.recipe.local)
        #expect(local.steps == nil)
        #expect(local.notes.isEmpty)
        #expect(local.componentSlices?.map(\.name) == [RecipeMultipartFixtures.dressingName, RecipeMultipartFixtures.saladName])
        #expect(received.hasShareNotes == false)
    }

    // MARK: - The exchange packet (Files, Shortcuts, Messages): one part stays v1, parts travel as v2

    /// A multipart recipe travels the exchange packet as format version 2, WITH its parts (it used to
    /// go out flattened in version 1, losing them new-to-new). An older build reads the packet's
    /// version first and accepts only 1, so it refuses the file cleanly as a format it does not know
    /// — never as corrupt, which is what a partition inside a version-1 packet would have caused.
    @Test func aMultipartRecipeTravelsAsPacketVersion2WhichOlderBuildsRefuseCleanly() throws {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let packet = try RecipeExchangePacket(recipe: salad.recipe, foodItems: salad.foodItems, includesNotes: true)
        #expect(packet.formatVersion == RecipeExchangePacket.multipartFormatVersion)
        #expect(packet.recipe.components?.map(\.name) == [RecipeMultipartFixtures.dressingName, RecipeMultipartFixtures.saladName])

        let data = try packet.encodedData()
        #expect(try RecipeExchangePacket.decode(data) == packet)
        let older = try JSONDecoder().decode(PreMultipartPacket.self, from: data)
        #expect(older.formatVersion != 1, "an older build's `formatVersion == 1` gate refuses it as unsupportedFormat")
    }

    @Test func aOnePartRecipesPacketHashIsWhatOlderBuildsCompute() throws {
        var recipe = RecipeMultipartFixtures.saladWithHomemadeDressing().recipe
        recipe.components = nil
        let foods = RecipeMultipartFixtures.saladWithHomemadeDressing().foodItems
        let packet = try RecipeExchangePacket(recipe: recipe, foodItems: foods, includesNotes: true)

        #expect(try olderBuildRehash(packet.encodedData()) == packet.contentHash)
    }

    /// A Messages card carries the multipart recipe whole: its parts come back out on the other side.
    @Test func aMultipartRecipeFitsAMessagesCardWithItsParts() throws {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let packet = try RecipeExchangePacket(recipe: salad.recipe, foodItems: salad.foodItems, includesNotes: true)
        let envelope = try ExchangeMessageEnvelope(recipe: packet)
        let url = try envelope.messageURL()

        let decoded = try ExchangeMessageEnvelope.decode(messageURL: url)
        #expect(decoded.card.ingredientCount == 9)
        #expect(decoded.card.stepCount == 5)
        guard case .recipe(let received) = try decoded.validatedPayload() else {
            Issue.record("Expected a recipe packet.")
            return
        }
        #expect(received.recipe.componentSlices?.map(\.name) == [RecipeMultipartFixtures.dressingName, RecipeMultipartFixtures.saladName])
    }

    // MARK: - Import: every path rebuilds the parts

    @Test func pastedShareTextImportsTheRecipeWithItsParts() throws {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let store = makeTestStore()
        let text = RecipeShareCodec.shareText(for: salad.recipe, foodItems: salad.foodItems)

        let imported = try store.importRecipe(from: text)
        try expectRebuiltSalad(imported, in: store)
    }

    @Test func aMeshShareImportsTheRecipeWithItsParts() throws {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let store = makeTestStore()
        let share = RecipeShareCodec.proximityPayload(for: salad.recipe, foodItems: salad.foodItems)
        let received = try JSONDecoder().decode(ProximityRecipeSharePayload.self, from: JSONEncoder().encode(share))

        #expect(try store.importProximityRecipeShare(received) == .imported(name: RecipeMultipartFixtures.recipeName))
        try expectRebuiltSalad(try #require(store.recipes.first), in: store)
    }

    @Test func aFlattenedV1PayloadImportsAsAOnePartRecipeWithLabelledSteps() throws {
        let store = makeTestStore()
        let flat = RecipeMultipartFixtures.saladPayload().droppingComponents()

        let imported = try store.importRecipe(from: String(decoding: JSONEncoder().encode(flat), as: UTF8.self))
        #expect(imported.components == nil)
        #expect(imported.ingredients.count == 9)
        #expect(imported.steps?.first?.text == "Lemon-dijon dressing: Whisk the lemon juice, mustard and honey.")
    }

    @Test func theShareTextListsIngredientsUnderEachPart() throws {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let text = RecipeShareCodec.shareText(for: salad.recipe, foodItems: salad.foodItems)
        let lines = text.components(separatedBy: "\n")

        let dressing = try #require(lines.firstIndex(of: "Lemon-dijon dressing:"))
        let saladHeading = try #require(lines.firstIndex(of: "Salad:"))
        #expect(dressing < saladHeading)
        #expect(lines[dressing + 1].contains("Olive oil"))
        #expect(lines[saladHeading + 1].contains("Romaine lettuce"))
        #expect(try RecipeShareCodec.decodePayload(from: text) == RecipeMultipartFixtures.saladPayload())
    }

    // MARK: - Helpers

    /// The imported copy of the salad: two parts, each with its own rows, labels gone, fresh step ids,
    /// nutrition identical to the sender's.
    private func expectRebuiltSalad(_ imported: RecipeDefinition, in store: FernletStore) throws {
        let parts = imported.resolvedComponents
        // `#require`, not `#expect`: the indexing below must never run on a wrong shape and crash the runner.
        try #require(parts.count == 2)
        #expect(imported.isMultipart)
        #expect(parts.map(\.name) == [RecipeMultipartFixtures.dressingName, RecipeMultipartFixtures.saladName])
        #expect(parts.map(\.ingredients.count) == [4, 5])
        #expect(parts[0].steps.map(\.text) == RecipeMultipartFixtures.dressingSteps.map(\.text))
        #expect(parts[1].steps.map(\.text) == RecipeMultipartFixtures.saladSteps.map(\.text))
        #expect(parts[1].steps.first?.durationSeconds == 480)
        #expect(Set(parts.flatMap(\.steps).map(\.id)).isDisjoint(with: Set((RecipeMultipartFixtures.dressingSteps
            + RecipeMultipartFixtures.saladSteps).map(\.id))))
        #expect(store.macroTotals(for: imported) == MacroTotals(protein: 12, carbs: 56, fat: 58))
    }

    /// What an older build does with a v1 packet: decode through the pre-multipart shapes, then
    /// re-hash the frozen pre-image with the exchange's canonical encoder settings.
    private func olderBuildRehash(_ packetData: Data) throws -> String {
        let old = try JSONDecoder().decode(PreMultipartPacket.self, from: packetData)
        let input = PreMultipartHashInput(format: old.format, version: old.formatVersion, packetID: old.packetID,
                                          originContentID: old.originContentID, includesNotes: old.includesNotes,
                                          recipe: old.recipe)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(input)).map { String(format: "%02x", $0) }.joined()
    }

    /// The share text's canonical encoding (`.sortedKeys`, as `RecipeShareCodec` embeds it).
    private func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
