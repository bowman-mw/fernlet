import SwiftUI
import LocalPersistence
import FernletFoundation
import FernletDomainModel
import AIProviders
import PrivateMediaStore
import FernletUI

/// The Move tab root: workout calendar, today's planned and logged workouts, the guided-workout
/// entry cards, and the progress-photo timeline.
///
/// Owned state is deliberately thin — `allDays` is a snapshot cache of `store.loadDays()` refreshed
/// through the single `refreshAllDays()` seam (which also recomputes the cached coach-tag gate), and
/// the guided cards derive from ``FernletStore``'s committed plan and persisted run state rather than
/// local `@State`. Day rollover and Live Activity progress are reconciled on scene activation
/// because a foreground can cross local midnight without re-firing `onAppear`. Navigation pushes a
/// day-key `String` for ``MoveDayDetailView``, a `ProgressPhotoRecord` for the photo detail, and a
/// ``MoveRoute`` for the parameterless screens (``ExerciseHistoryView``).
struct MoveView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int
    @State private var path = NavigationPath()
    @State private var displayedWeek: Date = .now
    @State private var allDays: [String: FernletDay] = [:]
    @State private var showingLocations = false
    // The trainer / coach handoff screen. It lives here rather than in Settings → Privacy & Data
    // because it is now two-way — a plan comes back through it — and a plan belongs next to the
    // plans, not next to the data-export controls.
    @State private var showingTrainerShare = false
    @State private var progressPhotos: [ProgressPhotoRecord] = []
    // Surfaced when a progress-photo capture couldn't be sealed to disk (fail-closed store returned nil):
    // the photo would otherwise vanish silently. A clear per-capture alert, never a silent drop.
    @State private var showPhotoSaveFailedAlert = false
    // The session the guided runner is walking through, presented from the root card. nil = closed.
    @State private var guidedSession: WorkoutProgram.SessionSuggestion?
    // The Suggest flow presented from the root card's empty state (FLOW-03) — one sheet straight
    // from the root, exactly the way the plan sheet presents it.
    @State private var showingSuggestSheet = false
    // A foreground can cross local midnight without re-firing `onAppear`; observing scenePhase lets the
    // card refresh its preview on the day-rollover / scene-active seam so it can't sit on a stale read.
    @Environment(\.scenePhase) private var scenePhase
    // Drives the Suggest sheet's detents: accessibility sizes open .large — grow the sheet, never
    // hide a control (1b·AX3).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The Move-root "Today's workout" card appears only once the user has APPROVED today's plan (or
    /// started it from the card) — so a plan generated just to look at, then closed, doesn't silently
    /// become "today's workout". Resolves against the approved committed plan and today's logged
    /// sessions, so it shows a done state (never a re-runnable `.ready`) for a session already logged,
    /// and re-derives the moment a workout is logged.
    private var guidedCardState: GuidedWorkoutCardState? {
        guard store.isTodaysGuidedPlanApproved, let plan = store.currentGuidedWorkoutPlan else { return nil }
        return GuidedWorkoutCardState.resolve(
            plan: plan,
            completed: store.guidedCompletedSessionIDs,
            loggedGuidedWorkoutNames: store.loggedGuidedWorkoutNamesToday
        )
    }

    /// Commits today's plan and opens the guided runner on the first still-to-do guidable session.
    /// Re-resolves against the *committed* plan (the preview's session ids are throwaway) and against
    /// today's logged workouts, so a relaunch can't open an already-logged session.
    private func startTodaysGuidedWorkout() {
        let plan = store.commitTodaysGuidedWorkoutPlan(intensity: store.recommendedWorkoutIntensity() ?? .moderate)
        if let session = GuidedWorkoutAvailability.firstGuidable(
            in: plan,
            excluding: store.guidedCompletedSessionIDs,
            loggedGuidedWorkoutNames: store.loggedGuidedWorkoutNamesToday
        ) {
            guidedSession = session
        } else {
            // A stale `.ready` that raced a day rollover or an equipment edit: the freshly committed
            // plan has nothing left to guide. Release the just-committed plan (safe — no session of it
            // is logged yet, so `reworkTodaysGuidedPlan` accepts it) so the card settles on its real
            // state instead of leaving the day silently pinned behind a dead button. R7: the claim in
            // that parenthesis is now checkable rather than a comment.
            if !store.reworkTodaysGuidedPlan() {
                assertionFailure("rework refused for a plan with no logged session")
                FernletAuditLog.log("workout.guided.reworkRefused", context: ["site": "startTodaysGuidedWorkout"])
            }
        }
    }

    /// Gate for the Coach/User plan-source tag: coach-sourced plans actually exist in the
    /// user's days. The previous gate scanned `trainerAuditEvents` — but that log is the
    /// GENERIC proximity audit, written by every mode on every state transition and envelope,
    /// so any friend-mesh user got tagged as having a coach (Increment 8 of
    /// Docs/Plan-Prekeys-ProtectedLoad-CoachMesh-2026-07-26.md).
    ///
    /// CACHED, not computed: the body reads it in four places, and the scan walks every loaded
    /// day's planned workouts — years of history, several times per frame, on every scroll
    /// (review finding, 2026-07-27). It is recomputed exactly where `allDays` is refreshed, via
    /// `refreshAllDays()`, so it can never drift from the data it summarizes.
    @State private var showsCoachPlanSourceTag = false

    /// The single seam for reloading `allDays` — keeps the derived coach-tag gate in step.
    private func refreshAllDays() {
        allDays = store.loadDays()
        showsCoachPlanSourceTag = Self.hasCoachSourcedPlans(in: allDays, today: store.day)
    }

    /// Static so it is testable: a private view computed cannot be (the `AwayHeartsCopy`
    /// precedent).
    static func hasCoachSourcedPlans(in days: [String: FernletDay], today: FernletDay) -> Bool {
        if today.plannedWorkouts.contains(where: { $0.source == .coach }) { return true }
        return days.values.contains { day in
            day.plannedWorkouts.contains { $0.source == .coach }
        }
    }

    /// The tab header: title plus the Log / Share / Settings actions.
    ///
    /// The action pills sit in an ``AdaptiveStack`` so they stack into a column at accessibility text
    /// sizes rather than squeezing side by side (where "Share" broke to "Shar/e").
    private var headerRow: some View {
        HStack(alignment: .top) {
            ScreenHeader(title: "Move", subtitle: "Enough to feel it, not enough to drain.", identifier: "screen.move")
            Spacer(minLength: 8)
            AdaptiveStack(spacing: 10, horizontalAlignment: .trailing, verticalAlignment: .top) {
                HeaderActionButton(title: "Log") { activeSheet = .workout }
                // Suggest moved into ``WorkoutPlanSheet`` — asking for a workout belongs
                // beside planning one, not in the tab header. The header slot it freed
                // goes to the trainer/coach handoff, which is the tab's other top-level
                // action and previously sat in a card halfway down the scroll.
                HeaderActionButton(title: "Share") { showingTrainerShare = true }
                    .accessibilityIdentifier("move.trainerShare")
                    .accessibilityLabel("Share with a trainer")
                // Settings used to be reachable only from Home (tab switch + gear). The same compact
                // gear the Home header draws, so every tab opens Settings in one tap.
                settingsButton
            }
        }
        .padding(.top, 4)
    }

    /// The Settings gear, drawn with the shared ``HeaderActionButton`` exactly as the Home and Food
    /// headers do. A hand-rolled 44pt 6%-bark circle here would re-create the very mismatch the Home
    /// header just dropped — smaller and lighter than the "Log" / "Share" pills beside it.
    private var settingsButton: some View {
        HeaderActionButton(systemImage: "gearshape", accessibilityLabel: "Settings") {
            activeSheet = .settings
        }
        .accessibilityIdentifier("move.settings")
    }

    /// Resume-a-run card, else the approved "Today's workout" card, else the SAME card in its
    /// empty state — the card always renders on the Move root (FLOW-03).
    ///
    /// A run in progress takes precedence — it stays resumable even after an app kill (the run
    /// survives in the app group though the in-memory committed plan doesn't), so this is driven by
    /// `guidedRunState` alone, not the plan-based card. With no approved plan the empty state's one
    /// primary opens the Suggest flow directly from the root — one sheet, not three.
    @ViewBuilder private var guidedEntryCard: some View {
        if let activeRun = store.guidedRunState, activeRun.isWorking || activeRun.isResting {
            ResumeWorkoutCard(title: activeRun.title, isResting: activeRun.isResting) {
                if let session = store.guidedSessionForResume() { guidedSession = session }
            }
        } else if let guidedCardState {
            StartTodaysWorkoutCard(
                state: guidedCardState,
                loggedSessionName: loggedGuidedSessionName,
                onStart: startTodaysGuidedWorkout
            )
        } else {
            StartTodaysWorkoutCard(
                state: .noPlan,
                loggedSessionName: nil,
                onStart: { showingSuggestSheet = true }
            )
        }
    }

    /// The name of today's guided session that is already accounted for, so the done card can say
    /// WHICH session is logged instead of a nameless "That's logged for today".
    private var loggedGuidedSessionName: String? {
        guard let plan = store.currentGuidedWorkoutPlan else { return nil }
        return plan.sessions.first {
            GuidedWorkoutAvailability.isAlreadyLogged(
                $0,
                completed: store.guidedCompletedSessionIDs,
                loggedGuidedWorkoutNames: store.loggedGuidedWorkoutNamesToday
            )
        }?.suggestion.name
    }

    /// Today's planned rows then today's logged rows, divided.
    private var todaysMovementSection: some View {
        FernletScrollSection("Today's movement") {
            if store.day.plannedWorkouts.isEmpty && store.day.workouts.isEmpty {
                EmptyState(text: "No workouts today. No rush.")
            } else {
                ForEach(Array(store.day.plannedWorkouts.enumerated()), id: \.element.id) { index, plannedWorkout in
                    PlannedWorkoutRow(
                        plannedWorkout: plannedWorkout,
                        showsPlanSourceTag: showsCoachPlanSourceTag,
                        showsCompleteAction: true,
                        onComplete: {
                            store.completePlannedWorkout(plannedWorkout, date: store.todayKey)
                            refreshAllDays()
                        },
                        onEdit: {
                            path.append(store.todayKey)
                        },
                        onDelete: {
                            store.deletePlannedWorkout(plannedWorkout, date: store.todayKey)
                            refreshAllDays()
                        }
                    )
                    if index < store.day.plannedWorkouts.count - 1 || !store.day.workouts.isEmpty {
                        FernletRowDivider()
                    }
                }
                ForEach(Array(store.day.workouts.enumerated()), id: \.element.id) { index, workout in
                    WorkoutRow(
                        store: store,
                        workout: workout,
                        date: store.todayKey,
                        onChanged: { refreshAllDays() }
                    )
                    if index < store.day.workouts.count - 1 {
                        FernletRowDivider()
                    }
                }
            }
        }
    }

    #if canImport(UIKit)
    /// The progress-photo timeline. Every capture path reports its own failure — a photo that
    /// couldn't be sealed must never vanish silently.
    private var progressPhotoSection: some View {
        ProgressPhotoSection(
            records: progressPhotos,
            loadData: { store.progressPhotoData(for: $0) },
            onCapture: { image in
                if store.addProgressPhoto(image) == nil {
                    showPhotoSaveFailedAlert = true
                }
                progressPhotos = store.progressPhotoRecords()
            },
            onCaptureData: { data, capturedAt in
                // Library pick: seal the raw bytes (bounded ImageIO decode) and stamp the
                // photo's own date when EXIF carried one (clamped to now at the EXIF read —
                // a wrong camera clock must not outrun the editor's today cap), else now.
                if store.addProgressPhoto(data: data, capturedAt: capturedAt ?? Date()) == nil {
                    showPhotoSaveFailedAlert = true
                }
                progressPhotos = store.progressPhotoRecords()
            },
            onCaptureFailed: { showPhotoSaveFailedAlert = true },
            onOpen: { record in path.append(record) }
        )
    }
    #endif

    /// The quiet "Exercise history" link under the week strip — the factual per-exercise recall
    /// list (``ExerciseHistoryView``). The same row chrome as the plan sheet's "Equipment & limits"
    /// entry, so a navigation row reads the same everywhere in Move.
    private var exerciseHistoryLink: some View {
        Button {
            path.append(MoveRoute.exerciseHistory)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.moss)
                Text("Exercise history")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.slate)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.cream.opacity(0.86), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.bark.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("move.exerciseHistory")
    }

    /// The Move root's scrolling column, in order.
    private var scrollContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerRow

            MoveContextStrip(
                store: store,
                onEditGoal: { activeSheet = .goals },
                onEditSpace: { showingLocations = true }
            )

            guidedEntryCard

            WorkoutCalendarCard(
                displayedWeek: $displayedWeek,
                allDays: allDays,
                todayKey: store.todayKey,
                selectedGoal: store.settings.selectedGoal,
                goals: store.goals,
                showsPlanSourceTag: showsCoachPlanSourceTag,
                onDayTapped: { key in path.append(key) }
            )

            exerciseHistoryLink

            todaysMovementSection

            #if canImport(UIKit)
            progressPhotoSection
            #endif
        }
        .padding(20)
    }

    /// The guided runner sheet for `session`, with the "other sessions remain" copy resolved.
    private func guidedRunnerSheet(_ session: WorkoutProgram.SessionSuggestion) -> some View {
        GuidedWorkoutSheet(
            store: store,
            session: session,
            sessionsRemain: store.currentGuidedWorkoutPlan.map { plan in
                // Route through the reconciliation seam (not an id-only check) so the done copy stays
                // truthful after a relaunch, when the completed-id set is empty but the day record
                // (by tagged name) still knows what's been guided.
                plan.sessions.contains {
                    $0.id != session.id && !GuidedWorkoutAvailability.isAlreadyLogged(
                        $0, completed: store.guidedCompletedSessionIDs,
                        loggedGuidedWorkoutNames: store.loggedGuidedWorkoutNamesToday
                    )
                }
            } ?? false
        )
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
    }

    /// Day rollover + Live Activity reconciliation on every return to the foreground.
    ///
    /// The app can foreground across local midnight without re-firing `onAppear`. Rolls the store
    /// over to the current day first (idempotent — ContentView does this too; a no-op when the day
    /// hasn't changed), then picks up any guided-run progress made from the Live Activity.
    private func handleSceneActive(_ phase: ScenePhase) {
        guard phase == .active else { return }
        store.refreshCurrentDayIfNeeded()
        store.reconcileGuidedRunFromAppGroup()
        refreshAllDays()
    }

    /// The pushed day detail for `dateKey`, refreshing the root's snapshots when it pops.
    private func dayDetail(_ dateKey: String) -> some View {
        MoveDayDetailView(store: store, dateKey: dateKey, showsPlanSourceTag: showsCoachPlanSourceTag)
            .onDisappear { refreshAllDays() }
    }

    #if canImport(UIKit)
    /// The pushed progress-photo detail for `record`. The detail view refreshes us itself after
    /// each persisted change (save → refresh in one step), so there's no racing `onDisappear` and
    /// no stale caption on return.
    private func photoDetail(_ record: ProgressPhotoRecord) -> some View {
        ProgressPhotoDetailView(
            store: store,
            record: record,
            onChanged: { progressPhotos = store.progressPhotoRecords() },
            // Pop-back vs genuine departure: by the time the detail's onDisappear fires on a
            // pop, the record is already off the path (empty → back at the strip, which owns
            // the session's re-lock); on a tab switch away the detail stays pushed (non-empty)
            // and the gate re-locks as before. One unlock covers strip → detail → pop-back.
            shouldLockOnDisappear: { !path.isEmpty }
        )
    }
    #endif

    /// Resolves a fixed ``MoveRoute`` to its screen.
    @ViewBuilder private func routedScreen(_ route: MoveRoute) -> some View {
        switch route {
        case .exerciseHistory:
            ExerciseHistoryView(store: store)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                scrollContent
                    .fernletTabBarBottomClearance()
            }
            .fernletTabBarCompaction($isTabBarCompact, resetToken: $tabResetToken)
            .background(Color.parchment)
            .navigationTitle("")
            .navigationDestination(for: String.self) { dayDetail($0) }
            .navigationDestination(for: MoveRoute.self) { routedScreen($0) }
            #if canImport(UIKit)
            .navigationDestination(for: ProgressPhotoRecord.self) { photoDetail($0) }
            #endif
        }
        .onAppear {
            refreshAllDays()
            progressPhotos = store.progressPhotoRecords()
            store.reconcileGuidedRunFromAppGroup()
        }
        .alert("Couldn't save this photo", isPresented: $showPhotoSaveFailedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Fernlet couldn't seal this photo to your private timeline. Please try again.")
        }
        .sheet(isPresented: $showingLocations) {
            WorkoutLocationSetupView(store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
        .sheet(isPresented: $showingTrainerShare, onDismiss: {
            // An imported plan writes planned workouts straight into day records, which the
            // calendar and "Today's movement" read from the `allDays` snapshot — refresh or the
            // new days stay invisible until some other mutation happens to bump it.
            refreshAllDays()
        }) {
            TrainerExportView(store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
        .sheet(item: $guidedSession) { session in
            guidedRunnerSheet(session)
        }
        .sheet(isPresented: $showingSuggestSheet) {
            // The root-card empty state's Suggest entry (FLOW-03), presented locally the way the
            // plan sheet presents it. Accessibility sizes open .large: the chips alone outgrow the
            // medium detent, and the sheet grows rather than hiding a control (1b·AX3).
            WorkoutSuggestionSheet(store: store)
                .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
        .task {
            await store.refreshWorkoutsFromHealth()
            refreshAllDays()
        }
        .onChange(of: store.day.workouts.count) { refreshAllDays() }
        .onChange(of: store.day.plannedWorkouts.count) { refreshAllDays() }
        .onChange(of: scenePhase) { _, phase in handleSceneActive(phase) }
    }
}

/// The guidable filter, in one place so the Move-root card and the Suggest sheet agree (reused, not
/// reimplemented).
///
/// A session is worth *guiding* through only when it carries real, set-based catalog work; pure
/// cardio/mobility/rest carry descriptor lines with `sets == 0`. ``MoveView``,
/// ``WorkoutSuggestionSheet``, and ``GuidedWorkoutCardState`` all route their already-logged checks
/// through these predicates, which is the invariant that keeps a session finished from one entry
/// point excluded everywhere — including after a relaunch, when session ids are fresh but the tagged
/// name in the day record survives.
enum GuidedWorkoutAvailability {
    /// A session with real, set-based catalog exercises (the guided runner needs sets to time rests).
    nonisolated static func isGuidable(_ session: WorkoutProgram.SessionSuggestion) -> Bool {
        session.exercises.contains { $0.fromCatalog && $0.sets >= 1 }
    }

    /// A session is already accounted for when its id is in the in-memory completed set OR today's
    /// GUIDED-logged workouts already carry its `suggestion.name`. The name check is the reconciliation
    /// seam: a routine relaunch mints the plan with fresh session ids and starts the completed set empty,
    /// but the guided log (written with `suggestion.name` and tagged `loggedFromGuidedSession`) survives
    /// in `day.workouts` — so matching on that name keeps an already-logged guided session from being
    /// offered, and re-logged, again. Only tagged names are passed in, so a manual or planned "Legs"
    /// never counts.
    nonisolated static func isAlreadyLogged(
        _ session: WorkoutProgram.SessionSuggestion,
        completed: Set<UUID>,
        loggedGuidedWorkoutNames: Set<String>
    ) -> Bool {
        completed.contains(session.id) || loggedGuidedWorkoutNames.contains(session.suggestion.name)
    }

    /// The first guidable session not already logged today — what a "start guided workout" tap opens.
    /// `loggedGuidedWorkoutNames` reconciles against the day record so a relaunch can't re-open a logged
    /// session (its fresh id isn't in `completed`, but its name is already guided-logged).
    nonisolated static func firstGuidable(
        in plan: WorkoutProgram.DayPlan,
        excluding completed: Set<UUID>,
        loggedGuidedWorkoutNames: Set<String> = []
    ) -> WorkoutProgram.SessionSuggestion? {
        plan.sessions.first {
            isGuidable($0) && !isAlreadyLogged($0, completed: completed, loggedGuidedWorkoutNames: loggedGuidedWorkoutNames)
        }
    }
}

/// The Move-root "Start today's workout" card's state, derived purely from today's plan and the set
/// of sessions already logged.
///
/// Extracted so the availability rules are unit-testable without SwiftUI;
/// ``StartTodaysWorkoutCard`` renders whichever case
/// ``resolve(plan:completed:loggedGuidedWorkoutNames:)`` returns.
enum GuidedWorkoutCardState: Equatable {
    /// A session is ready to guide (carries its id so the tap opens exactly this session).
    case ready(sessionID: UUID)
    /// No plan exists (or none is approved) for today — the card's always-rendered empty state
    /// (FLOW-03). Never returned by ``resolve(plan:completed:loggedGuidedWorkoutNames:)``, which
    /// only runs over an existing plan; the parent renders it when there is no plan to resolve.
    /// The primary then opens the Suggest flow instead of the runner.
    case noPlan
    /// Every guidable session today is already logged — offer a gentle done state, never a restart
    /// that would double-log. `remainingMovement` is true when today's plan still carries a non-guided
    /// movement session (a cardio/mobility descriptor, `sets == 0`) that hasn't been logged; the copy
    /// then names what was guided rather than implying the whole day is done.
    case allComplete(remainingMovement: Bool)
    /// No guidable session today (a rest, or cardio/mobility-only day). Carries a gentle reason.
    case noneToGuide(reason: String)

    /// Derives the card state for today's plan, routing every already-logged check through
    /// ``GuidedWorkoutAvailability`` so the result stays truthful after a relaunch.
    static func resolve(
        plan: WorkoutProgram.DayPlan,
        completed: Set<UUID>,
        loggedGuidedWorkoutNames: Set<String> = []
    ) -> GuidedWorkoutCardState {
        let guidable = plan.sessions.filter(GuidedWorkoutAvailability.isGuidable)
        guard !guidable.isEmpty else {
            let hasMovement = plan.sessions.contains { !$0.exercises.isEmpty }
            return .noneToGuide(reason: hasMovement
                ? "Today's about easy movement — no guided sets, but anything you do still counts."
                : "Rest day. Nothing to push — let your body settle.")
        }
        if let next = guidable.first(where: {
            !GuidedWorkoutAvailability.isAlreadyLogged($0, completed: completed, loggedGuidedWorkoutNames: loggedGuidedWorkoutNames)
        }) {
            return .ready(sessionID: next.id)
        }
        // Every guidable session is handled — but a non-guided movement session (cardio/mobility, not a
        // pure rest slot) may still be unlogged; note it so the done copy doesn't overstate the day.
        let remainingMovement = plan.sessions.contains { session in
            !GuidedWorkoutAvailability.isGuidable(session)
                && !session.exercises.isEmpty
                && !GuidedWorkoutAvailability.isAlreadyLogged(session, completed: completed, loggedGuidedWorkoutNames: loggedGuidedWorkoutNames)
        }
        return .allComplete(remainingMovement: remainingMovement)
    }
}

/// Shown while a guided run is in progress — the resume entry point.
///
/// Driven purely by the persisted run state (not the in-memory committed plan), so a workout
/// interrupted by an app kill can still be picked back up in-app, not only from the Live Activity.
/// ``MoveView`` gives it precedence over ``StartTodaysWorkoutCard``.
struct ResumeWorkoutCard: View {
    var title: String
    var isResting: Bool
    var onResume: () -> Void

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "figure.strengthtraining.traditional")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.moss)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Workout in progress")
                            .font(.fernlet(.headerMedium))
                            .foregroundStyle(Color.bark)
                        Text(isResting ? "\(title) — you're resting between sets." : "\(title) — pick up where you left off.")
                            .font(.fernlet(.bubble))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                    Spacer(minLength: 0)
                }

                Button(action: onResume) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.circle.fill")
                            .font(.body.weight(.semibold))
                        Text("Resume workout")
                            .font(.fernlet(.label))
                    }
                    .foregroundStyle(Color.onMoss)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.mossFill, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("workout.resume")
            }
        }
    }
}

