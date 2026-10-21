import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Settings search finds the screens from a Spanish query (localization plan §5, Phase 3).
///
/// Matching stays on the frozen English tokens, and Spanish adds its own vocabulary
/// (`SettingsSearchSynonyms`) while Spanish is an input language. The English-interface test host
/// proves the Spanish words are dormant there.
@MainActor
struct SpanishSettingsSearchTests {
    nonisolated private static let spanish = InputLanguages([.spanish])

    private static func titles(for query: String, languages: InputLanguages = spanish) -> [String] {
        SettingsSearchIndex.results(for: query, languages: languages).map(\.title)
    }

    @Test func everySynonymKeyNamesAnEntryAndEveryEntryHasSynonyms() {
        let titles = Set(SettingsSearchIndex.entries.map(\.title))
        let table = SettingsSearchSynonyms.table(for: .spanish)
        #expect(Set(table.keys) == titles, "orphaned: \(Set(table.keys).subtracting(titles)); missing: \(titles.subtracting(table.keys))")
        for (title, words) in table {
            #expect(!words.isEmpty, "\(title)")
            for word in words {
                #expect(!SettingsSearchIndex.tokens(in: word).isEmpty, "\(title): \"\(word)\" folds to nothing")
            }
        }
        #expect(SettingsSearchSynonyms.table(for: .english).isEmpty)
    }

    @Test func everyEntryIsFoundByItsSpanishTitle() throws {
        // The test build is DEBUG, so the debug-only routes are searchable here too.
        for entry in SettingsSearchIndex.entries {
            let first = try #require(SettingsSearchSynonyms.table(for: .spanish)[entry.title]?.first)
            #expect(SettingsSearchIndex.results(for: first, languages: Self.spanish).contains { $0.id == entry.id },
                    "\"\(first)\" does not find \(entry.title)")
        }
    }

    @Test func spanishQueriesFindTheirScreens() {
        let cases: [(String, String)] = [
            ("modo oscuro", "Dark mode"), ("notificaciones", "Notifications"), ("Código", "App lock"),
            ("codigo", "Change passcode"), ("copia de seguridad", "Sealed backup for journal entries"),
            ("vibración", "Haptics"), ("salud", "Health access"), ("borrar todo", "Delete everything"),
            ("regla", "Period tracking"), ("calorias", "Show calories"), ("agua", "Daily water target"),
            ("privacidad", "Privacy Policy"), ("amigos cerca", "Nearby friends"), ("exportar", "Export my data"),
            ("entrenador", "Share with a trainer"), ("huella", "Face ID / Touch ID"), ("ia", "AI status")
        ]
        for (query, title) in cases {
            #expect(Self.titles(for: query).contains(title), "\"\(query)\" does not find \(title)")
        }
    }

    @Test func spanishSynonymsAreDormantForAnEnglishInterface() {
        #expect(Self.titles(for: "modo oscuro", languages: .englishOnly).isEmpty)
        #expect(SettingsSearchIndex.results(for: "notificaciones").isEmpty)
    }

    @Test func englishQueriesFindTheSameScreensInSpanish() {
        for query in ["dark mode", "passcode", "backup", "health", "audit", "delete", "water", "friends"] {
            let english = Self.titles(for: query, languages: .englishOnly)
            #expect(!english.isEmpty, "\(query)")
            // Spanish only adds: every English answer is still there.
            #expect(Set(english).isSubset(of: Self.titles(for: query)), "\(query)")
        }
    }
}
