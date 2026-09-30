import FernletDomainModel
import FernletExchange
import Foundation
import Testing

/// What a Messages card shows when someone opens it: `FernletMessagesReceivedItem.resolve`, the one
/// decision the extension's received-card screen is drawn from.
///
/// **Why this suite exists (2026-09-30).** The owner reported that receiving a recipe through the
/// iMessage app "pops up and is blank". The extension's receive path could not be exercised from
/// `FernletTests` — `FernletMessagesViewController` lives in an appex this bundle does not link — so
/// the decision was moved into `FernletExchange` and is pinned here with the property that matters:
/// **every input lands on a screen with something to draw**. A card minted by the sender's own
/// encoder opens as that recipe or plan, with the packet's own title; anything else — no URL, a URL
/// that is not a Fernlet card, a truncated or re-encoded body, an oversize URL — is `.invalid`, which
/// the extension renders as "This Fernlet item can't be opened". There is no empty outcome and no
/// thrown error for the controller to drop.
///
/// What this suite cannot see: Messages itself. A device with no Fernlet iMessage extension able to
/// open the card (no Fernlet, a build older than 24, an iPad or a Mac) gets Messages' own install
/// sheet, which is empty because Fernlet has no public App Store page — that path never reaches this
/// code. `Docs/MessagesExtensionReleaseChecklist.md` carries the hardware check for it.
struct MessagesReceivedItemTests {

    // MARK: - A card the sender's encoder minted opens as itself

    @Test func aRecipeCardMintedByTheSendersEncoderOpensAsThatRecipe() throws {
        let packet = try ExchangeMessageEnvelopeV2Tests.goldenRecipePacket()
        let url = try ExchangeMessageEnvelope(recipe: packet).messageURL()

        guard case .recipe(let opened, let card) = FernletMessagesReceivedItem.resolve(messageURL: url) else {
            Issue.record("A card the composer minted did not open as a recipe.")
            return
        }
        #expect(opened == packet)
        #expect(card.kind == .recipe)
        #expect(card.title == packet.recipe.name && !card.title.isEmpty, "the received screen's title is the packet's own name")
        #expect(card.ingredientCount == packet.recipe.ingredients.count)
        #expect(card.stepCount == packet.recipe.steps?.count)
    }

    /// A recipe made in parts travels whole (packet version 2), so the received screen can list its
    /// parts above the note.
    @Test func aRecipeMadeInPartsKeepsItsParts() throws {
        let packet = try ExchangeMultipartRecipeTests.saladPacket()
        let url = try ExchangeMessageEnvelope(recipe: packet).messageURL()

        guard case .recipe(let opened, let card) = FernletMessagesReceivedItem.resolve(messageURL: url) else {
            Issue.record("A multipart recipe card did not open as a recipe.")
            return
        }
        #expect(opened.formatVersion == RecipeExchangePacket.multipartFormatVersion)
        #expect(opened.recipe.components == packet.recipe.components)
        #expect(opened.recipe.components?.isEmpty == false)
        #expect(card.title == packet.recipe.name)
    }

    /// A workout card opens as the review-inbox record it will be handed on as, with the sender's
    /// suggested day still attached — a suggestion, not a schedule.
    @Test func aWorkoutCardOpensAsItsInboxRecordWithTheSuggestedDay() throws {
        let packet = try ExchangeMessageEnvelopeV2Tests.goldenWorkoutPacket()
        let url = try ExchangeMessageEnvelope(workoutPlan: packet, scheduledStartDayKey: "2026-10-05").messageURL()

        guard case .workoutPlan(let record, let card) = FernletMessagesReceivedItem.resolve(messageURL: url) else {
            Issue.record("A workout card did not open as a workout plan.")
            return
        }
        #expect(record.packet == packet)
        #expect(record.suggestedStartDayKey == "2026-10-05")
        #expect(card.kind == .workoutPlan)
        #expect(card.title == packet.plan.title && !card.title.isEmpty)
        #expect(card.scheduledStartDayKey == "2026-10-05")
        #expect(card.senderLabel == "Fernlet Coach")
    }

