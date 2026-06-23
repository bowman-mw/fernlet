import SwiftUI

struct ProximityRecipeShareDraft: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var shareText: String
    var payload: ProximityRecipeSharePayload
}

struct ProximityRecipeShareSheet: View {
    var draft: ProximityRecipeShareDraft
    var manager: ProximityRecipeShareManager

    @Environment(\.dismiss) private var dismiss
    @State private var includeNotes = true
    @State private var hasFinishedInitialSearch = false
    @State private var searchDelayTask: Task<Void, Never>?
    @State private var dismissAfterSendTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ScreenHeader(
                            title: draft.title,
                            subtitle: "Share with a nearby Fernlet.",
                            subtitleFirst: false
                        )

                        FernletCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Fernlet nearby", systemImage: "dot.radiowaves.left.and.right")
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(Color.bark)

                                if draft.payload.hasShareNotes {
                                    Toggle(isOn: $includeNotes) {
                                        Text("Include notes")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Color.bark)
                                    }
                                    .toggleStyle(.switch)
                                    .tint(Color.moss)
                                }

                                if manager.nearbyRecipients.isEmpty {
                                    if hasFinishedInitialSearch {
                                        noNearbyView
                                    } else {
                                        searchingView
                                    }
                                } else {
                                    VStack(spacing: 0) {
                                        ForEach(Array(manager.nearbyRecipients.enumerated()), id: \.element.id) { index, recipient in
                                            if index > 0 { FernletRowDivider() }
                                            Button {
                                                manager.sendRecipeShare(outgoingPayload, to: recipient)
                                            } label: {
                                                HStack(spacing: 12) {
                                                    Image(systemName: "person.crop.circle.badge.checkmark")
                                                        .font(.title3.weight(.semibold))
                                                        .foregroundStyle(Color.moss)
                                                        .frame(width: 34, height: 34)
                                                    VStack(alignment: .leading, spacing: 3) {
                                                        Text(recipient.displayName)
                                                            .font(.headline.weight(.semibold))
                                                            .foregroundStyle(Color.bark)
                                                            .lineLimit(1)
                                                        Text(recipient.fingerprint.map { String($0.prefix(8)) } ?? "Verifying…")
                                                            .font(.caption)
                                                            .foregroundStyle(Color.slate)
                                                    }
                                                    Spacer()
                                                    Image(systemName: "paperplane.fill")
                                                        .font(.subheadline.weight(.semibold))
                                                        .foregroundStyle(Color.moss)
                                                }
                                                .padding(.vertical, 10)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }

                        if let statusText {
                            Text(statusText)
                                .font(.caption.italic())
                                .foregroundStyle(Color.slate)
                                .fernletWrappingText()
                        }

                        if !manager.diagnosticEvents.isEmpty {
                            diagnosticDetailsCard
                        }

                        FernletCard {
                            ShareLink(item: draft.shareText) {
                                Label("Share outside Fernlet", systemImage: "square.and.arrow.up")
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(Color.moss)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 10)
                }
            }
            .background(Color.parchment)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                manager.start()
                scheduleNoNearbyState()
            }
            .onDisappear {
                searchDelayTask?.cancel()
                dismissAfterSendTask?.cancel()
                manager.stop()
            }
            .onChange(of: manager.sendState) { _, state in
                scheduleDismissAfterSendIfNeeded(state)
            }
            .onChange(of: manager.nearbyRecipients) { _, recipients in
                if recipients.isEmpty {
                    scheduleNoNearbyState()
                } else {
                    searchDelayTask?.cancel()
                    hasFinishedInitialSearch = false
                }
            }
        }
    }

    private var searchingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView()
                .tint(Color.moss)
            Text("Looking for nearby people...")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.bark)
            Text("Open Fernlet on the other device and keep it nearby.")
                .font(.caption)
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
        .padding(.vertical, 4)
    }

    private var noNearbyView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No nearby Fernlets found", systemImage: "person.crop.circle.badge.questionmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.bark)
            Text("Ask the other person to open Fernlet on Home, Food, or Move while unlocked.")
                .font(.caption)
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            Button {
                hasFinishedInitialSearch = false
                manager.refreshDiscovery()
                manager.start()
                scheduleNoNearbyState()
            } label: {
                Label("Search again", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.moss)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private var diagnosticDetailsCard: some View {
        FernletCard {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(manager.diagnosticEvents.suffix(8).reversed())) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.slate)
                                .frame(width: 74, alignment: .leading)
                            Text(event.message)
                                .font(.caption)
                                .foregroundStyle(Color.bark)
                                .fernletWrappingText()
                        }
                    }
                }
                .padding(.top, 10)
            } label: {
                Label("Connection details", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.bark)
            }
            .tint(Color.moss)
        }
    }

    private func scheduleNoNearbyState() {
        searchDelayTask?.cancel()
        guard manager.nearbyRecipients.isEmpty else { return }
        hasFinishedInitialSearch = false
        searchDelayTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, manager.nearbyRecipients.isEmpty else { return }
            hasFinishedInitialSearch = true
        }
    }

    private func scheduleDismissAfterSendIfNeeded(_ state: ProximityRecipeShareManager.SendState) {
        dismissAfterSendTask?.cancel()
        guard case .sent = state else { return }
        dismissAfterSendTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    private var outgoingPayload: ProximityRecipeSharePayload {
        includeNotes ? draft.payload : draft.payload.omittingShareNotes()
    }

    private var statusText: String? {
        switch manager.sendState {
        case .idle:
            nil
        case .connecting(let recipientName):
            "Connecting to \(recipientName)..."
        case .sending(let recipientName):
            "Sending to \(recipientName)..."
        case .sent(let recipientName):
            "Sent to \(recipientName)."
        case .failed(let message):
            message
        }
    }
}
