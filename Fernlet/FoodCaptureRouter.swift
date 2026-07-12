import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
import Vision
import FernletDomainModel
import AppServices
import FoodCatalog

// MARK: - Auto-routing for the unified "Capture" front door
//
// One prominent Capture button opens the camera; when the user captures a still photo we auto-detect
// what it is and route to the EXISTING flow (Food Capture mockup §2b–2e + Barcode Handoff):
//
//   1) barcode  — Vision `VNDetectBarcodesRequest` (via `BarcodeScanner`) finds a product barcode →
//                 the existing barcode → product-lookup path (`BarcodeResolveFlowView`/lookup).
//   2) label    — the existing `NutritionLabelScanner` OCR parses a nutrition-facts label with a
//                 reasonable field count → the existing label-scan path.
//   3) meal     — otherwise it's a meal photo → the existing meal-photo / AI meal-estimation path.
//
// Detection order mirrors real-world confidence: a barcode is unambiguous, a parsed label is strong,
// a meal photo is the graceful default. When the strongest reading is weak/ambiguous we hand back
// `.ambiguous` so the caller can present a gentle chooser instead of guessing. This ADDS a front
// door — every existing manual entry point (Scan, label scan, meal photo, import) stays intact and
// is exactly what the chooser routes to.

/// Where a captured photo should be handed off. Each case maps onto an already-shipped flow.
enum FoodCaptureRoute: Equatable {
    /// A product barcode was read — follow the barcode → product-lookup path with this payload.
    case barcode(payload: String)
    /// A nutrition-facts label parsed with reasonable confidence — follow the label-scan path.
    case label(NutritionLabelResult)
    /// Nothing structured was found — treat it as a meal photo (AI meal-estimation path).
    case meal
    /// Two or more readings looked plausible, or everything was weak — let the user disambiguate.
    /// `label` carries the best-effort parse (if any) so "Read the label" can prefill.
    case ambiguous(label: NutritionLabelResult?)
}

/// Runs the three detectors in confidence order over a captured still image and picks a route.
/// Pure/testable: the detectors are injected behind the same seams the manual flows already use
/// (`BarcodePayloadDetecting`, `NutritionLabelScanner`), so this reimplements no lookup or parsing.
struct FoodCaptureRouter {
    var barcodeDetector: any BarcodePayloadDetecting = VisionBarcodeDetector()

    /// A label needs at least this many recognized fields to be routed confidently as a label rather
    /// than dropped into the chooser. Both this floor and `NutritionLabelCameraSheet`'s "< 3 fields =
    /// show tips" weak-scan heuristic now read the SAME `NutritionLabelResult.recognizedFieldCount`
    /// (calories included), so a stray "protein 8g" on a meal photo doesn't hijack the meal path.
    static let labelConfidenceFieldFloor = 3

    func route(for image: UIImage) async -> FoodCaptureRoute {
        // 1) Barcode first — unambiguous when present. Run on the ORIGINAL full-resolution image:
        //    retail barcodes decode off fine bar spacing that downscaling would smear.
        if let payload = try? await barcodeDetector.payload(in: image),
           payload.isEmpty == false {
            return .barcode(payload: payload)
        }

        // 2) Nutrition label — parse with the existing OCR scanner and gauge confidence by field count.
        //    The scanner's pipeline (document segmentation + perspective correction + noise reduction +
        //    `.accurate` recognition) is legible far below a 12MP camera frame, so feed it a downscaled
        //    copy. And before paying for that heavy pipeline at all, run a cheap `.fast` text-presence
        //    probe: an ordinary meal photo carries no text, so route it straight to `.meal` rather than
        //    OCR the whole plate only to discover there's no label (the perceived sluggishness fixed here).
        let scanImage = Self.downscaledForOCR(image)
        guard await Self.imageProbablyContainsText(scanImage) else {
            return .meal
        }

        let label = try? await NutritionLabelScanner.scanAll(image: scanImage).primary
        if let label {
            let fields = label.recognizedFieldCount
            if fields >= Self.labelConfidenceFieldFloor {
                return .label(label)
            }
            // A weak-but-nonzero label reading is exactly the ambiguous case: it might be a label shot
            // in poor light, or a meal photo with a stray number. Let the user choose, prefilled.
            if fields > 0 {
                return .ambiguous(label: label)
            }
        }

        // 3) Meal photo — the graceful default.
        return .meal
    }
}

// MARK: - Cheap image prep for the label OCR stage

private extension FoodCaptureRouter {
    /// Longest edge (in pixels) we hand the label OCR pipeline. Nutrition-facts text stays legible far
    /// below a full 12MP camera frame, and capping the long edge keeps document segmentation +
    /// perspective correction + `.accurate` recognition off the full-resolution image — the sluggish
    /// part on the iPhone-11 floor.
    static let ocrMaxDimension: CGFloat = 1600

    /// A downscaled, orientation-normalized copy of `image` for the label OCR stage. Never upscales — an
    /// image already within the cap is returned unchanged. `UIGraphicsImageRenderer` (scale 1) bakes the
    /// display orientation into the pixels so text is upright for Vision, which reads `cgImage` directly
    /// and would otherwise ignore `UIImage.imageOrientation`.
    static func downscaledForOCR(_ image: UIImage) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longEdge = max(pixelWidth, pixelHeight)
        guard longEdge > ocrMaxDimension else { return image }  // never upscale