/// The Move-root "Today's workout" card — ALWAYS rendered (FLOW-03), so the guided flow is
/// discoverable from the root in every state, not only once a plan is approved.
///
/// Gentle, no-pressure copy; the primary action is a single button (the a11y id lives on the
/// button, not a wrapping container, so it isn't overridden). The empty `.noPlan` state keeps the
/// exact geometry, icon, and header of the with-plan state — only the body line and the button
/// label differ, so the two read as one component; its primary opens the Suggest flow. On rest /
/// cardio-only days it shows a gentle reason instead of a button; once today's sessions are all
/// logged it shows a done state, never a restart. Renders whatever ``GuidedWorkoutCardState`` its
/// parent resolved. At accessibility sizes the body line and button label shorten so the primary
/// holds one line inside its height instead of wrapping (1a·AX3).
struct StartTodaysWorkoutCard: View {
    var state: GuidedWorkoutCardState
    /// The session already logged today, when there is one — the done copy names it rather than
    /// saying "That's logged" about an unnamed something. Nil falls back to the generic line.
    var loggedSessionName: String?
    /// Opens the runner (`.ready`) or the Suggest flow (`.noPlan`) — the parent decides.
    var onStart: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: iconName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Today's workout")
                            .font(.fernlet(.headerMedium))
                            .foregroundStyle(Color.bark)
                        subtitle
                            .font(.fernlet(.bubble))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                    Spacer(minLength: 0)
                }

                if showsPrimary {
                    primaryButton
                }
            }
        }
    }

    /// `.ready` and `.noPlan` both carry a primary; the other states are read-only.
    private var showsPrimary: Bool {
        switch state {
        case .ready, .noPlan: true
        case .allComplete, .noneToGuide: false
        }
    }

    /// One button geometry for both actionable states — only label and identifier differ.
    private var primaryButton: some View {
        Button(action: onStart) {
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(.body.weight(.semibold))
                primaryLabel
                    .font(.fernlet(.label))
            }
            .foregroundStyle(Color.onMoss)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Color.mossFill, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(state == .noPlan ? "workout.suggestToday" : "workout.startToday")
    }

    /// 1a·AX3: labels shorten at accessibility sizes so they hold one line in the button.
    private var primaryLabel: Text {
        if case .noPlan = state {
            return dynamicTypeSize.isAccessibilitySize
                ? Text("Suggest workout")
                : Text("Suggest today's workout")
        }
        return dynamicTypeSize.isAccessibilitySize
            ? Text("Start workout")
            : Text("Start today's workout")
    }

    private var iconName: String {
        switch state {
        // The empty state deliberately shares the ready state's icon: same card, same header,
        // same geometry — only the body line and the button label change (FLOW-03).
        case .ready, .noPlan: "figure.strengthtraining.traditional"
        case .allComplete: "checkmark.seal.fill"
        case .noneToGuide: "leaf.fill"
        }
    }

    private var accentColor: Color {
        switch state {
        case .ready, .noPlan, .allComplete: Color.moss
        case .noneToGuide: Color.slate
        }
    }

    private var subtitle: Text {
        switch state {
        case .ready:
            return Text("Ready when you are — I'll walk you through it, set by set, and time the rests. No pressure.")
        case .noPlan:
            return dynamicTypeSize.isAccessibilitySize
                ? Text("Nothing planned yet.")
                : Text("Nothing planned yet — I can put something together.")
        case .allComplete(let remainingMovement):
            if remainingMovement {
                return Text("Your guided sets are done. There's some easy movement left in today's plan too, whenever you feel like it.")
            }
            if let loggedSessionName, !loggedSessionName.isEmpty {
                return Text("\(loggedSessionName) is logged. Nicely done — rest up.")
            }
            return Text("That's logged for today. Nicely done — rest up.")
        case .noneToGuide(let reason):
            return Text(verbatim: reason)
        }
    }
}

