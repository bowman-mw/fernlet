import SwiftUI
import FernletDomainModel
import FernletFoundation
import FernletUI

// MARK: - Guided workout sheet

/// The in-app guided flow: shows the current exercise, "Set X of Y", reps, a segmented set strip,
/// the upcoming rest, the next exercises, and a live rest countdown between sets. On natural
/// completion the store logs the session (via `finishGuidedRunLogging`), so it still counts.
///
/// The runner's state now lives on `FernletStore.guidedRunState`, mirrored into the app-group
/// container — NOT in this sheet's `@State`. That is what lets the Lock Screen / Dynamic Island Live
/// Activity buttons ("Done set" / "Skip rest") advance the very same run this sheet renders: the sheet
/// calls `store.guidedMarkSetDone()` / `store.guidedSkipRest()`, the intents mutate the shared
/// app-group state, and this sheet re-derives from `store.guidedRunState` (reconciling on foreground).
/// The Live Activity is requested when the run starts and ended by the store on finish/abandon; it now
/// outlives the sheet, so closing the sheet no longer kills a workout in progress.
///
/// 2026-08-21 redesign (MOVE-26): the primary control lives in a FIXED bottom bar above the safe
/// area — "Done set" while working ("Finish workout" on the last set), "Skip rest" while resting —
/// with a quiet "Skip to next exercise" secondary beneath it. Everything else (set strip, rest
/// preview, Up-next list) scrolls and is never a control. At accessibility sizes the labels
/// abbreviate ("1 of 5", "1/4") so the numerals stay large, and the Last-time pill and Up-next
/// list give way (1e·AX3).
struct GuidedWorkoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
    /// Ran (after this sheet's own dismiss) when the done screen's "Done" closes a naturally finished
    /// run. The nested Suggest presenter passes its own dismiss so finishing lands the user back on
    /// the Move root with the session logged — ALWAYS, not only when the whole plan is fully logged
    /// (MOVE-01). The Move-root presenter leaves it nil — one dismiss already lands there.
    var onFinishedDone: (() -> Void)?

    @State private var showEndConfirm = false
    @State private var showReplaceConfirm = false
    /// The "Last time" recall weights keyed by normalized exercise name — built ONCE per
    /// presentation from `exerciseHistoryEntries()` (one full-history rollup) rather than
    /// re-rolling per exercise.
    @State private var lastWeightByName: [String: String] = [:]

    init(
        store: FernletStore,
        session: WorkoutProgram.SessionSuggestion,
        sessionsRemain: Bool = false,
        onExitToResumeCard: (() -> Void)? = nil,
        onFinishedDone: (() -> Void)? = nil
    ) {
        self.store = store
        self.session = session
        self.sessionsRemain = sessionsRemain
        self.onExitToResumeCard = onExitToResumeCard
        self.onFinishedDone = onFinishedDone
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
                    phaseContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            if isLive {
                bottomBar
            }
        }
        .background(Color.parchment)
        .interactiveDismissDisabled(isLive)
        .modifier(GuidedRunnerAlerts(
            showEndConfirm: $showEndConfirm,
            showReplaceConfirm: $showReplaceConfirm,
            replaceConfirmMessage: replaceConfirmMessage,
            onEndWithoutLogging: {
                store.abandonGuidedRun()
                dismiss()
            },
            onGoBackToActiveRun: {
                dismiss()
                // Nested presentation (the Suggest flow): also close the presenter, or the user lands on
                // the configurator whose Start re-opens this same dialog — a loop, not the promised
                // route back to the Resume card.
                onExitToResumeCard?()
            },
            onReplaceActiveRun: {
                // R7: a replace can still be refused (the plan moved on under us) — name it and get
                // out of the way rather than leaving the sheet pretending the run began.
                if !store.startGuidedRun(session, replacingActiveRun: true) {
                    FernletAuditLog.log("workout.guided.startRefused", context: ["replacing": "true"])
                    dismiss()
                }
            }
        ))
        // Pick up a set/rest transition (or a finish) made from the Live Activity while the app was in
        // the background: reconcile the shared run so this sheet re-renders in step. `.onChange` doesn't
        // fire on first presentation, so `.onAppear` covers the initial sync.
        .onAppear {
            store.reconcileGuidedRunFromAppGroup()
            refreshLastWeights()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            store.reconcileGuidedRunFromAppGroup()
        }
    }

    /// The phase-appropriate scroll content.
    @ViewBuilder private var phaseContent: some View {
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

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.suggestion.name)
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                if let run, run.isWorking || run.isResting {
                    progressLine(run)
                }
            }
            Spacer()
            closeButton
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    /// "Exercise 1 of 5 · 38 min left" — abbreviated to "1 of 5 · 38 min left" at accessibility
    /// sizes so the numerals stay large rather than the label shrinking (1e·AX3).
    private func progressLine(_ run: GuidedWorkoutRunState) -> some View {
        let position = run.exerciseIndex + 1
        let total = run.totalExercises
        let minutes = minutesLeft(run)
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                Text("\(position) of \(total) · \(minutes) min left")
            } else {
                Text("Exercise \(position) of \(total) · \(minutes) min left")
            }
        }
        .font(.fernlet(.labelSmall))
        .foregroundStyle(Color.slate)
        // T2-2: the shortened form drops the noun that says what "1 of 5" counts, and this line sits
        // beside a rest countdown and a set counter that are also "n of m". The drawn text keeps the
        // accessibility-size treatment; the spoken one keeps the noun.
        .accessibilityLabel("Exercise \(position) of \(total) · \(minutes) min left")
    }

    /// Whole minutes remaining, floored at 1 — a live run never claims "0 min left".
    private func minutesLeft(_ run: GuidedWorkoutRunState) -> Int {
        max(1, (run.estimatedSecondsRemaining() + 59) / 60)
    }

    private var closeButton: some View {
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

    /// The mid-set screen: the exercise card, the set strip, the rest preview, the next exercises,
    /// and the encouragement line. No controls — the fixed bottom bar owns those (MOVE-26).
    private func workingView(_ run: GuidedWorkoutRunState) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            if let exercise = run.currentExercise {
                exerciseCard(run, exercise)

                if exercise.fromCatalog && exercise.sets >= 1 {
                    GuidedSetStrip(total: run.totalSetsForCurrent, completed: run.setsCompletedForCurrent)
                    restPreview(run, exercise)
                }

                // The read-ahead list gives way at accessibility sizes (3a·AX3) — and a view that is
                // never drawn is never in the accessibility tree, so ``exerciseTitle(_:_:)`` re-hangs
                // it there as custom content (T2-2).
                if !dynamicTypeSize.isAccessibilitySize {
                    GuidedUpNextList(exercises: upcomingExercises(run))
                }

                encouragement(run)
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
    }

    /// The cream card naming the current exercise with its Set / Reps / Last-time pills.
    private func exerciseCard(_ run: GuidedWorkoutRunState, _ exercise: GuidedWorkoutRunState.Exercise) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            exerciseTitle(run, exercise)

            if exercise.fromCatalog && exercise.sets >= 1 {
                HStack(spacing: 10) {
                    metricPill(title: "Set", value: setCounterText(run))
                    if !exercise.reps.isEmpty {
                        metricPill(title: "Reps", value: exercise.reps)
                    }
                    // 1e·AX3: the Last-time pill is the first thing to go at accessibility sizes.
                    // ``exerciseTitle(_:_:)`` puts it back on the rotor there (T2-2).
                    if !dynamicTypeSize.isAccessibilitySize,
                       let lastWeight = lastWeightByName[WorkoutExerciseCatalog.normalizedName(exercise.name)] {
                        metricPill(title: "Last time", value: lastWeight)
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
    }

    /// The exercise name — and, at accessibility text sizes only, the two things the layout drops
    /// around it, re-hung on this element as VoiceOver custom content (T2-2).
    ///
    /// **The custom-content convention.** A view that is never *drawn* never enters the accessibility
    /// tree, so an `if !dynamicTypeSize.isAccessibilitySize` that removes real content removes it from
    /// speech as well — for a user running Larger Text *and* VoiceOver, which is a common pairing.
    /// The visual decisions stay exactly as designed; the content comes back as a rotor entry on the
    /// nearest element that owns it, which for both of these is the exercise being performed. Custom
    /// content, not a longer `.accessibilityLabel`: it is there on demand and never lengthens the
    /// sentence spoken on every landing. Each entry is a `Text` so a value that is user data stays
    /// `Text(verbatim:)` while its "nothing yet" case can be a localized literal.
    @ViewBuilder
    private func exerciseTitle(_ run: GuidedWorkoutRunState, _ exercise: GuidedWorkoutRunState.Exercise) -> some View {
        let title = Text(exercise.name)
            .font(.fernlet(.displayMedium))
            .foregroundStyle(Color.bark)
        if dynamicTypeSize.isAccessibilitySize {
            title
                .accessibilityCustomContent("Last time", lastWeightValue(exercise))
                .accessibilityCustomContent("Up next", upNextValue(run))
        } else {
            title
        }
    }

    /// The dropped "Last time" pill as one spoken value (`GuidedWorkout.swift` 1e·AX3 drop site).
    /// The no-history case is stated rather than omitted — a silent rotor entry would read as a bug.
    private func lastWeightValue(_ exercise: GuidedWorkoutRunState.Exercise) -> Text {
        guard let weight = lastWeightByName[WorkoutExerciseCatalog.normalizedName(exercise.name)] else {
            return Text("Not logged yet")
        }
        return Text(verbatim: weight)
    }

    /// The dropped `GuidedUpNextList` as one spoken value. `formatted(.list(type: .and))` rather than
    /// a hand-joined string: the separator and the final conjunction are locale-dependent.
    private func upNextValue(_ run: GuidedWorkoutRunState) -> Text {
        let names = upcomingExercises(run).map(\.name)
        guard !names.isEmpty else { return Text("Nothing after this one") }
        return Text(verbatim: names.formatted(.list(type: .and)))
    }

    /// "1 of 4", abbreviated to "1/4" at accessibility sizes so the numerals stay large (1e·AX3).
    private func setCounterText(_ run: GuidedWorkoutRunState) -> String {
        dynamicTypeSize.isAccessibilitySize
            ? "\(run.currentSet)/\(run.totalSetsForCurrent)"
            : "\(run.currentSet) of \(run.totalSetsForCurrent)"
    }

    /// The rest screen's "Set 1 of 4" line ("1/4" at accessibility sizes).
    private func restingSetLine(_ run: GuidedWorkoutRunState) -> Text {
        dynamicTypeSize.isAccessibilitySize
            ? Text(verbatim: "\(run.currentSet)/\(run.totalSetsForCurrent)")
            : Text("Set \(run.currentSet) of \(run.totalSetsForCurrent)")
    }

    /// The rest that will follow this set — shown DURING the work phase so the rest is never a
    /// surprise (MOVE-26). Absent on the exercise's last set (no rest follows; the run moves on).
    @ViewBuilder private func restPreview(_ run: GuidedWorkoutRunState, _ exercise: GuidedWorkoutRunState.Exercise) -> some View {
        if run.isWorking, run.currentSet < run.totalSetsForCurrent, exercise.restSeconds > 0 {
            VStack(alignment: .leading, spacing: 2) {
                Text(dynamicTypeSize.isAccessibilitySize ? "Rest next" : "Rest after this set")
                    .font(.fernlet(.labelSmall))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.slate)
                if dynamicTypeSize.isAccessibilitySize {
                    Text("\(exercise.restSeconds) seconds")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                } else {
                    Text("\(exercise.restSeconds) seconds — I'll count it for you")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.cream.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// The next two exercises after the current one — read-ahead, never controls (MOVE-26).
    private func upcomingExercises(_ run: GuidedWorkoutRunState) -> [GuidedWorkoutRunState.Exercise] {
        let next = run.exerciseIndex + 1
        guard next < run.exercises.count else { return [] }
        return Array(run.exercises[next...].prefix(2))
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
                // The design system's timer face (DM Sans, monospaced digits) rather than SF Rounded:
                // the largest text on this screen shouldn't be the one glyph set that isn't ours.
                Text(timerInterval: restStartedAt...restEndsAt, countsDown: true)
                    .font(.fernletTimer(size: 68))
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
                        restingSetLine(run)
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
            completionMessage
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
            primaryButton("Done", identifier: "workout.guided.close") {
                store.clearGuidedRun()
                dismiss()
                // MOVE-01: a nested presenter (the Suggest flow) closes itself too, so finishing
                // lands on the Move root with the session logged — always, not only when the whole
                // plan is fully logged.
                onFinishedDone?()
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }

    private var completionMessage: Text {
        sessionsRemain
            ? Text("\(session.suggestion.name) is logged. The rest of today's plan is there whenever you're ready.")
            : Text("That's logged for today.")
    }

    // MARK: Bottom bar (MOVE-26)

    /// The fixed control bar above the safe area: the 56pt primary ("Done set" / "Finish workout"
    /// while working, "Skip rest" while resting) with the quiet "Skip to next exercise" secondary
    /// beneath. The secondary keeps its slot (faded out) when there is nothing next, so the
    /// primary never moves as the run's state changes.
    @ViewBuilder private var bottomBar: some View {
        if let run {
            VStack(spacing: 6) {
                if run.isResting {
                    barPrimary("Skip rest", identifier: "workout.guided.skipRest") {
                        store.guidedSkipRest()
                    }
                } else {
                    barPrimary(doneSetLabel(run), identifier: "workout.guided.doneSet") {
                        store.guidedMarkSetDone()
                    }
                }
                skipToNextButton(run)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Color.parchment)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.bark.opacity(0.08)).frame(height: 1)
            }
        }
    }

    /// The bar's 56pt filled primary — thumb reach, unmoved as the set count changes (MOVE-26).
    private func barPrimary(_ label: LocalizedStringKey, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.fernlet(.label))
                .foregroundStyle(Color.onMoss)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Color.mossFill, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    /// The quiet "Skip to next exercise" secondary ("Skip" at accessibility sizes). Faded out —
    /// not removed — on the last exercise, so the bar's height never jumps.
    private func skipToNextButton(_ run: GuidedWorkoutRunState) -> some View {
        Button {
            store.guidedSkipToNextExercise()
        } label: {
            Text(dynamicTypeSize.isAccessibilitySize ? "Skip" : "Skip to next exercise")
                .font(.fernlet(.label))
                .foregroundStyle(Color.slate)
        }
        .buttonStyle(.plain)
        .fernletTapTarget()
        .disabled(!run.canSkipToNextExercise)
        .opacity(run.canSkipToNextExercise ? 1 : 0)
        .accessibilityHidden(!run.canSkipToNextExercise)
        // T2-2: the accessibility-size form of the visible title is the bare word "Skip", which in a
        // runner that also skips *rests* names nothing. The shortened text is the design decision;
        // the spoken name stays the whole one at every text size.
        .accessibilityLabel("Skip to next exercise")
        .accessibilityIdentifier("workout.guided.skipExercise")
    }

    // MARK: Pieces

    private func doneSetLabel(_ run: GuidedWorkoutRunState) -> LocalizedStringKey {
        guard let exercise = run.currentExercise else { return "Done" }
        let isLastSet = run.currentSet >= max(1, exercise.sets)
        let isLastExercise = run.exerciseIndex >= run.totalExercises - 1
        if isLastSet && isLastExercise { return "Finish workout" }
        return "Done set"
    }

    private func encouragement(_ run: GuidedWorkoutRunState) -> Text {
        switch run.currentSet {
        case 1: Text("No rush getting started.")
        default: Text("Steady — you've got this.")
        }
    }

    /// Rebuilds the Last-time weight map from ONE `exerciseHistoryEntries()` pass — each per-name
    /// lookup would re-roll the whole history, so the map is built once per presentation instead.
    private func refreshLastWeights() {
        var values: [String: String] = [:]
        for entry in store.exerciseHistoryEntries() {
            guard let weight = entry.lastWeight else { continue }
            let number = weight.formatted(.number.precision(.fractionLength(0...1)))
            let unit = entry.weightUnit.map { " \($0)" } ?? ""
            values[WorkoutExerciseCatalog.normalizedName(entry.name)] = "\(number)\(unit)"
        }
        lastWeightByName = values
    }

    private func metricPill(title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.fernlet(.labelSmall))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Color.slate)
            Text(verbatim: value)
                .font(.fernlet(.stat))
                .foregroundStyle(Color.bark)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.parchment, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.08), lineWidth: 1))
    }

    private func primaryButton(_ label: LocalizedStringKey, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.fernlet(.label))
                .foregroundStyle(Color.onMoss)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.mossFill, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// The runner's confirmation alerts, split out of the sheet body for the Power-of-10 line budget.
