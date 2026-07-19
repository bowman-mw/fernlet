import SwiftUI
import FernletDomainModel

// MARK: - Guided-session runner (app-side state machine)

/// Walks the user through a prescribed `SessionSuggestion` one set at a time, timing the rest
/// between sets. This is the "start a workout" flow the app was missing — the rest of the Move tab
/// only *logs* completed sessions. Deliberately app-side (not in FernletDomainModel): it merely
/// consumes the domain's `PrescribedExercise` / `SlotRole` / `GoalType`, so it needs no clean build
/// and stays out of the sealed stores.
///
/// The state machine is pure and deterministic: `now` and the rest-duration source are injectable so
/// transitions can be unit-tested without sleeping on a wall clock.
@MainActor
@Observable
final class WorkoutSessionRunner {
    enum Phase: Equatable {
        case ready      // shown the plan, not started
        case working    // doing the current set
        case resting    // between sets, counting down
        case done       // finished (naturally) or ended (abandoned)
    }

    let exercises: [PrescribedExercise]
    let goal: GoalType

    private let now: () -> Date
    private let restProvider: (SlotRole, GoalType) -> Int

    /// 0-based index into `exercises`.
    private(set) var exerciseIndex: Int = 0
    /// 1-based set counter for the current exercise.
    private(set) var currentSet: Int = 1
    private(set) var phase: Phase = .ready
    /// When the current rest ends. Drives the live `Text(timerInterval:)` countdown in the sheet.
    private(set) var restEndsAt: Date? = nil
    /// When the current rest began. Paired with `restEndsAt` so the sheet can render a *fixed*
    /// `Text(timerInterval:)` range that stays valid after the deadline passes — over-resting is a
    /// designed state, and a live `Date()...restEndsAt` lower bound would invert and trap once the
    /// countdown expires. Always set and cleared together with `restEndsAt`.
    private(set) var restStartedAt: Date? = nil
    /// Seconds of the most recent rest — exposed separately from `restEndsAt` so tests can assert the
    /// rest length without touching the clock.
    private(set) var restDuration: Int = 0
    /// True only after the session was walked all the way to the end. `end()` (an early exit) leaves
    /// this false, so the sheet logs the workout on natural completion but not on an abandon.
    private(set) var completedNaturally: Bool = false
    /// Flipped by `consumeCompletion()` so the completion side effects can only ever fire once.
    private(set) var completionReported: Bool = false

    init(
        exercises: [PrescribedExercise],
        goal: GoalType,
        now: @escaping () -> Date = Date.init,
        restProvider: @escaping (SlotRole, GoalType) -> Int = WorkoutSessionRunner.restSeconds(for:goal:)
    ) {
        self.exercises = exercises
        self.goal = goal
        self.now = now
        self.restProvider = restProvider
    }

    // MARK: Derived

    var currentExercise: PrescribedExercise? {
        exercises.indices.contains(exerciseIndex) ? exercises[exerciseIndex] : nil
    }

    /// A cardio/conditioning descriptor line carries `sets == 0`; treat it as a single completable
    /// step so the guided flow can walk through it without looping to zero.
    var totalSetsForCurrent: Int {
        max(1, currentExercise?.sets ?? 1)
    }

    var totalExercises: Int { exercises.count }

    // MARK: Actions

    func start() {
        exerciseIndex = 0
        currentSet = 1
        restStartedAt = nil
        restEndsAt = nil
        restDuration = 0
        completedNaturally = false
        completionReported = false
        phase = exercises.isEmpty ? .done : .working
    }

    /// Mark the current set done. More sets of this exercise → rest; last set of this exercise →
    /// straight to the next exercise; last set of the last exercise → done.
    func completeSet() {
        guard phase == .working, let exercise = currentExercise else { return }
        let total = max(1, exercise.sets)
        if currentSet < total {
            currentSet += 1
            beginRest(for: exercise.role)
        } else if exerciseIndex < exercises.count - 1 {
            exerciseIndex += 1
            currentSet = 1
            restStartedAt = nil
            restEndsAt = nil
            phase = .working
        } else {
            finish()
        }
    }

    /// End the rest early and resume the next set (the counters were already advanced when the rest
    /// began).
    func skipRest() {
        guard phase == .resting else { return }
        restStartedAt = nil
        restEndsAt = nil
        if currentExercise == nil {
            finish()
        } else {
            phase = .working
        }
    }

