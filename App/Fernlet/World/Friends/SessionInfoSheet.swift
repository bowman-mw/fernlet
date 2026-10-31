import SwiftUI
import UIKit
import FernletDomainModel
import FernletFoundation
import ProximityKit
import FernletConnections
import FernletSocial
import AppServices
import FernletUI
import FernletProximityUI

/// Session info (`b3-session-info`, World Review Batch 3), which the person sees as Hangout info (owner's
/// form answer 33; World Friends spec §2): the hangout's name (tap the pencil to rename it), how many
/// people are connected, the shots left, open or closed access, the people with a heart and a ••• menu
/// each, the removal requests, and End hangout. Only the words say hangout; its types and identifiers
/// (`sessionInfo.*`) keep the session's names.
///
/// It lived inside the disposable camera's info sheet until the World build moved it to Home's session
/// button (owner, 2026-10-24: "Messages, Session info and Leave" on the button; the camera has no info
/// or messages buttons any more). Its rules are the camera's, unchanged: names are always
/// `PeerNameDisplay`-filtered (never an identifier, 2026-09-29), Block asks first, a removal needs a
/// second participant, and the heart takes the transport order ``sessionHeartTransport(meshLinked:presenceReachable:meshAddressable:)``
/// pins. End hangout hands back to the presenter, which asks "End hangout?" and leaves.
struct SessionInfoSheet: View {
    var store: FernletStore
    /// The person tapped End session: the presenter closes this sheet and asks first.
    let onEndSession: () -> Void
    let onDone: () -> Void

    @State private var renamingMesh = false
    /// The session member a "Block …?" confirmation is about — the in-session menu used to block
    /// instantly while the roster's Block asked first.
    @State private var participantToBlock: MeshSessionParticipant?