/// The manual "Log workout" sheet: strength (exercise rows built from the catalog) or activity
/// (type + duration/distance/energy/effort) logging into a day record.
///
/// Presented from the Move header's Log button and from ``MoveDayDetailView`` (which passes a past
/// `dateKey`; past-day logs are stamped at noon of that day, today's at now). Save folds a
/// typed-but-unadded exercise draft into the rows first so it isn't silently dropped, and
/// ``WorkoutSheetRules`` keeps the save-gating and muscle-group aggregation unit-testable. Intensity
/// is inferred from RPE (strength) or effort (activity); the category preview reflects
/// `inferredCategory` live as the user types.
struct WorkoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var store: FernletStore
    var dateKey: String?
    @State private var name = ""
    @State private var exerciseRows: [WorkoutExerciseEntry] = []
    /// The in-progress exercise row (see ``WorkoutExerciseDraft``) — shared with ``WorkoutPlanSheet``.
    @State private var draft = WorkoutExerciseDraft()
    @State private var rpe = ""
    @State private var duration = ""
    @State private var distance = ""
    @State private var energyKcal = ""
    @State private var effort = ""
    @State private var notes = ""
    @State private var selectedActivityType: WorkoutActivityType?
    @State private var logMode: WorkoutMode = .strengthTraining
    /// The last five distinct exercises with their last sets×reps×weight, behind the Recent chips
    /// (MOVE-08). Fetched ONCE per presentation via `exerciseHistoryEntries()` — each per-name
    /// lookup would re-roll the whole history.
    @State private var recentEntries: [TrainerExportBundle.ExerciseHistoryEntry] = []
    /// The most recent logged workout of the current Kind — the "Log it again" card (MOVE-08).
    /// Re-queried when the Kind flips, so the card always offers the matching kind.
    @State private var lastLogged: RecentLoggedWorkout?

    var intensity: WorkoutIntensity {
        if logMode == .activity {
            guard let value = Double(effort) else { return .moderate }
            if value >= 8 { return .hard }
            if value >= 5 { return .moderate }
            return .light
        }
        guard let value = LocaleTolerantNumber.double(from: rpe) else { return .moderate }
        if value >= 8 { return .hard }
        if value >= 5 { return .moderate }
        return .light
    }

    private var inferredCategory: WorkoutType {
        if logMode == .activity, let selectedActivityType {
            return selectedActivityType.fernletCategory
        }
        if !aggregatedMuscleGroups.isEmpty {
            return Workout(
                name: workoutName,
                type: .fullBody,
                exercises: exerciseText,
                rpe: nil,
                notes: "",
                duration: nil,
                muscleGroups: aggregatedMuscleGroups,
                intensity: .moderate
            ).inferredCategory
        }
        return WorkoutExerciseCatalog.inferredCategory(for: "\(name)\n\(exerciseText)")
    }

    private var exerciseText: String {
        exerciseRows.map(\.summary).joined(separator: "\n")
    }

    private var aggregatedMuscleGroups: Set<MuscleGroup> {
        WorkoutSheetRules.aggregatedMuscleGroups(from: exerciseRows)
    }

    private var targetDateKey: String {
        dateKey ?? store.todayKey
    }

    /// The strength / activity mode chips.
    private var kindField: some View {
        SheetField("Kind") {
            FlowLayout(spacing: 8) {
                ForEach(WorkoutMode.allCases) { mode in
                    Button { logMode = mode } label: { kindChipLabel(mode) }
                        .buttonStyle(ChipButtonStyle(selected: logMode == mode))
                        .accessibilityIdentifier("workout.kind.\(mode.rawValue)")
                }
            }
        }
    }

    /// 1f·AX3: at accessibility sizes "Cardio & activity" would wrap inside its own pill, so the
    /// chips shorten to "Strength" / "Cardio"; default sizes keep the full mode labels.
    private func kindChipLabel(_ mode: WorkoutMode) -> Text {
        guard dynamicTypeSize.isAccessibilitySize else { return Text(verbatim: mode.label) }
        switch mode {
        case .strengthTraining: return Text("Strength")
        case .activity: return Text("Cardio")
        }
    }

    /// The "Log it again" entry card at the top of the sheet (MOVE-08), when a workout of the
    /// current Kind has ever been logged.
    /// The optional workout-name field — below the fold per artboard 3b, beside the Log-again card.
    private var workoutNameField: some View {
        SheetField("Workout") {
            TextField(namePlaceholder, text: $name)
                .sheetTextInput()
        }
    }

    @ViewBuilder private var logAgainCard: some View {
        if let lastLogged {
            LogAgainCard(recent: lastLogged) { prefill(from: lastLogged) }
        }
    }

    /// The Recent chips above the exercise search (MOVE-08): the last five distinct exercises,
    /// each carrying its last sets×reps×weight, one tap prefilling the builder's draft.
    @ViewBuilder private var recentExerciseChips: some View {
        if !recentEntries.isEmpty {
            SheetField("Recent") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(recentEntries, id: \.name) { entry in
                            recentChip(entry)
                        }
                    }
                }
            }
        }
    }

    /// One 44pt Recent chip: name over the factual last-time values.
    private func recentChip(_ entry: TrainerExportBundle.ExerciseHistoryEntry) -> some View {
        Button {
            prefillDraft(from: entry)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.name)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                if let recall = entry.lastTimeRecallValues {
                    Text(verbatim: recall)
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workout.recentExercise.\(entry.name)")
    }

    /// Loads both recall sources once per presentation (MOVE-08): one history rollup for the
    /// chips, one day-record scan for the Log-again card.
    private func refreshRecall() {
        recentEntries = Array(store.exerciseHistoryEntries().prefix(5))
        lastLogged = store.mostRecentLoggedWorkout(mode: logMode)
    }

    /// Prefills the builder's draft from a Recent chip — a tap instead of a keyboard trip.
    private func prefillDraft(from entry: TrainerExportBundle.ExerciseHistoryEntry) {
        guard let target = WorkoutExerciseCatalog.search(entry.name).first else { return }
        draft.clear()
        draft.exercise = target
        if let sets = entry.lastSets, sets > 0 { draft.sets = String(sets) }
        if let reps = entry.lastReps, !reps.isEmpty { draft.reps = reps }
        if let weight = entry.lastWeight {
            let number = weight.formatted(.number.precision(.fractionLength(0...1)))
            draft.weight = entry.weightUnit.map { "\(number) \($0)" } ?? number
        }
    }

    /// Copies the Log-again workout into the sheet's fields: name and prescription, never
    /// per-outing measures (distance stays blank; energy is calorie-opt-in territory).
    private func prefill(from recent: RecentLoggedWorkout) {
        let workout = recent.workout
        name = workout.name
        if logMode == .strengthTraining {
            draft.clear()
            exerciseRows = WorkoutSheetRules.exerciseEntries(from: workout.exercises)
        } else {
            selectedActivityType = workout.activityType
            if let effortValue = workout.effort { effort = String(effortValue) }
        }
        if let minutes = workout.duration { duration = String(minutes) }
    }

    /// The exercise builder plus the rows already added — strength mode only.
    @ViewBuilder private var strengthSection: some View {
        WorkoutExerciseBuilder(
            selectedExercise: $draft.exercise,
            sets: $draft.sets,
            reps: $draft.reps,
            weight: $draft.weight,
            speed: $draft.speed,
            incline: $draft.incline,
            details: $draft.details,
            resetToken: $draft.resetToken,
            pickerTitle: logMode.pickerTitle,
            searchPlaceholder: logMode.searchPlaceholder,
            mode: logMode,
            addLabel: logMode.addLabel,
            historyStore: store,
            onAdd: addDraftExercise
        )

        if !exerciseRows.isEmpty {
            SheetField("Workout exercises") {
                VStack(spacing: 8) {
                    ForEach(exerciseRows) { entry in
                        LoggedExerciseRow(entry: entry) {
                            exerciseRows.removeAll { $0.id == entry.id }
                        }
                    }
                }
            }
        }
    }

    /// RPE + duration, side by side — strength mode only.
    private var strengthMetricsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            SheetField("RPE (1–10)") {
                TextField("7", text: $rpe)
                    .keyboardType(.numberPad)
                    .sheetTextInput(font: .fernlet(.label))
            }
            SheetField("Duration (min)") {
                TextField("45", text: $duration)
                    .keyboardType(.numberPad)
                    .sheetTextInput(font: .fernlet(.label))
            }
        }
    }

    /// The exercises (added rows plus a typed-but-unadded draft) the default name is built from.
    private var namedExercises: [String] {
        var names = exerciseRows.map(\.exercise.name)
        if let drafted = draft.exercise { names.append(drafted.name) }
        return names
    }

    /// The name a strength log takes when the user doesn't type one: the first exercise, plus how
    /// many others came with it ("Bench press + 2"). Empty until something is added — which is
    /// exactly when Save is still gated.
    private var inferredStrengthName: String {
        guard let first = namedExercises.first else { return "" }
        let others = namedExercises.count - 1
        return others > 0 ? "\(first) + \(others)" : first
    }

    /// The name field is optional: the placeholder shows the name that will actually be saved.
    private var namePlaceholder: String {
        if logMode == .activity {
            return selectedActivityType?.displayName ?? "Optional, e.g. Saturday ride"
        }
        return inferredStrengthName.isEmpty ? "Optional, e.g. Upper strength" : inferredStrengthName
    }

    /// Whether there is anything for the category preview to be derived FROM. Before an exercise or
    /// an activity type exists it would claim "Full Body" about an empty sheet.
    private var hasCategoryInput: Bool {
        logMode == .activity ? selectedActivityType != nil : !namedExercises.isEmpty
    }

    /// The free-text notes field.
    private var notesField: some View {
        SheetField("Workout notes") {
            SheetTextEditor(
                text: $notes,
                placeholder: "Pain, form issues, stopped early...",
                minHeight: 100
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // Ordered per artboard 3b, which overrides 1f's drawn stacking where the two
                    // disagree: Kind, Recent and the search fit inside the medium detent so the
                    // quick path from the Home tile is never a sheet the user has to drag open
                    // first; the optional name and the Log-again card live below the fold, where
                    // they belong. The category preview reads beside the metrics it summarizes.
                    kindField

                    if logMode == .strengthTraining {
                        recentExerciseChips
                        strengthSection
                        logAgainCard
                        workoutNameField
                    } else {
                        ActivityPickerSection(
                            selectedActivityType: $selectedActivityType,
                            duration: $duration,
                            distance: $distance,
                            energyKcal: $energyKcal,
                            effort: $effort,
                            showsEnergyField: store.settings.showCalories
                        )
                        logAgainCard
                        workoutNameField
                    }

                    if hasCategoryInput {
                        WorkoutCategoryPreview(category: inferredCategory)
                    }

                    if logMode == .strengthTraining {
                        strengthMetricsRow
                    }

                    notesField
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(disabled: saveDisabled) { saveWorkout() }
        }
        .background(Color.parchment)
        // NOT `keyboardDoneToolbar()` here: this sheet is presented both by the root router (where
        // `fernletSheetChrome` already supplies one) and by the day detail (which supplies its own).
        // Declaring a second `ToolbarItemGroup(placement: .keyboard)` inside the same hierarchy puts
        // two "Done" buttons in one accessory bar.
        // The 2026-08-21 template chrome in one line: the pinned SheetHeader (Cancel + title),
        // blocked swipe-dismiss while dirty, and the discard prompt on Cancel.
        .fernletDraftGuard(isDirty: isDirty, title: "Log workout") { dismiss() }
        .onAppear { refreshRecall() }
        .onChange(of: logMode) { _, _ in
            draft.clear()
            lastLogged = store.mostRecentLoggedWorkout(mode: logMode)
        }
    }

    /// Builds the workout from the sheet's fields and logs it against the target day.
    private func saveWorkout() {
        // The save bar is disabled in this state; guarding here too means the mutation itself
        // states its precondition rather than trusting the button.
        guard !saveDisabled else { return }
        // A typed-but-not-yet-added exercise draft would otherwise be silently dropped on Save —
        // fold it into the rows first (guarded by the same validity addDraftExercise uses).
        if logMode == .strengthTraining, draft.hasExercise {
            addDraftExercise()
        }
        var workout = Workout(
            name: workoutName,
            type: inferredCategory,
            mode: logMode,
            activityType: logMode == .activity ? selectedActivityType : nil,
            exercises: logMode == .strengthTraining ? exerciseText : "",
            rpe: logMode == .strengthTraining ? LocaleTolerantNumber.double(from: rpe) : nil,
            notes: notes,
            duration: LocaleTolerantNumber.int(from: duration),
            distanceMiles: logMode == .activity ? LocaleTolerantNumber.double(from: distance) : nil,
            activeEnergyKcal: logMode == .activity ? LocaleTolerantNumber.double(from: energyKcal) : nil,
            effort: logMode == .activity ? LocaleTolerantNumber.int(from: effort) : nil,
            muscleGroups: logMode == .strengthTraining ? aggregatedMuscleGroups : [],
            intensity: intensity
        )
        workout.completedAt = completedAtDate
        workout.loggedAt = completedAtDate
        store.addWorkout(workout, date: targetDateKey)
        dismiss()
    }

    /// Any user-visible field filled in, a row already added, or a draft exercise typed. Deliberately
    /// shallow — a swipe-away guard, not a change-tracker.
    private var isDirty: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !exerciseRows.isEmpty
            || draft.hasExercise
            || !rpe.isEmpty || !duration.isEmpty || !distance.isEmpty
            || !energyKcal.isEmpty || !effort.isEmpty || !notes.isEmpty
            || selectedActivityType != nil
    }

    private var workoutName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if logMode == .activity, let selectedActivityType {
            return selectedActivityType.displayName
        }
        // A strength log names itself from what's in it, so a daily log costs no keyboard trip:
        // Save enables as soon as one exercise is added.
        return inferredStrengthName
    }

    private var saveDisabled: Bool {
        WorkoutSheetRules.saveDisabled(
            mode: logMode,
            workoutName: workoutName,
            exerciseRows: exerciseRows,
            selectedActivityType: selectedActivityType,
            duration: duration,
            distance: distance,
            // A strength draft is "valid" exactly when an exercise is chosen — the same guard
            // `addDraftExercise` (the Save-closure auto-commit) enforces. Only strength mode auto-commits.
            hasPendingValidDraft: logMode == .strengthTraining && draft.hasExercise
        )
    }

    private var completedAtDate: Date {
        guard targetDateKey != store.todayKey else { return .now }
        let date = FernletDate.date(fromDayKey: targetDateKey) ?? .now
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
    }

    /// Folds the current draft into the logged rows.
    ///
    /// `includingSetsAndReps: logMode == .strengthTraining` preserves this sheet's original guard: the
    /// builder is only rendered in strength mode, so sets/reps can only be non-empty there — but the log
    /// sheet blanked them defensively (activity logs carry no exercise rows), and dropping that would be
    /// a silent behaviour change rather than a simplification. The plan sheet has no such guard, which is
    /// exactly why the shared draft takes it as a parameter instead of assuming one side's answer.
    private func addDraftExercise() {
        // R7: `commit` returns false and leaves the rows untouched when no exercise is chosen —
        // consume it (mirroring ``WorkoutPlanSheet``, which already guards the same call).
        guard draft.commit(into: &exerciseRows, includingSetsAndReps: logMode == .strengthTraining) else { return }
    }
}

/// The Log sheet's pure save-gating and aggregation rules, extracted from ``WorkoutSheet`` so they
/// are unit-testable without SwiftUI.
///
/// `saveDisabled` mirrors the sheet's auto-commit behavior — a lone valid strength draft counts as
/// an exercise because the Save closure folds it in — and an activity log needs a chosen type plus a
/// positive duration or distance.
enum WorkoutSheetRules {
    static func saveDisabled(
        mode: WorkoutMode,
        workoutName: String,
        exerciseRows: [WorkoutExerciseEntry],
        selectedActivityType: WorkoutActivityType?,
        duration: String,
        distance: String,
        hasPendingValidDraft: Bool = false
    ) -> Bool {
        switch mode {
        case .strengthTraining:
            // A typed-but-not-yet-"Added" draft counts as an exercise: the Save closure auto-commits it
            // (mirroring WorkoutPlanSheet, which saves the identical lone-draft input), so a single valid
            // draft must satisfy the has-exercises requirement or that auto-commit is unreachable.
            let hasExercises = !exerciseRows.isEmpty || hasPendingValidDraft
            return workoutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasExercises
        case .activity:
            guard selectedActivityType != nil else { return true }
            let parsedDuration = LocaleTolerantNumber.int(from: duration) ?? 0
            let parsedDistance = LocaleTolerantNumber.double(from: distance) ?? 0
            return parsedDuration <= 0 && parsedDistance <= 0
        }
    }

    static func aggregatedMuscleGroups(from exerciseRows: [WorkoutExerciseEntry]) -> Set<MuscleGroup> {
        exerciseRows.reduce(into: Set<MuscleGroup>()) { acc, row in
            acc.formUnion(row.exercise.primaryMuscles)
            acc.formUnion(row.exercise.secondaryMuscles)
        }
    }

    /// Best-effort parse of free-text exercise lines ("Squat 3x8 @60") back into structured rows.
    ///
    /// Shared by ``WorkoutPlanSheet`` (re-hydrating "Plan steps" on open) and ``WorkoutSheet``'s
    /// "Log it again" prefill (MOVE-08) — one parser, so the two sheets can never disagree about
    /// what a line means. Lines that match no catalog exercise are skipped, not invented.
    static func exerciseEntries(from text: String) -> [WorkoutExerciseEntry] {
        text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let exercise = WorkoutExerciseCatalog.search(trimmed).first else {
                return nil
            }

            let setRep = firstMatch(in: trimmed, pattern: #"(\d+)\s*x\s*(\d+)"#)
            let weight = trimmed
                .split(separator: "@", maxSplits: 1)
                .dropFirst()
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            var details = trimmed.replacingOccurrences(of: exercise.name, with: "")
            if let fullMatch = setRep.fullMatch {
                details = details.replacingOccurrences(of: fullMatch, with: "")
            }
            if !weight.isEmpty {
                details = details.replacingOccurrences(of: "@\(weight)", with: "")
            }
            details = details.trimmingCharacters(in: .whitespacesAndNewlines)

            return WorkoutExerciseEntry(
                exercise: exercise,
                sets: setRep.groups.first ?? "",
                reps: setRep.groups.dropFirst().first ?? "",
                weight: exercise.inputKind == .strength ? weight : "",
                speed: exercise.inputKind == .treadmill ? weight : "",
                incline: "",
                details: details
            )
        }
    }

    /// The first regex match in `text`, as (whole match, capture groups) — nil-safe on both ends.
    private static func firstMatch(in text: String, pattern: String) -> (fullMatch: String?, groups: [String]) {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return (nil, [])
        }
        let fullMatch = Range(match.range(at: 0), in: text).map { String(text[$0]) }
        let groups = (1..<match.numberOfRanges).compactMap { index -> String? in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        return (fullMatch, groups)
    }
}

/// The "Log it again" entry card at the top of the Log sheet (MOVE-08): the most recent logged
/// workout of the current Kind, mirrored on the plan sheet's "Copy previous week" card.
///
/// Shows "<weekday> · <name>" plus a short exercise summary; the "Log again" action is a
/// SECONDARY pill — Save still owns the sheet's primary. At accessibility sizes the button takes
/// its own line under the body copy and the weekday abbreviates (1f·AX3).
struct LogAgainCard: View {
    /// The workout being offered for re-logging, with the day it was logged on.
    var recent: RecentLoggedWorkout
    /// Copies the workout into the sheet's fields — it never saves by itself.
    var onLogAgain: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.moss)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Log it again")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                    Text(verbatim: headline)
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                }
                Spacer(minLength: 8)
                if !dynamicTypeSize.isAccessibilitySize {
                    logAgainButton
                }
            }
            if !summary.isEmpty {
                Text(verbatim: summary)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .lineLimit(2)
            }
            if dynamicTypeSize.isAccessibilitySize {
                // 1f·AX3: the button moves onto its own line under the body copy.
                logAgainButton
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }

    private var logAgainButton: some View {
        Button("Log again", action: onLogAgain)
            .buttonStyle(ActionPillButtonStyle(.secondary))
            .accessibilityIdentifier("workout.logAgain")
    }

    /// "Wednesday · Upper strength" — abbreviated weekday at accessibility sizes.
    private var headline: String {
        let date = FernletDate.date(fromDayKey: recent.dayKey) ?? .now
        let weekday = dynamicTypeSize.isAccessibilitySize
            ? date.formatted(.dateTime.weekday(.abbreviated))
            : date.formatted(.dateTime.weekday(.wide))
        return "\(weekday) · \(recent.workout.name)"
    }

    /// "Bench press, Lat pulldown, Dip · 3 more" for strength; type + minutes for an activity.
    private var summary: String {
        let workout = recent.workout
        if workout.mode == .activity {
            var parts: [String] = []
            if let type = workout.activityType { parts.append(type.displayName) }
            if let minutes = workout.duration { parts.append("\(minutes) min") }
            return parts.joined(separator: " · ")
        }
        let names = workout.exerciseLines.compactMap { ExerciseLineParser.parse($0)?.name }
        let shown = names.isEmpty ? workout.exerciseLines : names
        guard !shown.isEmpty else { return "" }
        let leading = shown.prefix(3).joined(separator: ", ")
        let more = shown.count - min(3, shown.count)
        return more > 0 ? "\(leading) · \(more) more" : leading
    }
}

