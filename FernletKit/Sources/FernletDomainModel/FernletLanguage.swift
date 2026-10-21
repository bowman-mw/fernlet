//
//  FernletLanguage.swift
//  FernletDomainModel
//
//  The languages Fernlet's language-sensitive engines know (localization plan §5, Phase 3).
//
//  Display copy localizes through the string catalogs and needs none of this. What does need it is
//  everything that reads or writes LANGUAGE rather than drawing it: the on-device model's prompts
//  (which language to answer in), and the matching inputs — food words, unit words, the clinical and
//  moderation screens, Settings search — whose frozen English tables cannot understand another
//  language's input on their own. Each of those engines asks this file which languages are in play
//  and asks ``LanguagePack`` for that language's words.
//
//  Adding a language (French, say) is three steps and no engine change:
//  1. a case here, with its frozen code and prompt name;
//  2. a `LanguagePack+French.swift` beside `LanguagePack+Spanish.swift`, registered in
//     ``LanguagePack/pack(for:)``;
//  3. the app target's Settings search synonyms for it (`SettingsSearchSynonyms+French.swift`) and,
//     in AIContext, its prompt style (`AIPromptLanguage`).
//  `LanguagePackTests` fails until every case has a pack whose tables are filled and well-formed.
//

import Foundation

/// A language Fernlet's language-sensitive engines know, named by its frozen ISO 639-1 code.
///
/// The raw value is a TOKEN, never display text: it is compared against bundle localization
/// identifiers and `Locale.preferredLanguages`, so it never localizes and never changes. English is
/// the base: every frozen matching table, the food catalog and every prompt's instructions are
/// English, so English input is always understood whatever else is active.
public nonisolated enum FernletLanguage: String, CaseIterable, Sendable {
    /// English, the development language.
    case english = "en"
    /// Spanish — one base `es`, neutral and leaning Latin American (Docs/Localization-es-Glossary.md).
    case spanish = "es"

    /// The language's English name, as prompt vocabulary ("Write your reply in Spanish."). Frozen
    /// English: the on-device model reads it inside English instructions, and no screen draws it.
    public var promptName: String {
        switch self {
        case .english: "English"
        case .spanish: "Spanish"
        }
    }

    /// The language a localization or locale identifier names ("es", "es-MX", "es_419", "en-GB"),
    /// or nil when Fernlet does not know that language.
    public init?(identifier: String) {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let code = Locale(identifier: trimmed).language.languageCode?.identifier.lowercased() else { return nil }
        self.init(rawValue: code)
    }

    /// The language the app's interface runs in: the first localization the main bundle resolved
    /// that Fernlet knows, else English.
    ///
    /// A bundle can only resolve a language it ships, so this is also "app-supported" by
    /// construction: while the app catalog carries no `es`, a phone set to Spanish still resolves
    /// English here, and every engine stays English with it.
    ///
    /// - Parameter preferredLocalizations: The bundle's resolved localizations, best first.
    public static func appLanguage(preferredLocalizations: [String]) -> FernletLanguage {
        // R2: bounded by the bundle's localizations, a handful.
        for identifier in preferredLocalizations {
            if let language = FernletLanguage(identifier: identifier) { return language }
        }
        return .english
    }

    /// ``appLanguage(preferredLocalizations:)`` for this process's main bundle, resolved once.
    ///
    /// A constant for the process's life on purpose: iOS relaunches an app whose language the
    /// person changes, so the value cannot go stale, and the engines that read it run per keystroke.
    public static let app: FernletLanguage = appLanguage(preferredLocalizations: Bundle.main.preferredLocalizations)
}
