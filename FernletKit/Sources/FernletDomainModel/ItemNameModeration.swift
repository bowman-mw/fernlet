// ItemNameModeration.swift
// FernletDomainModel
//
// A small, pure, wall-safe name gate for the in-person clothing shop (Increment 3). When a user lists an
// item FOR SALE, its name is screened for profanity/slurs; private (unlisted) creations are never gated.
// Mirrors `DiagnosticLanguage`'s structure (normalize-then-substring) but with a profanity word list and a
// stronger normalize step (diacritic + leetspeak folding) — `DiagnosticLanguage` targets *clinical*
// language and is unusable here.
//
// IMPORTANT — best-effort, not a guarantee. Like any keyword screen this is evadable (novel spellings,
// other languages) and, because it matches a normalized substring, it can over-match innocent names that
// happen to contain a blocked substring (the "Scunthorpe problem"). That is an accepted tradeoff: the
// listing gate only WARNS and keeps the item unlisted with an editable, dismissible notice (never a silent
// drop), so a false positive is recoverable by renaming. The list errs toward terms unlikely to appear
// innocently in a short cosmetic item name. English here, plus every `LanguagePack`'s terms (Spanish
// since localization plan §5.4), all applied to every name whatever the interface language — a
// listing is shown to friends whose language may not be the seller's. A short term that sits inside
// ordinary words is matched as a whole word only ("puta" is inside "reputation").

import Foundation

/// Pure, wall-safe profanity gate plus name sanitizer for the in-person clothing shop.
///
/// `isAllowedForListing` screens a name only when the user lists an item FOR SALE (private
/// creations are never gated); `sanitizedName` is the never-throwing wire-boundary coercion every
/// received name passes through. Best-effort by design — see the header note on the Scunthorpe
/// tradeoff and the warn-don't-drop listing UX.
public nonisolated enum ItemNameModeration {

    /// Max characters an item name may carry on the wire / when listed. Names are cosmetic labels.
    public static let maxNameLength = 24

    /// Blocked terms in their *normalized* canonical form (lowercase, diacritic- and leetspeak-folded,
    /// alphanumerics only). Matched as a substring of the normalized candidate name.
    nonisolated static let blockedTerms: [String] = [
        "fuck", "motherfuck", "shit", "bullshit", "bitch", "cunt", "asshole", "dumbass",
        "bastard", "dick", "pussy", "slut", "whore", "dildo", "cocksuck", "blowjob",
        "nigger", "nigga", "faggot", "retard", "kike", "tranny", "rapist", "molest",
        "pedophile", "nazi"
    ]

    /// ``blockedTerms`` plus every ``LanguagePack``'s blocked stems, normalized once.
    nonisolated private static let normalizedBlockedTerms: [String] =
        (blockedTerms + LanguagePack.all.flatMap(\.blockedNameStems)).map(normalize)

    /// Every ``LanguagePack``'s blocked whole words, matched against the name's folded words.
    nonisolated private static let blockedWholeWords: Set<String> =
        Set(LanguagePack.all.flatMap(\.blockedNameWholeWords))

    /// Whether `name` is allowed to be LISTED for sale. Empty/whitespace names are allowed (they fall back
    /// to the slot label and carry no offensive content).
    public static func isAllowedForListing(_ name: String) -> Bool {
        !containsBlockedTerm(name)
    }

    /// True if the (normalized) text contains a blocked term as a substring, or one of its folded
    /// words is a blocked whole word.
    public static func containsBlockedTerm(_ text: String) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return false }
        if normalizedBlockedTerms.contains(where: { !$0.isEmpty && normalized.contains($0) }) { return true }
        return words(of: text).contains { blockedWholeWords.contains($0) }
    }

    /// Coerce a (possibly untrusted, e.g. wire-received) name into a safe shape WITHOUT throwing: drop
    /// control / zero-width / bidi-override scalars, collapse whitespace runs, and cap length. Mirrors
    /// `ItemGridTexture.sanitized()`'s never-throw boundary coercion for the name string. Does NOT remove
    /// profanity — listing is gated separately by `isAllowedForListing`.
    ///
    /// - Parameter maxLength: the length cap, defaulting to ``maxNameLength`` (24, the clothing wire
    ///   bound). Callers whose names are not clothing labels — a prompt payload bounding externally
    ///   authored meal/session names, say — pass their own; the control-character, zero-width and
    ///   whitespace-collapse properties are the same at any cap.
    public static func sanitizedName(_ raw: String, maxLength: Int = maxNameLength) -> String {
        // Order is load-bearing, and the three legs are not interchangeable:
        //  1. Invisible scalars are dropped OUTRIGHT, never turned into a space. They render as
        //     nothing, so "Ali<ZWSP>ce" is seen by a human as "Alice" and must sanitize to "Alice";
        //     emitting a space instead would invent a name nobody typed. This leg runs first
        //     because Foundation counts ZERO WIDTH SPACE as whitespace, so leg 2 would claim it.
        //  2. Visible whitespace — including the control scalars \n, \r and \t — becomes a SPACE
        //     rather than vanishing. Deleting it glues the words either side together
        //     ("Soup\nIgnore this" -> "SoupIgnore this"), which reads wrong and lets externally
        //     authored text forge a phrase it never wrote. Runs before leg 3 because those three
        //     are themselves control characters.
        //  3. Every remaining control scalar is dropped, so the result carries none.
        let normalized = raw.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if invisibleScalars.contains(scalar) { return nil }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
            if CharacterSet.controlCharacters.contains(scalar) { return nil }
            return scalar
        }
        let collapsed = String(String.UnicodeScalarView(normalized))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(maxLength))
    }

    // MARK: - Internals

    /// Zero-width and bidirectional-override format characters that can hide or reorder text.
    nonisolated private static let invisibleScalars: CharacterSet = CharacterSet(charactersIn:
        "\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}"
            + "\u{2060}\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}")

    /// Common leetspeak substitutions folded before matching so "5h1t" / "@ss" reduce to their letters.
    nonisolated private static let leetMap: [Character: Character] = [
        "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b",
        "@": "a", "$": "s", "!": "i"
    ]

    /// NFKC-compatibility-fold, lowercase + diacritic-fold (ü→u), apply leetspeak folding, then drop every
    /// non-alphanumeric scalar (so separator-injection — "b a d", "b.a.d" — is defeated). The compatibility
    /// mapping folds fullwidth (ｂａｄ), circled (ⓑⓐⓓ) and mathematical/styled (𝐛𝐚𝐝) homoglyphs of blocked
    /// words down to their plain ASCII letters before matching, which `.diacriticInsensitive` alone does not.
    /// Normalization can only widen coverage.
    nonisolated static func normalize(_ value: String) -> String {
        String(folded(value).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// `value`'s words after the same folding as ``normalize(_:)`` — so "put@" reads "puta" — split at
    /// every character that is not a letter or digit, for the whole-word terms. A word spelled with
    /// separators inside it ("p.u.t.a") is not one word here; the substring list is what catches those.
    nonisolated static func words(of value: String) -> [String] {
        folded(value).split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// NFKC-folded, lowercased, diacritic- and width-folded with `locale: nil`, then leetspeak-folded.
    nonisolated private static func folded(_ value: String) -> String {
        let compatible = value.precomposedStringWithCompatibilityMapping
        let folded = compatible.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        return String(folded.lowercased().map { leetMap[$0] ?? $0 })
    }
}