    /// Abandon the session. Goes to `.done` but leaves `completedNaturally` false, so nothing is
    /// logged.
    func end() {
        restStartedAt = nil
        restEndsAt = nil
        phase = .done
    }

    /// One-shot gate for the completion side effects (logging the workout, advancing progression).
    /// Returns true exactly once — on the first call after a natural finish; any repeat (a
    /// same-runloop double-tap of "Finish workout", a re-entrant UI event) is a no-op.
    func consumeCompletion() -> Bool {
        guard phase == .done, completedNaturally, !completionReported else { return false }
        completionReported = true
        return true
    }

    private func beginRest(for role: SlotRole) {
        let seconds = max(0, restProvider(role, goal))
        restDuration = seconds
        let started = now()
        restStartedAt = started
        restEndsAt = started.addingTimeInterval(TimeInterval(seconds))
        phase = .resting
    }

    private func finish() {
        restStartedAt = nil
        restEndsAt = nil
        completedNaturally = true
        phase = .done
    }

    // MARK: Rest durations

    /// How long to rest after a set, by movement role and goal. Compounds (`.main`) rest longer than
    /// accessories/core; strength-leaning goals rest a touch longer still, while the gentler goals
    /// keep rests short so a session stays brisk and unintimidating. Pure — unit-testable.
    static func restSeconds(for role: SlotRole, goal: GoalType) -> Int {
        let base: Int
        switch role {
        case .main: base = 150
        case .accessory: base = 75
        case .core: base = 60
        }
        let adjustment: Int
        switch goal {
        case .strength, .sportsPrep: adjustment = 15
        case .recovery, .mentalHealth: adjustment = -15
        case .wellness, .weightManagement, .exploring: adjustment = 0
        }
        return max(30, base + adjustment)
    }
}

// MARK: - Guided workout sheet

/// The in-app guided flow: shows the current exercise, "Set X of Y", reps, a "Done set" button, and
/// a live rest countdown between sets. On natural completion it logs the session through the same
/// path the retroactive "Mark done" button uses (via `onComplete`), so the workout still counts.
///
/// A Lock Screen / Dynamic Island Live Activity mirrors this flow, with a lifetime equal to this
/// sheet's: `WorkoutLiveActivityController` starts it on the first working set, `update`s it on each
/// set/exercise transition (via `syncLiveActivity`), and `end`s it on natural finish, abandon, or the
/// sheet's `onDisappear`. It degrades silently to in-app-only when Live Activities are disabled.
struct GuidedWorkoutSheet: View {
    @Environment(\.dismiss) private var dismiss

    let session: WorkoutProgram.SessionSuggestion
    /// True when other sessions in today's plan still need marking done after this one — the done
    /// copy then names what was logged instead of implying the whole day is.
    var sessionsRemain: Bool
    /// Logs the finished session. Called once, only on natural completion.
    var onComplete: () -> Void

    @State private var runner: WorkoutSessionRunner
    @State private var showEndConfirm = false
    /// One controller per sheet presentation — the Live Activity's lifetime equals this sheet's, so an
    /// `end` here can only ever touch this presentation's own activity, never a later sheet's.
    @State private var liveActivity = WorkoutLiveActivityController()

    init(
        session: WorkoutProgram.SessionSuggestion,
        goal: GoalType,
        sessionsRemain: Bool = false,
        onComplete: @escaping () -> Void
    ) {
        self.session = session
        self.sessionsRemain = sessionsRemain
        self.onComplete = onComplete
        _runner = State(initialValue: WorkoutSessionRunner(exercises: session.exercises, goal: goal))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch runner.phase {
                    case .ready: readyView
                    case .working: workingView
                    case .resting: restingView
                    case .done:
                        // An abandon dismisses straight away — only a natural finish shows the
                        // logged copy, so "End without logging" never flashes "That's logged".
                        if runner.completedNaturally { doneView }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .background(Color.parchment)
        .interactiveDismissDisabled(runner.phase == .working || runner.phase == .resting)
        .confirmationDialog("End this session?", isPresented: $showEndConfirm, titleVisibility: .visible) {
            Button("End without logging", role: .destructive) {
                runner.end()
                syncLiveActivity()
                dismiss()
            }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("You can always come back and start again — no pressure.")
        }
        // Belt-and-braces: end any still-live activity when the sheet goes away — covers a swipe
        // dismiss in `.ready`, the done screen close, and any path not handled explicitly. `end` is a
        // no-op once the activity is already ended, so this never double-ends, and because the
        // controller is @State-scoped to THIS presentation it can't end a later sheet's activity.
        .onDisappear {
            liveActivity.end(final: WorkoutActivityAttributes.ContentState(runner: runner))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.suggestion.name)
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                if runner.phase == .working || runner.phase == .resting {
                    Text("Exercise \(runner.exerciseIndex + 1) of \(runner.totalExercises)")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                }
            }
            Spacer()
            Button {
                if runner.phase == .working || runner.phase == .resting {
                    showEndConfirm = true
                } else {
                    runner.end()
                    syncLiveActivity()
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
                runner.start()
                startLiveActivity()
            }
        }
    }

