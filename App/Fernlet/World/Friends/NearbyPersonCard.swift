import FernletConnections
import FernletUI
import ProximityKit
import SwiftUI

/// One nearby phone on Friends nearby, drawn as the approved blue-button card for who they are
/// (`b4-mem-blue-friend`, `-blue-join`): the heading ("Sam is nearby"), a line when there is one ("Sam is
/// in a hangout with 1 other person."), and the teal choice ("Start a hangout with Sam", "Join Sam's
/// hangout · Picnic · Sam says yes before you're in") with what the phones are doing under it. The "Make a
/// friend" card (`-blue-new`) is retired (World Friends spec §1.1): someone new is met by tapping phones
/// on Home, so a phone that isn't a friend's reads only as "Someone nearby".
///
/// The ceremony is today's nearby row's, moved here with it (it lived in `ConnectView` as
/// `NearbySlotRow`): while ranging, the live distance and "Tap phones together to connect" (the commit is
/// the phones meeting); on phones without ranging, the choice itself commits (Connect), with the code
/// exchange (show my code / scan theirs, bound to THIS phone's slot) as a smaller button under it. Joining
/// someone's hangout sends the join request their hangout answers (`b3-join-request`). The failed-scan
/// alert is raised from the scan sheet's `onDismiss`:
/// presenting it from the scanner callback landed in the same update that tore the sheet down, and
/// SwiftUI silently dropped it.
struct NearbyPersonCard: View {
    let slot: PeerSlot
    let kind: FriendsNearbyKind
    let showDebugOverride: Bool
    let onForceConnect: () -> Void
    var onMakeVerifyQR: () -> URL? = { nil }
    /// Fires whenever the code sheet goes away (Done, swipe-down, or the sheet dismissing itself on
    /// backgrounding), so the manager stops honoring challenges for the shown code.
    var onDismissVerifyQR: () -> Void = {}
    var onScanVerified: (URL) -> Bool = { _ in false }

    /// B19: one `tick` as the phones come inside the commit distance, re-armed only past 30 cm
    /// (``ProximityApproachCue``). The "Close enough — hold still…" line is its visual twin.
    @State private var approachCue = ProximityApproachCue()
    @State private var verifyQRURL: URL?
    @State private var showVerifyScanner = false
    @State private var verifyMissed = false
    /// Set by the scanner callback, turned into `verifyMissed` only in the scan sheet's `onDismiss`.
    @State private var pendingScanFailed = false
    /// Set by the scanner callback when the code matched, so the "friend's here" cue plays as the
    /// scanner goes away — a beat after the scanner's own "got it", never stacked on it (A10).
    @State private var pendingScanMatched = false

    var body: some View {
        NearbyPersonCardChrome(kind: kind, someoneNearby: someoneNearby) {
            choice
        } extra: {
            secondaryControls
        }
        .onChange(of: approachMeters) { _, meters in
            if let cue = approachCue.observe(meters) { FernletFeedback.system.play(cue) }
        }
        .sheet(isPresented: $verifyQRURL.isPresent(), onDismiss: onDismissVerifyQR) {
            VerifyQRDisplaySheet(url: verifyQRURL)
        }
        .sheet(isPresented: $showVerifyScanner, onDismiss: verifyScannerDismissed) {
            VerifyQRScanSheet { url in
                let matched = onScanVerified(url)
                pendingScanFailed = !matched
                pendingScanMatched = matched
            }
        }
        .alert("That code didn't match", isPresented: $verifyMissed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Ask your friend to show their code again — codes expire after a few minutes — and make sure you're scanning the person shown in this row.")
        }
    }

    /// "Someone nearby" — the placeholder while the phones haven't said who they are.
    private var someoneNearby: String { PeerNameDisplay.text(for: .nearby) }

    // MARK: The choice

    /// The teal choice. On phones without ranging it acts: Connect. While ranging it is a card to read;
    /// the phones meeting is the act.
    @ViewBuilder
    private var choice: some View {
        if case .awaitingManualCommit = slot.coordinator.state {
            Button(action: onForceConnect) { choiceFace }
                .buttonStyle(.plain)
                .accessibilityIdentifier("friends.manualCommit.\(slot.id)")
        } else {
            choiceFace
        }
    }

