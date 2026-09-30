// PendingPhotoReviewCard.swift
// Fernlet
//
// Session photos U3 (2026-09-30): the Friends album's way back to a review the person put off with
// "Not now". While it is outstanding, discovery is stopped (the run policy's
// `sessionPhotoReviewBlocksDiscovery`), so this card takes the nearby-status slot — empty then,
// because that banner renders only while searching — and says why nothing is being looked for.

import SwiftUI
import FernletUI

/// "Photos waiting for you": the Friends album card for an ended session's photos still waiting
/// for the keep-or-delete choice, with a "Choose photos" button that re-presents the review
/// (``SessionPhotoReviewCoordinator/reopen()``).
///
/// The host renders it only while photos are outstanding, the session is not live, and no duress
/// session is in force: under the decoy there is no card at all (hide, never delete — the corpus is
/// untouched), because a "Choose photos" that could never open would itself be the tell.
///
/// Accessibility: the title and the sentence carrying the count read as one element, the button
/// as another; the card itself is a container with a frozen identifier.
struct PendingPhotoReviewCard: View {
    /// How many photos are waiting.
    let count: Int
    /// Re-presents the review.
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "photo.stack")
                    .foregroundStyle(Color.mossInk)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.title)
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(Color.bark)
                    Text(Self.body(count))
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 4)
            }
            Button(action: choose) {
                Text(Self.button)
            }
            .buttonStyle(ActionPillButtonStyle(.primary))
            .accessibilityIdentifier("friends.pendingReview.open")
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.moss.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("friends.pendingReview.card")
    }

    /// The card's title.
    static var title: LocalizedStringResource {
        LocalizedStringResource(
            "friends.pendingReview.title", defaultValue: "Photos waiting for you",
            comment: "Title of the Friends tab card shown while photos from an ended in-person session are still waiting for the person to choose which to keep."
        )
    }

    /// The card's sentence, naming the count; the key carries `one`/`other` plural variations.
    ///
    /// - Parameter count: How many photos are waiting.
    /// - Returns: "3 photos from your last session are waiting. Nothing is saved until you choose."
    static func body(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "friends.pendingReview.body",
            defaultValue: "\(count) photos from your last session are waiting. Nothing is saved until you choose.",
            comment: "Body of the Friends tab card for photos waiting to be chosen. The count is how many photos. Must keep saying that nothing is saved (not in Fernlet, not in the camera roll) until the person chooses."
        )
    }

    /// The button that re-opens the review.
    static var button: LocalizedStringResource {
        LocalizedStringResource(
            "friends.pendingReview.button", defaultValue: "Choose photos",
            comment: "Button on the Friends tab card that opens the review of photos from the last in-person session, where the person keeps or deletes them."
        )
    }
}
