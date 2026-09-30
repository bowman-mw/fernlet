import Foundation

/// What the Messages extension shows for a card someone opened, decided from the card's URL alone.
///
/// The extension used to make this decision inline — a `do`/`catch` around two throwing calls and
/// a `switch` — inside `FernletMessagesViewController`, which `FernletTests` cannot link. Resolved
/// here, "which of three screens does this URL get?" is a pure function the tests drive with the
/// sender's own encoder (`MessagesReceivedItemTests`).
///
/// **Total, never throwing.** Every input, `nil` included, lands on a case that has something to
/// draw: a URL that is not a Fernlet card, a wire version this build does not know, a truncated or
/// re-encoded body and a packet that fails its hash all come back ``invalid``, which the extension
/// renders as "This Fernlet item can't be opened". There is no fourth, empty outcome.
///
/// **It reads no file.** Opening a card needs only the card: nothing here touches the App Group
/// catalog (``FernletMessagesCatalogFileStore``), which is the composer's, so showing a received card
/// neither waits on a coordinated read nor depends on what the app last published.
///
/// The checks are the envelope's own (``ExchangeMessageEnvelope/decode(messageURL:)`` then
/// ``ExchangeMessageEnvelope/validatedPayload()``), and the card is derived from the validated packet,
/// never read from the bubble. A workout plan is also run through the review inbox's record
/// validation (its per-record size cap and its card) up front, so a plan card that opens can always be
/// handed to Fernlet for review.
public nonisolated enum FernletMessagesReceivedItem: Equatable, Sendable {
    /// A recipe whose packet passed every check, and the card derived from it.
    case recipe(RecipeExchangePacket, card: ExchangeCardMetadata)
    /// A one-day workout plan, already shaped as the review-inbox record it will be handed on as —
    /// the sender's suggested start day inside it stays a suggestion — and the card derived from it.
    case workoutPlan(FernletMessagesWorkoutInboxRecord, card: ExchangeCardMetadata)
    /// No URL, a URL that is not a Fernlet card, or bytes that failed a check.
    case invalid

    /// The screen a card with this URL gets. `nil` (a message Messages handed over without a URL)
    /// is ``invalid``, like any other URL that does not validate.
    public static func resolve(messageURL: URL?) -> FernletMessagesReceivedItem {
        guard let messageURL else { return .invalid }
        do {
            return try resolved(ExchangeMessageEnvelope.decode(messageURL: messageURL))
        } catch {
            return .invalid
        }
    }

    private static func resolved(_ envelope: ExchangeMessageEnvelope) throws -> FernletMessagesReceivedItem {
        switch try envelope.validatedPayload() {
        case .recipe(let packet):
            return .recipe(packet, card: try .recipe(from: packet))
        case .workoutPlan(let packet):
            let dayKey = envelope.scheduledStartDayKey
            let record = try FernletMessagesWorkoutInboxRecord(packet: packet, suggestedStartDayKey: dayKey)
            return .workoutPlan(record, card: try .workoutPlan(from: packet, scheduledStartDayKey: dayKey))
        }
    }
}
