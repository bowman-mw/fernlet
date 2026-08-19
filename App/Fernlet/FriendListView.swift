import ProximityKit
import SwiftUI
import FernletDomainModel
import FernletUI

/// The segment filter for the trusted-peer list: everyone, active friends, or blocked peers.
///
/// Backing model for the `HubSectionPicker` at the top of ``FriendListView``; the raw value doubles
/// as the visible segment title.
private enum FriendListFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case friends = "Friends"
    case blocked = "Blocked"
    var id: String { rawValue }
}

/// The "Friends & Blocks" management screen: every trusted proximity peer, searchable and
/// filterable, with block/unblock, remove, report, and heart-sending per peer.
///
/// Pushed from the Friends tab header. Rows expand in place into a detail card (fingerprint,
/// accepted/seen dates, mode, status timestamps) whose actions mirror the swipe actions; all
/// mutations go through ``FernletStore`` (`blockProximityPeer`, `revokeTrustedProximityPeer`,
/// `reportProximityPeer`, …). The screen also owns the user's mesh display name — committed only
/// on Return / focus loss / disappear, never per keystroke, because the name rides the discovery
/// broadcast and a half-typed value must never persist — and the "Send good vibes" heart flow:
/// live presence sends via `PresenceManager`, plus the consent-gated away-hearts dead-drop path
/// (`HeartDropService.queueHeart`) with nothing-silent status copy from ``AwayHeartsCopy``.
struct FriendListView: View {
    var store: FernletStore
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int