        let ratio = ocrMaxDimension / longEdge
        let target = CGSize(width: (pixelWidth * ratio).rounded(),
                            height: (pixelHeight * ratio).rounded())
        guard target.width >= 1, target.height >= 1 else { return image }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1        // output pixels == `target`; the default screen scale would re-inflate it
        format.opaque = true    // camera captures have no alpha; skip it
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// A fast, low-accuracy "is there any text here at all?" probe. An ordinary meal photo has none, so
    /// the caller can skip the full accurate label pipeline and route straight to `.meal`. Uses only the
    /// cheap `.fast` recognition level with no language correction and no image preprocessing — a small
    /// fraction of `NutritionLabelScanner.scanAll`'s cost. Fails OPEN: any Vision error (or a missing
    /// `cgImage`) returns `true`, so a real label is never dropped on a probe failure — it falls through
    /// to the accurate scan exactly as before. Only a genuine zero-text reading short-circuits, which is
    /// the same route (`.meal`) the accurate scan would reach when it finds nothing.
    static func imageProbablyContainsText(_ image: UIImage) async -> Bool {
        guard let cgImage = image.cgImage else { return true }
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                return observations.contains { $0.topCandidates(1).first?.string.isEmpty == false }
            } catch {
                return true  // Unsure → let the accurate scan decide (preserves prior routing).
            }
        }.value
    }
}

// MARK: - Resolve an already-scanned barcode payload

/// Resolves a barcode payload that the auto-router already read from a still photo — skipping the live
/// scanner entirely — through the EXISTING resolution path: catalog hit resolves instantly, otherwise
/// the gentle `BarcodeNotFoundView` "name it & remember" handoff. Mirrors `BarcodeResolveFlowView`
/// (which owns the live-scan case); this is its pre-scanned twin so the auto-router reuses, rather
/// than duplicates, the not-found flow. Calls `onResolved` exactly once.
struct BarcodePayloadResolveView: View {
    var store: FernletStore
    let payload: String
    var onResolved: (FoodItem) -> Void

    var body: some View {
        Group {
            if let item = store.foodCatalog.item(forBarcode: payload) {
                // Known product — hand it straight back; the naming screen would be redundant.
                Color.parchment
                    .onAppear { onResolved(item) }
            } else {
                BarcodeNotFoundView(store: store, barcode: payload, onCreated: onResolved)
            }
        }
        .background(Color.parchment)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Analyzing state (mockup §2b "Reading what you caught…")

/// The calm full-screen "analyzing…" veil shown while the auto-router detects what was captured. A
/// soft parchment scrim with a moss spinner and one gentle line — never a clinical progress bar.
struct CaptureAnalyzingOverlay: View {
    var body: some View {
        ZStack {
            Color.parchment.opacity(0.94).ignoresSafeArea()

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.moss.opacity(0.12))
                        .frame(width: 76, height: 76)
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.moss)
                }

                VStack(spacing: 6) {
                    Text("Analyzing")
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
                    Text("Reading what you caught…")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate)
                        .multilineTextAlignment(.center)
                        .fernletWrappingText()
                }
            }
            .padding(28)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Analyzing your photo")
        .accessibilityIdentifier("captureAnalyzing")
    }
}

// MARK: - Gentle chooser (mockup §2d "What did you catch?")

/// Shown when detection is ambiguous/low-confidence: three calm targets that route to the SAME
/// existing flows the auto-router would (barcode lookup · nutrition label · meal photo), plus a
/// "Type it instead" escape hatch. The meal branch is disabled and clearly named — never silently
/// missing — when on-device photo recognition is off (mockup §2d "AI off · meal branch unavailable").
struct CaptureChooserSheet: View {
    @Environment(\.dismiss) private var dismiss
    var aiEnabled: Bool
    var onBarcode: () -> Void
    var onLabel: () -> Void
    var onMeal: () -> Void
    var onTypeInstead: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What did you catch?")
                    .font(.fernlet(.header))
                    .foregroundStyle(Color.bark)
                Text("A couple of readings looked close. Pick the one that fits.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }

            VStack(spacing: 10) {
                chooserRow(
                    title: "Look up the barcode",
                    subtitle: "find the product by its code",
                    icon: "barcode.viewfinder",
                    action: onBarcode
                )
                chooserRow(
                    title: "Read the label",
                    subtitle: "pull the macros from a nutrition-facts label",
                    icon: "doc.viewfinder",
                    action: onLabel
                )
                chooserRow(
                    title: "It's a meal photo",
                    subtitle: aiEnabled
                        ? "let Fernlet guess what's on the plate"
                        : "photo recognition is off in Settings — barcode and label still work",
                    icon: "fork.knife",
                    action: onMeal,
                    disabled: !aiEnabled
                )
            }

            Button {
                onTypeInstead()
            } label: {
                Text("Type it instead")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.moss)
                    .frame(maxWidth: .infinity)
                    .padding(14)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("captureChooserTypeInstead")

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.parchment)
    }

    private func chooserRow(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void,
        disabled: Bool = false
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.moss.opacity(0.14))
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Color.moss)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                    Text(subtitle)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !disabled {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.softTaupe)
                }
            }
            .padding(16)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: FernletMetrics.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: FernletMetrics.radiusMd).stroke(Color.bark.opacity(0.08), lineWidth: 1))
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

#endif
