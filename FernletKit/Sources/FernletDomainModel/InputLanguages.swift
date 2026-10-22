//
//  InputLanguages.swift
//  FernletDomainModel
//
//  Which languages Fernlet reads typed input in (localization plan §5.2–§5.3).
//

import Foundation

/// The languages Fernlet reads a person's typed input in: English always, plus the app's own
/// language.
///
/// The food and unit engines consult it before they reach for a ``LanguagePack``: a Spanish food
/// word, unit word or connector is read only while Spanish is active. English is always first,
/// because the catalog, the frozen matching tables and the persisted unit tokens are English, so an
/// English word typed in a Spanish app still matches.
///
/// **Why the app's language and not the device's preferred languages.** A Spanish connector can sit
/// inside an English dish name ("chili con carne", "vitamin e"), and a Spanish plural rule reads
/// English words differently. Reading Spanish only once the person runs Fernlet in Spanish means an
/// English-interface user is never re-read, while a Spanish-interface user gets Spanish parsing.
/// Widening it to the device's languages is one line in ``current`` if the owner wants bilingual
/// devices covered.
///
/// **Concurrency:** an immutable value. ``current`` reads a process constant and a task-local test
/// seam, so the scorer and the SQLite candidate query, which both call it, always agree.
public nonisolated struct InputLanguages: Sendable, Equatable {
    /// The active languages, English first, each once.
    public let languages: [FernletLanguage]

    /// The active languages: English first, then `languages` in order, each once.
    public init(_ languages: [FernletLanguage]) {
        var ordered: [FernletLanguage] = [.english]
        // R2: bounded by the caller's list.
        for language in languages where !ordered.contains(language) {
            ordered.append(language)
        }
        self.languages = ordered
    }

    /// English alone — every engine's behaviour before Phase 3, byte for byte.
    public static let englishOnly = InputLanguages([])

    /// The packs of the active languages beyond English, in order. English has no pack: its words
    /// live in the engines' own frozen tables.
    public var packs: [LanguagePack] {
        languages.compactMap(LanguagePack.pack(for:))
    }

    /// Whether `language` is active.
    public func contains(_ language: FernletLanguage) -> Bool {
        languages.contains(language)
    }

    /// The task-local override a test binds with `InputLanguages.$testOverride.withValue(…)`; always
    /// nil in production. Task-local so parallel suites cannot leak one another's languages.
    @TaskLocal public static var testOverride: InputLanguages?

    /// The languages in force for this call: a test's override, else English plus the app's
    /// language (``FernletLanguage/app``).
    public static var current: InputLanguages {
        testOverride ?? forApp
    }

    /// English plus the app's language, resolved once with ``FernletLanguage/app``.
    private static let forApp = InputLanguages([FernletLanguage.app])
}
