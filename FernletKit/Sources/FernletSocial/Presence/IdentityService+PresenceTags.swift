// IdentityService+PresenceTags.swift
// FernletSocial/Presence
//
// Presence's two derivations over a device identity: the pair secret both friends derive, and the
// rotating epoch tag the presence radio advertises and matches a friend by. ProximityKit's
// `IdentityService` keeps the key-agreement private key and the presence epoch clock the tags rotate
// on (`presenceEpochSeconds`, `presenceEpoch(at:)`), and derives the pair secret through its one
// generic door, `pairSecret(with:purpose:)`, under the salt Fernlet's namespace declares for presence
// (`FernletFeaturePurposes.presencePairV1`); the tag reads nothing but that secret, so it is computed
// here, beside the feature that advertises it. Every byte is the one Fernlet shipped:
// `FernletFeatureGoldenTests` pins the pair secret from either side and its missing-key refusal, and
// three consecutive epochs' tags with their wire tokens; `PresenceTagTests` holds the malformed-key
// refusal and the tag's mutual, per-pair and per-epoch properties.

import CryptoKit
import FernletConnections
import FernletCrypto
import Foundation
import ProximityKit

extension IdentityService {

    /// Bytes kept from the truncated presence-tag HMAC (base64 → 12 chars on the wire, which is
    /// what keeps a 24-tag roster inside the ~400 B Bonjour TXT budget).
    public nonisolated static let presenceTagByteCount = 8

    /// STATIC-STATIC X25519 DH pair secret for presence tags: ProximityKit's
    /// `pairSecret(with:purpose:)` under Fernlet's declared presence salt
    /// (`FernletFeaturePurposes.presencePairV1`, `fernlet.presence.tag.v1`), its own salt, so
    /// `HKDF-SHA256(DH(myKA_priv, friendKA_pub))` is domain-separated from the sealing derivation
    /// (`fernlet.proximity.v1`), the group-key wrap (`fernlet.mesh.groupkey.v1`) and the heart
    /// dead-drop's pair secret (`fernlet.heartdrop.v1`), and presence material can never collide
    /// with message keys.
    ///
    /// SYMMETRIC BY CONSTRUCTION — the mutual-recognition property: `DH(aPriv, bPub) ==
    /// DH(bPriv, aPub)`, the salt is a constant, and the door's `sharedInfo` is deliberately EMPTY (any
    /// ordering-dependent info such as sender‖recipient key bytes would give the two sides of the
    /// pair different secrets and break mutual tag derivation). Pairwise-DH is also why blocking a
    /// friend removes their tag: only someone holding one of the two private keys can derive it —
    /// a past handshake partner holding just our public keys cannot (unlike public-key-hash tags).
    ///
    /// - Parameter friendKeyAgreementPublicKey: The friend's raw X25519 public key.
    /// - Returns: The 32-byte pair secret.
    /// - Throws: `IdentityError.notProvisioned` first, when this identity holds no key-agreement key;
    ///   then `IdentityError.invalidKeyData` for a friend key that is not a raw X25519 public key; then
    ///   what the door throws.
    public func presencePairSecret(with friendKeyAgreementPublicKey: Data) throws -> SymmetricKey {
        guard !localKeyAgreementPublicKey.isEmpty else { throw IdentityError.notProvisioned }
        guard let friendKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: friendKeyAgreementPublicKey) else {
            throw IdentityError.invalidKeyData
        }
        return try pairSecret(with: friendKey, purpose: FernletFeaturePurposes.presencePairV1)
    }

    /// The rotating presence tag for one friend pair at one epoch:
    /// `HMAC-SHA256("fernlet.presence.epoch.v1" ‖ epoch_be64, pairSecret)` truncated to
    /// `presenceTagByteCount`. Both members of the pair derive the SAME tag for the same epoch
    /// (see `presencePairSecret`); different pairs derive independent tags. Observer-opaque:
    /// without a pair private key the tag is an unlinkable pseudorandom value that rotates every
    /// 15 minutes.
    public func presenceTag(for friendKeyAgreementPublicKey: Data, epoch: UInt64) throws -> Data {
        let secret = try presencePairSecret(with: friendKeyAgreementPublicKey)
        var message = FernletCryptoPurpose.HMAC.presenceEpochTagV1.data
        message.append(contentsOf: TagCounterBytes.bigEndian(epoch))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: secret)
        return Data(Data(mac).prefix(Self.presenceTagByteCount))
    }
}
