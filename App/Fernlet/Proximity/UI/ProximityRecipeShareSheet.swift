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
/// "no nearby Fernlets" hint after ~6 s, the connect/send/sent status line, and — with the
/// proximity debug tools on, never in Release — a collapsible diagnostics card. Recipients are
/// named through `PeerNameDisplay`, never by fingerprint. An "Include notes" toggle strips the payload's share notes before sending,
/// and an "Include picture" toggle (default ON, shown only when the draft carries one) strips the
/// attached recipe photo — the picture can be the sender's own kitchen shot, so it gets the same
/// per-share control as their notes.
/// On disappear it also restarts passive listening behind the same opt-in + active-scene + lock
/// gates ContentView enforces — the go-dark-after-share fix, since `stop()` would otherwise leave
/// the device undiscoverable for inbound recipes until the next scene/tab/lock event.
///
/// **When a share ends, the sheet says so and stays.** It used to dismiss itself 1.4 s after a send,
/// which looked exactly like a cancel, and a failure line cleared itself after 2.5 s with nothing
/// saying to retry. Now the content cross-fades to a ``RecipeShareConfirmationPanel`` built from the
/// manager's ``ProximityRecipeShareManager/lastShareOutcome`` (latched by
/// ``RecipeShareOutcomeLatch``, so a share the user cancelled never raises one), announced to
/// VoiceOver, with a success or error haptic. It stays until Done. What the panel may claim is
/// "sent", never "delivered": see ``RecipeShareConfirmation``.
///
/// The radio's timeline after a successful send is unchanged: 1.4 s later
/// (``RecipeShareRadioHandBack/delay``, the same post-send pairing lifetime the auto-dismiss gave) a
/// hand back runs the same gated stop-and-restart the sheet's disappearance would have, so a panel
/// left open never holds the pairing (or keeps the other phone's radio closed to others). The
/// success moves custody of the radio to that hand back (``RecipeShareRadioCustody``), so a Done
/// or a swipe-down inside the window closes the sheet without stopping the radio early: a text
/// recipe's frame may still be draining.
struct ProximityRecipeShareSheet: View {
    var draft: ProximityRecipeShareDraft
    var manager: ProximityRecipeShareManager
    var store: FernletStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(FernletLockService.self) private var lockService
    @State private var includeNotes = true
    /// Whether the recipe's attached picture rides the share. Default ON (owner decision: the
    /// image rides the share); the toggle exists because the picture can be the sender's own
    /// personal photo, deserving the same per-share consent as their notes.
    @State private var includePhoto = true
    @State private var hasFinishedInitialSearch = false
    @State private var searchDelayTask: Task<Void, Never>?
    /// Which share's outcome this sheet is waiting for, and the confirmation on screen.
    @State private var latch = RecipeShareOutcomeLatch()
    /// Who stops the recipe radio when the sheet is done: the sheet from appear until a successful
    /// send, then the post-send hand back (see `startRadioHandBack(after:)`).
    @State private var custody = RecipeShareRadioCustody.sheet

