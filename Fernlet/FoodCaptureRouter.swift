import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
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
        // 1) Barcode first — unambiguous when present.
        if let payload = try? await barcodeDetector.payload(in: image),
           payload.isEmpty == false {
            return .barcode(payload: payload)
        }

        // 2) Nutrition label — parse with the existing OCR scanner and gauge confidence by field count.
        let label = try? await NutritionLabelScanner.scanAll(image: image).primary
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