    @State private var searchText = ""
    @State private var displayName = ""
    @State private var filter: FriendListFilter = .all
    @State private var selected: ProximityTrustedPeerRecord?
    @State private var peerToBlock: ProximityTrustedPeerRecord?
    @State private var blockConfirmShown = false
    /// The friend a "Remove …?" confirmation is about. Removing revokes trust and forgets their
    /// cached state — you have to meet in person again — so it asks first, exactly as Block does.
    @State private var peerToRemove: ProximityTrustedPeerRecord?
    @State private var peerToReport: ProximityTrustedPeerRecord?
    // Away hearts (bitchat adoptions Increment 3): the first-use consent target + the local
    // status line for queue outcomes (separate from the live-send heartSendState pipeline).
    @State private var awayConsentPeer: ProximityTrustedPeerRecord?
    @State private var awayStatus: String?
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        List {
            displayNameRow
            searchRow
            filterPicker
            // Compute the sorted/filtered list ONCE per render. It was previously re-derived on
            // every access — `.isEmpty` here, the `ForEach`, and `filteredPeers.last?.id` inside
            // each row — re-sorting and re-filtering the whole peer list O(n) times per render.
            let peers = filteredPeers
            peerList(peers, lastPeerID: peers.last?.id)
            safetyFooterRow
        }
        .listStyle(.plain)
        .fernletTabBarCompaction($isTabBarCompact, resetToken: $tabResetToken)
        .scrollContentBackground(.hidden)
        .background(Color.parchment)
        .navigationTitle("Friends & Blocks")
        // Inline, matching the two sibling pushes off the same header (Activities, Safety &
        // reporting). A large title here sat flush against x=0 while every field below is inset 20pt.
        .navigationBarTitleDisplayMode(.inline)
        // An `alert`, not a `confirmationDialog`: on iOS 26 the dialog renders as a popover that
        // suppresses the `.cancel`-role button, leaving a list of red reasons and no way out.
        .alert(
            "Report this person?",
            isPresented: $peerToReport.isPresent(),
            presenting: peerToReport
        ) { peer in
            reportDialogActions(peer)
        } message: { peer in
            Text("Reporting \(peer.displayName) blocks them and flags their shared content on your device.")
        }
        .onAppear {
            displayName = store.settings.proximityDisplayName
            store.recomputeCloseFriendsIfNeeded()
        }
        // Catch a name edited right up to a navigation/tab change that never resigned focus.
        .onDisappear { commitDisplayName() }
        .alert("Block peer?", isPresented: $blockConfirmShown) {
            blockAlertActions
        } message: {
            blockAlertMessage
        }
        .alert(
            peerToRemove.map { "Remove \($0.displayName)?" } ?? "Remove friend?",
            isPresented: $peerToRemove.isPresent(),
            presenting: peerToRemove
        ) { peer in
            removeAlertActions(peer)
        } message: { _ in
            Text("You'll need to meet in person to add them again.")
        }
    }

    /// The mesh display-name field — what nearby peers see, committed only when the edit finishes.
    private var displayNameRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            displayNameField
            Text("Friends nearby see this name.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .padding(.horizontal, 4)
        }
        .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 0, trailing: 20))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var displayNameField: some View {
        HStack(spacing: 10) {
            Text("You appear as")
                .font(.fernlet(.label))
                .foregroundStyle(Color.slate)
            Spacer()
            // The placeholder is the name that is ACTUALLY broadcast when the field is empty (the
            // device name), not an invented "Your name" — otherwise friends see "iPhone" and nothing
            // here ever said so.
            TextField(store.resolvedProximityDisplayName, text: $displayName)
                .font(.fernlet(.body))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Color.bark)
                .submitLabel(.done)
                .focused($nameFieldFocused)
                // Commit only when the user finishes — on Return, and when focus leaves the
                // field — never per keystroke. The old `.onChange` wrote the name to the synced
                // blob on every character AND fired on the `.onAppear` seed, and it would
                // persist a half-typed or empty name (which is also what a mesh peer sees, since
                // the display name rides the discovery broadcast) if the user navigated away
                // mid-edit. `commitDisplayName` rejects an empty value and restores the stored one.
                .onSubmit { commitDisplayName() }
                .onChange(of: nameFieldFocused) { _, focused in
                    if !focused { commitDisplayName() }
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }

    /// The name/fingerprint search field.
    private var searchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.slate)
            TextField("Search by name or fingerprint", text: $searchText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// All / Friends / Blocked segment control.
    private var filterPicker: some View {
        HubSectionPicker(
            sections: FriendListFilter.allCases,
            selection: $filter
        ) { $0.rawValue }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// The peer rows themselves (or the empty state), each expandable in place and swipeable.
    @ViewBuilder
    private func peerList(_ peers: [ProximityTrustedPeerRecord], lastPeerID: UUID?) -> some View {
        if peers.isEmpty {
            EmptyState(text: emptyStateText)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            ForEach(peers) { peer in
                peerCell(peer, isLast: peer.id == lastPeerID)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.parchment)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        swipeActions(for: peer)
                    }
            }
        }
    }

    /// One peer row: the summary line, the expanded detail card when selected, and the divider.
    private func peerCell(_ peer: ProximityTrustedPeerRecord, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            peerRow(peer)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        selected = selected?.id == peer.id ? nil : peer
                    }
                }

            if let expanded = selected, expanded.id == peer.id {
                peerDetailCard(peer)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !isLast {
                Divider()
                    .overlay(Color.bark.opacity(0.07))
                    .padding(.horizontal, 20)
            }
        }
    }

    /// The always-available route to the safety explainer — blocking happens on this screen, so the
    /// page that explains reporting (and what happens next) belongs at the end of it, not only in
    /// Settings › Privacy.
    private var safetyFooterRow: some View {
        NavigationLink {
            SafetyReportingView()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "lifepreserver")
                    .foregroundStyle(Color.moss)
                Text("Safety & reporting")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
            }
            .frame(minHeight: 44)
        }
        .accessibilityIdentifier("friends.safetyReporting")
        .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 28, trailing: 20))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// Remove / block-or-unblock / report, the swipe mirror of the detail card's actions.
    @ViewBuilder
    private func swipeActions(for peer: ProximityTrustedPeerRecord) -> some View {
        Button(role: .destructive) {
            peerToRemove = peer
        } label: {
            Label("Remove", systemImage: "trash")
        }

        if peer.blockedAt == nil {
            Button {
                peerToBlock = peer
                blockConfirmShown = true
            } label: {
                Label("Block", systemImage: "hand.raised")
            }
            .tint(Color.terracotta)
        } else {
            Button {
                store.unblockProximityPeer(signingPublicKey: peer.signingPublicKey)
            } label: {
                Label("Unblock", systemImage: "hand.raised.slash")
            }
            .tint(Color.moss)
        }

        if peer.reportedAt == nil {
            Button {
                peerToReport = peer
            } label: {
                Label("Report", systemImage: "flag")
            }
            .tint(Color.goldenrod)
        }
    }

    /// One destructive button per report reason, plus Cancel.
    @ViewBuilder
    private func reportDialogActions(_ peer: ProximityTrustedPeerRecord) -> some View {
        ForEach(ReportReason.allCases) { reason in
            Button(reason.label, role: .destructive) {
                store.reportProximityPeer(signingPublicKey: peer.signingPublicKey, reason: reason)
                if selected?.id == peer.id { selected = nil }
                peerToReport = nil
            }
        }
        Button("Cancel", role: .cancel) { peerToReport = nil }
    }

    /// Confirm/cancel for the remove alert. Removing revokes trust and forgets the friend's cached
    /// state, so it asks first — the most destructive of the three row actions used to be the only
    /// one that fired silently.
    @ViewBuilder
    private func removeAlertActions(_ peer: ProximityTrustedPeerRecord) -> some View {
        Button("Remove", role: .destructive) {
            store.revokeTrustedProximityPeer(signingPublicKey: peer.signingPublicKey)
            if selected?.id == peer.id { selected = nil }
            peerToRemove = nil
        }
        Button("Cancel", role: .cancel) { peerToRemove = nil }
    }

    /// Confirm/cancel for the block alert.
    @ViewBuilder
    private var blockAlertActions: some View {
        Button("Block", role: .destructive) {
            if let peer = peerToBlock {
                store.blockProximityPeer(signingPublicKey: peer.signingPublicKey)
                if selected?.id == peer.id { selected = nil }
            }
            peerToBlock = nil
        }
        Button("Cancel", role: .cancel) {
            peerToBlock = nil
        }
    }

    /// The block alert's explanatory line (empty when no peer is pending).
    @ViewBuilder
    private var blockAlertMessage: some View {
        if let peer = peerToBlock {
            Text("Blocking \(peer.displayName) will hide their content from you and yours from them.")
        }
    }

    // MARK: - Peer row

    private func peerRow(_ peer: ProximityTrustedPeerRecord) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(peer.displayName)
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)

                // The raw hex fingerprint lives in the expanded detail card, not on every row: it is
                // a verification tool, not a name, and a wall of hex made the roster read as a
                // security console rather than a list of friends.

                Text("Last seen \(peer.lastSeenAt.relativeFormatted)")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
            }

            Spacer()

            if peer.blockedAt == nil && peer.revokedAt == nil {
                if store.isCloseFriend(fingerprint: peer.fingerprint) {
                    Text("Close")
                        .font(.fernlet(.labelSmall))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(Color.parchment)
                        .background(Color.fern, in: Capsule())
                }
                fuzzyStateChip(for: peer)
            }
            statusBadge(for: peer)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
    }

    /// A friend's fuzzy vibe (thriving/okay/struggling) from the last time you met — never a number.
    /// Shows an "as of …" qualifier once it's more than a couple of days old; nothing at all past 30 days.
    @ViewBuilder
    private func fuzzyStateChip(for peer: ProximityTrustedPeerRecord) -> some View {
        if let cached = store.cachedFriendState(fingerprint: peer.fingerprint) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 5) {
                    Circle().fill(fuzzyColor(cached.fuzzyState)).frame(width: 7, height: 7)
                    Text(cached.fuzzyState.label)
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.bark)
                }
                if Date().timeIntervalSince(cached.capturedAt) > 48 * 3600 {
                    Text("as of \(cached.capturedAt.relativeFormatted)")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                }
            }
        }
    }

    private func fuzzyColor(_ state: FriendFuzzyState) -> Color {
        switch state {
        case .thriving: Color.moss
        case .okay: Color.goldenrod
        case .struggling: Color.terracotta
        }
    }

    @ViewBuilder
    private func statusBadge(for peer: ProximityTrustedPeerRecord) -> some View {
        if peer.blockedAt != nil {
            Text("Blocked")
                .font(.fernlet(.labelSmall))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(Color.terracotta)
                .background(Color.terracotta.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.terracotta.opacity(0.20), lineWidth: 1))
        } else if peer.revokedAt != nil {
            Text("Removed")
                .font(.fernlet(.labelSmall))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(Color.slate)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        } else {
            Text("Friend")
                .font(.fernlet(.labelSmall))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(Color.parchment)
                .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Expanded detail card

    private func peerDetailCard(_ peer: ProximityTrustedPeerRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                fingerprintDetailRow(peer.fingerprint)
                detailRow("Friends since", value: peer.firstAcceptedAt.formatted(date: .abbreviated, time: .omitted))
                detailRow("Last seen", value: peer.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                // "Mode: Uwb/Manual" was transport trivia in a friend's card — how the two phones
                // met changes nothing the user can act on. The Connection Inspector still shows it.
                if let revokedAt = peer.revokedAt {
                    detailRow("Revoked", value: revokedAt.formatted(date: .abbreviated, time: .omitted))
                }
                if let blockedAt = peer.blockedAt {
                    detailRow("Blocked since", value: blockedAt.formatted(date: .abbreviated, time: .omitted))
                }
                if let reportedAt = peer.reportedAt {
                    detailRow("Reported", value: reportedAt.formatted(date: .abbreviated, time: .omitted))
                }
            }

            if peer.blockedAt == nil && peer.revokedAt == nil && store.settings.allowNearbyHearts {
                Divider().overlay(Color.bark.opacity(0.08))
                heartRow(peer)
            }

            Divider().overlay(Color.bark.opacity(0.08))

            // These four ACT on a person, so they take the 44pt action pill rather than the 34pt
            // selection chip, and stack at accessibility text sizes instead of splitting words.
            AdaptiveStack(spacing: 10, horizontalAlignment: .leading) {
                if peer.blockedAt == nil {
                    Button("Block") {
                        peerToBlock = peer
                        blockConfirmShown = true
                    }
                    .buttonStyle(ActionPillButtonStyle(.secondary))
                } else {
                    Button("Unblock") {
                        store.unblockProximityPeer(signingPublicKey: peer.signingPublicKey)
                        if selected?.id == peer.id { selected = nil }
                    }
                    .buttonStyle(ActionPillButtonStyle(.primary))
                }

                Button("Remove") { peerToRemove = peer }
                    .buttonStyle(ActionPillButtonStyle(.destructive))

                if peer.reportedAt == nil {
                    Button("Report") { peerToReport = peer }
                        .buttonStyle(ActionPillButtonStyle(.secondary))
                }
            }
        }
        .padding(16)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.bark.opacity(0.08), lineWidth: 1))
    }

    // MARK: - Send good vibes

    /// In-person hearts, delivered over the presence radio (mesh redesign Phase 4b). The button
    /// lights up only while the friend is recognized nearby by presence and the 5-minute per-friend
    /// cooldown is clear; sending runs a multi-second connect → verify → send pipeline surfaced
    /// below. No counts of sent or received hearts appear anywhere.
    @ViewBuilder
    private func heartRow(_ peer: ProximityTrustedPeerRecord) -> some View {
        // In-person hearts require presence (Group 2). When hearts are on but the presence layer is
        // off, every friend would otherwise read a dead "Not nearby" — surface an actionable
        // enable-presence state instead. Reachability is only meaningful once presence is on.
        // Away delivery is the exception: it needs no radio, so with it on the presence prompt is a
        // dead end (it hides the only Send button that would still work) — the friend is just
        // `.notNearby`, and `sendHeartBlock` renders the dead-drop path.
        let affordance = PresenceManager.heartAffordance(
            heartsEnabled: store.settings.allowNearbyHearts,
            presenceEnabled: store.settings.allowNearbyPresence,
            reachable: store.presenceManager.isReachable(fingerprint: peer.fingerprint),
            awayDeliveryEnabled: store.settings.heartsAwayDelivery)

        VStack(alignment: .leading, spacing: 10) {
            if affordance == .needsPresence {
                needsPresenceHeartBlock()
            } else {
                sendHeartBlock(peer, reachable: affordance == .reachable)
            }
        }
    }

    /// Hearts-on + presence-off: hearts can't function without the presence layer, so offer to
    /// turn it on rather than leaving a perpetually-dead "Not nearby" (Group 2).
    @ViewBuilder
    private func needsPresenceHeartBlock() -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.softTaupe)
                .frame(width: 7, height: 7)
            Text("Nearby Friends is off")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
        }

        Button {
            store.setAllowNearbyPresence(true)
        } label: {
            Text("Turn on Nearby Friends to send hearts")
                .font(.fernlet(.label))
                .foregroundStyle(Color.parchment)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("friends.enablePresence")

        Text("Hearts are sent in person over Nearby Friends — turn it on to see when this friend is close by.")
            .font(.fernlet(.bodySmall))
            .foregroundStyle(Color.slate)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fernletWrappingText()
    }

    @ViewBuilder
    private func sendHeartBlock(_ peer: ProximityTrustedPeerRecord, reachable: Bool) -> some View {
        let onCooldown = !store.heartLedger.canSendHeart(to: peer.fingerprint)
        let sending = heartSendInProgress
        let firstName = PresenceManager.firstName(of: peer.displayName)
        let awayEnabled = store.settings.heartsAwayDelivery
        // "Queued but not yet at the drop-off" — an uploaded heart drops out of this count, so it
        // reads as "still waiting on us", not "still undelivered".
        let pendingDrops = reachable ? 0 : store.heartDropService.pendingCount(for: peer)
        // Nothing-silent: whenever delivery is not actually happening, the row must say so instead
        // of repeating the "delivered while you're apart" promise.
        let awayProblem = reachable ? nil : awayDeliveryProblemText

        presenceLine(reachable: reachable)

        sendHeartButton(
            peer: peer,
            reachable: reachable,
            awayEnabled: awayEnabled,
            onCooldown: onCooldown,
            sending: sending,
            firstName: firstName
        )

        heartHelperText(
            onCooldown: onCooldown,
            reachable: reachable,
            awayEnabled: awayEnabled,
            awayProblem: awayProblem,
            pendingDrops: pendingDrops,
            firstName: firstName
        )

        heartStatusLines
    }

    /// The presence line: a soft moss dot means you're actually together (good-vibes 10c);
    /// otherwise a muted taupe dot — warmth is a thing you do side by side.
    private func presenceLine(reachable: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(reachable ? Color.moss : Color.softTaupe)
                .frame(width: 7, height: 7)
            Text(reachable ? "Nearby now" : "Not nearby")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(reachable ? Color.moss : Color.slate)
        }
    }

    /// The Send button and the first-away-send consent alert it raises.
    private func sendHeartButton(
        peer: ProximityTrustedPeerRecord,
        reachable: Bool,
        awayEnabled: Bool,
        onCooldown: Bool,
        sending: Bool,
        firstName: String
    ) -> some View {
        Button {
            awayStatus = nil
            if reachable {
                store.presenceManager.sendHeart(to: peer)
            } else if awayEnabled {
                recordAwayOutcome(store.heartDropService.queueHeart(to: peer), firstName: firstName)
            } else {
                // First away-send: explicit consent before the one proximity feature that
                // touches the network does anything (nothing-silent).
                awayConsentPeer = peer
            }
        } label: {
            SendGoodVibesLabel(state: SendGoodVibesLabel.state(onCooldown: onCooldown, reachable: reachable || awayEnabled, sending: sending))
        }
        .buttonStyle(.plain)
        .disabled(onCooldown || sending)
        .accessibilityIdentifier("friends.sendHeart")
        .alert(
            "Deliver hearts when you're apart?",
            isPresented: $awayConsentPeer.isPresent()
        ) {
            Button("Turn on") {
                if let consented = awayConsentPeer {
                    store.setHeartsAwayDelivery(true)
                    recordAwayOutcome(
                        store.heartDropService.queueHeart(to: consented),
                        firstName: PresenceManager.firstName(of: consented.displayName)
                    )
                }
                awayConsentPeer = nil
            }
            Button("Not now", role: .cancel) { awayConsentPeer = nil }
        } message: {
            Text("When a friend isn't nearby, Fernlet seals the heart end-to-end and leaves it in a shared iCloud drop-off under a rotating tag only that friend's device can recognize — never a name. It's delivered when they next open Fernlet.\n\nThis is separate from iCloud Sync: only hearts go there, never your own data, and it works whether or not you sync Fernlet. It's the only nearby feature that uses the network, and you can turn it off any time in Settings — which also deletes the hearts still waiting there.")
        }
    }

    /// The one line under the button explaining the current state: cooldown, an away-delivery
    /// problem, what is already queued, or the in-person-only default.
    @ViewBuilder
    private func heartHelperText(
        onCooldown: Bool,
        reachable: Bool,
        awayEnabled: Bool,
        awayProblem: String?,
        pendingDrops: Int,
        firstName: String
    ) -> some View {
        if onCooldown {
            // An unloaded ledger also reads as "on cooldown" (fail-closed refuse) — but the
            // cooldown copy would be a lie there, so say what is actually wrong (Track A).
            Text(store.heartLedger.isLoaded
                 ? "You just sent \(firstName) some warmth — hearts settle for a few minutes."
                 : "Fernlet couldn't reach its own notes just now — unlock and reopen to send hearts.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fernletWrappingText()
        } else if !reachable {
            if awayEnabled {
                if let awayProblem {
                    Text(awayProblem)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.goldenrod)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .fernletWrappingText()
                        .accessibilityIdentifier("friends.awayProblem")
                } else {
                    Text(pendingDrops > 0
                         ? (pendingDrops == 1
                            ? "A heart is tucked away for \(firstName) — delivered when they next open Fernlet."
                            : "\(pendingDrops) hearts are tucked away for \(firstName) — delivered when they next open Fernlet.")
                         : "Not together right now — a heart sent now is delivered while you're apart.")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .fernletWrappingText()
                }
            } else {
                Text("Hearts travel in person for now — tap Send to turn on delivery while apart.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fernletWrappingText()
            }
        }
    }

    /// The two transient status lines: the away-queue outcome and the live-send pipeline's state.
    @ViewBuilder
    private var heartStatusLines: some View {
        if let awayStatus {
            Text(awayStatus)
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.moss)
                .frame(maxWidth: .infinity, alignment: .center)
                .fernletWrappingText()
        }

        if let status = heartStatusText {
            Text(status)
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.moss)
                .frame(maxWidth: .infinity, alignment: .center)
                .fernletWrappingText()
        }
    }

    /// The one honest sentence for whatever is stopping away hearts right now, or nil when delivery
    /// is healthy. `queueHeart` returns `.queued` even when the drop-off is unreachable — the heart
    /// really is saved — so this is what keeps the row from promising an arrival it can't make.
    private var awayDeliveryProblemText: String? {
        guard store.settings.heartsAwayDelivery else { return nil }
        return AwayHeartsCopy.friendRowLine(for: store.heartDropService.deliveryProblem)
    }

    private func recordAwayOutcome(_ outcome: HeartDropService.QueueOutcome, firstName: String) {
        switch outcome {
        case .queued:
            // The heart IS saved, so say so — but never alongside a delivery promise the service is
            // currently unable to keep.
            if let problem = awayDeliveryProblemText {
                awayStatus = "\(firstName)'s heart is tucked away and safe. \(problem)"
            } else {
                awayStatus = "Your heart is tucked away for \(firstName) — it'll be delivered while you're apart."
            }
        case .rateLimited:
            awayStatus = "You just sent \(firstName) some warmth — hearts settle for a few minutes."
        case .dailyLimitReached:
            // Distinct from `.rateLimited` on purpose: the wait is until tomorrow, and the
            // five-minute copy would be a lie the user would sit through and disbelieve.
            awayStatus = "\(firstName) has had all of today's hearts from you — send another tomorrow."
        case .backlogFull:
            awayStatus = "A few hearts are already waiting for \(firstName) — they'll arrive first."
        case .storageUnavailable:
            // Track A nothing-silent: the heart was REFUSED (not saved), so no "tucked away".
            awayStatus = "Fernlet couldn't reach its own notes just now — unlock and reopen to send hearts."
        case .disabled, .failed:
            awayStatus = "Couldn't tuck that heart away just now."
        }
    }

    private var heartSendInProgress: Bool {
        switch store.presenceManager.heartSendState {
        case .connecting, .verifying: return true
        default: return false
        }
    }

    private var heartStatusText: String? {
        switch store.presenceManager.heartSendState {
        case .idle:
            nil
        case .connecting(let recipientName):
            "Connecting to \(recipientName)..."
        case .verifying(let recipientName):
            "Saying hello to \(recipientName)..."
        case .sent(let recipientName):
            "Sent \(recipientName) some good vibes."
        case .failed(let message):
            message
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
            Spacer(minLength: 12)
            Text(value)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
    }

    /// The fingerprint's own row — the one place the raw hex belongs, rendered through the shared
    /// ``FingerprintText`` so every surface that shows one uses the same treatment.
    private func fingerprintDetailRow(_ fingerprint: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Fingerprint")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
            Spacer(minLength: 12)
            FingerprintText(fingerprint, color: Color.bark, lineLimit: 2)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Display name

    /// Persists the edited mesh display name, but only if it is non-empty after trimming — an empty
    /// field falls back to the stored value rather than clearing the user's name (which also rides
    /// the mesh discovery broadcast). Idempotent, so committing an unchanged name is a cheap no-op.
    private func commitDisplayName() {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            displayName = store.settings.proximityDisplayName
            return
        }
        guard trimmed != store.settings.proximityDisplayName else { return }
        store.setProximityDisplayName(trimmed)
    }

    // MARK: - Filtering

    private var filteredPeers: [ProximityTrustedPeerRecord] {
        var peers = store.trustedProximityPeers.sorted { $0.lastSeenAt > $1.lastSeenAt }
        switch filter {
        case .all: break
        case .friends: peers = peers.filter { $0.blockedAt == nil && $0.revokedAt == nil }
        case .blocked: peers = peers.filter { $0.blockedAt != nil }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            peers = peers.filter {
                $0.displayName.lowercased().contains(query) ||
                $0.fingerprint.lowercased().contains(query)
            }
        }
        return peers
    }

    private var emptyStateText: String {
        // Everyday words, not security-console words: this list is people you've met, not "peers".
        if !searchText.isEmpty { return "No one matches \"\(searchText)\"." }
        switch filter {
        case .all, .friends: return "No friends yet — meet up in person to add one."
        case .blocked: return "No one is blocked."
        }
    }
}

