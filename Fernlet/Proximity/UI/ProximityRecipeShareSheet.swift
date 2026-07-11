import ProximityKit
import SwiftUI
import FernletDomainModel
import FernletLock

struct ProximityRecipeShareDraft: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var shareText: String
    var payload: ProximityRecipeSharePayload
}

struct ProximityRecipeShareSheet: View {
    var draft: ProximityRecipeShareDraft
    var manager: ProximityRecipeShareManager
    var store: FernletStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(FernletLockService.self) private var lockService
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
                                    .font(.fernlet(.header))
                                    .foregroundStyle(Color.bark)

                                if draft.payload.hasShareNotes {
                                    Toggle(isOn: $includeNotes) {
                                        Text("Include notes")
                                            .font(.fernlet(.label))
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
                                            // Hard 2-device cap UX: while connecting to / paired
                                            // with one recipient, every OTHER row is disabled —
                                            // a tap there would only hit the manager's visible
                                            // outbound-cap refusal anyway.
                                            let isLockedOut = manager.engagedRecipientID != nil
                                                && manager.engagedRecipientID != recipient.id
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
                                                            .font(.fernlet(.headerMedium))
                                                            .foregroundStyle(Color.bark)
                                                            .lineLimit(1)
                                                        Text(recipient.fingerprint.map { String($0.prefix(8)) } ?? "Verifying…")
                                                            .font(.fernlet(.labelSmall))
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
                                            .disabled(isLockedOut)
                                            .opacity(isLockedOut ? 0.4 : 1)
                                        }
                                    }
                                }
                            }
                        }

                        if let statusText {
                            Text(statusText)
                                .font(.fernlet(.bubble))
                                .foregroundStyle(Color.slate)
                                .fernletWrappingText()
                        }

                        if !manager.diagnosticEvents.isEmpty {
                            diagnosticDetailsCard
                        }

                        FernletCard {
                            ShareLink(item: draft.shareText) {
                                Label("Share outside Fernlet", systemImage: "square.and.arrow.up")
                                    .font(.fernlet(.label))
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
                // Go-dark-after-share fix (mesh redesign Phase 3b): stop() tears the recipe
                // radio down, and historically nothing restarted passive listening until the
                // next tab/scene/lock event — after one share the device silently stopped
                // being discoverable for inbound recipes. Restart it here behind the same
                // opt-in + scene + lock gates ContentView enforces. The scene check is NOT
                // implicit: the post-send auto-dismiss can race a backgrounding (onDisappear
                // then fires with the scene inactive), and restarting there would broadcast
                // while backgrounded — the privacy line every listener holds. No unit seam
                // reaches this view closure; ContentView's updateRecipeShareListener chain
                // remains the authoritative gate — any later scene/tab/lock/opt-out change
                // re-evaluates and stops the manager again (an inactive-scene dismissal is
                // then restarted by the next scene-active event, not left dark). Tab is
                // implicitly satisfied (the sheet only presents over recipe-share tabs).
                if scenePhase == .active, store.settings.allowNearbyRecipeShares, isUnlockedForListening {
                    manager.start()
                }
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
            SearchingPulse(tint: Color.moss, size: 56, systemImage: "dot.radiowaves.left.and.right")
            Text("Looking for nearby people...")
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
            Text("Open Fernlet on the other device and keep it nearby.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
        .padding(.vertical, 4)
    }

    private var noNearbyView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No nearby Fernlets found", systemImage: "person.crop.circle.badge.questionmark")
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.bark)
            Text("Ask the other person to open Fernlet on Home, Food, or Move while unlocked.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            Button {
                hasFinishedInitialSearch = false
                manager.refreshDiscovery()
                manager.start()
                scheduleNoNearbyState()
            } label: {
                Label("Search again", systemImage: "arrow.clockwise")
                    .font(.fernlet(.label))
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
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.slate)
                                .frame(width: 74, alignment: .leading)
                            Text(event.message)
                                .font(.fernlet(.bodySmall))
                                .foregroundStyle(Color.bark)
                                .fernletWrappingText()
                        }
                    }
                }
                .padding(.top, 10)
            } label: {
                Label("Connection details", systemImage: "list.bullet.rectangle")
                    .font(.fernlet(.label))
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

    private var isUnlockedForListening: Bool {
        switch lockService.state {
        case .notConfigured, .unlocked: true
        case .locked: false
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
