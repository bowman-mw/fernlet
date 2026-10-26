import SwiftUI
import ProximityKit
import FernletDomainModel
import FernletSocial
import FernletUI

/// The live-session chat panel (mesh redesign Phase 5, Docs/Proximity-Mesh-Redesign-2026-07-10.md).
/// Presented from the in-session disposable-camera surface. Reads the observable
/// `chat.sessionMessages` transcript and sends via `chat.sendTempMessage(_:)` — FernletSocial's
/// `MeshSessionChat`, the store's `meshFeatures.chat` (ProximityKit plan step A0.5.9).
///
/// Session-scoped by construction: the VISIBLE transcript is memory-only and the chat drops it at
/// session end, so this list empties when the outing ends. Since P6 item 4 the messages
/// themselves ride the routed store as sealed ciphertext beneath it, held until the item expires —
/// which is what lets a message reach an admitted member who is not linked at that instant.
///
/// A send that did not stage is said **in place**, at the top of the compose bar — above the text
/// field, between it and the transcript — with the draft kept: the
/// compose bar is deliberately not gated on "is there anybody to send to", because that would need
/// a second published mirror of the mint's own answer and would flicker on every link blip. A draft
/// the chat's send filter refuses (`MeshTextSendOutcome.filtered`, App Review guideline 1.2) is said
/// the same way, gently, with the draft kept so it can be reworded.
///
/// **Report… (App Review guideline 1.2, 2026-10-15).** Touch and hold another person's message —
/// never your own — for "Report…", which is also the row's VoiceOver action. It opens the app's one
/// people-report flow (`peerReportFlow`, the Friends & Blocks sheet) naming the message by a short
/// excerpt; `onReport` files it through the store, which blocks the sender and re-folds the
/// transcript so their messages leave it at once.
struct SessionChatPanel: View {
    var chat: MeshSessionChat
    /// Files a report of a message's sender (the store's `reportSessionPeer`).
    var onReport: (PeerReportSubject, ReportReason) -> Void
    var onDone: () -> Void

    @State private var draft = ""
    /// The inline notice for a send that did not stage (P6 item 4). In place, at the TOP of the
    /// compose bar (above the text field, below the transcript), rather than on
    /// `routedShareRefusal`'s alert: that alert belongs to
    /// `DisposableCameraView`, which this panel is presented OVER, so firing it here would present
    /// on a covered presenter and its copy is photo-worded in every arm.
    @State private var sendNotice: LocalizedStringKey?
    /// The message sender the report flow is open for, if any.
    @State private var reportSubject: PeerReportSubject?
    @FocusState private var composeFocused: Bool

    private var messages: [SessionMessageStore.Message] { chat.sessionMessages.messages }