    /// Cards already sitting in conversations — version 1 from the 2026-09-23 build, version 2 from
    /// 2026-09-24 on — keep opening through the resolver, not just through the envelope.
    @Test func goldenCardsOfBothWireVersionsStillOpen() throws {
        let recipes = [ExchangeMessageEnvelopeV2Tests.goldenV1RecipeURL, ExchangeMessageEnvelopeV2Tests.goldenV2RecipeURL]
        for text in recipes {
            let url = try #require(URL(string: text))
            let resolved = FernletMessagesReceivedItem.resolve(messageURL: url)
            guard case .recipe(_, let card) = resolved else {
                Issue.record("Golden recipe card \(text.prefix(48))… no longer opens.")
                continue
            }
            #expect(card.title == "Training oats")
        }
        let workouts = [ExchangeMessageEnvelopeV2Tests.goldenV1WorkoutURL, ExchangeMessageEnvelopeV2Tests.goldenV2WorkoutURL]
        for text in workouts {
            let url = try #require(URL(string: text))
            let resolved = FernletMessagesReceivedItem.resolve(messageURL: url)
            guard case .workoutPlan(let record, _) = resolved else {
                Issue.record("Golden workout card \(text.prefix(48))… no longer opens.")
                continue
            }
            #expect(record.suggestedStartDayKey == "2026-09-02")
        }
    }

    // MARK: - Everything else is `.invalid`, never nothing

    @Test func aMessageWithNoURLIsInvalid() {
        #expect(FernletMessagesReceivedItem.resolve(messageURL: nil) == .invalid)
    }

    /// Foreign, damaged and oversize URLs all resolve — to `.invalid`, the screen that says so —
    /// rather than throwing past the caller or yielding an empty screen.
    @Test func foreignDamagedAndOversizeURLsAreInvalid() throws {
        let good = try ExchangeMessageEnvelope(recipe: ExchangeMessageEnvelopeV2Tests.goldenRecipePacket())
            .messageURL().absoluteString
        let prefix = "data:application/vnd.fernlet.exchange.v2,"
        let body = String(good.dropFirst(prefix.count))
        let cases: [(String, String)] = [
            ("a web link", "https://example.com/recipe"),
            ("a foreign data URL", "data:text/plain,hello"),
            ("a future wire version", "data:application/vnd.fernlet.exchange.v3," + body),
            ("a truncated body", prefix + String(body.dropLast(12))),
            ("standard base64 characters", prefix + body.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")),
            ("an oversize URL", prefix + body + String(repeating: "A", count: ExchangeLimits.maxMessageURLCharacters)),
        ]
        #expect(body.contains("-") || body.contains("_"), "fixture: the body must carry a base64url-only character")
        for (label, text) in cases {
            guard let url = URL(string: text) else {
                Issue.record("fixture \(label) is not a URL")
                continue
            }
            #expect(FernletMessagesReceivedItem.resolve(messageURL: url) == .invalid, "\(label)")
        }
    }

    /// A card whose packet was edited after hashing is refused, not shown: the received screen never
    /// describes bytes that failed their own check.
    @Test func aCardWhosePacketFailsItsHashIsInvalid() throws {
        var packet = try ExchangeMessageEnvelopeV2Tests.goldenRecipePacket()
        var envelope = try ExchangeMessageEnvelope(recipe: packet)
        envelope.formatVersion = ExchangeMessageEnvelope.legacyFormatVersion
        packet.recipe.name = "Not what was hashed"
        envelope.packetData = try JSONEncoder().encode(packet)
        let json = try JSONEncoder().encode(envelope)
        let url = try #require(URL(string: "data:application/vnd.fernlet.exchange+json;base64," + json.base64EncodedString()))

        #expect(FernletMessagesReceivedItem.resolve(messageURL: url) == .invalid)
    }
}
