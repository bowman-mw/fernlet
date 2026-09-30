// SessionPhotoReviewScreen.swift
// Fernlet
//
// Session photos U3 (2026-09-30): the full-screen review the overlay window hosts — ProximityKit's
// `FriendPhotoReviewSheet` over the coordinator's snapshot, with "Not now", the failed-export
// alert, and the scene phase the sheet's snapshot cover reads injected by hand.

import SwiftUI
import ProximityKit
import FernletUI

/// The session-end photo review as the overlay window draws it: ``SessionPhotoReviewCoordinator``'s
/// snapshot rendered through `FriendPhotoReviewSheet`, full screen.
///
/// **The scene phase is injected, not inherited** (design §4.5, invariant I18). A
/// `UIHostingController` in a window this app creates sits outside the SwiftUI `App` scene that
/// supplies `\.scenePhase`, so this screen hands the sheet the coordinator's phase (fed by
/// ContentView). While it is not `.active` the sheet draws its opaque cover instead of the grid, so
/// the app-switcher snapshot never holds a photo nobody chose.
///
/// Tiles load through the manager's gated seam (`reviewThumbnailData(for:)`), which answers nothing
/// under duress or while the device is locked; they reload when that seam reopens. The root is
/// modal to VoiceOver, and VoiceOver's escape gesture is "Not now" (the sheet wires it).
struct SessionPhotoReviewScreen: View {
    /// The coordinator whose snapshot and actions this renders.
    @Bindable var coordinator: SessionPhotoReviewCoordinator

    var body: some View {
        ZStack {
            Color.parchment.ignoresSafeArea()
            FriendPhotoReviewSheet(
                photos: coordinator.photos,
                selectedIDs: $coordinator.selectedIDs,
                friendCandidates: coordinator.candidates,
                keptFriendFingerprints: $coordinator.keptFriendFingerprints,
                alsoSaveToPhotos: $coordinator.alsoSaveToPhotos,
                canKeep: coordinator.canKeep,
                workingMessage: coordinator.workingMessage,
                answerFailure: coordinator.answerFailure,
                unreadableCount: coordinator.unreadableCount,
                tileReloadToken: coordinator.manager.heldPhotosCanBeShown ? 1 : 0,
                keepSelected: { await coordinator.keepSelected() },
                discardAll: { await coordinator.discardAll() },
                notNow: { Task { await coordinator.notNow() } },
                loadImageData: { coordinator.manager.reviewThumbnailData(for: $0) }
            )
            .environment(\.scenePhase, coordinator.scenePhase)
            .photoSaveFailureAlert("Couldn't Save Photos", failure: $coordinator.photoSaveError)
            // The alert closing — either button, or the system taking it down — releases an answer
            // waiting on it; so does the screen going away, so a hide never strands one.
            .onChange(of: coordinator.photoSaveError == nil) { _, cleared in
                if cleared { coordinator.acknowledgeSaveFailure() }
            }
            .onDisappear { coordinator.acknowledgeSaveFailure() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("friends.review.overlay")
    }
}
