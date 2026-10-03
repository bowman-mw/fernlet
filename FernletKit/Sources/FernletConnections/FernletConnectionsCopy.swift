// FernletConnectionsCopy.swift
// FernletConnections
//
// This module's copy vault: a sibling of `FernletUICopy`, `FernletLockCopy`, `ProximityUICopy` and
// `FernletProximityUICopy`, for the same reason and in the same shape. It holds the two plain
// phrases that stand in for a person whose name is not known, which this module's extension of
// ProximityKit's `PeerNameDisplay` (`PeerNameDisplay+Placeholders.swift`) hands the app's in-person
// surfaces. Their keys keep the `proximity.peer.` spelling: a key is a token, and a renamed key
// strands every translation of it.
//
// A `String(localized:)` inside an SPM module that omits `bundle: .module` resolves against
// `Bundle.main` — the APP's bundle — which never consults this module's own catalog, so the
// string renders as untranslatable English with a clean build and no warning anywhere. Here
// `bundle: .module` is FernletConnections' own `Localizable.xcstrings`; routing the copy through
// here with it is what makes the phrases translatable at all.
//
// DO NOT put wire vocabulary in this file. Every `PayloadSummary` title, every mesh token and
// every canonical-signature byte is FROZEN ENGLISH and must never reach `String(localized:)` —
// see `ProximityKit.md` §"Localization: nothing on the wire is display copy". This vault is
// display copy only: what a person reads, never what a peer parses. The namespace's values in this
// module (`ProximityNamespace.fernlet`) are data and never come here, the peer-name floor "A friend"
// among them, which a session can write into a roster and the trust vault as a peer's name.

import Foundation

/// Display copy FernletConnections hands out already resolved: the name placeholders
/// `PeerNameDisplay.text(for:)` returns for the app's in-person surfaces.
///
/// Members are computed, not stored, so each lookup happens under the locale in force when the
/// surface renders. Resolved `String`s rather than `LocalizedStringKey`s, deliberately: a key
/// carries no bundle, so handing one to SwiftUI would put the lookup back in `Bundle.main` and
/// undo the fix.
enum FernletConnectionsCopy {

    /// The plain phrases that stand in for a person whose name is not known, read through
    /// ``PeerNameDisplay``. `nonisolated` because that helper is: a resolved display string has no
    /// actor to protect, and `Bundle.module` is itself nonisolated.
    nonisolated enum Peer {
        /// Someone on the connect path whose name has not been shared yet.
        static var someoneNearby: String {
            String(localized: "proximity.peer.someoneNearby", defaultValue: "Someone nearby", bundle: .module,
                   comment: "Stands in for a nearby person whose name has not been shared yet: the connect rows on the Friends tab, the session's participant list, a join request, a recipe recipient. A plain phrase, shown where a name would be.")
        }

        /// Someone met in an earlier session whose name never arrived.
        static var someoneYouMet: String {
            String(localized: "proximity.peer.someoneYouMet", defaultValue: "Someone you met", bundle: .module,
                   comment: "Stands in for a person met in person whose name never arrived before the connection ended: the keep-as-friend rows at the end of a session and the Friends & Blocks list.")
        }
    }
}
