import FernletConnections
import FernletDomainModel
import FernletProximityUI
import FernletSocial
import FernletUI
import ProximityKit
import SwiftUI

/// Friends nearby: where a session starts, a hangout is joined and a friend is made (World Review Batch 4,
/// `b4-mem-blue-friend`, `b4-mem-blue-join`, `b4-mem-blue-new`, approved 2026-10-24). The Album page is
/// only the album now (`b4-mem-root`), so the rows that lived under its header — "Looking for nearby
/// friends…", each nearby phone with its connect ceremony, the discovery failure and "Change name" —
/// live here, each nearby phone drawn as the approved blue-button card for who they are.
///
/// It is a page of the Album panel's own stack (`FriendsRoute.nearby`), opened from Home's blue button
/// ("Start a session with Sam", or "Friends nearby"). That is deliberate: the discovery radio runs only
/// while the Album tab is in front (`ProximityRunPolicy`), exactly as it did for the Friends tab, so this
/// page adds no new radio behaviour; strangers are never drawn on the map. Starting works as today: tap
/// the phones together (or Connect / the code exchange on phones without ranging), and the session's
/// celebration plays; the Album panel then closes back to Home, where the session button now sits.
///
/// Activities (planned hangouts others can join) are one link down, since they left the Album page.
struct FriendsNearbyPage: View {
    var store: FernletStore

    private var manager: MeshNetworkManager { store.meshNetworkManager }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Bring your phones together to start. Nothing is shared until you both say yes.")
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                people
                    .animation(.easeInOut(duration: 0.3), value: manager.isSearching)
                    .animation(.easeInOut(duration: 0.3), value: manager.slots.count)
                displayNameHint
                NavigationLink(value: FriendsRoute.activities) {
                    FriendsLinkCard(title: Text("Activities"),
                                    detail: Text("A walk, coffee or meal that friends nearby can join"),
                                    sprite: FriendsSprites.flag, spriteScale: 3)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("friends.nearby.activities")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .fernletPageBackground()
        .accessibilityIdentifier("friends.nearby")
    }

    /// The people: in a session, who's here; otherwise what discovery is doing — a failure, a card per
    /// nearby phone, or the looking row.
    @ViewBuilder
    private var people: some View {
        if FriendsUITestHooks.nearbyDemo {
            FriendsNearbyDemoCards()
        } else if manager.isInSession {
            FriendsNearbyNote(sprite: FriendsSprites.people, text: Text(sessionLine))
        } else if manager.isSearching, let discoveryError = manager.discoveryError {
            FriendsDiscoveryFailureCard(message: discoveryError, showsDetail: store.proximityDebugToolsEnabled)
        } else if manager.isSearching, !manager.slots.isEmpty {
            VStack(spacing: 12) {
                ForEach(manager.slots) { slot in personCard(slot) }
            }
        } else {
            // Not `person.2`: the face says who, the line says the radio is listening.
            FriendsNearbyNote(sprite: WorldSprites.face, text: Text("Looking for nearby friends…"))
        }
    }

    /// "You're in a session with Sam and Rae." — first names only, never an identifier.
    private var sessionLine: LocalizedStringKey {
        let names = manager.sessionParticipants.filter { !$0.isLocal }.map {
            PeerNameDisplay.firstName($0.displayName, fingerprint: $0.fingerprint, placeholder: .met, in: .fernlet)
        }
        guard !names.isEmpty else { return "You're in a session. It lives on Home's session button." }
        return "You're in a session with \(FriendsSessionNames.sentence(names)). It lives on Home's session button."
    }

    /// One nearby phone as the card for who they are.
    private func personCard(_ slot: PeerSlot) -> some View {
        NearbyPersonCard(
            slot: slot,
            kind: kind(of: slot),
            showDebugOverride: store.proximityDebugToolsEnabled,
            onForceConnect: { manager.commitManualProximity(slotID: slot.id) },
            // The QR is minted FOR THIS CARD: only a challenge arriving on this slot may answer it,
            // so the manager binds the nonce to slot.id.
            onMakeVerifyQR: { manager.makeLocalVerifyQRURL(slotID: slot.id) },
            onDismissVerifyQR: { manager.clearActiveVerifyQR() },
            // Bound to THIS card, exactly like the QR above: a valid code belonging to a different
            // nearby person is refused, not searched for.
            onScanVerified: { url in manager.beginQRVerification(with: url, slotID: slot.id) }
        )
    }

    /// Who this phone is: a kept friend by first name (blocked and removed people are not friends), in
    /// an open hangout, or someone new.
    private func kind(of slot: PeerSlot) -> FriendsNearbyKind {
        let identity = NearbyPersonCard.identity(in: slot.coordinator.state)
        let friend = identity.flatMap { peer in
            store.trustedProximityPeers.first { $0.fingerprint == peer.fingerprint && $0.blockedAt == nil && $0.revokedAt == nil }
        }
        let name = friend.map { PeerNameDisplay.firstName($0.displayName, fingerprint: $0.fingerprint, placeholder: .met, in: .fernlet) }
        return FriendsNearbyKind.classify(friendName: name, identified: identity != nil,
                                          discoveryInfo: slot.peer.discoveryInfo)
    }