    private var workingView: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let exercise = runner.currentExercise {
                VStack(alignment: .leading, spacing: 10) {
                    Text(exercise.name)
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    if exercise.fromCatalog && exercise.sets >= 1 {
                        HStack(spacing: 10) {
                            metricPill(title: "Set", value: "\(runner.currentSet) of \(runner.totalSetsForCurrent)")
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

                Text(encouragement)
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                primaryButton(doneSetLabel, identifier: "workout.guided.doneSet") {
                    runner.completeSet()
                    syncLiveActivity()
                    logIfDone()
                }
            }
        }
    }

    private var restingView: some View {
        VStack(alignment: .center, spacing: 22) {
            Text("Rest")
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.moss)

            if let restStartedAt = runner.restStartedAt, let restEndsAt = runner.restEndsAt {
                // A fixed window: Text(timerInterval:) clamps to 0:00 once it expires, and the
                // range stays valid however long the user over-rests. A live `Date()` lower bound
                // would invert past the deadline and trap on the next body re-evaluation.
                Text(timerInterval: restStartedAt...restEndsAt, countsDown: true)
                    .font(.system(size: 68, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.bark)
                    .accessibilityIdentifier("workout.guided.restTimer")
            }

            if let exercise = runner.currentExercise {
                VStack(spacing: 4) {
                    Text("Next up")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                    Text(exercise.name)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                    if exercise.fromCatalog && exercise.sets >= 1 {
                        Text("Set \(runner.currentSet) of \(runner.totalSetsForCurrent)")
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
                runner.skipRest()
                syncLiveActivity()
                logIfDone()
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

    // MARK: Completion

    /// On natural completion, log through the shared path — `onComplete` owns the logging — then
    /// let the done view linger until the user closes it. The runner's one-shot
    /// `consumeCompletion()` makes any re-fire (a same-runloop double-tap of "Finish workout")
    /// a no-op, so the workout can't be logged twice.
    private func logIfDone() {
        guard runner.consumeCompletion() else { return }
        onComplete()
    }

    // MARK: Live Activity

    /// Request the Lock Screen / Dynamic Island activity when the workout begins — but only if the
    /// runner actually entered a live phase (an empty session goes straight to `.done`, so nothing to
    /// show). Silently no-ops when Live Activities are disabled.
    private func startLiveActivity() {
        guard runner.phase == .working || runner.phase == .resting else { return }
        liveActivity.start(
            title: session.suggestion.name,
            state: WorkoutActivityAttributes.ContentState(runner: runner)
        )
    }

    /// Mirror the runner's latest state onto the activity after a transition: update while the session
    /// is live, end (with a brief final state + immediate dismissal) once it reaches `.done`.
    private func syncLiveActivity() {
        let state = WorkoutActivityAttributes.ContentState(runner: runner)
        switch runner.phase {
        case .working, .resting:
            liveActivity.update(state: state)
        case .done:
            liveActivity.end(final: state)
        case .ready:
            break
        }
    }

    // MARK: Pieces

    private var doneSetLabel: String {
        guard let exercise = runner.currentExercise else { return "Done" }
        let isLastSet = runner.currentSet >= max(1, exercise.sets)
        let isLastExercise = runner.exerciseIndex >= runner.totalExercises - 1
        if isLastSet && isLastExercise { return "Finish workout" }
        return "Done set"
    }

    private var encouragement: String {
        switch runner.currentSet {
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