    var body: some View {
        NavigationStack {
            // An always-present container, so the lifecycle hooks below stay on ONE view: on a bare
            // `if`/`else` they would re-fire as the content switches, and `onDisappear` stops the radio.
            ZStack {
                if let confirmation = latch.confirmation {
                    RecipeShareConfirmationPanel(
                        confirmation: confirmation,
                        onDone: { dismiss() },
                        onRetry: retryShare
                    )
                    .transition(reduceMotion ? .identity : .opacity)
                } else {
                    pickerContent
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .background(Color.parchment)
            .onAppear { handleAppear() }
            .onDisappear { handleDisappear() }
            .onChange(of: manager.lastShareOutcome) { _, outcome in receive(outcome) }
            .onChange(of: manager.nearbyRecipients) { _, recipients in
                if recipients.isEmpty {
                    scheduleNoNearbyState()
                } else {
                    searchDelayTask?.cancel()
                    hasFinishedInitialSearch = false
                }
            }
            .sensoryFeedback(trigger: latch.confirmation) { _, shown in
                shown.map { $0.tone == .sent ? .success : .error }
            }
        }
    }

    /// The picker: the recipe, the nearby card, the status line, diagnostics and the "Share outside
    /// Fernlet" link. Carries the toolbar Done, so there is only one Done while the panel shows.
    private var pickerContent: some View {
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
                    statusText
                        .font(.fernlet(.bubble))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }

                // Developer detail (2026-09-29): its lines name peers by fingerprint and quote
                // transport errors, so it is not part of sharing a recipe.
                if store.proximityDebugToolsEnabled, !manager.diagnosticEvents.isEmpty {
                    diagnosticDetailsCard
                }

                externalShareCard
            }
            .padding(20)
            .padding(.bottom, 10)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
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
            send(to: recipient)
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
                // The name only (2026-09-29): the hex subtitle was an identifier, and its
                // pre-handshake "Verifying…" claimed work nobody had started.
                Text(verbatim: PeerNameDisplay.shown(recipient.displayName, fingerprint: recipient.fingerprint))
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                    .lineLimit(1)
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
        latch.reset()
        custody = .sheet
        manager.start()
        scheduleNoNearbyState()
    }

    /// Tears the sheet's work down and — the go-dark-after-share fix — restarts passive listening
    /// behind the same gates ContentView enforces, unless a post-send hand back has the radio.
    ///
    /// The latch is reset FIRST: `stop()` publishes `interrupted` for a share still in flight, and a
    /// share the user cancelled by closing the sheet must raise nothing (not even an announcement
    /// from a sheet on its way out). A pending hand back is deliberately NOT cancelled: closing the
    /// panel inside its window must not stop the radio before the sent frame has had time to drain.
    private func handleDisappear() {
        searchDelayTask?.cancel()
        latch.reset()
        guard custody.sheetStopsRadioOnDisappear else { return }
        let listen = scenePhase == .active
            && store.settings.allowNearbyRecipeShares
            && Self.allowsListening(lockService.state)
        Self.standDown(manager, thenListen: listen)
    }

    /// Stops the radio and, when `thenListen`, restarts passive listening.
    ///
    /// Go-dark-after-share fix (mesh redesign Phase 3b): stop() tears the recipe radio down, and
    /// historically nothing restarted passive listening until the next tab/scene/lock event — after
    /// one share the device silently stopped being discoverable for inbound recipes. Both callers
    /// restart it behind the opt-in + scene + lock gates. The scene check is NOT implicit: a
    /// dismissal (or the post-send hand back) can race a backgrounding, and restarting there would
    /// broadcast while backgrounded — the privacy line every listener holds. No unit seam reaches
    /// this view code; the store's run policy remains the authoritative gate — any later
    /// scene/tab/lock/opt-out edge re-evaluates, stops the manager again, or restarts a listener its
    /// verdict wants up (so a stop here is never left dark).
    ///
    /// Static, taking the manager, so the hand back can run it after the sheet has gone.
    private static func standDown(_ manager: ProximityRecipeShareManager, thenListen: Bool) {
        manager.stop()
        guard thenListen else { return }
        manager.start()
    }

    /// Begins a share to `recipient`, telling the latch first so its outcome becomes a panel.
    private func send(to recipient: ProximityRecipeShareRecipient) {
        latch.beganShare(to: recipient.id)
        manager.sendRecipeShare(outgoingPayload, to: recipient)
    }

    /// A share ended: latch it (only if this sheet began it), cross-fade to the panel, speak it,
    /// and, after a success, schedule the radio hand back.
    private func receive(_ outcome: RecipeShareOutcome?) {
        guard let outcome else { return }
        var next = latch
        guard let confirmation = next.receive(outcome) else { return }
        withAnimation(reduceMotion ? nil : FernletMotion.ui) {
            latch = next
        }
        // The announcement is the one spoken signal; focus is deliberately not moved as well,
        // which would speak the panel twice.
        FernletAnnouncer.system.announce(confirmation.announcementKind, confirmation.announcement)
        if confirmation.tone == .sent {
            startRadioHandBack(after: confirmation.id)
        }
    }

