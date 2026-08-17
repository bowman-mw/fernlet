import SwiftUI
import FernletDomainModel
import FernletFoundation
import FernletUI

// MARK: - Guided workout sheet

/// The in-app guided flow: shows the current exercise, "Set X of Y", reps, a "Done set" button, and a
/// live rest countdown between sets. On natural completion the store logs the session (via
/// `finishGuidedRunLogging`), so it still counts.
///
/// The runner's state now lives on `FernletStore.guidedRunState`, mirrored into the app-group
/// container — NOT in this sheet's `@State`. That is what lets the Lock Screen / Dynamic Island Live
/// Activity buttons ("Done set" / "Skip rest") advance the very same run this sheet renders: the sheet
/// calls `store.guidedMarkSetDone()` / `store.guidedSkipRest()`, the intents mutate the shared
/// app-group state, and this sheet re-derives from `store.guidedRunState` (reconciling on foreground).
/// The Live Activity is requested when the run starts and ended by the store on finish/abandon; it now
/// outlives the sheet, so closing the sheet no longer kills a workout in progress.
struct GuidedWorkoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var store: FernletStore
    let session: WorkoutProgram.SessionSuggestion
    /// True when other sessions in today's plan still need doing after this one — the done copy then
    /// names what was logged instead of implying the whole day is.
    var sessionsRemain: Bool
    /// Ran (after this sheet's own dismiss) when the user declines to replace a live run — "Go back to
    /// it" promises a route to the Move-root Resume card, so a presenter that has this sheet NESTED
    /// inside another (the Suggest flow) passes its own dismiss here; otherwise closing just this sheet
    /// would strand the user on the Suggest configurator, whose Start loops back into the same dialog.
    /// The Move-root presenter leaves it nil — one dismiss already lands beside the Resume card.
    var onExitToResumeCard: (() -> Void)?

    @State private var showEndConfirm = false
    @State private var showReplaceConfirm = false

    init(
        store: FernletStore,
        session: WorkoutProgram.SessionSuggestion,
        sessionsRemain: Bool = false,
        onExitToResumeCard: (() -> Void)? = nil
    ) {
        self.store = store
        self.session = session
        self.sessionsRemain = sessionsRemain
        self.onExitToResumeCard = onExitToResumeCard
    }

    /// The active run iff it belongs to THIS session; otherwise nil (show the ready screen).
    private var run: GuidedWorkoutRunState? {
        guard let state = store.guidedRunState, state.sessionID == session.id else { return nil }
        return state
    }

    private var isLive: Bool { run?.isWorking == true || run?.isResting == true }

    /// Names the run that would be lost, so the trade is legible before it's made rather than after.
    private var replaceConfirmMessage: String {
        guard let other = store.activeGuidedRunBlockingStart(of: session) else { return "" }
        return "\(other.title) is still going. Starting this one will let go of the sets you've already done there."
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let run {
                        switch run.phase {
                        case .working: workingView(run)
                        case .resting: restingView(run)
                        case .done:
                            // An abandon dismisses straight away — only a natural finish shows the
                            // logged copy, so "End without logging" never flashes "That's logged".
                            if run.completedNaturally { doneView }
                        }
                    } else {
                        readyView
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .background(Color.parchment)
        .interactiveDismissDisabled(isLive)
        .confirmationDialog("End this session?", isPresented: $showEndConfirm, titleVisibility: .visible) {
            Button("End without logging", role: .destructive) {
                store.abandonGuidedRun()
                dismiss()
            }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("You can always come back and start again — no pressure.")
        }
        // Starting here would throw away a live run for a different session. Name what's at stake, and
        // let "Go back to it" close the sheet onto the Move-root Resume card that resumes the other run.
        .confirmationDialog(
            "You have a workout in progress",
            isPresented: $showReplaceConfirm,
            titleVisibility: .visible
        ) {
            Button("Start this one instead", role: .destructive) {
                // R7: a replace can still be refused (the plan moved on under us) — name it and get
                // out of the way rather than leaving the sheet pretending the run began.
                if !store.startGuidedRun(session, replacingActiveRun: true) {
                    FernletAuditLog.log("workout.guided.startRefused", context: ["replacing": "true"])
                    dismiss()
                }
            }
            Button("Go back to it", role: .cancel) {
                dismiss()
                // Nested presentation (the Suggest flow): also close the presenter, or the user lands on
                // the configurator whose Start re-opens this same dialog — a loop, not the promised
                // route back to the Resume card.
                onExitToResumeCard?()
            }
        } message: {
            Text(replaceConfirmMessage)
        }
        // Pick up a set/rest transition (or a finish) made from the Live Activity while the app was in
        // the background: reconcile the shared run so this sheet re-renders in step. `.onChange` doesn't
        // fire on first presentation, so `.onAppear` covers the initial sync.
        .onAppear { store.reconcileGuidedRunFromAppGroup() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            store.reconcileGuidedRunFromAppGroup()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.suggestion.name)
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                if let run, run.isWorking || run.isResting {
                    Text("Exercise \(run.exerciseIndex + 1) of \(run.totalExercises)")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                }
            }
            Spacer()
            Button {
                if isLive {
                    showEndConfirm = true
                } else {
                    if run?.isDone == true { store.clearGuidedRun() }
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.slate)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End session")
            .accessibilityIdentifier("workout.guided.end")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    // MARK: Phases

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Ready when you are")
                .font(.fernlet(.displayMedium))
                .foregroundStyle(Color.bark)
            Text("We'll walk through it together — one set at a time, with a gentle rest timer between. Go at a pace that feels good.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            VStack(spacing: 8) {
                ForEach(Array(session.exercises.enumerated()), id: \.element.id) { _, exercise in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(Color.moss.opacity(0.5))
                            .frame(width: 7, height: 7)
                            .padding(.top, 7)
                        Text(exercise.line)
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.bark)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                }
            }

            primaryButton("Start", identifier: "workout.guided.start") {
                // Another session's run may still be live — after a relaunch the Suggest sheet mints a
                // fresh session, so this Start can arrive with sets already done elsewhere. Ask first.
                if store.activeGuidedRunBlockingStart(of: session) != nil {
                    showReplaceConfirm = true
                } else if !store.startGuidedRun(session) {
                    // R7: the only refusal left is a run that became blocking between the check and
                    // the start — ask before throwing it away, instead of a Start that does nothing.
                    showReplaceConfirm = true
                }
            }
        }
    }

    private func workingView(_ run: GuidedWorkoutRunState) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            if let exercise = run.currentExercise {
                VStack(alignment: .leading, spacing: 10) {
                    Text(exercise.name)
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    if exercise.fromCatalog && exercise.sets >= 1 {
                        HStack(spacing: 10) {
                            metricPill(title: "Set", value: "\(run.currentSet) of \(run.totalSetsForCurrent)")
                            if !exercise.reps.isEmpty {
                                metricPill(title: "Reps", value: exercise.reps)
                            }
                        }
                    } else {
                        Text("Take it at your own pace.")
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.slate)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 16))

                Text(encouragement(run))
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                primaryButton(doneSetLabel(run), identifier: "workout.guided.doneSet") {
                    store.guidedMarkSetDone()
                }
            }
        }
    }

    private func restingView(_ run: GuidedWorkoutRunState) -> some View {
        VStack(alignment: .center, spacing: 22) {
            Text("Rest")
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.moss)

            if let restStartedAt = run.restStartedAt, let restEndsAt = run.restEndsAt, restStartedAt <= restEndsAt {
                // A fixed window: Text(timerInterval:) clamps to 0:00 once it expires, and the range
                // stays valid however long the user over-rests. A live `Date()` lower bound would invert
                // past the deadline and trap on the next body re-evaluation.
                Text(timerInterval: restStartedAt...restEndsAt, countsDown: true)
                    .font(.system(size: 68, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.bark)
                    .accessibilityIdentifier("workout.guided.restTimer")
            }

            if let exercise = run.currentExercise {
                VStack(spacing: 4) {
                    Text("Next up")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                    Text(exercise.name)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                    if exercise.fromCatalog && exercise.sets >= 1 {
                        Text("Set \(run.currentSet) of \(run.totalSetsForCurrent)")
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                    }
                }
            }

            Text("Rest as long as you need — the timer's only a nudge.")
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()

            secondaryButton("Skip rest", identifier: "workout.guided.skipRest") {
                store.guidedSkipRest()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private var doneView: some View {
        VStack(spacing: 16) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.moss)
            Text("Nicely done")
                .font(.fernlet(.displayMedium))
                .foregroundStyle(Color.bark)
            Text(completionMessage)
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
            primaryButton("Done", identifier: "workout.guided.close") {
                store.clearGuidedRun()
                dismiss()
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }

    private var completionMessage: String {
        sessionsRemain
            ? "\(session.suggestion.name) is logged. The rest of today's plan is there whenever you're ready."
            : "That's logged for today."
    }

    // MARK: Pieces

    private func doneSetLabel(_ run: GuidedWorkoutRunState) -> String {
        guard let exercise = run.currentExercise else { return "Done" }
        let isLastSet = run.currentSet >= max(1, exercise.sets)
        let isLastExercise = run.exerciseIndex >= run.totalExercises - 1
        if isLastSet && isLastExercise { return "Finish workout" }
        return "Done set"
    }

    private func encouragement(_ run: GuidedWorkoutRunState) -> String {
        switch run.currentSet {
        case 1: "No rush getting started."
        default: "Steady — you've got this."
        }
    }

    private func metricPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.fernlet(.labelSmall))
                .tracking(0.6)
                .foregroundStyle(Color.slate)
            Text(value)
                .font(.fernlet(.stat))
                .foregroundStyle(Color.bark)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.parchment, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.08), lineWidth: 1))
    }

    private func primaryButton(_ label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.fernlet(.label))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.moss, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func secondaryButton(_ label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.fernlet(.label))
                .foregroundStyle(Color.moss)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.moss.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
