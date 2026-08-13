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
    /// Sentence-case feature name, used mid-sentence ("Intimacy tracking is available at…").
    let featureName: String
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
            Text("Fernlet couldn't check your age with Apple, so this is your word for it. Only confirm if you really are \(gate.minimumAge) or older — \(featureName.lowercased()) is meant for people that age and up.")
        }
    }

    private var message: String {
        // Checked before the age verdict, mirroring `AgeAssuranceRecord.allows`: a restricted account
        // may well pass the age check, and saying "you're too young" there would be simply untrue.
        if gate.isInterpersonalCommunication, ageAssurance.record.hasCommunicationLimits {
            return "\(featureName) is turned off because communication limits are set for this Apple Account. Whoever manages it can change that in Screen Time."
        }
        switch verdict {
        case .below:
            return "\(featureName) is available at \(gate.minimumAge) and older."
        case .undetermined where !gate.allowsSelfAttestation:
            // `.chat`: no manual route exists, so the copy must not imply one.
            return "\(featureName) is for people \(gate.minimumAge) and older, and Fernlet needs Apple to confirm your age range before turning it on. Your birthday is never shared."
        case .undetermined where ageAssurance.isDetermined:
            // The system returned a bracket, but without provenance Fernlet can't treat it as a claim of
            // being old enough. Rare; worth its own wording so the next step isn't a mystery.
            return "\(featureName) needs an age check, and Apple's answer wasn't specific enough to confirm you're \(gate.minimumAge) or older."
        case .undetermined:
            return "\(featureName) is for people \(gate.minimumAge) and older. Fernlet doesn't know your age yet — Apple can confirm your age range without sharing your birthday."
        case .meets:
            // Unreachable: the caller shows the feature's real control instead. Kept honest rather than
            // fatalError'd so a wiring slip degrades to a harmless line.
            return "\(featureName) is available."
        }
    }
}
