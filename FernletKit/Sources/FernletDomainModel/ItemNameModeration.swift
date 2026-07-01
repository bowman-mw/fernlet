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
// innocently in a short cosmetic item name. English-only for v1.

import Foundation

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

    nonisolated private static let normalizedBlockedTerms: [String] = blockedTerms.map(normalize)

    /// Whether `name` is allowed to be LISTED for sale. Empty/whitespace names are allowed (they fall back
    /// to the slot label and carry no offensive content).
    public static func isAllowedForListing(_ name: String) -> Bool {
        !containsBlockedTerm(name)
    }

    /// True if the (normalized) text contains a blocked term as a substring.
    public static func containsBlockedTerm(_ text: String) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return false }
        return normalizedBlockedTerms.contains { !$0.isEmpty && normalized.contains($0) }
    }

    /// Coerce a (possibly untrusted, e.g. wire-received) name into a safe shape WITHOUT throwing: drop
    /// control / zero-width / bidi-override scalars, collapse whitespace runs, and cap length. Mirrors
    /// `ItemGridTexture.sanitized()`'s never-throw boundary coercion for the name string. Does NOT remove
    /// profanity — listing is gated separately by `isAllowedForListing`.
    public static func sanitizedName(_ raw: String) -> String {
        let kept = raw.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !invisibleScalars.contains(scalar)
        }
        let collapsed = String(String.UnicodeScalarView(kept))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(maxNameLength))
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
        let compatible = value.precomposedStringWithCompatibilityMapping
        let folded = compatible.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        let deLeet = String(folded.map { leetMap[$0] ?? $0 })
        return String(deLeet.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