///
/// Alerts, not confirmationDialogs: on iOS 26 a confirmationDialog renders as a popover that
/// SUPPRESSES the `.cancel`-role button, so the user saw a lone red "End without logging" with
/// no visible way back — on a dialog whose whole purpose is offering the way back.
private struct GuidedRunnerAlerts: ViewModifier {
    @Binding var showEndConfirm: Bool
    @Binding var showReplaceConfirm: Bool
    let replaceConfirmMessage: String
    let onEndWithoutLogging: () -> Void
    let onGoBackToActiveRun: () -> Void
    let onReplaceActiveRun: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("End this session?", isPresented: $showEndConfirm) {
                Button("Keep going", role: .cancel) {}
                Button("End without logging", role: .destructive, action: onEndWithoutLogging)
            } message: {
                Text("You can always come back and start again — no pressure.")
            }
            // Starting here would throw away a live run for a different session. Name what's at
            // stake, and let "Go back to it" close the sheet onto the Move-root Resume card that
            // resumes the other run.
            .alert("You have a workout in progress", isPresented: $showReplaceConfirm) {
                Button("Go back to it", role: .cancel, action: onGoBackToActiveRun)
                Button("Start this one instead", role: .destructive, action: onReplaceActiveRun)
            } message: {
                Text(replaceConfirmMessage)
            }
    }
}

