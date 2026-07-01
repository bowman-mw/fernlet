// ItemDesigner.swift
// Provenance attribution for a user-designed item.

import Foundation

/// Who designed an item — carried with the item so a recipient's closet can show "designed by …".
///
/// Privacy by design: this holds ONLY an anonymous, stable designer id (a random UUID), never a name,
/// public key, or anything otherwise identifiable. The id reveals nothing on its own. The id→name
/// mapping is learned out-of-band, only when two people connect in person (the handshake carries the
/// pairing), and is stored locally per device. So a shared item — even one that travels friend-to-friend
/// across several people — never leaks who made it to anyone who hasn't actually met the designer.
///
/// "Is this item mine?" is deliberately NOT stored here: it is decided by comparing `id` to the local
/// designer id at read time. Storing it would be wrong — a copy I share must not claim to be self-made
/// on the recipient's device.
public nonisolated struct ItemDesigner: Codable, Equatable, Sendable {
    /// Anonymous, stable identifier for the original designer. Not derived from any identity material.
    public var id: UUID

    public init(id: UUID) {
        self.id = id
    }
}
