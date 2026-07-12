import ProximityKit
import SwiftUI
import FernletDomainModel

private enum FriendListFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case friends = "Friends"
    case blocked = "Blocked"
    var id: String { rawValue }
}

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
    @State private var peerToReport: ProximityTrustedPeerRecord?

    var body: some View {
        List {
            HStack(spacing: 10) {
                Text("You appear as")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.slate)
                Spacer()
                TextField("Your name", text: $displayName)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(Color.bark)
                    .submitLabel(.done)
                    .onSubmit { store.setProximityDisplayName(displayName) }
                    .onChange(of: displayName) { store.setProximityDisplayName(displayName) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
            .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 0, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

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

            HubSectionPicker(
                sections: FriendListFilter.allCases,
                selection: $filter
            ) { $0.rawValue }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if filteredPeers.isEmpty {
                EmptyState(text: emptyStateText)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(filteredPeers) { peer in
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

                        if peer.id != filteredPeers.last?.id {
                            Divider()
                                .overlay(Color.bark.opacity(0.07))
                                .padding(.horizontal, 20)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.parchment)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            store.revokeTrustedProximityPeer(signingPublicKey: peer.signingPublicKey)
                            if selected?.id == peer.id { selected = nil }
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

                        Button {
                            peerToReport = peer
                        } label: {
                            Label("Report", systemImage: "flag")
                        }
                        .tint(Color.goldenrod)
                    }
                }
            }
        }
        .listStyle(.plain)
        .fernletTabBarCompaction($isTabBarCompact, resetToken: $tabResetToken)
        .scrollContentBackground(.hidden)
        .background(Color.parchment)
        .navigationTitle("Friends & Blocks")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog(
            "Report this person?",
            isPresented: Binding(get: { peerToReport != nil }, set: { if !$0 { peerToReport = nil } }),
            presenting: peerToReport
        ) { peer in
            ForEach(ReportReason.allCases) { reason in
                Button(reason.label, role: .destructive) {
                    store.reportProximityPeer(signingPublicKey: peer.signingPublicKey, reason: reason)
                    if selected?.id == peer.id { selected = nil }
                    peerToReport = nil
                }
            }
            Button("Cancel", role: .cancel) { peerToReport = nil }
        } message: { peer in
            Text("Reporting \(peer.displayName) blocks them and flags their shared content on your device.")
        }
        .onAppear {
            displayName = store.settings.proximityDisplayName
            store.recomputeCloseFriendsIfNeeded()
        }
        .alert("Block peer?", isPresented: $blockConfirmShown) {
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
        } message: {
            if let peer = peerToBlock {
                Text("Blocking \(peer.displayName) will hide their content from you and yours from them.")
            }
        }
    }

    // MARK: - Peer row

    private func peerRow(_ peer: ProximityTrustedPeerRecord) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(peer.displayName)
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)

                Text(peer.fingerprint)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.slate)
                    .lineLimit(1)
                    .truncationMode(.middle)

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
                detailRow("Fingerprint", value: peer.fingerprint, monospaced: true)
                detailRow("First accepted", value: peer.firstAcceptedAt.formatted(date: .abbreviated, time: .omitted))
                detailRow("Last seen", value: peer.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                detailRow("Mode", value: peer.mode.rawValue.capitalized)
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

            HStack(spacing: 10) {
                if peer.blockedAt == nil {
                    Button("Block") {
                        peerToBlock = peer
                        blockConfirmShown = true
                    }
                    .buttonStyle(ChipButtonStyle(selected: false))
                } else {
                    Button("Unblock") {
                        store.unblockProximityPeer(signingPublicKey: peer.signingPublicKey)
                        if selected?.id == peer.id { selected = nil }
                    }
                    .buttonStyle(ChipButtonStyle(selected: true))
                }

                Button("Remove") {
                    store.revokeTrustedProximityPeer(signingPublicKey: peer.signingPublicKey)
                    if selected?.id == peer.id { selected = nil }
                }
                .buttonStyle(ChipButtonStyle(selected: false))

                if peer.reportedAt == nil {
                    Button("Report") { peerToReport = peer }
                        .buttonStyle(ChipButtonStyle(selected: false))
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
        // Hearts require presence (Group 2). When hearts are on but the presence layer is off,
        // every friend would otherwise read a dead "Not nearby" — surface an actionable
        // enable-presence state instead. Reachability is only meaningful once presence is on.
        let affordance = PresenceManager.heartAffordance(
            heartsEnabled: store.settings.allowNearbyHearts,
            presenceEnabled: store.settings.allowNearbyPresence,
            reachable: store.presenceManager.isReachable(fingerprint: peer.fingerprint))

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

        // Presence line: a soft moss dot means you're actually together (good-vibes 10c);
        // otherwise a muted taupe dot — warmth is a thing you do side by side.
        HStack(spacing: 6) {
            Circle()
                .fill(reachable ? Color.moss : Color.softTaupe)
                .frame(width: 7, height: 7)
            Text(reachable ? "Nearby now" : "Not nearby")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(reachable ? Color.moss : Color.slate)
        }

        Button {
            store.presenceManager.sendHeart(to: peer)
        } label: {
            SendGoodVibesLabel(state: SendGoodVibesLabel.state(onCooldown: onCooldown, reachable: reachable, sending: sending))
        }
        .buttonStyle(.plain)
        .disabled(onCooldown || !reachable || sending)
        .accessibilityIdentifier("friends.sendHeart")

        if onCooldown {
            Text("You just sent \(firstName) some warmth — hearts settle for a few minutes.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fernletWrappingText()
        } else if !reachable {
            Text("Hearts travel in person for now — they can be sent when you're together.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
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

    private func detailRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .subheadline)
                .foregroundStyle(Color.bark)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
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
        if !searchText.isEmpty { return "No peers match \"\(searchText)\"." }
        switch filter {
        case .all: return "No trusted peers yet."
        case .friends: return "No friends yet."
        case .blocked: return "No blocked peers."
        }
    }
}

/// The "Send good vibes" affordance label in its presentation states (good-vibes 10c): a filled
/// terracotta button when ready, a spinner while the multi-second send pipeline runs, a soft
/// filled "cooldown" state within the 5-minute window, and a muted state when the friend isn't
/// nearby. Presentation only — the enabling/disabling and the send action stay with the caller.
struct SendGoodVibesLabel: View {
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
    var relativeFormatted: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
