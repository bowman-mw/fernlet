import SwiftUI
import ProximityKit
import FernletUI

/// The live-session chat panel (mesh redesign Phase 5, Docs/Proximity-Mesh-Redesign-2026-07-10.md).
/// Presented from the in-session disposable-camera surface. Reads the observable
/// `manager.sessionMessages` transcript and sends via `manager.sendTempMessage(_:)`.
///
/// Session-scoped by construction: the transcript is memory-only and the manager clears it at session
/// end (messages VANISH — nothing retained, nothing synced), so this list empties when the outing ends.
/// Sending outside a session is a no-op (there are no active committed slots), so the compose bar simply
/// goes quiet rather than erroring.
struct SessionChatPanel: View {
    var manager: MeshNetworkManager
    var onDone: () -> Void

    @State private var draft = ""
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

    private var composeBar: some View {
        HStack(spacing: 10) {
            TextField("Message", text: $draft, axis: .vertical)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .focused($composeFocused)
                .accessibilityIdentifier("session.chat.field")

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? Color.terracotta : Color.slate.opacity(0.4))
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
        manager.sendTempMessage(text)
        draft = ""
    }
}
