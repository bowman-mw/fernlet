# ``FernletProximityUI``

The SwiftUI screens of Fernlet's in-person features: the session-end photo review, the keep-as-friend prompt, the Photos-library saver with its shared failure alert, and the one view that renders a fingerprint.

## Overview

`FernletProximityUI` is the presentation layer that sits on top of ProximityKit. The mesh, its
sealed photo corpus and its review state stay in `ProximityKit`; this module owns what a person sees
and touches when a session ends. ``FriendPhotoReviewSheet`` lets them choose which of a session's
photos to keep, with the keep-as-friend rows riding along when the session left eligible
candidates. ``KeepFriendsPromptSheet`` asks the keep-as-friend question on its own when the session
produced no photos. ``FriendPhotoLibrarySaver`` copies photos that are already on the wall to the
system Photos library, and ``PhotoSaveFailure`` with the `photoSaveFailureAlert(_:failure:)`
modifier gives every save surface the same failure wording. ``FingerprintText`` is the one view
that shows a peer's identity fingerprint.

All of it lived in ProximityKit's `UI/` folder until step A0.1 of
`Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md` moved it here, unchanged apart from what the
module boundary required (imports, and the copy vault's name). The move is what lets ProximityKit
become a drop-in package for any app: it now carries no SwiftUI view and no `FernletUI` edge.

**Position in the FernletKit graph and the S3 wall.** The target depends on `ProximityKit` (the
keep rows' `MeshSessionRosterEntry`, the review's `SessionPhotoAnswerFailure`, and
`PeerNameDisplay`), `FernletUI` (the design system: colour tokens, `.fernlet` fonts,
`ChipButtonStyle`, `ActionPillButtonStyle`, `AdaptiveStack`, `confirmDestructive`,
`FernletAnnouncer`), `FernletDomainModel` (`FriendPhotoPayload`), `FernletFoundation`
(`FernletAuditLog`) and `FernletConnections` (`ProximityNamespace.fernlet`, which both screens hand
`PeerNameDisplay` so it hides Fernlet's QUIC instance-name prefix). Only the app target consumes it.
**The edge runs from the UI to ProximityKit,
never the reverse**: ProximityKit cannot name anything here, so a module below can never call up
into a screen. Through ProximityKit it reaches `PrivateMediaStore` transitively, which puts it on
the protected side of the S3 wall: the walled `AIProviders` and `CloudKitSync` targets have no edge
to it, and `S3BoundaryTests.proximityAndCloudSyncDoNotImportEachOther()` holds it to ProximityKit's
own rule that nothing here imports CloudKit. It has no persistence and no cryptography of its own,
and it never reads a held photo's bytes itself: tiles load through the host's `loadImageData` seam,
which the app wires to ProximityKit's gated review readers.

**Why it is not part of FernletUI.** `FernletUI` is the design system, and the Fernlet Coach app
(iPhone, iPad and Mac) uses it without the mesh. Folding these screens into it would hand every
design-system consumer the networking stack and the Photos framework. Keeping them in their own
module leaves `FernletUI` free of both, and keeps the direction the plan requires: a UI module may
depend on ProximityKit, and ProximityKit never depends on a UI module.

**Nothing is saved before the person chooses.** The review shows photos HELD in ProximityKit's
sealed pending corpus. ``FriendPhotoReviewSheet`` never writes anything itself: Keep selected and
Delete all are the host's closures, and the "Also save kept photos to Photos" toggle is a binding
the host reads after the keep has landed, applying it only to the photos the answer reports on the
wall. While the scene is not `.active` the sheet draws an opaque cover instead of the grid, so the
app-switcher snapshot never holds a photo nobody chose yet, and while an answer runs the sheet
cannot be swiped away, so its working line and any failure alert stay in front of the person. The
two hosts are the app's session-end overlay (which passes `notNow`, a header text button that
answers nothing and is also VoiceOver's escape gesture there) and the camera's Develop sheet (which
passes nil and keeps its own swipe-down). Tiles are labelled "Photo from" the sender's name through
`PeerNameDisplay`, never a fingerprint.

**The Photos saver must stay off the main actor.** ``FriendPhotoLibrarySaver/save(_:)`` is
`nonisolated` with an explicit `@Sendable` change block: `PHPhotoLibrary.performChanges` runs on
Photos' own serial queue, and a block inheriting this module's `MainActor` default trips the Swift
executor precondition (the build-19 TestFlight crash). It asks for add-only authorization, counts
the creation requests it actually made, and throws ``FriendPhotoLibrarySaver/NothingSavedError``
when every image failed to decode rather than reporting a false success; a partial decode failure
is audited as `photoSave.partialDecodeFailure`. Its callers are the review hosts' post-answer
export (the overlay's coordinator receives it through `FernletStore` as an injected closure, so its
only route to the camera roll is that export) and the album carousel's per-photo save of a photo
already on the wall. ``FriendPhotoLibrarySaver/userFacingFailure(for:photoCount:)`` maps any failure
onto a ``PhotoSaveFailure``: the permission denial is the only one that offers Open Settings.
``PhotoSaveFailure`` is presentation state only, never `Codable`, persisted or sent.

**A fingerprint is shown in exactly one place.** ``FingerprintText`` renders a peer's fingerprint
for the friend detail card's collapsed "Safety code" disclosure in Friends & Blocks, and nowhere
else (owner decision 2026-09-29). Middle truncation keeps the head and tail people compare, and the
view spells the hex out for VoiceOver. `PeerNameDisplayTests` pins that no connect-path file,
`KeepFriendsPromptSheet.swift` included, renders it.

**Localization.** The module owns a `Localizable.xcstrings` and one copy vault,
`FernletProximityUICopy` (the review, keep-friends and save-failure copy), and every lookup passes
`bundle: .module`; `NothingSavedError`'s message is the one key written inline. These 28 keys moved
here from ProximityKit's catalog byte for byte, because a key is a token: a renamed key strands its
translations. ProximityKit keeps `ProximityUICopy` for the three strings it still hands out itself
(the camera's hold-failure line and the two `PeerNameDisplay` placeholders). The `friends.review.*`,
`friends.keepFriend.*` and `friends.keepFriends.done` accessibility identifiers are frozen tokens
that the UI tests drive. One gap came over unchanged: the Delete all confirmation's title and message
are English literals handed to `confirmDestructive`, which takes already-resolved strings, so they
reach no catalog yet.

The whole module is main-actor isolated (`defaultIsolation(MainActor.self)` in `Package.swift`),
matching its role as a SwiftUI surface; the saver above is the one deliberate `nonisolated` member.

## Topics

### Session-end photo review

- ``FriendPhotoReviewSheet``
- ``FriendPhotoReviewWorkingMessage``

### Keeping friends

- ``KeepFriendsPromptSheet``

### Saving to the Photos library

- ``FriendPhotoLibrarySaver``
- ``PhotoSaveFailure``
- ``SwiftUICore/View/photoSaveFailureAlert(_:failure:)``

### Identifiers

- ``FingerprintText``