    /// The choice as drawn, with what the phones are doing now.
    private var choiceFace: some View {
        NearbyPersonChoice(kind: kind, someoneNearby: someoneNearby, stateLabel: stateLabel,
                           connected: isConnected, distance: distanceTag)
    }

    /// Whether the phones are connected (the tick in the choice's tile).
    private var isConnected: Bool {
        switch slot.coordinator.state {
        case .connected, .transferring: return true
        default: return false
        }
    }

    /// While ranging: the live distance in whole centimetres (none while the debug tools' Force shows).
    private var distanceTag: Text? {
        guard case .awaitingProximityCommit = slot.coordinator.state, !showDebugOverride, let d = distanceMeters else { return nil }
        return Text("\(Self.wholeCentimeters(d)) cm")
    }

    // MARK: The other ceremony

    /// Under the choice, on phones without ranging: the code exchange (proof the person holds the key; a
    /// successful round commits both sides). The debug tools' Force while ranging.
    @ViewBuilder
    private var secondaryControls: some View {
        switch slot.coordinator.state {
        case .awaitingProximityCommit where showDebugOverride:
            Button("Force", action: onForceConnect)
                .buttonStyle(ChipButtonStyle(selected: true))
                .accessibilityIdentifier("friends.forceConnect.\(slot.id)")
        case .awaitingManualCommit:
            Menu { codeExchangeButtons } label: { Text("Verify") }
                .menuStyle(.button)
                .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
                .accessibilityIdentifier("friends.verifyQR.menu.\(slot.id)")
        default:
            EmptyView()
        }
    }

    /// Show my code / Scan their code.
    @ViewBuilder
    private var codeExchangeButtons: some View {
        Button {
            verifyQRURL = onMakeVerifyQR()
        } label: {
            Label("Show my code", systemImage: "qrcode")
        }
        Button {
            showVerifyScanner = true
        } label: {
            Label("Scan their code", systemImage: "qrcode.viewfinder")
        }
    }

    /// The scanner has gone away. Raise the alert only now, and give each result its own cue (A10): the
    /// error beside "That code didn't match", or the friend cue for a code that matched. A Cancel sets
    /// neither, so it stays silent.
    private func verifyScannerDismissed() {
        if pendingScanFailed {
            pendingScanFailed = false
            verifyMissed = true
            FernletFeedback.system.play(.failed)
        } else if pendingScanMatched {
            pendingScanMatched = false
            FernletFeedback.system.play(.friendHere)
        }
    }
}

extension NearbyPersonCard {
    // MARK: What the phones are doing

    /// The handshake identity once the phones have said who they are; nil before.
    static func identity(in state: ProximityCoordinator.State) -> ProximityCoordinator.PeerIdentity? {
        switch state {
        case .awaitingProximityCommit(let peer), .awaitingManualCommit(let peer),
             .awaitingUserConfirmation(let peer), .connected(let peer), .transferring(let peer, _):
            return peer
        default:
            return nil
        }
    }

    /// The distance the approach cue reads: the live reading while the phones come together, and
    /// nothing in any other state, so a connected pair that touches again never ticks.
    private var approachMeters: Double? {
        guard case .awaitingProximityCommit = slot.coordinator.state else { return nil }
        return distanceMeters
    }

    private var distanceMeters: Double? {
        if case .meters(let d, _) = slot.coordinator.lastKnownDistance { return d }
        return nil
    }

    /// The live line under the choice (today's nearby row's status, the same keys).
    private var stateLabel: String {
        switch slot.coordinator.state {
        case .awaitingIdentityIntroduction:
            return String(localized: "friends.nearby.exchangingIdentity", defaultValue: "Exchanging identity…",
                          comment: "A nearby-friend row's status while the two phones confirm who each other is")
        case .awaitingProximityCommit:
            return proximityLabel
        case .awaitingManualCommit:
            return String(localized: "friends.nearby.tapToConfirm", defaultValue: "Tap to confirm connection",
                          comment: "A nearby-friend row's status when a tap on this phone completes the connection")
        case .connected, .transferring:
            return String(localized: "friends.nearby.connected", defaultValue: "Connected",
                          comment: "A nearby-friend row's status once the two phones are connected")
        default:
            return String(localized: "friends.nearby.connecting", defaultValue: "Connecting…",
                          comment: "A nearby-friend row's status while the connection is being set up")
        }
    }

