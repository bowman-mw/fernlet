// FernletStore+SessionReports.swift
// Fernlet
//
// App Review guideline 1.2 (owner decision 2026-10-15): Report… on a live-session chat message and
// on a session photo. Both report the content's SENDER through the app's existing people report —
// `reportProximityPeer`, the trust vault's report-and-block on this device, exactly what Friends &
// Blocks records — and never through a second moderation store. What prompted the report then goes:
// the chat re-folds its view gates so the now-blocked author's rows leave the transcript at once, and
// a reported photo is removed the way declining it would remove it.

import Foundation
import FernletDomainModel
import FernletFoundation
import FernletSocial
import FernletConnections
import ProximityKit

extension FernletStore {

    /// The signing key a Report of `photo` names, or nil when Report… must not be offered: this
    /// device's own photo, or one that names nobody Fernlet can report. The routed delivery's
    /// verified key first, the trust vault's key for the photo's fingerprint second.
    ///
    /// - Parameter photo: A session photo — held for a review, or on the wall.
    /// - Returns: The sender's key, or nil.
    func reportableSenderKey(of photo: FriendPhotoPayload) -> Data? {
        let mesh = meshNetworkManager
        return PeerReportSubject.photoSenderKey(
            of: photo,
            localSigningKey: mesh.localSigningPublicKey,
            localFingerprint: mesh.localFingerprint,
            vaultKey: { [proximityTrustVault] fingerprint in
                proximityTrustVault.peer(fingerprint: fingerprint)?.signingPublicKey
            }
        )
    }

    /// Files a report made from inside a session — a chat message's or a photo's sender — through
    /// the people report (``reportProximityPeer(signingPublicKey:reason:)``: recorded in the trust
    /// vault on this device, the person blocked), then re-folds the chat's view gates so their
    /// messages leave the transcript now rather than at the next message. The photo's own removal
    /// is its host's (``reportWallPhoto(_:reason:)``, or the review's answer).
    ///
    /// - Parameters:
    ///   - subject: Who is reported; never this device (its factories refuse that).
    ///   - reason: The reason the person chose.
    func reportSessionPeer(_ subject: PeerReportSubject, reason: ReportReason) {
        guard !subject.signingPublicKey.isEmpty,
              subject.signingPublicKey != meshNetworkManager.localSigningPublicKey else { return }
        reportProximityPeer(signingPublicKey: subject.signingPublicKey, reason: reason)
        meshFeatures.chat.refreshVisibleTranscript()
    }

    /// Report… on a photo in the friend wall's viewer: reports its sender (``reportSessionPeer(_:reason:)``)
    /// and deletes the photo from the wall (`MeshSessionPhotos.removeReportedPhoto(_:)`), so it is
    /// never shown again.
    ///
    /// A wall photo is never held, so the removal is the wall's own delete; a removal that did not
    /// apply is audited (a frozen token, no identity) rather than left silent.
    ///
    /// - Parameters:
    ///   - subject: The photo's sender, with the photo's id as its content.
    ///   - reason: The reason the person chose.
    func reportWallPhoto(_ subject: PeerReportSubject, reason: ReportReason) {
        guard case .photo(let photoID) = subject.content else { return }
        reportSessionPeer(subject, reason: reason)
        guard meshFeatures.photos.removeReportedPhoto(photoID) else {
            FernletAuditLog.log("sessionReport.wallPhotoNotRemoved")
            return
        }
    }
}