/// The "Send good vibes" affordance label in its presentation states (good-vibes 10c).
///
/// A filled terracotta button when ready, a spinner while the multi-second send pipeline runs, a
/// soft filled "cooldown" state within the 5-minute window, and a muted state when the friend
/// isn't nearby. Presentation only — the enabling/disabling and the send action stay with the
/// caller (``FriendListView``'s heart row; ``DisposableCameraView`` reuses just the
/// ``SendGoodVibesLabel/state(onCooldown:reachable:sending:)`` mapping for its compact form).
struct SendGoodVibesLabel: View {
    /// The four presentation states; derive one with `state(onCooldown:reachable:sending:)` so
    /// every surface ranks sending > cooldown > reachability identically.
    enum SendState { case ready, sending, cooldown, notNearby }

    var state: SendState

    static func state(onCooldown: Bool, reachable: Bool, sending: Bool) -> SendState {
        if sending { return .sending }
        if onCooldown { return .cooldown }
        return reachable ? .ready : .notNearby
    }

    var body: some View {
        HStack(spacing: 9) {
            if state == .sending {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.parchment)
            } else {
                Image(systemName: state == .cooldown ? "checkmark" : "heart.fill")
                    .font(.subheadline.weight(.semibold))
            }
            Text(label)
                .font(.fernlet(.label))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(background, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .shadow(
            color: state == .ready ? Color.terracotta.opacity(0.32) : .clear,
            radius: state == .ready ? 10 : 0,
            y: state == .ready ? 4 : 0
        )
    }

    private var label: String {
        switch state {
        case .ready, .notNearby: "Send good vibes"
        case .sending: "Sending..."
        case .cooldown: "Sent just now"
        }
    }

    private var foreground: Color {
        switch state {
        case .ready, .sending: Color.parchment
        case .cooldown: Color.terracotta.opacity(0.7)
        case .notNearby: Color.bark.opacity(0.35)
        }
    }

    private var background: Color {
        switch state {
        case .ready, .sending: Color.terracotta
        case .cooldown: Color.dustyRose.opacity(0.16)
        case .notNearby: Color.bark.opacity(0.06)
        }
    }
}

private extension Date {
    // A single shared formatter. `RelativeDateTimeFormatter` is expensive to construct, and this
    // ran once per peer row ("Last seen …") plus again in the fuzzy-state chip, on every render —
    // rebuilding a formatter each time. MainActor-isolated because the view reads it on the main
    // actor and `RelativeDateTimeFormatter` is not Sendable.
    @MainActor
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    @MainActor
    var relativeFormatted: String {
        Date.relativeFormatter.localizedString(for: self, relativeTo: Date())
    }
}

/// Copy for "away hearts are not being delivered right now", in ONE place.
///
/// Two surfaces answer the same question — a friend's row ("will this heart reach them?") and the
/// Settings toggle ("I turned this on, is it working?") — and the review round that added
/// `HeartDropService.DeliveryProblem` exists precisely because the app used to promise delivery it
/// wasn't making. Two hand-written mappings would drift into two different explanations of the same
/// condition, and a view's private computed cannot be tested; this can.
enum AwayHeartsCopy {
    /// Friend-scoped: read directly under a heart button, so it speaks about hearts travelling.
    static func friendRowLine(for problem: HeartDropService.DeliveryProblem?) -> String? {
        switch problem {
        case nil:
            return nil
        case .noAccount:
            return "Hearts can't travel while you're apart until this iPhone is signed in to iCloud."
        case .uploadFailing(let since):
            return "Hearts sent since \(dayLabel(since)) haven't reached the drop-off yet — Fernlet keeps trying."
        case .undeliverable(let count):
            return count == 1
                ? "A heart couldn't be delivered before it expired."
                : "\(count) hearts couldn't be delivered before they expired."
        case .storageUnavailable:
            return "Fernlet couldn't reach its own notes just now — unlock and reopen to send hearts."
        case .incomingUnreachable(let since):
            return "Fernlet hasn't been able to check for hearts since \(dayLabel(since)) — yours still send."
        }
    }

    /// Feature-scoped: sits under the toggle, so it speaks about the feature's health.
    static func settingsLine(for problem: HeartDropService.DeliveryProblem?) -> String? {
        switch problem {
        case nil:
            return nil
        case .noAccount:
            return "Not signed in to iCloud — hearts can't be delivered yet."
        case .uploadFailing(let since):
            return "Hearts sent since \(dayLabel(since)) haven't reached the drop-off yet. Fernlet keeps trying."
        case .undeliverable(let count):
            return count == 1
                ? "A heart couldn't be delivered before it expired."
                : "\(count) hearts couldn't be delivered before they expired."
        case .storageUnavailable:
            return "Fernlet couldn't read its saved hearts just now. Unlock and reopen, and it will retry."
        case .incomingUnreachable(let since):
            return "Hearts sent to you since \(dayLabel(since)) haven't been picked up yet. Fernlet keeps trying."
        }
    }

    private static func dayLabel(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
