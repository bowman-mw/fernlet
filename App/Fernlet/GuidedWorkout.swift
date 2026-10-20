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
/// preview, Up-next list) scrolls and is never a control — save the rest timer's quiet "−15 s" /
/// "+15 s" chips (idea 7, the Live Activity's same adjustment). At accessibility sizes the labels
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
    /// The exercise whose how-to sheet is open, by frozen name; nil when none is.
    @State private var howTo: ExerciseHowToRequest?

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
            // The two-finger scrub is the close button: without this, mid-run it hit the swipe block
            // below and did nothing, where the button asks "Keep going / End without logging". On the
            // content and the bar — where the cursor sits during a run — not on the whole sheet:
            // SwiftUI copies an action on a plain container onto every child, and on the header
            // that made the small progress line read as actionable to the audit (measured
            // 2026-10-18). The header's own control IS the close button.
            .accessibilityAction(.escape) { closeTapped() }
            if isLive {
                bottomBar
                    .accessibilityAction(.escape) { closeTapped() }
            }
        }
        .background(Color.parchment)
        // Cooking's rule, for the same reason: while a run is live and this sheet is in front the
        // screen stays on, so a phone propped on a bench does not lock mid-rest — locked, the app is
        // suspended, its in-app cues cannot play and the warm-up's hands-free advance stops. Scoped to
        // this sheet; the idle timer comes back the moment the run ends or the sheet or app goes away.
        .keepsScreenAwake(isLive)
        // While this sheet shows the live run its own VoiceOver lines say every moment, so the cue
        // director's spoken cues stay off VoiceOver until the sheet goes away (`GuidedRunCues.swift`).
        .onChange(of: isLive, initial: true) { _, live in store.guidedRunCues.runnerOnScreen = live }
        .onDisappear { store.guidedRunCues.runnerOnScreen = false }
        .interactiveDismissDisabled(isLive)
        .exerciseHowToSheet($howTo, sex: store.effectiveUserProfile.sex)
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
        let (position, total) = run.blockPosition
        let minutes = minutesLeft(run)
        let full = Self.blockProgressText(block: run.currentBlock, position: position, total: total, minutes: minutes)
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                Text("\(position) of \(total) · \(minutes) min left")
            } else {
                full
            }
        }
        .font(.fernlet(.labelSmall))
        .foregroundStyle(Color.slate)
        // T2-2: the shortened form drops the noun that says what "1 of 5" counts, and this line sits
        // beside a rest countdown and a set counter that are also "n of m". The drawn text keeps the
        // accessibility-size treatment; the spoken one keeps the noun.
        .accessibilityLabel(full)
    }

    /// "Warm-up 3 of 23 · 38 min left" — the position within the current block, so twenty-odd
    /// stretches never read as "Exercise 3 of 40". Lifting keeps its own wording. One whole sentence
    /// per block, so a translator can reorder each.
    static func blockProgressText(block: String, position: Int, total: Int, minutes: Int) -> Text {
        switch block {
        case GuidedWorkoutRunState.BlockToken.warmUp:
            Text("Warm-up \(position) of \(total) · \(minutes) min left")
        case GuidedWorkoutRunState.BlockToken.activation:
            Text("Activate \(position) of \(total) · \(minutes) min left")
        case GuidedWorkoutRunState.BlockToken.cardio:
            Text("Cardio · \(minutes) min left")
        case GuidedWorkoutRunState.BlockToken.coolDown:
            Text("Cool-down \(position) of \(total) · \(minutes) min left")
        case GuidedWorkoutRunState.BlockToken.mobility:
            Text("Stretch \(position) of \(total) · \(minutes) min left")
        default:
            Text("Exercise \(position) of \(total) · \(minutes) min left")
        }
    }

    /// Whole minutes remaining, floored at 1 — a live run never claims "0 min left".
    private func minutesLeft(_ run: GuidedWorkoutRunState) -> Int {
        max(1, (run.estimatedSecondsRemaining() + 59) / 60)
    }

    private var closeButton: some View {
        Button(action: closeTapped) {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.slate)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("End session")
        // Voice Control: the button draws only an X, which people name "Close".
        .accessibilityInputLabels([Text("End session"), Text("Close")])
        .accessibilityIdentifier("workout.guided.end")
    }

    /// The close button's action, shared with VoiceOver's escape: mid-run it asks before ending,
    /// otherwise it closes.
    private func closeTapped() {
        if isLive {
            showEndConfirm = true
        } else {
            if run?.isDone == true { store.clearGuidedRun() }
            dismiss()
        }
    }

    // MARK: Phases

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Ready when you are")
                .font(.fernlet(.displayMedium))
                .foregroundStyle(Color.bark)
            GuidedReadyIntro.text(for: session)
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            // A planned workout lists its lines as written; the app's own sessions, their steps.
            GuidedReadyList(exercises: session.exercises, writtenLines: store.plannedRunLink(for: session)?.lines ?? [:])

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
                GuidedPreviousLiftFix(store: store, run: run)
                GuidedLoadPanel(store: store, exercise: exercise, isLastSet: run.currentSet >= run.totalSetsForCurrent)

                if exercise.fromCatalog && exercise.sets >= 1 && !Self.isSingleHold(exercise) {
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
        .task(id: run.holdWindow?.upperBound) { await advanceWhenHoldEnds(run) }
        // While this view is up it moves a timed step on at its hold's end and plays that move's cue
        // itself, so the store's cue director leaves the hold's end to it (`GuidedRunCues.swift`).
        .onAppear { store.guidedRunCues.sheetDrivesHoldEnd = true }
        .onDisappear { store.guidedRunCues.sheetDrivesHoldEnd = false }
    }

    /// Moves a timed step on by itself when its hold runs out — a stretch flow you can do without
    /// looking at the phone. Only while this exact set is still the one being worked (a tap, a Lock
    /// Screen button or a skip that got there first cancels it). Keyed by the hold's end, so the
    /// next step re-arms it. The move carries the hold-end cue, unless the app slept through the
    /// hold's end — then the background notification already said it, and the move stays quiet.
    private func advanceWhenHoldEnds(_ run: GuidedWorkoutRunState) async {
        guard let end = run.holdWindow?.upperBound else { return }
        let remaining = end.timeIntervalSinceNow
        if remaining > 0 {
            do {
                try await Task.sleep(for: .seconds(remaining))
            } catch {
                return
            }
        }
        guard let now = store.guidedRunState, now.isWorking,
              now.exerciseIndex == run.exerciseIndex, now.currentSet == run.currentSet else { return }
        let onTime = GuidedRunCuePlan.isOnTime(end, now: Date())
        announcingTransition(store.guidedMarkSetDone, cue: onTime ? .holdRanOut : nil)
    }

    /// A one-set timed step — a stretch, a balance hold. Its countdown says everything, so it gets no
    /// set strip, no rest preview and no Set / Hold pills.
    static func isSingleHold(_ exercise: GuidedWorkoutRunState.Exercise) -> Bool {
        exercise.holdSeconds != nil && exercise.sets <= 1
    }

    /// The cream card naming the current exercise with its Set / Reps / Last-time pills.
    private func exerciseCard(_ run: GuidedWorkoutRunState, _ exercise: GuidedWorkoutRunState.Exercise) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                exerciseTitle(run, exercise)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // How to do it, beside the name it explains: the cues, the common mistake and an
                // easier version, for a catalog exercise only.
                if ExerciseHowToCatalog.entry(for: exercise.name) != nil {
                    ExerciseHowToButton(exerciseName: exercise.name) {
                        howTo = ExerciseHowToRequest(name: exercise.name)
                    }
                }
            }
            if let side = GuidedSideLabel(raw: exercise.sideRaw) {
                side.text
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
            }
            // A planned workout's line as written, when it says more than the card does (a coach's cue).
            if let written = exercise.writtenLine {
                Text("Your plan: \(written)")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            // An interval's round; its pace is the countdown's caption, in words.
            if let round = exercise.segment?.round, let rounds = exercise.segment?.rounds {
                Text("Round \(round) of \(rounds)")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
            }
            if let window = run.holdWindow {
                GuidedHoldTimer(window: window, paceRaw: exercise.segment?.paceRaw)
            }

            if Self.isSingleHold(exercise) {
                // The countdown above says it all: no "Set 1 of 1", no "Hold 20 s" beside a 0:20.
                EmptyView()
            } else if exercise.fromCatalog && exercise.sets >= 1 {
                HStack(spacing: 10) {
                    metricPill(title: "Set", value: setCounterText(run))
                    if !exercise.reps.isEmpty {
                        metricPill(title: exercise.holdSeconds == nil ? "Reps" : "Hold", value: exercise.reps)
                    }
                    // 1e·AX3: the Last-time pill is the first thing to go at accessibility sizes.
                    // ``exerciseTitle(_:_:)`` puts it back on the rotor there (T2-2).
                    if !dynamicTypeSize.isAccessibilitySize, exercise.holdSeconds == nil,
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
        let title = Text(verbatim: exercise.displayedName)
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
        let names = upcomingExercises(run).map(GuidedSegmentWords.upNextName)
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
                .accessibilityAddTraits(.isHeader)

            if let restStartedAt = run.restStartedAt, let restEndsAt = run.restEndsAt, restStartedAt <= restEndsAt {
                // A fixed window: Text(timerInterval:) clamps to 0:00 once it expires, and the range
                // stays valid however long the user over-rests. A live `Date()` lower bound would invert
                // past the deadline and trap on the next body re-evaluation.
                // The design system's timer face (DM Sans, monospaced digits) rather than SF Rounded:
                // the largest text on this screen shouldn't be the one glyph set that isn't ours.
                Text(timerInterval: restStartedAt...restEndsAt, countsDown: true)
                    .font(.fernletTimer(size: 68))
                    .foregroundStyle(Color.bark)
                    // Without it VoiceOver keeps the time it read when the cursor arrived, as the
                    // Live Activity's own timer already notes (`WorkoutLiveActivity.swift`).
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityIdentifier("workout.guided.restTimer")
                    .task(id: restEndsAt) { await announceRestOver(at: restEndsAt) }
                GuidedRestAdjustRow(store: store)
            }

            if let exercise = run.currentExercise {
                VStack(spacing: 4) {
                    Text("Next up")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                    Text(verbatim: exercise.displayedName)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                    if exercise.fromCatalog && exercise.sets >= 1 {
                        restingSetLine(run)
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                    }
                    if exercise.tracking != nil {
                        GuidedEditRepsButton(store: store, exercise: exercise, label: Text("Edit reps so far"))
                            .padding(.top, 6)
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
                .accessibilityHidden(true)
            Text("Nicely done")
                .font(.fernlet(.displayMedium))
                .foregroundStyle(Color.bark)
                .accessibilityAddTraits(.isHeader)
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
                // ONE button whose words and action follow the phase — not an if/else of two.
                // SwiftUI gives each branch of an if/else its own identity, so every "Done set" and
                // every "Skip rest" destroyed the control under VoiceOver's cursor and the cursor
                // fell somewhere else on the screen, set after set (VoiceOver dry run, 2026-10-18).
                let resting = run.isResting
                barPrimary(
                    resting ? "Skip rest" : doneSetLabel(run),
                    identifier: resting ? "workout.guided.skipRest" : "workout.guided.doneSet"
                ) {
                    announcingTransition(resting ? store.guidedSkipRest : store.guidedMarkSetDone,
                                         cue: resting ? .skip : .setDone)
                }
                if run.canSkipBlock {
                    skipBlockButton(run)
                } else {
                    skipToNextButton(run)
                }
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
            announcingTransition(store.guidedSkipToNextExercise, cue: .skip)
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
        // Voice Control: both drawn forms ("Skip" at accessibility sizes), plus a short one.
        .accessibilityInputLabels([Text("Skip to next exercise"), Text("Skip exercise"), Text("Skip")])
        .accessibilityIdentifier("workout.guided.skipExercise")
    }

    /// The quiet "Skip warm-up" / "Skip cardio" / "Finish early" / "Skip cool-down" secondary, in the
    /// skip-to-next slot (``GuidedBlockSkip``). Skipping the cool-down finishes the session and logs it —
    /// the lifting is done — and "Finish early" logs a cardio or stretch session's time so far.
    private func skipBlockButton(_ run: GuidedWorkoutRunState) -> some View {
        let skip = GuidedBlockSkip(run: run)
        return Button {
            announcingTransition(store.guidedSkipBlock, cue: .skip)
        } label: {
            skip.label
                .font(.fernlet(.label))
                .foregroundStyle(Color.slate)
        }
        .buttonStyle(.plain)
        .fernletTapTarget()
        .accessibilityIdentifier(skip.identifier)
    }

    /// Runs one of the bottom bar's transitions, plays its haptic or sound cue, and says what it
    /// changed.
    ///
    /// Everything a bar button changes — the set strip, the rest timer, the exercise card — is
    /// elsewhere on the screen, so without this a double-tap moved the whole workout in silence.
    /// See ``GuidedRunAnnouncement`` for the spoken line and ``GuidedRunCuePlan`` for the cue; `cue`
    /// is why the run moved, or nil for a move that should stay quiet. With spoken cues on, the
    /// VoiceOver line also carries the new lift's weight (``GuidedRunCueDirector/voiceOverAddition(from:to:)``)
    /// — one announcement, never a second voice beside it.
    private func announcingTransition(_ transition: @MainActor () -> Void, cue: GuidedRunCuePlan.Cause?) {
        let before = run
        transition()
        let after = store.guidedRunState
        if let cue {
            store.guidedRunCues.transition(from: before, to: after, cause: cue)
        }
        guard let before, let spoken = GuidedRunAnnouncement.spoken(from: before, to: after) else {
            return
        }
        let addition = store.guidedRunCues.voiceOverAddition(from: before, to: after)
        let line = GuidedRunSpokenCue.sentences(String(localized: spoken.sentence), addition)
        FernletAnnouncer.system.announce(spoken.kind, resolved: line)
    }

    /// Says the rest's nudge is over when its timer reaches zero. The rest itself waits for the user
    /// — nothing on screen moves at 0:00 — so this is the only way a VoiceOver user not focused on
    /// the timer learns it ran out. Keyed by the rest's end, so a new rest re-arms it and a skipped
    /// one cancels it with the view.
    private func announceRestOver(at end: Date) async {
        let remaining = end.timeIntervalSinceNow
        guard remaining > 0 else { return }
        do {
            try await Task.sleep(for: .seconds(remaining))
        } catch {
            return
        }
        FernletAnnouncer.system.announce(.status, GuidedRunAnnouncement.restOver)
    }

    // MARK: Pieces

    private func doneSetLabel(_ run: GuidedWorkoutRunState) -> LocalizedStringKey {
        guard let exercise = run.currentExercise else { return "Done" }
        let isLastSet = run.currentSet >= max(1, exercise.sets)
        let isLastExercise = run.exerciseIndex >= run.totalExercises - 1
        if isLastSet && isLastExercise { return "Finish workout" }
        // A one-set timed step (a stretch) moves on; "Done set" would name a set it is not.
        if exercise.holdSeconds != nil && exercise.sets <= 1 { return "Next" }
        // A line walked as one step (a planned line the runner can't count) is simply done.
        if exercise.sets < 1 { return "Done" }
        return "Done set"
    }

    private func encouragement(_ run: GuidedWorkoutRunState) -> Text {
        switch run.currentBlock {
        case GuidedWorkoutRunState.BlockToken.warmUp: Text("Ease into each stretch — no bouncing.")
        case GuidedWorkoutRunState.BlockToken.activation: Text("Light and steady — just waking things up.")
        case GuidedWorkoutRunState.BlockToken.coolDown: Text("Breathe out and let it go.")
        case GuidedWorkoutRunState.BlockToken.cardio: GuidedSegmentWords.encouragement(run.currentExercise?.segment?.paceRaw)
        case GuidedWorkoutRunState.BlockToken.mobility: Text("Ease in and breathe. Stop anywhere that feels like enough.")
        default:
            run.currentSet == 1 ? Text("No rush getting started.") : Text("Steady — you've got this.")
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

/// "−15 s" and "+15 s" under the rest timer — the same adjustment as the Live Activity's buttons
/// (`FernletStore.guidedAdjustRest(by:)`): never under five seconds left, never past ten minutes.
///
/// Quiet chips, not a second primary: "Skip rest" in the bottom bar stays the one big control. Each
/// tap says what it did to VoiceOver — the timer's own spoken value is re-read only when the cursor
/// lands on it — and at a limit, where nothing on screen moves, says why.
private struct GuidedRestAdjustRow: View {
    var store: FernletStore

    var body: some View {
        HStack(spacing: 12) {
            Button { adjust(by: -GuidedWorkoutRunState.restAdjustStepSeconds) } label: {
                Text("−15 s")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            .fernletTapTarget()
            .accessibilityLabel("Take 15 seconds off the rest")
            // Voice Control: the drawn "−15 s", spoken, plus the plain verbs.
            .accessibilityInputLabels([Text("Minus 15 seconds"), Text("Minus 15"), Text("Shorter rest")])
            .accessibilityIdentifier("workout.guided.rest.shorter")

            Button { adjust(by: GuidedWorkoutRunState.restAdjustStepSeconds) } label: {
                Text("+15 s")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            .fernletTapTarget()
            .accessibilityLabel("Add 15 seconds of rest")
            .accessibilityInputLabels([Text("Plus 15 seconds"), Text("Plus 15"), Text("Longer rest")])
            .accessibilityIdentifier("workout.guided.rest.longer")
        }
    }

    /// Moves the rest's end and says what happened.
    private func adjust(by seconds: Int) {
        let moved = store.guidedAdjustRest(by: seconds)
        let spoken = GuidedRunAnnouncement.restAdjusted(adding: seconds > 0, moved: moved)
        FernletAnnouncer.system.announce(.status, spoken)
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: exercise.displayedName)
                                .font(.fernlet(.body))
                                .foregroundStyle(Color.bark)
                            if let side = GuidedSideLabel(raw: exercise.sideRaw) {
                                side.text
                                    .font(.fernlet(.labelSmall))
                                    .foregroundStyle(Color.slate)
                            }
                            // A cardio segment's pace — every segment shares its line's name.
                            if let segment = exercise.segment {
                                GuidedSegmentWords.caption(segment.paceRaw)
                                    .font(.fernlet(.labelSmall))
                                    .foregroundStyle(Color.slate)
                            }
                        }
                        Spacer(minLength: 8)
                        prescription(exercise)
                    }
                    .padding(12)
                    .background(Color.cream.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

extension GuidedUpNextList {
    /// The row's trailing prescription: "3 × 8" or a hold for a catalog step, a clock for a cardio
    /// segment ("1:00"), nothing for an untimed line.
    @ViewBuilder fileprivate func prescription(_ exercise: GuidedWorkoutRunState.Exercise) -> some View {
        if exercise.segment != nil, let seconds = exercise.holdSeconds {
            Text(verbatim: GuidedSegmentWords.clock(seconds: seconds))
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
        } else if exercise.fromCatalog && exercise.sets >= 1 && !exercise.reps.isEmpty {
            Text(verbatim: exercise.sets > 1 ? "\(exercise.sets) × \(exercise.reps)" : exercise.reps)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
        }
    }
}

/// "Left side" / "Right side" for a one-sided step, from a raw side token (the run's, or a plan
/// step's `ExerciseSide` raw value) — shared by the runner and the Move plan card.
struct GuidedSideLabel {
    let text: Text

    init?(raw: String?) {
        switch raw {
        case "left": text = Text("Left side")
        case "right": text = Text("Right side")
        default: return nil
        }
    }
}

/// The hold countdown on a timed step's card: "Get into position" through the lead-in, then
/// "Hold" over a countdown of the fixed window — never a live `Date()` range, so it clamps at 0:00
/// rather than inverting (the same rule as the rest timer). A cardio segment reads "Get ready", then
/// its pace in words ("Hard", "Easy", "Steady") over the same countdown.
private struct GuidedHoldTimer: View {
    let window: ClosedRange<Date>
    /// The cardio segment's pace token, or nil for a hold.
    var paceRaw: String? = nil
    @State private var holding = false

    /// The caption over the countdown, for the lead-in or the hold.
    private var caption: Text {
        guard let paceRaw else { return holding ? Text("Hold") : Text("Get into position") }
        return holding ? GuidedSegmentWords.caption(paceRaw) : Text("Get ready")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            caption
                .font(.fernlet(.labelSmall))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Color.moss)
            Text(timerInterval: window, countsDown: true)
                .font(.fernletTimer(size: 56))
                .foregroundStyle(Color.bark)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("workout.guided.holdTimer")
        }
        .task(id: window.lowerBound) { await waitForHoldStart() }
    }

    /// Flips the caption from "Get into position" to "Hold" when the lead-in ends, and says so to
    /// VoiceOver at that moment (``GuidedRunAnnouncement/holdStarted(leadInEndedAt:now:)``). A hold
    /// already running when this view appears flips silently.
    private func waitForHoldStart() async {
        let remaining = window.lowerBound.timeIntervalSinceNow
        guard remaining > 0 else {
            holding = true
            return
        }
        holding = false
        do {
            try await Task.sleep(for: .seconds(remaining))
        } catch {
            return
        }
        holding = true
        if let line = GuidedRunAnnouncement.holdStarted(leadInEndedAt: window.lowerBound, now: Date()) {
            // A segment's form of "Hold now." is "Go — hard." and the like.
            FernletAnnouncer.system.announce(.status, paceRaw.map(GuidedSegmentWords.goLine) ?? line)
        }
    }
}

/// The Ready screen's list of what the session holds, block by block: the warm-up and the cool-down
/// as one summary row each (their twenty-odd stretches are walked one at a time in the run), and
/// every activation, lifting and cardio movement on its own row.
private struct GuidedReadyList: View {
    let exercises: [PrescribedExercise]
    /// A planned workout's lines exactly as written, by step id — listed in place of the step's own line,
    /// so a coach's weights and cues read as the coach wrote them. Empty for the app's own sessions.
    var writtenLines: [UUID: String] = [:]

    var body: some View {
        VStack(spacing: 8) {
            let warmUp = exercises.filter { $0.block == .warmUp }
            let coolDown = exercises.filter { $0.block == .coolDown }
            if !warmUp.isEmpty {
                row(Text("Warm-up · \(warmUp.count) stretches · \(WorkoutSessionBlocks.minutes(of: warmUp)) min"))
            }
            ForEach(exercises.filter { $0.block != .warmUp && $0.block != .coolDown }) { exercise in
                row(Text(verbatim: writtenLines[exercise.id] ?? exercise.displayLine))
            }
            if !coolDown.isEmpty {
                row(Text("Cool-down · \(coolDown.count) stretches · \(WorkoutSessionBlocks.minutes(of: coolDown)) min"))
            }
        }
    }

    private func row(_ text: Text) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.moss.opacity(0.5))
                .frame(width: 7, height: 7)
                .padding(.top, 7)
                .accessibilityHidden(true)
            text
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
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
        // A skipped lift is logged as skipped, never as "completed as prescribed".
        editGuidedRun { $0.markCurrentSkipped() }
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
