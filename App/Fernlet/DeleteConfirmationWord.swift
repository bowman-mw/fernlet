import Foundation

/// The typed confirm word shared by Fernlet's two typed-gate deletions: the "Delete iCloud data"
/// sheet and the "Delete everything" sheet (2026-08-21 redesign, artboard 5e).
///
/// The word is a **matching input** under the localization wall: the prompt ("Type DELETE to
/// confirm") renders the localized word, so the comparison must run against the *same* localized
/// word — a localized prompt over a hardcoded English compare would make a French user type
/// English DELETE forever, which is exactly the one-string-two-jobs shape the wall forbids. Both
/// arm checks (`PrivacyDataSettingsView`'s iCloud sheet and ``DeleteEverythingSheet``) fold through
/// ``matches(_:)``.
///
/// The **service token is a separate, frozen half of the fork**: `CloudKitSync`'s
/// `DeletionConfirmation` validates the English literal `"DELETE"` and must keep doing so (it is a
/// wire/service contract, mirrored by `ContentView`'s programmatic pass). Once the UI gate has
/// validated the localized word, callers hand the service ``serviceToken`` — never the user's
/// typed text.
enum DeleteConfirmationWord {
    /// The word the user must type — localized alongside the display copy that asks for it.
    ///
    /// Resolved via `Bundle.main` (this is the app target); translators should keep it a short,
    /// unambiguous word in caps, matching however the surrounding "Type … to confirm" sentence
    /// names it.
    static var localizedWord: String {
        String(
            localized: "DELETE",
            comment: "The word the user must type to arm the delete confirmations. Keep it short and uppercase; the 'Type … to confirm' prompts insert this same word."
        )
    }

    /// The frozen English token `CloudKitSync.DeletionConfirmation` validates. Never localized,
    /// never shown; passed programmatically once the localized gate has been satisfied.
    static let serviceToken = "DELETE"

    /// Whether `typed` matches the localized confirm word.
    ///
    /// Case-insensitive, diacritic-insensitive, and locale-independent (`locale: nil`) — the same
    /// fold `SettingsSearchIndex.normalized` uses, and for the same reason: locale-sensitive case
    /// rules (Turkish dotless ı) silently break the agreement between what is displayed and what
    /// the user types.
    static func matches(_ typed: String) -> Bool {
        let folded = fold(typed)
        return !folded.isEmpty && folded == fold(localizedWord)
    }

    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }
}
