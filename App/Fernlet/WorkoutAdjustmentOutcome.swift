import Foundation
import FernletDomainModel

/// What "Adjust with AI" did to today's plan (the owner's fix s2, 2026-11-10, review finding E6).
///
/// The adjustment used to hand back a plan whatever happened — AI off, today's budget used up, an
/// empty reply, a thrown error all returned the plan it was given — and the plan pane cleared the
/// request field as if it had worked. Now the service says which: the adjusted plan, or the reason
/// nothing changed, and the pane keeps the request and shows the reason (``WorkoutAdjustField``).
enum WorkoutAdjustmentOutcome {
    /// At least one session changed: the plan to commit in place of the one adjusted.
    case changed(WorkoutProgram.DayPlan)
    /// Nothing changed, and why.
    case unchanged(Reason)

    /// The most sessions of one plan an adjustment reads (a split day has one or two).
    static let maximumSessions = 6

    /// Why an adjustment changed nothing.
    enum Reason: Equatable, CaseIterable {
        /// AI is switched off, or this device has no on-device model.
        case aiOff
        /// The model could not be asked just now, failed, or answered with nothing usable.
        case couldNot
        /// The reply asked for the session the plan already has (or the plan has nothing to adjust).
        case nothingNeeded
        /// The reply would have left fewer than 3 lifts in a session that had 4 or more: refused.
        case tooFewLifts

        /// The one reason shown when a plan's sessions gave several: a refusal first (the request was
        /// understood and turned down), then a failure, then AI being off, then nothing to change.
        static func strongest(of reasons: [Reason]) -> Reason {
            for reason in [Reason.tooFewLifts, .couldNot, .aiOff] where reasons.contains(reason) { return reason }
            return .nothingNeeded
        }

        /// The line the plan pane shows and VoiceOver hears.
        var message: String {
            switch self {
            case .aiOff:
                String(localized: "move.adjust.aiOff", defaultValue: "On-device AI is off.",
                       comment: "Line under the 'Adjust with AI' field on today's workout plan: the request was not applied because on-device AI is switched off or not available on this device. The request stays in the field.")
            case .couldNot:
                String(localized: "move.adjust.couldNot", defaultValue: "Couldn't adjust just now. Try again.",
                       comment: "Line under the 'Adjust with AI' field on today's workout plan: the on-device model could not answer this time. The request stays in the field.")
            case .nothingNeeded:
                String(localized: "move.adjust.nothingNeeded", defaultValue: "Nothing needed changing.",
                       comment: "Line under the 'Adjust with AI' field on today's workout plan: the plan already matches what the person asked for, so it is unchanged. The request stays in the field.")
            case .tooFewLifts:
                String(localized: "move.adjust.tooFewLifts", defaultValue: "That would leave too few lifts, so your plan is as it was.",
                       comment: "Line under the 'Adjust with AI' field on today's workout plan: the adjustment was refused because it would have left fewer than three exercises in a session that had four or more. The plan is unchanged and the request stays in the field.")
            }
        }
    }
}

/// The "Adjust with AI" field after an adjustment: what it holds and the line under it.
///
/// The request is cleared only when the plan changed. When nothing changed it stays exactly as typed,
/// so the person can try again or reword it, and the reason is shown.
struct WorkoutAdjustField: Equatable {
    /// The field's text.
    var request: String
    /// Why nothing changed; nil when the plan changed.
    var notice: WorkoutAdjustmentOutcome.Reason?

    /// The field after `outcome`, for the `request` it was run with.
    static func after(_ outcome: WorkoutAdjustmentOutcome, request: String) -> WorkoutAdjustField {
        switch outcome {
        case .changed: WorkoutAdjustField(request: "", notice: nil)
        case .unchanged(let reason): WorkoutAdjustField(request: request, notice: reason)
        }
    }
}