/// The runner's segmented set strip — the "health bar" of the current exercise (MOVE-26).
///
/// Pure display: done sets fill moss, the set in progress fills a lighter moss, upcoming sets stay
/// faint. Never a control; VoiceOver reads it as one element ("Sets, 1 of 4 done").
private struct GuidedSetStrip: View {
    /// Total sets of the current exercise (≥ 1, already clamped by the run state).
    let total: Int
    /// Sets already done (0...total).
    let completed: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sets")
                .font(.fernlet(.labelSmall))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Color.slate)
            HStack(spacing: 6) {
                // Bounded: `total` is a per-exercise set count, capped by the session editor/plan.
                ForEach(0..<max(1, total), id: \.self) { index in
                    Capsule()
                        .fill(segmentColor(index))
                        .frame(height: 10)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sets")
        .accessibilityValue("\(completed) of \(total) done")
    }

    private func segmentColor(_ index: Int) -> Color {
        if index < completed { return Color.mossFill }
        if index == completed { return Color.moss.opacity(0.38) }
        return Color.bark.opacity(0.10)
    }
}

/// The read-ahead list of the next two exercises under the runner's working card (MOVE-26).
///
/// Rows are name + prescription only — never tappable. Renders nothing when the current exercise
/// is the last one.
private struct GuidedUpNextList: View {
    let exercises: [GuidedWorkoutRunState.Exercise]

