// R8: the one custom condition (Docs/Power-of-10-Swift.md §R8) — compiled only into the `Demo`
// build configuration (`Fernlet Demo` scheme). Normal builds carry none of this file.
//
// The demo's pretend friend, display-side only: nothing here touches the radio. The friend is a
// trust-vault row over freshly generated public keys whose private halves are thrown away at once, so
// no device anywhere can ever answer as this friend; their photos, golden heart and shop are written
// straight into the local stores a real in-person session would have filled.
#if FERNLET_DEMO
import CryptoKit
import Foundation
import FernletConnections
import FernletDomainModel
import FernletFoundation
import FernletSocial
import ProximityKit

/// The demo's pretend friend: a kept friend in the friends list, three photos on the album wall from a
/// session two days ago, one golden heart given in person, and a shop window with two items.
///
/// Called by ``ReviewDemo`` right after the sample data. ``removeReviewDemoFriend()`` undoes it — first,
/// before the delete-everything funnel, because that funnel deliberately keeps the photo wall.
extension FernletStore {
    /// The pretend friend's name.
    static let reviewDemoFriendName = "Juniper"

    /// The `UserDefaults` row holding the friend's signing public key, so removal finds exactly the
    /// vault row the seed wrote (a real friend who happens to share the name is never touched).
    private static let reviewDemoFriendKeyDefaultsKey = "reviewDemo.friendSigningKey"

    /// How many photos the friend puts on the album wall.
    private static let reviewDemoFriendPhotoCount = 3

    /// Adds the pretend friend. A no-op (logged) when the friend is already there.
    @MainActor
    func seedReviewDemoFriend() {
        let defaults = UserDefaults.standard
        if let existing = defaults.data(forKey: Self.reviewDemoFriendKeyDefaultsKey),
           trustedProximityPeer(signingPublicKey: existing) != nil {
            FernletAuditLog.log("reviewDemo.friend.skipped", context: ["reason": "present"])
            return
        }
        // Fresh keys, private halves discarded on return: the row is real-shaped (a genuine fingerprint)
        // but no device can ever authenticate as it.
        let signingKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let agreementKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let fingerprint = IdentityService.fingerprint(of: signingKey)
        let name = Self.reviewDemoFriendName
        let peer = ProximityCoordinator.PeerIdentity(
            id: UUID(), displayName: name, signingPublicKey: signingKey,
            keyAgreementPublicKey: agreementKey, fingerprint: fingerprint,
            rangingMode: .none, firstSeenAt: Date().addingTimeInterval(-2 * 24 * 60 * 60)
        )
        trustProximityPeer(peer, mode: .friend)
        defaults.set(signingKey, forKey: Self.reviewDemoFriendKeyDefaultsKey)
        seedReviewDemoFriendPhotos(fingerprint: fingerprint, signingKey: signingKey)
        // One heart, given in person: a gold heart for its first 12 hours (`GoldHeartRules`). The
        // ledger's 5-minute receive window allows one per friend, which is also the honest count.
        if !heartLedger.recordReceivedHeart(id: UUID(), senderDisplayName: name, senderFingerprint: fingerprint) {
            FernletAuditLog.log("reviewDemo.friend.heartNotRecorded")
        }
        seedReviewDemoFriendShop(fingerprint: fingerprint, signingKey: signingKey, agreementKey: agreementKey)
        FernletAuditLog.log("reviewDemo.friend.added")
    }

    /// Removes everything ``seedReviewDemoFriend()`` added: the vault row (gone outright, not left as
    /// "Removed"), the wall photos (through the wall's own delete, which reseals the index without
    /// them), the received hearts and the shop window. Also drops the still-owed intimacy marker
    /// (``reviewDemoIntimacyPendingKey``). Safe to call when nothing was seeded.
    @MainActor
    func removeReviewDemoFriend() {
        let photos = meshFeatures.photos
        for index in 0..<Self.reviewDemoFriendPhotoCount {
            photos.deletePhoto(Self.reviewDemoFriendPhotoID(index))
        }
        // The demo never receives a real heart, so wiping the ledger takes only the friend's.
        heartLedger.clearAll()
        meshFeatures.clothingShop.clearAll()
        let defaults = UserDefaults.standard
        if let signingKey = defaults.data(forKey: Self.reviewDemoFriendKeyDefaultsKey) {
            let kept = proximityTrustVault.trustedPeers.filter { $0.signingPublicKey != signingKey }
            if kept.count != proximityTrustVault.trustedPeers.count {
                proximityTrustVault.apply(peers: kept, audit: proximityTrustVault.auditEvents)
                proximityTrustVault.onChange()
            }
            closenessLedger.remove(fingerprint: IdentityService.fingerprint(of: signingKey))
        }
        defaults.removeObject(forKey: Self.reviewDemoFriendKeyDefaultsKey)
        defaults.removeObject(forKey: Self.reviewDemoIntimacyPendingKey)
        FernletAuditLog.log("reviewDemo.friend.removed")
    }

    // MARK: - Album wall

