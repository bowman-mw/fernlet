import SwiftUI

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

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Text("You appear as")
                            .font(.subheadline)
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
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

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
                    .padding(.horizontal, 20)
                    .padding(.top, 0)
                    .padding(.bottom, 8)

                    HubSectionPicker(
                        sections: FriendListFilter.allCases,
                        selection: $filter
                    ) { $0.rawValue }

                    if filteredPeers.isEmpty {
                        EmptyState(text: emptyStateText)
                            .padding(.horizontal, 20)
                            .padding(.top, 24)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredPeers) { peer in
                                VStack(alignment: .leading, spacing: 0) {
                                    peerRow(peer)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                                selected = selected?.id == peer.id ? nil : peer
                                            }
                                        }
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
                            }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 20)
                    }
                }
            }
            .fernletTabBarCompaction($isTabBarCompact, resetToken: $tabResetToken)
            .scrollContentBackground(.hidden)
            .background(Color.parchment)
            .navigationTitle("Friends & Blocks")
            .navigationBarTitleDisplayMode(.large)
            .onAppear { displayName = store.settings.proximityDisplayName }
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
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.bark)

                Text(peer.fingerprint)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.slate)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("Last seen \(peer.lastSeenAt.relativeFormatted)")
                    .font(.caption)
                    .foregroundStyle(Color.slate)
            }

            Spacer()

            statusBadge(for: peer)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func statusBadge(for peer: ProximityTrustedPeerRecord) -> some View {
        if peer.blockedAt != nil {
            Text("Blocked")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(Color.terracotta)
                .background(Color.terracotta.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.terracotta.opacity(0.20), lineWidth: 1))
        } else if peer.revokedAt != nil {
            Text("Removed")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(Color.slate)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        } else {
            Text("Friend")
                .font(.caption.weight(.semibold))
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
            }
        }
        .padding(16)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.bark.opacity(0.08), lineWidth: 1))
    }

    private func detailRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption.weight(.semibold))
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

private extension Date {
    var relativeFormatted: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
