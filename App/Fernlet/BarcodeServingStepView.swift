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

    /// R3: one entry appears per distinct scanned product, so the dictionary is explicitly capped —
    /// at the cap a newly scanned product evicts the lowest-sorted remembered key.
    static let maxRememberedBarcodes = 500

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
        guard let key = FoodBarcode.normalized(barcode), servings.isFinite, servings > 0 else { return }
        var map = defaults.dictionary(forKey: defaultsKey) ?? [:]
        if map[key] == nil, map.count >= maxRememberedBarcodes, let evicted = map.keys.sorted().first {
            map.removeValue(forKey: evicted)
        }
        map[key] = servings
        defaults.set(map, forKey: defaultsKey)
    }

    /// Forgets every remembered per-GTIN serving count. Invoked from the store's wipe paths
    /// (`resetAll` / `deleteAllData`) so this device-local sidecar is cleared alongside the other
    /// device-local ledgers (heart, closeness, moderation…) rather than surviving a "Delete all data".
    static func clearAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
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
    let foodItem: FoodItem
    /// Fires with the confirmed serving count when the user taps Log. The caller performs the actual
    /// log (barcode vs. label provenance) and dismisses the surrounding flow.
    var onLog: (Double) -> Void
    /// Fires when the user abandons the serving step (Cancel). The caller aborts the whole scan-log
    /// flow — clearing the pending food and exiting the scanner — rather than just closing this sheet,
    /// which would strand the user on a now-paused (frozen) viewfinder.
    var onCancel: () -> Void

    @State private var servings: Double

    init(
        foodItem: FoodItem,
        initialServings: Double,
        onCancel: @escaping () -> Void,
        onLog: @escaping (Double) -> Void
    ) {
        self.foodItem = foodItem
        self.onCancel = onCancel
        self.onLog = onLog
        // Preserve any positive prefill (a remembered half-serving stays 0.5); default to 1 only when
        // the caller has nothing useful to seed.
        _servings = State(initialValue: initialServings > 0 ? initialServings : 1)
    }

    /// The Stepper's upper bound, applied to the TYPED value too: `Macros.scaled(by:)` converts with
    /// `Int(Double)`, which traps on an out-of-range product — and `scaledMacros` is evaluated in
    /// `body` while the user is still typing (R5).
    private static let maxServings = 99.0

    /// Clamped, log-safe count (a typed-in negative or blank collapses to zero, which disables Log; a
    /// huge or non-finite entry is clamped to ``maxServings``).
    private var sanitizedServings: Double {
        guard servings.isFinite else { return 0 }
        return min(max(servings, 0), Self.maxServings)
    }

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

    /// Title block plus the inline Cancel affordance — the sheet's own header.
    private var header: some View {
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
            Button("Cancel") { onCancel() }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(Color.slate)
                .accessibilityIdentifier("barcodeServingCancel")
        }
    }

    /// The typeable servings field, its stepper, and the macros that scale with it.
    private var servingsField: some View {
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
                    // T2-8: an empty label makes VoiceOver announce "stepper" with no name and
                    // leaves Voice Control nothing to say. The word is given to the control and
                    // hidden from the layout, so the visual row is unchanged — the same pattern
                    // the age stepper in onboarding already uses.
                    Stepper("Servings", value: $servings, in: 0...99, step: 1)
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if let servingContext {
                        Text("One serving: \(servingContext)")
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.softTaupe)
                            .fernletWrappingText()
                    }

                    servingsField
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Log", disabled: sanitizedServings <= 0) {
                onLog(sanitizedServings)
            }
        }
        .background(Color.parchment)
        // Its own presentation, so it inherits neither the presenting sheet's tint nor its keyboard
        // accessory: the decimal pad here had no Done and floated over the Log bar.
        .tint(Color.moss)
        .keyboardDoneToolbar()
        .accessibilityIdentifier("barcodeServingStep")
    }
}
#endif
