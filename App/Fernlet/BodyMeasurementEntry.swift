//
//  BodyMeasurementEntry.swift
//  Fernlet
//
//  The display/entry boundary for body weight and height. Storage stays
//  imperial — `UserNutritionProfile` persists `weightPounds`/`heightInches`,
//  and those stay the stable units the way enum rawValues stay stable English
//  tokens — while what a person reads and steps follows their locale's
//  measurement system.
//
//  Before this, both editors offered pounds and feet/inches only, so a metric
//  user had no way to enter their own body: they had to convert by hand, and
//  the numbers feed the BMR that drives every nutrition target.
//

import SwiftUI
import FernletDomainModel

/// Converts stored imperial body measurements to and from the units a person actually reads.
///
/// Two editors — the onboarding personal-details step and Settings' ``ProfileEditor`` — show the
/// same two steppers, so the labels, ranges, steps, and conversions live here once rather than
/// being duplicated (and drifting) in both.
///
/// The system is read from `Locale.current.measurementSystem` at render time, so changing region
/// in iOS Settings changes the units without a relaunch. `.uk` counts as metric here: British
/// height is commonly feet/inches and weight commonly stones, but stones are not offered anywhere
/// in the app, and kilograms are what UK medical settings use.
enum BodyMeasurementEntry {

    /// Exact pounds per kilogram, matching `UserNutritionProfile.weightKilograms`'s divisor so a
    /// value shown in kilograms round-trips to the same stored pounds.
    static let poundsPerKilogram = 2.20462
    /// Exact centimetres per inch, matching `UserNutritionProfile.heightCentimeters`.
    static let centimetresPerInch = 2.54

    /// Whether this device wants pounds and feet/inches. Read per render, never cached.
    ///
    /// Every member below takes this as a defaulted parameter rather than reading the locale
    /// directly, so the conversions are testable without changing the process locale.
    static var usesImperial: Bool { Locale.current.measurementSystem == .us }

    // MARK: - Weight

    /// Stepper bounds in display units: 70–500 lb, or the same span rounded inward in kilograms so
    /// converting back can never leave `UserNutritionProfile`'s stored clamp.
    static func weightRange(imperial: Bool = usesImperial) -> ClosedRange<Double> {
        imperial ? 70...500 : 32...226
    }

    /// The stepper's label, e.g. `"Weight: 168 lb"` or `"Weight: 76 kg"`.
    static func weightLabel(pounds: Double, imperial: Bool = usesImperial) -> String {
        let value = imperial ? pounds : pounds / poundsPerKilogram
        return "Weight: \(Int(value.rounded())) \(imperial ? "lb" : "kg")"
    }

    /// A whole-number binding in display units over the stored pounds.
    ///
    /// `get` rounds so the stepper and the label always agree — a HealthKit import can leave a
    /// fractional 168.2 lb behind, and stepping the raw value made the label read 168 while the
    /// next tap produced 169.2.
    static func weightBinding(
        _ pounds: Binding<Double>,
        imperial: Bool = usesImperial
    ) -> Binding<Double> {
        Binding(
            get: { (imperial ? pounds.wrappedValue : pounds.wrappedValue / poundsPerKilogram).rounded() },
            set: { pounds.wrappedValue = imperial ? $0 : $0 * poundsPerKilogram }
        )
    }

    // MARK: - Height

    /// Stepper bounds in display units: 48–84 in, or the same span rounded inward in centimetres.
    static func heightRange(imperial: Bool = usesImperial) -> ClosedRange<Double> {
        imperial ? 48...84 : 122...213
    }

    /// The stepper's label, e.g. `"Height: 5 ft 9 in"` or `"Height: 175 cm"`.
    static func heightLabel(inches: Double, imperial: Bool = usesImperial) -> String {
        guard imperial else {
            return "Height: \(Int((inches * centimetresPerInch).rounded())) cm"
        }
        let total = Int(inches.rounded())
        return "Height: \(total / 12) ft \(total % 12) in"
    }

    /// A whole-number binding in display units over the stored inches. Rounds on `get` for the
    /// same reason ``weightBinding(_:)`` does.
    static func heightBinding(
        _ inches: Binding<Double>,
        imperial: Bool = usesImperial
    ) -> Binding<Double> {
        Binding(
            get: { (imperial ? inches.wrappedValue : inches.wrappedValue * centimetresPerInch).rounded() },
            set: { inches.wrappedValue = imperial ? $0 : $0 / centimetresPerInch }
        )
    }
}
