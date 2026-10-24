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
/// ``MoveRoute`` for the parameterless screens (``ExerciseHistoryView``, ``WeeklyTotalsView``).
struct MoveView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    @Binding var trainerExportLaunchAction: TrainerExportLaunchAction?
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int
    @State private var path = NavigationPath()
    /// The root page's own scroll-to-top token; `tabReselect` bumps it only when nothing is pushed.
    @State private var scrollToTopToken = 0
    @State private var displayedWeek: Date = .now
    @State private var allDays: [String: FernletDay] = [:]
    /// The outer tab host retains this view. Hydrate its repository/index snapshots once instead of
    /// rebuilding them on every tab-selection `onAppear`; mutation paths refresh them explicitly.
    @State private var didLoadInitialSnapshots = false
    @State private var showingLocations = false
    // The trainer / coach handoff screen. It lives here rather than in Settings → Privacy & Data
    // because it is now two-way — a plan comes back through it — and a plan belongs next to the
    // plans, not next to the data-export controls.
    @State private var showingTrainerShare = false
    /// Captured before clearing the root handoff so the presented trainer view receives one stable
    /// action for its lifetime.
    @State private var presentedTrainerAction: TrainerExportLaunchAction?
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
    /// The World build's framed look (`b2-move-root`); nil draws today's Move tab.
    @Environment(\.fernletFramedLook) private var look

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

    private func loadInitialSnapshotsIfNeeded() {
        guard !didLoadInitialSnapshots else { return }
        didLoadInitialSnapshots = true
        refreshAllDays()
        progressPhotos = store.progressPhotoRecords()
    }

    /// Static so it is testable: a private view computed cannot be (the `AwayHeartsCopy`
    /// precedent).
    static func hasCoachSourcedPlans(in days: [String: FernletDay], today: FernletDay) -> Bool {
        if today.plannedWorkouts.contains(where: { $0.source == .coach }) { return true }
        return days.values.contains { day in
            day.plannedWorkouts.contains { $0.source == .coach }
        }
    }

    /// The tab header: title plus the Log and Share actions.
    ///
    /// The action pills sit in an ``AdaptiveStack`` so they stack into a column at accessibility text
    /// sizes rather than squeezing side by side (where "Share" broke to "Shar/e").
    @ViewBuilder private var headerRow: some View {
        if look != nil {
            framedHeaderRow
        } else {
            HStack(alignment: .top) {
                ScreenHeader(title: "Move", subtitle: "Enough to feel it, not enough to drain.", identifier: "screen.move")
                Spacer(minLength: 8)
                AdaptiveStack(spacing: 10, horizontalAlignment: .trailing, verticalAlignment: .top) {
                    HeaderActionButton(title: "Log") { activeSheet = .workout }
                    // Suggest moved into ``WorkoutPlanSheet`` — asking for a workout belongs
                    // beside planning one, not in the tab header. The header slot it freed
                    // goes to the trainer/coach handoff, which is the tab's other top-level
                    // action and previously sat in a card halfway down the scroll.
                    HeaderActionButton(title: "Share", action: openTrainerShare)
                        .modifier(MoveShareAccessibility())
                }
            }
            .padding(.top, 4)
        }
    }

    /// World build (`b2-move-root`): the plate names the panel, so the page opens on its one-line
    /// description, then Log and Share as two framed buttons side by side (stacked at accessibility sizes).
    private var framedHeaderRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "Move", subtitle: "Enough to feel it, not enough to drain.", identifier: "screen.move")
            AdaptiveStack(spacing: 10, horizontalAlignment: .leading) {
                MoveIconButton(title: Text("Log"), sprite: WorldSprites.plus) { activeSheet = .workout }
                    .accessibilityIdentifier("move.log")
                MoveIconButton(title: Text("Share"), sprite: WorldSprites.box, action: openTrainerShare)
                    .modifier(MoveShareAccessibility())
            }
        }
    }

    /// Share opens the trainer / coach handoff with no Shortcut action waiting.
    private func openTrainerShare() {
        presentedTrainerAction = nil
        showingTrainerShare = true
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
            ResumeWorkoutCard(title: WorkoutSessionNames.drawn(activeRun.title), isResting: activeRun.isResting) {
                if let session = store.guidedSessionForResume() { guidedSession = session }
            }
        } else if let guidedCardState {
            StartTodaysWorkoutCard(
                state: guidedCardState,
                loggedSessionName: loggedGuidedSessionName,
                isRestDay: store.needsRestToday,
                readyIsTimed: guidedReadyIsTimed,
                onStart: startTodaysGuidedWorkout
            )
        } else {
            StartTodaysWorkoutCard(
                state: .noPlan,
                loggedSessionName: nil,
                isRestDay: store.needsRestToday,
                onStart: { showingSuggestSheet = true }
            )
        }
    }

    /// Whether the session the card would start is timed cardio or stretching rather than sets — the
    /// card then says it times each part instead of promising "set by set".
    private var guidedReadyIsTimed: Bool {
        guard case .ready(let id) = guidedCardState,
              let session = store.currentGuidedWorkoutPlan?.sessions.first(where: { $0.id == id }) else { return false }
        return !session.exercises.contains { $0.fromCatalog && $0.sets >= 1 }
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
        }?.displayedName
    }

    /// Today's planned row's Start: opens the guided runner — its Ready screen lists the plan as written,
    /// or, when this plan's run is already under way, the run itself. Nil (no Start) for a plan with
    /// nothing the runner can walk.
    private func startAction(for planned: PlannedWorkout) -> (() -> Void)? {
        guard PlannedWorkoutRun.canGuide(planned) else { return nil }
        return {
            guard let session = store.guidedSession(forPlanned: planned, date: store.todayKey) else {
                FernletAuditLog.log("workout.plannedRun.notGuidable")
                return
            }
            guidedSession = session
        }
    }

    /// Today's planned rows then today's logged rows, divided.
    private var todaysMovementSection: some View {
        MoveCardList(header: Text("Today's movement")) {
            if store.day.plannedWorkouts.isEmpty && store.day.workouts.isEmpty {
                EmptyState(text: "No workouts today. No rush.")
            } else {
                ForEach(store.day.plannedWorkouts) { plannedWorkout in
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
                        },
                        onStart: startAction(for: plannedWorkout)
                    )
                }
                ForEach(store.day.workouts) { workout in
                    WorkoutRow(
                        store: store,
                        workout: workout,
                        date: store.todayKey,
                        onChanged: { refreshAllDays() }
                    )
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
                finishProgressPhoto(sealed: store.addProgressPhoto(image) != nil)
            },
            onCaptureData: { data, capturedAt in
                // Library pick: seal the raw bytes (bounded ImageIO decode) and stamp the
                // photo's own date when EXIF carried one (clamped to now at the EXIF read —
                // a wrong camera clock must not outrun the editor's today cap), else now.
                finishProgressPhoto(sealed: store.addProgressPhoto(data: data, capturedAt: capturedAt ?? Date()) != nil)
            },
            onCaptureFailed: { finishProgressPhoto(sealed: false) },
            onOpen: { record in path.append(record) }
        )
    }

    /// Lands one progress-photo attempt: the timeline re-reads, and the outcome is felt (B15) — `done`
    /// as a sealed photo joins the timeline, `failed` beside the "Couldn't save this photo" alert, so
    /// a photo that couldn't be sealed never vanishes silently.
    private func finishProgressPhoto(sealed: Bool) {
        FernletFeedback.system.play(sealed ? .done : .failed)
        if !sealed { showPhotoSaveFailedAlert = true }
        progressPhotos = store.progressPhotoRecords()
    }
    #endif

    /// The quiet "Exercise history" link under the week strip — the factual per-exercise recall
    /// list (``ExerciseHistoryView``). The same row chrome as the plan sheet's "Equipment & limits"
    /// entry, so a navigation row reads the same everywhere in Move.
    @ViewBuilder private var exerciseHistoryLink: some View {
        if look != nil {
            MoveLinkCard(title: Text("Exercise history"), sprite: WorldSprites.chart, identifier: "move.exerciseHistory") {
                path.append(MoveRoute.exerciseHistory)
            }
        } else {
            plainExerciseHistoryLink
        }
    }

    /// Today's quiet link row, outside the World look.
    private var plainExerciseHistoryLink: some View {
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
        VStack(alignment: .leading, spacing: look == nil ? 16 : 18) {
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

            WeeklyTotalsLink { path.append(MoveRoute.weeklyTotals) }

            todaysMovementSection

            #if canImport(UIKit)
            progressPhotoSection
            #endif
        }
        .padding(20)
    }

    /// The guided runner for `session`, with the "other sessions remain" copy resolved. World build
    /// (`b3-runner-*`): a focused flow, presented full screen with no grabber (the ✕ ends it).
    private func guidedRunnerSheet(_ session: WorkoutProgram.SessionSuggestion) -> some View {
        GuidedWorkoutSheet(store: store, session: session, sessionsRemain: otherSessionsRemain(after: session))
    }

    /// Whether other sessions of today's committed plan still need doing after `session` — the runner's
    /// done copy then names what was logged. Never for a planned workout's run, which is not one of the
    /// plan's sessions.
    private func otherSessionsRemain(after session: WorkoutProgram.SessionSuggestion) -> Bool {
        guard !store.isPlannedRun(session), let plan = store.currentGuidedWorkoutPlan else { return false }
        // Route through the reconciliation seam (not an id-only check) so the done copy stays
        // truthful after a relaunch, when the completed-id set is empty but the day record
        // (by tagged name) still knows what's been guided.
        return plan.sessions.contains {
            $0.id != session.id && !GuidedWorkoutAvailability.isAlreadyLogged(
                $0, completed: store.guidedCompletedSessionIDs,
                loggedGuidedWorkoutNames: store.loggedGuidedWorkoutNamesToday
            )
        }
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
        case .weeklyTotals:
            WeeklyTotalsView(store: store)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                scrollContent
                    .fernletTabBarBottomClearance()
            }
            .fernletTabBarCompaction($isTabBarCompact, resetToken: $scrollToTopToken)
            // World build: the dotted page under the panel's plate (plain parchment without the look).
            .fernletPageBackground()
            .navigationTitle("")
            .navigationDestination(for: String.self) { dayDetail($0) }
            .navigationDestination(for: MoveRoute.self) { routedScreen($0) }
            #if canImport(UIKit)
            .navigationDestination(for: ProgressPhotoRecord.self) { photoDetail($0) }
            #endif
        }
        // Re-tapping Move pops a pushed day, photo or history page; at the root it scrolls up.
        .tabReselect(token: $tabResetToken, scrollToTopToken: $scrollToTopToken, isAtRoot: { path.isEmpty }) {
            path = NavigationPath()
        }
        .onAppear {
            loadInitialSnapshotsIfNeeded()
            store.reconcileGuidedRunFromAppGroup()
            openRequestedTrainerExportIfNeeded()
        }
        .alert("Couldn't save this photo", isPresented: $showPhotoSaveFailedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Fernlet couldn't seal this photo to your private timeline. Please try again.")
        }
        .sheet(isPresented: $showingLocations) {
            WorkoutLocationSetupView(store: store)
                .fernletSheet()
        }
        .sheet(isPresented: $showingTrainerShare, onDismiss: {
            // An imported plan writes planned workouts straight into day records, which the
            // calendar and "Today's movement" read from the `allDays` snapshot — refresh or the
            // new days stay invisible until some other mutation happens to bump it.
            refreshAllDays()
            presentedTrainerAction = nil
            openRequestedTrainerExportIfNeeded()
        }) {
            TrainerExportView(store: store, initialAction: presentedTrainerAction)
                .fernletSheet()
        }
        .fullScreenCover(item: $guidedSession) { session in
            guidedRunnerSheet(session)
        }
        .sheet(isPresented: $showingSuggestSheet) {
            // The root-card empty state's Suggest entry (FLOW-03), presented locally the way the
            // plan sheet presents it. World build: full height in the sheet frame, like every sheet.
            WorkoutSuggestionSheet(store: store)
                .fernletSheet()
        }
        .onChange(of: store.day.workouts.count) { refreshAllDays() }
        .onChange(of: store.day.plannedWorkouts.count) { refreshAllDays() }
        .onChange(of: trainerExportLaunchAction?.rawValue) { openRequestedTrainerExportIfNeeded() }
        .onChange(of: scenePhase) { _, phase in handleSceneActive(phase) }
    }

    /// Consumes a root Shortcut handoff only when this view can present it. A request arriving while
    /// Share is already open remains pending and is picked up by that sheet's on-dismiss path.
    private func openRequestedTrainerExportIfNeeded() {
        guard !showingTrainerShare, let action = trainerExportLaunchAction else { return }
        trainerExportLaunchAction = nil
        presentedTrainerAction = action
        showingTrainerShare = true
    }
}

/// The guidable filter, in one place so the Move-root card and the Suggest sheet agree (reused, not
/// reimplemented).
///
/// A session is worth *guiding* through when it carries real, set-based catalog work, or a cardio or
/// mobility line the runner can time (``WorkoutTimedSessions``: steady and interval cardio, a mobility
/// flow). A line it cannot time stays a descriptor (`sets == 0`) and its session unguided, and the rest
/// day's gentle stretch is never the day's session — only an optional extra
/// (``optionalStretch(in:excluding:loggedGuidedWorkoutNames:)``). ``MoveView``,
/// ``WorkoutSuggestionSheet``, and ``GuidedWorkoutCardState`` all route their already-logged checks
/// through these predicates, which is the invariant that keeps a session finished from one entry
/// point excluded everywhere — including after a relaunch, when session ids are fresh but the tagged
/// name in the day record survives.
enum GuidedWorkoutAvailability {
    /// A session with real, set-based catalog exercises, or a cardio or mobility line the runner can
    /// time as countdowns.
    nonisolated static func isGuidable(_ session: WorkoutProgram.SessionSuggestion) -> Bool {
        session.exercises.contains { ($0.fromCatalog && $0.sets >= 1) || WorkoutTimedSessions.isGuidable($0) }
    }

    /// The rest day's gentle stretch, while it is still to do — offered as a quiet extra on the Suggest
    /// sheet, never as today's workout: the day's readiness says rest, and rest stays the plan.
    nonisolated static func optionalStretch(
        in plan: WorkoutProgram.DayPlan,
        excluding completed: Set<UUID>,
        loggedGuidedWorkoutNames: Set<String> = []
    ) -> WorkoutProgram.SessionSuggestion? {
        plan.sessions.first { session in
            !isGuidable(session) && session.exercises.contains(where: WorkoutTimedSessions.isOptionalStretch)
                && !isAlreadyLogged(session, completed: completed, loggedGuidedWorkoutNames: loggedGuidedWorkoutNames)
        }
    }

