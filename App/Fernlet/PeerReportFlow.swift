// PeerReportFlow.swift
// Fernlet
//
// App Review guideline 1.2 (owner decision 2026-10-15, "Report + a small filter", all on device):
// the app's ONE people-report flow. Friends & Blocks reports a person through it, and the live
// session reports the sender of a chat message or of a photo through the same sheet, with the same
// consequences — `FernletStore.reportProximityPeer`, which records the report in the trust vault on
// this device and blocks the person — and then offers the developer contact route that Safety &
// reporting publishes. There is no second moderation store: what a report records is what it
// recorded before, and it never leaves the phone.

import SwiftUI
import ProximityKit
import FernletConnections
import FernletDomainModel
import FernletSocial
import FernletUI

/// Who a report names and what prompted it: the subject of the app's one people-report flow
/// (``SwiftUICore/View/peerReportFlow(_:onReport:)``).
///
/// Built only through its factories, which carry the one rule that must never bend — a report
/// never names this device itself: ``message(_:)`` answers nil for an outgoing row, and
/// ``photo(_:senderKey:)`` needs a sender key that ``photoSenderKey(of:localSigningKey:localFingerprint:vaultKey:)``
/// refuses for this device's own photo. Presentation state only: never `Codable`, persisted or sent.
struct PeerReportSubject: Identifiable, Equatable {

    /// What the person is reporting the subject FOR, which the sheet names so they know what they
    /// are acting on.
    enum Content: Equatable {
        /// The person themself (Friends & Blocks).
        case person
        /// One of their session messages, named by a short excerpt of its opening (``excerpt(of:)``).
        case message(excerpt: String)
        /// One of their photos, by its local id — the photo the host removes after the report.
        case photo(id: UUID)
    }

    /// The presentation's identity: a new subject is a new sheet.
    let id = UUID()
    /// The signing key the report names — the key `FernletStore.reportProximityPeer` records and
    /// blocks. Never empty, and never this device's own.
    let signingPublicKey: Data
    /// The name the sheet shows, already made safe to render (never an identifier).
    let displayName: String
    /// What prompted the report.
    let content: Content

    /// The most characters of a reported message the sheet quotes: enough to say WHICH message, and
    /// no more of what may be objectionable text than that.
    static let excerptCharacters = 32

    /// A person from the trust vault (Friends & Blocks), or nil when the record carries no key.
    ///
    /// - Parameters:
    ///   - signingPublicKey: The record's signing key.
    ///   - displayName: The name the list shows for them.
    /// - Returns: The subject, or nil for an empty key.
    static func person(signingPublicKey: Data, displayName: String) -> PeerReportSubject? {
        guard !signingPublicKey.isEmpty else { return nil }
        return PeerReportSubject(signingPublicKey: signingPublicKey, displayName: displayName, content: .person)
    }

    /// The sender of a session chat message, or nil when the panel must not offer Report… on it:
    /// this device's own message, or a row whose author key the delivery did not carry
    /// (`SessionMessageStore.Message.canBeReported`).
    ///
    /// - Parameter message: One transcript row.
    /// - Returns: The subject, quoting a short excerpt of the message.
    static func message(_ message: SessionMessageStore.Message) -> PeerReportSubject? {
        guard message.canBeReported else { return nil }
        return PeerReportSubject(
            signingPublicKey: message.senderSigningPublicKey,
            displayName: message.senderDisplayName,
            content: .message(excerpt: excerpt(of: message.text))
        )
    }

    /// The sender of a session photo, or nil when there is no key to report (this device's own
    /// photo answers nil from ``photoSenderKey(of:localSigningKey:localFingerprint:vaultKey:)``).
    ///
    /// - Parameters:
    ///   - photo: The photo.
    ///   - senderKey: The key ``photoSenderKey(of:localSigningKey:localFingerprint:vaultKey:)`` resolved.
    /// - Returns: The subject, naming the photo's sender as the review tile does.
    static func photo(_ photo: FriendPhotoPayload, senderKey: Data?) -> PeerReportSubject? {
        guard let senderKey, !senderKey.isEmpty else { return nil }
        let name = PeerNameDisplay.shown(
            photo.senderName, fingerprint: photo.senderFingerprint, placeholder: .met, in: .fernlet
        )
        return PeerReportSubject(signingPublicKey: senderKey, displayName: name, content: .photo(id: photo.id))
    }

