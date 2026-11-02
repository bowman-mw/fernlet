//
//  CompanionName.swift
//  FernletDomainModel
//
//  The companion is called Sprout (owner, 2026-11-01): the art, the design docs and the approved World
//  screens already said so, and only the code's default fell back to the product's name. Every place
//  that names the companion reads it through here, so a companion with no chosen name is Sprout
//  everywhere at once. "Fernlet" stays the APP's name: the lock screen, the passport's issuer line,
//  exports, folders and Home's product title keep it.
//

import Foundation

/// The companion's name as the screens say it: the person's choice, or ``standard`` when there is none.
///
/// "Sprout" is a proper name and is never translated (Spanish says Sprout too), so it is a plain `String`,
/// not a localized one. Onboarding offers it as the starter name, so most people have it saved; the
/// fallback covers a name that was cleared.
public enum CompanionName {
    /// The companion's own name, when the person has not chosen one.
    public static let standard = "Sprout"

    /// The name to show for `chosen` (the saved setting): trimmed, or ``standard`` when it is empty.
    public static func displayed(_ chosen: String) -> String {
        let trimmed = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? standard : trimmed
    }
}

public extension FernletSettings {
    /// The companion's name as every screen says it (``CompanionName/displayed(_:)``).
    var companionDisplayName: String { CompanionName.displayed(companionName) }
}
