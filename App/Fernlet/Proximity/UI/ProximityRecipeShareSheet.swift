import ProximityKit
import SwiftUI
import FernletDomainModel
import FernletLock
import FernletUI

/// One recipe the user chose to share, packaged for the share sheet.
///
/// Built at the tap site in `FoodView` (from a local recipe or a saved web recipe) and presented
/// via `.sheet(item:)`: `payload` is the signed wire body ``ProximityRecipeShareSheet`` sends
/// over the proximity radio, and `shareText` is the plain-text fallback for the system
/// "Share outside Fernlet" link.
struct ProximityRecipeShareDraft: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var shareText: String
    var payload: ProximityRecipeSharePayload
}

/// The "share this recipe with a nearby Fernlet" sheet: discovers recipients over the recipe
/// radio and sends the drafted payload to the tapped one.
///
/// Runs `ProximityRecipeShareManager` for its whole presentation (`start()` on appear, `stop()`
/// on disappear) and renders its observable state: the recipient list (with the hard 2-device cap
/// — every other row disables while one is engaged), a searching pulse that gives way to a
/// "no nearby Fernlets" hint after ~6 s, the connect/send/sent status line, and a collapsible
/// diagnostics card. An "Include notes" toggle strips the payload's share notes before sending,
/// and an "Include picture" toggle (default ON, shown only when the draft carries one) strips the
/// attached recipe photo — the picture can be the sender's own kitchen shot, so it gets the same
/// per-share control as their notes.
/// On disappear it also restarts passive listening behind the same opt-in + active-scene + lock
/// gates ContentView enforces — the go-dark-after-share fix, since `stop()` would otherwise leave
/// the device undiscoverable for inbound recipes until the next scene/tab/lock event.
struct ProximityRecipeShareSheet: View {
    var draft: ProximityRecipeShareDraft
    var manager: ProximityRecipeShareManager
    var store: FernletStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(FernletLockService.self) private var lockService
    @State private var includeNotes = true
    /// Whether the recipe's attached picture rides the share. Default ON (owner decision: the
    /// image rides the share); the toggle exists because the picture can be the sender's own
    /// personal photo, deserving the same per-share consent as their notes.
    @State private var includePhoto = true
    @State private var hasFinishedInitialSearch = false
    @State private var searchDelayTask: Task<Void, Never>?
    @State private var dismissAfterSendTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ScreenHeader(
                            // The user's own recipe name — `verbatim:` so it is never treated as
                            // a catalog key.
                            title: Text(verbatim: draft.title),
                            subtitle: Text("Share with a nearby Fernlet."),
                            subtitleFirst: false,
                            // The title is the user's own recipe name: three lines rather than the
                            // default two, so "Grandma's slow-cooked white bean…" keeps its name at
                            // accessibility sizes instead of being cut mid-word.
                            titleLineLimit: 3
                        )

                        recipientCard

                        if let statusText {
                            Text(statusText)
                                .font(.fernlet(.bubble))
                                .foregroundStyle(Color.slate)
                                .fernletWrappingText()
                        }

                        if !manager.diagnosticEvents.isEmpty {
                            diagnosticDetailsCard
                        }

                        externalShareCard
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
            .onAppear { handleAppear() }
            .onDisappear { handleDisappear() }
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

    /// The nearby card: the per-share notes/picture toggles and the recipient list (or the
    /// searching / no-nearby state).
    private var recipientCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Fernlet nearby", systemImage: "dot.radiowaves.left.and.right")
                    .font(.fernlet(.header))
                    .foregroundStyle(Color.bark)

                shareToggles

                recipientList
            }
        }
    }

    /// Per-share consent for the two optional payload parts: the sender's notes and their picture.
    @ViewBuilder
    private var shareToggles: some View {
        if draft.payload.hasShareNotes {
            Toggle(isOn: $includeNotes) {
                Text("Include notes")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
            }
            .toggleStyle(.switch)
            .tint(Color.moss)
        }

        if draft.payload.imageJPEGData != nil {
            Toggle(isOn: $includePhoto) {
                Text("Include picture")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
            }
            .toggleStyle(.switch)
            .tint(Color.moss)
        }
    }

    /// The nearby recipients, or the searching / nothing-found state while there are none.
    @ViewBuilder
    private var recipientList: some View {
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
                    recipientRow(recipient, isLockedOut: isLockedOut)
                }
            }
        }
    }

    /// One tappable recipient row; tapping sends the payload to that device.
    private func recipientRow(_ recipient: ProximityRecipeShareRecipient, isLockedOut: Bool) -> some View {
        Button {
            manager.sendRecipeShare(outgoingPayload, to: recipient)
        } label: {
            HStack(spacing: 12) {
                // T1-8: both glyphs are decorative next to text that already names the
                // recipient/action — without this the button's announcement leaks their raw SF
                // Symbol names ("person crop circle badge checkmark", "paperplane fill").
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.moss)
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
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
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .disabled(isLockedOut)
        .opacity(isLockedOut ? 0.4 : 1)
    }

    /// The escape hatch: share the recipe as plain text through the system share sheet.
    private var externalShareCard: some View {
        FernletCard {
            ShareLink(item: draft.shareText) {
                Label("Share outside Fernlet", systemImage: "square.and.arrow.up")
                    .font(.fernlet(.label))
                    // F3: text ink, not the `moss` accent (3.74:1, fails 4.5:1 small text).
                    .foregroundStyle(Color.mossInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
    }

    /// Starts the recipe radio and arms the "nothing nearby" timeout.
    private func handleAppear() {
        manager.start()
        scheduleNoNearbyState()
    }

    /// Tears the sheet's work down and — the go-dark-after-share fix — restarts passive listening
    /// behind the same gates ContentView enforces.
    private func handleDisappear() {
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
            // The sleep result IS the cancellation check (R7): `Task.sleep` throws exactly when the
            // task is cancelled, so a cancelled timeout simply returns.
            do {
                try await Task.sleep(for: .seconds(6))
            } catch {
                return
            }
            guard manager.nearbyRecipients.isEmpty else { return }
            hasFinishedInitialSearch = true
        }
    }

    private func scheduleDismissAfterSendIfNeeded(_ state: ProximityRecipeShareManager.SendState) {
        dismissAfterSendTask?.cancel()
        guard case .sent = state else { return }
        dismissAfterSendTask = Task { @MainActor in
            // Same shape as `scheduleNoNearbyState`: a cancelled wait must not dismiss the sheet.
            do {
                try await Task.sleep(for: .seconds(1.4))
            } catch {
                return
            }
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
        var payload = includeNotes ? draft.payload : draft.payload.omittingShareNotes()
        if !includePhoto { payload = payload.omittingImage() }
        return payload
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
