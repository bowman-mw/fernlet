import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
import Vision
import FernletDomainModel
import AppServices
import FoodCatalog
import FernletUI

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

extension FoodCaptureRouter {
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
                let observations = request.results ?? []
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
    /// The page Back returns to on the naming screen, already resolved; nil says "Back".
    var backTitle: String? = nil
    var onResolved: (FoodItem) -> Void

    var body: some View {
        Group {
            if let item = store.foodCatalog.item(forBarcode: payload) {
                // Known product — hand it straight back; the naming screen would be redundant.
                Color.clear
                    .onAppear { onResolved(item) }
            } else {
                BarcodeNotFoundView(store: store, barcode: payload, backTitle: backTitle, onCreated: onResolved)
            }
        }
        .foodSheetBackground()
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Analyzing state (b3-capture-veil, "Reading what you caught…")

/// The calm full-screen "analyzing…" veil shown while the auto-router reads what was captured
/// (`b3-capture-veil`, approved 2026-10-24): the page's parchment over the sheet, a framed moss disc
/// with pixel dots that take turns (still under Reduce Motion), "Analyzing" in Fraunces and one gentle
/// line. Never a clinical progress bar.
struct CaptureAnalyzingOverlay: View {
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        ZStack {
            (look?.page ?? Color.parchment).opacity(0.96).ignoresSafeArea()

            VStack(spacing: 14) {
                CaptureAnalyzingDots()
                    // "Analyzing" below is the label; the disc is the same fact drawn again.
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text("Analyzing")
                        .font(look == nil ? .fernlet(.header) : FernletFramedFont.sheetTitle)
                        .foregroundStyle(look?.text ?? Color.bark)
                    Text("Reading what you caught…")
                        .font(look == nil ? .fernlet(.body) : FernletFramedFont.body)
                        .foregroundStyle(look?.dim ?? Color.slate)
                        .multilineTextAlignment(.center)
                        .fernletWrappingText()
                }
            }
            .padding(28)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Analyzing your photo")
        .accessibilityIdentifier("captureAnalyzing")
        // T1-4: this full-screen veil blocks touches, so it is modal to VoiceOver and Switch Control
        // too; hiding the covered content is the caller's half.
        .accessibilityAddTraits(.isModal)
    }
}

/// The veil's spinner: a 96-pt sage disc in a 3-pt ink ring holding a 3 × 3 ring of pixel squares in
/// moss shades, the darkest walking round once a second. Reduce Motion holds it on one frame.
struct CaptureAnalyzingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fernletFramedLook) private var look

    /// The eight ring cells, clockwise from the top left, as (column, row).
    private static let ring: [(Int, Int)] = [(0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1)]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.125, paused: reduceMotion)) { timeline in
            let step = reduceMotion ? 0 : Int(timeline.date.timeIntervalSinceReferenceDate * 8) % Self.ring.count
            ZStack {
                Circle().fill(look?.sage ?? Color.moss.opacity(0.12))
                Circle().strokeBorder(look?.ink ?? Color.clear, lineWidth: 3)
                cells(step: step)
            }
            .frame(width: 96, height: 96)
        }
    }

    /// The eight cells, each a little lighter the further it trails the lead.
    private func cells(step: Int) -> some View {
        ZStack {
            ForEach(Self.ring.indices, id: \.self) { index in
                let cell = Self.ring[index]
                let behind = (step - index + Self.ring.count) % Self.ring.count
                Rectangle()
                    .fill(WorldPalette.moss.opacity(1 - Double(behind) * 0.1))
                    .frame(width: 13, height: 13)
                    .offset(x: CGFloat(cell.0 - 1) * 19, y: CGFloat(cell.1 - 1) * 19)
            }
        }
    }
}

// MARK: - Fallback chooser (b3-capture-chooser draft 2, "Nothing to read here")

/// The fallback when a photo had no barcode or label to read (`b3-capture-chooser` draft 2; owner,
/// 2026-10-24: "for the barcode and label, it should detect automatically. This should be a back up
/// screen at worst"). Barcodes and labels are read without asking, so this only asks what to do with a
/// photo that reads as neither: log it as a meal photo, take it again, or type it instead.
///
/// The meal-photo row is disabled and says why (never silently missing) when on-device photo
/// recognition is off in Settings.
struct CaptureChooserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fernletFramedLook) private var look
    let image: UIImage
    var aiEnabled: Bool
    var onMeal: () -> Void
    var onRetake: () -> Void
    var onTypeInstead: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Nothing to read here", onCancel: onTypeInstead)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(look?.ink ?? Color.clear, lineWidth: 2))
                        .accessibilityIgnoresInvertColors()
                        .accessibilityHidden(true)
                    Text("Fernlet didn't find a barcode or a nutrition label in this photo.")
                        .font(look == nil ? .fernlet(.body) : FernletFramedFont.body)
                        .foregroundStyle(look?.dim ?? Color.slate)
                        .fernletWrappingText()
                    rows
                    typeInsteadButton
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
            }
        }
        .foodSheetBackground()
    }

    private var rows: some View {
        VStack(spacing: 12) {
            chooserRow(
                title: "Log it as a meal photo",
                subtitle: aiEnabled
                    ? "let Fernlet guess what's on the plate"
                    : "photo recognition is off in Settings — barcode and label still work",
                sprite: WorldSprites.onigiri,
                action: onMeal,
                disabled: !aiEnabled
            )
            chooserRow(title: "Take it again", subtitle: "closer, with more light", sprite: FoodSprites.camera,
                       action: onRetake)
        }
    }

    private var typeInsteadButton: some View {
        Button(action: onTypeInstead) {
            Text("Type it instead")
                .font(look == nil ? .fernlet(.label) : FernletFramedFont.button)
                .foregroundStyle(look?.link ?? Color.moss)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("captureChooserTypeInstead")
    }

    /// One way on: a framed icon tile, the title and its line, and the pixel chevron, on a framed card.
    private func chooserRow(title: LocalizedStringKey, subtitle: LocalizedStringKey, sprite: WorldSprite,
                            action: @escaping () -> Void, disabled: Bool = false) -> some View {
        Button(action: action) {
            FernletCard {
                HStack(spacing: 14) {
                    FernletIconTile(size: 44) { WorldSpriteView(sprite: sprite, scale: 2) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(FoodFont.rowName)
                            .foregroundStyle(look?.text ?? Color.bark)
                        Text(subtitle)
                            .font(FernletFramedFont.rowDetail)
                            .foregroundStyle(look?.dim ?? Color.slate)
                            .fernletWrappingText()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !disabled { FernletIcon(.chevron, scale: 2) }
                }
            }
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

#endif