    /// While ranging: hold still, move closer, or tap phones together.
    private var proximityLabel: String {
        if let d = distanceMeters, ProximityApproachCue.isWithinCommitDistance(d) {
            return String(localized: "friends.nearby.holdStill", defaultValue: "Close enough — hold still…",
                          comment: "A nearby-friend row's status once the two phones are within the 15 cm connect distance, while the connection settles (under a second). Pairs with a light haptic tick.")
        }
        if let d = distanceMeters {
            let centimeters = Self.wholeCentimeters(d)
            return String(localized: "friends.nearby.moveCloser", defaultValue: "Move closer — \(centimeters) cm away",
                          comment: "A nearby-friend row's status while the phones are too far apart to connect. %lld is the distance in centimetres.")
        }
        return String(localized: "friends.nearby.tapPhones", defaultValue: "Tap phones together to connect",
                      comment: "A nearby-friend row's status before the phones are close: bring them together to connect")
    }

    /// A ranging distance in whole centimetres, rounded exactly as `String(format: "%.0f")` rounds (to
    /// nearest, ties to even), so the drawn number is the one the row always showed.
    static func wholeCentimeters(_ meters: Double) -> Int {
        Int((meters * 100).rounded(.toNearestOrEven))
    }
}

/// The paper card around one nearby person (the quick start's `.qs` card): the heading ("Sam is
/// nearby"), the line under it when there is one, the choice, and anything under the choice.
struct NearbyPersonCardChrome<Choice: View, Extra: View>: View {
    let kind: FriendsNearbyKind
    let someoneNearby: String
    @ViewBuilder let choice: Choice
    @ViewBuilder let extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(verbatim: FriendsNearbyCopy.heading(kind, someoneNearby: someoneNearby))
                .font(WorldQuickStartType.heading)
                .foregroundStyle(WorldPalette.bark)
                .fernletWrappingText()
                .accessibilityAddTraits(.isHeader)
            if let note = FriendsNearbyCopy.note(kind) {
                Text(verbatim: note)
                    .font(WorldQuickStartType.note)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
            }
            choice
            extra
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorldPalette.paper, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(WorldPalette.ink, lineWidth: 3))
        .background {
            RoundedRectangle(cornerRadius: 13).fill(WorldPalette.ink.opacity(0.22)).offset(y: 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("friends.nearby.person")
    }
}

/// The teal choice on a nearby person's card (the quick start's leading choice): the icon in its tile
/// (two people, a tick once connected), the name, the approved line, what the phones are doing, and the
/// live distance while ranging.
struct NearbyPersonChoice: View {
    let kind: FriendsNearbyKind
    let someoneNearby: String
    let stateLabel: String
    var connected = false
    var distance: Text?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility sizes the tile sits above the words, so the words keep the card's width.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 11))
        layout {
            WorldSpriteView(sprite: sprite, scale: 3)
                .frame(width: 44, height: 44)
                .background(WorldQuickStartPalette.tileOnTeal, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: FriendsNearbyCopy.title(kind, someoneNearby: someoneNearby))
                    .font(WorldQuickStartType.optionTitle)
                if let detail = FriendsNearbyCopy.detail(kind) {
                    Text(verbatim: detail).font(WorldQuickStartType.optionDetail)
                }
                Text(verbatim: stateLabel)
                    .font(WorldQuickStartType.optionDetail.weight(.semibold))
            }
            .foregroundStyle(WorldQuickStartPalette.onTeal)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let distance {
                distance
                    .font(FernletFramedFont.button)
                    .foregroundStyle(WorldQuickStartPalette.onTeal)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11))
        .frame(minHeight: 54)
        .background(WorldQuickStartPalette.teal, in: RoundedRectangle(cornerRadius: 11))
        .overlay(alignment: .bottom) { WorldQuickStartPalette.tealLow.frame(height: 4).padding(.horizontal, 3).padding(.bottom, 3) }
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(WorldPalette.ink, lineWidth: 3))
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .combine)
    }

    private var sprite: WorldSprite {
        connected ? WorldSprites.check : WorldSprites.pair
    }
}