    /// A session is already accounted for when its id is in the in-memory completed set OR today's
    /// GUIDED-logged workouts already carry its `suggestion.name`. The name check is the reconciliation
    /// seam: a routine relaunch mints the plan with fresh session ids and starts the completed set empty,
    /// but the guided log (written with `suggestion.name` and tagged `loggedFromGuidedSession`) survives
    /// in `day.workouts` — so matching on that name keeps an already-logged guided session from being
    /// offered, and re-logged, again. Only tagged names are passed in, so a manual or planned "Legs"
    /// never counts — nor does a guided run of a planned "Legs" (``Workout/isPlanRun``), which the
    /// store matches by its plan's id and leaves out of the names.
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
                ? String(localized: "move.guided.noneToGuide.easyMovement",
                         defaultValue: "Today's about easy movement — no guided sets, but anything you do still counts.",
                         comment: "Move tab, today's workout card on a day with only easy movement planned")
                : String(localized: "move.guided.noneToGuide.rest",
                         defaultValue: "Rest day. Nothing to push — let your body settle.",
                         comment: "Move tab, today's workout card on a rest day"))
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
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: look == nil ? .center : .top, spacing: 12) {
                    Group {
                        if look != nil {
                            FernletIconTile(size: 44) { WorldSpriteView(sprite: WorldSprites.shoe, scale: 3) }
                        } else {
                            Image(systemName: "figure.strengthtraining.traditional")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Color.moss)
                                .frame(width: 30)
                        }
                    }
                    // Decorative, as on `StartTodaysWorkoutCard`: the header names the card.
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Workout in progress")
                            .font(look == nil ? .fernlet(.headerMedium) : FernletFramedFont.cardTitle)
                            .foregroundStyle(look?.text ?? Color.bark)
                            .accessibilityAddTraits(.isHeader)
                        Text(isResting ? "\(title) — you're resting between sets." : "\(title) — pick up where you left off.")
                            .font(look == nil ? .fernlet(.bubble) : FernletFramedFont.body)
                            .foregroundStyle(look?.dim ?? Color.slate)
                            .fernletWrappingText()
                    }
                    Spacer(minLength: 0)
                }

                resumeButton
            }
        }
    }

    /// Resume: the framed primary under the World look, today's moss bar without it.
    @ViewBuilder private var resumeButton: some View {
        if look != nil {
            Button(action: onResume) { Text("Resume workout").frame(maxWidth: .infinity) }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .accessibilityIdentifier("workout.resume")
        } else {
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

/// The Move tab's rest-day copy, in one place so a test can hold all of it to "never push".
///
/// A rest day is today's readiness reading `"needs rest"` — the user marked today unwell (spec §6a).
/// Every line here replaces a line that suggested an intensity or a workout; none may name one.
/// `LocalizedStringResource` literals, so each extracts into the app catalog like a `Text("…")`.
enum MoveRestDayCopy {
    /// The root card's empty state on a rest day.
    static let cardNoPlan: LocalizedStringResource = "You marked yourself unwell, so rest is today's plan. If moving would feel good, I can suggest something gentle."
    /// ``cardNoPlan`` at accessibility sizes, where the body line shortens (1a·AX3).
    static let cardNoPlanShort: LocalizedStringResource = "Resting today."
    /// The root card over a plan the user approved before marking today unwell.
    static let cardApprovedPlan: LocalizedStringResource = "You marked yourself unwell — this can wait for another day. Rest counts too."
    /// The root card's empty-state button on a rest day.
    static let suggestGentle: LocalizedStringResource = "Suggest something gentle"
    /// ``suggestGentle`` at accessibility sizes.
    static let suggestGentleShort: LocalizedStringResource = "Something gentle"
    /// The Suggest sheet's readiness line on a rest day, in place of "Today's readiness suggests …".
    static let suggestSheetLine: LocalizedStringResource = "You marked yourself unwell, so today is for rest. If moving would feel good, keep it gentle — or skip it entirely."

    /// Every line above, for the "never push" test.
    static let all: [LocalizedStringResource] = [
        cardNoPlan, cardNoPlanShort, cardApprovedPlan, suggestGentle, suggestGentleShort, suggestSheetLine
    ]
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
    /// Today's readiness is `"needs rest"` — the user marked today unwell (spec §6a). The card then
    /// never pushes: the empty state offers "something gentle" instead of today's workout, and an
    /// already-approved plan is framed as something that can wait. Geometry and actions are
    /// unchanged; only the words soften, so the choice stays the user's.
    var isRestDay: Bool = false
    /// The `.ready` session is timed cardio or stretching, not sets: its line says the parts are timed.
    var readyIsTimed: Bool = false
    /// Opens the runner (`.ready`) or the Suggest flow (`.noPlan`) — the parent decides.
    var onStart: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: look == nil ? .center : .top, spacing: 12) {
                    cardIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Today's workout")
                            .font(look == nil ? .fernlet(.headerMedium) : FernletFramedFont.cardTitle)
                            .foregroundStyle(look?.text ?? Color.bark)
                            // The guided workout's way in, findable from the Headings rotor.
                            .accessibilityAddTraits(.isHeader)
                        subtitle
                            .font(look == nil ? .fernlet(.bubble) : FernletFramedFont.body)
                            .foregroundStyle(look?.dim ?? Color.slate)
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

    /// The card's icon: World build, a pixel shoe (a tick when done, a leaf for a gentle day) in a framed
    /// tile (`b2-move-root`); today, the symbol. Decorative either way: the header beside it names the
    /// card. Left visible, the audit heard the symbol's name read aloud ("Label not human-readable").
    @ViewBuilder private var cardIcon: some View {
        if look != nil {
            FernletIconTile(size: 44) { WorldSpriteView(sprite: iconSprite, scale: 3) }
                .accessibilityHidden(true)
        } else {
            Image(systemName: iconName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 30)
                .accessibilityHidden(true)
        }
    }

    /// The pixel twin of ``iconName``.
    private var iconSprite: WorldSprite {
        switch state {
        case .ready, .noPlan: WorldSprites.shoe
        case .allComplete: WorldSprites.check
        case .noneToGuide: WorldSprites.leaf
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
    @ViewBuilder private var primaryButton: some View {
        if look != nil {
            // World build: the framed primary, full width, the word alone (`b2-move-root`).
            Button(action: onStart) { primaryLabel.frame(maxWidth: .infinity) }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .accessibilityIdentifier(state == .noPlan ? "workout.suggestToday" : "workout.startToday")
        } else {
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
    }

    /// 1a·AX3: labels shorten at accessibility sizes so they hold one line in the button.
    private var primaryLabel: Text {
        if case .noPlan = state, isRestDay {
            return dynamicTypeSize.isAccessibilitySize
                ? Text(MoveRestDayCopy.suggestGentleShort)
                : Text(MoveRestDayCopy.suggestGentle)
        }
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
        case .ready where isRestDay:
            return Text(MoveRestDayCopy.cardApprovedPlan)
        case .ready where readyIsTimed:
            return Text("Ready when you are — I'll time each part and move you on. No pressure.")
        case .ready:
            return Text("Ready when you are — I'll walk you through it, set by set, and time the rests. No pressure.")
        case .noPlan where isRestDay:
            return dynamicTypeSize.isAccessibilitySize
                ? Text(MoveRestDayCopy.cardNoPlanShort)
                : Text(MoveRestDayCopy.cardNoPlan)
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
    /// The row the name field was last prefilled from by "Log again". The field draws its
    /// `displayedName`; ``typedName`` hands the stored name back while that text is untouched.
    @State private var prefilledFrom: Workout?
    /// "Log set by set" (idea 6): the picked lift takes one row per set instead of the Sets / Reps /
    /// Weight fields, and saves the same structured record a guided run does. Off by default, so the
    /// free-text entry works exactly as before.
    /// World build (`b3-workout-exercise`): on by default, as the approved page draws a lift's sets row
    /// by row; the switch still offers the quick Sets / Reps / Weight line.
    @State private var logsBySet = true
    /// The picked lift's set rows while ``logsBySet`` is on; rebuilt whenever the pick changes.
    @State private var setsDraft: ExerciseSetsDraft?
    /// The sheet's stack (`b3-workout-log` draft 2): empty on the list, `.lift` while one exercise's
    /// own page is open. Leaving that page with Back drops what it held.
    @State private var liftPath: [WorkoutLiftRoute] = []
    /// The listed row the open page is changing, or nil while it adds a new exercise.
    @State private var editingRowID: UUID?
    /// "Last time" for the open page's exercise, read once per pick.
    @State private var liftLastTime: String?
    @Environment(\.fernletFramedLook) private var look

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
        return WorkoutExerciseCatalog.inferredCategory(for: "\(typedName)\n\(exerciseText)")
    }

    private var exerciseText: String {
        exerciseRows.map(\.summary).joined(separator: "\n")
    }

    /// The name field's text as it will be SAVED and keyword-matched. A "Log again" prefill left as
    /// drawn is the source row's stored name, not its translation (`Workout.savedName(editing:)`), so
    /// on a translated device the logged copy keeps the English default and files under the same
    /// category.
    private var typedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return prefilledFrom?.savedName(editing: trimmed) ?? trimmed
    }

    private var aggregatedMuscleGroups: Set<MuscleGroup> {
        WorkoutSheetRules.aggregatedMuscleGroups(from: exerciseRows)
    }

    private var targetDateKey: String {
        dateKey ?? store.todayKey
    }

    /// The pinned draft-guard title: at AX5 it truncates to one word — "the title truncates to
    /// 'Log'" (3b·AX5).
    private var logSheetTitle: Text {
        dynamicTypeSize >= .accessibility5 ? Text("Log") : Text("Log workout")
    }

    /// Strength or Cardio & activity (`b3-workout-log` draft 2: "a framed two-way switch"). It stacks at
    /// accessibility sizes; without the World look it is the system segmented control.
    private var kindField: some View {
        FernletSegmentedPicker("Kind", selection: $logMode, options: WorkoutMode.allCases) { kindChipLabel($0) }
            .accessibilityIdentifier("workout.kind")
    }

    /// 1f·AX3: at accessibility sizes "Cardio & activity" would wrap inside its own pill, so the
    /// chips shorten to "Strength" / "Cardio"; default sizes keep the full mode labels.
    private func kindChipLabel(_ mode: WorkoutMode) -> Text {
        guard dynamicTypeSize.isAccessibilitySize else {
            // World build (`b3-workout-log`): "Strength" beside "Cardio & activity" in the segmented bar.
            return look != nil && mode == .strengthTraining ? Text("Strength") : Text(verbatim: mode.label)
        }
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
            TextField(namePlaceholder, text: $name, prompt: .fieldPrompt(verbatim: namePlaceholder))
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
        if !recentEntries.isEmpty, look != nil {
            // World build (`b3-workout-log` draft 2): full rows with a framed +, so nothing is cut off;
            // + adds the lift straight to the list with last time's sets.
            FernletCard {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("Recent").padding(.bottom, 4)
                    ForEach(recentEntries, id: \.name) { entry in
                        if entry.name != recentEntries.first?.name { FernletDottedRule() }
                        MoveRecentLiftRow(name: ExerciseHowToCatalog.displayName(for: entry.name),
                                          recall: entry.lastTimeRecallValues,
                                          identifier: "workout.recentExercise.\(entry.name)") { addRecent(entry) }
                    }
                }
            }
        } else if !recentEntries.isEmpty {
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

    /// A Recent row's +: the lift joins the list with last time's sets, weight and unit, as one line.
    private func addRecent(_ entry: TrainerExportBundle.ExerciseHistoryEntry) {
        prefillDraft(from: entry)
        guard draft.commit(into: &exerciseRows, includingSetsAndReps: true) else { return }
        setsDraft = nil
        FernletFeedback.system.play(.done)
    }

    /// One 44pt Recent chip: name over the factual last-time values. At accessibility sizes the
    /// chip drops its sets×reps line and keeps the name alone (3b·AX3).
    ///
    /// **T2-2 convention.** The dropped recall line is real content — it is the whole reason to
    /// tap the chip rather than search — and a view that is never *drawn* never enters the
    /// accessibility tree, so at accessibility sizes VoiceOver lost it too. It is re-attached with
    /// `.accessibilityCustomContent`, which puts it on the More Content rotor, at EVERY size:
    /// default-importance custom content is never part of the spoken utterance, so it cannot
    /// double up with the drawn line, and an unbranched modifier cannot drift out of step with the
    /// layout branch it mirrors. The `Text?` overload takes the nil case (no recall recorded)
    /// without an empty rotor row, which is why the key is spelled out.
    private func recentChip(_ entry: TrainerExportBundle.ExerciseHistoryEntry) -> some View {
        Button {
            prefillDraft(from: entry)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                // Drawn through the display lookup; the chip still prefills by the logged name.
                Text(verbatim: ExerciseHowToCatalog.displayName(for: entry.name))
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                if let recall = entry.lastTimeRecallValues, !dynamicTypeSize.isAccessibilitySize {
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
        // Voice Control: the chip's name carries last time's sets ("Rows, 3x10"); its exercise is
        // what a user says.
        .accessibilityInputLabels([Text(verbatim: ExerciseHowToCatalog.displayName(for: entry.name))])
        .accessibilityIdentifier("workout.recentExercise.\(entry.name)")
        .accessibilityCustomContent(AccessibilityCustomContentKey("Last time"),
                                    entry.lastTimeRecallValues.map { Text(verbatim: $0) })
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
        prefilledFrom = workout
        name = workout.displayedName
        if logMode == .strengthTraining {
            draft.clear()
            exerciseRows = WorkoutSheetRules.exerciseEntries(from: workout.exercises)
        } else {
            selectedActivityType = workout.activityType
            if let effortValue = workout.effort { effort = String(effortValue) }
        }
        if let minutes = workout.duration { duration = String(minutes) }
    }

    /// The exercise builder plus the rows already added — strength mode only. With "Log set by set"
    /// on, the builder keeps its picker (which also takes a typed name) and the set rows replace its
    /// Sets / Reps / Weight fields. The switch sits under the builder, so the quick path above it —
    /// Kind, Recent and the search — still fits the medium detent (artboard 3b).
    /// World build (`b3-workout-log` draft 2): the sheet is a list. Each exercise is one row with its sets
    /// in one line; Add exercise and tapping a row open that exercise's own page, where its sets are
    /// entered (``liftPage``).
    private var strengthSection: some View {
        MoveLiftCard(header: Text("Exercises")) {
            ForEach(exerciseRows) { entry in
                // An exercise added set by set reads "3 sets · 10, 9, 8 reps · 35 lb" (b3-workout-log d2).
                MoveLiftListRow(name: entry.exercise.displayName,
                                detail: entry.result.flatMap { WorkoutSetSummary.line(for: $0) }
                                    ?? WorkoutMeasurementEntry.displayedSpeeds(in: entry.detailSummary),
                                color: entry.exercise.category.color,
                                identifier: "workout.log.row",
                                onRemove: { exerciseRows.removeAll { $0.id == entry.id } }) { openLift(entry) }
            }
        } footer: {
            MoveAddExerciseButton(identifier: "workout.log.addExercise") { openLift(nil) }
        }
    }

    /// Opens the exercise page: blank for a new exercise, or holding `entry`'s exercise and sets.
    private func openLift(_ entry: WorkoutExerciseEntry?) {
        draft.clear()
        setsDraft = nil
        editingRowID = entry?.id
        if let entry {
            draft.exercise = entry.exercise
            draft.sets = entry.sets
            draft.reps = entry.reps
            draft.weight = entry.weight
            draft.speed = entry.speed
            draft.incline = entry.incline
            draft.details = entry.details
            logsBySet = entry.result != nil
            setsDraft = entry.result.map {
                ExerciseSetsDraft(result: $0, index: 0, defaultUnit: WorkoutLoadContextBuilder.defaultUnit(for: .current))
            }
        }
        liftPath = [.lift]
    }

    /// The page's button: the exercise joins the list, or replaces the row it was opened from.
    private func commitLift() {
        let before = exerciseRows.count
        addDraftExercise()
        guard exerciseRows.count > before else { return }
        if let id = editingRowID, let old = exerciseRows.firstIndex(where: { $0.id == id }) {
            let updated = exerciseRows.removeLast()
            exerciseRows[old] = updated
        }
        editingRowID = nil
        liftPath = []
    }

    /// The page's Remove: the row it was opened from leaves the list.
    private func removeOpenLift() {
        if let id = editingRowID { exerciseRows.removeAll { $0.id == id } }
        editingRowID = nil
        liftPath = []
    }

    /// One exercise's own page (`b3-workout-exercise`): its name and last time, then its sets row by row
    /// (or the quick Sets / Reps / Weight line, or a treadmill's speed and incline), and Add to workout.
    private var liftPage: some View {
        MoveLiftPage(title: draft.exercise.map { Text(verbatim: $0.displayName) } ?? Text("Add exercise"),
                     subtitle: liftLastTime.map { Text("Last time: \($0)") },
                     buttonLabel: editingRowID == nil ? "Add to workout" : "Save",
                     buttonDisabled: draft.exercise == nil, back: logSheetTitle, onButton: commitLift) {
            if draft.exercise == nil {
                ExerciseSearchPicker(selectedExercise: $draft.exercise, resetToken: $draft.resetToken,
                                     autofocus: true, allowsTypedExercise: true)
            } else {
                liftFields
            }
        }
        .onAppear {
            refreshLiftLastTime()
            if setsDraft == nil { resetSetsDraft(for: draft.exercise) }
        }
        .onChange(of: draft.exercise) { _, exercise in
            refreshLiftLastTime()
            // The pick happens on this page, while the list page under it is covered and may not run its
            // own onChange: build the set rows here too (the reset is a no-op when they already match).
            resetSetsDraft(for: exercise)
        }
    }

    /// The chosen exercise's fields on its page, then Change (a new pick) or Remove (a listed row).
    @ViewBuilder private var liftFields: some View {
        if draft.exercise?.inputKind == .strength {
            bySetToggle
            if logsBySet {
                bySetEntry
            }
        }
        if draft.exercise?.inputKind != .strength || !logsBySet {
            WorkoutExerciseBuilder(
                selectedExercise: $draft.exercise, sets: $draft.sets, reps: $draft.reps, weight: $draft.weight,
                speed: $draft.speed, incline: $draft.incline, details: $draft.details, resetToken: $draft.resetToken,
                mode: logMode, showAddButton: false, showsPicker: false, onAdd: addDraftExercise
            )
        }
        if editingRowID == nil {
            Button("Change") { draft.exercise = nil }
                .font(FernletFramedFont.sheetControl)
                .foregroundStyle(look?.link ?? Color.moss)
                .fernletTapTarget()
                .accessibilityIdentifier("workout.log.changeExercise")
        } else {
            Button(role: .destructive, action: removeOpenLift) { Text("Remove").frame(maxWidth: .infinity) }
                .buttonStyle(ActionPillButtonStyle(.destructive))
                .accessibilityIdentifier("workout.log.removeExercise")
        }
    }

    /// Reads "last time" for the page's exercise.
    private func refreshLiftLastTime() {
        liftLastTime = draft.exercise.flatMap { store.exerciseHistoryEntry(named: $0.name)?.lastTimeRecallValues }
    }

    /// The "Log set by set" switch above the builder.
    private var bySetToggle: some View {
        Toggle(isOn: $logsBySet) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Log set by set")
                    .font(look == nil ? .fernlet(.label) : MoveFont.rowTitle)
                    .foregroundStyle(look?.text ?? Color.bark)
                Text("Each set gets its own reps and weight.")
                    .font(look == nil ? .fernlet(.labelSmall) : FernletFramedFont.rowDetail)
                    .foregroundStyle(look?.dim ?? Color.slate)
                    .fernletWrappingText()
            }
        }
        .tint(Color.moss)
        // The routed sheet sits above the root that sets the framed switch; the system switch without the look.
        .toggleStyle(FernletFramedToggleStyle())
        // Voice Control: the spoken label runs on into the explainer line.
        .accessibilityInputLabels([Text("Log set by set"), Text("Set by set")])
        .accessibilityIdentifier("workout.log.bySet")
    }

    /// The picked lift's set rows and its Add button, while "Log set by set" is on. A treadmill pick
    /// keeps the builder's own speed and incline fields; the button adds it the usual way.
    @ViewBuilder private var bySetEntry: some View {
        if let exercise = draft.exercise, exercise.inputKind == .strength, let current = setsDraft {
            // The page's footer adds it (Add to workout), so the card carries no button of its own.
            // Never a force-unwrapping binding of the optional draft: Add to workout clears the draft while the
            // page is still leaving the stack, and an unwrapping binding read then traps.
            ExerciseSetsEditor(draft: Binding(get: { setsDraft ?? current }, set: { setsDraft = $0 }),
                               identifier: "workout.log.sets", showsName: look != nil)
        }
    }

    /// A fresh set-by-set draft for the newly picked lift (nil when the pick was cleared), in the
    /// unit the person's region weighs in.
    private func resetSetsDraft(for exercise: ExerciseTarget?) {
        guard let exercise else {
            setsDraft = nil
            return
        }
        // A listed lift reopened on its page keeps the sets it was logged with.
        guard setsDraft?.name != exercise.name else { return }
        setsDraft = ExerciseSetsDraft.blank(
            name: exercise.name, unit: WorkoutLoadContextBuilder.defaultUnit(for: .current),
            equipment: exercise.equipment)
    }

    /// The picked lift's set rows as a logged row, or nil when set-by-set entry does not apply (it is
    /// off, nothing is picked, or the pick is a treadmill entry).
    private func structuredEntry() -> WorkoutExerciseEntry? {
        guard logsBySet, logMode == .strengthTraining, let exercise = draft.exercise,
              exercise.inputKind == .strength, var sets = setsDraft else { return nil }
        sets.name = exercise.name
        guard let result = sets.handLoggedResult() else { return nil }
        return WorkoutExerciseEntry(exercise: exercise, sets: "", reps: "", weight: "", speed: "", incline: "",
                                    details: "", result: result)
    }

    /// RPE + duration, side by side — strength mode only.
    private var strengthMetricsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            SheetField("RPE (1–10)", namesControl: true) {
                TextField("7", text: $rpe, prompt: .fieldPrompt("7"))
                    .keyboardType(.numberPad)
                    .sheetTextInput(font: .fernlet(.label))
            }
            SheetField("Duration (min)", namesControl: true) {
                TextField("45", text: $duration, prompt: .fieldPrompt("45"))
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

    /// The name field is optional: the placeholder shows the name the workout will take.
    ///
    /// A resolved `String`, not a key, because two of its three answers are already final text: the
    /// activity type's localized `displayName` and the name inferred from the exercises the user
    /// added. The two authored fallbacks go through `String(localized:)`, so they reach the catalog
    /// instead of riding the field's verbatim overload in English. An activity left unnamed is SAVED
    /// under its frozen English `defaultName` (see ``workoutName``), so on a translated device the
    /// placeholder reads in the user's language while the stored name stays the token, as the plan
    /// sheet's split placeholder already does.
    private var namePlaceholder: String {
        if logMode == .activity {
            return selectedActivityType?.displayName
                ?? String(localized: "move.workoutName.placeholder.activity",
                          defaultValue: "Optional, e.g. Saturday ride",
                          comment: "Placeholder in the optional workout-name field before an activity is chosen. Names an example activity.")
        }
        guard inferredStrengthName.isEmpty else { return inferredStrengthName }
        return String(localized: "move.workoutName.placeholder.strength",
                      defaultValue: "Optional, e.g. Upper strength",
                      comment: "Placeholder in the optional workout-name field before any exercise is added. Names an example strength session.")
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
        // The exercise page is built here, inside this body, so every state it draws (its set rows, the
        // switch, last time) is read by this view: built lazily in the destination closure, a change to
        // state only that page read never re-rendered it, and a picked lift showed no set rows.
        let page = liftPage
        // World build (`b3-workout-log` draft 2): a stack, so an exercise's sets open on their own page
        // with Back naming the sheet. The list keeps the sheet's header (Cancel, the title) and Save.
        NavigationStack(path: $liftPath) {
            listPage
                .navigationTitle(logSheetTitle)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: WorkoutLiftRoute.self) { _ in page }
        }
        .onChange(of: liftPath) { _, path in
            // Back from an exercise's page drops what it held; Add to workout already took it.
            guard path.isEmpty else { return }
            draft.clear()
            setsDraft = nil
            editingRowID = nil
        }
    }

    /// The sheet's list page: Kind, the exercises (or the activity), the name, and the rest.
    private var listPage: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // Draft 2 order (`b3-workout-log`): Kind, the exercise list, Recent, then the
                    // name and metrics; Log it again, the category preview and notes further down.
                    kindField

                    if logMode == .strengthTraining {
                        strengthSection
                        recentExerciseChips
                        workoutNameField
                        strengthMetricsRow
                    } else {
                        ActivityPickerSection(
                            selectedActivityType: $selectedActivityType,
                            duration: $duration,
                            distance: $distance,
                            energyKcal: $energyKcal,
                            effort: $effort,
                            showsEnergyField: store.settings.showCalories
                        )
                        workoutNameField
                    }

                    notesField
                    logAgainCard

                    if hasCategoryInput {
                        WorkoutCategoryPreview(category: inferredCategory)
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(disabled: saveDisabled) { saveWorkout() }
        }
        .background((look?.paper ?? Color.parchment).ignoresSafeArea())
        // NOT `keyboardDoneToolbar()` here: this sheet is presented both by the root router (where
        // `fernletSheetChrome` already supplies one) and by the day detail (which supplies its own).
        // Declaring a second `ToolbarItemGroup(placement: .keyboard)` inside the same hierarchy puts
        // two "Done" buttons in one accessory bar.
        // The 2026-08-21 template chrome in one line: the pinned SheetHeader (Cancel + title),
        // blocked swipe-dismiss while dirty, and the discard prompt on Cancel.
        .fernletDraftGuard(isDirty: isDirty, title: logSheetTitle) { dismiss() }
        .onAppear { refreshRecall() }
        .onChange(of: logMode) { _, _ in
            draft.clear()
            lastLogged = store.mostRecentLoggedWorkout(mode: logMode)
        }
        .onChange(of: draft.exercise) { _, exercise in resetSetsDraft(for: exercise) }
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
        // Lifts entered set by set carry their structured record too; a free-text-only log has none.
        let structured = logMode == .strengthTraining ? exerciseRows.compactMap(\.result) : []
        var workout = Workout(
            name: workoutName,
            type: inferredCategory,
            mode: logMode,
            activityType: logMode == .activity ? selectedActivityType : nil,
            exercises: logMode == .strengthTraining ? exerciseText : "",
            rpe: logMode == .strengthTraining ? LocaleTolerantNumber.double(from: rpe) : nil,
            notes: notes,
            duration: WorkoutSheetRules.durationMinutes(from: duration),
            // Typed in the device's units, stored in miles as always.
            distanceMiles: logMode == .activity ? WorkoutMeasurementEntry.miles(fromEntry: distance) : nil,
            activeEnergyKcal: logMode == .activity ? LocaleTolerantNumber.double(from: energyKcal) : nil,
            effort: logMode == .activity ? LocaleTolerantNumber.int(from: effort) : nil,
            muscleGroups: logMode == .strengthTraining ? aggregatedMuscleGroups : [],
            intensity: intensity,
            exerciseResults: structured.isEmpty ? nil : Array(structured.prefix(Workout.maxExerciseResults))
        )
        workout.completedAt = completedAtDate
        workout.loggedAt = completedAtDate
        store.addWorkout(workout, date: targetDateKey)
        dismiss()
        // The sheet closes in silence otherwise: nothing on the screen it returns to changes under
        // VoiceOver's cursor. Spoken once the dismissal has settled.
        Task { @MainActor in await TaskConfirmation.workoutLogged.announceAfterSheetCloses() }
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
        if !typedName.isEmpty { return typedName }
        if logMode == .activity, let selectedActivityType {
            // `defaultName`, not `displayName`: this is PERSISTED as `Workout.name`, and the
            // workout row and week calendar file the row under a category by keyword-matching
            // English words in it. The placeholder is display-only and keeps the localized name.
            return selectedActivityType.defaultName
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
        // Set by set: the picked lift's rows become a structured row (its record plus its line).
        if let entry = structuredEntry() {
            exerciseRows.append(entry)
            draft.clear()
            setsDraft = nil
            return
        }
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
            let parsedDuration = durationMinutes(from: duration) ?? 0
            let parsedDistance = LocaleTolerantNumber.double(from: distance) ?? 0
            return parsedDuration <= 0 && parsedDistance <= 0
        }
    }

    /// Whole minutes from a Duration field, rounding a fractional entry to the nearest minute.
    ///
    /// The field shows a number pad, but a pasted or hardware-keyboard "30.5" still arrives. Parsed as
    /// an integer it read as no duration at all: an activity log's Save stayed disabled with nothing
    /// saying why, and a strength log saved with its duration silently dropped. Every Duration field in
    /// this file reads through here, so the save gate and the saved value cannot disagree.
    ///
    /// - Returns: nil for empty, negative, unparseable or unrepresentable text.
    static func durationMinutes(from text: String) -> Int? {
        guard let minutes = LocaleTolerantNumber.double(from: text), minutes >= 0 else { return nil }
        return Int(exactly: minutes.rounded())
    }

    static func aggregatedMuscleGroups(from exerciseRows: [WorkoutExerciseEntry]) -> Set<MuscleGroup> {
        exerciseRows.reduce(into: Set<MuscleGroup>()) { acc, row in
            acc.formUnion(row.exercise.primaryMuscles)
            acc.formUnion(row.exercise.secondaryMuscles)
        }
    }

    /// Best-effort parse of free-text exercise lines ("Back squat 3x8 @60") back into structured rows.
    ///
    /// Shared by ``WorkoutPlanSheet`` (re-hydrating "Plan steps" on open) and ``WorkoutSheet``'s
    /// "Log it again" prefill (MOVE-08) — one parser, so the two sheets can never disagree about
    /// what a line means. Lines that match no catalog exercise are skipped, not invented.
    ///
    /// A treadmill line stores its speed in mph; its Speed field reads in the device's units
    /// (`imperial` nil reads this device), so a metric reopen shows km/h and re-saves the same mph.
    ///
    /// A guided or set-by-set line (`ExerciseResult.loggedLine`, "Bench press - 3 x 8 @ 105 lb (did 8,
    /// 8, 6)") reopens as its prescription: 3 × 8 at 105 lb. Its "(did …)" outcome is what happened
    /// that day, not what to do again, so it is dropped (``withoutLoggedOutcome(_:)``); the weight
    /// ends where a parenthetical starts; and the " - " after the name is not kept as a detail. Any
    /// other parenthetical — a calibration tag ("(ramp-up)"), a coach's cue ("(RPE 7)") — stays in
    /// the details, so a copied ramp set is still told apart from working sets.
    static func exerciseEntries(from text: String, imperial: Bool? = nil) -> [WorkoutExerciseEntry] {
        text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = withoutLoggedOutcome(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let exercise = catalogExercise(namedBy: trimmed) else {
                return nil
            }

            let setRep = firstMatch(in: trimmed, pattern: #"(\d+)\s*x\s*(\d+)"#)
            let load = loadSegment(in: trimmed)
            let weight = load?.value ?? ""
            let treadmill = exercise.inputKind == .treadmill ? treadmillFields(in: trimmed) : nil
            var details = trimmed.replacingOccurrences(of: exercise.name, with: "")
            let consumed = [setRep.fullMatch, load?.text] + (treadmill?.consumed ?? [])
            for match in consumed.compactMap({ $0 }) {
                details = details.replacingOccurrences(of: match, with: "")
            }
            details = detailsWithoutLeadingSeparator(details)

            return WorkoutExerciseEntry(
                exercise: exercise,
                sets: setRep.groups.first ?? "",
                reps: setRep.groups.dropFirst().first ?? "",
                weight: exercise.inputKind == .strength ? weight : "",
                // `summary` writes "5.5 mph"; an older line carried the speed after "@".
                speed: treadmill.map {
                    WorkoutMeasurementEntry.speedEntry(fromStored: $0.speed.isEmpty ? weight : $0.speed, imperial: imperial)
                } ?? "",
                incline: treadmill?.incline ?? "",
                details: details
            )
        }
    }

    /// `line` without the "(did 8, 8, 6)" / "(did 8 @ 100, 6 @ 95)" outcome a guided or set-by-set
    /// line carries (`ExerciseResult.loggedLine`, a FROZEN log token). Strict — "(did " then a digit —
    /// so a typed note such as "(did it slowly)" is left alone. The outcome is removed before the
    /// weight is read, because its own "@ 100" would otherwise read as the load.
    static func withoutLoggedOutcome(_ line: String) -> String {
        line.replacing(/\s*\(did \d[^)]*\)/, with: "")
    }

    /// The load a line states after its "@" — the text from the "@" up to the first parenthetical
    /// (or the line's end), and that text's value without the "@" ("@ 105 lb " → "105 lb"). Nil when
    /// the line has no "@". A parenthetical is a tag or a cue, never part of a weight.
    static func loadSegment(in line: String) -> (text: String, value: String)? {
        guard let at = line.firstIndex(of: "@") else { return nil }
        let end = line[at...].firstIndex(of: "(") ?? line.endIndex
        let text = String(line[at..<end])
        return (text, text.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What is left of a line once its name, sets × reps and load are taken out, without the
    /// separator that stood between the name and the numbers ("Bench press - 3 x 8" leaves "-").
    static func detailsWithoutLeadingSeparator(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators: Set<Character> = ["-", "–", "—", ":"]
        return trimmed.drop(while: { separators.contains($0) }).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The catalog exercise a written line names: the longest catalog name the line starts with
    /// (case-insensitive, ending at a word boundary), since ``WorkoutExerciseEntry/summary`` always
    /// writes the name first.
    ///
    /// The lookup used to be `WorkoutExerciseCatalog.search(line)`, which matches only when an
    /// exercise's NAME contains the whole line. Any line carrying its numbers ("Bench press 3x8 @95",
    /// "Treadmill walk 3.5 mph") therefore matched nothing and was dropped on reopen. That search is
    /// kept as the fallback, so a line that is just a name (or that only it matched before) still
    /// resolves as it did.
    private static func catalogExercise(namedBy line: String) -> ExerciseTarget? {
        let lower = line.lowercased()
        let named = WorkoutExerciseCatalog.allExercises.filter { exercise in
            let name = exercise.name.lowercased()
            guard !name.isEmpty, lower.hasPrefix(name) else { return false }
            return lower.dropFirst(name.count).first.map { !$0.isLetter } ?? true
        }
        return named.max { $0.name.count < $1.name.count } ?? WorkoutExerciseCatalog.search(line).first
    }

    /// The speed and incline a treadmill line's ``WorkoutExerciseEntry/summary`` wrote ("5.5 mph",
    /// "2% incline"), with the matched text so the caller can keep it out of `details`.
    ///
    /// Without this a reopened treadmill line lost both values into its free-text details, and a
    /// re-typed speed then appeared twice in the saved line.
    private static func treadmillFields(in text: String) -> (speed: String, incline: String, consumed: [String?]) {
        let speed = firstMatch(in: text, pattern: #"(\d+(?:[.,]\d+)?)\s*mph"#)
        let incline = firstMatch(in: text, pattern: #"(-?\d+(?:[.,]\d+)?)\s*%\s*incline"#)
        return (speed.groups.first ?? "", incline.groups.first ?? "", [speed.fullMatch, incline.fullMatch])
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
                    // Decorative, beside its own title; unhidden it read as its symbol name
                    // (VoiceOver dry run, 2026-10-18).
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Log it again")
                        .font(.fernlet(.label))
                        .foregroundStyle(look?.text ?? Color.bark)
                    Text(verbatim: headline)
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(look?.dim ?? Color.slate)
                }
                Spacer(minLength: 8)
                if !dynamicTypeSize.isAccessibilitySize {
                    logAgainButton
                }
            }
            if let summary {
                summary
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(look?.dim ?? Color.slate)
                    .lineLimit(2)
            }
            if dynamicTypeSize.isAccessibilitySize {
                // 1f·AX3: the button moves onto its own line under the body copy.
                logAgainButton
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MoveInsetCardFrame())
    }

    @Environment(\.fernletFramedLook) private var look

    private var logAgainButton: some View {
        Button("Log again", action: onLogAgain)
            .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
            .accessibilityIdentifier("workout.logAgain")
    }

    /// "Wednesday · Upper strength" — abbreviated weekday at accessibility sizes.
    private var headline: String {
        let date = FernletDate.date(fromDayKey: recent.dayKey) ?? .now
        let weekday = dynamicTypeSize.isAccessibilitySize
            ? date.formatted(.dateTime.weekday(.abbreviated))
            : date.formatted(.dateTime.weekday(.wide))
        return "\(weekday) · \(recent.workout.displayedName)"
    }

    /// "Bench press, Lat pulldown, Dip · 3 more" for strength; type + minutes for an activity.
    /// A `Text`, not a `String`, so the "min"/"more" sentence shapes localize — the exercise and
    /// type names interpolate as data. Nil when the workout carries nothing to summarize.
    private var summary: Text? {
        let workout = recent.workout
        if workout.mode == .activity {
            let type = workout.activityType?.displayName
            let minutes = workout.duration
            if let type, let minutes { return Text("\(type) · \(minutes) min") }
            if let type { return Text(verbatim: type) }
            if let minutes { return Text("\(minutes) min") }
            return nil
        }
        let names = workout.exerciseLines.compactMap { ExerciseLineParser.parse($0)?.name }
        let shown = names.isEmpty ? workout.exerciseLines : names
        guard !shown.isEmpty else { return nil }
        let leading = shown.prefix(3).joined(separator: ", ")
        let more = shown.count - min(3, shown.count)
        return more > 0 ? Text("\(leading) · \(more) more") : Text(verbatim: leading)
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
    /// World build (`b3-suggest-config`, `b3-suggest-plan`): the sheet's paper and framed pieces.
    @Environment(\.fernletFramedLook) private var suggestLook
    var store: FernletStore
    @State private var energy: WorkoutIntensity = .moderate
    @State private var context = ""
    // Today's session length: seeded once from Workout setup, and shapes only the plan it builds.
    @State private var sessionLength: WorkoutSessionLength = .noLimit
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
    // Set when the user taps a plan row's info button; presents that exercise's how-to. nil = closed.
    @State private var howTo: ExerciseHowToRequest?

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
            // At accessibility sizes "Change" moves under the location, which then has the whole
            // width to wrap in: side by side at AX5 they read "Full gy…" and "Chang/e".
            AdaptiveStack(spacing: 10, horizontalAlignment: .leading) {
                HStack(spacing: 10) {
                    Group {
                        if suggestLook != nil {
                            WorldSpriteView(sprite: WorldSprites.pin, scale: 2)
                        } else {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.moss)
                        }
                    }
                    // Decorative. Unhidden, VoiceOver read the symbol's system description —
                    // "Remove Map Pin" — beside a row that removes nothing (dry run, 2026-10-18).
                    .accessibilityHidden(true)
                    // Localizing interpolation, never a verbatim String build: "items" is display
                    // copy; the location name interpolates as data.
                    Text("\(store.settings.activeWorkoutLocation.displayedName) · \(store.settings.activeWorkoutLocation.ownedEquipment.count) items")
                        .font(suggestLook == nil ? .fernlet(.label) : MoveFont.rowTitle)
                        .foregroundStyle(suggestLook?.text ?? Color.bark)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Change") { showingSpaces = true }
                    .font(suggestLook == nil ? .fernlet(.label) : FernletFramedFont.sheetControl)
                    .foregroundStyle(suggestLook?.link ?? Color.moss)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .fernletTapTarget()
                    .accessibilityIdentifier("workout.space.change")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, suggestLook == nil ? 6 : 10)
            .modifier(MoveInsetCardFrame(cornerRadius: suggestLook == nil ? 10 : 12))
        }
    }

    /// The "Equipment & limits" entry — the only app-wide way into `WorkoutSetupSheet` (split,
    /// frequency, experience, injuries). Kept on the committed-plan branch, so the full setup stays
    /// reachable once a plan is pinned (change it here, then "Rework today's plan" to regenerate
    /// against the new setup); the configurator now states the space inline instead (MOVE-34).
    @ViewBuilder private var equipmentLimitsButton: some View {
        if suggestLook != nil {
            // World build: the framed link card the Move pages use (`b2-move-root`'s history link).
            MoveLinkCard(title: Text("Equipment & limits"), sprite: WorldSprites.dumbbell,
                         detail: Text(verbatim: store.settings.activeWorkoutLocation.displayedName),
                         inksSprite: true, identifier: "workout.setup.open") { showingSetup = true }
        } else {
            plainEquipmentLimitsButton
        }
    }

    private var plainEquipmentLimitsButton: some View {
        Button {
            showingSetup = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "dumbbell")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.moss)
                Text("Equipment & limits · \(store.settings.activeWorkoutLocation.displayedName)")
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
                    // Cream, not a slate tint: this sheet is parchment, and slate text on a 10%
                    // slate tint over parchment measures 4.22:1, under the 4.5:1 floor.
                    .background(Color.cream, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.bark.opacity(0.10), lineWidth: 1))
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
    /// "Already did this" tertiary and the one-line caption move below the primary.
    @ViewBuilder private func committedPlanActionBar(_ dayPlan: WorkoutProgram.DayPlan) -> some View {
        if suggestLook != nil {
            framedPlanActionBar(dayPlan)
        } else {
            plainPlanActionBar(dayPlan)
        }
    }

    /// World build (`b3-suggest-plan` draft 2): Edit and Start now side by side, then Save full width.
    /// "Already did this — log it" is gone (the owner's note on draft 1); the gentle stretch stays.
    private func framedPlanActionBar(_ dayPlan: WorkoutProgram.DayPlan) -> some View {
        let editTarget = guidableSession(in: dayPlan) ?? dayPlan.sessions.first
        return VStack(spacing: 10) {
            gentleStretchButton(in: dayPlan)
            AdaptiveStack(spacing: 10) {
                if store.canReworkTodaysGuidedPlan, let editTarget {
                    Button { editingSession = editTarget } label: { Text("Edit").frame(maxWidth: .infinity) }
                        .buttonStyle(ActionPillButtonStyle(.secondary))
                        .disabled(isAdjusting)
                        .accessibilityIdentifier("workout.editPlan")
                }
                if let guidable = guidableSession(in: dayPlan) {
                    startNowButton(guidable)
                }
            }
            Button {
                store.approveTodaysGuidedPlan()
                dismiss()
            } label: {
                Text("Save").frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.secondary))
            .accessibilityIdentifier("workout.approvePlan")
            if dynamicTypeSize.isAccessibilitySize { startOrSaveCaption }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    /// Today's committed-plan bar.
    @ViewBuilder private func plainPlanActionBar(_ dayPlan: WorkoutProgram.DayPlan) -> some View {
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
            gentleStretchButton(in: dayPlan)
            if let guidable = guidableSession(in: dayPlan) {
                startNowButton(guidable)
            }
            if dynamicTypeSize.isAccessibilitySize, !remainingSessions.isEmpty {
                logAlreadyDoneButton(remainingSessions)
            }
            if dynamicTypeSize.isAccessibilitySize {
                // 1d·AX3: the caption follows the tertiary below the primary bar.
                startOrSaveCaption
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .background(Color.parchment)
    }

    /// The rest day's optional gentle stretch (``GuidedWorkoutAvailability/optionalStretch(in:excluding:loggedGuidedWorkoutNames:)``),
    /// about eight minutes on the floor — a quiet tint like "Already did this", never the screen's green:
    /// on a day the person said they are unwell a stretch is offered, not pushed, and the plan stays rest.
    @ViewBuilder private func gentleStretchButton(in dayPlan: WorkoutProgram.DayPlan) -> some View {
        if let session = GuidedWorkoutAvailability.optionalStretch(
            in: dayPlan, excluding: guidedCompletedSessionIDs, loggedGuidedWorkoutNames: store.loggedGuidedWorkoutNamesToday
        ) {
            Button {
                guidedSession = session
            } label: {
                Text("Guide me through a gentle stretch, about 8 minutes")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.moss)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color.moss.opacity(0.12), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .buttonStyle(.plain)
            // Voice Control: the drawn line is long; its first words, or the plain name, are enough.
            .accessibilityInputLabels([Text("Gentle stretch"), Text("Guide me through a gentle stretch")])
            .accessibilityIdentifier("workout.startGentleStretch")
        }
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
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.moss.opacity(0.12), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        // Voice Control: the drawn line is five words; either half of it is enough.
        .accessibilityInputLabels([Text("Already did this"), Text("Log it")])
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
        Task { @MainActor in await TaskConfirmation.workoutLogged.announceAfterSheetCloses() }
    }

    /// The configurator bottom bar: **Suggest a workout**, with a loading state while the plan is
    /// generated. At AX5 the label drops to "Suggest" — the primary grows rather than wrapping
    /// (1b·AX5, the exception recorded on 2d).
    @ViewBuilder private var suggestActionBar: some View {
        if suggestLook != nil {
            // `b3-suggest-config`: the framed primary at the bottom right, like every sheet's save.
            HStack {
                Spacer()
                Button(action: startSuggesting) {
                    HStack(spacing: 8) {
                        if isSuggesting {
                            ProgressView().controlSize(.small).accessibilityHidden(true)
                        } else if let suggestLook {
                            WorldSpriteView(sprite: MoveSprites.wand, scale: 2, tint: suggestLook.onAccent)
                        }
                        suggestLabel
                    }
                }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .disabled(isSuggesting)
                .accessibilityIdentifier("workout.suggest")
            }
            .padding(20)
        } else {
            HStack {
                Spacer()
                Button(action: startSuggesting) {
                    HStack(spacing: 8) {
                        if isSuggesting {
                            // The button's own label already changes while it runs; the spinner is the
                            // visual half of the same fact and has nothing of its own to say.
                            ProgressView().controlSize(.small).tint(Color.onMoss)
                                .accessibilityHidden(true)
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
    }

    /// The Suggest primary's label across its states and sizes. A rest day asks for "something
    /// gentle", never "a workout".
    private var suggestLabel: Text {
        if isSuggesting { return Text("Building your workout…") }
        if dynamicTypeSize >= .accessibility5 { return Text("Suggest") }
        return store.needsRestToday ? Text(MoveRestDayCopy.suggestGentle) : Text("Suggest a workout")
    }

    /// Generate today's plan with a brief, deliberate loading state. Generation is on-device and
    /// near-instant today, so a short minimum keeps the affordance from flashing (and future-proofs it
    /// for AI-backed generation, which is genuinely slow). The `nil` guard makes a double-tap a no-op.
    private func startSuggesting() {
        guard !isSuggesting, store.currentGuidedWorkoutPlan == nil else { return }
        isSuggesting = true
        // Belt to the light-only chips' braces: a chip state seeded before the rest day began can
        // never build a harder plan on it.
        let intensity = store.needsRestToday ? .light : energy
        let requestContext = context
        let length = sessionLength
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
            store.commitTodaysGuidedWorkoutPlan(intensity: intensity, context: requestContext, sessionLength: length)
            isSuggesting = false
        }
    }

    /// One session card in the committed plan (1d): name, "5 exercises · ~45 min", one prescription
    /// row per exercise, and the session note.
    private func sessionCard(_ session: WorkoutProgram.SessionSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.displayedName)
                .font(suggestLook == nil ? .fernlet(.headerMedium) : FernletFramedFont.cardTitle)
                .foregroundStyle(suggestLook?.text ?? Color.bark)
            sessionMetaLine(session)
                .font(suggestLook == nil ? .fernlet(.labelSmall) : FernletFramedFont.body)
                .foregroundStyle(suggestLook?.dim ?? Color.slate)
            // World build (`b3-suggest-plan`): a dotted rule above every row, compact rows, and the
            // small "i" (`.controlSize(.small)` is what ExerciseHowToButton reads for it).
            Group(subviews: sessionRows(session)) { rows in
                VStack(alignment: .leading, spacing: suggestLook == nil ? 8 : 0) {
                    ForEach(rows) { row in
                        if suggestLook != nil { FernletDottedRule().padding(.vertical, 4) }
                        row.frame(minHeight: suggestLook == nil ? nil : 36)
                    }
                }
            }
            .controlSize(suggestLook == nil ? .regular : .small)
            if !session.suggestion.notes.isEmpty {
                Text(CoachPlanNoteStamp.displayedNotes(session.suggestion.notes))
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // World build (`b3-suggest-plan`): the session is one framed card.
        .modifier(MoveInsetCardFrame(cornerRadius: suggestLook == nil ? 14 : 12))
    }

    /// The session's rows, top to bottom: the warm-up, each movement, the cool-down.
    @ViewBuilder private func sessionRows(_ session: WorkoutProgram.SessionSuggestion) -> some View {
        let warmUp = session.exercises.filter { $0.block == .warmUp }
        let coolDown = session.exercises.filter { $0.block == .coolDown }
        if !warmUp.isEmpty {
            blockSummaryRow(Text("Warm-up · \(warmUp.count) stretches"), minutes: WorkoutSessionBlocks.minutes(of: warmUp))
        }
        // A lift's warm-up sets fold into one row ("Back squat · 3 warm-up sets").
        ForEach(GuidedPlanRow.rows(session.exercises.filter { $0.block != .warmUp && $0.block != .coolDown })) { row in
            if row.warmUpCount > 0 {
                GuidedWarmUpPlanRow(name: row.step.name, count: row.warmUpCount)
            } else {
                sessionExerciseRow(row.step)
            }
        }
        if !coolDown.isEmpty {
            blockSummaryRow(Text("Cool-down · \(coolDown.count) stretches"), minutes: WorkoutSessionBlocks.minutes(of: coolDown))
        }
    }

    /// A row's name font: the World look's body face, or today's body.
    private var sessionNameFont: Font { suggestLook == nil ? .fernlet(.body) : FernletFramedFont.body }

    /// A row's trailing figure ("4 × 8–12", "~8 min"): bold in the ink under the World look
    /// (`b3-suggest-plan`), today's small slate without it.
    private var sessionFigureFont: Font {
        suggestLook == nil ? .fernlet(.labelSmall) : MoveFont.body
    }

    private var sessionFigureColor: Color { suggestLook?.text ?? Color.slate }

    /// The warm-up or cool-down as one row ("Warm-up · 23 stretches" beside "~9 min"): the stretches
    /// themselves are walked one at a time in the run, not listed here.
    private func blockSummaryRow(_ label: Text, minutes: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            label
                .font(sessionNameFont)
                .foregroundStyle(suggestLook?.text ?? Color.bark)
            Spacer(minLength: 8)
            Text("~\(minutes) min")
                .font(sessionFigureFont)
                .foregroundStyle(sessionFigureColor)
        }
    }

    /// "5 exercises · ~45 min" under the session name. The count is the movements listed one per row
    /// (activation, lifting, cardio; a lift's warm-up sets are not one); the time includes the warm-up and
    /// cool-down, by the same estimate the planner fits a session-length budget with and the runner counts
    /// down from (``WorkoutSessionTime``) — so a session set to 30 minutes says ~30 here and in the run.
    private func sessionMetaLine(_ session: WorkoutProgram.SessionSuggestion) -> Text {
        let minutes = WorkoutSessionTime.minutes(of: session.exercises, goal: store.settings.selectedGoal)
        let count = GuidedPlanRow.movementCount(session.exercises.filter { $0.block != .warmUp && $0.block != .coolDown })
        return count == 1
            ? Text("1 exercise · ~\(minutes) min")
            : Text("\(count) exercises · ~\(minutes) min")
    }

    /// One exercise's prescription row: name beside "4 × 8–12", with the how-to button at the end of
    /// a catalog exercise's row. At accessibility sizes name and prescription stop sharing a line
    /// (1d·AX3). The name is drawn through `displayName`; the plan keeps the frozen one.
    @ViewBuilder private func sessionExerciseRow(_ exercise: PrescribedExercise) -> some View {
        let prescription: String? = exercise.fromCatalog && exercise.sets >= 1 && !exercise.reps.isEmpty
            ? (exercise.holdSeconds != nil && exercise.sets <= 1 ? exercise.reps : "\(exercise.sets) × \(exercise.reps)")
            : nil
        // A descriptor step's name is frozen plan text ("Easy cardio - 20 min"), drawn localized.
        let drawnName = exercise.fromCatalog ? exercise.displayName : WorkoutPlanLine.displayed(exercise.name)
        if dynamicTypeSize.isAccessibilitySize {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: drawnName)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                    if let side = GuidedSideLabel(raw: exercise.side?.rawValue) {
                        side.text
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                    }
                    if let prescription {
                        Text(verbatim: prescription)
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                sessionHowToButton(exercise)
            }
        } else {
            HStack(alignment: suggestLook == nil ? .firstTextBaseline : .center, spacing: 10) {
                Text(verbatim: drawnName)
                    .font(sessionNameFont)
                    .foregroundStyle(suggestLook?.text ?? Color.bark)
                if let side = GuidedSideLabel(raw: exercise.side?.rawValue) {
                    side.text
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(suggestLook?.dim ?? Color.slate)
                }
                Spacer(minLength: 8)
                if let prescription {
                    Text(verbatim: prescription)
                        .font(sessionFigureFont)
                        .foregroundStyle(sessionFigureColor)
                }
                sessionHowToButton(exercise)
            }
        }
    }

    /// The row's how-to button, for a catalog exercise with bundled how-to text; nothing otherwise
    /// (a cardio descriptor line, a custom exercise).
    @ViewBuilder private func sessionHowToButton(_ exercise: PrescribedExercise) -> some View {
        if ExerciseHowToCatalog.entry(for: exercise.name) != nil {
            ExerciseHowToButton(exerciseName: exercise.name) {
                howTo = ExerciseHowToRequest(name: exercise.name)
            }
        }
    }

    /// "Start now" — the screen's ONE green, and the only route into the runner (MOVE-17/MOVE-01).
    /// Lives in the bottom bar; the explanation is the single italic line in the scroll content.
    @ViewBuilder private func startNowButton(_ guidable: WorkoutProgram.SessionSuggestion) -> some View {
        if let look = suggestLook {
            Button { startNow(guidable) } label: {
                HStack(spacing: 8) {
                    WorldSpriteView(sprite: MoveSprites.flag, scale: 2, tint: look.onAccent)
                    Text("Start now")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.primary))
            .accessibilityIdentifier("workout.startGuided")
        } else {
            Button { startNow(guidable) } label: {
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
    }

    /// Start now: approves the plan, so the Move-root "Today's workout" card surfaces it if the user
    /// backs out and returns, and opens the runner on `guidable`.
    private func startNow(_ guidable: WorkoutProgram.SessionSuggestion) {
        store.approveTodaysGuidedPlan()
        guidedSession = guidable
    }

    /// The natural-language "Adjust with AI" field over a committed plan.
    private var aiAdjustField: some View {
        SheetField("Adjust") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("e.g. swap the squat, 30 minutes, no barbell", text: $adjustRequest,
                          prompt: .fieldPrompt("e.g. swap the squat, 30 minutes, no barbell"))
                    .sheetTextInput()
                    .disabled(isAdjusting)
                Button {
                    runAdjustment()
                } label: {
                    HStack(spacing: 8) {
                        // "Adjusting…" below is the spoken half; the spinner is the drawn one.
                        if isAdjusting { ProgressView().controlSize(.small).accessibilityHidden(true) }
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

    /// The committed-plan reading pane (1d): session cards, the context and explanation lines,
    /// then adjust / equipment / rework. The split eyebrow lives in the pinned header, not here,
    /// and no controls compete with the bottom bar's single green (MOVE-17) — Start now lives there.
    private func committedPlanContent(_ dayPlan: WorkoutProgram.DayPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(dayPlan.sessions) { session in
                sessionCard(session)
            }

            committedContextLine
            // 1d·AX3: at accessibility sizes the caption moves below the primary bar
            // (with the "Already did this" tertiary) instead of sitting in the scroll content.
            if !dynamicTypeSize.isAccessibilitySize {
                startOrSaveCaption
            }

            if aiAdjustAvailable {
                aiAdjustField
            }

            equipmentLimitsButton
            reworkPlanAffordance
        }
        // One presenter for every row's info button, on the plan rather than on each card, so two
        // sessions never bind two sheets to the same state. The store lets the sheet offer "Don't
        // suggest this" (N6); today's committed plan keeps the exercise, later plans leave it out.
        .exerciseHowToSheet($howTo, sex: store.effectiveUserProfile.sex, preferences: store)
    }

    /// The one italic "what happens next" line of the committed plan (1d); rendered in the scroll
    /// content at default sizes and below the primary bar at accessibility sizes (1d·AX3).
    private var startOrSaveCaption: some View {
        Text("Start it now, or save it and it'll be waiting on the Move root.")
            .font(.fernlet(.bubble))
            .italic()
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
    }

    /// "Full gym · built for a hard day" — where and at what intensity the plan was built.
    /// `displayWord` is the localized half of the intensity's token/display fork — never
    /// interpolate the frozen `rawValue` into display copy.
    private var committedContextLine: some View {
        let locationName = store.settings.activeWorkoutLocation.displayedName
        let intensity = (store.committedGuidedIntensity ?? energy).displayWord
        return Text("\(locationName) · built for a \(intensity) day")
            .font(.fernlet(.labelSmall))
            .foregroundStyle(Color.slate)
    }

    /// The pre-plan configurator (1b): readiness chips, the inline stated space, and the free-text
    /// note. The accepted 44pt chip targets now exceed the 437pt medium-detent budget, so the note
    /// can require a short scroll at default type. The old Goal row and closing caption stay out.
    @ViewBuilder private var configuratorContent: some View {
        feelingSection
        if !store.needsRestToday {
            sessionLengthField
        }
        spaceRow
        SheetField("Anything else?") {
            TextField("e.g. sore left knee, short on time", text: $context,
                      prompt: .fieldPrompt("e.g. sore left knee, short on time"))
                .sheetTextInput()
                // Measured with no spoken name at all ("text field"); the caption above is a
                // separate element.
                .accessibilityLabel("Anything else?")
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
                    // A rest day (today marked unwell → readiness `needs rest`, spec §6a) says rest,
                    // never "suggests light": no intensity suggestion on the day the body asked for none.
                    if store.needsRestToday {
                        Text(MoveRestDayCopy.suggestSheetLine)
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(suggestLook?.dim ?? Color.slate)
                            .fernletWrappingText()
                    } else if let rec = recommendedIntensity {
                        Text("Today's readiness suggests \(rec.displayWord).")
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(suggestLook?.dim ?? Color.slate)
                    }
                    feelingChips
                }
            }
            .onAppear { seedIntensityOnce(preferCommitted: false) }
        }
    }

    /// "How long?" — today's session length (``WorkoutSessionLength``), seeded from Workout setup.
    /// A one-line menu rather than a fifth chip row, so the configurator stays short; the caption
    /// names the menu, so VoiceOver reads "How long?, 30 min, pop-up button" and Voice Control
    /// answers to "Tap How long". Hidden on a rest day, whose gentle plan has no length to fit.
    @ViewBuilder private var sessionLengthField: some View {
        if suggestLook != nil {
            // `b3-suggest-config`: one framed dropdown, full width, under its section label.
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("How long?").padding(.horizontal, 4)
                FernletDropdown("How long?", selection: $sessionLength, options: WorkoutSessionLength.allCases,
                                showsLabel: false, fullWidth: true) { length in
                    Text(length.displayName)
                }
                .accessibilityIdentifier("workout.suggest.length")
            }
        } else {
            plainSessionLengthField
        }
    }

    /// Today's menu picker for the session length.
    private var plainSessionLengthField: some View {
        SheetField("How long?", namesControl: true) {
            Picker(selection: $sessionLength) {
                ForEach(WorkoutSessionLength.allCases) { length in
                    Text(length.displayName).tag(length)
                }
            } label: {
                Text("How long?")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            // A menu picker draws its value in the tint; `moss` measures 3.74:1 on parchment, under
            // the 4.5:1 text floor, so the value takes the moss text token (the injury picker's rule).
            .tint(Color.mossInk)
            .accessibilityIdentifier("workout.suggest.length")
        }
    }

    /// The intensity chips the configurator offers: Light / Moderate / Hard, or Light alone on a rest
    /// day (readiness `needs rest` — today marked unwell). Gentle options only; no push. Static so it
    /// is testable (the `AwayHeartsCopy` precedent).
    nonisolated static func offeredIntensities(needsRest: Bool) -> [WorkoutIntensity] {
        needsRest ? [.light] : Array(WorkoutIntensity.allCases)
    }

    /// The intensity chips — ``offeredIntensities(needsRest:)`` for today.
    private var feelingChips: some View {
        FlowLayout(spacing: 8) {
            ForEach(Self.offeredIntensities(needsRest: store.needsRestToday)) { intensity in
                // `displayWord` is the localized token-free half; `.localizedCapitalized` raises it
                // for a standalone chip using the USER's locale rules (Turkish dotless i included),
                // which `String.capitalized` does not.
                Button(intensity.displayWord.localizedCapitalized) { FernletFeedback.system.select(intensity, in: &energy) }
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
        // The session length seeds with it, once per presentation, from Workout setup.
        sessionLength = store.settings.workoutSessionLength
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
            // was swipe-only to dismiss before (XCUT-15). A committed plan carries its split
            // eyebrow ABOVE the title in the pinned header (1d: "Daily movement · day 1"), never
            // as the first line of the scroll content.
            SheetHeader(
                title: sheetTitle,
                eyebrow: dayPlan.map { Text("\($0.displayedSplitName) · \($0.displayedDayTitle)") },
                onCancel: attemptCancel
            )
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
                // At accessibility sizes the committed plan's four actions scroll with the plan: pinned,
                // at AX5 they took all but ~150pt of the sheet, truncated "Already did this…" and left
                // the plan itself unreadable behind them.
                if let dayPlan, dynamicTypeSize.isAccessibilitySize {
                    committedPlanActionBar(dayPlan)
                }
            }

            if let dayPlan {
                if !dynamicTypeSize.isAccessibilitySize {
                    committedPlanActionBar(dayPlan)
                }
            } else {
                suggestActionBar
            }
        }
        .background((suggestLook?.paper ?? Color.parchment).ignoresSafeArea())
        .interactiveDismissDisabled(isConfiguratorDirty)
        .discardConfirmation(isPresented: $showDiscardConfirm) { dismiss() }
        .onAppear { seedIntensityOnce(preferCommitted: true) }
        .sheet(isPresented: $showingSetup) {
            WorkoutSetupSheet(store: store)
                .fernletSheet()
        }
        .sheet(isPresented: $showingSpaces) {
            // The space row's Change (MOVE-34) — straight to the Your-spaces list (1c), not the
            // full setup sheet.
            WorkoutLocationSetupView(store: store)
                .fernletSheet()
        }
        // World build (`b3-runner-*`): the runner is a focused flow, full screen with no grabber.
        .fullScreenCover(item: $guidedSession, onDismiss: dismissIfPlanFullyLogged) { session in
            guidedRunnerSheet(session)
        }
        .sheet(item: $editingSession) { session in
            GuidedWorkoutEditorSheet(store: store, session: session)
                .fernletSheet()
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
    /// The user's term of address, which the remove alert's "whenever you're ready" agrees with.
    @Environment(\.fernletTermOfAddress) private var termOfAddress
    /// Called after a remove or edit so the parent can refresh caches it snapshots (calendar days, or a
    /// past-day detail list that isn't observed).
    var onChanged: () -> Void = {}

    @State private var showRemoveConfirm = false
    @State private var showEditSheet = false
    @State private var showHealthRefusalAlert = false
    /// World build (`b2-move-day`): a Fraunces title, a framed RPE tag, framed exercise rows.
    @Environment(\.fernletFramedLook) private var look

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

    /// The remove alert's title, under its own key: the shared "Remove %@?" is also asked about
    /// PEOPLE (a friend), which Spanish words differently ("¿Quitar a Ana?"); this one names a workout.
    private var removeAlertTitle: Text {
        Text(String(localized: "move.workout.remove.title", defaultValue: "Remove \(workout.displayedName)?",
                    comment: "Title of the alert before removing a logged workout. Argument: the workout's name."))
    }

    /// The remove alert's cancel button, under its own key: "Keep it" refers to the workout, so a
    /// language that agrees the pronoun with its noun needs it apart from other "Keep it"s.
    private static var keepItLabel: String {
        String(localized: "move.workout.remove.keep", defaultValue: "Keep it",
               comment: "Cancel button of the remove-workout alert: keep the logged workout")
    }

    /// The remove alert's body: one whole key per combination (plan restored or not, Health copy
    /// removed or not), rather than two English sentences joined in code. The two that put the
    /// workout back "whenever you're ready" describe the user (*lista*) and agree with them.
    private var removeConfirmMessage: String {
        switch (restoresPlannedRow, removesHealthCopy) {
        case (true, false):
            AddressedCopy.string(
                LocalizedStringResource("move.workout.remove.restoresPlan",
                                        defaultValue: "I'll put it back in your plan so you can redo it whenever you're ready.",
                                        comment: "Remove-workout alert body, for a workout completed from a plan"),
                addressing: termOfAddress)
        case (true, true):
            AddressedCopy.string(
                LocalizedStringResource("move.workout.remove.restoresPlanAndHealth",
                                        defaultValue: "I'll put it back in your plan so you can redo it whenever you're ready. This also removes the copy saved to your Health app.",
                                        comment: "Remove-workout alert body, for a workout completed from a plan that Fernlet also saved to Apple Health"),
                addressing: termOfAddress)
        case (false, false):
            String(localized: "move.workout.remove.clears",
                   defaultValue: "This just clears it from your log — no worries, you can always add it again.",
                   comment: "Remove-workout alert body")
        case (false, true):
            String(localized: "move.workout.remove.clearsAndHealth",
                   defaultValue: "This just clears it from your log — no worries, you can always add it again. This also removes the copy saved to your Health app.",
                   comment: "Remove-workout alert body, for a workout Fernlet also saved to Apple Health")
        }
    }

    /// Name plus the RPE capsule.
    private var titleRow: some View {
        HStack(alignment: .top) {
            Text(workout.displayedName)
                .font(look == nil ? .fernlet(.headerMedium) : .custom(FernletFontName.frauncesSemiBold, size: 20, relativeTo: .title3))
                .foregroundStyle(look?.text ?? Color.bark)
            Spacer()
            if let rpe = workout.rpe, let look {
                // World build (`b2-move-day`): RPE is a framed tag.
                Text("RPE \(rpe, specifier: "%.1g")")
                    .font(FernletFramedFont.buttonSmall)
                    .foregroundStyle(look.text)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .fernletFramed(look, cornerRadius: 8)
            } else if let rpe = workout.rpe {
                // The hues' TEXT inks: plain `moss` on its own 12% tint measured 3.44:1 (bundle 6,
                // 2026-10-20); `mossInk` and `terracottaInk` are the 4.5:1 text tokens for these hues.
                Text("RPE \(rpe, specifier: "%.1g")")
                    .font(.fernlet(.stat))
                    .foregroundStyle(rpe >= 8 ? Color.terracottaInk : Color.mossInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((rpe >= 8 ? Color.terracotta : Color.moss).opacity(0.12), in: Capsule())
            }
        }
    }

    /// Category, duration, distance, and intensity, all in the row's full-strength `slate`. The category
    /// used to be drawn in its accent hue, which as small text measured 3.95:1 for moss (bundle 6,
    /// 2026-10-20) and less for goldenrod and dusty rose; the word itself carries the category. The
    /// distance is stored in miles and read in the device's units ("3.1 mi", "5 km").
    private var metaRow: some View {
        HStack(spacing: look == nil ? 12 : 6) {
            Text(verbatim: category.displayName)
            if let duration = workout.duration { metaDot; Text("\(duration) min") }
            if let miles = workout.distanceMiles, miles > 0 {
                metaDot
                Text(verbatim: WorkoutMeasurementEntry.distanceText(miles: miles))
            }
            metaDot
            // Both halves of the fork are now localized: `WorkoutType.displayName` exists and this
            // site was still rendering the FROZEN `rawValue` beside the translated intensity word.
            Text(verbatim: workout.intensity.displayWord)
        }
        .font(look == nil ? .fernlet(.labelSmall) : FernletFramedFont.body)
        .foregroundStyle(look?.dim ?? Color.slate)
    }

    /// The World look's middle dot between the meta words (`b2-move-day`); nothing without it, where
    /// the wider spacing alone separates them. Never spoken.
    @ViewBuilder private var metaDot: some View {
        if look != nil { Text(verbatim: "·").accessibilityHidden(true) }
    }

    /// The logged exercise lines, the target summary, and any note.
    @ViewBuilder private var detailLines: some View {
        if !workout.displayedExerciseLines.isEmpty {
            VStack(spacing: 8) {
                ForEach(Array(workout.displayedExerciseLines.enumerated()), id: \.offset) { _, exercise in
                    WorkoutExerciseRow(exercise: exercise)
                }
            }
        }
        if !targetSummary.isEmpty {
            Text("Targets: \(targetSummary)")
                .font(look == nil ? .fernlet(.bodySmall) : FernletFramedFont.body)
                .foregroundStyle(look?.dim ?? Color.slate)
        }
        if !workout.notes.isEmpty {
            Text(workout.displayedNotes)
                .font(look == nil ? .fernlet(.bubble) : FernletFramedFont.body)
                .foregroundStyle(look?.dim ?? Color.slate)
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
            HStack(spacing: look == nil ? 10 : 18) {
                Button("Edit") { showEditSheet = true }
                    .font(look == nil ? .fernlet(.label) : FernletFramedFont.sheetControl)
                    .foregroundStyle(look?.link ?? Color.moss)
                    .fernletTapTarget()
                    .accessibilityIdentifier("workout.log.edit")
                Button("Remove", role: .destructive) { showRemoveConfirm = true }
                    .font(look == nil ? .fernlet(.label) : FernletFramedFont.sheetControl)
                    .foregroundStyle(look?.text ?? Color.terracottaInk)
                    .fernletTapTarget()
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
        .alert(removeAlertTitle, isPresented: $showRemoveConfirm) {
            Button(Self.keepItLabel, role: .cancel) {}
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
                .fernletSheet()
        }
    }
}

/// A small editor for an already-logged workout — the reversible half of the recoverability feature.
///
/// It edits the fields that make sense to correct after the fact (name, intensity, duration, notes)
/// and each lift's sets — reps, weight, how it felt and why it left the range (idea 6) — and reuses
/// the manual Log sheet's field idiom (`SheetField`, `SheetTextEditor`, chips, `SheetSaveBar`). A
/// corrected set rewrites the lift's structured record and its readable line together
/// (``WorkoutSetEditing``), and the load engine reads it from there, so a mis-tapped set no longer
/// skews the next prescription. Everything else — provenance (planned/guided/Health), targets,
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
    /// Each editable lift's sets (``WorkoutSetEditing/drafts(for:defaultUnit:)``), and what they were
    /// when the sheet opened — the save writes back only the lifts that changed.
    @State private var setDrafts: [ExerciseSetsDraft]
    private let originalSetDrafts: [ExerciseSetsDraft]
    @State private var showHealthRefusalAlert = false
    @State private var showDiscardConfirm = false
    /// The sheet's stack: the lift whose sets are open on their own page (`b3-workout-edit` draft 2).
    @State private var liftPath: [UUID] = []
    @Environment(\.fernletFramedLook) private var look

    init(store: FernletStore, workout: Workout, date: String, onSaved: @escaping () -> Void = {}) {
        self.store = store
        self.workout = workout
        self.date = date
        self.onSaved = onSaved
        // Drawn, not stored: a blank-named activity reads in the user's language, and `saveEdits`
        // hands the stored English default back unless the user actually renames it.
        _name = State(initialValue: workout.displayedName)
        _intensity = State(initialValue: workout.intensity)
        _duration = State(initialValue: workout.duration.map(String.init) ?? "")
        _rpe = State(initialValue: Self.rpeText(workout.rpe))
        _notes = State(initialValue: workout.notes)
        let drafts = WorkoutSetEditing.drafts(
            for: workout, defaultUnit: WorkoutLoadContextBuilder.defaultUnit(for: .current))
        _setDrafts = State(initialValue: drafts)
        originalSetDrafts = drafts
    }

    /// The RPE as the field shows it — "7", not "7.0" — and empty when the row carries none.
    private static func rpeText(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%g", value)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Any editable field diverges from the row this sheet opened on.
    private var isDirty: Bool {
        // The set drafts first, so this body always reads them: the lift pages pushed from it draw them,
        // and a page re-renders only when state this view read changes.
        setDrafts != originalSetDrafts
            || name != workout.displayedName
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
            TextField("e.g. Upper strength", text: $name, prompt: .fieldPrompt("e.g. Upper strength"))
                .sheetTextInput()
                .disabled(isGuided)
                .opacity(isGuided ? 0.55 : 1)
                .accessibilityIdentifier("workout.edit.name")
            if isGuided {
                Text("Name stays put — it's how your guided plan keeps track of this one.")
                    .font(look == nil ? .fernlet(.bodySmall) : FernletFramedFont.note)
                    .foregroundStyle(look?.dim ?? Color.slate)
                    .fernletWrappingText()
            }
        }
    }

    /// Light · Moderate · Hard (`b3-workout-edit` draft 2: "a framed three-way switch").
    private var intensityField: some View {
        SheetField("Intensity") {
            FernletSegmentedPicker("Intensity", selection: $intensity, options: WorkoutIntensity.allCases) { level in
                Text(verbatim: level.displayWord.localizedCapitalized)
            }
            .accessibilityIdentifier("workout.edit.intensity")
        }
    }

    /// Each editable lift — a guided lift, one logged set by set, or a hand-written line that reads
    /// as sets × reps — as one row; tapping one opens its sets on their own page (`b3-workout-edit`
    /// draft 2). Absent for a row with none (an activity, or a guided log from before load tracking,
    /// whose lines are the plan rather than a record).
    private var setsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Exercises").padding(.horizontal, 4)
            Text("Tap one to fix any set that went differently. Fernlet plans your next weights from these.")
                .font(FernletFramedFont.body)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()
                .padding(.horizontal, 4)
            FernletFramedSection {
                ForEach(setDrafts) { draft in
                    MoveLiftListRow(name: ExerciseHowToCatalog.displayName(for: draft.name),
                                    detail: WorkoutSetSummary.line(for: draft),
                                    color: WorkoutExerciseCatalog.exercise(named: draft.name)?.category.color ?? Color.moss,
                                    identifier: "workout.edit.lift") { liftPath = [draft.id] }
                }
            }
        }
    }

    /// One lift's sets on their own page, edited in place; Back returns to the list, Save keeps them.
    @ViewBuilder private func liftPage(_ id: UUID) -> some View {
        if let index = setDrafts.firstIndex(where: { $0.id == id }) {
            let current = setDrafts[index]
            MoveLiftPage(title: Text(verbatim: ExerciseHowToCatalog.displayName(for: current.name)),
                         subtitle: Text("Change only the sets that went differently."), buttonLabel: nil,
                         back: Text("Edit workout")) {
                // By id, never `$setDrafts[index]`, so a page still leaving the stack never reads past the list.
                ExerciseSetsEditor(draft: Binding(get: { setDrafts.first { $0.id == id } ?? current },
                                                  set: { updated in
                                                      guard let at = setDrafts.firstIndex(where: { $0.id == id }) else { return }
                                                      setDrafts[at] = updated
                                                  }),
                                   identifier: "workout.edit.sets.\(index)")
            }
        }
    }

    /// Writes the edited fields back through the store.
    ///
    /// Consumes the store's refusal Bool: on a refusal (a genuine Health import) keep the sheet open
    /// and explain, rather than dismissing as if the edit saved.
    private func saveEdits() {
        guard !trimmedName.isEmpty else { return }
        // Corrected sets first: each changed lift's record and its line, rewritten together.
        var updated = WorkoutSetEditing.applying(setDrafts, original: originalSetDrafts, to: workout)
        updated.name = workout.savedName(editing: trimmedName)
        updated.intensity = intensity
        updated.duration = WorkoutSheetRules.durationMinutes(from: duration)
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
        // World build (`b3-workout-edit` draft 2): a stack, so a lift's sets open on their own page.
        NavigationStack(path: $liftPath) {
            listPage
                .navigationTitle(Text("Edit workout"))
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: UUID.self) { liftPage($0) }
        }
        .keyboardDoneToolbar()
        .interactiveDismissDisabled(isDirty)
        .discardConfirmation(isPresented: $showDiscardConfirm) { dismiss() }
        .alert("This one lives in Apple Health", isPresented: $showHealthRefusalAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("It came from Health, so manage it in the Health app.")
        }
    }

    /// The sheet's list page: the header (Cancel and the title in the sheet), the fields, the lifts, Save.
    private var listPage: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    nameField

                    intensityField

                    HStack(alignment: .top, spacing: 12) {
                        SheetField("RPE (1–10)", namesControl: true) {
                            TextField("7", text: $rpe, prompt: .fieldPrompt("7"))
                                .keyboardType(.numberPad)
                                .sheetTextInput(font: .fernlet(.label))
                                .accessibilityIdentifier("workout.edit.rpe")
                        }
                        SheetField("Duration (min)", namesControl: true) {
                            TextField("45", text: $duration, prompt: .fieldPrompt("45"))
                                .keyboardType(.numberPad)
                                .sheetTextInput(font: .fernlet(.label))
                                .accessibilityIdentifier("workout.edit.duration")
                        }
                    }

                    if !setDrafts.isEmpty {
                        setsSection
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
        .background((look?.paper ?? Color.parchment).ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            SheetHeader(title: Text("Edit workout"), onCancel: attemptCancel)
        }
        .accessibilityAction(.escape) { attemptCancel() }
    }
}

/// One checked-off exercise line inside a logged ``WorkoutRow``.
///
/// Pure display — a checkmark glyph beside the free-text exercise summary the workout was logged
/// with.
struct WorkoutExerciseRow: View {
    var exercise: String
    /// World build (`b2-move-day`): a framed row with a moss pixel tick.
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        if let look {
            HStack(spacing: 10) {
                WorldSpriteView(sprite: WorldSprites.check, scale: 2, tint: WorldPalette.mossInk)
                Text(WorkoutMeasurementEntry.drawnLine(exercise))
                    .font(FernletFramedFont.rowTitle)
                    .foregroundStyle(look.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(look.raised, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
        } else {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.moss)
                // The stored line is frozen plan text; it is drawn with the planner's descriptors in the
                // user's language and a treadmill's mph in km/h on a metric device.
                Text(WorkoutMeasurementEntry.drawnLine(exercise))
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        }
    }
}

/// The read-only "Category · Auto" strip in the Log sheet showing the inferred workout category.
///
/// The category is derived live from the typed name and exercises (see
/// `WorkoutSheet.inferredCategory`), so this preview is how the user sees what the log will be
/// classified as before saving. Every word is inked at text contrast; the category's accent colour
/// is carried by the dot and the "Auto" capsule's tint only.
struct WorkoutCategoryPreview: View {
    var category: WorkoutType

    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        HStack(spacing: 10) {
            if look != nil {
                MoveSwatch(color: category.color, size: 12)
            } else {
                Circle()
                    .fill(category.color)
                    .frame(width: 10, height: 10)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Category")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(look?.dim ?? Color.slate)
                // `displayName`, not `rawValue`: the raw value is the persisted category token.
                Text(verbatim: category.displayName)
                    .font(.fernlet(.body))
                    .foregroundStyle(look?.text ?? Color.bark)
            }
            Spacer()
            // A text ink, not the category's accent hue: on its own 12% tint over cream the hue
            // measured 3.50:1 (moss), 2.17:1 (goldenrod), 3.11:1 (dusty rose) and 3.84:1 (terracotta),
            // and 3.83:1 for dark terracotta (2026-10-20). `slate` falls short on that tint too (4.40:1
            // on terracotta) and dusty rose has no ink token, so the word takes `bark` — 9.8:1 or
            // better on every tint in both appearances. The dot and the tint keep the category's colour.
            Text("Auto")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.bark)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(category.color.opacity(0.12), in: Capsule())
        }
        .padding(14)
        .modifier(MoveInsetCardFrame())
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
    ///
    /// The count word is a catalog key with the number as an ARGUMENT, not an English `"s"` glued
    /// on at runtime (review A4 follow-up F4): the ternary produced a string no translator ever
    /// sees, welded to a two-form plural rule that most languages do not have. The `%lld` slot lets
    /// the catalog carry as many plural variations as a language needs.
    static func text(selectedGoal: GoalType, goalCount: Int) -> String {
        guard goalCount > 0 else { return selectedGoal.displayName }
        let goals = String(localized: "move.goalCount", defaultValue: "\(goalCount) goals",
                           comment: "Goal count in the Move header's goal segment, e.g. '3 goals'. Needs a plural variation per language; English also needs the one-goal form.")
        return "\(selectedGoal.displayName) · \(goals)"
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
    @Environment(\.fernletFramedLook) fileprivate var look

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
            ? "\(location.displayedName) · \(count)"
            : "\(location.displayedName) · \(count) items"
    }

    /// Spoken when no movement goal is set. A shared constant rather than an inline `??` literal:
    /// a fallback written inside an interpolation never reaches the catalog (review T2-1).
    static var goalNotSet: String {
        String(localized: "move.goal.notSet", defaultValue: "not set",
               comment: "Spoken in place of the movement goal when the user has not set one. Reads inside the sentence 'Goal, …'.")
    }

    /// Always the full, unabbreviated sentence — VoiceOver has no width to run out of.
    ///
    /// Stays a `String` because it is spliced into the `%@` slot of the segment's own
    /// `.accessibilityLabel` key — but a LOCALIZED one now (T2-1): the count word was frozen
    /// English inside an otherwise translated sentence.
    private var spaceAccessibilityValue: String {
        String(localized: "move.space.accessibilityValue",
               defaultValue: "\(location.displayedName), \(location.ownedEquipment.count) items",
               comment: "Spoken value of the Move header's space segment: the training location's name and how many pieces of equipment it has.")
    }

    var body: some View {
        // Side by side, each half was ~130pt wide, and at accessibility sizes two lines of it
        // truncated even the shortened "Full gym · 22". Stacked, each value has the full width.
        AdaptiveStack(spacing: 0, horizontalAlignment: .leading) {
            MoveContextSegment(
                icon: "target",
                sprite: WorldSprites.target,
                label: "Goal",
                value: goalValue,
                emptyPrompt: "Tap to plan",
                action: onEditGoal
            )
            // Both segments announce label + current value, then what a tap does — the Goal segment
            // used to announce only the action (never the goal) and Space only the value (never that
            // it opens anything).
            .accessibilityLabel("Goal, \(goalValue ?? MoveContextStrip.goalNotSet)")
            .accessibilityHint("Opens your movement goals")
            // T2-12: the label above is a whole SENTENCE that ends in the user's own goal, so a
            // Voice Control user had to say "tap Goal, build strength, three goals" to reach it.
            // Input labels are ADDITIVE — the spoken label is unchanged — and are listed
            // shortest-first because the first one is what the numbered overlay shows.
            .accessibilityInputLabels([Text("Goal"), Text("Goals"), Text("Movement goal")])

            divider

            MoveContextSegment(
                icon: "mappin.and.ellipse",
                sprite: WorldSprites.pin,
                label: "Space",
                value: spaceValue,
                emptyPrompt: "Set up your space",
                action: onEditSpace
            )
            .accessibilityLabel("Space, \(spaceAccessibilityValue)")
            .accessibilityHint("Opens where you train")
            // T2-12, as for the Goal segment: the label carries the location NAME and an item
            // count, neither of which anyone wants to speak to tap a button.
            .accessibilityInputLabels([Text("Space"), Text("Where you train")])
            // Stable id: the label is the location's NAME, which the user can now rename, so a test that
            // matched on it would break the moment it exercised the rename it's there to check.
            .accessibilityIdentifier("move.space")
        }
        .modifier(MoveContextStripFrame())
    }
}

/// The context strip's card: World build, one framed paper card (`b2-move-root`: "the goal and space
/// sit side by side in one framed card"); today, the quiet cream strip.
private struct MoveContextStripFrame: ViewModifier {
    @Environment(\.fernletFramedLook) private var look

    func body(content: Content) -> some View {
        if let look {
            let shape = RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius, style: .continuous)
            content
                .padding(.vertical, 2)
                .background(look.paper, in: shape)
                .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
                .background { shape.fill(look.shadow).offset(y: 3) }
        } else {
            content
                .background(Color.cream.opacity(0.86), in: RoundedRectangle(cornerRadius: FernletMetrics.radiusSm))
                .overlay(RoundedRectangle(cornerRadius: FernletMetrics.radiusSm).stroke(Color.bark.opacity(0.08), lineWidth: 1))
        }
    }
}

extension MoveContextStrip {
    /// The hairline between the two segments: vertical beside them, horizontal once they stack.
    /// The World card draws no line beside them (`b2-move-root`), a dotted rule once they stack.
    @ViewBuilder fileprivate var divider: some View {
        if look != nil {
            if dynamicTypeSize.isAccessibilitySize { FernletDottedRule().padding(.horizontal, 14) }
        } else if dynamicTypeSize.isAccessibilitySize {
            Rectangle()
                .fill(Color.bark.opacity(0.10))
                .frame(height: 1)
                .padding(.horizontal, 14)
        } else {
            Rectangle()
                .fill(Color.bark.opacity(0.10))
                .frame(width: 1)
                .padding(.vertical, 10)
        }
    }
}

/// One tappable half of the context strip: a small uppercase label over a value line, with a
/// leading icon.
///
/// Each segment truncates independently; the icon never clips. A nil value renders the italic empty
/// prompt so a first-run segment reads as an invitation, not a set value.
private struct MoveContextSegment: View {
    var icon: String
    /// The World build's pixel icon in place of `icon` (`b2-move-root`).
    var sprite: WorldSprite
    /// The uppercase caption. `LocalizedStringKey`: both callers pass a literal, which the `String`
    /// this used to be kept out of the catalog (so `.textCase` ran on English).
    var label: LocalizedStringKey
    /// The set value (user data or an already-localized summary); nil shows the italic empty prompt.
    var value: String?
    /// The italic invitation shown while unset; a literal at both callers.
    var emptyPrompt: LocalizedStringKey
    var action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Two lines below accessibility sizes; unlimited at them, where the strip stacks and each
    /// value has the whole width to wrap in.
    private var valueLineLimit: Int? { dynamicTypeSize.isAccessibilitySize ? nil : 2 }

    @Environment(\.fernletFramedLook) private var look

    /// The segment's icon: the pixel sprite under the World look, today's symbol without it.
    @ViewBuilder private var iconView: some View {
        if look != nil {
            WorldSpriteView(sprite: sprite, scale: 2)
        } else {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(value == nil ? Color.slate : Color.moss)
        }
    }

    /// The caption: under the World look the section label's small framed square before the word.
    private var caption: some View {
        HStack(spacing: 6) {
            if let look {
                look.mark.frame(width: 7, height: 7).padding(2).background(look.ink).accessibilityHidden(true)
            }
            // `.textCase` on a `LocalizedStringKey` caption: the transform runs after the
            // catalog lookup, on the translation. (F5: as a `String` parameter it ran on
            // nothing, because a `String` never reaches the catalog at all.)
            Text(label)
                .textCase(.uppercase)
                .font(look == nil ? .fernlet(.labelSmall) : MoveFont.caption)
                .tracking(0.6)
                .foregroundStyle(look?.text ?? Color.slate)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                iconView
                VStack(alignment: .leading, spacing: 2) {
                    caption
                    if let value {
                        Text(value)
                            // Two lines, not one: at default size an accepted goal already truncated
                            // to "Complete 3 gene…" with no way to read the rest. The World card's value
                            // is the kit's 15-pt strong face, so "Full gym · 22 items" fits its half.
                            .font(look == nil ? .fernlet(.label) : MoveFont.body)
                            .foregroundStyle(look?.text ?? Color.bark)
                            .lineLimit(valueLineLimit)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(emptyPrompt)
                            .font(look == nil ? .fernlet(.bubble) : FernletFramedFont.body)
                            .foregroundStyle(look?.dim ?? Color.slate)
                            .lineLimit(valueLineLimit)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, look == nil ? 14 : 12)
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
    /// The structured record of a lift entered set by set in the Log sheet (idea 6); nil for every
    /// free-text row. When set, the row's line is the record's own ``ExerciseResult/loggedLine``, so
    /// the readable log and the record cannot disagree.
    var result: ExerciseResult? = nil

    /// The row's line without its name, for the added-row card ("3 x 8 @ 100 lb (did 8, 8, 6)").
    var detailSummary: String {
        guard let result else {
            return summary.replacingOccurrences(of: exercise.name, with: "").trimmingCharacters(in: .whitespaces)
        }
        let line = result.loggedLine
        let prefix = "\(result.name) - "
        guard line.hasPrefix(prefix) else { return line }
        return String(line.dropFirst(prefix.count))
    }

    var summary: String { summaryLine(imperial: nil) }

    /// ``summary`` on a device that reads miles (`true`), kilometres (`false`), or this one (nil). The
    /// line always stores a treadmill speed in mph: on a metric device the typed km/h is converted
    /// (``WorkoutMeasurementEntry/storedSpeed(fromEntry:imperial:)``), and screens read it back in km/h.
    /// A lift entered set by set is its record's own line.
    func summaryLine(imperial: Bool?) -> String {
        if let result { return result.loggedLine }
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
            if !cleanSpeed.isEmpty {
                parts.append("\(WorkoutMeasurementEntry.storedSpeed(fromEntry: cleanSpeed, imperial: imperial)) mph")
            }
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
    /// Catalog keys. Both sheets show the builder only while the Kind is strength, so they take these
    /// defaults. `WorkoutMode` once carried English `String` copies of all three; nothing read them
    /// after the field-title round, and they were deleted rather than localized.
    var pickerTitle: LocalizedStringKey = "Exercise"
    var searchPlaceholder: LocalizedStringKey = "Search exercise or muscle"
    var mode: WorkoutMode = .strengthTraining
    var addLabel: LocalizedStringKey = "Add exercise"
    var showAddButton = true
    /// Forwarded to ``ExerciseSearchPicker`` — see there.
    var autofocusSearch = false
    /// Backs the "last time" recall line with the store's logged day history; `nil` (the default)
    /// hides the line entirely, so call sites without a store are untouched.
    var historyStore: FernletStore? = nil
    /// Draws the Sets / Reps / Weight / Details fields for a strength pick. The Log sheet turns it off
    /// while "Log set by set" is on, where per-set rows take their place.
    var showsStrengthFields = true
    /// Forwarded to ``ExerciseSearchPicker`` — lets a typed name stand as the exercise.
    var allowsTypedExercise = false
    /// Draws the search picker above the fields. Off on an exercise's own page (`b3-workout-exercise`),
    /// whose title already names the pick.
    var showsPicker = true
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
            SheetField("Sets", namesControl: true) {
                TextField("3", text: $sets, prompt: .fieldPrompt("3"))
                    .keyboardType(.numberPad)
                    .sheetTextInput(font: .fernlet(.label))
            }
            SheetField("Reps", namesControl: true) {
                TextField("8", text: $reps, prompt: .fieldPrompt("8"))
                    .keyboardType(.numberPad)
                    .sheetTextInput(font: .fernlet(.label))
            }
        }

        SheetField("Weight", namesControl: true) {
            TextField("30 lb", text: $weight, prompt: .fieldPrompt("30 lb"))
                .sheetTextInput()
        }

        SheetField("Details") {
            TextField("tempo, form note", text: $details, prompt: .fieldPrompt("tempo, form note"))
                .sheetTextInput()
        }
    }

    /// Speed / incline / details — the treadmill prescription fields.
    @ViewBuilder private var treadmillFields: some View {
        HStack(alignment: .top, spacing: 12) {
            // The speed is typed in the device's units; the saved line converts km/h to mph.
            SheetField("Speed", namesControl: true) {
                TextField(WorkoutMeasurementEntry.usesImperial ? "5.5 mph" : "9 km/h", text: $speed,
                          prompt: .fieldPrompt(WorkoutMeasurementEntry.usesImperial ? "5.5 mph" : "9 km/h"))
                    .keyboardType(.decimalPad)
                    .sheetTextInput(font: .fernlet(.label))
            }
            SheetField("Incline", namesControl: true) {
                TextField("2", text: $incline, prompt: .fieldPrompt("2"))
                    .keyboardType(.decimalPad)
                    .sheetTextInput(font: .fernlet(.label))
            }
        }

        SheetField("Details") {
            TextField("intervals, distance, notes", text: $details, prompt: .fieldPrompt("intervals, distance, notes"))
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
            if showsPicker {
                ExerciseSearchPicker(
                    selectedExercise: $selectedExercise,
                    resetToken: $resetToken,
                    title: pickerTitle,
                    placeholder: searchPlaceholder,
                    autofocus: autofocusSearch,
                    allowsTypedExercise: allowsTypedExercise
                )
            }

            if let lastTimeValues {
                Text("Last time: \(lastTimeValues)")
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                    .accessibilityIdentifier("exercise.lastTime")
            }

            switch inputKind {
            case .strength:
                if showsStrengthFields { strengthFields }
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
    var title: LocalizedStringKey = "Exercise"
    var placeholder: LocalizedStringKey = "Search exercise or muscle"
    /// Puts the keyboard in the search field as the sheet opens. Only the speed-first Quick exercise
    /// sheet asks for it — a sheet with fields above the picker shouldn't yank focus past them.
    var autofocus = false
    /// Offers the typed text itself as the exercise when no catalog name matches it — the Log sheet's
    /// set-by-set entry, where a lift outside the catalog can still be recorded. Off everywhere else.
    var allowsTypedExercise = false
    @FocusState private var searchFocused: Bool
    /// One in-flight result-count announcement at a time (T2-14) — the debounce itself. Held as
    /// state so a newer keystroke can cancel the pending one; see ``announceResultCount(_:)``.
    @State private var resultAnnouncementTask: Task<Void, Never>?

    /// Longest typed name taken as an exercise.
    static let maxTypedNameLength = 80

    private var results: [ExerciseTarget] {
        Array(WorkoutExerciseCatalog.search(query).prefix(8))
    }

    /// The typed text as an exercise of its own, when typed names are allowed and the text names no
    /// catalog exercise. It carries no muscles or gear: it is logged and recalled by name only.
    private var typedExercise: ExerciseTarget? {
        guard allowsTypedExercise, selectedExercise == nil else { return nil }
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= Self.maxTypedNameLength,
              WorkoutExerciseCatalog.exercise(named: name) == nil else { return nil }
        return ExerciseTarget(name: name, primaryMuscles: [])
    }

    /// "Use “Farmer's walk”" — picks the typed name as the exercise.
    private func typedExerciseRow(_ exercise: ExerciseTarget) -> some View {
        Button {
            selectedExercise = exercise
            query = exercise.name
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "pencil")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.moss)
                    .accessibilityHidden(true)
                Text("Use “\(exercise.name)”")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(minHeight: 44)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.bark.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        // Voice Control: the drawn label quotes whatever was typed; "Use typed name" always works.
        .accessibilityInputLabels([Text("Use typed name")])
        .accessibilityIdentifier("exercise.useTyped")
    }

    /// The count worth SPEAKING, or `nil` when there is nothing to say.
    ///
    /// Not the same thing as `results.count`, which is what the list draws. A blank query returns
    /// the whole catalog (`WorkoutExerciseCatalog.search` trims and returns everything for `""`),
    /// so the picker opens with eight rows the user never asked for — announcing that on appear
    /// would speak a number nobody searched for. And once an exercise is picked the list is gone,
    /// but selecting also writes the exercise's name into `query`, so a plain count would fire
    /// again for a list that is no longer on screen.
    private var speakableResultCount: Int? {
        guard selectedExercise == nil else { return nil }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return results.count
    }

    /// The plural-correct "8 exercises" sentence, used both as the results list's spoken value and
    /// as the announcement — one key, so there is one plural rule to translate rather than two.
    ///
    /// A catalog key with the number as an ARGUMENT, never an English `"s"` glued on in Swift: a
    /// `count == 1 ? "exercise" : "exercises"` ternary welds the app to a two-form plural rule most
    /// languages do not have, and produces a string no translator ever sees. ``MoveGoalSummary``
    /// earlier in this file carries the full record of that fix.
    private static func resultCountText(_ count: Int) -> String {
        String(localized: "exercise.search.resultCount", defaultValue: "\(count) exercises",
               comment: "Spoken count of exercise search results, e.g. '8 exercises'. Needs a plural variation per language; English also needs the one-exercise form.")
    }

    /// Speaks how many exercises the search now matches — debounced twice over, because a search
    /// field fires on every keystroke and one announcement per keystroke is worse than none.
    ///
    /// The first gate is the `.onChange` this is called from: it watches the COUNT, not the query,
    /// so the four keystrokes of "squa" that all leave eight results standing say nothing at all.
    /// The second is the sleep below: a burst that walks the count 8 → 5 → 3 speaks only "3
    /// exercises", because each new count cancels the announcement the previous one scheduled. A
    /// cancelled sleep simply ends the superseded task — the same shape `SettingsSheet` uses for
    /// its reminder reschedule.
    ///
    /// A count, never a result: an announcement is spoken aloud into the room, and the announcer's
    /// standing rule is to announce the event and not the payload.
    private func announceResultCount(_ count: Int?) {
        resultAnnouncementTask?.cancel()
        guard let count else { return }
        resultAnnouncementTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return  // superseded by a newer keystroke (or the picker went away)
            }
            guard !Task.isCancelled else { return }
            FernletAnnouncer.system.announce(.status, resolved: Self.resultCountText(count))
        }
    }

    /// Return picks the top result instead of doing nothing — typing "squat" then Return used to
    /// leave the user reaching back up to tap the row they'd already named.
    private func selectFirstResult() {
        guard selectedExercise == nil, let first = results.first else { return }
        selectedExercise = first
        query = first.displayName
        searchFocused = false
    }

    var body: some View {
        SheetField(title) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.slate)
                    TextField(placeholder, text: $query, prompt: .fieldPrompt(placeholder))
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
                                query = exercise.displayName
                            }
                        }
                    }
                    // T2-14's persistent half: the count as a value on the list itself, so a user
                    // who missed (or turned off) the announcement can still swipe to it and hear
                    // how many rows follow. `.contain`, NOT `.combine` — the rows stay individually
                    // navigable — and the `.accessibilityElement` is load-bearing: without it the
                    // value propagates DOWN and stamps "8 exercises" onto every single row.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Text("Exercise results"))
                    .accessibilityValue(Text(verbatim: Self.resultCountText(results.count)))

                    if let typedExercise {
                        typedExerciseRow(typedExercise)
                    }
                }
            }
        }
        .onChange(of: resetToken) { _, _ in
            query = ""
        }
        // Watches the COUNT, not the query: keystrokes that leave the same number of matches
        // standing are silent. See ``announceResultCount(_:)`` for the second gate.
        .onChange(of: speakableResultCount) { _, count in
            announceResultCount(count)
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
    /// World build (`b3-exercise-swap`): the row sits in a shared framed card, which draws the frame and
    /// the dotted rules, so the row draws none of its own.
    var inCard = false
    var action: () -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Button(action: action) {
            HStack(alignment: look == nil ? .top : .center, spacing: 10) {
                if look != nil {
                    MoveSwatch(color: exercise.category.color, size: 14)
                } else {
                    Circle()
                        .fill(exercise.category.color)
                        .frame(width: 9, height: 9)
                        .padding(.top, 5)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: exercise.displayName)
                        .font(look == nil ? .fernlet(.body) : MoveFont.rowTitle)
                        .foregroundStyle(look?.text ?? Color.bark)
                    // `displayName`, not `rawValue` — the seventh site of this class in this file.
                    // The harvested key here is "%@ - %@", so the row LOOKS localized while its
                    // first argument is the frozen persisted category token.
                    Text("\(exercise.category.displayName) - \(exercise.muscles.joined(separator: ", "))")
                        .font(look == nil ? .fernlet(.labelSmall) : FernletFramedFont.rowDetail)
                        .foregroundStyle(look?.dim ?? Color.slate)
                }
                Spacer()
                rowGlyph
            }
            .padding(inCard ? 0 : 10)
            .padding(.vertical, inCard ? 8 : 0)
            .modifier(SearchRowFrame(isFramed: !inCard))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Voice Control: the row's name runs on through its category and every muscle it works;
        // the exercise's name is what a user says.
        .accessibilityInputLabels([Text(verbatim: exercise.displayName)])
    }

    /// The trailing glyph: a framed pixel + (or ✕ to clear the pick) under the World look, today's symbol.
    @ViewBuilder private var rowGlyph: some View {
        if look != nil {
            FernletIconTile(size: 32) { FernletIcon(isSelected ? .close : .plus, scale: 2) }
        } else {
            Image(systemName: isSelected ? "xmark.circle" : "plus.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Color.slate : Color.moss)
        }
    }
}

/// A search result row's own card when it stands alone (World: framed paper; today: cream with a
/// hairline), or nothing when a shared card holds it.
private struct SearchRowFrame: ViewModifier {
    let isFramed: Bool

    func body(content: Content) -> some View {
        if isFramed {
            content.modifier(MoveInsetCardFrame(cornerRadius: 10))
        } else {
            content
        }
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
                Text(verbatim: entry.exercise.displayName)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                Text(WorkoutMeasurementEntry.displayedSpeeds(in: entry.detailSummary))
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
            .fernletIconButton("Remove \(entry.exercise.displayName)")
            // T2-12: the spoken name interpolates the exercise, so a Voice Control user had to
            // say "tap remove barbell back squat". Duplicate short names across rows are fine —
            // Voice Control numbers ambiguous matches.
            .accessibilityInputLabels([Text("Remove")])
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
    /// The name, muscles and ✕ on a card. Off on the exercise's own page (`b3-workout-plan` draft 2),
    /// whose title names it and which ends with Remove.
    var showsHeader = true
    var onRemove: () -> Void
    var onChange: () -> Void

    var body: some View {
        if showsHeader {
            fields
                .padding(14)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
        } else {
            VStack(alignment: .leading, spacing: 18) {
                Text(entry.exercise.muscles.joined(separator: ", "))
                    .font(FernletFramedFont.body)
                    .foregroundStyle(entry.exercise.category.color)
                fields
                Button(role: .destructive, action: onRemove) { Text("Remove").frame(maxWidth: .infinity) }
                    .buttonStyle(ActionPillButtonStyle(.destructive))
                    .accessibilityIdentifier("plan.removeExercise")
            }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: entry.exercise.displayName)
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
                    .fernletIconButton("Remove \(entry.exercise.displayName)")
                    // T2-12, as on ``LoggedExerciseRow``.
                    .accessibilityInputLabels([Text("Remove")])
                }
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
    }

    @Environment(\.fernletFramedLook) private var look

    private func editableField(
        _ label: LocalizedStringKey,
        text: Binding<String>,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(look?.dim ?? Color.slate)
            TextField(label, text: text, prompt: .fieldPrompt(label))
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
    // Read ONCE for the whole card and handed to the legend swatches; ``WorkoutCalendarCell`` reads
    // it once for itself. See ``WorkoutCategoryMark`` for what the flag changes.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

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

    /// World build (`b2-move-root`): pixel chevrons, a Fraunces week title, framed day cells.
    @Environment(\.fernletFramedLook) private var look

    /// One week-step chevron: pixel under the World look, the symbol without it.
    private func weekStepButton(forward: Bool) -> some View {
        Button {
            displayedWeek = cal.date(byAdding: .weekOfYear, value: forward ? 1 : -1, to: displayedWeek) ?? displayedWeek
        } label: {
            Group {
                if look != nil {
                    FernletIcon(forward ? .chevron : .back)
                } else {
                    Image(systemName: forward ? "chevron.right" : "chevron.left")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.slate)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(forward ? Text("Next week") : Text("Previous week"))
    }

    var body: some View {
        let model = WorkoutWeekModel(date: displayedWeek, allDays: allDays, todayKey: todayKey)
        return FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    weekStepButton(forward: false)
                    Text(model.weekTitle)
                        .font(look == nil ? .fernlet(.headerMedium) : .custom(FernletFontName.frauncesSemiBold, size: 19, relativeTo: .title3))
                        .foregroundStyle(look?.text ?? Color.bark)
                        .frame(maxWidth: .infinity)
                    weekStepButton(forward: true)
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
    ///
    /// Under **Differentiate Without Color** the swatch becomes the same filled shape the day cells
    /// draw for that split's category, so the legend stays a working key: without it the cells
    /// would show shapes the legend explained only in hue. The default swatch is untouched.
    private var workoutLegend: some View {
        FlowLayout(spacing: 10) {
            ForEach(legendSplits) { split in
                HStack(spacing: 4) {
                    if differentiateWithoutColor {
                        Image(systemName: split.workoutType.differentiatingShapeFilled)
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(split.color)
                            .frame(width: 10, height: 10)
                    } else if look != nil {
                        // `.legend i`: a pixel square in an ink frame.
                        MoveSwatch(color: split.color, size: 9)
                    } else {
                        Circle().fill(split.color).frame(width: 8, height: 8)
                    }
                    Text(split.title).font(.fernlet(.labelSmall)).foregroundStyle(look?.dim ?? Color.slate)
                }
                .fixedSize()
            }
        }
    }
}

/// The shape vocabulary that stands in for hue when **Differentiate Without Color** is on.
///
/// `WorkoutType.color` maps eight categories onto four tints — `.upper`/`.armsBack`/`.mixed` are
/// all moss and `.cardio`/`.run`/`.hike` are all terracotta — so hue cannot separate them even in
/// principle, before colour blindness is considered at all. These symbols can.
///
/// The four *current* categories (see `WorkoutType.allCases`, which deliberately omits the legacy
/// four) take the four shapes that stay legible at 8pt: triangle, square, diamond, circle. The
/// legacy categories, which surface only on history rows old enough to still carry them, take the
/// remaining shapes — mutually confusable at that size, but never confusable with the four that
/// matter. Every symbol here has both an outline and a `.fill` variant, which is what carries the
/// planned-vs-logged distinction.
private extension WorkoutType {
    /// The outline symbol for this category — drawn for a PLANNED workout.
    var differentiatingShape: String {
        switch self {
        case .upper: "triangle"
        case .lower: "square"
        case .fullBody: "diamond"
        case .cardio: "circle"
        case .armsBack: "star"
        case .mixed: "seal"
        case .run: "capsule"
        case .hike: "hexagon"
        }
    }

    /// The filled variant of ``differentiatingShape`` — drawn for a LOGGED workout.
    var differentiatingShapeFilled: String { "\(differentiatingShape).fill" }
}

/// One category mark inside a ``WorkoutCalendarCell``'s day tile, and in the card's legend.
///
/// Two renderings of the same fact, chosen by the environment and nothing else. By default it is
/// the 5pt hue-filled dot the artboards specify — solid for a logged workout, `.opacity(0.38)` for
/// a planned one. That default branch is untouched by this type's existence and must stay so.
///
/// Under **Differentiate Without Color** it becomes a per-category SF Symbol (see
/// ``WorkoutType/differentiatingShape``), filled for logged and hollow for planned, so neither the
/// category nor the logged/planned distinction rests on hue. The opacity channel it replaces was
/// never a real second channel anyway: a 38%-alpha 5pt dot is below the discrimination threshold
/// for most low-vision users regardless of how they see colour.
private struct WorkoutCategoryMark: View {
    /// The category this mark stands for.
    var category: WorkoutType
    /// `true` for a workout that is only planned, `false` for one already logged.
    var planned: Bool
    /// Passed in rather than read here, so the environment is read once per cell instead of once
    /// per dot.
    var differentiateWithoutColor: Bool
    /// World build: the mark is a pixel square (`.cal span.dot`), not a dot.
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        if differentiateWithoutColor {
            Image(systemName: planned ? category.differentiatingShape : category.differentiatingShapeFilled)
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(category.color)
                .frame(width: 8, height: 8)
        } else if look != nil {
            Rectangle()
                .fill(planned ? category.color.opacity(0.38) : category.color)
                .frame(width: 5, height: 5)
        } else {
            Circle()
                .fill(planned ? category.color.opacity(0.38) : category.color)
                .frame(width: 5, height: 5)
        }
    }
}

/// One tappable day cell in the calendar week strip.
///
/// Pure rendering of a ``WorkoutWeekCell`` — fill, today ring, logged (solid) and planned (faded)
/// category marks, and the log/plan/rest summary line.
///
/// The body was already at the Power-of-10 length ceiling, so the tile, its contents, the marks
/// and the caption were extracted into computed properties before the Differentiate-Without-Color
/// branch and the accessibility attachments were added.
struct WorkoutCalendarCell: View {
    var cell: WorkoutWeekCell
    var onTap: () -> Void
    // 1a·AX3: the per-day caption ("Rest" / "1 log" / "1 plan") is dropped at accessibility sizes
    // so the day tile itself stays legible; VoiceOver still gets the full label.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // Read ONCE per cell and handed down to every mark — see ``WorkoutCategoryMark``.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    /// World build (`b2-move-root`): framed day cells, today outlined in ink.
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                Text(cell.weekdayText)
                    .font(look == nil ? .fernlet(.labelSmall) : MoveFont.caption)
                    .foregroundStyle(look?.dim ?? Color.slate)
                dayTile
                if !dynamicTypeSize.isAccessibilitySize {
                    summaryLine
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(cell.accessibilityLabel)
        // T2-2: ``summaryLine`` is deleted from the layout at accessibility sizes, and an undrawn
        // view is an absent accessibility element — so the counts vanished from speech too. (They
        // were never in the utterance at any size, in fact: the explicit label above replaces the
        // derived one.) Re-attached on the More Content rotor as its own sentence rather than the
        // drawn `summaryText`, which only has room for the logs on a mixed day.
        .accessibilityCustomContent("Summary", cell.accessibilitySummary)
        // T2-12: the label is a sentence ending in the day's categories.
        .accessibilityInputLabels([Text("Day \(cell.day)")])
    }

    /// The rounded day tile: fill, today ring, the day numeral and the category marks.
    @ViewBuilder private var dayTile: some View {
        if let look {
            // `.cal span`: recessed paper, today raised in a 2-pt ink frame, a day ahead unfilled.
            RoundedRectangle(cornerRadius: 7)
                .fill(cell.isFuture ? Color.clear : (cell.isToday ? look.raised : look.paperLow))
                .overlay {
                    if cell.isToday { RoundedRectangle(cornerRadius: 7).strokeBorder(look.ink, lineWidth: 2) }
                }
                .overlay { tileContents }
                .frame(height: 46)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(cell.fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(cell.isToday ? Color.moss : Color.clear, lineWidth: 1.5)
                )
                .overlay { tileContents }
                .frame(height: 46)
        }
    }

    /// What sits inside the tile: the day numeral over the category marks.
    ///
    /// Full-strength `bark` on every day, because it is the only ink that clears 4.5:1 on every
    /// fill a tile can take: the worst is goldenrod at 34% in dark mode, 6.13:1. The numeral used to
    /// carry the day's state in its alpha — 68% bark behind today (4.32:1 on the taupe tile), 28%
    /// ahead of it, and moss on today (2.54:1 on today's moss fill) — and all three failed. Today
    /// is still marked by its moss ring and fill; a day ahead of today is quieted by the smaller,
    /// lighter `labelSmall` face instead of by a fainter ink.
    private var tileContents: some View {
        VStack(spacing: 4) {
            Text("\(cell.day)")
                .font(.fernlet(cell.isFuture ? .labelSmall : .stat))
                .fontWeight(look != nil && cell.isToday ? .bold : nil)
                .foregroundStyle(look.map { cell.isFuture ? $0.dim : $0.text } ?? Color.bark)
            categoryMarks
        }
    }

    /// Up to three marks: logged categories first, then planned ones into whatever room is left.
    ///
    /// The two ``WorkoutCategoryMark``s differ only in `planned`, which is drawn as an opacity
    /// step by default and as filled-vs-hollow under Differentiate Without Color.
    @ViewBuilder private var categoryMarks: some View {
        if !cell.categories.isEmpty || !cell.plannedCategories.isEmpty {
            HStack(spacing: 2) {
                ForEach(Array(cell.categories.prefix(3).enumerated()), id: \.offset) { _, category in
                    WorkoutCategoryMark(category: category, planned: false,
                                        differentiateWithoutColor: differentiateWithoutColor)
                }
                ForEach(Array(cell.plannedCategories.prefix(max(0, 3 - cell.categories.count)).enumerated()), id: \.offset) { _, category in
                    WorkoutCategoryMark(category: category, planned: true,
                                        differentiateWithoutColor: differentiateWithoutColor)
                }
            }
        }
    }

    /// The per-day caption under the tile, dropped at accessibility sizes (1a·AX3).
    private var summaryLine: some View {
        Text(cell.summaryText)
            .font(.fernlet(.labelSmall))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(look?.dim ?? Color.slate)
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

    /// The tile's drawn count line, localized (2026-10-20): the counts are plural-ruled keys rather
    /// than an English "1 plan" / "N plans" branch.
    var summaryText: String {
        if workoutCount == 0 && plannedCount == 0 {
            return String(localized: "move.week.cell.rest", defaultValue: "Rest",
                          comment: "Move tab week strip: a day tile with nothing logged or planned")
        }
        if workoutCount == 0 {
            return String(localized: "move.week.cell.plans", defaultValue: "\(plannedCount) plans",
                          comment: "Move tab week strip: a day tile's count of planned workouts. Needs a plural variation.")
        }
        return String(localized: "move.week.cell.logs", defaultValue: "\(workoutCount) logs",
                      comment: "Move tab week strip: a day tile's count of logged workouts. Needs a plural variation.")
    }

    /// `Text` rather than `String` (review T2-1), and `displayName` rather than `rawValue`.
    ///
    /// The `rawValue` was a real defect, not a style point: `WorkoutType.rawValue` is the FROZEN
    /// persisted category token, so VoiceOver was reading storage vocabulary aloud and would keep
    /// reading English out of a fully translated screen. `displayName` is the reader-facing half
    /// that already exists for exactly this.
    ///
    /// Two further corrections, both from the Differentiate-Without-Color work: the day that also
    /// has a plan on it now says so — the previous branching spoke the plan ONLY on a day with
    /// nothing logged, so on a mixed day the plan was silent — and the weekday comes from
    /// `longWeekdayText` ("Wed"), not the drawn `weekdayText`, which is the NARROW symbol ("W")
    /// and is read out as a single letter. The word "planned" is the channel a blind user has for
    /// the logged/planned distinction that sighted users get from the mark's fill, so it is stated
    /// whether or not anything is also logged.
    var accessibilityLabel: Text {
        let dayName = isToday ? Text("Today") : Text(verbatim: longWeekdayText)
        let categoryText = categories.map(\.displayName).joined(separator: ", ")
        let planText = plannedSplits.map(\.title).joined(separator: ", ")
        if !categoryText.isEmpty && !planText.isEmpty {
            return Text("\(dayName), day \(day), \(categoryText), planned \(planText)")
        }
        if !categoryText.isEmpty {
            return Text("\(dayName), day \(day), \(categoryText)")
        }
        if !planText.isEmpty {
            return Text("\(dayName), day \(day), planned \(planText)")
        }
        return Text("\(dayName), day \(day), no workouts")
    }

    /// The count line the tile drops at accessibility sizes (1a·AX3), re-exposed as accessibility
    /// custom content (T2-2).
    ///
    /// A separate `Text` rather than a reuse of ``summaryText``: it was written when that was a plain
    /// `String` of English literals (it is localized now, 2026-10-20), and it still states both
    /// halves on a mixed day, where the drawn caption only has room for the logs.
    ///
    /// The counts are plural-ruled count phrases (a translator agrees the participle with each),
    /// not a `count == 1` branch between two keys; a mixed day lists both, joined with ", ".
    var accessibilitySummary: Text {
        if workoutCount == 0 && plannedCount == 0 { return Text("Rest day") }
        let logged = String(localized: "move.week.cell.a11y.logged", defaultValue: "\(workoutCount) logged",
                            comment: "Spoken summary of a Move week-strip day: how many workouts were logged. Needs a plural variation.")
        let planned = String(localized: "move.week.cell.a11y.planned", defaultValue: "\(plannedCount) planned",
                             comment: "Spoken summary of a Move week-strip day: how many workouts are planned. Needs a plural variation.")
        if workoutCount == 0 { return Text(verbatim: planned) }
        if plannedCount == 0 { return Text(verbatim: logged) }
        return Text(verbatim: "\(logged), \(planned)")
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
    /// The guided run a today's plan's Start opened (`PlannedWorkoutRun.swift`). nil = closed.
    @State private var plannedRunSession: WorkoutProgram.SessionSuggestion?
    /// World build (`b2-move-day`); nil draws today's day page.
    @Environment(\.fernletFramedLook) private var look

    /// The page's name on the panel's plate: "Today", or the day's short date.
    private var plateTitle: String {
        if dateKey == store.todayKey {
            return String(localized: "Today")
        }
        let date = FernletDate.date(fromDayKey: dateKey) ?? .now
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

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
            },
            onStart: startAction(for: workout)
        )
    }

    /// Start, on today's plans only: the same guided run the Move root's row opens.
    private func startAction(for workout: PlannedWorkout) -> (() -> Void)? {
        guard dateKey == store.todayKey, PlannedWorkoutRun.canGuide(workout) else { return nil }
        return {
            guard let session = store.guidedSession(forPlanned: workout, date: dateKey) else {
                FernletAuditLog.log("workout.plannedRun.notGuidable")
                return
            }
            plannedRunSession = session
        }
    }

    /// The day's plan: an empty-state that opens the planner, or the planned rows.
    private var planSection: some View {
        MoveCardList(header: Text("Plan")) {
            if day.plannedWorkouts.isEmpty {
                Button {
                    editingPlannedWorkout = nil
                    showPlanSheet = true
                } label: {
                    EmptyState(text: "No workouts planned")
                }
                .buttonStyle(.plain)
            } else {
                ForEach(day.plannedWorkouts) { workout in
                    plannedRow(workout)
                }
            }
        }
    }

    /// The day's logged workouts — hidden on future days (you can plan ahead, not log ahead).
    @ViewBuilder private var workoutsSection: some View {
        if !isFuture {
            MoveCardList(header: Text("Workouts")) {
                if day.workouts.isEmpty {
                    EmptyState(text: "No workouts logged")
                } else {
                    ForEach(day.workouts) { workout in
                        WorkoutRow(
                            store: store,
                            workout: workout,
                            date: dateKey,
                            onChanged: { reloadToken += 1 }
                        )
                    }
                }
            }
        }
    }

    /// World build (`b2-move-day`): Plan and Log sit under the date as two framed buttons, instead of
    /// crowding the bar (the plate hides it). Log is offered on today and past days only.
    private var framedActions: some View {
        AdaptiveStack(spacing: 10, horizontalAlignment: .leading) {
            MoveIconButton(title: Text("Plan"), sprite: WorldSprites.diary) {
                editingPlannedWorkout = nil
                showPlanSheet = true
            }
            .accessibilityIdentifier("move.day.plan")
            if !isFuture {
                MoveIconButton(title: Text("Log"), sprite: WorldSprites.plus) { showWorkoutSheet = true }
                    .accessibilityIdentifier("move.day.log")
            }
        }
    }

    /// The page's heading: World build, the big title and date with Plan and Log under them; today, the
    /// ScreenHeader (Plan and Log ride in the bar).
    @ViewBuilder private var pageHeader: some View {
        if look != nil {
            MovePageTitle(title: navigationTitle, subtitle: Text(verbatim: headerSubtitle))
            framedActions
        } else {
            ScreenHeader(title: navigationTitle, subtitle: Text(verbatim: headerSubtitle))
        }
    }

    /// One toolbar capsule — the Plan and Log entries are the same chrome.
    private func toolbarCapsule(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
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
                pageHeader
                planSection
                workoutsSection
            }
            .padding(20)
        }
        .modifier(MoveDayChrome(isFramed: look != nil, plateTitle: plateTitle) { toolbarItems })
        .sheet(isPresented: $showWorkoutSheet) {
            WorkoutSheet(store: store, dateKey: dateKey)
                .fernletSheet()
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
                .fernletSheet()
        }
        // A finished run completes the planned row: re-read the day when the runner closes.
        // World build (`b3-runner-*`): the runner is a focused flow, full screen.
        .fullScreenCover(item: $plannedRunSession, onDismiss: { reloadToken += 1 }) { session in
            GuidedWorkoutSheet(store: store, session: session)
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
    /// Runs this plan in the guided runner, as written (`PlannedWorkoutRun.swift`). Nil — no Start — on
    /// any day but today, and for a plan with nothing to run.
    var onStart: (() -> Void)? = nil

    /// Remove asks first — a mis-tap on a small text button used to erase a plan (possibly a
    /// coach-imported one) with no dialog and no undo, while the sibling logged row confirmed.
    /// Held here rather than at each call site so both the Move root and the day detail inherit it.
    @State private var pendingDestructiveAction: DestructiveConfirmation?

    /// The plan's lines as drawn: an activity plan's one step reads in the user's language
    /// (``PlannedWorkout/displayedExerciseLines``), never as its stored English default.
    private var stepLines: [String] {
        plannedWorkout.displayedExerciseLines
    }

    /// The complete button, or the faded dot a future day shows in its place.
    @ViewBuilder private var leadingMarker: some View {
        if showsCompleteAction {
            Button {
                onComplete()
                // The row under VoiceOver's cursor leaves the list as it completes, so the cursor
                // moves somewhere else with nothing said about why.
                TaskConfirmation.workoutLogged.announce()
            } label: {
                if let look {
                    // World build: a framed check box in the plan's colour, a pixel tick inside.
                    WorldSpriteView(sprite: WorldSprites.check, scale: 2, tint: look.text)
                        .frame(width: 34, height: 34)
                        .fernletFramed(look, fill: plannedWorkout.workoutType.color.opacity(0.22), cornerRadius: 8)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                } else {
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark \(plannedWorkout.displayedName) complete")
            // T2-12: "Mark upper body strength complete" is a sentence to speak at a checkbox.
            .accessibilityInputLabels([Text("Done"), Text("Complete"), Text("Mark complete")])
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
            Text(plannedWorkout.displayedName)
                .font(look == nil ? .fernlet(.headerMedium) : .custom(FernletFontName.frauncesSemiBold, size: 20, relativeTo: .title3))
                .foregroundStyle(look?.text ?? Color.bark)
            HStack(spacing: 8) {
                Text(plannedWorkout.split.title)
                if showsPlanSourceTag {
                    Text(plannedWorkout.source.title)
                }
                if let duration = plannedWorkout.duration {
                    Text("\(duration) min")
                }
            }
            .font(look == nil ? .fernlet(.labelSmall) : FernletFramedFont.body)
            .foregroundStyle(look?.dim ?? Color.slate)
        }
    }

    /// The first few plan steps, and the plan note.
    @ViewBuilder private var stepPreview: some View {
        if !stepLines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(stepLines.prefix(4).enumerated()), id: \.offset) { _, line in
                    Text(WorkoutMeasurementEntry.drawnLine(line))
                        .font(look == nil ? .fernlet(.bodySmall) : FernletFramedFont.body)
                        .foregroundStyle(look?.text ?? Color.bark.opacity(0.82))
                        .lineLimit(2)
                }
            }
        }

        if !plannedWorkout.notes.isEmpty {
            Text(plannedWorkout.displayedNotes)
                .font(look == nil ? .fernlet(.bodySmall) : FernletFramedFont.note)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()
        }
    }

    /// "Start" — a filled capsule, the row's one primary — runs the plan in the guided runner. The spoken
    /// name says which plan; Voice Control answers to the drawn word.
    @ViewBuilder private var startButton: some View {
        if let onStart, look != nil {
            Button("Start", action: onStart)
                .buttonStyle(ActionPillButtonStyle(.primary, size: .small))
                .accessibilityLabel("Start \(plannedWorkout.displayedName), guided")
                .accessibilityInputLabels([Text("Start"), Text("Start plan"), Text("Start workout")])
                .accessibilityIdentifier("workout.plan.start")
        } else if let onStart {
            Button(action: onStart) {
                Label("Start", systemImage: "play.fill")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.onMoss)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.mossFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .fernletTapTarget()
            .accessibilityLabel("Start \(plannedWorkout.displayedName), guided")
            .accessibilityInputLabels([Text("Start"), Text("Start plan"), Text("Start workout")])
            .accessibilityIdentifier("workout.plan.start")
        }
    }

    /// Start (today's plans), Edit, Remove — stacked at accessibility text sizes rather than squeezed.
    private var actionRow: some View {
        AdaptiveStack(spacing: look == nil ? 10 : 18, horizontalAlignment: .leading) {
            startButton
            Button("Edit", action: onEdit)
                .font(look == nil ? .fernlet(.label) : FernletFramedFont.sheetControl)
                .foregroundStyle(look?.link ?? Color.moss)
                .fernletTapTarget()
            Button("Remove", role: .destructive) { confirmRemove() }
                .font(look == nil ? .fernlet(.label) : FernletFramedFont.sheetControl)
                .foregroundStyle(look?.text ?? Color.terracottaInk)
                .fernletTapTarget()
                .accessibilityIdentifier("workout.plan.remove")
        }
    }

    /// World build (`b2-move-day`): a Fraunces title, the framed Start, link-coloured Edit.
    @Environment(\.fernletFramedLook) private var look

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
    /// The sheet's stack: a planned exercise's own page (`b3-workout-plan` draft 2).
    @State private var liftPath: [WorkoutLiftRoute] = []
    @Environment(\.fernletFramedLook) private var look
    private let previousWeekPlan: PlannedWorkout?
    /// The plan the name field was seeded from: the one being edited, or the one "Copy previous week"
    /// copied. The field draws its `displayedName`; ``plannedName`` hands the stored name back while
    /// that text is untouched.
    @State private var nameSeedPlan: PlannedWorkout?
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
        let seedName = editingPlan?.displayedName ?? ""
        let seedPlanned = editingPlan?.exercises ?? ""
        let seedDuration = editingPlan?.duration.map(String.init) ?? ""
        // Stored in miles; the field reads in the device's units (kilometres on a metric device).
        let seedDistance = editingPlan?.targetDistanceMiles.map { WorkoutMeasurementEntry.entryText(miles: $0) } ?? ""
        let seedEnergy = editingPlan?.targetEnergyKcal.map { String($0) } ?? ""
        let seedEffort = editingPlan?.targetEffort.map(String.init) ?? ""
        let seedNotes = editingPlan?.notes ?? ""
        let seedActivity = editingPlan?.activityType
        _split = State(initialValue: copiedSplit)
        _logMode = State(initialValue: seedMode)
        _name = State(initialValue: seedName)
        _nameSeedPlan = State(initialValue: editingPlan)
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

    /// The plan sheet's date line: "Today", or the formatted target day. The literal was a `String`
    /// drawn through `Text`'s verbatim overload, so it never reached the catalog.
    private var targetDateTitle: String {
        if dateKey == store.todayKey {
            return String(localized: "move.plan.targetDate.today", defaultValue: "Today",
                          comment: "Plan sheet: the workout is being planned for today")
        }
        let date = FernletDate.date(fromDayKey: dateKey) ?? .now
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var plannedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // A seeded name left as drawn saves as the stored name it was drawn from, so editing a
        // blank-named plan on a translated device keeps its English default.
        if !trimmed.isEmpty { return nameSeedPlan?.savedName(editing: trimmed) ?? trimmed }
        // `defaultName` and `defaultPlanName`, not `displayName` and `defaultPlanDisplayName`: this
        // string is PERSISTED as `PlannedWorkout.name`, a completed plan carries it onto the logged
        // row, and `WorkoutExerciseCatalog.inferredCategory`/`targetSummary` then match ENGLISH
        // keywords against it. A localized default name would have a plan created on a German
        // device infer its own type differently. The placeholder below is display-only and keeps
        // the localized names.
        if logMode == .activity, let selectedActivityType {
            return selectedActivityType.defaultName
        }
        return split.defaultPlanName
    }

    /// The name field is optional — the placeholder shows the name the plan will take, in the
    /// user's language; ``plannedName`` stores its frozen English form.
    ///
    /// A resolved `String` for the same reason as ``WorkoutSheet``'s: the activity type's
    /// `displayName` is already final text. The activity fallback goes through
    /// `String(localized:)`; the split line is `WorkoutSplit.defaultPlanDisplayName`, the same
    /// localized form a row draws for a plan saved under it, so " workout" is not English glued on
    /// in Swift.
    private var plannedNamePlaceholder: String {
        if logMode == .activity {
            return selectedActivityType?.displayName
                ?? String(localized: "move.workoutName.placeholder.activity",
                          defaultValue: "Optional, e.g. Saturday ride",
                          comment: "Placeholder in the optional workout-name field before an activity is chosen. Names an example activity.")
        }
        return split.defaultPlanDisplayName
    }

    private var exerciseText: String {
        if logMode == .activity {
            // Persisted as `PlannedWorkout.exercises` and keyword-matched with the name: the
            // frozen `defaultName`, for the reason ``plannedName`` gives.
            return selectedActivityType?.defaultName ?? ""
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

    /// Copy last week and Suggest one, side by side (stacked at accessibility sizes), when offered.
    @ViewBuilder private var quickStarts: some View {
        if previousWeekPlan != nil || showsSuggestEntry {
            AdaptiveStack(spacing: 10, horizontalAlignment: .leading) {
                if let previousWeekPlan {
                    entryCard(icon: "arrow.turn.down.right",
                              title: "Copy last week",
                              subtitle: previousWeekPlan.displayedName) {
                        copyPreviousWeekPlan(previousWeekPlan)
                    }
                    .accessibilityIdentifier("plan.copyPreviousWeek")
                }
                if showsSuggestEntry {
                    entryCard(icon: "wand.and.stars",
                              title: "Suggest one",
                              subtitle: String(localized: "move.plan.suggest.subtitle",
                                               defaultValue: "Built from your split, equipment, and limits",
                                               comment: "Plan sheet, the Suggest a workout card's second line")) {
                        showingSuggestion = true
                    }
                    .accessibilityIdentifier("plan.suggest")
                }
            }
        }
    }

    /// A planned row's binding by id: reads the row while it is listed (`fallback` once it is gone) and
    /// writes only into a row that is still there.
    private func plannedRowBinding(_ id: UUID, fallback: WorkoutExerciseEntry) -> Binding<WorkoutExerciseEntry> {
        Binding(
            get: { exerciseRows.first { $0.id == id } ?? fallback },
            set: { updated in
                guard let index = exerciseRows.firstIndex(where: { $0.id == id }) else { return }
                exerciseRows[index] = updated
            }
        )
    }

    /// The new-exercise page's Add to plan: the exercise joins the list and the plan steps.
    private func commitPlannedLift() {
        addDraftExercise()
        liftPath = []
    }

    /// Takes a planned row off the list, and out of the plan steps it was folded into.
    private func removePlannedRow(_ id: UUID) {
        exerciseRows.removeAll { $0.id == id }
        plannedExerciseText = exerciseRows.map(\.summary).joined(separator: "\n")
    }

    /// The exercise page's back word: the plan sheet's own title.
    private var planBackLabel: Text { Text(editingPlan == nil ? "Plan workout" : "Edit plan") }

    /// The plan sheet's exercise page: a new exercise (search, then its prescription, Add to plan), or a
    /// listed one edited in place (Back keeps the change; Remove takes it off the plan).
    @ViewBuilder private func planLiftPage(_ route: WorkoutLiftRoute) -> some View {
        switch route {
        case .lift:
            MoveLiftPage(title: draft.exercise.map { Text(verbatim: $0.displayName) } ?? Text("Add exercise"),
                         subtitle: nil, buttonLabel: "Add to plan", buttonDisabled: draft.exercise == nil,
                         back: planBackLabel, onButton: commitPlannedLift) {
                WorkoutExerciseBuilder(
                    selectedExercise: $draft.exercise, sets: $draft.sets, reps: $draft.reps, weight: $draft.weight,
                    speed: $draft.speed, incline: $draft.incline, details: $draft.details, resetToken: $draft.resetToken,
                    mode: logMode, showAddButton: false, autofocusSearch: true, historyStore: store, onAdd: addDraftExercise
                )
            }
        case .row(let id):
            if let entry = exerciseRows.first(where: { $0.id == id }) {
                MoveLiftPage(title: Text(verbatim: entry.exercise.displayName), subtitle: nil, buttonLabel: nil,
                             back: planBackLabel) {
                    // By id, never `$exerciseRows[index]`: Remove takes the row out while the page is
                    // still leaving the stack, and an index binding read then runs off the array.
                    EditablePlannedExerciseRow(entry: plannedRowBinding(id, fallback: entry), showsHeader: false) {
                        removePlannedRow(id)
                        liftPath = []
                    } onChange: {
                        plannedExerciseText = exerciseRows.map(\.summary).joined(separator: "\n")
                    }
                }
            }
        }
    }

    /// The "User plan" tag when coach-sourced plans exist (the title and day are in the sheet's header).
    @ViewBuilder private var planHeader: some View {
        if showsPlanSourceTag {
            FernletTag("User plan")
        }
    }

    /// The shared chrome behind "Copy last week" and "Suggest one" (`b3-workout-plan` draft 2: two small
    /// framed buttons in one row). The second line is spoken as the button's hint.
    private func entryCard(icon: String, title: LocalizedStringKey, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .accessibilityHidden(true)
                Text(title)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ActionPillButtonStyle(.secondary))
        .accessibilityHint(Text(verbatim: subtitle))
    }

    /// The split as one framed dropdown — strength only (`b3-workout-plan` draft 2, instead of eight chips).
    ///
    /// The "Workout" split is deliberately absent: it duplicated the Kind row (picking it flipped Kind,
    /// and picking Kind flipped it back), so two controls mirrored one piece of state. Split is now
    /// only asked for when it means something, which is a strength plan.
    private var splitField: some View {
        FernletDropdown("Split", selection: $split, options: strengthSplits) { option in
            Text(verbatim: option.title)
        }
        .accessibilityIdentifier("plan.split")
    }

    private var strengthSplits: [WorkoutSplit] {
        WorkoutSplit.allCases.filter { $0 != .workout }
    }

    /// Strength or Cardio & activity, a framed switch kept consistent with the chosen split.
    private var kindField: some View {
        FernletSegmentedPicker("Kind", selection: $logMode, options: WorkoutMode.allCases) { mode in
            // `b3-workout-plan` draft 2: "Strength" beside "Cardio & activity", as on the Log sheet.
            mode == .strengthTraining ? Text("Strength") : Text(verbatim: mode.label)
        }
        .accessibilityIdentifier("plan.kind")
    }

    /// The split that goes with a change of kind: an activity is a `.workout`; strength leaves it.
    private func syncSplit(to mode: WorkoutMode) {
        if mode == .activity {
            split = .workout
        } else if split == .workout {
            split = .fullBody
        }
    }

    /// The planned exercises (the same list as Log workout, each opening its own page), then the
    /// free-text plan steps they stay in sync with.
    @ViewBuilder private var strengthPlanFields: some View {
        MoveLiftCard(header: Text("Planned exercises")) {
            ForEach(exerciseRows) { entry in
                MoveLiftListRow(name: entry.exercise.displayName,
                                detail: WorkoutMeasurementEntry.displayedSpeeds(in: entry.detailSummary),
                                color: entry.exercise.category.color,
                                identifier: "plan.row",
                                onRemove: { removePlannedRow(entry.id) }) { liftPath = [.row(entry.id)] }
            }
        } footer: {
            MoveAddExerciseButton(identifier: "plan.addExercise") {
                draft.clear()
                liftPath = [.lift]
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

            quickStarts

            // Kind first, then Split — Split only qualifies a strength plan.
            kindField
            if logMode == .strengthTraining {
                splitField
            }

            SheetField("Workout") {
                TextField(plannedNamePlaceholder, text: $name, prompt: .fieldPrompt(verbatim: plannedNamePlaceholder))
                    .sheetTextInput()
            }

            if logMode == .strengthTraining {
                strengthPlanFields
            } else {
                activityFields
            }

            if logMode == .strengthTraining {
                SheetField("Duration (min)", namesControl: true) {
                    TextField("45", text: $duration, prompt: .fieldPrompt("45"))
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
                duration: WorkoutSheetRules.durationMinutes(from: duration),
                targetDistanceMiles: WorkoutMeasurementEntry.miles(fromEntry: distance),
                targetEnergyKcal: LocaleTolerantNumber.double(from: energyKcal),
                targetEffort: LocaleTolerantNumber.int(from: effort),
                createdAt: editingPlan?.createdAt ?? Date()
            ),
            date: dateKey
        )
        dismiss()
    }

    var body: some View {
        // World build (`b3-workout-plan` draft 2): a stack, so a planned exercise opens on its own page.
        NavigationStack(path: $liftPath) {
            listPage
                .navigationTitle(Text(editingPlan == nil ? "Plan workout" : "Edit plan"))
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: WorkoutLiftRoute.self) { planLiftPage($0) }
        }
        .keyboardDoneToolbar()
        .interactiveDismissDisabled(isDirty)
        .discardConfirmation(isPresented: $showDiscardConfirm) { dismiss() }
        .sheet(isPresented: $showingSuggestion) {
            // Presented from THIS sheet rather than routed through the tab's `activeSheet` slot:
            // that route would have to dismiss the plan sheet first, throwing away a part-filled
            // plan. The suggestion flow commits its own plan and closes itself, so on return the
            // user is back on the plan they were writing. Full height, like every sheet.
            WorkoutSuggestionSheet(store: store)
                .fernletSheet()
        }
        .onChange(of: logMode) { _, mode in
            draft.clear()
            syncSplit(to: mode)
        }
        .onChange(of: liftPath) { _, path in
            // Back from a new exercise's page drops what it held; Add to plan already took it.
            if path.isEmpty { draft.clear() }
        }
    }

    /// The sheet's list page under its header (Cancel, the title and the day in the sheet), with Save.
    private var listPage: some View {
        VStack(spacing: 0) {
            ScrollView {
                planForm
            }
            SheetSaveBar(label: editingPlan == nil ? "Save plan" : "Update plan") { savePlan() }
        }
        .background((look?.paper ?? Color.parchment).ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            SheetHeader(title: Text(editingPlan == nil ? "Plan workout" : "Edit plan"),
                        subtitle: Text(verbatim: targetDateTitle), onCancel: attemptCancel)
        }
        .accessibilityAction(.escape) { attemptCancel() }
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
        nameSeedPlan = plan
        name = plan.displayedName
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
    /// World build (`b3-goals`): each proposed goal on a framed card.
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        if look != nil {
            VStack(alignment: .leading, spacing: 3) {
                Text(goal.goal).font(FernletFramedFont.cardTitle).foregroundStyle(look?.text ?? Color.bark)
                Text("\(goal.timeframe) - \(goal.metric)")
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(look?.dim ?? Color.slate)
                if !goal.milestones.isEmpty {
                    Text(goal.milestones.joined(separator: " - "))
                        .font(FernletFramedFont.rowDetail)
                        .foregroundStyle(look?.link ?? Color.moss)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(MoveInsetCardFrame())
        } else {
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
}
