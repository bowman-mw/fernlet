// VerifyQRViews.swift
// Fernlet
//
// QR verification ceremony UI (bitchat adoptions Increment 4,
// Docs/Plan-Bitchat-Adoptions-2026-07-25.md): the display sheet renders this device's signed
// `fernlet://verify` QR; the scan sheet reuses the food viewfinder with `.qr` symbology. Both
// are presented from the ConnectView slot row while a peer is `awaitingManualCommit` — the
// non-UWB fallback that used to be a bare "tap to confirm" is now upgradeable to ceremony grade.

import SwiftUI
import Vision
import VisionKit
import FernletUI
import CoreImage.CIFilterBuiltins

/// Namespace for rendering a string into a scannable QR `UIImage` via CoreImage.
///
/// Used by ``VerifyQRDisplaySheet`` to draw this device's signed `fernlet://verify` URL; kept as
/// a caseless enum because it is a pure function with no state.
enum QRCodeRenderer {
    /// Sharp, screen-sized QR (medium error correction; nearest-neighbor upscale so modules stay
    /// crisp). Nil only when CoreImage fails outright.
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// "Show my code": the signed, 5-minute-fresh verify QR for the peer to scan.
///
/// Presented from the slot row's Verify menu in `NearbySlotRow`. The sheet auto-dismisses when
/// the app leaves the foreground — the ceremony is an in-person, eyes-on-both-screens moment —
/// and every dismissal path routes through the caller's `onDismiss` so the mesh manager stops
/// honoring challenges for the displayed QR.
struct VerifyQRDisplaySheet: View {
    let url: URL?
    let peerName: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 20) {
            Text("Verify with \(peerName)")
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.bark)
            if let url, let image = QRCodeRenderer.image(for: url.absoluteString) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260)
                    .padding(14)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                    // T2-10: Smart Invert would flip the black-on-white modules to white-on-black
                    // and no scanner would read them. A QR is data, not decoration.
                    .accessibilityIgnoresInvertColors()
                    // T2-20: the image was silent, so VoiceOver skipped straight past the only
                    // thing on the sheet that matters. The protocol commits the *displayer*'s side
                    // (`MeshNetworkManager.beginQRVerification`), so "I hold up my phone, you scan
                    // it" is a fully supported ceremony for a blind user — it just has to be
                    // narratable.
                    .accessibilityLabel("Your verification code, as a QR code for \(peerName) to scan")
                    .accessibilityIdentifier("friends.verifyQR.code")
                Text("Have \(peerName) scan this code. It proves this phone really holds your Fernlet identity — the code expires after a few minutes.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .multilineTextAlignment(.center)
                    .fernletWrappingText()
            } else {
                Text("Couldn't create a verification code just now.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
            }
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(Color.moss)
                .accessibilityIdentifier("friends.verifyQR.done")
        }
        .padding(24)
        .presentationDetents([.medium])
        .presentationBackground(Color.parchment)
        // The ceremony is an in-person, eyes-on-both-screens moment: once the app leaves the
        // foreground nobody is running it, so end the display (the caller's `onDismiss` then tells
        // the mesh manager to stop honoring challenges for this QR). `.background` rather than
        // `.inactive` — Control Center and the notification shade produce `.inactive` without the
        // user ever leaving the ceremony.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { dismiss() }
        }
    }
}

/// "Scan their code": the same VisionKit viewfinder the barcode scanner uses, QR-only.
///
/// Hands the first parseable URL to `onScanned` exactly once (`handedOff` latches so a second
/// frame can't double-fire) and dismisses itself; the caller reports success or failure back
/// through the row's own alert after the sheet is gone. Falls back to guidance copy when the
/// scanner is unavailable (camera access off).
///
/// Acquisition is reported non-visually as well (accessibility review T2-20): a success haptic on
/// the `handedOff` latch plus a `FernletAnnouncer` announcement of the *event*. Neither carries the
/// scanned payload — this is a security ceremony and an announcement is audible to the room.
struct VerifyQRScanSheet: View {
    /// Called with the scanned URL; the caller runs `beginQRVerification` and reports back.
    let onScanned: (URL) -> Void
    /// Sheet heading. Defaulted to the friend-verification wording so the original call sites are
    /// unchanged; the duress recovery ceremony (P7) passes its own, because "their code" names a
    /// friend and that ceremony is between two phones the same person owns.
    var title: String = "Scan their code"
    /// The line under the viewfinder, defaulted for the same reason.
    var prompt: String = "Point at the code on your friend's screen."
    /// What VoiceOver says when it lands on the live viewfinder (T2-20).
    ///
    /// Deliberately a *separate* `LocalizedStringKey` rather than a reuse of ``prompt``: `prompt`
    /// is `String`-typed, so it is frozen English (the T2-1 class) and would carry that freeze into
    /// speech. Aiming instructions are also not the same sentence for eyes and for ears — a sighted
    /// user has already seen the viewfinder and only needs to know *what* to aim at, while a
    /// VoiceOver user needs to be told there is a camera running here at all.
    var scannerLabel: LocalizedStringKey = "Camera viewfinder. Point the camera at the code on your friend's screen."
    @Environment(\.dismiss) private var dismiss
    @State private var handedOff = false
    @State private var scannerUnavailable = false

    var body: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.bark)
            if scannerUnavailable {
                Text("The camera isn't available — check camera access for Fernlet in Settings, or use the plain Connect button instead.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .multilineTextAlignment(.center)
                    .fernletWrappingText()
                    .padding(.horizontal, 20)
            } else {
                BarcodeDataScannerView(
                    paused: handedOff,
                    symbologies: [.qr],
                    onPayload: { payload in
                        guard !handedOff, let url = URL(string: payload) else { return }
                        handedOff = true
                        // T2-20: acquisition is otherwise entirely visual — the viewfinder simply
                        // vanishes. Announce the EVENT, never the payload: this URL carries the
                        // peer's signing key and a fingerprint, and an announcement is spoken out
                        // loud into whatever room the ceremony is happening in.
                        FernletAnnouncer.system.announce(.success, "Code captured")
                        onScanned(url)
                        dismiss()
                    },
                    onUnavailable: { scannerUnavailable = true }
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .frame(maxHeight: 380)
                // The representable hosts a live `DataScannerViewController` with no accessible
                // content of its own, so without this the viewfinder is a hole in the tree that
                // VoiceOver walks straight over.
                .accessibilityElement()
                .accessibilityLabel(scannerLabel)
                .accessibilityIdentifier("friends.verifyQR.scanner")
                Text(prompt)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
            }
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(Color.slate)
                .accessibilityIdentifier("friends.verifyQR.cancel")
        }
        .padding(20)
        .presentationDetents([.large])
        .presentationBackground(Color.parchment)
        // The second half of acquisition feedback (T2-20). `handedOff` is a one-way latch, so this
        // fires exactly once per sheet; it is on the root rather than the viewfinder because the
        // viewfinder is inside the `else` branch and leaves the tree the instant the latch flips.
        .sensoryFeedback(.success, trigger: handedOff)
    }
}
