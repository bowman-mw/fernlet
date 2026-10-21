//
//  AddressedCopy.swift
//  FernletDomainModel
//
//  Copy that describes the user agrees with the user (Spanish round, 2026-10-20).
//
//  Spanish genders the words that describe the person being spoken to: "¿Estás listo?" to a man,
//  "¿Estás lista?" to a woman. The owner's rule is that Fernlet follows the body profile's Sex
//  answer, the one onboarding already asks for the calorie math, and uses masculine forms when it
//  was never answered (which is also `UserNutritionProfile`'s own default). There is deliberately
//  no separate "address me as" setting.
//
//  Translators write the masculine form and mark each such word with Foundation's automatic
//  grammar agreement: `¿Estás ^[listo](inflect: true)?` (Docs/Localization-es-Glossary.md). What
//  this file adds is the one thing Foundation and SwiftUI do not do on their own: inflect with
//  FERNLET'S answer. `Text(LocalizedStringKey)` and `AttributedString(localized:)` both inflect
//  at creation against the system-wide "Form of Address" setting, which most people never set and
//  which can disagree with the profile, and SwiftUI has no environment value for it. So a marked
//  string is created with inflection OFF and inflected here with an explicit term of address.
//
//  It lives in the domain layer, not in FernletUI, because the copy that needs it is not all on a
//  screen: the planner composes session notes that are STORED on a logged workout, the scoring
//  module writes the companion's fallback lines, AppServices writes a notification's body, and
//  every one of those modules sits on FernletDomainModel and none of them on SwiftUI. FernletUI's
//  `AddressedText` and its `fernletTermOfAddress` environment value are the view half, built on this.
//
//  Measured traps the helpers close (macOS 26 Foundation, 2026-10-20 and 2026-10-21):
//  - `String(localized:)` returns the RAW markup ("¿Estás ^[listo](inflect: true)?"), so a marked
//    key must never be read as a plain `String`. `LocalizationBoundaryTests` part I holds that wall;
//    ``AddressedCopy/string(_:addressing:)`` is the `String` path that is safe.
//  - Inflection follows each run's `languageIdentifier` attribute, not the `locale:` argument, and
//    a run can come back tagged with a language other than the one the text was resolved in. The
//    helper sets it from the resource's locale before inflecting.
//  - `AttributedString(localized:)` parses the RESOLVED text as Markdown, interpolated arguments
//    included: a `String(localized:)` that read "Name: *Row* 2" reads "Name: Row 2" through it.
//    An argument that is user data goes in through ``AddressedCopy/argument(_:)``, which escapes it.
//  - The second pass inflects GENDER only. A count marked for plural agreement
//    (`^[\(n) serving](inflect: true)`) loses its agreement once inflection is off at creation —
//    "Made 3 time." where `Text` says "Made 3 times." — and `inflected()` does not restore it. So
//    count-agreed copy stays on `Text` / `AttributedString(localized:)`; none of the keys this file
//    serves carries a count.
//
//  Package callers build the resource with their own module's bundle,
//  `LocalizedStringResource("key", defaultValue: …, bundle: .module, comment: …)`: a resource
//  created in a package defaults to `Bundle.main`, which would silently miss the module's catalog.
//

import Foundation

public extension BiologicalSex {
    /// The grammatical form Fernlet's copy takes when it describes the user: feminine for
    /// `.female`, masculine for `.male`. Words such as "listo" in a Spanish translation agree
    /// with it through ``AddressedCopy``.
    var termOfAddress: TermOfAddress {
        switch self {
        case .female: .feminine
        case .male: .masculine
        }
    }
}

/// Resolves catalog copy whose translation marks the words that describe the user with
/// `^[…](inflect: true)`, inflected for an explicit term of address instead of the system's.
///
/// Use it for every key whose translation carries a user-agreement mark, with the user's real term
/// (``BiologicalSex/termOfAddress`` of the effective body profile, which a view reads from FernletUI's
/// `fernletTermOfAddress` environment value). Copy without such a mark renders identically through
/// it, so a call site never needs to know which languages mark a key. `LocalizationBoundaryTests`
/// part I2 pins every user-gendered key to an addressed reader: its literal must sit inside a
/// ``string(_:addressing:)`` or ``attributed(_:addressing:)`` call (or FernletUI's `AddressedText`,
/// or the announcer's `announce(_:_:addressing:)`), never `String(localized:)`, `Text("…")` or
/// ``plain(_:)``.
///
/// **Concurrency:** nonisolated and stateless. `LocalizedStringResource`, `AttributedString` and
/// `TermOfAddress` are all `Sendable`, so a store, a planner or a background formatter may call it.
public nonisolated enum AddressedCopy {
    /// The resolved, inflected text, keeping any Markdown styling the translation carries.
    ///
    /// - Parameters:
    ///   - resource: The catalog entry. Its `locale` (`.current` unless the caller set one) names
    ///     the language the text resolves and inflects in. Built in a package, it must name the
    ///     module's bundle (`bundle: .module`).
    ///   - address: Usually ``BiologicalSex/termOfAddress`` of the effective profile.
    public static func attributed(
        _ resource: LocalizedStringResource, addressing address: TermOfAddress
    ) -> AttributedString {
        var options = AttributedString.LocalizationOptions()
        options.inflect = false
        var text = AttributedString(localized: resource, options: options)
        let locale = resource.locale
        if let language = locale.language.languageCode?.identifier {
            text.languageIdentifier = language
        }
        return text.inflected(locale: locale, userTermOfAddress: address)
    }

    /// The resolved, inflected text as a plain `String`: the safe way to read a marked key where a
    /// `String` is required (a notice, an alert message, an accessibility label, a stored note).
    public static func string(
        _ resource: LocalizedStringResource, addressing address: TermOfAddress
    ) -> String {
        String(attributed(resource, addressing: address).characters)
    }

    /// The resolved text of copy that never describes the user, as a plain `String`, for a caller
    /// with no profile to hand (a pure formatter, a background task's title).
    ///
    /// It still consumes any grammar-agreement markup, so a marked translation can never reach the
    /// screen or VoiceOver raw; a word that does describe the user would come out masculine, so such
    /// copy goes through ``string(_:addressing:)`` instead (part I2 fails a user-gendered key read
    /// here). It is not a plural path either: see the file header. `LocalizationBoundaryTests` part I
    /// bans the bare `String(localized: resource)` this replaces.
    public static func plain(_ resource: LocalizedStringResource) -> String {
        string(resource, addressing: .masculine)
    }

    /// `text` escaped so it comes back verbatim from the Markdown parse ``attributed(_:addressing:)``
    /// runs over its resolved text, for an interpolated argument that is data rather than copy (an
    /// exercise's name, which a person may have typed, or a formatted weight).
    ///
    /// Every ASCII punctuation or symbol character gets a backslash, which CommonMark consumes and
    /// any other character is left alone. Measured 2026-10-21 against `*bold* _x_ [a](b)`, backticks,
    /// `<http://…>`, `~~s~~`, HTML and entities, a lone or trailing backslash, an apostrophe and a
    /// percent sign: each came back byte for byte, where the unescaped argument lost its markers.
    public static func argument(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for character in text {
            if character.isASCII, character.isPunctuation || character.isSymbol {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}