/// The Suggest flow: configure intensity/context and generate today's guided plan, then review it —
/// start it guided, edit it, adjust it with AI, save it for later (approve), rework it, or bulk-log
/// it as done.
///
/// 2026-08-21 chrome (1b/1d): a pinned ``SheetHeader`` with Cancel top-left (XCUT-15) titles both
/// states; the configurator states the active space inline with one Change into the Your-spaces
/// list (MOVE-34); and the committed state carries ONE green — "Start now" in the bottom bar, with
/// "Save for later" (the renamed Approve) and "Edit" as secondaries (MOVE-17). Finishing the
/// nested runner closes this sheet too, landing the user on the Move root (MOVE-01).
///
/// The committed plan and completed-session set live on ``FernletStore`` (not private `@State`),
/// which is what keeps this sheet and the Move-root "Today's workout" card in agreement: a session
/// finished from either entry point is excluded in both. Every already-logged check routes through
/// ``GuidedWorkoutAvailability`` so a relaunch (fresh session ids, empty completed set) reconciles
/// against the tagged workout names in the day record. The AI adjustment pins the base plan's
/// session ids so a stale result can't land on a plan the user reworked mid-flight, and the rework /
/// edit affordances only appear while nothing of the plan is logged yet.
struct WorkoutSuggestionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var store: FernletStore
    @State private var energy: WorkoutIntensity = .moderate
    @State private var context = ""
    @State private var showingSetup = false
    // The "Your spaces" list (1c), opened by the configurator's inline space row's Change (MOVE-34).
    @State private var showingSpaces = false
    // Cancel-with-typed-note raises the discard prompt instead of silently dropping the note.
    @State private var showDiscardConfirm = false
    @State private var adjustRequest = ""
    @State private var isAdjusting = false
    @State private var didApplyReadiness = false
    // True while a plan is being generated after the user taps "Suggest" — drives the loading state.
    @State private var isSuggesting = false
    // Set when the user taps "Start guided workout"; presents the guided runner sheet. nil = closed.
    @State private var guidedSession: WorkoutProgram.SessionSuggestion?
    // Set when the user taps "Edit"; presents the manual workout editor for that session. nil = closed.
    @State private var editingSession: WorkoutProgram.SessionSuggestion?

    // Today's plan and the set of already-logged sessions live on the store, shared with the Move-root
    // "Start today's workout" card. Reading them here (instead of a private @State) is what lets a
    // session completed from either entry point be excluded in both — the two surfaces hold the same
    // FernletStore, so this is the shared-owner + binding the plan calls for.
    private var dayPlan: WorkoutProgram.DayPlan? { store.currentGuidedWorkoutPlan }
    private var guidedCompletedSessionIDs: Set<UUID> { store.guidedCompletedSessionIDs }

    private var aiAdjustAvailable: Bool {
        // Key off the EFFECTIVE status (stored intent overlaid with today's local call budget), not the
        // raw stored value: at `.resting` a user tap can only fall back to the unchanged plan, so the
        // affordance is hidden rather than silently no-op'ing. `.sleepy` keeps it — a user-invoked
        // adjustment still runs in the sleepy band (only ambient work falls back there).
        let status = store.effectiveAIStatus
        return status != .off && status != .resting && FoodSelectionAvailability.isFoundationModelAvailable
    }

    /// The session in the current plan worth *guiding* through — the first with real, set-based
    /// exercises that hasn't already been logged. Reuses the shared guidable filter; pure
    /// cardio/mobility/rest days return nil, so the guided button is absent (the retroactive "Mark
    /// done" path still works).
    private func guidableSession(in plan: WorkoutProgram.DayPlan) -> WorkoutProgram.SessionSuggestion? {
        GuidedWorkoutAvailability.firstGuidable(
            in: plan,
            excluding: guidedCompletedSessionIDs,
            loggedGuidedWorkoutNames: store.loggedGuidedWorkoutNamesToday
        )
    }

    /// Maps the derived intensity-readiness signal to a recommended workout intensity, if present.
    private var recommendedIntensity: WorkoutIntensity? {
        store.recommendedWorkoutIntensity()
    }

    /// The configurator's inline stated space row (MOVE-34): the saved location and its item count
    /// stated in place, with one trailing "Change" that opens the Your-spaces list (1c) — never the
    /// full setup sheet.
    private var spaceRow: some View {
        SheetField("Space & equipment") {
            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.moss)
                Text(verbatim: "\(store.settings.activeWorkoutLocation.name) · \(store.settings.activeWorkoutLocation.ownedEquipment.count) items")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Spacer(minLength: 8)
                Button("Change") { showingSpaces = true }
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.moss)
                    .buttonStyle(.plain)
                    .fernletTapTarget()
                    .accessibilityIdentifier("workout.space.change")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.cream.opacity(0.86), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.bark.opacity(0.08), lineWidth: 1))
        }
    }

    /// The "Equipment & limits" entry — the only app-wide way into `WorkoutSetupSheet` (split,
    /// frequency, experience, injuries). Kept on the committed-plan branch, so the full setup stays
    /// reachable once a plan is pinned (change it here, then "Rework today's plan" to regenerate
    /// against the new setup); the configurator now states the space inline instead (MOVE-34).
    private var equipmentLimitsButton: some View {
        Button {
            showingSetup = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "dumbbell")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.moss)
                Text("Equipment & limits · \(store.settings.activeWorkoutLocation.name)")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.slate)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.cream.opacity(0.86), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.bark.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// Gentle "Rework today's plan" affordance, shown only while nothing of the committed plan is
    /// logged yet (`store.canReworkTodaysGuidedPlan`). Tapping clears the committed plan, which drops
    /// this sheet back to its configurator — so a plan committed by an exploratory tap (or one built
    /// before an equipment change) isn't an irreversible same-day pin.
    @ViewBuilder private var reworkPlanAffordance: some View {
        if store.canReworkTodaysGuidedPlan {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    // R7: the button is only shown while `canReworkTodaysGuidedPlan`, so a refusal
                    // means the plan changed under us — name it rather than dropping it.
                    if !store.reworkTodaysGuidedPlan() {
                        FernletAuditLog.log("workout.guided.reworkRefused", context: ["site": "reworkPlanAffordance"])
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                        Text("Rework today's plan")
                            .font(.fernlet(.label))
                    }
                    .foregroundStyle(Color.slate)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.slate.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
                // Reworking mid-adjustment would let a stale AI result land on a freshly reworked plan;
                // hold the affordance while an adjustment is in flight (belt to the store-side identity
                // guard's braces), with gentle copy explaining the brief wait.
                .disabled(isAdjusting)
                .accessibilityIdentifier("workout.reworkPlan")

                Text(isAdjusting
                    ? "Hang on — we'll finish your adjustment first, then you can rework it."
                    // "Nothing's logged yet" read as false whenever anything else was logged today:
                    // it means nothing of THIS plan.
                    : "None of this plan is logged yet, so you can still rebuild it — adjust your intensity, notes, or equipment.")
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            .opacity(isAdjusting ? 0.5 : 1)
        }
    }

    /// The committed-plan bottom bar (MOVE-17): ONE green on the screen. **Start now** is the
    /// filled primary and the only route into the runner; **Save for later** (the renamed Approve —
    /// same `approveTodaysGuidedPlan` + dismiss) and **Edit** sit above it as secondary pills; the
    /// retroactive "Already did this — log it" keeps its moss-tint capsule between them.
    ///
    /// 1d·AX3: Edit and Save for later unstack to full width (``AdaptiveStack``), and the
    /// "Already did this" tertiary moves below the primary.
    @ViewBuilder private func committedPlanActionBar(_ dayPlan: WorkoutProgram.DayPlan) -> some View {
        let editTarget = guidableSession(in: dayPlan) ?? dayPlan.sessions.first
        // Sessions not yet logged (guided runner, card, a prior log, or — after a relaunch — a matching
        // tagged workout already in the day record), so "Log as already done" never double-logs.
        let remainingSessions = dayPlan.sessions.filter {
            !GuidedWorkoutAvailability.isAlreadyLogged(
                $0, completed: guidedCompletedSessionIDs,
                loggedGuidedWorkoutNames: store.loggedGuidedWorkoutNamesToday
            )
        }
        VStack(spacing: 10) {
            // Stacks at accessibility sizes so "Save for later" can't break mid-word beside "Edit".
            AdaptiveStack(spacing: 12) {
                // Edit is offered only while nothing of the plan is logged yet — the same precondition
                // `updateGuidedSession` enforces — so an edit is never silently discarded after a
                // session started (matching the rework affordance).
                if store.canReworkTodaysGuidedPlan, let editTarget {
                    Button {
                        editingSession = editTarget
                    } label: {
                        Text("Edit").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ActionPillButtonStyle(.secondary))
                    .disabled(isAdjusting)
                    .accessibilityIdentifier("workout.editPlan")
                }
                Button {
                    store.approveTodaysGuidedPlan()
                    dismiss()
                } label: {
                    Text("Save for later").frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionPillButtonStyle(.secondary))
                .accessibilityIdentifier("workout.approvePlan")
            }
            if !dynamicTypeSize.isAccessibilitySize, !remainingSessions.isEmpty {
                logAlreadyDoneButton(remainingSessions)
            }
            if let guidable = guidableSession(in: dayPlan) {
                startNowButton(guidable)
            }
            if dynamicTypeSize.isAccessibilitySize, !remainingSessions.isEmpty {
                logAlreadyDoneButton(remainingSessions)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .background(Color.parchment)
    }

    /// The retroactive "already did this" action in the committed-plan bar.
    ///
    /// A full-width moss-tint capsule (48pt) rather than the 24pt italic caption it used to be:
    /// this writes workouts, and an action that logs should not be the least tappable thing on the
    /// screen — but it stays a tint, never the screen's green (MOVE-17).
    private func logAlreadyDoneButton(_ sessions: [WorkoutProgram.SessionSuggestion]) -> some View {
        Button {
            logRemainingSessions(sessions)
        } label: {
            Text("Already did this — log it")
                .font(.fernlet(.label))
                .foregroundStyle(Color.moss)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.moss.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workout.logAlreadyDone")
    }

    /// Retroactive log for a workout done outside the app — logs the still-unlogged sessions to the
    /// committed day at the committed intensity, tagged as guided so reconciliation recognizes them
    /// after a relaunch.
    private func logRemainingSessions(_ sessions: [WorkoutProgram.SessionSuggestion]) {
        guard !sessions.isEmpty else { return }
        let intensity = store.committedGuidedIntensity ?? energy
        for session in sessions {
            store.addWorkout(session.workout(intensity: intensity, loggedFromGuidedSession: true))
            store.recordCompletedExercises(session.catalogExerciseNames)
            store.markGuidedSessionCompleted(session.id)
        }
        dismiss()
    }

    /// The configurator bottom bar: **Suggest a workout**, with a loading state while the plan is
    /// generated. At AX5 the label drops to "Suggest" — the primary grows rather than wrapping
    /// (1b·AX5, the exception recorded on 2d).
    @ViewBuilder private var suggestActionBar: some View {
        HStack {
            Spacer()
            Button(action: startSuggesting) {
                HStack(spacing: 8) {
                    if isSuggesting {
                        ProgressView().controlSize(.small).tint(Color.onMoss)
                    }
                    suggestLabel
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.onMoss)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(Color.mossFill.opacity(isSuggesting ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .disabled(isSuggesting)
            .accessibilityIdentifier("workout.suggest")
        }
        .padding(20)
        .background(Color.parchment)
    }

    /// The Suggest primary's label across its states and sizes.
    private var suggestLabel: Text {
        if isSuggesting { return Text("Building your workout…") }
        return dynamicTypeSize >= .accessibility5 ? Text("Suggest") : Text("Suggest a workout")
    }

    /// Generate today's plan with a brief, deliberate loading state. Generation is on-device and
    /// near-instant today, so a short minimum keeps the affordance from flashing (and future-proofs it
    /// for AI-backed generation, which is genuinely slow). The `nil` guard makes a double-tap a no-op.
    private func startSuggesting() {
        guard !isSuggesting, store.currentGuidedWorkoutPlan == nil else { return }
        isSuggesting = true
        let intensity = energy
        let requestContext = context
        Task {
            await Task.yield()
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                // Cancelled (the sheet closed): abandon the suggest rather than committing a plan
                // for a screen that is gone.
                isSuggesting = false
                return
            }
            store.commitTodaysGuidedWorkoutPlan(intensity: intensity, context: requestContext)
            isSuggesting = false
        }
    }

    /// One session card in the committed plan (1d): name, "5 exercises · ~45 min", one prescription
    /// row per exercise, and the session note.
    private func sessionCard(_ session: WorkoutProgram.SessionSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.suggestion.name)
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.bark)
            sessionMetaLine(session)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(session.exercises) { exercise in
                    sessionExerciseRow(exercise)
                }
            }
            if !session.suggestion.notes.isEmpty {
                Text(session.suggestion.notes)
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    /// "5 exercises · ~45 min" under the session name.
    private func sessionMetaLine(_ session: WorkoutProgram.SessionSuggestion) -> Text {
        let minutes = Self.estimatedMinutes(for: session, goal: store.settings.selectedGoal)
        let count = session.exercises.count
        return count == 1
            ? Text("1 exercise · ~\(minutes) min")
            : Text("\(count) exercises · ~\(minutes) min")
    }

    /// One exercise's prescription row: name beside "4 × 8–12". At accessibility sizes name and
    /// prescription stop sharing a line (1d·AX3).
    @ViewBuilder private func sessionExerciseRow(_ exercise: PrescribedExercise) -> some View {
        let prescription: String? = exercise.fromCatalog && exercise.sets >= 1 && !exercise.reps.isEmpty
            ? "\(exercise.sets) × \(exercise.reps)"
            : nil
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                if let prescription {
                    Text(verbatim: prescription)
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(exercise.name)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                Spacer(minLength: 8)
                if let prescription {
                    Text(verbatim: prescription)
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                }
            }
        }
    }

    /// The same rough time heuristic the runner's header uses, over a not-yet-started session:
    /// 45s per prescribed set plus that exercise's rest between its own sets (override, else the
    /// research default for the goal), and 5 min per descriptor line. `static` so it is testable
    /// without standing up the sheet (the `AwayHeartsCopy` precedent).
    nonisolated static func estimatedMinutes(for session: WorkoutProgram.SessionSuggestion, goal: GoalType) -> Int {
        var seconds = 0
        for exercise in session.exercises {
            if exercise.fromCatalog && exercise.sets >= 1 {
                let rest = exercise.restSecondsOverride
                    ?? WorkoutRestGuidance.restSeconds(forExerciseNamed: exercise.name, role: exercise.role, goal: goal)
                seconds += exercise.sets * 45 + max(0, exercise.sets - 1) * max(0, rest)
            } else {
                seconds += 300
            }
        }
        return max(1, (seconds + 59) / 60)
    }

    /// "Start now" — the screen's ONE green, and the only route into the runner (MOVE-17/MOVE-01).
    /// Lives in the bottom bar; the explanation is the single italic line in the scroll content.
    private func startNowButton(_ guidable: WorkoutProgram.SessionSuggestion) -> some View {
        Button {
            // Starting now also approves the plan, so the Move-root "Today's
            // workout" card surfaces it if the user backs out and returns.
            store.approveTodaysGuidedPlan()
            guidedSession = guidable
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(.body.weight(.semibold))
                Text("Start now")
                    .font(.fernlet(.label))
            }
            .foregroundStyle(Color.onMoss)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Color.mossFill, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workout.startGuided")
    }

    /// The natural-language "Adjust with AI" field over a committed plan.
    private var aiAdjustField: some View {
        SheetField("Adjust") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("e.g. swap the squat, 30 minutes, no barbell", text: $adjustRequest)
                    .sheetTextInput()
                    .disabled(isAdjusting)
                Button {
                    runAdjustment()
                } label: {
                    HStack(spacing: 8) {
                        if isAdjusting { ProgressView().controlSize(.small) }
                        Image(systemName: "wand.and.stars")
                            .font(.caption.weight(.semibold))
                        Text(isAdjusting ? "Adjusting…" : "Adjust with AI")
                            .font(.fernlet(.label))
                    }
                    .foregroundStyle(Color.moss)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.moss.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isAdjusting || adjustRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// The committed-plan reading pane (1d): split label, session cards, the context and
    /// explanation lines, then adjust / equipment / rework. No controls compete with the bottom
    /// bar's single green (MOVE-17) — Start now lives there.
    private func committedPlanContent(_ dayPlan: WorkoutProgram.DayPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(dayPlan.splitName) · \(dayPlan.dayTitle)")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.moss)
            ForEach(dayPlan.sessions) { session in
                sessionCard(session)
            }

            committedContextLine
            Text("Start it now, or save it and it'll be waiting on the Move root.")
                .font(.fernlet(.bubble))
                .italic()
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            if aiAdjustAvailable {
                aiAdjustField
            }

            equipmentLimitsButton
            reworkPlanAffordance
        }
    }

    /// "Full gym · built for a hard day" — where and at what intensity the plan was built.
    private var committedContextLine: some View {
        let locationName = store.settings.activeWorkoutLocation.name
        let intensity = (store.committedGuidedIntensity ?? energy).rawValue.lowercased()
        return Text("\(locationName) · built for a \(intensity) day")
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.slate)
    }

    /// The pre-plan configurator (1b): readiness chips, the inline stated space, and the free-text
    /// note — exactly the children that sum to the 437pt medium detent with no internal scroll at
    /// default type. The old Goal row and closing caption gave way to make that true.
    @ViewBuilder private var configuratorContent: some View {
        feelingSection
        spaceRow
        SheetField("Anything else?") {
            TextField("e.g. sore left knee, short on time", text: $context)
                .sheetTextInput()
        }
    }

    /// The readiness section. At AX5 the "How are you feeling?" caption goes — the three chips are
    /// self-describing, and each is already ~100pt tall (1b·AX5).
    @ViewBuilder private var feelingSection: some View {
        if dynamicTypeSize >= .accessibility5 {
            feelingChips
                .onAppear { seedIntensityOnce(preferCommitted: false) }
        } else {
            SheetField("How are you feeling?") {
                VStack(alignment: .leading, spacing: 8) {
                    if let rec = recommendedIntensity {
                        Text("Today's readiness suggests \(rec.rawValue.lowercased()).")
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.slate)
                    }
                    feelingChips
                }
            }
            .onAppear { seedIntensityOnce(preferCommitted: false) }
        }
    }

    /// The Light / Moderate / Hard intensity chips.
    private var feelingChips: some View {
        FlowLayout(spacing: 8) {
            ForEach(WorkoutIntensity.allCases) { intensity in
                Button(intensity.rawValue.capitalized) { energy = intensity }
                    .buttonStyle(ChipButtonStyle(selected: energy == intensity))
            }
        }
    }

    /// Seeds the intensity chips exactly once per presentation.
    ///
    /// With `preferCommitted`, a committed plan's own intensity wins — the configurator that would
    /// set this isn't shown then, and the readiness signal drifts across the day, so anything logged
    /// here reflects how the plan was actually built. Otherwise today's readiness recommendation.
    private func seedIntensityOnce(preferCommitted: Bool) {
        guard !didApplyReadiness else { return }
        didApplyReadiness = true
        if preferCommitted, let committed = store.committedGuidedIntensity {
            energy = committed
        } else if let rec = recommendedIntensity {
            energy = rec
        }
    }

    /// The runner sheet presented from this (already nested) sheet.
    private func guidedRunnerSheet(_ session: WorkoutProgram.SessionSuggestion) -> some View {
        GuidedWorkoutSheet(
            store: store,
            session: session,
            sessionsRemain: dayPlan.map { plan in
                // Reconciliation seam, not an id-only check — truthful done copy after a relaunch.
                plan.sessions.contains {
                    $0.id != session.id && !GuidedWorkoutAvailability.isAlreadyLogged(
                        $0, completed: guidedCompletedSessionIDs,
                        loggedGuidedWorkoutNames: store.loggedGuidedWorkoutNamesToday
                    )
                }
            } ?? false,
            // "Go back to it" (declining to replace a live run) must land on the Move-root Resume
            // card; from THIS nested presentation that means closing the Suggest flow too.
            onExitToResumeCard: { dismiss() },
            // MOVE-01: finishing lands on the Move root with the session logged — the runner's
            // done-screen Done closes this presenter too, ALWAYS, not only when the whole plan is
            // fully logged.
            onFinishedDone: { dismiss() }
        )
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
    }

    /// Closes the whole Suggest flow once every session of the plan is accounted for.
    ///
    /// Always the case on a single-session day once it's guided → nothing left to mark done. Routed
    /// through the reconciliation seam (not an id-only check) so it stays correct after a relaunch.
    private func dismissIfPlanFullyLogged() {
        guard let plan = dayPlan, !plan.sessions.isEmpty else { return }
        let allLogged = plan.sessions.allSatisfy {
            GuidedWorkoutAvailability.isAlreadyLogged(
                $0, completed: guidedCompletedSessionIDs,
                loggedGuidedWorkoutNames: store.loggedGuidedWorkoutNamesToday
            )
        }
        if allLogged { dismiss() }
    }

    /// Whether Cancel has anything to lose: only the configurator's typed note — a committed plan
    /// lives on the store and survives the sheet.
    private var isConfiguratorDirty: Bool {
        dayPlan == nil && !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Cancel top-left (XCUT-15): prompt before discarding a typed note, dismiss directly otherwise.
    private func attemptCancel() {
        if isConfiguratorDirty { showDiscardConfirm = true } else { dismiss() }
    }

    /// The pinned header's title per state; at AX5 "Suggest workout" drops to one word (1b·AX5).
    private var sheetTitle: Text {
        if dayPlan != nil { return Text("Today's session") }
        return dynamicTypeSize >= .accessibility5 ? Text("Suggest") : Text("Suggest workout")
    }

    var body: some View {
        VStack(spacing: 0) {
            // The 2026-08-21 template chrome: grabber (presenter), Cancel, then title — the sheet
            // was swipe-only to dismiss before (XCUT-15).
            SheetHeader(title: sheetTitle, onCancel: attemptCancel)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let dayPlan {
                        committedPlanContent(dayPlan)
                    } else {
                        configuratorContent
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            if let dayPlan {
                committedPlanActionBar(dayPlan)
            } else {
                suggestActionBar
            }
        }
        .background(Color.parchment)
        .interactiveDismissDisabled(isConfiguratorDirty)
        .discardConfirmation(isPresented: $showDiscardConfirm) { dismiss() }
        .onAppear { seedIntensityOnce(preferCommitted: true) }
        .sheet(isPresented: $showingSetup) {
            WorkoutSetupSheet(store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
        .sheet(isPresented: $showingSpaces) {
            // The space row's Change (MOVE-34) — straight to the Your-spaces list (1c), not the
            // full setup sheet.
            WorkoutLocationSetupView(store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
        .sheet(item: $guidedSession, onDismiss: dismissIfPlanFullyLogged) { session in
            guidedRunnerSheet(session)
        }
        .sheet(item: $editingSession) { session in
            GuidedWorkoutEditorSheet(store: store, session: session)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
    }

    private func runAdjustment() {
        guard let plan = dayPlan, isAdjusting == false else { return }
        let request = adjustRequest
        // Identity of the plan this adjustment starts from. An adjustment preserves each session id, so
        // this set still matches when it resolves — UNLESS the user reworked and committed a different
        // plan (fresh ids) meanwhile, in which case `replaceGuidedWorkoutPlan` refuses the stale write.
        let baseSessionIDs = Set(plan.sessions.map(\.id))
        isAdjusting = true
        Task {
            let adjusted = await store.adjustWorkoutDayPlan(plan, request: request)
            // An adjustment keeps each session's id, so completions stay valid — replace in place, but
            // only if the committed plan is still the one we started from.
            store.replaceGuidedWorkoutPlan(adjusted, replacing: baseSessionIDs)
            adjustRequest = ""
            isAdjusting = false
        }
    }
}

/// A logged (completed) workout row with edit and remove recoverability affordances.
///
/// Beyond displaying the workout it carries the recoverability a tester asked for: a one-tap
/// Complete is easy to trigger by accident, so every logged row can be edited or removed. Remove
/// confirms first (gentle copy, and it mentions putting a planned row back when the completion came
/// from one). A workout that lives in Apple Health (`healthKitUUID` set — an import, or a Fernlet
/// log already synced) can't be cleanly edited/removed here without orphaning or resurrecting the
/// Health sample, so a genuine import shows a gentle "manage in Health" note instead, while a
/// Fernlet-authored row stays editable and removal deletes its Health copy too.
struct WorkoutRow: View {
    var store: FernletStore
    var workout: Workout
    var date: String
    /// Called after a remove or edit so the parent can refresh caches it snapshots (calendar days, or a
    /// past-day detail list that isn't observed).
    var onChanged: () -> Void = {}

    @State private var showRemoveConfirm = false
    @State private var showEditSheet = false
    @State private var showHealthRefusalAlert = false

    private var category: WorkoutType {
        WorkoutExerciseCatalog.inferredCategory(for: workout)
    }

    private var targetSummary: String {
        WorkoutExerciseCatalog.targetSummary(for: workout)
    }

    /// Only genuine Apple Health *imports* (a sample another app or a manual Health entry owns) are
    /// read-only here. A Fernlet-authored row — even one already synced to Health — stays editable and
    /// removable; removal deletes the Health copy too.
    private var isHealthImported: Bool { workout.isHealthImported }

    /// Removing an authored row also deletes the Health copy Fernlet wrote — surfaced in the dialog copy.
    private var removesHealthCopy: Bool { workout.isHealthAuthored }

    /// A completion that consumed a planned row will restore it on remove — surfaced in the dialog copy.
    private var restoresPlannedRow: Bool { workout.plannedWorkoutID != nil }

    private var removeConfirmMessage: String {
        var parts: [String] = [
            restoresPlannedRow
                ? "I'll put it back in your plan so you can redo it whenever you're ready."
                : "This just clears it from your log — no worries, you can always add it again."
        ]
        if removesHealthCopy {
            parts.append("This also removes the copy saved to your Health app.")
        }
        return parts.joined(separator: " ")
    }

    /// Name plus the RPE capsule.
    private var titleRow: some View {
        HStack(alignment: .top) {
            Text(workout.name).font(.fernlet(.headerMedium))
            Spacer()
            if let rpe = workout.rpe {
                Text("RPE \(rpe, specifier: "%.1g")")
                    .font(.fernlet(.stat))
                    .foregroundStyle(rpe >= 8 ? Color.terracotta : Color.moss)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((rpe >= 8 ? Color.terracotta : Color.moss).opacity(0.12), in: Capsule())
            }
        }
    }

    /// Category, duration, and intensity.
    private var metaRow: some View {
        HStack(spacing: 12) {
            Text(category.rawValue)
                .foregroundStyle(category.color)
            if let duration = workout.duration { Text("\(duration) min") }
            Text(workout.intensity.rawValue)
        }
        .font(.fernlet(.labelSmall))
        .foregroundStyle(Color.slate)
    }

    /// The logged exercise lines, the target summary, and any note.
    @ViewBuilder private var detailLines: some View {
        if !workout.exerciseLines.isEmpty {
            VStack(spacing: 8) {
                ForEach(Array(workout.exerciseLines.enumerated()), id: \.offset) { _, exercise in
                    WorkoutExerciseRow(exercise: exercise)
                }
            }
        }
        if !targetSummary.isEmpty {
            Text("Targets: \(targetSummary)")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
        }
        if !workout.notes.isEmpty {
            Text(workout.notes)
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)
        }
    }

    /// Edit / Remove, or the gentle "manage it in Health" note for a genuine import.
    @ViewBuilder private var footerActions: some View {
        if isHealthImported {
            HStack(spacing: 8) {
                Image(systemName: "heart.text.square")
                    .font(.caption)
                    .foregroundStyle(Color.slate)
                Text("This came from Health — manage it in the Health app.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            .padding(.top, 2)
        } else {
            HStack(spacing: 10) {
                Button("Edit") { showEditSheet = true }
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.moss)
                    .accessibilityIdentifier("workout.log.edit")
                Button("Remove", role: .destructive) { showRemoveConfirm = true }
                    .font(.fernlet(.label))
                    .accessibilityIdentifier("workout.log.remove")
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    /// Removes the row, consuming the store's refusal Bool: on a refusal (a genuine Health import —
    /// defensive here, since Remove is hidden for those) show the gentle Health note instead of
    /// reporting success.
    private func removeTapped() {
        guard store.removeWorkout(id: workout.id, date: date) else {
            showHealthRefusalAlert = true
            return
        }
        onChanged()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            metaRow
            detailLines
            footerActions
        }
        .padding(.vertical, 4)
        // An alert, not a confirmationDialog: on iOS 26 the dialog renders as a popover that
        // SUPPRESSES the `.cancel` button (leaving a lone red Remove) and anchors to the view root
        // rather than the row, so its arrow pointed at a different workout. The title names the
        // workout, so there is no doubt which one is about to go.
        .alert("Remove \(workout.name)?", isPresented: $showRemoveConfirm) {
            Button("Keep it", role: .cancel) {}
            Button("Remove", role: .destructive) { removeTapped() }
        } message: {
            Text(removeConfirmMessage)
        }
        .alert("This one lives in Apple Health", isPresented: $showHealthRefusalAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("It came from Health, so manage it in the Health app.")
        }
        .sheet(isPresented: $showEditSheet) {
            // .large only, like Log and Plan: at .medium the notes field sat below the fold with no
            // cue that there was anything under it.
            EditWorkoutSheet(store: store, workout: workout, date: date, onSaved: onChanged)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
    }
}

/// A small editor for an already-logged workout — the reversible half of the recoverability feature.
///
/// It edits only the fields that make sense to correct after the fact (name, intensity, duration,
/// notes) and reuses the manual Log sheet's field idiom (`SheetField`, `SheetTextEditor`, chips,
/// `SheetSaveBar`). Everything else — provenance (planned/guided/Health), exercises, targets,
/// timestamps — is carried straight through by editing a copy of the original and letting the store
/// re-assert provenance on save. A guided-logged row's name is pinned (it's the guided card's
/// reconciliation key), and a store refusal (a genuine Health import) keeps the sheet open with an
/// explanation instead of pretending the edit saved.
struct EditWorkoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore
    var workout: Workout
    var date: String
    var onSaved: () -> Void = {}

    @State private var name: String
    @State private var intensity: WorkoutIntensity
    @State private var duration: String
    @State private var rpe: String
    @State private var notes: String
    @State private var showHealthRefusalAlert = false
    @State private var showDiscardConfirm = false

    init(store: FernletStore, workout: Workout, date: String, onSaved: @escaping () -> Void = {}) {
        self.store = store
        self.workout = workout
        self.date = date
        self.onSaved = onSaved
        _name = State(initialValue: workout.name)
        _intensity = State(initialValue: workout.intensity)
        _duration = State(initialValue: workout.duration.map(String.init) ?? "")
        _rpe = State(initialValue: Self.rpeText(workout.rpe))
        _notes = State(initialValue: workout.notes)
    }

    /// The RPE as the field shows it — "7", not "7.0" — and empty when the row carries none.
    private static func rpeText(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%g", value)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Any editable field diverges from the row this sheet opened on.
    private var isDirty: Bool {
        name != workout.name
            || intensity != workout.intensity
            || duration != (workout.duration.map(String.init) ?? "")
            || rpe != Self.rpeText(workout.rpe)
            || notes != workout.notes
    }

    private func attemptCancel() {
        if isDirty { showDiscardConfirm = true } else { dismiss() }
    }

    /// A guided-logged row's name is the guided card's reconciliation key, so it can't be renamed here
    /// (the store also pins it as a fail-closed backstop). The field is shown disabled with a gentle note.
    private var isGuided: Bool { workout.loggedFromGuidedSession == true }

    /// The name field, disabled with a note for a guided-logged row.
    private var nameField: some View {
        SheetField("Workout") {
            TextField("e.g. Upper strength", text: $name)
                .sheetTextInput()
                .disabled(isGuided)
                .opacity(isGuided ? 0.55 : 1)
                .accessibilityIdentifier("workout.edit.name")
            if isGuided {
                Text("Name stays put — it's how your guided plan keeps track of this one.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
    }

    /// The intensity chip row.
    private var intensityField: some View {
        SheetField("Intensity") {
            FlowLayout(spacing: 8) {
                ForEach(WorkoutIntensity.allCases) { level in
                    Button(level.rawValue.capitalized) { intensity = level }
                        .buttonStyle(ChipButtonStyle(selected: intensity == level))
                        .accessibilityIdentifier("workout.edit.intensity.\(level.rawValue)")
                }
            }
        }
    }

    /// Writes the edited fields back through the store.
    ///
    /// Consumes the store's refusal Bool: on a refusal (a genuine Health import) keep the sheet open
    /// and explain, rather than dismissing as if the edit saved.
    private func saveEdits() {
        guard !trimmedName.isEmpty else { return }
        var updated = workout
        updated.name = trimmedName
        updated.intensity = intensity
        updated.duration = LocaleTolerantNumber.int(from: duration)
        // Blank clears the RPE rather than pinning the old one — the field is how you correct it.
        updated.rpe = LocaleTolerantNumber.double(from: rpe)
        updated.notes = notes
        guard store.updateWorkout(updated, date: date) else {
            showHealthRefusalAlert = true
            return
        }
        onSaved()
        dismiss()
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetCancelBar { attemptCancel() }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Edit workout")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    nameField

                    intensityField

                    HStack(alignment: .top, spacing: 12) {
                        SheetField("RPE (1–10)") {
                            TextField("7", text: $rpe)
                                .keyboardType(.numberPad)
                                .sheetTextInput(font: .fernlet(.label))
                                .accessibilityIdentifier("workout.edit.rpe")
                        }
                        SheetField("Duration (min)") {
                            TextField("45", text: $duration)
                                .keyboardType(.numberPad)
                                .sheetTextInput(font: .fernlet(.label))
                                .accessibilityIdentifier("workout.edit.duration")
                        }
                    }

                    SheetField("Workout notes") {
                        SheetTextEditor(
                            text: $notes,
                            placeholder: "Pain, form issues, stopped early...",
                            minHeight: 100
                        )
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(disabled: trimmedName.isEmpty) { saveEdits() }
        }
        .background(Color.parchment)
        .keyboardDoneToolbar()
        .interactiveDismissDisabled(isDirty)
        .discardConfirmation(isPresented: $showDiscardConfirm) { dismiss() }
        .alert("This one lives in Apple Health", isPresented: $showHealthRefusalAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("It came from Health, so manage it in the Health app.")
        }
    }
}

/// One checked-off exercise line inside a logged ``WorkoutRow``.
///
/// Pure display — a checkmark glyph beside the free-text exercise summary the workout was logged
/// with.
struct WorkoutExerciseRow: View {
    var exercise: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.moss)
            Text(exercise)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }
}

/// The read-only "Category · Auto" strip in the Log sheet showing the inferred workout category.
///
/// The category is derived live from the typed name and exercises (see
/// `WorkoutSheet.inferredCategory`), so this preview is how the user sees what the log will be
/// classified as before saving.
struct WorkoutCategoryPreview: View {
    var category: WorkoutType

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(category.color)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text("Category")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                Text(category.rawValue)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
            }
            Spacer()
            Text("Auto")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(category.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(category.color.opacity(0.12), in: Capsule())
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }
}

/// The one summary of the user's movement goal, shared by the Move root's GOAL segment and the
/// Suggest sheet's read-only "Goal" field.
///
/// They used to disagree: the strip showed the first crafted goal's own sentence (which truncated to
/// "Complete 3 gene…") while Suggest showed the goal TYPE ("Wellness"), under the same word "Goal".
/// One function, so both read the same thing. Static so it is unit-testable without SwiftUI.
enum MoveGoalSummary {
    /// e.g. "Wellness · 3 goals", "Wellness · 1 goal", or just "Wellness" when none are written.
    static func text(selectedGoal: GoalType, goalCount: Int) -> String {
        guard goalCount > 0 else { return selectedGoal.displayName }
        return "\(selectedGoal.displayName) · \(goalCount) goal\(goalCount == 1 ? "" : "s")"
    }
}

/// The thin two-segment context strip (Goal · Space) above the workout calendar.
///
/// The three look-alike cream boxes it replaced — a navigational goal, a passive readiness band, and
/// a navigational location — collapse into these two tappable segments. Readiness, already surfaced
/// on Home and inside Suggest, no longer claims a band or caption here.
struct MoveContextStrip: View {
    var store: FernletStore
    var onEditGoal: () -> Void
    var onEditSpace: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Goal segment value; nil renders the empty "Tap to plan" treatment so a first-run goal reads as
    /// an invitation, not a set value.
    private var goalValue: String? {
        if store.goals.isEmpty && store.settings.selectedGoal == .exploring { return nil }
        return MoveGoalSummary.text(selectedGoal: store.settings.selectedGoal, goalCount: store.goals.count)
    }

    private var location: WorkoutLocation { store.settings.activeWorkoutLocation }

    /// "Full gym · 22 items", shortened to "Full gym · 22" at accessibility sizes where the word
    /// "items" is what pushes the line into an ellipsis.
    private var spaceValue: String {
        let count = location.ownedEquipment.count
        return dynamicTypeSize.isAccessibilitySize
            ? "\(location.name) · \(count)"
            : "\(location.name) · \(count) items"
    }

    /// Always the full, unabbreviated sentence — VoiceOver has no width to run out of.
    private var spaceAccessibilityValue: String {
        "\(location.name), \(location.ownedEquipment.count) items"
    }

    var body: some View {
        HStack(spacing: 0) {
            MoveContextSegment(
                icon: "target",
                label: "Goal",
                value: goalValue,
                emptyPrompt: "Tap to plan",
                action: onEditGoal
            )
            // Both segments announce label + current value, then what a tap does — the Goal segment
            // used to announce only the action (never the goal) and Space only the value (never that
            // it opens anything).
            .accessibilityLabel("Goal, \(goalValue ?? "not set")")
            .accessibilityHint("Opens your movement goals")

            Rectangle()
                .fill(Color.bark.opacity(0.10))
                .frame(width: 1)
                .padding(.vertical, 10)

            MoveContextSegment(
                icon: "mappin.and.ellipse",
                label: "Space",
                value: spaceValue,
                emptyPrompt: "Set up your space",
                action: onEditSpace
            )
            .accessibilityLabel("Space, \(spaceAccessibilityValue)")
            .accessibilityHint("Opens where you train")
            // Stable id: the label is the location's NAME, which the user can now rename, so a test that
            // matched on it would break the moment it exercised the rename it's there to check.
            .accessibilityIdentifier("move.space")
        }
        .background(Color.cream.opacity(0.86), in: RoundedRectangle(cornerRadius: FernletMetrics.radiusSm))
        .overlay(RoundedRectangle(cornerRadius: FernletMetrics.radiusSm).stroke(Color.bark.opacity(0.08), lineWidth: 1))
    }
}

/// One tappable half of the context strip: a small uppercase label over a value line, with a
/// leading icon.
///
/// Each segment truncates independently; the icon never clips. A nil value renders the italic empty
/// prompt so a first-run segment reads as an invitation, not a set value.
private struct MoveContextSegment: View {
    var icon: String
    var label: String
    /// The set value; nil shows the italic empty prompt.
    var value: String?
    var emptyPrompt: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(value == nil ? Color.slate.opacity(0.5) : Color.moss)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label.uppercased())
                        .font(.fernlet(.labelSmall))
                        .tracking(0.6)
                        .foregroundStyle(value == nil ? Color.slate.opacity(0.5) : Color.slate)
                    if let value {
                        Text(value)
                            // Two lines, not one: at default size an accepted goal already truncated
                            // to "Complete 3 gene…" with no way to read the rest.
                            .font(.fernlet(.label))
                            .foregroundStyle(Color.bark)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(emptyPrompt)
                            .font(.fernlet(.bubble))
                            .foregroundStyle(Color.slate)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One editable exercise row in the workout sheets: a catalog exercise plus its free-text inputs
/// (sets/reps/weight for strength, speed/incline for treadmill, details for either).
///
/// `summary` renders the row into the single free-text line that `Workout`/`PlannedWorkout` store in
/// their `exercises` field — the shared display and persistence format for exercise lines.
struct WorkoutExerciseEntry: Identifiable, Equatable {
    var id = UUID()
    var exercise: ExerciseTarget
    var sets: String
    var reps: String
    var weight: String
    var speed: String
    var incline: String
    var details: String

    var summary: String {
        var parts: [String] = [exercise.name]
        let cleanSets = sets.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanReps = reps.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanWeight = weight.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSpeed = speed.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanIncline = incline.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)

        switch exercise.inputKind {
        case .strength:
            if !cleanSets.isEmpty && !cleanReps.isEmpty {
                parts.append("\(cleanSets)x\(cleanReps)")
            } else if !cleanSets.isEmpty {
                parts.append("\(cleanSets) sets")
            } else if !cleanReps.isEmpty {
                parts.append("\(cleanReps) reps")
            }
            if !cleanWeight.isEmpty { parts.append("@\(cleanWeight)") }
        case .treadmill:
            if !cleanSpeed.isEmpty { parts.append("\(cleanSpeed) mph") }
            if !cleanIncline.isEmpty { parts.append("\(cleanIncline)% incline") }
        case .none:
            break
        }
        if !cleanDetails.isEmpty { parts.append(cleanDetails) }
        return parts.joined(separator: " ")
    }
}

/// The "one exercise currently being typed" state machine shared by ``WorkoutSheet`` and
/// ``WorkoutPlanSheet``.
///
/// Both sheets present the same ``WorkoutExerciseBuilder`` over a chosen exercise plus its free-text
/// inputs, and both need the same three operations on it: bind the fields, commit the draft into a
/// row list, and clear it. The row editor was already shared; only this state machine was
/// copy-pasted, so the two `addDraftExercise`/`clearDraftExercise` pairs could (and did) drift.
/// Holding the fields in one value type also means a new input (a future tempo, RPE-per-set, …) is
/// added once and both sheets get it.
///
/// Used as `@State`, so `$draft.sets` and friends are ordinary bindings into the builder — the
/// sheets keep owning the state exactly as before, they just stop re-declaring it.
///
/// Invariants:
/// - `exercise == nil` means "nothing typed yet"; ``commit(into:includingSetsAndReps:)`` is then a
///   no-op and reports `false`, which is the guard both sheets' save-time auto-commit relies on.
/// - Committing always clears (via ``clear()``), and clearing always bumps ``resetToken`` — the
///   builder watches that token to reset its own picker/search sub-state, so the token must never
///   be advanced without also blanking the fields.
/// - The `inputKind` filtering in ``entry(includingSetsAndReps:)`` is what stops a treadmill row
///   from carrying a stale weight (or a strength row a stale incline) when the user switches
///   exercises mid-draft without clearing.
struct WorkoutExerciseDraft {
    /// The catalog exercise the user picked, or `nil` while nothing is chosen.
    var exercise: ExerciseTarget?
    /// Free-text set count (strength inputs only).
    var sets = ""
    /// Free-text rep count (strength inputs only).
    var reps = ""
    /// Free-text working weight; kept only for `.strength` exercises.
    var weight = ""
    /// Free-text treadmill speed; kept only for `.treadmill` exercises.
    var speed = ""
    /// Free-text treadmill incline; kept only for `.treadmill` exercises.
    var incline = ""
    /// Free-text notes, kept for every input kind.
    var details = ""
    /// Bumped on every ``clear()`` so ``WorkoutExerciseBuilder`` resets its internal picker state.
    var resetToken = 0

    /// Whether an exercise has been chosen — the sheets' "is there something to auto-commit / is the
    /// sheet dirty" question.
    var hasExercise: Bool { exercise != nil }

    /// The row this draft would produce, or `nil` when no exercise is chosen.
    ///
    /// - Parameter includingSetsAndReps: `false` blanks sets/reps. ``WorkoutSheet`` passes
    ///   `logMode == .strengthTraining` here, matching its original behaviour; ``WorkoutPlanSheet``
    ///   always kept them. In practice both sheets only show the builder in strength mode, so the
    ///   two agree today — the parameter preserves the log sheet's explicit belt-and-braces guard
    ///   rather than silently adopting the plan sheet's unconditional version.
    func entry(includingSetsAndReps: Bool = true) -> WorkoutExerciseEntry? {
        guard let exercise else { return nil }
        return WorkoutExerciseEntry(
            exercise: exercise,
            sets: includingSetsAndReps ? sets : "",
            reps: includingSetsAndReps ? reps : "",
            weight: exercise.inputKind == .strength ? weight : "",
            speed: exercise.inputKind == .treadmill ? speed : "",
            incline: exercise.inputKind == .treadmill ? incline : "",
            details: details
        )
    }

    /// Appends the draft's row to `rows` and clears the draft.
    ///
    /// - Returns: `false` (and leaves `rows` untouched) when no exercise is chosen, so a caller with
    ///   follow-up work — the plan sheet re-folds its rows into the free-text plan — can bail on the
    ///   same condition the old `guard let draftExercise else { return }` used.
    ///
    /// Not `@discardableResult`: this is a success/failure signal (R7), so every caller consumes it.
    mutating func commit(into rows: inout [WorkoutExerciseEntry], includingSetsAndReps: Bool = true) -> Bool {
        guard let entry = entry(includingSetsAndReps: includingSetsAndReps) else { return false }
        rows.append(entry)
        clear()
        return true
    }

    /// Blanks every field and advances ``resetToken`` so the builder drops its picker/search state.
    mutating func clear() {
        exercise = nil
        sets = ""
        reps = ""
        weight = ""
        speed = ""
        incline = ""
        details = ""
        resetToken += 1
    }
}

/// Display half of the row editor's "last time" recall (``WorkoutExerciseBuilder``).
extension TrainerExportBundle.ExerciseHistoryEntry {
    /// The values half of the "Last time: 3x8 @ 135 lb" line — the most recent session's sets×reps
    /// as logged, plus its weight in the unit the user wrote (bare number when no unit was ever
    /// stated). `nil` when the entry carries neither a prescription nor a load, so the caller shows
    /// nothing rather than an empty recall. Factual only: no comparison against today's draft, no
    /// trend, no praise (round 2.1 design constraint).
    var lastTimeRecallValues: String? {
        var parts: [String] = []
        if let sets = lastSets, let reps = lastReps, sets > 0, !reps.isEmpty {
            parts.append("\(sets)x\(reps)")
        }
        if let weight = lastWeight {
            let number = weight.formatted(.number.precision(.fractionLength(0...1)))
            let unit = weightUnit.map { " \($0)" } ?? ""
            parts.append("@ \(number)\(unit)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }
}

/// The shared exercise-entry form: catalog search picker plus the input fields for the selected
/// exercise's kind (sets/reps/weight, or speed/incline), with an optional Add button.
///
/// Reused by ``WorkoutSheet`` and ``WorkoutPlanSheet``; all field state is
/// bound to the presenting sheet, which owns the draft and decides what an Add (or an implicit
/// save-time fold) does with it.
///
/// When `historyStore` is set, picking an exercise also surfaces a one-line factual recall of the
/// last logged session for it ("Last time: 3x8 @ 135 lb") — refreshed once per pick, never per
/// keystroke, and absent entirely when that exercise has no parsed history.
struct WorkoutExerciseBuilder: View {
    @Binding var selectedExercise: ExerciseTarget?
    @Binding var sets: String
    @Binding var reps: String
    @Binding var weight: String
    @Binding var speed: String
    @Binding var incline: String
    @Binding var details: String
    @Binding var resetToken: Int
    var pickerTitle = "Exercise"
    var searchPlaceholder = "Search exercise or muscle"
    var mode: WorkoutMode = .strengthTraining
    var addLabel = "Add exercise"
    var showAddButton = true
    /// Forwarded to ``ExerciseSearchPicker`` — see there.
    var autofocusSearch = false
    /// Backs the "last time" recall line with the store's logged day history; `nil` (the default)
    /// hides the line entirely, so call sites without a store are untouched.
    var historyStore: FernletStore? = nil
    var onAdd: () -> Void

    /// The resolved recall values for the current pick — held as state so the rollup runs once per
    /// exercise selection (see ``refreshLastTime()``), not on every keystroke in the fields below.
    @State private var lastTimeValues: String?

    private var inputKind: ExerciseInputKind {
        selectedExercise?.inputKind ?? .strength
    }

    /// Recomputes ``lastTimeValues`` for the current selection. `nil` (no store, no pick, or no
    /// parsed history for that exercise) renders no line at all — nothing is the honest display for
    /// "never logged".
    private func refreshLastTime() {
        guard let historyStore, let selectedExercise else {
            lastTimeValues = nil
            return
        }
        lastTimeValues = historyStore.exerciseHistoryEntry(named: selectedExercise.name)?
            .lastTimeRecallValues
    }

    /// Sets / reps / weight / details — the strength prescription fields.
    @ViewBuilder private var strengthFields: some View {
        HStack(alignment: .top, spacing: 12) {
            SheetField("Sets") {
                TextField("3", text: $sets)
                    .keyboardType(.numberPad)
                    .sheetTextInput(font: .fernlet(.label))
            }
            SheetField("Reps") {
                TextField("8", text: $reps)
                    .keyboardType(.numberPad)
                    .sheetTextInput(font: .fernlet(.label))
            }
        }

        SheetField("Weight") {
            TextField("30 lb", text: $weight)
                .sheetTextInput()
        }

        SheetField("Details") {
            TextField("tempo, form note", text: $details)
                .sheetTextInput()
        }
    }

    /// Speed / incline / details — the treadmill prescription fields.
    @ViewBuilder private var treadmillFields: some View {
        HStack(alignment: .top, spacing: 12) {
            SheetField("Speed") {
                TextField("5.5 mph", text: $speed)
                    .keyboardType(.decimalPad)
                    .sheetTextInput(font: .fernlet(.label))
            }
            SheetField("Incline") {
                TextField("2", text: $incline)
                    .keyboardType(.decimalPad)
                    .sheetTextInput(font: .fernlet(.label))
            }
        }

        SheetField("Details") {
            TextField("intervals, distance, notes", text: $details)
                .sheetTextInput()
        }
    }

    /// The Add button, disabled until an exercise is chosen.
    private var addButton: some View {
        Button(action: onAdd) {
            Label(addLabel, systemImage: "plus.circle.fill")
                .font(.fernlet(.label))
                .foregroundStyle(selectedExercise == nil ? Color.slate.opacity(0.45) : Color.moss)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(selectedExercise == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ExerciseSearchPicker(
                selectedExercise: $selectedExercise,
                resetToken: $resetToken,
                title: pickerTitle,
                placeholder: searchPlaceholder,
                autofocus: autofocusSearch
            )

            if let lastTimeValues {
                Text("Last time: \(lastTimeValues)")
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                    .accessibilityIdentifier("exercise.lastTime")
            }

            switch inputKind {
            case .strength:
                strengthFields
            case .treadmill:
                treadmillFields
            case .none:
                EmptyView()
            }

            if showAddButton {
                addButton
            }
        }
        // Attached to the always-rendered VStack, never to the conditional line — an empty view's
        // onAppear/onChange silently never fire.
        .onAppear { refreshLastTime() }
        .onChange(of: selectedExercise) { _, _ in refreshLastTime() }
    }
}

/// Search-as-you-type picker over the exercise catalog, collapsing to the chosen exercise once one
/// is selected.
///
/// Bumping `resetToken` clears the query from outside — how the sheets reset the picker after an
/// add. Also reused by ``GuidedWorkoutEditorSheet`` to append catalog exercises to a session.
struct ExerciseSearchPicker: View {
    @Binding var selectedExercise: ExerciseTarget?
    @Binding var resetToken: Int
    @State private var query = ""
    var title = "Exercise"
    var placeholder = "Search exercise or muscle"
    /// Puts the keyboard in the search field as the sheet opens. Only the speed-first Quick exercise
    /// sheet asks for it — a sheet with fields above the picker shouldn't yank focus past them.
    var autofocus = false
    @FocusState private var searchFocused: Bool

    private var results: [ExerciseTarget] {
        Array(WorkoutExerciseCatalog.search(query).prefix(8))
    }

    /// Return picks the top result instead of doing nothing — typing "squat" then Return used to
    /// leave the user reaching back up to tap the row they'd already named.
    private func selectFirstResult() {
        guard selectedExercise == nil, let first = results.first else { return }
        selectedExercise = first
        query = first.name
        searchFocused = false
    }

    var body: some View {
        // `verbatim:` — `title` is a `String` fed from a domain enum's picker title, so it arrives
        // already resolved rather than as authored copy written here.
        SheetField(verbatim: title) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.slate)
                    TextField(placeholder, text: $query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(false)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .onSubmit { selectFirstResult() }
                        .accessibilityIdentifier("exercise.search")
                }
                .sheetTextInput()

                if let selectedExercise {
                    ExerciseSearchResultRow(exercise: selectedExercise, isSelected: true) {
                        self.selectedExercise = nil
                    }
                }

                if selectedExercise == nil {
                    VStack(spacing: 6) {
                        ForEach(results) { exercise in
                            ExerciseSearchResultRow(exercise: exercise, isSelected: false) {
                                selectedExercise = exercise
                                query = exercise.name
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: resetToken) { _, _ in
            query = ""
        }
        .onAppear {
            if autofocus && selectedExercise == nil { searchFocused = true }
        }
    }
}

/// One row in the exercise search results — name, category dot, muscles, and a plus/clear glyph.
///
/// The same row renders both the selected exercise (tap to clear) and an unselected result (tap to
/// pick), keyed off `isSelected`.
struct ExerciseSearchResultRow: View {
    var exercise: ExerciseTarget
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(exercise.category.color)
                    .frame(width: 9, height: 9)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                    Text("\(exercise.category.rawValue) - \(exercise.muscles.joined(separator: ", "))")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                }
                Spacer()
                Image(systemName: isSelected ? "xmark.circle" : "plus.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.slate : Color.moss)
            }
            .padding(10)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.bark.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A read-only added-exercise row in the Log sheet, with a remove button.
///
/// Shows the entry's name, its summary minus the name, and its muscles; corrections happen by
/// removing the row and re-adding it through the builder.
struct LoggedExerciseRow: View {
    var entry: WorkoutExerciseEntry
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.exercise.name)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                Text(entry.summary.replacingOccurrences(of: entry.exercise.name, with: "").trimmingCharacters(in: .whitespaces))
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                Text(entry.exercise.muscles.joined(separator: ", "))
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(entry.exercise.category.color)
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.slate)
            }
            .buttonStyle(.plain)
            .fernletIconButton("Remove \(entry.exercise.name)")
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }
}

/// An in-place editable exercise row in the plan sheet — fields vary by the exercise's input kind.
///
/// Unlike ``LoggedExerciseRow`` its fields stay live; every keystroke calls `onChange` so
/// ``WorkoutPlanSheet`` can re-fold the rows into its plan-steps text.
struct EditablePlannedExerciseRow: View {
    @Binding var entry: WorkoutExerciseEntry
    var onRemove: () -> Void
    var onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.exercise.name)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                    Text(entry.exercise.muscles.joined(separator: ", "))
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(entry.exercise.category.color)
                }
                Spacer()
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.slate)
                }
                .buttonStyle(.plain)
                .fernletIconButton("Remove \(entry.exercise.name)")
            }

            switch entry.exercise.inputKind {
            case .strength:
                HStack(alignment: .top, spacing: 10) {
                    editableField("Sets", text: $entry.sets, keyboard: .numberPad)
                    editableField("Reps", text: $entry.reps, keyboard: .numberPad)
                    editableField("Weight", text: $entry.weight)
                }
            case .treadmill:
                HStack(alignment: .top, spacing: 10) {
                    editableField("Speed", text: $entry.speed, keyboard: .decimalPad)
                    editableField("Incline", text: $entry.incline, keyboard: .decimalPad)
                }
            case .none:
                EmptyView()
            }

            editableField("Details", text: $entry.details)
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }

    private func editableField(
        _ label: String,
        text: Binding<String>,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
            TextField(label, text: text)
                .keyboardType(keyboard)
                // Tabular DM Sans for the numeric fields, per the shared field idiom.
                .sheetTextInput(font: keyboard == .default ? nil : .fernlet(.label))
                .onChange(of: text.wrappedValue) { _, _ in onChange() }
        }
    }
}

/// The week-strip workout calendar on the Move root: seven tappable day cells with logged/planned
/// category dots, week paging chevrons, and a split legend.
///
/// Renders a ``WorkoutWeekModel`` built from the parent's `allDays` snapshot. The legend shows the
/// default splits plus any split actually planned in the last month, so uncommon splits only claim
/// legend space while they're in use. Day taps hand the day key back for navigation to
/// ``MoveDayDetailView``.
struct WorkoutCalendarCard: View {
    @Binding var displayedWeek: Date
    var allDays: [String: FernletDay]
    var todayKey: String
    var selectedGoal: GoalType
    var goals: [FitnessGoal]
    var showsPlanSourceTag: Bool
    var onDayTapped: (String) -> Void

    private var cal: Calendar { .current }
    private let defaultLegendSplits: [WorkoutSplit] = [.fullBody, .upper, .lower, .workout]
    // 1a·AX3: at accessibility sizes the strip shows ~3 days behind a horizontal scroll and drops
    // its legend; the cells drop their per-day captions themselves.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var legendSplits: [WorkoutSplit] {
        let today = FernletDate.date(fromDayKey: todayKey) ?? .now
        let cutoff = cal.date(byAdding: .month, value: -1, to: today) ?? today
        let cutoffKey = FernletDate.dayKey(for: cutoff)

        let recentSplits = allDays
            .filter { $0.key >= cutoffKey && $0.key <= todayKey }
            .flatMap { $0.value.plannedWorkouts.map(\.split) }

        return WorkoutSplit.allCases.filter { split in
            defaultLegendSplits.contains(split) || recentSplits.contains(split)
        }
    }

    var body: some View {
        let model = WorkoutWeekModel(date: displayedWeek, allDays: allDays, todayKey: todayKey)
        return FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Button {
                        displayedWeek = cal.date(byAdding: .weekOfYear, value: -1, to: displayedWeek) ?? displayedWeek
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.slate)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Previous week")

                    Text(model.weekTitle)
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(Color.bark)
                        .frame(maxWidth: .infinity)

                    Button {
                        displayedWeek = cal.date(byAdding: .weekOfYear, value: 1, to: displayedWeek) ?? displayedWeek
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.slate)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next week")
                }

                weekStrip(model)
                if !dynamicTypeSize.isAccessibilitySize {
                    workoutLegend
                }
            }
        }
    }

    /// Seven cells side by side; at accessibility sizes they go behind a horizontal scroll
    /// (about three visible, wide fixed tiles) instead of squeezing seven columns (1a·AX3).
    @ViewBuilder private func weekStrip(_ model: WorkoutWeekModel) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.cells) { cell in
                        WorkoutCalendarCell(cell: cell) {
                            onDayTapped(cell.dateKey)
                        }
                        .frame(width: 96)
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                ForEach(model.cells) { cell in
                    WorkoutCalendarCell(cell: cell) {
                        onDayTapped(cell.dateKey)
                    }
                }
            }
        }
    }

    /// The split legend, wrapped rather than shrunk: as a fixed row with `minimumScaleFactor(0.7)` the
    /// entries scaled down to "Work…"/"Full B…" instead of taking a second line.
    private var workoutLegend: some View {
        FlowLayout(spacing: 10) {
            ForEach(legendSplits) { split in
                HStack(spacing: 4) {
                    Circle().fill(split.color).frame(width: 8, height: 8)
                    Text(split.title).font(.fernlet(.labelSmall)).foregroundStyle(Color.slate)
                }
                .fixedSize()
            }
        }
    }
}

