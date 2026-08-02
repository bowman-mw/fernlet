import Foundation

/// How the age range Fernlet was handed came to be known. Supplied by the system alongside the
/// range itself; Fernlet never sees a birthdate, only this provenance and a bracket.
///
/// Deliberately NOT `CaseIterable` and deliberately without a `default:` anywhere it is switched:
/// a future, stronger provenance must force an explicit decision about whether it opens a gate
/// rather than silently inheriting the permissive branch.
public nonisolated enum AgeAssuranceProvenance: String, Codable, Sendable {
    /// The account holder entered their own birthdate.
    case selfDeclared
    /// A Family Sharing organizer set it for this account.
    case guardianDeclared
    /// Backed by a stronger check (ID, payment, or another verification the system performed).
    case confirmed
}

/// The age thresholds Fernlet gates features on.
///
/// The system API accepts at most three thresholds per request, and these are exactly three, so a
/// single prompt yields a bracket that answers every gate — nobody is ever asked twice.
public nonisolated enum AgeGate: Int, Codable, Sendable, CaseIterable {
    /// Peer-to-peer chat on the proximity mesh.
    case chat = 13
    /// Intimate-activity tracking.
    case intimacy = 16
    /// Not gating anything today. Requested anyway so the stored bracket can answer an adult-only
    /// question later without putting the user through a second system prompt.
    case adult = 18

    public var minimumAge: Int { rawValue }

    /// Whether the manual "I'm N or older" confirmation may open this gate when the system never ruled.
    ///
    /// **False for `.chat`, deliberately.** 13 is the line the system check exists to hold: a tap-to-
    /// confirm there would let a 12-year-old into messaging, which is exactly the hole asking Apple was
    /// meant to close. The higher gates keep the confirmation because the cost of being wrong is a
    /// private on-device log rather than contact with other people, and because refusing outright would
    /// strand adults whose Apple Account carries no age range.
    ///
    /// Note the consequence: confirming 16 by hand opens intimacy but NOT chat, even though 16 > 13.
    /// Chat is not reachable by any route except the system's own answer.
    public var allowsSelfAttestation: Bool {
        switch self {
        case .chat: false
        case .intimacy, .adult: true
        }
    }

    /// Whether this gate covers contact with other people, and so is closed by a guardian's
    /// communication limits regardless of age.
    ///
    /// Exhaustive with no `default:`, matching `SensitiveSurfaceVisibility.allows`: a new gate must not
    /// be able to join by silently inheriting the permissive branch.
    public var isInterpersonalCommunication: Bool {
        switch self {
        case .chat: true
        case .intimacy, .adult: false
        }
    }
}

/// What Fernlet currently believes about one user relative to one gate.
///
/// Three states, not a `Bool`: "the system placed them below this line" and "we have no idea" must
/// lead to different behavior. The first is final and unappealable; the second is the only one the
/// manual confirmation may speak to.
public nonisolated enum AgeGateVerdict: String, Codable, Sendable {
    /// Never asked, declined, or the system had nothing to share. No claim either way.
    case undetermined
    /// The system placed the user below this gate. Final — see `allows(_:)`.
    case below
    /// The system placed the user at or above this gate, with usable provenance.
    case meets
}

