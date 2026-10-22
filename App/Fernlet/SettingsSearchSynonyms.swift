// SettingsSearchSynonyms.swift
// Per-language search vocabulary for the Settings hub (localization plan §5, Phase 3).
//
// `SettingsSearchIndex` matches on FROZEN English tokens — each entry's `title` and `keywords` —
// because a translated token would stop matching the queries the catalog was written for and would
// re-identify every row on a language change. A Spanish speaker types Spanish, though, so each
// language beyond English adds its own synonyms here, keyed by the entry's frozen `title`. They are
// matching vocabulary, curated per language, not translations of the keywords: the first synonym of
// each entry is the row's own title in that language, so the words on the screen always find it.
//
// Adding a language is one `SettingsSearchSynonyms+<Language>.swift` and one case in
// ``SettingsSearchSynonyms/table(for:)``; `SpanishSettingsSearchTests` pins that every key names a
// real entry and every entry has synonyms.

import Foundation
import FernletDomainModel

/// Per-language Settings search synonyms, keyed by a ``SettingsSearchEntry``'s frozen English `title`.
///
/// Read once per entry at construction (``SettingsSearchEntry/synonymTokens``) and matched by
/// ``SettingsSearchIndex/results(for:languages:)`` only while that language is an input language
/// (English plus the app's language, `InputLanguages.current`), alongside the English tokens, which
/// always match. Values may carry accents: they fold through ``SettingsSearchIndex/tokens(in:)`` like
/// the typed query does.
nonisolated enum SettingsSearchSynonyms {
    /// The synonyms `language` adds, keyed by entry title; empty for English, whose synonyms are each
    /// entry's own `keywords`.
    static func table(for language: FernletLanguage) -> [String: [String]] {
        switch language {
        case .english: [:]
        case .spanish: spanish
        }
    }
}
