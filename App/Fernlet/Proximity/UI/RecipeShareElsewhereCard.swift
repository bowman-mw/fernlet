import FernletDomainModel
import FernletExchange
import FernletFoundation
import FernletUI
import Messages
import SwiftUI

/// One composed card waiting for the Messages draft sheet, so `.sheet(item:)` re-presents for each tap.
struct ComposedRecipeCard: Identifiable {
    let id = UUID()
    /// The card, from `FernletMessagesCard.recipeMessage(for:)`.
    let message: MSMessage
}

/// The recipe Share screen's second card: the two ways to share a recipe beyond nearby Fernlets
/// (2026-09-30, the owner's report that "Share outside Fernlet" pasted raw JSON).
///
/// - **Send in Messages** opens a Messages draft holding the same Fernlet recipe card the iMessage
///   app inserts (``RecipeMessageComposer`` over `FernletMessagesCard`), for a recipient to open and
///   save in Fernlet on iPhone. When it cannot be offered, a one-line note says why in its place:
///   Messages is not set up here (always, on a simulator), the recipe is too long for a card, or it
///   was saved from a web page (``RecipeMessagesCardOffer``).
/// - **Share as text** hands the system share sheet readable text (``RecipeShareText``) through
///   ``RecipeShareTextItemSource``, with the recipe's name as the sheet's title and Mail's subject.
///   No JSON, no Fernlet data. The text is built when the row is tapped, not on every render.
///
/// Both follow the Share screen's "Include notes" switch, passed in as `includesNotes`. After a
/// draft closes, one line says "Sent in Messages." or that sending failed, VoiceOver hears it, and
/// it is felt — `done` or `failed` (report §7, 2026-10-20); a cancelled draft says and plays nothing. "Sent" is all it may claim — Messages reports handing the message
/// over, never delivery.
struct RecipeShareElsewhereCard: View {
    var recipe: RecipeDefinition
    var includesNotes: Bool
    var store: FernletStore

