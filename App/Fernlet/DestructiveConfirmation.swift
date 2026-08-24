import SwiftUI
import FernletFoundation
import FernletUI

/// A single destructive/irreversible action pending the user's explicit confirmation.
///
/// The guiding principle of Fernlet's privacy model is that **nothing destructive happens silently**:
/// every Settings toggle or button that deletes data or removes a recovery path must route through this
/// type so the confirmation it renders (1) names the *exact* data, (2) states whether — and how — it's
/// recoverable, and (3) requires a destructive-role confirm before anything commits. Centralizing the
/// pattern in the shared `.destructiveConfirmation` modifier means a new destructive toggle can't ship
/// without a warning: the mutation only runs from `perform`, which only runs on confirm.
///
/// **The title and both button labels are `LocalizedStringKey`, and the body is a `Text`**
/// (accessibility review T2-1).
/// They were plain `String`s, which meant the compiler harvested nothing and SwiftUI's
/// `StringProtocol` overloads of `alert(_:…)`, `Button(_:role:)` and `Text(_:)` rendered them
/// verbatim — so every irreversible-action dialog in the app, all 23 production ones, was frozen English
/// with a clean build. A component whose whole promise is that the user *understood* what they were
/// about to lose cannot be the one component that never translates. The fork is source-compatible:
/// a string literal (interpolations included) converts to `LocalizedStringKey` at every call site,
/// so only a site passing a `String`-typed *variable* had to change — and each of those had to
/// decide, deliberately, whether its words were copy or already-resolved text.
struct DestructiveConfirmation: Identifiable {
    /// A SECOND destructive outcome, for the rare dialog where the honest question isn't "do this or
    /// not" but "which of two irreversible things do you mean" — deleting everything Fernlet stores,
    /// with or without the samples Fernlet wrote to Apple Health.
    ///
    /// Both outcomes are destructive, both are spelled out in `message`, and offering the choice is
    /// what stops Fernlet from silently picking on the user's behalf. Nil for every ordinary
    /// confirm-or-cancel dialog.
    struct SecondaryConfirm {
        /// Must say how it differs from `confirmLabel`, e.g. "Delete from Health too" beside "Delete".
        let label: LocalizedStringKey
        /// Distinct from the primary's, so the log records WHICH irreversible choice was made.
        let auditEvent: String?
        let perform: () async -> Void

        init(label: LocalizedStringKey, auditEvent: String? = nil, perform: @escaping () async -> Void) {
            self.label = label
            self.auditEvent = auditEvent
            self.perform = perform
        }
    }

    let id = UUID()
    /// Alert title — phrase it as a question, e.g. "Turn off encrypted period backup?".
    let title: LocalizedStringKey
    /// Body — name the exact data affected and whether it can be recovered (and how).
    ///
    /// A `Text` rather than a `LocalizedStringKey` because two dialogs *compose* their body from
    /// conditional fragments (the delete-everything funnel and the workout-location delete), and a
    /// composed body cannot be a single catalog key. Both initializers below settle which kind of
    /// string it was, once, so nothing downstream has to branch.
    let message: Text
    /// The destructive button's label, e.g. "Turn off", "Exclude", "Delete".
    let confirmLabel: LocalizedStringKey
    /// Audit event logged (with `confirmed=true`) when the user confirms. Optional but encouraged so
    /// every destructive path leaves a `FernletAuditLog` trail.
    let auditEvent: String?
    /// The second destructive choice, if this dialog offers one. Rendered after the primary.
    let secondaryConfirm: SecondaryConfirm?
    /// The mutation to run — ONLY on confirm. Cancelling runs nothing. Async so a confirm can await the
    /// work it triggered; a synchronous closure literal still satisfies it, so existing call sites are
    /// unchanged.
    let perform: () async -> Void