    private var manager: MeshNetworkManager { store.meshNetworkManager }
    /// Fernlet's mesh features: the vouch list's labels, the in-session hearts and the session photos.
    private var features: FernletMeshFeatures { store.meshFeatures }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                renameButton
                sessionStats
                accessPicker
                FernletFramedSection("People") {
                    ForEach(manager.sessionParticipants) { participantRow($0) }
                }
                heartStatusRow
                presenceNudge
                debugInspectorButton
                removalRequestsSection
                endSessionButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SheetHeader(title: titleText, onDone: onDone)
        }
        .sheet(isPresented: $renamingMesh) {
            SessionRenameSheet(manager: manager, initialName: manager.currentMesh?.name ?? "") { renamingMesh = false }
        }
        .alert(
            participantToBlock.map { "Block \(shownName($0))?" } ?? "Block this person?",
            isPresented: $participantToBlock.isPresent(),
            presenting: participantToBlock
        ) { participant in
            Button("Block", role: .destructive) {
                manager.block(participant)
                participantToBlock = nil
            }
            Button("Cancel", role: .cancel) { participantToBlock = nil }
        } message: { participant in
            Text("Blocking \(shownName(participant)) will hide their content from you and yours from them, and drop them from this hangout.")
        }
        .fernletSheet()
        .accessibilityIdentifier("sessionInfo.sheet")
    }

    /// The hangout's name, or "Hangout" before the mesh has one.
    private var titleText: Text {
        guard let mesh = manager.currentMesh else { return Text("Hangout") }
        return Text(verbatim: mesh.name)
    }

    /// The pencil under the title: rename the session (it rides the mesh descriptor to everyone).
    @ViewBuilder
    private var renameButton: some View {
        if manager.currentMesh != nil {
            Button { renamingMesh = true } label: {
                WorldSpriteView(sprite: WorldSprites.pen, scale: 3)
                    .frame(width: 44, height: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rename hangout")
            .accessibilityIdentifier("sessionInfo.rename")
        }
    }

    /// Participant count and remaining film.
    private var sessionStats: some View {
        // Real plurals — "2 person(s) connected" is a placeholder that shipped. Each is ONE
        // count-bearing key whose English "1 person" / "1 shot" form is the catalog's `one` plural
        // variation, not an `== 1` branch between two English sentences.
        let people = manager.sessionParticipants.count
        let shots = features.photos.filmRemaining
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(people) people connected")
                .font(FernletFramedFont.rowTitle)
                .foregroundStyle(WorldPalette.dim)
            HStack(spacing: 8) {
                WorldSpriteView(sprite: FriendsSprites.film, scale: 2)
                Text("\(shots) shots left")
                    .font(FernletFramedFont.rowTitleBold)
                    .foregroundStyle(WorldPalette.bark)
            }
            // P8 item 0 (c): photos that reached nobody are said once, as a count — through the
            // copy table, never composed here — and never as an alert per shot.
            if let kept = RoutedShareRefusalCopy.photoKeptNotice(count: features.photos.photosKeptOnThisPhone) {
                Text(kept)
                    .font(FernletFramedFont.note)
                    .foregroundStyle(Color.terracottaInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("camera.photosKeptNotice")
            }
        }
    }

    /// Open vs closed session access.
    private var accessPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Hangout access")
            FernletSegmentedPicker("Hangout access", selection: Binding(
                get: { manager.isSessionOpen ? MeshMode.open : MeshMode.closed },
                set: { manager.setSessionOpen($0 == .open) }
            ), options: [MeshMode.open, MeshMode.closed]) { mode in
                mode == .open ? Text("Open") : Text("Closed")
            }
            .accessibilityIdentifier("sessionInfo.mode")
        }
    }

    /// One roster row: the face, the name, the vouch label, the heart for trusted friends, the menu.
    private func participantRow(_ participant: MeshSessionParticipant) -> some View {
        HStack(spacing: 12) {
            WorldSpriteView(sprite: WorldSprites.face, scale: 2)
            (participant.isLocal ? Text("You") : Text(verbatim: shownName(participant)))
                .font(FernletFramedFont.rowTitle)
                .foregroundStyle(WorldPalette.bark)
            if !participant.isLocal, let vouchLabel = features.vouchList.vouchLabel(for: participant.fingerprint) {
                FernletTag(text: Text(vouchLabel))
            }
            Spacer(minLength: 6)
            if !participant.isLocal {
                if let friend = trustedFriend(for: participant) {
                    sessionHeartButton(for: friend)
                }
                participantMenu(participant)
            }
        }
        .frame(minHeight: 54)
    }

    /// What a person reads for a session participant (2026-09-29): the local user's own name as
    /// is, and for everyone else their chosen name or "Someone nearby", never an identifier. A
    /// committed peer not yet in the mesh descriptor is projected from its slot, whose only name
    /// before disclosure is the QUIC transport's instance name (`fernlet-mesh-…`), truncated.
    ///
    /// Display only: `MeshNetworkManager.proposeRemoval(of:)` and `block(_:)` still receive the
    /// participant itself.
    ///
    /// - Parameter participant: One row of `manager.sessionParticipants`.
    /// - Returns: The text to render.
    private func shownName(_ participant: MeshSessionParticipant) -> String {
        guard !participant.isLocal else { return participant.displayName }
        return PeerNameDisplay.shown(participant.displayName, fingerprint: participant.fingerprint, in: .fernlet)
    }

    /// The per-participant overflow menu: propose a removal, or block outright.
    private func participantMenu(_ participant: MeshSessionParticipant) -> some View {
        Menu {
            Button {
                manager.proposeRemoval(of: participant)
            } label: {
                Label("Ask to remove", systemImage: "person.badge.minus")
            }
            Button(role: .destructive) {
                // Same action, same person, same safety net as Friends & Blocks: blocking here also
                // drops them from the shared photo and chat flow, so it asks first.
                participantToBlock = participant
            } label: {
                Label("Block", systemImage: "hand.raised")
            }
        } label: {
            SessionFramedSquare {
                Text(verbatim: "•••")
                    .font(FernletFramedFont.buttonSmall)
                    .foregroundStyle(WorldPalette.mossInk)
            }
        }
        .accessibilityLabel("Options for \(shownName(participant))")
    }

    /// TF b19 item 5 tier 1: surface heart send state inline (no longer silent).
    ///
    /// **Two sources, one row** (P6 item 6). The mesh path publishes a frozen token the app forks
    /// into a `LocalizedStringKey` (`SessionHeartStatusCopy`); the presence fallback publishes a
    /// `String` its manager already resolved, which ``presenceHeartStatusText`` draws verbatim
    /// (never `LocalizedStringKey(runtimeString)`). The mesh line wins when present: only one send
    /// runs at a time, and the mesh mint is synchronous.
    @ViewBuilder
    private var heartStatusRow: some View {
        if let status = sessionHeartStatusKey {
            heartStatusText(Text(status))
        } else if let status = presenceHeartStatusText {
            heartStatusText(status)
        }
    }

    /// The one set of modifiers both status sources share.
    private func heartStatusText(_ text: Text) -> some View {
        text
            .font(FernletFramedFont.note)
            .foregroundStyle(WorldPalette.mossInk)
            .frame(maxWidth: .infinity, alignment: .center)
            .fernletWrappingText()
            .accessibilityIdentifier("sessionInfo.heartStatus")
    }

    /// TF b19 item 5 tier 1: actionable prompt for the older-build fallback that still needs the
    /// presence radio (hearts on, Nearby Friends off). Hidden in the common mesh path.
    @ViewBuilder
    private var presenceNudge: some View {
        if sessionHeartsNeedPresence {
            Button {
                store.setAllowNearbyPresence(true)
            } label: {
                Text("Turn on Nearby Friends to send hearts").frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.primary))
            .accessibilityIdentifier("sessionInfo.enablePresence")
        }
    }

    /// The Connection Inspector entry point, behind the proximity debug-tools setting as clamped
    /// for this build (`FernletStore.proximityDebugToolsEnabled`: always off in Release).
    @ViewBuilder
    private var debugInspectorButton: some View {
        if store.proximityDebugToolsEnabled {
            Button {
                store.showConnectionInspector = true
            } label: {
                FriendsLinkCard(title: Text("Connection Inspector"), sprite: FriendsSprites.people, spriteScale: 2)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sessionInfo.inspectorButton")
        }
    }

    /// Pending removal proposals awaiting a second.
    @ViewBuilder
    private var removalRequestsSection: some View {
        if !manager.pendingRemovalProposals.isEmpty {
            SectionLabel("Removal Requests")
            ForEach(manager.pendingRemovalProposals) { proposal in
                removalRequestCard(proposal)
            }
        }
    }

    /// One pending removal proposal: what was asked, and this device's part in it.
    private func removalRequestCard(_ proposal: MeshRemovalProposalPayload) -> some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(PeerNameDisplay.shown(proposal.proposerDisplayName, fingerprint: proposal.proposerFingerprint, in: .fernlet)) asked to remove \(PeerNameDisplay.shown(proposal.targetDisplayName, fingerprint: proposal.targetFingerprint, in: .fernlet)).")
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.bark)
                if manager.canSecondRemoval(proposal) {
                    Button("Second Removal", role: .destructive) {
                        manager.secondRemoval(proposal)
                    }
                    .buttonStyle(ActionPillButtonStyle(.destructive, size: .small))
                } else {
                    Text("Waiting for another participant to second this decision.")
                        .font(FernletFramedFont.note)
                        .foregroundStyle(WorldPalette.dim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Ends the hangout: the presenter asks "End hangout?" first.
    private var endSessionButton: some View {
        Button(action: onEndSession) {
            Text("End hangout").frame(maxWidth: .infinity)
        }
        .buttonStyle(ActionPillButtonStyle(.destructive))
        .padding(.top, 4)
        .accessibilityIdentifier("sessionInfo.endSession")
    }
}

// MARK: - Send good vibes (in-session)

extension SessionInfoSheet {
    /// The trusted-friend record behind a session participant, when hearts can go to them:
    /// consent on, known in the vault by fingerprint, not blocked or removed.
    private func trustedFriend(for participant: MeshSessionParticipant) -> ProximityTrustedPeerRecord? {
        guard store.settings.allowNearbyHearts else { return nil }
        return store.trustedProximityPeers.first {
            IdentityService.fingerprintsMatch($0.fingerprint, participant.fingerprint)
                && $0.blockedAt == nil
                && $0.revokedAt == nil
        }
    }

    /// A quiet one-tap heart beside a connected friend. TF b19 item 5: in-session hearts ride the
    /// live mesh session (reliable — the peer is right here, already connected over a verified channel)
    /// instead of the fragile on-demand presence connect. A session peer on an older build (no `hearts`
    /// mesh capability) falls back to the presence path so nothing regresses. Enabled only while the
    /// 5-minute cooldown to them is clear, they're reachable, and no send is in flight; no counts shown
    /// anywhere. A tick marks the cooldown — a state, never a number.
    private func sessionHeartButton(for friend: ProximityTrustedPeerRecord) -> some View {
        let onCooldown = !store.heartLedger.canSendHeart(to: friend.fingerprint)
        // `canSendHeart` is fail-closed (Track A): an UNLOADED ledger also answers false, and the
        // cooldown copy would be a lie there — nothing was sent. Say what is actually wrong, exactly
        // as the friend row does (FriendListView's `onCooldown` branch).
        let ledgerUnavailable = onCooldown && !store.heartLedger.isLoaded
        // **Three-way since P6 item 6, and the order matters** — it lives in
        // `sessionHeartTransport(meshLinked:presenceReachable:meshAddressable:)` below, which is
        // where its reasoning and its behavioural pin are. This body only reads the three seams.
        let meshLinked = features.hearts.hasLiveHeartSlot(forFingerprint: friend.fingerprint)
        let presenceReachable = store.presenceManager.isReachable(fingerprint: friend.fingerprint)
        let meshAddressable = features.hearts.canSendSessionHeart(toFingerprint: friend.fingerprint)
        let transport = Self.sessionHeartTransport(
            meshLinked: meshLinked, presenceReachable: presenceReachable,
            meshAddressable: meshAddressable
        )
        // **Reachability is the transport's own answer, never a re-derived disjunction** (P6 item 6
        // fix review, P3-e).
        let reachable = transport != .unavailable
        let sending = sessionHeartSendInProgress
        let friendName = PeerNameDisplay.shown(friend.displayName, fingerprint: friend.fingerprint, placeholder: .met, in: .fernlet)
        let firstName = PeerNameDisplay.firstName(friend.displayName, fingerprint: friend.fingerprint, placeholder: .met, in: .fernlet)
        let state = SendGoodVibesLabel.state(onCooldown: onCooldown, reachable: reachable, sending: sending)
        return Button {
            // Haptic acknowledgement so the tap is never silent (TF b19 item 5 tier 1): `logged`, a
            // one-tap action that landed in place.
            FernletFeedback.system.play(.logged)
            switch transport {
            case .mesh: features.hearts.sendSessionHeart(to: friend)
            case .presence: store.presenceManager.sendHeart(to: friend)
            case .unavailable: break
            }
        } label: {
            SessionFramedSquare {
                WorldSpriteView(sprite: state == .cooldown ? WorldSprites.check : WorldSprites.heartSm, scale: 2)
                    .opacity(state == .notNearby ? 0.4 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(onCooldown || !reachable || sending)
        .accessibilityLabel(
            ledgerUnavailable
                ? "Fernlet couldn't reach its own notes just now — unlock and reopen to send hearts."
                : onCooldown
                    ? "You just sent \(firstName) some warmth — hearts settle for a few minutes."
                    : reachable
                        ? "Send good vibes to \(friendName)"
                        : "\(firstName) isn't reachable for a heart right now."
        )
        // Voice Control: the heart is drawn with no words, and every row has one, so the friend's
        // name is what makes it sayable and unique ("Heart Sam"), whichever state the label is in.
        .accessibilityInputLabels([Text("Heart \(firstName)"), Text("Send good vibes to \(firstName)")])
    }

    /// Which pipe one heart tap takes.
    enum SessionHeartTransport: Equatable {
        /// The routed store: delivered now over a live slot, or staged and custodied for a member
        /// with no link.
        case mesh
        /// The presence path, which delivers now to a friend who is presence-reachable.
        case presence
        /// Neither can carry it; the affordance is disabled in this state.
        case unavailable
    }

    /// The three-way order behind the heart tap, as a pure function of the three seams the button
    /// reads (P6 item 6 fix review, P3-6).
    ///
    /// The order is a PRODUCT rule. A routed heart to an admitted member with no live mesh slot is
    /// staged and CUSTODIED — delivered only if a link forms before the mesh ends, and otherwise
    /// expired at `hardDeadline + 20 min` while the sender saw "Sent" and spent five minutes of
    /// cooldown. So a live presence link, which delivers now, must still win over that: a live
    /// `.hearts` slot first (delivered now, capability known), then presence while the friend is
    /// presence-reachable (delivered now), and only then a routed custodied heart — the star case,
    /// which is the unlock and which presence cannot serve at all.
    ///
    /// - Parameters:
    ///   - meshLinked: A live, hearts-capable slot faces the friend.
    ///   - presenceReachable: The presence path can reach them right now.
    ///   - meshAddressable: They are on the derived roster with a resolvable key.
    /// - Returns: the pipe the tap takes.
    static func sessionHeartTransport(
        meshLinked: Bool, presenceReachable: Bool, meshAddressable: Bool
    ) -> SessionHeartTransport {
        if meshLinked, meshAddressable { return .mesh }
        if presenceReachable { return .presence }
        if meshAddressable { return .mesh }
        return .unavailable
    }

    /// A send is in flight — presence-only since P6 item 6: the routed mint is synchronous, so the
    /// mesh path has no `.sending` window to describe.
    private var sessionHeartSendInProgress: Bool {
        switch store.presenceManager.heartSendState {
        case .connecting, .verifying: return true
        default: return false
        }
    }

    /// The MESH path's status line, localized by construction (P6 item 6).
    private var sessionHeartStatusKey: LocalizedStringKey? {
        SessionHeartStatusCopy.line(features.hearts.sessionHeartState)
    }

    /// The PRESENCE fallback's status line. `PresenceManager`'s `heartSendState.failed(message:)`
    /// arrives already resolved in this device's language, so it is drawn verbatim — never through
    /// `LocalizedStringKey(runtimeString)`; the other three lines are this view's own keys. Names go
    /// through `SessionHeartStatusCopy.shownRecipient`.
    private var presenceHeartStatusText: Text? {
        switch store.presenceManager.heartSendState {
        case .idle: return nil
        case .connecting(let name): return Text("Connecting to \(SessionHeartStatusCopy.shownRecipient(name))…")
        case .verifying(let name): return Text("Saying hello to \(SessionHeartStatusCopy.shownRecipient(name))…")
        case .sent(let name): return Text("Sent \(SessionHeartStatusCopy.shownRecipient(name)) some good vibes.")
        case .failed(let message): return Text(verbatim: message)
        }
    }

    /// TF b19 item 5 tier 1: the actionable `needsPresence` affordance, only where the presence path
    /// still applies — a session friend on an OLDER build who can't receive a mesh heart, while
    /// hearts are on but the Nearby Friends (presence) radio is off.
    private var sessionHeartsNeedPresence: Bool {
        guard store.settings.allowNearbyHearts, !store.settings.allowNearbyPresence else { return false }
        return manager.sessionParticipants.contains { participant in
            guard !participant.isLocal, let friend = trustedFriend(for: participant) else { return false }
            return !features.hearts.canSendSessionHeart(toFingerprint: friend.fingerprint)
                && !features.hearts.hasLiveHeartSlot(forFingerprint: friend.fingerprint)
        }
    }
}

/// A framed 44-pt square control on raised paper: the session's heart and ••• (`b3-session-info`).
struct SessionFramedSquare<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        content
            .frame(width: 44, height: 44)
            .background(WorldPalette.paperLight, in: shape)
            .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: FernletFramedLook.frameWidth))
            .contentShape(shape)
    }
}