/// Fernlet's device-local record of the age determination behind its gated features.
///
/// **Never persist this in the synced settings blob.** The determination describes the Apple Account
/// signed in on *this* device; syncing it would carry one account's status onto a device signed in as
/// someone else, and would broadcast a minor's status across the sync boundary. It lives in the
/// device-local sidecar next to the sensitive-surface visibility resolution, for the same reason.
public nonisolated struct AgeAssuranceRecord: Codable, Sendable, Equatable {
    /// The inclusive lower edge of the bracket the system returned, when it gave one.
    public var lowerBound: Int?
    /// The exclusive upper edge of the bracket the system returned, when it gave one.
    public var upperBound: Int?
    public var provenance: AgeAssuranceProvenance?
    /// Whether a guardian has restricted who this account may communicate with, reported by the system
    /// alongside the age range. Closes every `isInterpersonalCommunication` gate on its own — the
    /// guardian has already answered the question the age check was asking.
    public var hasCommunicationLimits: Bool
    /// When the system determination was recorded. Diagnostics only — nothing expires on it.
    public var determinedAt: Date?
    /// The highest gate the user has manually confirmed they meet, taken behind a warning. Only ever
    /// consulted for gates the system left `.undetermined`; a determined bracket supersedes it.
    ///
    /// One number rather than a set, because the gates are ordered: confirming 16 necessarily confirms 13.
    public var selfAttestedMinimumAge: Int?

    public init(
        lowerBound: Int? = nil,
        upperBound: Int? = nil,
        provenance: AgeAssuranceProvenance? = nil,
        hasCommunicationLimits: Bool = false,
        determinedAt: Date? = nil,
        selfAttestedMinimumAge: Int? = nil
    ) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.provenance = provenance
        self.hasCommunicationLimits = hasCommunicationLimits
        self.determinedAt = determinedAt
        self.selfAttestedMinimumAge = selfAttestedMinimumAge
    }

    /// Absent key ⇒ `false`, so a record written before parental controls were read decodes as
    /// unrestricted rather than failing. That is the correct direction here: the flag only ever CLOSES
    /// a gate, and inventing a restriction nobody reported would lock a user out over a schema change.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lowerBound = try container.decodeIfPresent(Int.self, forKey: .lowerBound)
        upperBound = try container.decodeIfPresent(Int.self, forKey: .upperBound)
        provenance = try container.decodeIfPresent(AgeAssuranceProvenance.self, forKey: .provenance)
        hasCommunicationLimits = try container.decodeIfPresent(Bool.self, forKey: .hasCommunicationLimits) ?? false
        determinedAt = try container.decodeIfPresent(Date.self, forKey: .determinedAt)
        selfAttestedMinimumAge = try container.decodeIfPresent(Int.self, forKey: .selfAttestedMinimumAge)
    }

    /// A device that has never asked. The fail-closed starting point.
    public static let unknown = AgeAssuranceRecord()

    /// Whether the system reached any conclusion at all. Drives the UI's choice between "verify your
    /// age" and "you don't meet this requirement".
    public var isDetermined: Bool {
        lowerBound != nil || upperBound != nil
    }

    /// Classifies the stored bracket against one gate.
    ///
    /// The two directions are deliberately asymmetric, because the cost of being wrong differs:
    ///
    /// - **Toward meeting the gate**, weak evidence is not enough: a bracket with no provenance
    ///   attached stays `.undetermined` rather than opening. The user can still get through via the
    ///   manual confirmation, so this costs them a tap, not access.
    /// - **Toward falling below it**, weak evidence *is* enough: any bracket placing the user under the
    ///   line locks, provenance or not. There is no tap that undoes it.
    public func verdict(for gate: AgeGate) -> AgeGateVerdict {
        // A "sharing" response carrying no bracket at all tells us nothing. Treat it as if we never
        // asked rather than as evidence of being underage.
        guard isDetermined else { return .undetermined }
        if let lowerBound, lowerBound >= gate.minimumAge {
            return provenance == nil ? .undetermined : .meets
        }
        return .below
    }

    /// **The gate.** Every age-gated feature fans out from this one call.
    ///
    /// A `.below` verdict is not overridable — that is the entire point of asking the system, and a
    /// manual confirmation that could undo it would make the gate decorative.
    public func allows(_ gate: AgeGate) -> Bool {
        // A guardian's communication limits close a communication gate outright, whatever the age says.
        // Checked FIRST so no combination of bracket or confirmation can get past it.
        if gate.isInterpersonalCommunication, hasCommunicationLimits { return false }
        return switch verdict(for: gate) {
        case .meets: true
        case .below: false
        case .undetermined: gate.allowsSelfAttestation && (selfAttestedMinimumAge ?? 0) >= gate.minimumAge
        }
    }

    /// Whether the manual confirmation may even be offered for this gate. Never for a gate that refuses
    /// self-attestation outright (`.chat`), never to a user the system has already placed below it, and
    /// pointless for one it has already placed above.
    public func mayOfferSelfAttestation(for gate: AgeGate) -> Bool {
        guard gate.allowsSelfAttestation else { return false }
        if gate.isInterpersonalCommunication, hasCommunicationLimits { return false }
        return verdict(for: gate) == .undetermined
    }

    /// Folds a fresh system determination into this record.
    ///
    /// A determined bracket DROPS any standing manual confirmation. The system just supplied real
    /// information, so the user's own claim is superseded — and dropping it outright avoids having to
    /// reason about a stale claim resurfacing if a later re-check comes back empty. A user whose
    /// re-check genuinely returns nothing simply confirms again.
    public func determining(
        lowerBound: Int?,
        upperBound: Int?,
        provenance: AgeAssuranceProvenance?,
        hasCommunicationLimits: Bool = false,
        now: Date
    ) -> AgeAssuranceRecord {
        let determined = lowerBound != nil || upperBound != nil
        return AgeAssuranceRecord(
            lowerBound: lowerBound,
            upperBound: upperBound,
            provenance: provenance,
            hasCommunicationLimits: hasCommunicationLimits,
            determinedAt: now,
            selfAttestedMinimumAge: determined ? nil : selfAttestedMinimumAge
        )
    }

    /// Records that the system gave us nothing usable — the user declined to share, or the account has
    /// no age information. Clears any earlier bracket rather than leaving a stale one standing (the
    /// parental-controls flag goes with it: it came from the response we no longer have), and preserves
    /// the manual confirmation, which re-asking and learning nothing does not revoke.
    public func undetermined(now: Date) -> AgeAssuranceRecord {
        AgeAssuranceRecord(
            determinedAt: now,
            selfAttestedMinimumAge: selfAttestedMinimumAge
        )
    }

    /// Applies the manual confirmation for one gate, keeping the highest confirmed threshold.
    ///
    /// A no-op when the system has already ruled on that gate, so a caller cannot open a `.below` gate
    /// by mistake. Confirming a higher gate implies the lower ones — the stored value is a floor.
    public func selfAttesting(_ gate: AgeGate) -> AgeAssuranceRecord {
        guard mayOfferSelfAttestation(for: gate) else { return self }
        var updated = self
        updated.selfAttestedMinimumAge = max(selfAttestedMinimumAge ?? 0, gate.minimumAge)
        return updated
    }
}
