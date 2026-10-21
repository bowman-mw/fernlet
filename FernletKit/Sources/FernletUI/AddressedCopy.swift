//
//  AddressedCopy.swift
//  FernletUI
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
//  Two measured traps the helpers close (macOS 26 Foundation, 2026-10-20):
//  - `String(localized:)` returns the RAW markup ("¿Estás ^[listo](inflect: true)?"), so a marked
//    key must never be read as a plain `String`. `LocalizationBoundaryTests` holds that wall;
//    ``AddressedCopy/string(_:addressing:)`` is the `String` path that is safe.
//  - Inflection follows each run's `languageIdentifier` attribute, not the `locale:` argument, and
//    a run can come back tagged with a language other than the one the text was resolved in. The
//    helper sets it from the resource's locale before inflecting.
//

import Foundation
import SwiftUI
import FernletDomainModel

public extension BiologicalSex {
    /// The grammatical form Fernlet's copy takes when it describes the user: feminine for
    /// `.female`, masculine for `.male`. Words such as "listo" in a Spanish translation agree
    /// with it through ``AddressedCopy``.
    nonisolated var termOfAddress: TermOfAddress {
        switch self {
        case .female: .feminine
        case .male: .masculine
        }
    }
}

public extension EnvironmentValues {
    /// The term of address that ``AddressedText`` inflects with. The app root sets it from the
    /// effective body profile's ``BiologicalSex/termOfAddress`` (onboarding from the profile being
    /// edited, so it follows the Sex picker as it changes). Masculine when nothing set it, the same
    /// default as an unanswered profile.
    @Entry var fernletTermOfAddress: TermOfAddress = .masculine
}

/// Resolves catalog copy whose translation marks the words that describe the user with
/// `^[…](inflect: true)`, inflected for an explicit term of address instead of the system's.
///
/// Use it for every key whose translation carries a user-agreement mark. Copy without such a mark
/// renders identically through it, so a call site never needs to know which languages mark a key.
/// Plural agreement (`^[\(n) serving](inflect: true)`) is applied in the same pass.
///
/// **Concurrency:** nonisolated and stateless. `LocalizedStringResource`, `AttributedString` and
/// `TermOfAddress` are all `Sendable`, so a store or a background formatter may call it.
public nonisolated enum AddressedCopy {
    /// The resolved, inflected text, keeping any Markdown styling the translation carries.
    ///
    /// - Parameters:
    ///   - resource: The catalog entry. Its `locale` (`.current` unless the caller set one) names
    ///     the language the text resolves and inflects in.
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
    /// `String` is required (a notice, an alert message, an accessibility label).
    public static func string(
        _ resource: LocalizedStringResource, addressing address: TermOfAddress
    ) -> String {
        String(attributed(resource, addressing: address).characters)
    }
}

/// A `Text` for catalog copy that describes the user, inflected for the term of address in the
/// environment (`EnvironmentValues.fernletTermOfAddress`).
///
/// `AddressedText("Start your next set when you're ready.")` extracts into the catalog like any
/// literal; the Spanish translation's `^[listo](inflect: true)` then reads "lista" for a user whose
/// profile says female.
public struct AddressedText: View {
    /// The catalog entry to resolve.
    private let resource: LocalizedStringResource
    /// The user's term of address, set at the app root from the body profile.
    @Environment(\.fernletTermOfAddress) private var address

    /// Creates the text from a catalog entry (a literal or interpolation extracts as its key).
    public init(_ resource: LocalizedStringResource) {
        self.resource = resource
    }

    public var body: some View {
        Text(AddressedCopy.attributed(resource, addressing: address))
    }
}
