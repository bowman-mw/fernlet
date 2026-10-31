import SwiftUI
import FernletUI
import FernletDomainModel
import ProximityKit
import FernletConnections

// Phase 2 friend minting (Docs/Proximity-Mesh-Redesign-2026-07-10.md): the per-participant
// "keep as a friend?" affordance shown at session end. One-sided and local-only — keeping mints
// a trust-vault record on THIS device only; skipping does nothing, and the peer is never
// notified either way.

/// The keep-as-friend rows. Embedded in FriendPhotoReviewSheet when the session produced photos,
/// or hosted by KeepFriendsPromptSheet when it didn't.
struct KeepFriendsSection: View {
    let candidates: [MeshSessionRosterEntry]
    @Binding var keptFingerprints: Set<String>
    /// Whether the hangout began with the phones tapped together, so each name says "met by tapping
    /// phones" under it (World Friends spec §1.3, `fr-tap-keep`). False shows the name alone, as before.
    var metByTapping = false
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: FernletProximityUICopy.KeepFriends.sectionTitle)
                .font(look == nil ? .fernlet(.headerMedium) : FernletFramedFont.cardTitle)
                .foregroundStyle(look?.text ?? Color.bark)
                .accessibilityAddTraits(.isHeader)

            Text(verbatim: FernletProximityUICopy.KeepFriends.explainer)
                .font(look == nil ? .fernlet(.bodySmall) : FernletFramedFont.body)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()

            VStack(spacing: 8) {
                ForEach(candidates) { candidate in
                    KeepFriendRow(
                        candidate: candidate,
                        isKept: keptFingerprints.contains(candidate.fingerprint),
                        metByTapping: metByTapping,
                        toggle: { toggle(candidate.fingerprint) }
                    )
                }
            }
        }
    }

    /// Flips one person's Keep chip, with the chip's tick under the thumb (report §7, "Keep-as-friends
    /// prompt chips → tick"). The chip turning to Keeping, and the row's moss outline, are the visual.
    private func toggle(_ fingerprint: String) {
        if keptFingerprints.contains(fingerprint) {
            keptFingerprints.remove(fingerprint)
        } else {
            keptFingerprints.insert(fingerprint)
        }
        FernletFeedback.system.play(.tick)
    }
}

/// One keep-as-friend row: the person's name (with "met by tapping phones" under it when the hangout
/// began with a tap) and the Keep/Keeping chip.
///
/// Private child of ``KeepFriendsSection``; the toggle closure flips membership in the shared
/// kept-fingerprints binding. No fingerprint (owner decision 2026-09-29): an identifier string
/// is not a name, and the roster files the fingerprint AS the name when the link dropped before
/// the name arrived, so that case reads "Someone you met" instead.
private struct KeepFriendRow: View {
    let candidate: MeshSessionRosterEntry
    let isKept: Bool
    /// Whether the line "met by tapping phones" sits under the name.
    let metByTapping: Bool
    let toggle: () -> Void
    @Environment(\.fernletFramedLook) private var look

    /// The display name is peer-supplied wire input: ``PeerNameDisplay`` sanitizes it (control,
    /// zero-width and bidi scalars out) and turns an identifier filed as a name into the placeholder.
    private var displayName: String {
        PeerNameDisplay.shown(candidate.displayName, fingerprint: candidate.fingerprint, placeholder: .met, in: .fernlet)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: displayName)
                    .font(look == nil ? .fernlet(.headerMedium) : FernletFramedFont.rowTitleBold)
                    .foregroundStyle(look?.text ?? Color.bark)
                if metByTapping {
                    Text(verbatim: FernletProximityUICopy.KeepFriends.metByTapping)
                        .font(look == nil ? .fernlet(.bodySmall) : FernletFramedFont.rowDetail)
                        .foregroundStyle(look?.dim ?? Color.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // One VoiceOver stop for the name and how you met, beside the chip.
            .accessibilityElement(children: .combine)

            Spacer(minLength: 12)

            // b3-keep-friends: a framed Keep, and Keeping on the accent once chosen.
            Button(isKept ? FernletProximityUICopy.KeepFriends.keeping : FernletProximityUICopy.KeepFriends.keep) { toggle() }
                .buttonStyle(ActionPillButtonStyle(isKept ? .primary : .secondary, size: .small))
                .accessibilityAddTraits(isKept ? .isSelected : [])
                .accessibilityIdentifier("friends.keepFriend.\(candidate.fingerprint)")
        }
        .padding(12)
        .frame(minHeight: 60)
        .background(look?.paper ?? Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isKept ? (look?.mark ?? Color.moss) : (look?.ink ?? Color.bark.opacity(0.08)),
                              lineWidth: look == nil ? (isKept ? 1.5 : 1) : (isKept ? 3 : FernletFramedLook.frameWidth))
        )
        // Deliberately no accessibilityIdentifier on this container — a container id would
        // shadow the per-row button id above (known settings-toggle gotcha).
    }
}

/// Compact standalone prompt for sessions that ended with no photos to review but with eligible
/// new-friend candidates. Dismissing without choosing = skip all (the host clears the roster in
/// onDismiss and mints only what was toggled).
public struct KeepFriendsPromptSheet: View {
    let candidates: [MeshSessionRosterEntry]
    @Binding var keptFingerprints: Set<String>
    /// Whether the hangout began with the phones tapped together: each name then says "met by tapping
    /// phones" under it (`fr-tap-keep`).
    let metByTapping: Bool
    let done: () -> Void

    /// - Parameters:
    ///   - candidates: The people met, each with a Keep chip.
    ///   - keptFingerprints: The people the person switched on.
    ///   - metByTapping: Whether the hangout began with a tap of two phones on Home (World Friends spec
    ///     §1.3); false, the default, shows the names alone.
    ///   - done: Finishes the flow (the presenter mints the keeps on dismiss).
    public init(candidates: [MeshSessionRosterEntry], keptFingerprints: Binding<Set<String>>, metByTapping: Bool = false,
                done: @escaping () -> Void) {
        self.candidates = candidates
        self._keptFingerprints = keptFingerprints
        self.metByTapping = metByTapping
        self.done = done
    }

    @Environment(\.fernletFramedLook) private var look

    public var body: some View {
        if look != nil {
            framed
        } else {
            standard
        }
    }

    /// The World build's sheet (b3-keep-friends): Done top right in the sheet header, the title in the
    /// sheet, framed rows. The presenter adds the sheet frame (`fernletSheet()`).
    private var framed: some View {
        ScrollView {
            KeepFriendsSection(candidates: candidates, keptFingerprints: $keptFingerprints, metByTapping: metByTapping)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SheetHeader(title: Text(verbatim: FernletProximityUICopy.KeepFriends.sessionTitle), onDone: done)
        }
    }

    /// Today's sheet, outside the World build.
    private var standard: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(verbatim: FernletProximityUICopy.KeepFriends.sessionTitle)
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    KeepFriendsSection(candidates: candidates, keptFingerprints: $keptFingerprints, metByTapping: metByTapping)
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            // "Done" finishes the flow (and mints the keeps), so it is a call-to-action pill, not a
            // 34pt selection chip.
            Button(FernletProximityUICopy.KeepFriends.done) { done() }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(Color.parchment)
                .accessibilityIdentifier("friends.keepFriends.done")
        }
        .background(Color.parchment)
    }
}
