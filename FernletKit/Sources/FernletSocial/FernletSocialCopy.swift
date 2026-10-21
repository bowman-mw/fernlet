// FernletSocialCopy.swift
// FernletSocial
//
// This module's copy vault: a sibling of `FernletUICopy`, `FernletLockCopy`, `FernletProximityUICopy`
// and `FernletConnectionsCopy`, for the same reason and in the same shape. It holds every string
// FernletSocial hands out already resolved: the in-person camera's two capture refusals, which the
// photo object (`MeshSessionPhotos`) publishes on the mesh's `meshError`; the session roster's
// "Friend of …" vouch label; Group Activities' `activityError` lines; the presence path's heart
// sentences (`PresenceManager.heartSendState`); and the recipe share's failed status line. The
// first key keeps the `proximity.camera.` spelling it shipped under: a key is a token, and a renamed
// key strands every translation of it.
//
// A `String(localized:)` inside an SPM module that omits `bundle: .module` resolves against
// `Bundle.main` — the APP's bundle — which never consults this module's own catalog, so the
// string renders as untranslatable English with a clean build and no warning anywhere. Here
// `bundle: .module` is FernletSocial's own `Localizable.xcstrings`, the module's first; routing the
// copy through here with it is what makes the line translatable at all.
//
// DO NOT put wire vocabulary in this file. Every `PayloadSummary` title, every mesh token and
// every canonical-signature byte is FROZEN ENGLISH and must never reach `String(localized:)` —
// see ProximityKit's landing page, `ProximityKit.md` in its repository, §"Localization: nothing on
// the wire is display copy". This vault is
// display copy only: what a person reads, never what a peer parses.

import Foundation

/// Display copy FernletSocial hands out already resolved: the in-person camera's session lines, the
/// Group Activities errors, the presence path's heart sentences, the recipe share's status line and
/// the session's "Friend of …" vouch label.
///
/// Members are computed, not stored, so each lookup happens under the locale in force when the
/// surface renders. Resolved `String`s rather than `LocalizedStringKey`s, deliberately: a key
/// carries no bundle, so handing one to SwiftUI would put the lookup back in `Bundle.main` and
/// undo the fix. Every sentence is one key with its names as placeholders, never English pieces
/// joined, and a count rides a key whose English `one`/`other` block is authored in the catalog
/// (`LocalizationBoundaryTests.pluralRuledKeys`).
enum FernletSocialCopy {

    /// Copy the disposable camera's session surfaces read from the mesh.
    enum Camera {
        /// The capture refusal when this phone could not seal its own copy (no film is spent and
        /// nothing is shared). Rendered by the camera's session alert through `meshError`.
        static var holdFailed: String {
            String(localized: "proximity.camera.holdFailed", defaultValue: "Couldn't keep that photo. Try again.",
                   bundle: .module,
                   comment: "Alert on the in-person camera when a photo just taken could not be saved securely on this phone. No film was used and nothing was shared.")
        }

        /// The capture refusal once this phone has shared its per-session photo allowance.
        /// Rendered by the camera's session alert through `meshError`.
        ///
        /// - Parameter limit: The per-sender, per-session photo cap.
        static func photoLimitReached(_ limit: Int) -> String {
            String(localized: "proximity.camera.photoLimitReached",
                   defaultValue: "You've shared the maximum of \(limit) photos in this mesh session.",
                   bundle: .module,
                   comment: "Alert on the in-person camera when this phone has shared as many photos as one session allows. %lld is that number.")
        }
    }

    /// Copy the in-person session's roster reads.
    enum Session {
        /// The session roster's line under a participant someone you trust has vouched for
        /// (`FernletVouchList.vouchLabel(for:)`).
        ///
        /// - Parameter voucherName: The vouching friend's name as their vouch list carried it.
        static func friendOf(_ voucherName: String) -> String {
            String(localized: "proximity.session.friendOf", defaultValue: "Friend of \(voucherName)",
                   bundle: .module,
                   comment: "Under a person in the in-person session's list: one of your friends trusts them. %@ is that friend's name.")
        }
    }

    /// Group Activities' errors, published on `ProximityActivityManager.activityError` and shown by
    /// the Activities screen's alert or the join sheet's inline banner.
    enum Activities {
        /// No device identity to sign with.
        static var identityUnavailable: String {
            String(localized: "activities.error.identityUnavailable", defaultValue: "Identity unavailable.",
                   bundle: .module,
                   comment: "Group Activities error when this phone's secure identity is not available to start or join an activity")
        }