    var body: some View {
        // b3-session-chat: paper, the wooden grabber, Done top right (the way out, as today), the
        // title in the sheet, framed bubbles, then the compose bar.
        VStack(spacing: 0) {
            transcript
            composeBar
        }
        .frame(maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            SheetHeader(title: "Messages", onDone: onDone)
        }
        .fernletSheet()
        // TF b19 item 6: an open panel keeps the unread badge at zero — the store suppresses unread
        // counting while viewing, and clears the standing count the moment the panel appears.
        // Opening the panel is already "I want to type" — land the caret in the field rather than
        // charging every message an extra tap.
        .onAppear {
            chat.sessionMessages.beginViewing()
            composeFocused = true
        }
        .onDisappear { chat.sessionMessages.endViewing() }
        .peerReportFlow($reportSubject, onReport: onReport)
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        if messages.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(messages) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
                .onChange(of: messages.count) { _, _ in
                    guard let last = messages.last else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onAppear {
                    guard let last = messages.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            WorldSpriteView(sprite: FriendsSprites.bubble, scale: 4)
            Text("Say hello")
                .font(FernletFramedFont.cardTitle)
                .foregroundStyle(WorldPalette.bark)
            Text("Messages stay in this session only — they disappear for everyone when the session ends.")
                .font(FernletFramedFont.body)
                .foregroundStyle(WorldPalette.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One framed bubble: yours on the right on the rose fill, theirs on the left on paper with their
    /// name above (b3-session-chat).
    private func messageRow(_ message: SessionMessageStore.Message) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack {
            if message.isOutgoing { Spacer(minLength: 40) }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                if !message.isOutgoing {
                    Text(message.senderDisplayName)
                        .font(FernletFramedFont.rowDetailBold)
                        .foregroundStyle(WorldPalette.dim)
                }
                Text(message.text)
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.bark)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(message.isOutgoing ? WorldPalette.rose : WorldPalette.paperLight, in: shape)
                    .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: FernletFramedLook.frameWidth))
            }
            if !message.isOutgoing { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session.chat.message")
        .accessibilityLabel(
            message.isOutgoing
                ? "You: \(message.text)"
                : "\(message.senderDisplayName): \(message.text)"
        )
        .modifier(ReportableMessageRow(subject: PeerReportSubject.message(message)) { reportSubject = $0 })
    }

    // MARK: - Compose

    @ViewBuilder
    private var composeBar: some View {
        if let sendNotice {
            Text(sendNotice)
                .font(FernletFramedFont.note)
                .foregroundStyle(Color.terracottaInk)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .accessibilityIdentifier("session.chat.sendNotice")
        }
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $draft, prompt: .fieldPrompt("Message"), axis: .vertical)
                .lineLimit(1...4)
                // Return sends, as it does in every messaging app — it used to only insert a newline,
                // leaving the glyph as the single way to send.
                .submitLabel(.send)
                .onSubmit {
                    if canSend { send() }
                }
                .sheetTextInput()
                .focused($composeFocused)
                .accessibilityIdentifier("session.chat.field")

            Button(action: send) {
                WorldSpriteView(sprite: FriendsSprites.sendArrow, scale: 3, tint: WorldPalette.onAccent)
                    .frame(width: 50, height: 50)
                    .background(canSend ? WorldPalette.accent : WorldPalette.accent.opacity(0.45),
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldPalette.ink, lineWidth: FernletFramedLook.frameWidth))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send message")
            .accessibilityIdentifier("session.chat.send")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // The outcome is READ, never discarded: an unread one is a message the user believes was
        // sent. `.noDestinations` is the real case that makes this necessary — the founding window
        // (commit → found → grant → adopt) is a second or two in which the roster names nobody
        // else, and destinations are frozen at the mint, so the item can never acquire one later.
        let outcome = chat.sendTempMessage(text)
        sendNotice = RoutedShareRefusalCopy.chatNotice(outcome)
        // The draft survives anything but a staged send, so "send again" is the retry.
        guard outcome == .staged else {
            // A6: a refused send (one with a notice to read) is felt as well as shown. A send that
            // lands gets nothing — the bubble appearing is enough, and a tick per message would be
            // constant.
            if sendNotice != nil { FernletFeedback.system.play(.failed) }
            return
        }
        draft = ""
    }
}

/// Report… on one transcript row, when the row is another person's message: a destructive
/// context-menu item (touch and hold) and the same named VoiceOver action, both opening the panel's
/// report flow. A row with no subject — this device's own message — gets neither.
private struct ReportableMessageRow: ViewModifier {
    /// The message's sender as a report subject; nil for a row that is not reportable.
    let subject: PeerReportSubject?
    /// Opens the report flow for the subject.
    let report: (PeerReportSubject) -> Void

    func body(content: Content) -> some View {
        if let subject {
            content
                .contextMenu {
                    Button(role: .destructive) {
                        report(subject)
                    } label: {
                        Label("Report…", systemImage: "flag")
                    }
                    .accessibilityIdentifier("session.chat.report")
                }
                .accessibilityAction(named: "Report…") { report(subject) }
        } else {
            content
        }
    }
}