/// One tappable day cell in the calendar week strip.
///
/// Pure rendering of a ``WorkoutWeekCell`` — fill, today ring, logged (solid) and planned (faded)
/// category dots, and the log/plan/rest summary line.
struct WorkoutCalendarCell: View {
    var cell: WorkoutWeekCell
    var onTap: () -> Void
    // 1a·AX3: the per-day caption ("Rest" / "1 log" / "1 plan") is dropped at accessibility sizes
    // so the day tile itself stays legible; VoiceOver still gets the full label.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                Text(cell.weekdayText)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                RoundedRectangle(cornerRadius: 8)
                    .fill(cell.fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(cell.isToday ? Color.moss : Color.clear, lineWidth: 1.5)
                    )
                    .overlay {
                        VStack(spacing: 4) {
                            Text("\(cell.day)")
                                .font(.fernlet(.stat))
                                .foregroundStyle(
                                    cell.isFuture ? Color.bark.opacity(0.28)
                                        : cell.isToday ? Color.moss
                                        : Color.bark.opacity(0.68)
                                )
                            if !cell.categories.isEmpty || !cell.plannedCategories.isEmpty {
                                HStack(spacing: 2) {
                                    ForEach(Array(cell.categories.prefix(3).enumerated()), id: \.offset) { _, category in
                                        Circle()
                                            .fill(category.color)
                                            .frame(width: 5, height: 5)
                                    }
                                    ForEach(Array(cell.plannedCategories.prefix(max(0, 3 - cell.categories.count)).enumerated()), id: \.offset) { _, category in
                                        Circle()
                                            .fill(category.color.opacity(0.38))
                                            .frame(width: 5, height: 5)
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: 46)
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(cell.summaryText)
                        .font(.fernlet(.labelSmall))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(cell.categories.isEmpty && cell.plannedCategories.isEmpty ? Color.slate.opacity(0.45) : Color.slate)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(cell.accessibilityLabel)
    }
}

/// The display model for one day cell of the workout calendar week strip.
///
/// Precomputed by ``WorkoutWeekModel`` from that day's record: deduplicated logged categories,
/// planned splits/categories, counts, and the today/future flags that drive the cell's fill and text
/// colors.
struct WorkoutWeekCell: Identifiable {
    let id = UUID()
    var day: Int
    var dateKey: String
    var weekdayText: String
    var longWeekdayText: String
    var monthDayText: String
    var categories: [WorkoutType]
    var plannedWorkouts: [PlannedWorkout]
    var plannedSplits: [WorkoutSplit]
    var plannedCategories: [WorkoutType]
    var workoutCount: Int
    var plannedCount: Int
    var isToday: Bool
    var isFuture: Bool = false

    var fill: Color {
        if let first = categories.first { return first.color.opacity(isToday ? 0.34 : 0.24) }
        if let first = plannedCategories.first { return first.color.opacity(isToday ? 0.18 : 0.12) }
        if isToday { return Color.moss.opacity(0.18) }
        return Color.softTaupe.opacity(0.16)
    }

    var summaryText: String {
        if workoutCount == 0 && plannedCount == 0 { return "Rest" }
        if workoutCount == 0 { return plannedCount == 1 ? "1 plan" : "\(plannedCount) plans" }
        return workoutCount == 1 ? "1 log" : "\(workoutCount) logs"
    }

    var accessibilityLabel: String {
        let categoryText = categories.map(\.rawValue).joined(separator: ", ")
        let planText = plannedSplits.map(\.title).joined(separator: ", ")
        if categoryText.isEmpty && !planText.isEmpty { return "\(weekdayText), day \(day), planned \(planText)" }
        if categoryText.isEmpty { return isToday ? "Today, day \(day), no workouts" : "\(weekdayText), day \(day), no workouts" }
        return isToday ? "Today, day \(day), \(categoryText)" : "\(weekdayText), day \(day), \(categoryText)"
    }
}

/// Builds the calendar card's week: a "Jun 1 - Jun 7"-style title plus seven ``WorkoutWeekCell``s
/// for the week containing `date`.
///
/// Pure and synchronous over the `allDays` snapshot so the card's body stays cheap; category and
/// split lists are deduplicated in first-seen order.
struct WorkoutWeekModel {
    let weekTitle: String
    let cells: [WorkoutWeekCell]

    init(date: Date, allDays: [String: FernletDay], todayKey: String, calendar: Calendar = .current) {
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: date)
        assert(weekInterval != nil, "week interval required")
        let start = weekInterval?.start ?? date
        let dates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }

        if let first = dates.first, let last = dates.last {
            weekTitle = "\(first.formatted(.dateTime.month(.abbreviated).day())) - \(last.formatted(.dateTime.month(.abbreviated).day()))"
        } else {
            weekTitle = date.formatted(.dateTime.month(.abbreviated).day())
        }

        cells = dates.map { date in
            let key = FernletDate.dayKey(for: date)
            let workouts = allDays[key]?.workouts ?? []
            let plannedWorkouts = allDays[key]?.plannedWorkouts ?? []
            let categories = workouts.reduce(into: [WorkoutType]()) { result, workout in
                let category = WorkoutExerciseCatalog.inferredCategory(for: workout)
                if !result.contains(category) { result.append(category) }
            }
            let plannedSplits = plannedWorkouts.reduce(into: [WorkoutSplit]()) { result, workout in
                let split = workout.split
                if !result.contains(split) { result.append(split) }
            }
            let plannedCategories = plannedWorkouts.reduce(into: [WorkoutType]()) { result, workout in
                let category = workout.workoutType
                if !result.contains(category) { result.append(category) }
            }
            return WorkoutWeekCell(
                day: calendar.component(.day, from: date),
                dateKey: key,
                weekdayText: date.formatted(.dateTime.weekday(.narrow)),
                longWeekdayText: date.formatted(.dateTime.weekday(.abbreviated)),
                monthDayText: date.formatted(.dateTime.month(.abbreviated).day()),
                categories: categories,
                plannedWorkouts: plannedWorkouts,
                plannedSplits: plannedSplits,
                plannedCategories: plannedCategories,
                workoutCount: workouts.count,
                plannedCount: plannedWorkouts.count,
                isToday: key == todayKey,
                isFuture: key > todayKey
            )
        }
    }
}

/// The per-day drill-in from the calendar: that day's plan and logged workouts, with Plan and Log
/// entry points in the toolbar.
///
/// Past-day reads (`store.loadDay` for a non-today key) aren't observed, so mutations bump a local
/// `reloadToken` to force a re-read — the same nudge every row callback uses. Future days hide the
/// log section and the complete action (you can plan ahead but not log ahead).
struct MoveDayDetailView: View {
    var store: FernletStore
    var dateKey: String
    var showsPlanSourceTag: Bool
    @State private var showWorkoutSheet = false
    @State private var showPlanSheet = false
    @State private var editingPlannedWorkout: PlannedWorkout?
    // Past-day reads (`store.loadDay` for a non-today key) aren't observed, so a remove/edit on a past
    // day needs an explicit nudge to re-render. Bumping this re-evaluates the body, re-reading `day`.
    @State private var reloadToken = 0

