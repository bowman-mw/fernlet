import FernletDomainModel
import FernletExchange
import FernletFoundation
import FernletUI
import SwiftUI

/// Fernlet-owned review for a workout plan received in Messages. It deliberately uses the same
/// canonical exchange service as file imports, so the visible message card never controls a write.
///
/// Add confirms itself (report §7, 2026-10-20): an added plan swaps the button for the "added" line
/// and plays `done`, holds for a beat, closes, and VoiceOver hears the line once the close has
/// settled. "Your calendar changed" — a refusal with the updated plan on screen to review — plays
/// `caveat`, as does a plan that saved but whose review could not be cleared; any other error plays
/// `failed`. Each is spoken beside its line (``ImportReviewLanding``). Cancel plays nothing.
struct MessagesWorkoutPlanImportReviewSheet: View {
    let record: FernletMessagesWorkoutInboxRecord
    let inbox: FernletMessagesRecipeInboxCoordinator
    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var startDate: Date
    @State private var collisionPolicy: WorkoutPlanCollisionPolicy = .keepExistingWorkouts
    @State private var preview: WorkoutPlanImportPreview?
    @State private var isLoadingPreview = true
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var previewRequest = 0
    /// The "added" line, set when the plan landed; the sheet holds it for a beat, then closes.
    @State private var landedLine: String?

