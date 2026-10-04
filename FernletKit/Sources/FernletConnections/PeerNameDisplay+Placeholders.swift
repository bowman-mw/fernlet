// PeerNameDisplay+Placeholders.swift
// FernletConnections
//
// The Fernlet app's half of ProximityKit's name display: the plain phrases that stand in for a
// person whose name is not known, and the two ways the in-person surfaces render a peer's name with
// them. ProximityKit keeps the identifier filter, `PeerNameDisplay.personName(_:fingerprint:in:)`
// with the fingerprint width and shape it checks, beside the namespace soundness rule that exists
// to keep it whole; which phrase a person reads when that filter refuses a name is Fernlet's display
// policy, so it lives here, beside `PeerNames.fernlet` (the cap and the "A friend" floor), Fernlet's
// other peer-name presentation values. The phrases resolve against this module's own catalog
// (`FernletConnectionsCopy.Peer`). A placeholder is resolved display text and never a token: it is
// never persisted, put in a roster or vault row, or sent. `PeerNameDisplayTests` pins the rules.

import ProximityKit

nonisolated extension PeerNameDisplay {

    /// Which plain phrase stands in for a person whose name is not known.
    public enum Placeholder: Sendable {
        /// Someone on the connect path whose name has not been shared yet: the nearby rows, the
        /// session's participants, a join request, a recipe recipient.
        case nearby
        /// Someone met in an earlier session whose name never arrived: the keep-as-friend rows and
        /// the Friends & Blocks list.
        case met
    }

    /// The text to render for a peer: ``personName(_:fingerprint:in:)``, or the placeholder.
    ///
    /// - Parameters:
    ///   - raw: The name as received or stored.
    ///   - fingerprint: The peer's fingerprint, when the caller has it.
    ///   - placeholder: Which phrase stands in when there is no name. Defaults to ``Placeholder/nearby``.
    ///   - namespace: The host's namespace, whose mesh instance-name prefix is never a name and whose
    ///     peer-name cap caps the name.
    /// - Returns: A string safe to show, already localized. Render it verbatim.
    public static func shown(
        _ raw: String, fingerprint: String?, placeholder: Placeholder = .nearby, in namespace: ProximityNamespace
    ) -> String {
        personName(raw, fingerprint: fingerprint, in: namespace) ?? text(for: placeholder)
    }

    /// The first word of the peer's chosen name for warm copy ("Aisha" from "Aisha Bloom"), or the
    /// WHOLE placeholder when there is no name to take it from.
    ///
    /// Taking the first word of ``shown(_:fingerprint:placeholder:in:)`` instead would turn
    /// "Someone you met" into "Someone", which is why the rule is applied before the split, here.
    /// `FernletSocial`'s `PresenceManager.firstName(of:in:)` delegates to this, so the hearts copy
    /// presence composes (its refusals) can never interpolate a fingerprint filed as a name.
    ///
    /// - Parameters:
    ///   - raw: The name as received or stored.
    ///   - fingerprint: The peer's fingerprint, when the caller has it.
    ///   - placeholder: Which phrase stands in when there is no name. Defaults to ``Placeholder/nearby``.
    ///   - namespace: The host's namespace, whose mesh instance-name prefix is never a name and whose
    ///     peer-name cap caps the name.
    /// - Returns: A string safe to show, already localized. Render it verbatim.
    public static func firstName(
        _ raw: String, fingerprint: String?, placeholder: Placeholder = .nearby, in namespace: ProximityNamespace
    ) -> String {
        guard let name = personName(raw, fingerprint: fingerprint, in: namespace) else {
            return text(for: placeholder)
        }
        // `personName` collapsed every whitespace run to one space and trimmed the ends.
        return name.split(separator: " ", maxSplits: 1).first.map(String.init) ?? name
    }

    /// The localized phrase for a placeholder, resolved against FernletConnections' catalog.
    ///
    /// - Parameter placeholder: Which phrase.
    /// - Returns: "Someone nearby" or "Someone you met", in the current locale.
    public static func text(for placeholder: Placeholder) -> String {
        switch placeholder {
        case .nearby: FernletConnectionsCopy.Peer.someoneNearby
        case .met: FernletConnectionsCopy.Peer.someoneYouMet
        }
    }
}
