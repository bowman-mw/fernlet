// IdentityService+HeartDrop.swift
// FernletSocial/HeartSharing
//
// The heart dead-drop's three derivations over a device identity: the UTC day its tags rotate on,
// the pair secret both friends derive, and the day tag a drop is filed under. ProximityKit's
// `IdentityService` keeps the key-agreement private key and derives the pair secret through its one
// generic door, `pairSecret(with:purpose:)`, under the salt Fernlet's namespace declares for the
// dead-drop (`FernletFeaturePurposes.heartDropPairV1`); the day epoch and the tag read no key, so
// they are pure statics here, beside the feature that files and fetches drops under them. Every byte
// is the one Fernlet shipped: `FernletFeatureGoldenTests` pins the pair secret from either side and
// its refusals in their order, the two directions' day tags and the day epoch at its boundaries.

import CryptoKit
import FernletConnections
import FernletCrypto
import Foundation
import ProximityKit

extension IdentityService {

    /// UTC day index for heart-drop tag rotation (bitchat's day-rotating courier recipient tags).
    public nonisolated static func heartDropDayEpoch(at date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970) / 86_400)
    }

    /// Static-static pair secret for heart-drop day tags: ProximityKit's
    /// `pairSecret(with:purpose:)` under Fernlet's declared heart-drop salt
    /// (`FernletFeaturePurposes.heartDropPairV1`, `fernlet.heartdrop.v1`), its own salt, so presence
    /// tags and drop tags can never collide across protocols. The door's info stays EMPTY: both
    /// sides must derive the same key (symmetry requirement).
    ///
    /// - Parameter friendKeyAgreementPublicKey: The friend's raw X25519 public key.
    /// - Returns: The 32-byte pair secret.
    /// - Throws: `IdentityError.notProvisioned` first, when this identity holds no key-agreement key;
    ///   then `IdentityError.sealFailed` for a friend key that is not a raw X25519 public key, the
    ///   error the dead-drop's audit lines name; then what the door throws.
    public func heartDropPairSecret(with friendKeyAgreementPublicKey: Data) throws -> SymmetricKey {
        guard !localKeyAgreementPublicKey.isEmpty else { throw IdentityError.notProvisioned }
        guard let friendKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: friendKeyAgreementPublicKey) else {
            throw IdentityError.sealFailed
        }
        return try pairSecret(with: friendKey, purpose: FernletFeaturePurposes.heartDropPairV1)
    }

    /// A drop's public-DB record tag: HMAC-SHA256 over a domain string + the day epoch + the
    /// SENDER's KA key (the sender term gives direction asymmetry, so my outgoing tag for a
    /// friend never equals my expected incoming tag from them), truncated to 16 bytes, hex.
    /// Uncorrelatable across days without the pair secret.
    public nonisolated static func heartDropTag(
        pairSecret: SymmetricKey,
        dayEpoch: UInt64,
        senderKeyAgreementPublicKey: Data
    ) -> String {
        var message = FernletCryptoPurpose.HMAC.heartDropDayTagV1.data
        message.append(contentsOf: TagCounterBytes.bigEndian(dayEpoch))
        message.append(senderKeyAgreementPublicKey)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: pairSecret)
        return Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// Big-endian (MSB-first) serialization of a 64-bit counter for the domain-separated HMAC messages
/// of FernletSocial's rotating tags, the heart day tag here and the presence epoch tag
/// (`Presence/IdentityService+PresenceTags.swift`) — the R9-safe replacement for
/// `withUnsafeBytes(of: value.bigEndian)`, byte-identical to it, so every pinned tag vector still
/// matches.
///
/// `nonisolated` against the module's `defaultIsolation(MainActor.self)`: a pure function of its
/// argument, called from the nonisolated tag statics.
nonisolated enum TagCounterBytes {

    /// The eight bytes of `value`, most significant first.
    static func bigEndian(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - 8 * $0)) }
    }
}
