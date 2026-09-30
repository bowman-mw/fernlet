import Foundation

/// Parses and displays the grams a person types into a macro field ("3.4 g protein").
///
/// One rule for both directions, so a value always survives the trip from field to model and back:
/// ``parse(_:in:allowsDecimals:locale:)`` reads what was typed and ``display(_:locale:)`` writes what
/// the field is prefilled with and what the row shows. Both work in tenths of a gram
/// (``quantized(_:)``), so what is stored is exactly what is shown.
///
/// Separators follow ``LocaleTolerantNumber``: `.` and `,` are both accepted, and the locale only
/// settles a genuinely ambiguous spelling ("1,500"). The display writes the locale's own decimal
/// separator and never groups, so its output re-parses to the same value in that locale.
///
/// Pure and stateless: the format style is a value built per call, not a shared `NumberFormatter`.
public nonisolated enum MacroGramEntry {
    /// Tenths of a gram: the precision a typed value is stored and shown at.
    public static let stepsPerGram = 10.0

    /// The grams `text` spells, rounded to a tenth, or `nil` when it is not a value `range` accepts.
    ///
    /// Rejects empty text, a leading minus (including "-0"), anything ``LocaleTolerantNumber``
    /// refuses ("3.4.5", "1e3", "inf", "12g", over-long input), and anything outside `range` after
    /// rounding. With `allowsDecimals` false only a whole number is accepted, so a whole-gram field
    /// never silently rounds "3.4" to 3.
    public static func parse(
        _ text: String,
        in range: ClosedRange<Double>,
        allowsDecimals: Bool = true,
        locale: Locale = .current
    ) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return nil }
        let candidate = allowsDecimals
            ? LocaleTolerantNumber.double(from: trimmed, locale: locale)
            : LocaleTolerantNumber.int(from: trimmed, locale: locale).map(Double.init)
        guard let parsed = candidate else { return nil }
        let grams = quantized(parsed)
        guard range.contains(grams) else { return nil }
        return grams
    }

    /// `grams` rounded to the nearest tenth, half away from zero; non-finite becomes 0 and `-0` becomes
    /// `+0`, so neither can ever be displayed.
    public static func quantized(_ grams: Double) -> Double {
        guard grams.isFinite else { return 0 }
        let tenths = (grams * stepsPerGram).rounded(.toNearestOrAwayFromZero) / stepsPerGram
        guard tenths.isFinite, tenths != 0 else { return 0 }
        return tenths
    }

    /// `grams` as a field shows it: at most one decimal place in `locale`'s separator, no grouping,
    /// and no ".0" on a whole number ("3", "3.4", "3,4").
    public static func display(_ grams: Double, locale: Locale = .current) -> String {
        let style = FloatingPointFormatStyle<Double>(locale: locale)
            .precision(.fractionLength(0...1))
            .grouping(.never)
            .rounded(rule: .toNearestOrAwayFromZero)
        return quantized(grams).formatted(style)
    }
}