        /// The host cap.
        ///
        /// - Parameter limit: How many activities one phone may host at once.
        static func hostLimit(_ limit: Int) -> String {
            String(localized: "activities.error.hostLimit",
                   defaultValue: "You can host up to \(limit) activities.",
                   bundle: .module,
                   comment: "Group Activities error when starting one more activity than a phone may host. %lld is the limit.")
        }

        /// Signing the first roster failed.
        static var createFailed: String {
            String(localized: "activities.error.createFailed", defaultValue: "Couldn't create the activity.",
                   bundle: .module,
                   comment: "Group Activities error when a new activity could not be set up")
        }

        /// Re-signing the roster after a change failed.
        static var updateFailed: String {
            String(localized: "activities.error.updateFailed", defaultValue: "Couldn't update the activity.",
                   bundle: .module,
                   comment: "Group Activities error when the member list could not be updated after someone joined, left or was removed")
        }

        /// The participant cap.
        static var full: String {
            String(localized: "activities.error.full", defaultValue: "This activity is full.",
                   bundle: .module,
                   comment: "Group Activities error shown to the host when allowing one more person would go over the member limit")
        }

        /// Minting the joiner's token failed.
        static var grantFailed: String {
            String(localized: "activities.error.grantFailed", defaultValue: "Couldn't grant the join.",
                   bundle: .module,
                   comment: "Group Activities error shown to the host when letting a person join failed")
        }

        /// The offered activity expired before the request.
        static var expired: String {
            String(localized: "activities.error.expired", defaultValue: "That activity has expired.",
                   bundle: .module,
                   comment: "Group Activities error when asking to join an activity whose time is up")
        }

        /// The joined cap.
        static var joinLimit: String {
            String(localized: "activities.error.joinLimit", defaultValue: "You've joined the maximum number of activities.",
                   bundle: .module,
                   comment: "Group Activities error when asking to join one more activity than a phone may be in")
        }

        /// The host's grant did not verify.
        static var inviteUnverified: String {
            String(localized: "activities.error.inviteUnverified", defaultValue: "That invitation couldn't be verified.",
                   bundle: .module,
                   comment: "Group Activities error when the host's answer to a join request could not be verified, so the join did not happen")
        }
    }

    /// The presence path's heart sentences, published on `PresenceManager.heartSendState`'s
    /// `.failed(message:)` and drawn verbatim by the Friends list and the in-person camera.
    ///
    /// The mesh path's sentences are the app's own (`SessionHeartStatusCopy`, a frozen cause per
    /// case); this path keeps its resolved `String` because it is resolved HERE, under
    /// `bundle: .module`, which is what makes it translatable — the hole the app's note named was a
    /// sentence composed in English, not the `String` type. Each `name` is a first name already
    /// through `PresenceManager.firstName(of:in:)`, or "Someone you met" whole.
    enum Presence {
        /// Hearts are turned off on this phone.
        static func heartsOff(_ name: String) -> String {
            String(localized: "presence.heart.heartsOff", defaultValue: "Turn on nearby hearts to send \(name) some warmth.",
                   bundle: .module,
                   comment: "Heart status line when nearby hearts are turned off. %@ is the friend's first name.")
        }

        /// The per-friend cooldown is running.
        static func cooldown(_ name: String) -> String {
            String(localized: "presence.heart.cooldown",
                   defaultValue: "You just sent \(name) some warmth — hearts settle for a few minutes.",
                   bundle: .module,
                   comment: "Heart status line when a heart was sent to this friend minutes ago. %@ is the friend's first name.")
        }

        /// A connection to this friend is already busy.
        static func alreadySending(_ name: String) -> String {
            String(localized: "presence.heart.alreadySending", defaultValue: "Already sending \(name) some warmth — one moment.",
                   bundle: .module,
                   comment: "Heart status line when a heart to this friend is already on its way. %@ is the friend's first name.")
        }

        /// The connecting device held no friend key to verify against.
        static var couldNotVerifyThisFriend: String {
            String(localized: "presence.heart.couldNotVerifyThisFriend",
                   defaultValue: "Couldn't verify this friend — no heart was sent.",
                   bundle: .module,
                   comment: "Heart status line when the nearby phone could not be confirmed as the friend, so nothing was sent")
        }

        /// The connected device did not verify as the intended friend.
        static func couldNotVerify(_ name: String) -> String {
            String(localized: "presence.heart.couldNotVerify", defaultValue: "Couldn't verify \(name) — no heart was sent.",
                   bundle: .module,
                   comment: "Heart status line when the nearby phone could not be confirmed as this friend, so nothing was sent. %@ is the friend's first name.")
        }