    /// "You appear as iPhone · Change" while no name is set: nearby people see this device's name, which
    /// rides the discovery broadcast, so it is said where the connecting happens, and links to the field.
    @ViewBuilder
    private var displayNameHint: some View {
        if store.settings.proximityDisplayName.trimmingCharacters(in: .whitespaces).isEmpty {
            NavigationLink(value: FriendsRoute.friendList) {
                FriendsSlimRow {
                    Text("You appear as \(store.resolvedProximityDisplayName)")
                        .font(FernletFramedFont.body)
                        .foregroundStyle(WorldPalette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                } trailing: {
                    Text("Change")
                        .font(FernletFramedFont.buttonSmall)
                        .foregroundStyle(WorldPalette.mossInk)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("friends.changeDisplayName")
            .accessibilityLabel("You appear as \(store.resolvedProximityDisplayName). Change the name friends see.")
            // Voice Control: the row's drawn action word, not the two-sentence label.
            .accessibilityInputLabels([Text("Change"), Text("Change name")])
        }
    }
}

/// One slim line on Friends nearby: a small pixel sprite and the sentence (looking for nearby friends,
/// or the session you're in).
struct FriendsNearbyNote: View {
    let sprite: WorldSprite
    let text: Text

    var body: some View {
        FriendsSlimRow {
            WorldSpriteView(sprite: sprite, scale: 2)
            text
                .font(FernletFramedFont.notice)
                .foregroundStyle(WorldPalette.dim)
                .fixedSize(horizontal: false, vertical: true)
        } trailing: {
            EmptyView()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shown in place of the looking line when the radios failed to start.
///
/// The transport detects this (`NetworkMeshSession`'s `onTransportError`) and routes it to
/// `manager.discoveryError`. A discovery failure happens before any session, so without this card the
/// message was set and never seen. On a device the likely cause is a declined Local Network prompt, so
/// it leads with that; the transport's own words are developer text, shown only with the proximity
/// debug tools on.
struct FriendsDiscoveryFailureCard: View {
    let message: String
    let showsDetail: Bool

    var body: some View {
        FriendsNoticeCard(tone: .warn, symbolName: "wifi.exclamationmark") {
            Text("Can't look for nearby friends")
                .font(FernletFramedFont.rowTitleBold)
                .foregroundStyle(WorldPalette.bark)
            Text("Fernlet needs Local Network access to find friends in person. Check Settings › Fernlet › Local Network, then come back to this screen.")
                .font(FernletFramedFont.note)
                .foregroundStyle(WorldPalette.dim)
                .fixedSize(horizontal: false, vertical: true)
            // Frozen English that can name a tunnel, an error and its identifiers (2026-09-29).
            if showsDetail {
                Text(verbatim: message)
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(WorldPalette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("friends.discoveryFailure")
        .accessibilityElement(children: .combine)
    }
}

/// DEBUG screenshots only (`FERNLET_UI_TEST_NEARBY_DEMO`; the hook is false in Release): Friends
/// nearby's three cards over stand-in people, as a phone without ranging draws them — Sam nearby, Sam in
/// a picnic with one other, and someone new — since a simulator has no nearby phones. Display only.
struct FriendsNearbyDemoCards: View {
    var body: some View {
        let someone = PeerNameDisplay.text(for: .nearby)
        let confirm = String(localized: "friends.nearby.tapToConfirm", defaultValue: "Tap to confirm connection",
                             comment: "A nearby-friend row's status when a tap on this phone completes the connection")
        VStack(spacing: 12) {
            ForEach(Self.kinds.indices, id: \.self) { index in
                let kind = Self.kinds[index]
                NearbyPersonCardChrome(kind: kind, someoneNearby: someone) {
                    NearbyPersonChoice(kind: kind, someoneNearby: someone, stateLabel: confirm)
                } extra: {
                    (kind == .newPerson ? Text("Connect") : Text("Verify"))
                        .frame(minWidth: 88)
                        .modifier(FriendsNearbyDemoPill())
                }
            }
        }
    }

    /// The three people.
    private static let kinds: [FriendsNearbyKind] = [
        .friend(name: "Sam"),
        .hangout(friend: "Sam", hangoutName: "Picnic", others: 1),
        .newPerson
    ]
}

/// The demo's secondary button face: the framed small pill, drawn without a button (nothing to do).
struct FriendsNearbyDemoPill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(FernletFramedFont.buttonSmall)
            .foregroundStyle(WorldPalette.bark)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(WorldPalette.paperLight, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldPalette.ink, lineWidth: 2))
    }
}
