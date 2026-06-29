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
    /// The mutation to run — ONLY on confirm. Cancelling runs nothing.
    let perform: () -> Void

    init(
        title: String,
        message: String,
        confirmLabel: String,
        auditEvent: String? = nil,
        perform: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.auditEvent = auditEvent
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
                if let event = action.auditEvent {
                    FernletAuditLog.log(event, context: ["confirmed": "true"])
                }
                action.perform()
                pending.wrappedValue = nil
            }
        } message: { action in
            Text(action.message)
        }
    }
}