        /// The heart connection failed before the heart went out.
        static var noHeartConnectionDropped: String {
            String(localized: "presence.heart.noHeartConnectionDropped",
                   defaultValue: "No heart was sent — the connection dropped.",
                   bundle: .module,
                   comment: "Heart status line when the connection to the friend's phone failed before the heart was sent")
        }

        /// The heart connection disconnected before the heart went out.
        static var connectionDropped: String {
            String(localized: "presence.heart.connectionDropped",
                   defaultValue: "The connection dropped — no heart was sent.",
                   bundle: .module,
                   comment: "Heart status line when the friend's phone disconnected before the heart was sent")
        }

        /// The send itself threw.
        static var couldNotSend: String {
            String(localized: "presence.heart.couldNotSend", defaultValue: "Could not send that heart just now.",
                   bundle: .module,
                   comment: "Heart status line when sending the heart failed")
        }

        /// The friend's phone never answered the invite.
        static func didNotAnswer(_ name: String) -> String {
            String(localized: "presence.heart.didNotAnswer", defaultValue: "\(name) didn't answer — try again in a moment.",
                   bundle: .module,
                   comment: "Heart status line when the friend's phone did not answer. %@ is the friend's first name.")
        }

        /// Not nearby, and the away drop-off (which the person turned on) refused the heart too.
        static func notNearbyAwayFailed(_ name: String) -> String {
            String(localized: "presence.heart.notNearbyAwayFailed",
                   defaultValue: "\(name) isn't nearby, and the heart couldn't be tucked away just now — try again in a moment.",
                   bundle: .module,
                   comment: "Heart status line when the friend is not nearby and saving the heart for later delivery also failed. %@ is the friend's first name.")
        }

        /// Not nearby, with delivery while apart turned off.
        static func notNearbyInPersonOnly(_ name: String) -> String {
            String(localized: "presence.heart.notNearbyInPersonOnly",
                   defaultValue: "\(name) isn't nearby right now — hearts travel in person for now.",
                   bundle: .module,
                   comment: "Heart status line when the friend is not nearby and hearts are only sent in person. %@ is the friend's first name.")
        }
    }

    /// The recipe share's failed status line, published on `ProximityRecipeShareManager.sendState`'s
    /// `.failed(message:)` and drawn by the recipe share sheet. Each `name` is the nearby Fernlet's
    /// name as its pair session reported it.
    enum RecipeShare {
        /// A search was refused because this phone is already paired.
        static func pairedAlready(_ name: String) -> String {
            String(localized: "recipeShare.failed.pairedAlready",
                   defaultValue: "Connected to \(name) — recipe sharing links two Fernlets at a time.",
                   bundle: .module,
                   comment: "Recipe share status when this phone is already linked to another nearby phone. %@ is that phone's name.")
        }

        /// The chosen recipient left.
        static var recipientUnavailable: String {
            String(localized: "recipeShare.failed.recipientUnavailable",
                   defaultValue: "That nearby Fernlet is no longer available.",
                   bundle: .module,
                   comment: "Recipe share status when the chosen nearby phone is gone")
        }

        /// Another connection attempt is in flight.
        static var connectingToAnother: String {
            String(localized: "recipeShare.failed.connectingToAnother",
                   defaultValue: "Still connecting to another Fernlet — recipe sharing links two Fernlets at a time.",
                   bundle: .module,
                   comment: "Recipe share status when this phone is still connecting to a different nearby phone")
        }

        /// This phone is still sharing with someone else.
        static func pairedWithAnother(_ name: String) -> String {
            String(localized: "recipeShare.failed.pairedWithAnother",
                   defaultValue: "Still sharing with \(name) — recipe sharing links two Fernlets at a time.",
                   bundle: .module,
                   comment: "Recipe share status when this phone is still sharing with another nearby phone. %@ is that phone's name.")
        }

        /// The recipient never answered.
        static func noAnswer(_ name: String) -> String {
            String(localized: "recipeShare.failed.noAnswer",
                   defaultValue: "No answer from \(name) — that Fernlet may be busy sharing with someone else.",
                   bundle: .module,
                   comment: "Recipe share status when the chosen nearby phone did not answer. %@ is that phone's name.")
        }

        /// The secure channel could not be set up.
        static func couldNotConnect(_ name: String) -> String {
            String(localized: "recipeShare.failed.couldNotConnect", defaultValue: "Could not connect securely to \(name).",
                   bundle: .module,
                   comment: "Recipe share status when a secure connection to the nearby phone could not be made. %@ is that phone's name.")
        }

        /// The send failed or was a duplicate.
        static var couldNotSend: String {
            String(localized: "recipeShare.failed.couldNotSend", defaultValue: "Could not send that recipe.",
                   bundle: .module,
                   comment: "Recipe share status when sending the recipe failed")
        }
    }
}
