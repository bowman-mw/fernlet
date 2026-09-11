import SwiftUI
import ProximityKit
import FernletUI

/// The live-session chat panel (mesh redesign Phase 5, Docs/Proximity-Mesh-Redesign-2026-07-10.md).
/// Presented from the in-session disposable-camera surface. Reads the observable
/// `manager.sessionMessages` transcript and sends via `manager.sendTempMessage(_:)`.
///
/// Session-scoped by construction: the VISIBLE transcript is memory-only and the manager clears it
/// at session end, so this list empties when the outing ends. Since P6 item 4 the messages
/// themselves ride the routed store as sealed ciphertext beneath it, held until the item expires —
/// which is what lets a message reach an admitted member who is not linked at that instant.
///
/// A send that did not stage is said **in place**, under the compose bar, with the draft kept: the
/// compose bar is deliberately not gated on "is there anybody to send to", because that would need
/// a second published mirror of the mint's own answer and would flicker on every link blip.
struct SessionChatPanel: View {
    var manager: MeshNetworkManager
    var onDone: () -> Void

    @State private var draft = ""
    /// The inline notice for a send that did not stage (P6 item 4). In place, beneath the compose
    /// bar, rather than on `routedShareRefusal`'s alert: that alert belongs to
    /// `DisposableCameraView`, which this panel is presented OVER, so firing it here would present
    /// on a covered presenter and its copy is photo-worded in every arm.
    @State private var sendNotice: LocalizedStringKey?
    @FocusState private var composeFocused: Bool

    private var messages: [SessionMessageStore.Message] { manager.sessionMessages.messages }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                composeBar
            }
            .background(Color.parchment.ignoresSafeArea())
            .navigationTitle("Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone() }
                        .foregroundStyle(Color.bark)
                }
            }
        }
        // TF b19 item 6: an open panel keeps the unread badge at zero — the store suppresses unread
        // counting while viewing, and clears the standing count the moment the panel appears.
        // Opening the panel is already "I want to type" — land the caret in the field rather than
        // charging every message an extra tap.
        .onAppear {
            manager.sessionMessages.beginViewing()
            composeFocused = true
        }
        .onDisappear { manager.sessionMessages.endViewing() }
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
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Color.slate.opacity(0.5))
            Text("Say hello")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
            Text("Messages stay in this session only — they disappear for everyone when the session ends.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func messageRow(_ message: SessionMessageStore.Message) -> some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 40) }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
                if !message.isOutgoing {
                    Text(message.senderDisplayName)
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                }
                Text(message.text)
                    .font(.fernlet(.body))
                    .foregroundStyle(message.isOutgoing ? Color.midnight : Color.bark)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        message.isOutgoing ? Color.terracotta.opacity(0.18) : Color.cream,
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )
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
    }

    // MARK: - Compose

    @ViewBuilder
    private var composeBar: some View {
        if let sendNotice {
            Text(sendNotice)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.terracotta)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .background(Color.parchment)
                .accessibilityIdentifier("session.chat.sendNotice")
        }
        HStack(spacing: 10) {
            TextField("Message", text: $draft, axis: .vertical)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .lineLimit(1...4)
                // Return sends, as it does in every messaging app — it used to only insert a newline,
                // leaving the 30pt glyph as the single way to send. (Same mechanism as the shared
                // `SheetGrowingTextField`; the chat bubble keeps its own chrome.)
                .submitLabel(.send)
                .onSubmit {
                    if canSend { send() }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .focused($composeFocused)
                .accessibilityIdentifier("session.chat.field")

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? Color.terracotta : Color.slate.opacity(0.4))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!canSend)
            .accessibilityLabel("Send message")
            .accessibilityIdentifier("session.chat.send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.parchment)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.bark.opacity(0.08))
                .frame(height: 1)
        }
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
        let outcome = manager.sendTempMessage(text)
        sendNotice = RoutedShareRefusalCopy.chatNotice(outcome)
        // The draft survives anything but a staged send, so "send again" is the retry.
        guard outcome == .staged else { return }
        draft = ""
    }
}
