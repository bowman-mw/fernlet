import SwiftUI
import DeclaredAgeRange
import FernletDomainModel

/// The single seam between Fernlet and Apple's `DeclaredAgeRange` framework.
///
/// Nothing else in the app imports it — the rest of the codebase deals in `AgeAssuranceRecord`
/// primitives, so every gating rule stays testable without the entitlement, a signed-in Apple Account,
/// or a system prompt.
///
/// Requires the `com.apple.developer.declared-age-range` entitlement (see `Fernlet.entitlements`).
/// Without it the request throws and Fernlet lands on `.undetermined` — locked, but with the manual
/// confirmation still available, so a provisioning slip degrades to friction rather than a dead app.
enum AgeAssuranceRequest {
    /// Asks the system to bracket the user against all three of Fernlet's gates at once and records the
    /// outcome. One prompt answers 13, 16, and 18 — the framework accepts at most three thresholds, and
    /// Fernlet has exactly three, so nobody is ever asked twice.
    ///
    /// Every failure path lands on `.undetermined` rather than propagating: a thrown `.notAvailable`
    /// (account has no age information, or the entitlement is missing) and an explicit "Don't Share" are
    /// the same thing as far as the gate is concerned — no usable claim — and both leave the manual
    /// confirmation as the way through.
    @MainActor
    static func perform(_ action: DeclaredAgeRangeAction, into store: AgeAssuranceStore) async {
        do {
            let response = try await action(
                ageGates: AgeGate.chat.minimumAge,
                AgeGate.intimacy.minimumAge,
                AgeGate.adult.minimumAge
            )
            switch response {
            case .sharing(let range):
                store.applyDetermination(
                    lowerBound: range.lowerBound,
                    upperBound: range.upperBound,
                    provenance: provenance(from: range.ageRangeDeclaration),
                    // A guardian has restricted who this account may communicate with. Closes mesh chat
                    // on its own, independently of the age bracket — the guardian has already answered
                    // the question the age check was asking.
                    hasCommunicationLimits: range.activeParentalControls.contains(.communicationLimits)
                )
            case .declinedSharing:
                store.applyUndetermined()
            @unknown default:
                store.applyUndetermined()
            }
        } catch {
            store.applyUndetermined()
        }
    }

    /// Maps the system's provenance onto Fernlet's.
    ///
    /// `default` rather than an exhaustive switch, on purpose. The cases it absorbs are the pre-26.5
    /// spellings (`governmentIDChecked`, `paymentChecked`, and their guardian variants) that Apple
    /// deprecated in favour of `.confirmed` — unreachable at this app's 26.5 deployment floor, and
    /// naming them would only buy deprecation warnings. Anything genuinely new lands here too and maps
    /// to `nil`, which reads as "no usable provenance" and therefore fails closed: an unrecognized
    /// provenance can never open a gate, but it also can never wrongly close one, because
    /// `AgeAssuranceRecord.verdict(for:)` only consults provenance in the permissive direction.
    static func provenance(
        from declaration: AgeRangeService.AgeRangeDeclaration?
    ) -> AgeAssuranceProvenance? {
        switch declaration {
        case .selfDeclared: .selfDeclared
        case .guardianDeclared: .guardianDeclared
        case .confirmed: .confirmed
        default: nil
        }
    }
}

extension View {
    /// Runs the system age-range request whenever `trigger` flips true, records the outcome in `store`,
    /// then flips it back and calls `onFinish`.
    ///
    /// A modifier rather than a plain `async` helper because `\.requestAgeRange` is a SwiftUI
    /// environment action — it has to be read from inside a view.
    func requestsAgeRange(
        when trigger: Binding<Bool>,
        into store: AgeAssuranceStore,
        onFinish: @escaping () -> Void = {}
    ) -> some View {
        modifier(AgeRangeRequestModifier(store: store, isRequesting: trigger, onFinish: onFinish))
    }
}

private struct AgeRangeRequestModifier: ViewModifier {
    let store: AgeAssuranceStore
    @Binding var isRequesting: Bool
    let onFinish: () -> Void

    @Environment(\.requestAgeRange) private var requestAgeRange

    func body(content: Content) -> some View {
        content.task(id: isRequesting) {
            // `.task(id:)` also fires on first appearance, when nothing has been asked for yet.
            guard isRequesting else { return }
            await AgeAssuranceRequest.perform(requestAgeRange, into: store)
            isRequesting = false
            onFinish()
        }
    }
}
