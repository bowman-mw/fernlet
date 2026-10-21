//
//  AddressedText.swift
//  FernletUI
//
//  The view half of addressing the user (Spanish round, 2026-10-20).
//
//  Words that describe the user agree with the body profile's Sex answer, masculine when it was
//  never answered. The resolution itself — inflection off at creation, then inflected with an
//  explicit term of address, and the measured traps that make that necessary — is
//  `AddressedCopy` in FernletDomainModel, so a planner note, a notification body or a scoring line
//  can use it without SwiftUI. This file adds what only a view needs: the environment value the
//  app root fills from the profile, and a `Text` that reads it.
//

import SwiftUI
import FernletDomainModel

public extension EnvironmentValues {
    /// The term of address that ``AddressedText`` inflects with, and that a view hands to
    /// `AddressedCopy` where it needs a `String` or a `Text`. The app root sets it from the effective
    /// body profile's `BiologicalSex.termOfAddress` (onboarding from the profile being edited, so it
    /// follows the Sex picker as it changes). Masculine when nothing set it, the same default as an
    /// unanswered profile.
    @Entry var fernletTermOfAddress: TermOfAddress = .masculine
}

/// A `Text` for catalog copy that describes the user, inflected for the term of address in the
/// environment (`EnvironmentValues.fernletTermOfAddress`).
///
/// `AddressedText("Start your next set when you're ready.")` extracts into the catalog like any
/// literal; the Spanish translation's `^[listo](inflect: true)` then reads "lista" for a user whose
/// profile says female. Where the context needs a `Text` value rather than a view (an alert's
/// message, a component's `Text` parameter), use `Text(AddressedCopy.attributed(…, addressing:))`
/// with the same environment value.
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
