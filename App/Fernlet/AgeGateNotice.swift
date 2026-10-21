import SwiftUI
import FernletDomainModel
import FernletUI

/// The locked-state row for an age-gated feature, shown in place of the feature's own control.
///
/// Says the *true* reason rather than a generic "unavailable", because the two reasons need different
/// affordances: a user the system placed below the line has nothing to tap, while one it never ruled on
/// has two ways through — re-ask the system, or confirm manually behind a warning.
///
/// Also the only path back for two real cases the onboarding prompt cannot reach: someone who installed
/// before this gate existed and therefore never saw the prompt, and someone who was below the line when
/// they answered and has since had a birthday.
struct AgeGateNotice: View {
    let gate: AgeGate
    /// The feature this notice stands in for. Its sentences are whole per feature
    /// (``AgeGatedFeature``) rather than a name spliced into shared sentences: the name opens most of
    /// them, and in Spanish the article and the participle agree with it ("El seguimiento … está
    /// desactivado", "La mensajería … está desactivada").
    let feature: AgeGatedFeature
    var ageAssurance: AgeAssuranceStore

    @State private var isRequestingAgeRange = false
    @State private var isConfirmingAge = false

    private var verdict: AgeGateVerdict { ageAssurance.record.verdict(for: gate) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fixedSize(horizontal: false, vertical: true)

            // Offered for every locked state, including `.below`. A birthday is the ordinary way out of
            // that one — a 12-year-old turns 13 — and without this the verdict would be permanent.
            // It is also how a lifted parental restriction gets picked up.
            // `.plain` matches the rest of Settings: two Buttons sharing one List row otherwise fire
            // together, which here would mean the re-check also raising the confirmation alert.
            Button("Check my age with Apple") { isRequestingAgeRange = true }
                .buttonStyle(.plain)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.bark)
                .disabled(isRequestingAgeRange)
                .accessibilityIdentifier("ageGate.\(gate.minimumAge).verify")

            // Withheld entirely for `.chat` (`allowsSelfAttestation` is false there): 13 is the line the
            // system check exists to hold, so there is no tap-to-confirm route into messaging.
            if ageAssurance.mayOfferSelfAttestation(for: gate) {
                Button("I'm \(gate.minimumAge) or older") { isConfirmingAge = true }
                    .buttonStyle(.plain)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .accessibilityIdentifier("ageGate.\(gate.minimumAge).confirm")
            }
        }
        .accessibilityIdentifier("ageGate.\(gate.minimumAge).notice")
        .requestsAgeRange(when: $isRequestingAgeRange, into: ageAssurance)
        .alert("Confirm your age", isPresented: $isConfirmingAge) {
            Button("Cancel", role: .cancel) { }
            Button("I'm \(gate.minimumAge) or older") { ageAssurance.selfAttest(gate) }
        } message: {
            Text(verbatim: feature.selfAttestationWarning(minimumAge: gate.minimumAge))
        }
    }

    /// The notice's sentence, already resolved, for the state the gate is in.
    private var message: String {
        feature.sentence(for: lockedState, minimumAge: gate.minimumAge)
    }

    /// Which locked-state sentence applies.
    private var lockedState: AgeGatedFeature.LockedState {
        // Checked before the age verdict, mirroring `AgeAssuranceRecord.allows`: a restricted account
        // may well pass the age check, and saying "you're too young" there would be simply untrue.
        if gate.isInterpersonalCommunication, ageAssurance.record.hasCommunicationLimits {
            return .communicationLimits
        }
        switch verdict {
        case .below:
            return .below
        case .undetermined where !gate.allowsSelfAttestation:
            // `.chat`: no manual route exists, so the copy must not imply one.
            return .needsSystemCheck
        case .undetermined where ageAssurance.isDetermined:
            // The system returned a bracket, but without provenance Fernlet can't treat it as a claim of
            // being old enough. Rare; worth its own wording so the next step isn't a mystery.
            return .unclearAnswer
        case .undetermined:
            return .unknownAge
        case .meets:
            // Unreachable: the caller shows the feature's real control instead. Kept honest rather than
            // fatalError'd so a wiring slip degrades to a harmless line.
            return .available
        }
    }
}

/// A feature behind an age gate, and every sentence its locked-state notice can say.
///
/// Whole sentences per feature, each with the age as its only placeholder (Spanish round,
/// 2026-10-20). They used to be one family of sentences with the feature's English name spliced in
/// (and lower-cased in code for the confirmation alert), which no catalog could translate: the name
/// opens most of them, and its article and the participles around it agree with it in Spanish. Some
/// combinations cannot be reached today (intimacy is not interpersonal, so it never meets
/// communication limits, and it offers self-attestation, so it never needs the system-only
/// wording; messaging takes that wording for every undetermined answer and offers no
/// self-attestation); they are worded anyway so a gate change never draws a blank.
enum AgeGatedFeature {
    /// Intimacy tracking (the 16+ gate).
    case intimacyTracking
    /// Messaging friends nearby (the 13+ gate).
    case messagingFriendsNearby

    /// The states ``AgeGateNotice`` words differently.
    enum LockedState {
        /// A guardian's communication limits are set on the Apple Account.
        case communicationLimits
        /// Apple placed the user below the line.
        case below
        /// Undetermined, and the gate offers no manual confirmation.
        case needsSystemCheck
        /// Apple answered, but not specifically enough to confirm the age.
        case unclearAnswer
        /// Undetermined; the age has not been checked yet.
        case unknownAge
        /// The gate is open (not normally shown: the caller draws the real control).
        case available
    }

