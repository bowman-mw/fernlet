import CryptoKit
import FernletDomainModel
import FernletExchange
import Foundation
import Testing

/// A recipe made in parts — the owner's "salad with a homemade dressing" — as an exchange packet and
/// a Messages card (2026-09-24).
///
/// **The packet rule.** A one-part recipe stays packet version 1, byte-for-byte what every earlier
/// build wrote. A recipe made in parts is version 2: its payload carries W1-multipart's `components`
/// partition, which a version-1 reader could not keep (it re-hashes what it decoded, without the
/// unknown key, and would call an honest file corrupt), so the version is the gate. The content-hash
/// scheme is versioned with it: the same SHA-256-over-canonical-JSON construction, with the version
/// INSIDE the pre-image — checked here against a pre-image this file builds itself — and each version
/// may carry only its own shape.
///
/// **The card.** The fixture must fit a version-2 card with room to spare, and come back out with its
/// parts, their names and every row intact.
struct ExchangeMultipartRecipeTests {

    // MARK: - Packet versions

    @Test func aOnePartRecipeStaysPacketVersionOne() throws {
        let packet = try ExchangeMessageEnvelopeV2Tests.goldenRecipePacket()

        #expect(packet.formatVersion == RecipeExchangePacket.formatVersion)
        #expect(packet.formatVersion == 1)
        #expect(packet.recipe.components == nil)
        #expect(packet.contentHash == ExchangeMessageEnvelopeV2Tests.goldenV1RecipeHash,
                "a one-part recipe hashes exactly as the 2026-09-23 build hashed it")
    }

    @Test func aRecipeMadeInPartsIsPacketVersionTwoAndRoundTrips() throws {
        let packet = try Self.saladPacket()
        let decoded = try RecipeExchangePacket.decode(packet.encodedData())

        #expect(packet.formatVersion == RecipeExchangePacket.multipartFormatVersion)
        #expect(packet.formatVersion == 2)
        #expect(packet.recipe.components?.map(\.name) == [RecipeMultipartFixtures.dressingName, RecipeMultipartFixtures.saladName])
        #expect(decoded == packet)
        #expect(decoded.recipe.componentSlices?.map(\.ingredients.count) == [4, 5])
        #expect(decoded.recipe.componentSlices?.map(\.steps.count) == [2, 3])
        #expect(decoded.recipe.componentSlices?.first?.steps.first?.text == RecipeMultipartFixtures.dressingSteps.first?.text,
                "the part label rides the flat step and comes off again")
    }

    // MARK: - The versioned content-hash scheme

    /// Scheme 2 is scheme 1's construction with `version: 2` in the pre-image — computed here from a
    /// pre-image this test encodes itself, not by the code under test.
    @Test func theVersionTwoHashIsTheSameConstructionWithVersionTwoInThePreImage() throws {
        let packet = try Self.saladPacket()

        #expect(try Self.independentHash(of: packet, version: 2) == packet.contentHash)
        #expect(try Self.independentHash(of: packet, version: 1) != packet.contentHash,
                "the version is inside the pre-image, so scheme 1 cannot verify a scheme-2 packet")
    }

    /// The partition is inside the hash: renaming a part after hashing is refused as tampering.
    @Test func editingAPartAfterHashingFailsTheHash() throws {
        var packet = try Self.saladPacket()
        packet.recipe.components?[0].name = "Vinaigrette"

        #expect(throws: ExchangePacketError.invalidHash) { try RecipeExchangePacket.decode(Self.encode(packet)) }
    }

    /// Each version carries only its own shape, even with a hash that verifies: version 1 may not
    /// smuggle parts past an older reader's gate, and version 2 may not be a one-part recipe.
    @Test func versionOneMayNotCarryPartsAndVersionTwoMustCarryThem() throws {
        var partsInVersionOne = try Self.saladPacket()
        partsInVersionOne.formatVersion = 1
        partsInVersionOne.contentHash = try Self.independentHash(of: partsInVersionOne, version: 1)
        var onePartInVersionTwo = try ExchangeMessageEnvelopeV2Tests.goldenRecipePacket()
        onePartInVersionTwo.formatVersion = 2
        onePartInVersionTwo.contentHash = try Self.independentHash(of: onePartInVersionTwo, version: 2)
        var future = try Self.saladPacket()
        future.formatVersion = 3

        #expect(throws: ExchangePacketError.invalidPayload) { try RecipeExchangePacket.decode(Self.encode(partsInVersionOne)) }
        #expect(throws: ExchangePacketError.invalidPayload) { try RecipeExchangePacket.decode(Self.encode(onePartInVersionTwo)) }
        #expect(throws: ExchangePacketError.unsupportedFormat) { try RecipeExchangePacket.decode(Self.encode(future)) }
    }

    // MARK: - The card

    /// The owner's example fits a version-2 card with room to spare and comes back whole.
    @Test func theSaladWithHomemadeDressingFitsACard() throws {
        let packet = try Self.saladPacket()
        let envelope = try ExchangeMessageEnvelope(recipe: packet)
        let url = try envelope.messageURL()
        let recovered = try ExchangeMessageEnvelope.decode(messageURL: url)

        #expect(url.absoluteString.count <= ExchangeLimits.maxMessageURLCharacters / 2,
                "the salad needs \(url.absoluteString.count) of 5,000 characters")
        #expect(recovered == envelope)
        guard case .recipe(let received) = try recovered.validatedPayload() else {
            Issue.record("Expected a recipe.")
            return
        }
        #expect(received == packet)
        #expect(received.recipe.components?.count == 2)
    }

    /// The Messages catalog and the review inbox hold a version-2 packet like any other.
    @Test func theCatalogAndTheReviewInboxAcceptAVersionTwoPacket() throws {
        let packet = try Self.saladPacket()
        let entry = try FernletMessagesRecipeCatalogEntry(packet: packet)
        let catalog = try FernletMessagesCatalog(recipes: [entry], workouts: [])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inbox = FernletMessagesInboxStore(directory: directory)
        let record = try inbox.enqueue(packet)

        #expect(try FernletMessagesCatalog.decode(catalog.encodedData()) == catalog)
        #expect(try inbox.record(id: record.id)?.packet == packet)
        #expect(inbox.clear())
    }

    // MARK: - Helpers

    static func saladPacket() throws -> RecipeExchangePacket {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        return try RecipeExchangePacket(recipe: salad.recipe, foodItems: salad.foodItems, includesNotes: true)
    }

    /// SHA-256 over the canonical pre-image — the packet minus `contentHash`, `formatVersion` spelled
    /// `version` — encoded here, independently of the code under test.
    static func independentHash(of packet: RecipeExchangePacket, version: Int) throws -> String {
        let preImage = PreImage(format: packet.format, version: version, packetID: packet.packetID,
                                originContentID: packet.originContentID, includesNotes: packet.includesNotes,
                                recipe: packet.recipe)
        let digest = SHA256.hash(data: try encode(preImage))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical bytes (`.sortedKeys`, `.withoutEscapingSlashes`) WITHOUT a packet's own validation, so
    /// a deliberately broken packet can reach the decoder.
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// The hash pre-image as the version-1 frozen scheme defines it (the literal pins in
    /// `ExchangeMessageEnvelopeV2Tests` spell its bytes out).
    struct PreImage: Encodable {
        var format: String
        var version: Int
        var packetID: UUID
        var originContentID: UUID
        var includesNotes: Bool
        var recipe: SharedRecipePayload
    }
}
