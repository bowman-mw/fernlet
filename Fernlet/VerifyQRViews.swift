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
/// Presented from the slot row's Verify menu in ``NearbySlotRow``. The sheet auto-dismisses when
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
struct VerifyQRScanSheet: View {
    /// Called with the scanned URL; the caller runs `beginQRVerification` and reports back.
    let onScanned: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var handedOff = false
    @State private var scannerUnavailable = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Scan their code")
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
                        onScanned(url)
                        dismiss()
                    },
                    onUnavailable: { scannerUnavailable = true }
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .frame(maxHeight: 380)
                .accessibilityIdentifier("friends.verifyQR.scanner")
                Text("Point at the code on your friend's screen.")
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
    }
}
