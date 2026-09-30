import Foundation

/// Writes an ingredient's quantity or a food's serving size for a row that also shows
/// ``MacroGramEntry`` grams ("1,5 cup · P3,4g"), so both halves of the line use the locale's decimal
/// separator.
///
/// Up to two decimal places (a quarter cup reads "0.25", a third "0.33"), half away from zero, no
/// trailing zeros, and never grouped — the same shape as ``MacroGramEntry/display(_:locale:)``, one
/// place wider because a quantity is not stored at tenths. It replaces `String(format: "%g")`, which
/// always writes ".", so an es/fr/de row no longer mixes "1.5" with "3,4".
///
/// Display only: a quantity that is persisted, sent on a wire or shared as text keeps its POSIX form.
/// Pure and stateless: the format style is a value built per call, not a shared `NumberFormatter`.
public nonisolated enum RecipeQuantityDisplay {
    /// `quantity` as a row shows it in `locale`. A non-finite value (never a real quantity) reads "0".
    public static func display(_ quantity: Double, locale: Locale = .current) -> String {
        guard quantity.isFinite else { return "0" }
        let style = FloatingPointFormatStyle<Double>(locale: locale)
            .precision(.fractionLength(0...2))
            .grouping(.never)
            .rounded(rule: .toNearestOrAwayFromZero)
        return quantity.formatted(style)
    }
}