    /// Three photos from a session two days ago, kept on the wall as a real session's answer would.
    ///
    /// The wall holds `meshPhotos` in memory and writes its sealed index only on its own saves, so the
    /// photos ride in with a fourth, sender-less throwaway photo that is then deleted through
    /// ``MeshSessionPhotos/deletePhoto(_:)``: that delete is the wall's public save, sealing the three
    /// photos' bytes and index to disk (and, with no sender, the throwaway leaves no tombstone).
    private func seedReviewDemoFriendPhotos(fingerprint: String, signingKey: Data) {
        let name = Self.reviewDemoFriendName
        let startedAt = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        let session = FriendPhotoSessionMetadata(
            id: UUID(), meshID: nil, meshName: nil, startedAt: startedAt,
            participants: [FriendPhotoSessionParticipant(fingerprint: fingerprint, displayName: name)]
        )
        var seeded: [FriendPhotoPayload] = []
        for index in 0..<Self.reviewDemoFriendPhotoCount {
            guard let data = ReviewDemoArt.parkScene(variant: index + 3) else { continue }
            seeded.insert(FriendPhotoPayload(
                id: Self.reviewDemoFriendPhotoID(index), imageData: data,
                addedAt: startedAt.addingTimeInterval(Double(index) * 20 * 60), senderName: name,
                senderFingerprint: fingerprint, senderSigningPublicKey: signingKey, session: session
            ), at: 0)
        }
        guard !seeded.isEmpty, let flushData = ReviewDemoArt.parkScene(variant: 0) else {
            FernletAuditLog.log("reviewDemo.friend.photosNotDrawn")
            return
        }
        let flush = FriendPhotoPayload(imageData: flushData, addedAt: startedAt, senderName: name)
        let photos = meshFeatures.photos
        let seededIDs = Set(seeded.map(\.id))
        photos.meshPhotos = seeded + [flush] + photos.meshPhotos.filter { !seededIDs.contains($0.id) }
        photos.deletePhoto(flush.id)
    }

    /// A stable id for the friend's `index`th wall photo, so removal finds them whether or not the
    /// vault row is still there (delete-everything clears the vault but keeps the wall).
    private static func reviewDemoFriendPhotoID(_ index: Int) -> UUID {
        let digest = Array(SHA256.hash(data: Data("fernlet.reviewDemo.friendPhoto.\(index)".utf8)))
        guard digest.count >= 16 else { return UUID() }
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }

    /// Re-opens the friend's shop window once launch finishes while the demo runs: the shop is memory
    /// only, so without this a reviewer who relaunches finds it empty. A no-op outside the demo or once
    /// the friend is gone.
    @MainActor
    func refreshReviewDemoFriendShop() {
        guard ReviewDemo.isActive,
              let signingKey = UserDefaults.standard.data(forKey: Self.reviewDemoFriendKeyDefaultsKey),
              let friend = trustedProximityPeer(signingPublicKey: signingKey) else { return }
        seedReviewDemoFriendShop(fingerprint: friend.fingerprint, signingKey: signingKey,
                                 agreementKey: friend.keyAgreementPublicKey)
    }

    // MARK: - Shop

    /// The friend's shop: two items, held and opened for the usual one-hour window as at a session's
    /// end. Memory only (like every received catalog), so it is gone an hour later or at relaunch.
    ///
    /// The envelope is never sent and never signed: `receiveCatalog` trusts its caller to have verified
    /// the sender, and here the caller is this seed. Sharing must be on, or the shop drops the catalog.
    private func seedReviewDemoFriendShop(fingerprint: String, signingKey: Data, agreementKey: Data) {
        if !settings.allowNearbyClothingShares {
            setAllowNearbyClothingShares(true)
        }
        let designer = ItemDesigner(id: UUID())
        let items = [
            CustomizationItem(name: FernletStore.reviewDemoSample("reviewDemo.friend.beanie", "Striped beanie"), slot: .hat,
                              texture: Self.reviewDemoStripes(slot: .hat, rows: 8..<22, cols: 6..<26, colors: [8, 3]),
                              designer: designer, isShareable: true, price: 10),
            CustomizationItem(name: FernletStore.reviewDemoSample("reviewDemo.friend.scarf", "Cozy scarf"), slot: .body,
                              texture: Self.reviewDemoStripes(slot: .body, rows: 10..<16, cols: 8..<40, colors: [12, 4]),
                              designer: designer, isShareable: true, price: 15),
        ]
        let catalog = ClothingCatalogPayload(designerID: designer.id, displayName: Self.reviewDemoFriendName, items: items)
        let plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(catalog)
        } catch {
            FernletAuditLog.log("reviewDemo.friend.shopNotEncoded", context: ["error": "\(type(of: error))"])
            return
        }
        let envelope = ProximityIdentityEnvelope(
            schemaVersion: 1, envelopeID: UUID(), senderSigningPublicKey: signingKey,
            senderKeyAgreementPublicKey: agreementKey, senderDisplayName: Self.reviewDemoFriendName,
            recipientFingerprint: nil, payloadTypeToken: PayloadType.clothingCatalog.rawValue,
            payloadEncryption: .none, payloadSummary: PayloadSummary(title: "Shop", itemCount: items.count),
            payload: plaintext, createdAt: Date(), expiresAt: nil, signature: Data()
        )
        let shop = meshFeatures.clothingShop
        shop.receiveCatalog(envelope, plaintext: plaintext, verifiedFingerprint: fingerprint)
        shop.openWindowAtSessionEnd()
    }

    /// A pixel texture for `slot`: horizontal two-row stripes of `colors` (palette indices) over the
    /// given rectangle, transparent elsewhere.
    private static func reviewDemoStripes(slot: ItemSlot, rows: Range<Int>, cols: Range<Int>, colors: [Int]) -> ItemGridTexture {
        var texture = ItemGridTexture.blank(for: slot, palette: ItemDesignPalette.hexes)
        guard !colors.isEmpty else { return texture }
        for y in rows where y >= 0 && y < texture.rows {
            for x in cols where x >= 0 && x < texture.cols {
                texture.pixels[y * texture.cols + x] = colors[(y / 2) % colors.count]
            }
        }
        return texture
    }
}
#endif
