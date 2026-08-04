import SwiftUI
import FernletFoundation

/// A single destructive/irreversible action pending the user's explicit confirmation.
///
/// The guiding principle of Fernlet's privacy model is that **nothing destructive happens silently**:
/// every Settings toggle or button that deletes data or removes a recovery path must route through this
/// type so the confirmation it renders (1) names the *exact* data, (2) states whether — and how — it's
/// recoverable, and (3) requires a destructive-role confirm before anything commits. Centralizing the
/// pattern in the shared `.destructiveConfirmation` modifier means a new destructive toggle can't ship
/// without a warning: the mutation only runs from `perform`, which only runs on confirm.
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
        let label: String
        /// Distinct from the primary's, so the log records WHICH irreversible choice was made.
        let auditEvent: String?
        let perform: () async -> Void

        init(label: String, auditEvent: String? = nil, perform: @escaping () async -> Void) {
            self.label = label
            self.auditEvent = auditEvent
            self.perform = perform
        }
    }

    let id = UUID()
    /// Alert title — phrase it as a question, e.g. "Turn off encrypted period backup?".
    let title: String
    /// Body — name the exact data affected and whether it can be recovered (and how).
    let message: String
    /// The destructive button's label, e.g. "Turn off", "Exclude", "Delete".
    let confirmLabel: String
    /// Audit event logged (with `confirmed=true`) when the user confirms. Optional but encouraged so
    /// every destructive path leaves a `FernletAuditLog` trail.
    let auditEvent: String?
    /// The second destructive choice, if this dialog offers one. Rendered after the primary.
    let secondaryConfirm: SecondaryConfirm?
    /// The mutation to run — ONLY on confirm. Cancelling runs nothing. Async so a confirm can await the
    /// work it triggered; a synchronous closure literal still satisfies it, so existing call sites are
    /// unchanged.
    let perform: () async -> Void

    init(
        title: String,
        message: String,
        confirmLabel: String,
        auditEvent: String? = nil,
        secondaryConfirm: SecondaryConfirm? = nil,
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
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            presenting: pending.wrappedValue
        ) { action in
            Button("Cancel", role: .cancel) { pending.wrappedValue = nil }
            Button(action.confirmLabel, role: .destructive) {
                commitDestructive(action.auditEvent, action.perform, clearing: pending)
            }
            if let secondary = action.secondaryConfirm {
                Button(secondary.label, role: .destructive) {
                    commitDestructive(secondary.auditEvent, secondary.perform, clearing: pending)
                }
            }
        } message: { action in
            Text(action.message)
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