    var body: some View {
        if !exercises.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Up next")
                    .font(.fernlet(.labelSmall))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.slate)
                ForEach(exercises) { exercise in
                    HStack(spacing: 10) {
                        Text(exercise.name)
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.bark)
                        Spacer(minLength: 8)
                        if exercise.fromCatalog && exercise.sets >= 1 && !exercise.reps.isEmpty {
                            Text(verbatim: "\(exercise.sets) × \(exercise.reps)")
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.slate)
                        }
                    }
                    .padding(12)
                    .background(Color.cream.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

// MARK: - Skip to next exercise (store seam)

extension FernletStore {
    /// Jump the active guided run past the rest of the current exercise to the first set of the
    /// next one — the runner's quiet "Skip to next exercise" secondary (MOVE-26).
    ///
    /// Drives the run through the EXISTING `guidedMarkSetDone()` / `guidedSkipRest()` transitions
    /// (which own mirroring and Live Activity sync) rather than a new state mutation, so the
    /// app-group file and the Lock Screen stay in step by construction. Guarded by
    /// `canSkipToNextExercise`, so it can never walk a run past its last exercise into a silent
    /// finish-and-log.
    ///
    /// Bounded: each iteration consumes one set or one rest of the current exercise, and per-set
    /// counts are capped, so the budget below is generous and the loop always terminates.
    func guidedSkipToNextExercise() {
        guard let start = guidedRunState, start.canSkipToNextExercise else { return }
        let startIndex = start.exerciseIndex
        var budget = 2 * max(1, start.totalSetsForCurrent) + 2
        while let state = guidedRunState,
              !state.isDone,
              state.exerciseIndex == startIndex,
              budget > 0 {
            budget -= 1
            if state.isResting { guidedSkipRest() } else { guidedMarkSetDone() }
        }
    }
}