    /// The localizing initializer — the one 25 of the 26 construction sites use (23 production, 3
    /// in tests; exactly one of those 26 assembles its body and takes the `verbatimMessage:` form).
    ///
    /// The literals are harvested into the app's own string catalog and looked up in `Bundle.main`,
    /// which is the app bundle: every destructive dialog lives in the app target.
    init(
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        confirmLabel: LocalizedStringKey,
        auditEvent: String? = nil,
        secondaryConfirm: SecondaryConfirm? = nil,
        perform: @escaping () async -> Void
    ) {
        self.init(
            title: title, message: Text(message), confirmLabel: confirmLabel,
            auditEvent: auditEvent, secondaryConfirm: secondaryConfirm, perform: perform
        )
    }

    /// The non-localizing initializer, for a body **assembled at runtime** from fragments the caller
    /// has already localized itself (`DeleteAllDataConfirmation.message(…)` bolts up to four
    /// sentences together depending on what the user actually has in iCloud).
    ///
    /// The distinct `verbatimMessage:` label is the safeguard, exactly as in ``SectionLabel`` and
    /// ``EmptyState``: a same-label `String` overload would win overload resolution for every plain
    /// literal and quietly un-localize all 23 production dialogs again without a single warning. Callers using
    /// this must localize their own fragments — the label says the string is finished, not that it
    /// is exempt.
    init(
        title: LocalizedStringKey,
        verbatimMessage: String,
        confirmLabel: LocalizedStringKey,
        auditEvent: String? = nil,
        secondaryConfirm: SecondaryConfirm? = nil,
        perform: @escaping () async -> Void
    ) {
        self.init(
            title: title, message: Text(verbatim: verbatimMessage), confirmLabel: confirmLabel,
            auditEvent: auditEvent, secondaryConfirm: secondaryConfirm, perform: perform
        )
    }

    /// The single designated initializer both public forms funnel through.
    private init(
        title: LocalizedStringKey,
        message: Text,
        confirmLabel: LocalizedStringKey,
        auditEvent: String?,
        secondaryConfirm: SecondaryConfirm?,
        perform: @escaping () async -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.auditEvent = auditEvent
        self.secondaryConfirm = secondaryConfirm
        self.perform = perform
    }
}

extension View {
    /// Presents a destructive-role confirmation whenever `pending` is non-nil. The bound action's
    /// `perform` closure runs only when the user taps the destructive button; cancelling clears the
    /// binding and mutates nothing. Apply once near the root of a settings screen and drive every
    /// destructive toggle by assigning a `DestructiveConfirmation` to the binding instead of mutating
    /// state directly.
    func destructiveConfirmation(_ pending: Binding<DestructiveConfirmation?>) -> some View {
        alert(
            pending.wrappedValue?.title ?? "",
            isPresented: pending.isPresent(),
            presenting: pending.wrappedValue
        ) { action in
            Button("Cancel", role: .cancel) { pending.wrappedValue = nil }  // app target: Bundle.main is right
            Button(action.confirmLabel, role: .destructive) {
                commitDestructive(action.auditEvent, action.perform, clearing: pending)
            }
            if let secondary = action.secondaryConfirm {
                Button(secondary.label, role: .destructive) {
                    commitDestructive(secondary.auditEvent, secondary.perform, clearing: pending)
                }
            }
        } message: { action in
            action.message
        }
    }
}

/// Logs the choice, dismisses the alert, then runs the mutation. Shared by BOTH destructive buttons so a
/// second outcome cannot ship with a different — or missing — audit trail than the first.
///
/// The binding is cleared BEFORE the work starts (the sync version cleared it after): with an async
/// `perform` the alert must not sit on screen for the duration of a wipe.
@MainActor
private func commitDestructive(
    _ auditEvent: String?,
    _ perform: @escaping () async -> Void,
    clearing pending: Binding<DestructiveConfirmation?>
) {
    if let auditEvent {
        FernletAuditLog.log(auditEvent, context: ["confirmed": "true"])
    }
    pending.wrappedValue = nil
    Task { await perform() }
}