    /// The key a report of `photo` names: the signing key its routed delivery verified, else the
    /// trust vault's key for its fingerprint — and nil for this device's own photo (its key or its
    /// fingerprint is this device's), for a photo that names nobody, and for an empty key.
    ///
    /// - Parameters:
    ///   - photo: The photo.
    ///   - localSigningKey: This device's signing key.
    ///   - localFingerprint: This device's fingerprint.
    ///   - vaultKey: The trust vault's key for a fingerprint, if it holds one.
    /// - Returns: The sender's key, or nil when Report… must not be offered.
    static func photoSenderKey(
        of photo: FriendPhotoPayload, localSigningKey: Data, localFingerprint: String, vaultKey: (String) -> Data?
    ) -> Data? {
        let fingerprint = photo.senderFingerprint ?? ""
        guard fingerprint.isEmpty || !IdentityService.fingerprintsMatch(fingerprint, localFingerprint) else { return nil }
        let key = photo.senderSigningPublicKey.flatMap { $0.isEmpty ? nil : $0 }
            ?? (fingerprint.isEmpty ? nil : vaultKey(fingerprint))
        guard let key, !key.isEmpty, key != localSigningKey else { return nil }
        return key
    }

    /// The opening of a reported message, at most ``excerptCharacters`` characters, cut at a
    /// character boundary and marked with an ellipsis when cut — what the sheet quotes.
    ///
    /// - Parameter text: The message as the transcript shows it.
    /// - Returns: The excerpt, trimmed of surrounding whitespace.
    static func excerpt(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > excerptCharacters else { return trimmed }
        let cut = String(trimmed.prefix(excerptCharacters)).trimmingCharacters(in: .whitespaces)
        return cut + "…"
    }

    /// The sheet's title for one subject.
    var title: LocalizedStringKey {
        switch content {
        case .person: return "Report this person?"
        case .message: return "Report this message?"
        case .photo: return "Report this photo?"
        }
    }

    /// The sheet's explanation: who is reported, for what, and what reporting does on this phone.
    var explanation: LocalizedStringKey {
        switch content {
        case .person:
            return "Reporting \(displayName) blocks them and flags their shared content on your device."
        case .message(let excerpt):
            return "Reporting \(displayName) for the message “\(excerpt)” blocks them and hides their messages on this phone."
        case .photo:
            return "Reporting \(displayName) for this photo blocks them and deletes the photo from this phone."
        }
    }
}

extension View {
    /// Presents the app's one people-report flow whenever `subject` is set: the report sheet — one
    /// destructive button per ``ReportReason`` and Cancel — then, once a reason is chosen and
    /// `onReport` has filed it, a short "Reported" note that offers the developer contact route
    /// Safety & reporting publishes.
    ///
    /// - Parameters:
    ///   - subject: Who is being reported; the sheet is up while it is non-nil, and cleared by every
    ///     button.
    ///   - onReport: Files the report — the host calls `FernletStore`'s report funnel and removes
    ///     whatever prompted it.
    /// - Returns: The view, with the flow's two alerts attached.
    func peerReportFlow(
        _ subject: Binding<PeerReportSubject?>,
        onReport: @escaping (PeerReportSubject, ReportReason) -> Void
    ) -> some View {
        modifier(PeerReportFlowModifier(subject: subject, onReport: onReport))
    }
}

/// The two alerts of ``SwiftUICore/View/peerReportFlow(_:onReport:)``: the report sheet, and the
/// "Reported" note with the contact route.
///
/// Alerts, not a `confirmationDialog`: on iOS 26 the dialog renders as a popover that suppresses the
/// `.cancel`-role button, leaving a list of red reasons and no way out (Friends & Blocks' reason,
/// carried here with its sheet). The note hangs off a background view rather than beside the sheet,
/// so the second presentation never competes with the first one's dismissal on the same view.
private struct PeerReportFlowModifier: ViewModifier {
    @Binding var subject: PeerReportSubject?
    let onReport: (PeerReportSubject, ReportReason) -> Void
    /// The subject whose report just landed, while the "Reported" note is up.
    @State private var reported: PeerReportSubject?
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .alert(
                subject?.title ?? "Report this person?",
                isPresented: $subject.isPresent(),
                presenting: subject
            ) { shown in
                ForEach(ReportReason.allCases) { reason in
                    Button(reason.label, role: .destructive) { file(shown, reason: reason) }
                }
                Button("Cancel", role: .cancel) { subject = nil }
            } message: { shown in
                Text(shown.explanation)
            }
            .background { reportedNote }
    }

    /// The "Reported" note: who is now blocked, and the developer contact route.
    private var reportedNote: some View {
        Color.clear
            .alert("Reported", isPresented: $reported.isPresent(), presenting: reported) { _ in
                if let contact = SafetyReportingView.contactURL {
                    Button("Email the developer") {
                        reported = nil
                        openURL(contact)
                    }
                }
                Button("Done", role: .cancel) { reported = nil }
            } message: { shown in
                Text("\(shown.displayName) is blocked on this phone. If something needs more than a report, you can email the developer.")
            }
    }

    /// Files the report, closes the sheet, and raises the note.
    private func file(_ shown: PeerReportSubject, reason: ReportReason) {
        guard !shown.signingPublicKey.isEmpty else {
            subject = nil
            return
        }
        onReport(shown, reason)
        subject = nil
        reported = shown
    }
}