/// Renaming the session (`b3-session-rename`): the new name, up to 40 characters, saved with Rename.
/// The name rides the mesh descriptor to every peer, so it is bounded at the field and again on save.
struct SessionRenameSheet: View {
    let manager: MeshNetworkManager
    let initialName: String
    let onClose: () -> Void

    /// The cap on a session name typed here — it rides the mesh descriptor to every peer.
    static let maxMeshNameLength = 40

    @State private var newMeshName = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                SheetField("New name") {
                    TextField("Hangout name", text: Binding(
                        get: { newMeshName },
                        set: { newMeshName = String($0.prefix(Self.maxMeshNameLength)) }
                    ), prompt: .fieldPrompt("Hangout name"))
                    .sheetTextInput()
                    .accessibilityIdentifier("sessionInfo.renameField")
                    // How much of the 40 is used (b3-session-rename); the field stops at 40.
                    Text(verbatim: "\(newMeshName.count)/\(Self.maxMeshNameLength)")
                        .font(FernletFramedFont.rowDetail)
                        .monospacedDigit()
                        .foregroundStyle(WorldPalette.dim)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            SheetSaveBar(
                label: "Rename",
                disabled: newMeshName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                // R3/R5: the name is broadcast to every peer in the mesh descriptor, so it is
                // bounded here as well as at the field (the advertised copy caps separately).
                let trimmed = String(newMeshName.trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(Self.maxMeshNameLength))
                guard !trimmed.isEmpty else { return }
                manager.renameMesh(trimmed)
                onClose()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SheetHeader(title: Text("Rename hangout"), onCancel: onClose)
        }
        .onAppear { newMeshName = String(initialName.prefix(Self.maxMeshNameLength)) }
        .fernletSheet()
    }
}