    /// The notice's sentence for `state`. `minimumAge` is the gate's line.
    func sentence(for state: LockedState, minimumAge: Int) -> String {
        switch self {
        case .intimacyTracking: Self.intimacySentence(for: state, minimumAge: minimumAge)
        case .messagingFriendsNearby: Self.messagingSentence(for: state, minimumAge: minimumAge)
        }
    }

    /// The "Confirm your age" alert's warning, naming this feature.
    func selfAttestationWarning(minimumAge: Int) -> String {
        switch self {
        case .intimacyTracking:
            String(localized: "ageGate.intimacy.confirmWarning",
                   defaultValue: "Fernlet couldn't check your age with Apple, so this is your word for it. Only confirm if you really are \(minimumAge) or older — intimacy tracking is meant for people that age and up.",
                   comment: "Alert body before a user confirms their own age to turn on intimacy tracking. The argument is the minimum age (16).")
        case .messagingFriendsNearby:
            String(localized: "ageGate.chat.confirmWarning",
                   defaultValue: "Fernlet couldn't check your age with Apple, so this is your word for it. Only confirm if you really are \(minimumAge) or older — messaging friends nearby is meant for people that age and up.",
                   comment: "Alert body before a user confirms their own age to message friends nearby (not normally shown: this feature offers no manual confirmation). The argument is the minimum age (13).")
        }
    }

    private static func intimacySentence(for state: LockedState, minimumAge: Int) -> String {
        switch state {
        case .communicationLimits:
            String(localized: "ageGate.intimacy.communicationLimits",
                   defaultValue: "Intimacy tracking is turned off because communication limits are set for this Apple Account. Whoever manages it can change that in Screen Time.",
                   comment: "Settings: intimacy tracking is locked by a guardian's communication limits (not normally shown).")
        case .below:
            String(localized: "ageGate.intimacy.below", defaultValue: "Intimacy tracking is available at \(minimumAge) and older.",
                   comment: "Settings: intimacy tracking is locked because Apple placed the user below the minimum age. The argument is the age (16).")
        case .needsSystemCheck:
            String(localized: "ageGate.intimacy.needsSystemCheck",
                   defaultValue: "Intimacy tracking is for people \(minimumAge) and older, and Fernlet needs Apple to confirm your age range before turning it on. Your birthday is never shared.",
                   comment: "Settings: intimacy tracking needs Apple's age check (not normally shown). The argument is the age (16).")
        case .unclearAnswer:
            String(localized: "ageGate.intimacy.unclearAnswer",
                   defaultValue: "Intimacy tracking needs an age check, and Apple's answer wasn't specific enough to confirm you're \(minimumAge) or older.",
                   comment: "Settings: Apple's age answer was too vague to unlock intimacy tracking. The argument is the age (16).")
        case .unknownAge:
            String(localized: "ageGate.intimacy.unknownAge",
                   defaultValue: "Intimacy tracking is for people \(minimumAge) and older. Fernlet doesn't know your age yet — Apple can confirm your age range without sharing your birthday.",
                   comment: "Settings: intimacy tracking is locked until the user's age is checked. The argument is the age (16).")
        case .available:
            String(localized: "ageGate.intimacy.available", defaultValue: "Intimacy tracking is available.",
                   comment: "Settings: intimacy tracking is unlocked (not normally shown).")
        }
    }

    private static func messagingSentence(for state: LockedState, minimumAge: Int) -> String {
        switch state {
        case .communicationLimits:
            String(localized: "ageGate.chat.communicationLimits",
                   defaultValue: "Messaging friends nearby is turned off because communication limits are set for this Apple Account. Whoever manages it can change that in Screen Time.",
                   comment: "Settings: messaging friends nearby is locked by a guardian's communication limits (Screen Time).")
        case .below:
            String(localized: "ageGate.chat.below", defaultValue: "Messaging friends nearby is available at \(minimumAge) and older.",
                   comment: "Settings: messaging friends nearby is locked because Apple placed the user below the minimum age. The argument is the age (13).")
        case .needsSystemCheck:
            String(localized: "ageGate.chat.needsSystemCheck",
                   defaultValue: "Messaging friends nearby is for people \(minimumAge) and older, and Fernlet needs Apple to confirm your age range before turning it on. Your birthday is never shared.",
                   comment: "Settings: messaging friends nearby needs Apple's age check; there is no manual confirmation. The argument is the age (13).")
        case .unclearAnswer:
            String(localized: "ageGate.chat.unclearAnswer",
                   defaultValue: "Messaging friends nearby needs an age check, and Apple's answer wasn't specific enough to confirm you're \(minimumAge) or older.",
                   comment: "Settings: Apple's age answer was too vague to unlock messaging friends nearby (not normally shown: this gate takes the needs-system-check wording). The argument is the age (13).")
        case .unknownAge:
            String(localized: "ageGate.chat.unknownAge",
                   defaultValue: "Messaging friends nearby is for people \(minimumAge) and older. Fernlet doesn't know your age yet — Apple can confirm your age range without sharing your birthday.",
                   comment: "Settings: messaging friends nearby is locked until the user's age is checked (not normally shown: this gate takes the needs-system-check wording). The argument is the age (13).")
        case .available:
            String(localized: "ageGate.chat.available", defaultValue: "Messaging friends nearby is available.",
                   comment: "Settings: messaging friends nearby is unlocked (not normally shown).")
        }
    }
}