    private var day: FernletDay {
        _ = reloadToken
        return store.loadDay(for: dateKey)
    }

    private var isFuture: Bool {
        dateKey > store.todayKey
    }

    /// Typed `Text` because the two branches differ in kind: "Today" is authored copy that should
    /// translate, while the formatted date has already localized itself and must not be looked up.
    private var navigationTitle: Text {
        if dateKey == store.todayKey { return Text("Today") }
        let date = FernletDate.date(fromDayKey: dateKey) ?? .now
        return Text(verbatim: date.formatted(.dateTime.month(.abbreviated).day()))
    }

    /// The full date under the header title. Replaces "Movement only." — which said nothing about
    /// WHICH day, next to a nav bar that was already repeating the title.
    private var headerSubtitle: String {
        let date = FernletDate.date(fromDayKey: dateKey) ?? .now
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    /// One planned row, wired to the reload-token nudge past days need.
    private func plannedRow(_ workout: PlannedWorkout) -> some View {
        PlannedWorkoutRow(
            plannedWorkout: workout,
            showsPlanSourceTag: showsPlanSourceTag,
            showsCompleteAction: !isFuture,
            // Past-day reads aren't observed — bump the reload token so the list
            // re-reads `day` after a complete/delete (a stale row otherwise allows a
            // second tap).
            onComplete: {
                store.completePlannedWorkout(workout, date: dateKey)
                reloadToken += 1
            },
            onEdit: {
                editingPlannedWorkout = workout
                showPlanSheet = true
            },
            onDelete: {
                store.deletePlannedWorkout(workout, date: dateKey)
                reloadToken += 1
            }
        )
    }

    /// The day's plan: an empty-state that opens the planner, or the planned rows.
    private var planSection: some View {
        FernletScrollSection("Plan") {
            if day.plannedWorkouts.isEmpty {
                Button {
                    editingPlannedWorkout = nil
                    showPlanSheet = true
                } label: {
                    EmptyState(text: "No workouts planned")
                }
                .buttonStyle(.plain)
            } else {
                ForEach(Array(day.plannedWorkouts.enumerated()), id: \.element.id) { index, workout in
                    plannedRow(workout)
                    if index < day.plannedWorkouts.count - 1 { FernletRowDivider() }
                }
            }
        }
    }

    /// The day's logged workouts — hidden on future days (you can plan ahead, not log ahead).
    @ViewBuilder private var workoutsSection: some View {
        if !isFuture {
            FernletScrollSection("Workouts") {
                if day.workouts.isEmpty {
                    EmptyState(text: "No workouts logged")
                } else {
                    ForEach(Array(day.workouts.enumerated()), id: \.element.id) { index, workout in
                        WorkoutRow(
                            store: store,
                            workout: workout,
                            date: dateKey,
                            onChanged: { reloadToken += 1 }
                        )
                        if index < day.workouts.count - 1 { FernletRowDivider() }
                    }
                }
            }
        }
    }

    /// One toolbar capsule — the Plan and Log entries are the same chrome.
    private func toolbarCapsule(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.fernlet(.label))
            .foregroundStyle(Color.bark)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.cream.opacity(0.9), in: Capsule())
            .overlay(Capsule().stroke(Color.bark.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// Plan (always) and Log (past/today only).
    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 8) {
                toolbarCapsule("Plan", systemImage: "calendar.badge.plus") {
                    editingPlannedWorkout = nil
                    showPlanSheet = true
                }
                if !isFuture {
                    toolbarCapsule("Log", systemImage: "plus") { showWorkoutSheet = true }
                }
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(title: navigationTitle, subtitle: Text(verbatim: headerSubtitle))
                planSection
                workoutsSection
            }
            .padding(20)
        }
        .background(Color.parchment)
        // The page draws its own ScreenHeader (matching the Move root), so the bar carries only
        // back + Plan/Log rather than repeating "Today" directly above the big one.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .sheet(isPresented: $showWorkoutSheet) {
            WorkoutSheet(store: store, dateKey: dateKey)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
                // The sheet no longer declares its own (the root router's `fernletSheetChrome` does
                // for the other presentation), so this presentation supplies it — the RPE and
                // Duration number pads have no return key of their own.
                .keyboardDoneToolbar()
        }
        .sheet(isPresented: $showPlanSheet) {
            WorkoutPlanSheet(
                store: store,
                dateKey: dateKey,
                showsPlanSourceTag: showsPlanSourceTag,
                editingPlan: editingPlannedWorkout
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
    }
}

/// A planned (not yet done) workout row: complete tap target, name/split/duration, a preview of the
/// plan's first steps, and edit/remove actions.
///
/// Shared by the Move root and ``MoveDayDetailView``; `showsCompleteAction` is false on future days,
/// and the coach/user source tag only renders when coach-sourced plans exist at all.
struct PlannedWorkoutRow: View {
    var plannedWorkout: PlannedWorkout
    var showsPlanSourceTag: Bool
    var showsCompleteAction: Bool
    var onComplete: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    /// Remove asks first — a mis-tap on a small text button used to erase a plan (possibly a
    /// coach-imported one) with no dialog and no undo, while the sibling logged row confirmed.
    /// Held here rather than at each call site so both the Move root and the day detail inherit it.
    @State private var pendingDestructiveAction: DestructiveConfirmation?

