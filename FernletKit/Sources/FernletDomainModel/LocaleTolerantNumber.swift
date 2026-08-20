// LocaleTolerantNumber.swift
// FernletDomainModel
//
// The one parser for numbers a person typed. iOS shows `.decimalPad` with the
// *locale's* decimal separator, so a Spanish, French, or German user types
// "2,5" — and bare `Double("2,5")` returns nil, silently dropping the value.
//
// Home: FernletDomainModel rather than FernletFoundation. Every consumer of
// this helper (the app target, AppServices, and AIProviders' food-text
// quantity parser) already depends on FernletDomainModel, while AIProviders
// deliberately does NOT depend on FernletFoundation — routing it there to
// reach this parser would also hand it KeychainHelpers/StoragePreferences.
// This is the only node reachable from every caller without widening a wall.

import Foundation

/// Parses numbers out of free text a person typed, accepting either decimal separator.
///
/// Every free-text numeric field in Fernlet — food quantities, workout distance/RPE, sleep hours,
/// basal temperature — reaches its model as a `String` typed on a `.decimalPad`, whose separator
/// key follows the device locale (`,` in es/fr/de, `.` in en-US). Bare `Double(_:)` accepts only
/// `.`, so every such field silently discarded a metric user's input; this type is the single
/// replacement for those call sites.
///
/// Deliberately **not** a `NumberFormatter`: a formatter locked to `Locale.current` rejects the
/// other separator outright, which breaks pasted values and anyone typing the way their previous
/// phone taught them. The rule here is "accept both, and only consult the locale when the string
/// is genuinely ambiguous" (see ``double(from:locale:)``).
///
/// The parser also guards the input charset, so the hex, infinity, and NaN spellings `Double(_:)`
/// accepts (`"0x1p3"`, `"inf"`, `"nan"`) can never reach a clinical sample or a macro total.
/// All members are static; the enum is `nonisolated` and safe to call from any executor.
public nonisolated enum LocaleTolerantNumber {

    /// Longest input accepted, in characters — every parse loop below is bounded by it (Rule 2).
    ///
    /// Far above any real typed quantity (a body weight is 3 digits, a macro total 4) and far
    /// below the length at which separator scanning would cost anything.
    public static let maxInputCharacters = 32

    // MARK: - Public API

    /// Parses a decimal number a person typed, accepting `.` or `,` as the decimal separator.
    ///
    /// Ambiguity is resolved by structure first and locale second:
    /// - **Both separators present** — the rightmost is the decimal separator, the other is
    ///   grouping. Handles `"1,234.5"` (en) and `"1.234,5"` (de) with no locale check at all.
    /// - **One separator, repeated** — grouping (`"1.234.567"` → 1234567).
    /// - **One separator, not followed by exactly three digits** — decimal (`"2,5"` → 2.5).
    /// - **One separator followed by exactly three digits** — genuinely ambiguous (`"1,500"` is
    ///   1500 in en-US and 1.5 in de), so `locale`'s decimal separator decides.
    ///
    /// Returns `nil` for empty input, anything carrying a character other than digits, separators,
    /// and a single leading sign, and any result that is not finite.
    public static func double(from raw: String, locale: Locale = .current) -> Double? {
        guard let canonical = canonicalized(raw, locale: locale) else { return nil }
        guard let value = Double(canonical), value.isFinite else { return nil }
        return value
    }

    /// Parses a whole number a person typed, accepting grouped spellings (`"1.500"` → 1500).
    ///
    /// Returns `nil` when the text carries a fractional part, matching what the bare `Int(_:)`
    /// call sites this replaces already did for `"12.5"`, so no integer field silently rounds.
    public static func int(from raw: String, locale: Locale = .current) -> Int? {
        guard let canonical = canonicalized(raw, locale: locale) else { return nil }
        return Int(canonical)
    }

    // MARK: - Canonicalization

    /// Rewrites typed text into a plain `"[-]digits[.digits]"` string, or `nil` if it is not a
    /// number. Splitting the charset guard from the separator decision keeps both under Rule 4.
    static func canonicalized(_ raw: String, locale: Locale) -> String? {
        let separators = separatorCharacters(for: locale)
        guard let (sign, body) = validatedBody(raw, separators: separators) else { return nil }
        let decimalSeparator = resolvedDecimalSeparator(in: body, locale: locale)
        let parts = body.split(separator: decimalSeparator, omittingEmptySubsequences: false)
        // Two decimal separators is never one number ("1,2,3" is a typo, not 123).
        guard parts.count <= 2 else { return nil }
        let integerText = parts.first ?? ""
        let fractionText = parts.count == 2 ? parts[1] : ""
        // Grouping separators belong to the integer part only ("1.234,5" — never "2,5.5").
        guard fractionText.allSatisfy(\.isNumber) else { return nil }
        guard let integerDigits = ungrouped(integerText) else { return nil }
        guard integerDigits.isEmpty == false || fractionText.isEmpty == false else { return nil }
        let fraction = fractionText.isEmpty ? "" : "." + fractionText
        return sign + (integerDigits.isEmpty ? "0" : integerDigits) + fraction
    }

    /// Strips grouping separators from an integer part, or `nil` when the grouping is malformed.
    ///
    /// Validating group widths is what keeps a typo from becoming a plausible number: with the
    /// separators merely dropped, `"1,2,3"` would parse as 123 and be silently logged. Groups
    /// after the first must be exactly three digits wide, as every locale in scope writes them.
    private static func ungrouped(_ text: Substring) -> String? {
        guard text.contains(where: { $0.isNumber == false }) else { return String(text) }
        let groups = text.split(omittingEmptySubsequences: false) { $0.isNumber == false }
        guard groups.count >= 2, groups.count <= maxGroups else { return nil }
        guard let first = groups.first, first.isEmpty == false, first.count <= 3 else { return nil }
        guard groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        return groups.joined()
    }

    /// Largest number of grouped digit runs accepted — bounds ``ungrouped(_:)`` (Rule 2) well
    /// above any real quantity (11 groups is 10^33).
    private static let maxGroups = 12

    /// Strips whitespace and a leading sign, then rejects any input carrying a character that is
    /// neither a digit nor a known separator.
    ///
    /// The charset guard is what keeps `Double(_:)`'s hex/infinity/NaN spellings out: `"0x1p3"`,
    /// `"inf"`, and `"nan"` all fail here rather than becoming a value downstream.
    private static func validatedBody(
        _ raw: String,
        separators: Set<Character>
    ) -> (sign: String, body: Substring)? {
        // Length is guarded before the strip, not after: `raw` can be an arbitrarily long paste,
        // and the filter below must not walk it (Rule 2 — the scan is bounded by the guard).
        guard raw.isEmpty == false, raw.count <= maxInputCharacters else { return nil }
        let stripped = raw.filter { $0.isWhitespace == false }
        guard stripped.isEmpty == false else { return nil }
        var body = stripped[stripped.startIndex...]
        var sign = ""
        if let first = body.first, first == "-" || first == "+" {
            sign = first == "-" ? "-" : ""
            body = body.dropFirst()
        }
        guard body.isEmpty == false else { return nil }
        guard body.allSatisfy({ $0.isNumber || separators.contains($0) }) else { return nil }
        return (sign, body)
    }

    /// Decides which character in `body` is the decimal separator, per the rules documented on
    /// ``double(from:locale:)``. Returns a character that may not appear in `body` at all, which
    /// simply means every separator present is grouping.
    private static func resolvedDecimalSeparator(in body: Substring, locale: Locale) -> Character {
        let localeDecimal = decimalSeparator(for: locale)
        let dots = body.filter { $0 == "." }.count
        let commas = body.filter { $0 == "," }.count

        // Both kinds present: the rightmost separator is the decimal one.
        if dots > 0, commas > 0 {
            let lastDot = body.lastIndex(of: ".")
            let lastComma = body.lastIndex(of: ",")
            guard let dot = lastDot, let comma = lastComma else { return localeDecimal }
            return dot > comma ? "." : ","
        }

        // One kind, repeated: grouping throughout ("1.234.567").
        let present: Character? = dots > 0 ? "." : (commas > 0 ? "," : nil)
        guard let separator = present else { return localeDecimal }
        guard dots + commas == 1 else { return groupingOnly }

        // A lone separator followed by exactly three digits is ambiguous ("1,500"); anything
        // else is a decimal fraction ("2,5", "12,34", "1,2345").
        guard let index = body.lastIndex(of: separator) else { return localeDecimal }
        let trailingDigits = body.distance(from: body.index(after: index), to: body.endIndex)
        guard trailingDigits == 3 else { return separator }
        return localeDecimal
    }

    // MARK: - Locale separators

    /// Sentinel returned when every separator in the input is grouping: a character that cannot
    /// occur in a validated body, so the canonicalizer drops all separators it sees.
    private static let groupingOnly: Character = "\u{0}"

    /// The locale's decimal separator, falling back to `.` when the locale does not name one.
    private static func decimalSeparator(for locale: Locale) -> Character {
        guard let symbol = locale.decimalSeparator, let character = symbol.first else { return "." }
        return character
    }

    /// Every character treated as a separator for `locale`: both ASCII separators (always, so a
    /// pasted or foreign-keyboard spelling still parses), both apostrophe spellings (de-CH groups
    /// with U+0027, but a typographic keyboard or a paste supplies U+2019), plus the locale's own
    /// grouping symbol. A whitespace grouping symbol — fr's narrow no-break space — is not listed
    /// because ``validatedBody(_:separators:)`` has already stripped it.
    private static func separatorCharacters(for locale: Locale) -> Set<Character> {
        var characters: Set<Character> = [".", ",", "'", "\u{2019}"]
        if let grouping = locale.groupingSeparator?.first, grouping.isWhitespace == false {
            characters.insert(grouping)
        }
        if let decimal = locale.decimalSeparator?.first {
            characters.insert(decimal)
        }
        return characters
    }
}
