// FernletRoutedTypes.swift
// FernletSocial/Mesh
//
// ProximityKit plan step A0.5.9 (seam S16): Fernlet's routed-type rows, declared by the host rather
// than resident in the mesh engine. The engine builds its routed type registry from its resident rows
// and the host's (`ProximityHost.meshRoutedTypeEntries`); FernletStore answers this file's `entries`,
// and the test target's host doubles answer the same. A row moves here with its feature, spelled
// exactly as the engine's registry spelled it, each cap the same formula over the moved body's
// constants: the temporary-message row with chat (A0.5.9), the heart row with hearts (A0.5.10) and the
// photo row with photos (A0.5.11).
//
// The one FernletSocial file that reads a routed type off the namespace (the field-homes wall in
// `MeshRoutedStoreIsolationTests`): the composition registers each feature's projection adapter, and
// each sender mints, under its row's token from here, so a host with another namespace registers and
// mints under its own spellings. The registry is token-keyed, so the order of these rows, and theirs
// against the engine's, reaches no door and no byte.

import Foundation
import ProximityKit

/// Fernlet's routed-type rows by name, each built from the routed types of the namespace the host
/// holds (plan step A0.5.9, S16): the rows the mesh registers beyond its resident ones.
///
/// A value: the mesh still admits, resolves and forwards by its own registry alone, built once from
/// its resident rows and ``entries``, and asks that registry whether a row is registered before a
/// sender mints under the row's token. The rows by name say which token is whose — the token the chat
/// sends under and the composition registers its projection adapter under — and ``entries`` hands
/// them all to the host's ``ProximityHost/meshRoutedTypeEntries``.
public nonisolated struct FernletRoutedTypes: Equatable, Sendable {

    /// The temporary-message row: the live-session chat's routed type (P6 item 4), FernletSocial's
    /// since the chat left the engine (plan step A0.5.9).
    public let text: MeshRoutedTypeEntry

    /// Fernlet's rows over `routedTypes`, each row's token read off them: this file spells no routed
    /// type of its own.
    ///
    /// - Parameter routedTypes: The routed types of the namespace the host holds.
    public init(_ routedTypes: ProximityNamespace.RoutedTypes) {
        // The text row's cap is the SECOND narrowed one (P6 item 4), and narrowed the same way as the
        // photo row's: `MeshRoutedTextBody.maxSealedBlobByteCount` is the sanitized maximum's own byte
        // bound (16 × `SessionMessageStore.maxTextLength`, because the product's cap is 500
        // *Characters* and a grapheme cluster is unbounded in bytes) plus this body family's framed
        // header allowance plus the seal's overhead — 9 065 B. Defined as that constant, never as a
        // copy, so the mint's own refusal and the manifest door's `sizeExceedsTypeCap` are one number.
        // `contentScope` and `maxItemByteCount` are the two columns the freezing rule leaves editable
        // in place, so this needs no amendment to it.
        self.text = MeshRoutedTypeEntry(
            token: routedTypes.tempMessage,
            maxItemByteCount: UInt64(MeshRoutedTextBody.maxSealedBlobByteCount),
            destinations: .fullRosterAtCreation,
            relayRetention: .originRetainsUntilDeparture,
            finalAck: .durableRecipientStorage,
            expiry: .meshHardDeadlinePlusGrace,
            contentScope: .session
        )
    }

    /// Every row, the host's half of the mesh's registry: today the temporary-message row.
    public var entries: [MeshRoutedTypeEntry] { [text] }

    /// The rows a host answers ``ProximityHost/meshRoutedTypeEntries`` with:
    /// `FernletRoutedTypes(routedTypes).entries`.
    ///
    /// - Parameter routedTypes: The routed types of the namespace the host holds.
    /// - Returns: Every Fernlet row, each under its token in `routedTypes`.
    public static func entries(_ routedTypes: ProximityNamespace.RoutedTypes) -> [MeshRoutedTypeEntry] {
        FernletRoutedTypes(routedTypes).entries
    }
}