    private var stepLines: [String] {
        plannedWorkout.exercises
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The complete button, or the faded dot a future day shows in its place.
    @ViewBuilder private var leadingMarker: some View {
        if showsCompleteAction {
            Button(action: onComplete) {
                ZStack {
                    Circle()
                        .fill(plannedWorkout.workoutType.color.opacity(0.14))
                        .frame(width: 34, height: 34)
                    Circle()
                        .stroke(plannedWorkout.workoutType.color, lineWidth: 2)
                        .frame(width: 34, height: 34)
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(plannedWorkout.workoutType.color)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark \(plannedWorkout.name) complete")
        } else {
            Circle()
                .fill(plannedWorkout.workoutType.color.opacity(0.42))
                .frame(width: 18, height: 18)
                .padding(.top, 6)
        }
    }

    /// Name plus the split / source / duration line.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plannedWorkout.name)
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.bark)
            HStack(spacing: 8) {
                Text(plannedWorkout.split.title)
                if showsPlanSourceTag {
                    Text(plannedWorkout.source.title)
                }
                if let duration = plannedWorkout.duration {
                    Text("\(duration) min")
                }
            }
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.slate)
        }
    }

    /// The first few plan steps, and the plan note.
    @ViewBuilder private var stepPreview: some View {
        if !stepLines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(stepLines.prefix(4).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.bark.opacity(0.82))
                        .lineLimit(2)
                }
            }
        }

        if !plannedWorkout.notes.isEmpty {
            Text(plannedWorkout.notes)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
    }

    /// Edit / Remove.
    private var actionRow: some View {
        HStack(spacing: 10) {
            Button("Edit", action: onEdit)
                .font(.fernlet(.label))
                .foregroundStyle(Color.moss)
            Button("Remove", role: .destructive) { confirmRemove() }
                .font(.fernlet(.label))
                .foregroundStyle(Color.terracottaInk)
                .accessibilityIdentifier("workout.plan.remove")
        }
    }

    private func confirmRemove() {
        pendingDestructiveAction = DestructiveConfirmation(
            title: "Remove this plan?",
            message: "It won't be logged — you can plan it again any time.",
            confirmLabel: "Remove",
            auditEvent: "workout.plan.deleteConfirmed",
            perform: { onDelete() }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            leadingMarker

            VStack(alignment: .leading, spacing: 10) {
                titleBlock
                stepPreview
                actionRow
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .destructiveConfirmation($pendingDestructiveAction)
    }
}

/// The plan-ahead sheet: create or edit a `PlannedWorkout` for a given day — split, kind, exercise
/// rows or an activity, duration/targets, and notes.
///
/// Seeds from the plan being edited, else copies forward the most recent split, and offers a
/// one-tap "Copy previous week" for the matching weekday. Free-text plan steps and structured rows
/// stay in sync: row edits re-fold into the text, and `exerciseEntries(from:)` best-effort parses
/// text lines back into rows on open. Dirty tracking compares a field signature captured at init, so
/// an untouched sheet (blank or pre-seeded) can be swiped away without a discard prompt.
struct WorkoutPlanSheet: View {
    @Environment(\.dismiss) private var dismiss
    // Drives the nested Suggest sheet's detents: accessibility sizes open .large (1b·AX3).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var store: FernletStore
    var dateKey: String
    var showsPlanSourceTag: Bool
    var editingPlan: PlannedWorkout?
    @State private var split: WorkoutSplit
    @State private var name = ""
    @State private var exerciseRows: [WorkoutExerciseEntry] = []
    @State private var plannedExerciseText = ""
    /// The in-progress exercise row (see ``WorkoutExerciseDraft``) — shared with ``WorkoutSheet``.
    @State private var draft = WorkoutExerciseDraft()
    @State private var duration = ""
    @State private var distance = ""
    @State private var energyKcal = ""
    @State private var effort = ""
    @State private var notes = ""
    @State private var selectedActivityType: WorkoutActivityType?
    @State private var logMode: WorkoutMode
    @State private var showDiscardConfirm = false
    /// Presents ``WorkoutSuggestionSheet`` — the flow that used to sit behind the Move header's
    /// "Suggest" pill. It lives here now because asking for a workout belongs beside planning one.
    @State private var showingSuggestion = false
    private let previousWeekPlan: PlannedWorkout?
    /// A shallow snapshot of the seeded field values, so `isDirty` can tell an untouched sheet (whether
    /// blank-new or opened on an existing plan) from one the user has changed. Row edits fold into
    /// `plannedExerciseText`, so the string signature covers them without a deep row compare.
    private let initialSignature: String

    init(store: FernletStore, dateKey: String, showsPlanSourceTag: Bool, editingPlan: PlannedWorkout? = nil) {
        self.store = store
        self.dateKey = dateKey
        self.showsPlanSourceTag = showsPlanSourceTag
        self.editingPlan = editingPlan
        self.previousWeekPlan = store.previousWeekPlannedWorkout(for: dateKey)
        let copiedSplit = editingPlan?.split ?? store.copiedForwardWorkoutSplit(before: dateKey) ?? .fullBody
        let seedMode = editingPlan?.mode ?? (copiedSplit == .workout ? .activity : .strengthTraining)
        let seedName = editingPlan?.name ?? ""
        let seedPlanned = editingPlan?.exercises ?? ""
        let seedDuration = editingPlan?.duration.map(String.init) ?? ""
        let seedDistance = editingPlan?.targetDistanceMiles.map { String($0) } ?? ""
        let seedEnergy = editingPlan?.targetEnergyKcal.map { String($0) } ?? ""
        let seedEffort = editingPlan?.targetEffort.map(String.init) ?? ""
        let seedNotes = editingPlan?.notes ?? ""
        let seedActivity = editingPlan?.activityType
        _split = State(initialValue: copiedSplit)
        _logMode = State(initialValue: seedMode)
        _name = State(initialValue: seedName)
        _plannedExerciseText = State(initialValue: seedPlanned)
        _exerciseRows = State(initialValue: WorkoutSheetRules.exerciseEntries(from: seedPlanned))
        _duration = State(initialValue: seedDuration)
        _distance = State(initialValue: seedDistance)
        _energyKcal = State(initialValue: seedEnergy)
        _effort = State(initialValue: seedEffort)
        _notes = State(initialValue: seedNotes)
        _selectedActivityType = State(initialValue: seedActivity)
        self.initialSignature = Self.planSignature(
            name: seedName, planned: seedPlanned, duration: seedDuration, distance: seedDistance,
            energy: seedEnergy, effort: seedEffort, notes: seedNotes,
            activity: seedActivity, split: copiedSplit, mode: seedMode
        )
    }

    private static func planSignature(
        name: String, planned: String, duration: String, distance: String,
        energy: String, effort: String, notes: String,
        activity: WorkoutActivityType?, split: WorkoutSplit, mode: WorkoutMode
    ) -> String {
        "\(name)\u{1f}\(planned)\u{1f}\(duration)\u{1f}\(distance)\u{1f}\(energy)\u{1f}\(effort)\u{1f}\(notes)\u{1f}\(activity?.rawValue ?? "")\u{1f}\(split)\u{1f}\(mode)"
    }

    private var isDirty: Bool {
        if draft.hasExercise { return true }
        let current = Self.planSignature(
            name: name, planned: plannedExerciseText, duration: duration, distance: distance,
            energy: energyKcal, effort: effort, notes: notes,
            activity: selectedActivityType, split: split, mode: logMode
        )
        return current != initialSignature
    }

    private func attemptCancel() {
        if isDirty { showDiscardConfirm = true } else { dismiss() }
    }

    private var targetDateTitle: String {
        if dateKey == store.todayKey { return "Today" }
        let date = FernletDate.date(fromDayKey: dateKey) ?? .now
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var plannedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if logMode == .activity, let selectedActivityType {
            return selectedActivityType.displayName
        }
        // `rawValue`, not `title`: this string is PERSISTED as `PlannedWorkout.name`, and
        // `WorkoutExerciseCatalog.inferType`/`targetSummary` then match ENGLISH keywords against
        // it. A localized default name would have a plan created on a German device infer its own
        // type differently. The placeholder below is display-only and keeps the localized title.
        return "\(split.rawValue) workout"
    }

    /// The name field is optional — the placeholder shows the name the plan will actually take.
    private var plannedNamePlaceholder: String {
        if logMode == .activity {
            return selectedActivityType?.displayName ?? "Optional, e.g. Saturday ride"
        }
        return "\(split.title) workout"
    }

    private var exerciseText: String {
        if logMode == .activity {
            return selectedActivityType?.displayName ?? ""
        }
        return plannedExerciseText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var aggregatedMuscleGroups: Set<MuscleGroup> {
        WorkoutSheetRules.aggregatedMuscleGroups(from: exerciseRows)
    }

    private var plannedMuscleGroups: Set<MuscleGroup> {
        if exerciseRows.isEmpty {
            return editingPlan?.muscleGroups ?? []
        }
        return aggregatedMuscleGroups
    }

    /// Whether to offer the suggestion flow on this sheet.
    ///
    /// Gated to a NEW plan for TODAY, and both halves are load-bearing rather than tidiness:
    /// ``WorkoutSuggestionSheet`` is today-scoped by construction (it reads
    /// `currentGuidedWorkoutPlan`, `recommendedWorkoutIntensity`, and today's logged guided names),
    /// so offering it while planning next Tuesday would generate and commit a plan for the wrong
    /// day — silently. And offering it mid-edit of an existing plan invites a suggestion that has no
    /// relationship to the row being edited.
    private var showsSuggestEntry: Bool {
        editingPlan == nil && dateKey == store.todayKey
    }

    /// Title, target day, and the "User plan" tag when coach-sourced plans exist.
    private var planHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(editingPlan == nil ? "Plan workout" : "Edit plan")
                .font(.fernlet(.displayMedium))
                .foregroundStyle(Color.bark)
            Text(targetDateTitle)
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
            if showsPlanSourceTag {
                Text("User plan")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.moss)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.moss.opacity(0.12), in: Capsule())
            }
        }
    }

    /// The shared chrome behind "Copy previous week" and "Suggest a workout".
    private func entryCard(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.moss)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                    Text(subtitle)
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(12)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// The split chip row — strength only.
    ///
    /// The "Workout" chip is deliberately absent: it duplicated the Kind row (picking it flipped Kind,
    /// and picking Kind flipped it back), so two controls mirrored one piece of state. Split is now
    /// only asked for when it means something, which is a strength plan.
    private var splitField: some View {
        SheetField("Split") {
            FlowLayout(spacing: 8) {
                ForEach(strengthSplits) { option in
                    Button(option.title) { split = option }
                        .buttonStyle(ChipButtonStyle(selected: split == option))
                }
            }
        }
    }

    private var strengthSplits: [WorkoutSplit] {
        WorkoutSplit.allCases.filter { $0 != .workout }
    }

    /// The strength / activity chip row, kept consistent with the chosen split.
    private var kindField: some View {
        SheetField("Kind") {
            FlowLayout(spacing: 8) {
                ForEach(WorkoutMode.allCases) { mode in
                    Button(mode.label) {
                        logMode = mode
                        if mode == .activity {
                            split = .workout
                        } else if split == .workout {
                            split = .fullBody
                        }
                    }
                        .buttonStyle(ChipButtonStyle(selected: logMode == mode))
                }
            }
        }
    }

    /// Exercise builder, the editable planned rows, and the free-text plan steps they stay in sync with.
    @ViewBuilder private var strengthPlanFields: some View {
        WorkoutExerciseBuilder(
            selectedExercise: $draft.exercise,
            sets: $draft.sets,
            reps: $draft.reps,
            weight: $draft.weight,
            speed: $draft.speed,
            incline: $draft.incline,
            details: $draft.details,
            resetToken: $draft.resetToken,
            pickerTitle: logMode.pickerTitle,
            searchPlaceholder: logMode.searchPlaceholder,
            mode: logMode,
            addLabel: logMode.addLabel,
            historyStore: store,
            onAdd: addDraftExercise
        )

        if !exerciseRows.isEmpty {
            SheetField("Planned exercises") {
                VStack(spacing: 8) {
                    ForEach($exerciseRows) { $entry in
                        EditablePlannedExerciseRow(entry: $entry) {
                            exerciseRows.removeAll { $0.id == entry.id }
                            plannedExerciseText = exerciseRows.map(\.summary).joined(separator: "\n")
                        } onChange: {
                            plannedExerciseText = exerciseRows.map(\.summary).joined(separator: "\n")
                        }
                    }
                }
            }
        }

        // The two free-text fields used to invite the same content ("exercises, cues") while only
        // this one parses into rows. The placeholders now say which is which.
        SheetField("Plan steps") {
            SheetTextEditor(
                text: $plannedExerciseText,
                placeholder: "One exercise per line, e.g. Squat 3x8 @60",
                minHeight: 100
            )
        }
    }

    /// The activity fields, for a non-strength plan.
    private var activityFields: some View {
        ActivityPickerSection(
            selectedActivityType: $selectedActivityType,
            duration: $duration,
            distance: $distance,
            energyKcal: $energyKcal,
            effort: $effort,
            showsEnergyField: store.settings.showCalories
        )
    }

    /// The free-text plan note.
    private var notesField: some View {
        SheetField("Plan notes") {
            SheetTextEditor(
                text: $notes,
                placeholder: "Anything to remember on the day (pace, warm-up, how you felt)",
                minHeight: 120
            )
        }
    }

    /// The scrolling form, in order.
    private var planForm: some View {
        VStack(alignment: .leading, spacing: 22) {
            planHeader

            if let previousWeekPlan {
                entryCard(icon: "arrow.turn.down.right",
                          title: "Copy previous week",
                          subtitle: previousWeekPlan.name) {
                    copyPreviousWeekPlan(previousWeekPlan)
                }
            }

            if showsSuggestEntry {
                entryCard(icon: "wand.and.stars",
                          title: "Suggest a workout",
                          subtitle: "Built from your split, equipment, and limits") {
                    showingSuggestion = true
                }
                .accessibilityIdentifier("plan.suggest")
            }

            // Kind first, then Split — Split only qualifies a strength plan.
            kindField
            if logMode == .strengthTraining {
                splitField
            }

            SheetField("Workout") {
                TextField(plannedNamePlaceholder, text: $name)
                    .sheetTextInput()
            }

            if logMode == .strengthTraining {
                strengthPlanFields
            } else {
                activityFields
            }

            if logMode == .strengthTraining {
                SheetField("Duration (min)") {
                    TextField("45", text: $duration)
                        .keyboardType(.numberPad)
                        .sheetTextInput(font: .fernlet(.label))
                }
            }

            notesField
        }
        .padding(20)
        .padding(.bottom, 10)
    }

    /// Writes the planned workout for `dateKey`, folding in a typed-but-unadded draft first.
    private func savePlan() {
        // Fold a typed-but-not-yet-added exercise draft into the plan so Save doesn't drop it.
        if logMode == .strengthTraining, draft.hasExercise {
            addDraftExercise()
        }
        store.planWorkout(
            PlannedWorkout(
                id: editingPlan?.id ?? UUID(),
                name: plannedName,
                split: split,
                source: editingPlan?.source ?? .user,
                mode: logMode,
                activityType: selectedActivityType,
                exercises: exerciseText,
                muscleGroups: plannedMuscleGroups,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                duration: LocaleTolerantNumber.int(from: duration),
                targetDistanceMiles: LocaleTolerantNumber.double(from: distance),
                targetEnergyKcal: LocaleTolerantNumber.double(from: energyKcal),
                targetEffort: LocaleTolerantNumber.int(from: effort),
                createdAt: editingPlan?.createdAt ?? Date()
            ),
            date: dateKey
        )
        dismiss()
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetCancelBar { attemptCancel() }
            ScrollView {
                planForm
            }

            SheetSaveBar(label: editingPlan == nil ? "Save plan" : "Update plan") { savePlan() }
        }
        .background(Color.parchment)
        .keyboardDoneToolbar()
        .interactiveDismissDisabled(isDirty)
        .discardConfirmation(isPresented: $showDiscardConfirm) { dismiss() }
        .sheet(isPresented: $showingSuggestion) {
            // Presented from THIS sheet rather than routed through the tab's `activeSheet` slot:
            // that route would have to dismiss the plan sheet first, throwing away a part-filled
            // plan. The suggestion flow commits its own plan and closes itself, so on return the
            // user is back on the plan they were writing. Accessibility sizes open .large — grow
            // the sheet, never hide a control (1b·AX3).
            WorkoutSuggestionSheet(store: store)
                .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
        .onChange(of: logMode) { _, _ in
            draft.clear()
        }
    }

    /// Folds the current draft into the planned rows AND back into the free-text plan.
    ///
    /// Unlike ``WorkoutSheet``, this sheet keeps a free-text "Plan steps" field in sync with the
    /// structured rows, so the commit is followed by a re-fold of the new row's summary into that text
    /// — the one thing the two sheets genuinely do differently, and the reason `commit` reports whether
    /// it appended anything (the fold must not run for an empty draft).
    ///
    /// Sets/reps are kept unconditionally (`includingSetsAndReps` defaults to `true`), matching this
    /// sheet's original behaviour; the log sheet blanks them outside strength mode.
    private func addDraftExercise() {
        guard draft.commit(into: &exerciseRows) else { return }
        plannedExerciseText = (plannedExerciseText.components(separatedBy: .newlines) + [exerciseRows.last?.summary ?? ""])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func copyPreviousWeekPlan(_ plan: PlannedWorkout) {
        split = plan.split
        logMode = plan.mode
        name = plan.name
        plannedExerciseText = plan.exercises
        exerciseRows = WorkoutSheetRules.exerciseEntries(from: plan.exercises)
        duration = plan.duration.map(String.init) ?? ""
        notes = plan.notes
        selectedActivityType = plan.activityType
    }
}

/// A compact read-only summary row for a saved `FitnessGoal` (goal, timeframe/metric, milestones).
///
/// Rendered in the goals sheet's list (SharedSheets); editing happens there, not on the row.
struct GoalRow: View {
    var goal: FitnessGoal

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(goal.goal).font(.fernlet(.headerMedium))
            Text("\(goal.timeframe) - \(goal.metric)")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
            if !goal.milestones.isEmpty {
                Text(goal.milestones.joined(separator: " - "))
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.moss)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.parchment, in: RoundedRectangle(cornerRadius: 10))
    }
}