    @State private var composing: ComposedRecipeCard?
    @State private var outcome: RecipeMessagesSendOutcome?
    /// The text on its way to the system share sheet, while that sheet is up.
    @State private var sharingText: RecipeShareTextItemSource?
    /// The rows' glyph box, grown with the glyph's own text style so an accessibility-size glyph
    /// never spills over the row's words.
    @ScaledMetric(relativeTo: .title3) private var glyphSide: CGFloat = 34

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                // World build (b3-recipe-share draft 2): the framed section label, then each route as
                // a framed link row with its pixel icon tile.
                SectionLabel("Share outside Fernlet")
                messagesRow
                    .sheet(item: $composing) { card in
                        RecipeMessageComposer(message: card.message) { finish($0) }
                            .ignoresSafeArea()
                    }
                textRow
                    .sheet(item: $sharingText) { source in
                        ActivityShareView(items: [source]) { sharingText = nil }
                            .presentationDetents([.medium, .large])
                            .ignoresSafeArea()
                    }
                if let status {
                    Text(status.message)
                        .font(FernletFramedFont.note)
                        .foregroundStyle(WorldPalette.dim)
                        .fernletWrappingText()
                        .accessibilityIdentifier("recipeShare.messagesOutcome")
                }
            }
        }
    }

    /// The line after a draft closed, if it says anything.
    private var status: Status? {
        outcome.flatMap { Status($0) }
    }

    // MARK: - Send in Messages

    @ViewBuilder private var messagesRow: some View {
        switch messagesAvailability {
        case .ready(let packet):
            Button { compose(packet) } label: {
                rowLabel(title: "Send in Messages",
                         caption: "A Fernlet card they can open and save in Fernlet on iPhone.",
                         sprite: WorldSprites.bubble)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("recipeShare.sendInMessages")
        case .note(let note):
            noteRow(note.text)
        }
    }

    /// Whether the row is offered, or which note stands in its place. The device check comes first:
    /// with Messages not set up, no recipe can go, whatever its size.
    private var messagesAvailability: MessagesAvailability {
        guard RecipeMessageComposer.canSendText else { return .note(.messagesNotSetUp) }
        switch store.recipeMessagesCardOffer(for: recipe, includesNotes: includesNotes) {
        case .ready(let packet): return .ready(packet)
        case .webImported: return .note(.webImported)
        case .tooLarge: return .note(.tooLarge)
        case .unavailable: return .note(.unavailable)
        }
    }

    /// Builds the card and opens the draft — after checking Messages AGAIN, because presenting a
    /// composer on a device that cannot send throws (see ``RecipeMessageComposer``).
    private func compose(_ packet: RecipeExchangePacket) {
        outcome = nil
        guard RecipeMessageComposer.canSendText else {
            report(.failed)
            return
        }
        do {
            composing = ComposedRecipeCard(message: try FernletMessagesCard.recipeMessage(for: packet))
        } catch {
            FernletAuditLog.log("recipeShare.messagesCard.buildFailed", context: ["error": String(describing: error)])
            report(.failed)
        }
    }

    private func finish(_ result: RecipeMessagesSendOutcome) {
        composing = nil
        report(result)
    }

    /// Shows the outcome line, speaks it and plays its haptic; a cancelled draft has none of them.
    private func report(_ result: RecipeMessagesSendOutcome) {
        outcome = result
        guard let status = Status(result) else { return }
        FernletAnnouncer.system.announce(status.announcementKind, status.message)
        if let event = Self.feedbackEvent(for: result) { FernletFeedback.system.play(event) }
    }

    /// The haptic a closed draft plays: `done` once Messages took the card, `failed` when it could
    /// not, and nothing for a draft the person cancelled — the cancel is its own answer.
    static func feedbackEvent(for outcome: RecipeMessagesSendOutcome) -> FernletFeedbackEvent? {
        switch outcome {
        case .sent: .done
        case .failed: .failed
        case .cancelled: nil
        }
    }

    // MARK: - Share as text

    /// Opens the system share sheet with the text for the current "Include notes" choice.
    private var textRow: some View {
        Button {
            sharingText = RecipeShareTextItemSource(
                text: store.recipeShareText(for: recipe, includesNotes: includesNotes),
                title: recipe.name
            )
        } label: {
            rowLabel(title: "Share as text",
                     caption: "Readable text for Mail, Notes or any other app. It doesn't import into Fernlet.",
                     sprite: WorldSprites.doc)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("recipeShare.shareAsText")
    }

    // MARK: - Rows

    /// A full-width, at-least-44-point row: a decorative glyph, the action's name and one line
    /// saying what it sends.
    private func rowLabel(title: LocalizedStringKey, caption: LocalizedStringKey, sprite: WorldSprite) -> some View {
        HStack(alignment: .center, spacing: 12) {
            RecipeSpriteTile(sprite: sprite, size: glyphSide + 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(FernletFramedFont.rowTitle.weight(.bold))
                    .foregroundStyle(WorldPalette.bark)
                    .fernletWrappingText()
                Text(caption)
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
            }
            Spacer(minLength: 0)
            FernletIcon(.chevron, scale: 2)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(12)
        .modifier(RecipeEditorCardFrame(radius: 10))
        .contentShape(Rectangle())
    }

    /// The note that stands in for "Send in Messages" when it cannot be offered.
    private func noteRow(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RecipeSpriteTile(sprite: WorldSprites.bubble, size: glyphSide + 8)
            Text(text)
                .font(FernletFramedFont.rowDetail)
                .foregroundStyle(WorldPalette.dim)
                .fernletWrappingText()
                .padding(.top, 7)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, 6)
        .accessibilityIdentifier("recipeShare.messagesNote")
    }

    // MARK: - Types

    /// The Messages row's state for one render.
    private enum MessagesAvailability {
        case ready(RecipeExchangePacket)
        case note(MessagesNote)
    }

    /// Why "Send in Messages" is not offered, as the line shown in its place.
    private enum MessagesNote {
        case messagesNotSetUp, webImported, tooLarge, unavailable

        var text: LocalizedStringKey {
            switch self {
            case .messagesNotSetUp: "Messages isn't set up on this iPhone, so share the recipe as text."
            case .webImported: "Recipes saved from a web page share as text."
            case .tooLarge: "This recipe is too long for a Messages card. Share it as text, or with someone nearby."
            case .unavailable: "This recipe can't go on a Messages card. Share it as text instead."
            }
        }
    }

    /// The line and announcement after a draft closes; `nil` for a cancelled one.
    private struct Status {
        let message: LocalizedStringResource
        let announcementKind: FernletAnnouncementKind

        init?(_ outcome: RecipeMessagesSendOutcome) {
            switch outcome {
            case .sent:
                message = "Sent in Messages."
                announcementKind = .success
            case .failed:
                message = "Messages couldn't send the recipe. Try again, or share it as text."
                announcementKind = .error
            case .cancelled:
                return nil
            }
        }
    }
}
