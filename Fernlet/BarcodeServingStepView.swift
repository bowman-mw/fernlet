import Foundation
import FernletDomainModel

// MARK: - Per-GTIN last-used serving memory

/// Device-local memory of the last serving count logged for a scanned product, keyed by normalized
/// GTIN, so the quick serving step can prefill the amount the user chose last time.
///
/// Deliberately a `UserDefaults` sidecar and NOT a `FernletSettings` field: the synced blob is
/// strip-migrated on decode (the blob-strip landmine in NutritionModels.swift) and rides the
/// seal/sync path. This is a small, non-sensitive, device-local convenience that must stay off that
/// path — it never needs to sync and must not widen the synced surface. Stored as one bounded
/// dictionary under a single key so it stays easy to inspect and clear.
enum BarcodeServingMemory {
    static let defaultsKey = "fernlet.barcodeLastServings.v1"

    /// Last serving count recorded for `barcode`, or `nil` when the code is unrecognizable (e.g. the
    /// empty barcode of a label-scanned item) or nothing has been logged for it yet. Only positive
    /// counts are returned.
    static func lastServings(for barcode: String?, defaults: UserDefaults = .standard) -> Double? {
        guard let key = FoodBarcode.normalized(barcode) else { return nil }
        guard let stored = defaults.dictionary(forKey: defaultsKey)?[key] as? NSNumber else { return nil }
        let value = stored.doubleValue
        return value > 0 ? value : nil
    }

    /// Records `servings` as the last count for `barcode`. No-ops for unrecognizable codes or a
    /// non-positive count (those carry no useful prefill).
    static func setLastServings(_ servings: Double, for barcode: String?, defaults: UserDefaults = .standard) {
        guard let key = FoodBarcode.normalized(barcode), servings > 0 else { return }
        var map = defaults.dictionary(forKey: defaultsKey) ?? [:]
        map[key] = servings
        defaults.set(map, forKey: defaultsKey)
    }
}

#if canImport(UIKit)
import SwiftUI
import FernletUI

// MARK: - Quick serving step

/// The compact "how many servings?" confirmation shown after a barcode/label resolve, before the
/// meal is logged. Prefilled with the last count used for this product so accepting the prefill is a
/// single tap on Log. The macro preview scales live with the count so the impact is visible.
struct BarcodeServingStepView: View {
    @Environment(\.dismiss) private var dismiss

    let foodItem: FoodItem
    /// Fires with the confirmed serving count when the user taps Log. The caller performs the actual
    /// log (barcode vs. label provenance) and dismisses the surrounding flow.
    var onLog: (Double) -> Void

    @State private var servings: Double

    init(foodItem: FoodItem, initialServings: Double, onLog: @escaping (Double) -> Void) {
        self.foodItem = foodItem
        self.onLog = onLog
        // Preserve any positive prefill (a remembered half-serving stays 0.5); default to 1 only when
        // the caller has nothing useful to seed.
        _servings = State(initialValue: initialServings > 0 ? initialServings : 1)
    }

    /// Clamped, log-safe count (a typed-in negative or blank collapses to zero, which disables Log).
    private var sanitizedServings: Double { max(servings, 0) }

    private var scaledMacros: Macros { foodItem.macros.scaled(by: sanitizedServings) }

    /// One-serving reference line for context (e.g. "2 cookies (30g)"), falling back to the item's
    /// serving size/unit when no descriptive string was captured.
    private var servingContext: String? {
        if let description = foodItem.servingDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           description.isEmpty == false {
            return description
        }
        guard foodItem.servingSize > 0 else { return nil }
        return "\(String(format: "%g", foodItem.servingSize)) \(foodItem.servingUnit)"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("How many servings?")
                                .font(.fernlet(.header))
                                .foregroundStyle(Color.bark)
                                .fernletWrappingText()
                            Text(foodItem.name)
                                .font(.fernlet(.body))
                                .foregroundStyle(Color.slate)
                                .fernletWrappingText()
                        }
                        Spacer(minLength: 12)
                        Button("Cancel") { dismiss() }
                            .buttonStyle(.plain)
                            .font(.fernlet(.label))
                            .foregroundStyle(Color.slate)
                            .accessibilityIdentifier("barcodeServingCancel")
                    }

                    if let servingContext {
                        Text("One serving: \(servingContext)")
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.softTaupe)
                            .fernletWrappingText()
                    }

                    SheetField("Servings") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                // Typeable so fractional amounts (half a bar, a serving and a half) log honestly.
                                TextField("Servings", value: $servings, format: .number.precision(.fractionLength(0...2)))
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.leading)
                                    .textContentType(.none)
                                    .frame(maxWidth: 90)
                                    .font(.fernlet(.displayMedium))
                                    .foregroundStyle(Color.bark)
                                    .accessibilityIdentifier("barcodeServingValue")
                                Spacer()
                                Stepper("", value: $servings, in: 0...99, step: 1)
                                    .labelsHidden()
                                    .accessibilityIdentifier("barcodeServingStepper")
                            }
                            Text("P \(scaledMacros.protein)g   C \(scaledMacros.carbs)g   F \(scaledMacros.fat)g")
                                .font(.fernlet(.stat))
                                .foregroundStyle(Color.moss)
                        }
                        .padding(14)
                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Log", disabled: sanitizedServings <= 0) {
                onLog(sanitizedServings)
            }
        }
        .background(Color.parchment)
        .accessibilityIdentifier("barcodeServingStep")
    }
}
#endif