    /// "Try again": re-send to the same row with the current toggles if it is still listed and not
    /// locked out; otherwise go back to the picker, whose searching / "Search again" states are the
    /// retry surface.
    private func retryShare() {
        var next = latch
        guard let recipientID = next.retry() else { return }
        withAnimation(reduceMotion ? nil : FernletMotion.ui) {
            latch = next
        }
        guard let row = manager.nearbyRecipients.first(where: { $0.id == recipientID }),
              manager.engagedRecipientID == nil || manager.engagedRecipientID == row.id else { return }
        send(to: row)
    }

    /// After a successful send, takes custody of the radio away from the sheet and gives it back to
    /// passive listening once ``RecipeShareRadioHandBack/delay`` has passed, whether the panel is
    /// still open or was closed inside the window (the drain rule).
    ///
    /// The task outlives the sheet when the user closes the panel early, so it reads nothing through
    /// the view: the manager, store and lock service are captured here, while the sheet is on
    /// screen, and the scene comes from the store's live run-policy verdict (the authority that
    /// starts the listener on every scene and tab edge), never from this view's environment, which
    /// is a snapshot and is gone with the sheet. Its handle is not kept: nothing may cancel it, and
    /// it ends on its own after one bounded sleep.
    private func startRadioHandBack(after outcomeID: UUID) {
        guard let handBack = custody.handOff(afterSendOf: outcomeID) else { return }
        let manager = manager
        let store = store
        let lockService = lockService
        Task { @MainActor in
            do {
                try await Task.sleep(for: RecipeShareRadioHandBack.delay)
            } catch {
                return
            }
            let listen = store.proximityRunVerdict?.recipeShare.isRunning == true
                && store.settings.allowNearbyRecipeShares
                && Self.allowsListening(lockService.state)
            switch handBack.step(currentOutcomeID: manager.lastShareOutcome?.id, listeningWanted: listen) {
            case .leaveAlone:
                return
            case .stop:
                Self.standDown(manager, thenListen: false)
            case .stopAndListen:
                Self.standDown(manager, thenListen: true)
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

    /// The sheet's lock gate on restarting passive listening: a lock that is not configured, or is
    /// unlocked. Takes the state rather than reading the environment, so the hand back can ask it
    /// after the sheet has gone.
    private static func allowsListening(_ state: FernletLockState) -> Bool {
        switch state {
        case .notConfigured, .unlocked, .openedWithoutPasscode: true
        case .locked: false
        }
    }

    private var outgoingPayload: ProximityRecipeSharePayload {
        var payload = includeNotes ? draft.payload : draft.payload.omittingShareNotes()
        if !includePhoto { payload = payload.omittingImage() }
        return payload
    }

    /// The progress line under the nearby card while a share is under way.
    ///
    /// `sent` shows nothing: the confirmation panel owns that moment. `failed` renders the manager's
    /// message VERBATIM, and it is English — a pre-existing residual, since ProximityKit composes it.
    /// With the panel carrying every share failure, the line now shows it only for the search
    /// refusal ("Search again" while paired), and for the moments after "Try again" returns to the
    /// list, before the 2.5 s auto-clear. Names pass through `PeerNameDisplay` with no fingerprint to
    /// hand: the recipient row files the fingerprint as the name for a peer this radio never
    /// discovered, and the helper's fingerprint-shape rule catches exactly that.
    private var statusText: Text? {
        switch manager.sendState {
        case .idle, .sent:
            nil
        case .connecting(let recipientName):
            Text("Connecting to \(PeerNameDisplay.shown(recipientName, fingerprint: nil))…")
        case .sending(let recipientName):
            Text("Sending to \(PeerNameDisplay.shown(recipientName, fingerprint: nil))…")
        case .failed(let message):
            Text(verbatim: message)
        }
    }
}