    init(
        record: FernletMessagesWorkoutInboxRecord,
        inbox: FernletMessagesRecipeInboxCoordinator,
        onCompleted: @escaping () -> Void
    ) {
        self.record = record
        self.inbox = inbox
        self.onCompleted = onCompleted
        _startDate = State(initialValue: FernletDate.date(fromDayKey: record.suggestedStartDayKey ?? "") ?? .now)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    planHeader
                    schedulingControls
                    reviewContent
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(errorInk)
                    }
                    importButton
                }
                .padding(20)
            }
            .background(paperColor.ignoresSafeArea())
            // World build (`b3-messages-plan`): Cancel top left (off while adding) and the title in the sheet.
            .fernletSheetToolbar(title: "Review workout plan", onCancel: cancelAction)
            .task { await refreshPreview() }
            .onChange(of: startDayKey) { _, _ in Task { await refreshPreview() } }
            .onChange(of: collisionPolicy) { _, _ in Task { await refreshPreview() } }
        }
        .interactiveDismissDisabled(isImporting)
    }

    /// World build: the sheet's paper and the framed pieces.
    @Environment(\.fernletFramedLook) private var look

    /// Cancel: closes the review without adding anything — none while the plan is being added.
    private var cancelAction: (() -> Void)? {
        guard !isImporting else { return nil }
        return { dismiss() }
    }

    /// The sheet's ground: the look's paper, the system background without it.
    private var paperColor: Color { look?.paper ?? Color(.systemBackground) }

    /// An error line's ink: terracotta's text token under the look, red today.
    private var errorInk: Color { look == nil ? Color.red : Color.terracottaInk }

    private var startDayKey: String { FernletDate.dayKey(for: startDate) }

    private var planHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.packet.plan.title)
                .font(look == nil ? .title2.weight(.semibold) : FernletFramedFont.cardTitle)
                .foregroundStyle(look?.text ?? Color.primary)
            Text(senderLabel).foregroundStyle(look?.dim ?? Color.secondary)
            Text("\(record.packet.plan.days.count) days · \(record.packet.plan.sessionCount) workouts")
                .foregroundStyle(look?.dim ?? Color.secondary)
        }
    }

    private var senderLabel: String {
        record.packet.plan.coachDisplayName.isEmpty ? "Sender not specified" : record.packet.plan.coachDisplayName
    }

    @ViewBuilder private var schedulingControls: some View {
        if look != nil {
            // `b3-messages-plan`: the start date and the collision rule as framed rows.
            FernletFramedSection {
                DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                    .tint(Color.moss)
                FernletDropdown("If workouts collide", selection: $collisionPolicy,
                                options: [.keepExistingWorkouts, .addAlongside, .replaceFutureConflicts]) { policy in
                    Self.policyText(policy)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                Picker("If workouts collide", selection: $collisionPolicy) {
                    Text("Keep existing workouts").tag(WorkoutPlanCollisionPolicy.keepExistingWorkouts)
                    Text("Add alongside").tag(WorkoutPlanCollisionPolicy.addAlongside)
                    Text("Replace future conflicts").tag(WorkoutPlanCollisionPolicy.replaceFutureConflicts)
                }
                .pickerStyle(.menu)
            }
        }
    }

    /// A collision rule's words, as the menu draws them.
    static func policyText(_ policy: WorkoutPlanCollisionPolicy) -> Text {
        switch policy {
        case .keepExistingWorkouts: Text("Keep existing workouts")
        case .addAlongside: Text("Add alongside")
        case .replaceFutureConflicts: Text("Replace future conflicts")
        }
    }

    @ViewBuilder
    private var reviewContent: some View {
        if isLoadingPreview {
            ProgressView("Checking your workout calendar…")
        } else if let preview {
            previewSummary(preview)
        } else {
            Text("Fernlet couldn't prepare this plan for import.").foregroundStyle(.red)
        }
    }

    private func previewSummary(_ preview: WorkoutPlanImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(preview.startDayKey) – \(lastDayKey(for: preview))")
            Text("\(preview.review.collidingDayKeys.count) calendar collisions · \(policyLabel)")
            Text(changeCounts(for: preview))
            safetyFlags(for: preview)
        }
        .foregroundStyle(look?.text ?? Color.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(look == nil ? 0 : 15)
        .modifier(MessagesPlanCardFrame(isFramed: look != nil))
    }

    private func safetyFlags(for preview: WorkoutPlanImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !preview.review.safetyFlags.isEmpty {
                if look != nil {
                    SectionLabel("Check these against your limits")
                } else {
                    Text("Check these against your limits").font(.headline)
                }
                ForEach(preview.review.safetyFlags) { flag in
                    Text("• \(flag.exerciseName): \(flag.reason)")
                        .foregroundStyle(look == nil ? Color.orange : Color.terracottaInk)
                }
            }
        }
    }

    /// Add workout plan, or — once the plan landed — the "added" line in its place.
    @ViewBuilder
    private var importButton: some View {
        if let landedLine {
            ImportLandedLine(text: landedLine)
                .font(.headline)
        } else if look != nil {
            Button(action: beginImport) {
                Text(isImporting ? "Adding workout plan…" : "Add workout plan")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.primary))
            .disabled(isLoadingPreview || preview == nil || isImporting)
        } else {
            Button(action: beginImport) {
                Text(isImporting ? "Adding workout plan…" : "Add workout plan")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoadingPreview || preview == nil || isImporting)
        }
    }

    private var policyLabel: String {
        switch collisionPolicy {
        case .keepExistingWorkouts: "Keep existing workouts"
        case .addAlongside: "Add alongside"
        case .replaceFutureConflicts: "Replace future conflicts"
        }
    }

    private func lastDayKey(for preview: WorkoutPlanImportPreview) -> String {
        let highestDay = preview.review.plan.days.map(\.dayIndex).max() ?? 1
        return FernletStore.dayKey(startingOn: preview.startDayKey, offsetBy: highestDay - 1) ?? preview.startDayKey
    }

    private func changeCounts(for preview: WorkoutPlanImportPreview) -> String {
        let edits = preview.review.resolvedEdits.filter(\.isMeaningful)
        let changed = edits.filter { $0.action != .delete }.count
        let removed = edits.filter { $0.action == .delete }.count
        return "\(preview.review.plan.sessionCount) added · \(changed) changed · \(removed) removed"
    }

    @MainActor
    private func refreshPreview() async {
        previewRequest += 1
        let request = previewRequest
        isLoadingPreview = true
        do {
            let result = try await ExchangeIntentService.shared.workoutPreview(
                packet: record.packet, startDate: startDate, policy: collisionPolicy
            )
            guard request == previewRequest else { return }
            preview = result
            errorMessage = nil
        } catch {
            guard request == previewRequest else { return }
            preview = nil
            errorMessage = "Fernlet couldn't check this plan. Unlock your iPhone and try again."
        }
        guard request == previewRequest else { return }
        isLoadingPreview = false
    }

    /// Re-checks the calendar, adds the plan, and hands the outcome to ``ImportReviewLanding``.
    /// `isImporting` stays set through a landed plan's beat, so Cancel and the swipe stay off until
    /// the sheet closes itself.
    private func beginImport() {
        guard let preview, !isImporting else { return }
        isImporting = true
        errorMessage = nil
        Task { @MainActor in
            let outcome = await addPlan(reviewed: preview)
            switch outcome {
            case .added(let line):
                landedLine = line
            case .caveat(let line), .failed(let line):
                isImporting = false
                errorMessage = line
            }
            await ImportReviewLanding().answer(outcome) {
                onCompleted()
                dismiss()
            }
        }
    }

    /// The import itself: what one Add came to, decided only after the writes returned.
    @MainActor
    private func addPlan(reviewed: WorkoutPlanImportPreview) async -> ImportReviewOutcome {
        do {
            let current = try await ExchangeIntentService.shared.workoutPreview(
                packet: record.packet, startDate: startDate, policy: collisionPolicy
            )
            guard current.matches(reviewed) else {
                self.preview = current
                return Self.outcome(for: ExchangeIntentServiceError.reviewChanged)
            }
            let result = try await ExchangeIntentService.shared.importWorkoutPlan(current)
            guard !result.id.isEmpty else { throw ExchangeIntentServiceError.invalidPacket }
            guard inbox.consumeWorkout(id: record.id) else {
                return .caveat(String(
                    localized: "messagesWorkoutPlanImport.savedNotCleared",
                    defaultValue: "Saved the plan, but Fernlet couldn't clear this review. Try adding it again.",
                    comment: "Shown in the Messages workout plan review sheet when the plan was saved but the review it came from could not be cleared."))
            }
            return .added(String(
                localized: "messagesWorkoutPlanImport.added",
                defaultValue: "\u{201C}\(record.packet.plan.title)\u{201D} is on your workout calendar.",
                comment: "Shown in the Messages workout plan review sheet for a moment after Add workout plan, before it closes, and spoken once it has. The title is the plan's, as the sender named it."))
        } catch {
            return Self.outcome(for: error)
        }
    }

    /// What an Add that threw came to: the calendar changing under the review is a `caveat` — the
    /// updated plan is on screen to look over and add again — and anything else is `failed`.
    static func outcome(for error: Error) -> ImportReviewOutcome {
        if case ExchangeIntentServiceError.reviewChanged = error {
            return .caveat(String(
                localized: "messagesWorkoutPlanImport.calendarChanged",
                defaultValue: "Your calendar changed. Review the updated plan, then add it again.",
                comment: "Shown in the Messages workout plan review sheet when the workout calendar changed between the review and Add, so nothing was added and the updated plan is now on screen."))
        }
        return .failed(String(
            localized: "messagesWorkoutPlanImport.failed",
            defaultValue: "Fernlet couldn't add this workout plan.",
            comment: "Shown in the Messages workout plan review sheet when adding the plan failed for any reason other than the calendar changing."))
    }
}

/// The plan preview's card under the World look (`b3-messages-plan`); nothing around it today.
private struct MessagesPlanCardFrame: ViewModifier {
    let isFramed: Bool

    func body(content: Content) -> some View {
        if isFramed {
            content.modifier(MoveInsetCardFrame())
        } else {
            content
        }
    }
}
