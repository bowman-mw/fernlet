// FernletSocialCopy.swift
// FernletSocial
//
// This module's copy vault: a sibling of `FernletUICopy`, `FernletLockCopy`, `FernletProximityUICopy`
// and `FernletConnectionsCopy`, for the same reason and in the same shape. It holds the one string
// FernletSocial hands out already resolved: the in-person camera's hold-failure line, which the photo
// object (`MeshSessionPhotos`) publishes on the mesh's `meshError` when a capture cannot be held. Its
// key keeps the `proximity.camera.` spelling it shipped under: a key is a token, and a renamed key
// strands every translation of it.
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

/// Display copy FernletSocial hands out already resolved: the in-person camera's hold-failure line.
///
/// Members are computed, not stored, so each lookup happens under the locale in force when the
/// surface renders. Resolved `String`s rather than `LocalizedStringKey`s, deliberately: a key
/// carries no bundle, so handing one to SwiftUI would put the lookup back in `Bundle.main` and
/// undo the fix.
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
    }
}
