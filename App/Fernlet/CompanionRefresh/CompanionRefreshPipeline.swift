//
//  CompanionRefreshPipeline.swift
//  Fernlet
//
//  Network migration P10 item 4 (plan §17.2, §27.3): the companion refresh handler, written as a
//  PIPELINE OVER VALUES rather than as a method on a store.
//
//  **What §17.2 asks for, in order.** Acquire the store → check the widget's inbound queue →
//  check that the scoring context is whole → roll the diary day → recompute the deterministic
//  companion → diff the snapshot → publish through the widget bridge → reload timelines ONLY on a
//  change → complete exactly once. The last step is the coordinator's (it owns the delivered
//  handle); everything before it is this file, and nothing here knows what a background task is.
//
//  **What "acquire" really does, said plainly.** It asks `FernletStoreAccess` for the process's one
//  store, and on a COLD wake — a process the system started for this task alone — there is no such
//  store yet, so the acquisition BUILDS one: the Core Data stack and the bundled food catalog, both
//  inside the grant. §17.2 forbids the handler creating a store of its OWN (a second store over the
//  same repositories) and forbids any creation while protected data is unavailable, which
//  `FernletStoreAccess.load()` refuses before it opens anything. It does not, and cannot, forbid the
//  first store in the process from existing. The import wall keeps `FernletStore(`,
//  `FernletStore.load(` and `FernletStoreLoader` out of this directory for that reason: the handler
//  may only ever arrive through the one cache.
//
//  **Why closures rather than a `FernletStore` parameter.** A pipeline that named the store could
//  be driven in a unit test only by building one — the single thing §17.2 forbids outright — and
//  that would drag a Core Data stack into a suite that wants to assert an ORDER and a DECISION. The
//  steps arrive as eight closures the production wiring binds to the real store
//  (``CompanionRefreshWiring``) and a fake binds to counters. What the pipeline itself speaks is a
//  trace of the steps that ran, a publication verdict, and one outcome.
//
//  **Acquire is a two-phase step, deliberately.** Every step after the first needs the acquired
//  store, so ``CompanionRefreshPipeline/acquire`` returns the REMAINING steps rather than a store.
//  The store therefore appears in no type below, and a fake supplies the same eight closures without
//  one existing.
//
//  **Why the diff and the reload are not separate injected steps.** They are one decision, and the
//  thing that owns it already exists: `WidgetSnapshotMirror` holds the snapshot file it would read
//  and the `reloadTimelines` closure `WidgetBridgeTests` already counts. Splitting them here would
//  create a SECOND site that decides whether a change is a change, and two such sites drift. The
//  decision lives once, on `WidgetSnapshot.contentEquals(_:)`, and reaches this file as a
//  `WidgetSnapshotPublication` the trace below reads a reload off.
//
//  **No persisted surface, no clock, no second store.** Nothing here writes a defaults key, opens a
//  file, or reads the wall clock: the day roll's clock is the store's, the snapshot's stamp is the
//  store's, and "is the published snapshot for today?" is answered by the store against the same
//  clock its own roll uses, so two callers cannot disagree about what day it is. The whole memory
//  of a refresh is the snapshot file the app already publishes.
//

import FernletFoundation
import Foundation

// MARK: - CompanionRefreshStep

/// One step of §17.2's pipeline, as the trace records it.
///
/// A trace rather than a set of booleans: the ORDER is half of what item 4 is — a publish that ran
/// before the day roll would publish yesterday under today's key — and an array makes the order
/// assertable in one `#expect`.
///
/// ``reload`` is the odd one out: it is not a step the pipeline calls but a step the run OBSERVED,
/// so "reload only on change" reads off the trace as the presence or absence of one element. It is
/// recorded in two places — after the day roll, when the store's own publish reloaded the widget on
/// its way through, and after the handler's publish, when the diff decided so. At most one of them
/// can happen in a run, because the second reads a file the first has just brought up to date.
///
/// ## Concurrency
///
/// `nonisolated`; it is a raw-value enum.
nonisolated enum CompanionRefreshStep: String, CaseIterable, Equatable, Sendable {

    /// The process's one store was acquired through `FernletStoreAccess`. On a cold wake that
    /// acquisition BUILDS it; what the handler may never do is build one of its own, or build any
    /// while protected data is unavailable — see this file's header.
    case acquire

    /// The widget's inbound action queue was asked whether it still holds undrained rows.
    case inspectWidgetQueue

    /// The store was asked whether every enabled scoring adjustment has its bridge (D-10.4.6).
    case inspectScoringContext

    /// The diary day was rolled to the current wall-clock day (it may have been today already).
    case rollDay

    /// The deterministic companion was recomputed off the rolled day.
    case recompute

    /// The snapshot was handed to the widget bridge.
    case publish

    /// …and the widget timelines were reloaded, because the content had changed. Caused by the
    /// handler's own publish, or — on a day roll through a warm process — by the store's.
    case reload
}

// MARK: - CompanionRefreshOutcome

/// How one refresh ended, and therefore what the system is told.
///
/// Eight cases and no payloads, so the completion table asserts whole values rather than shapes.
/// The error behind ``acquisitionFailed`` is audited where it is caught rather than carried,
/// because a `String` payload would make every row of that table a substring match.
///
/// ## Concurrency
///
/// `nonisolated`; a plain enum.
nonisolated enum CompanionRefreshOutcome: String, CaseIterable, Equatable, Sendable {

    /// The content changed and the widget timelines were reloaded. The ordinary interesting refresh.
    case reloaded

    /// The pipeline ran to the end and the content was identical, so nothing was reloaded. The
    /// ordinary DULL refresh, and the one §17.2's diff exists to produce.
    case unchanged

    /// The snapshot file could not be written. Not a reload by another name: a failed write leaves
    /// the widget on its last good snapshot, which is the correct degradation.
    case writeFailed

    /// The widget's action queue still held undrained rows AND the published snapshot is still
    /// today's, so the run skipped everything after the acquisition. See
    /// ``CompanionRefreshSteps/hasUndrainedWidgetActions`` for why that is the right answer rather
    /// than a missed refresh.
    case widgetActionsPending

    /// The queue still held undrained rows, but the published snapshot is for a day that has
    /// ENDED, so the run published anyway (decision D-10.4.8).
    ///
    /// Its own case rather than a flavour of ``reloaded``, because the run knowingly republished
    /// over a provisional count: a person who tapped "+1" from the widget yesterday evening may
    /// see that tap's optimistic bump disappear a moment before the foreground drain files it
    /// against yesterday, where it belongs. The alternative is the widget going BLANK — a snapshot
    /// whose `dateKey` is yesterday fails `WidgetDayGate.snapshotReflectsDay` and the companion
    /// stops being drawn at all — and that is worse in every reading. A widget one tap behind beats
    /// a widget showing nothing.
    case publishedDespitePendingActions

    /// An adjustment the person turned on had no bridge attached, so the run refused to publish a
    /// score the app itself would not agree with (decision D-10.4.6). See
    /// `FernletStore.hasCompleteScoringContext`.
    ///
    /// The cost, stated: on a COLD wake with period-aware care or body signals switched on, this
    /// handler publishes nothing at all, and the widget holds its last foreground snapshot until
    /// the person next opens the app. A warm process — the ordinary case, since the scene attaches
    /// both bridges the moment the store is ready — is unaffected.
    case scoringContextUnavailable

    /// The store could not be acquired — a locked device before first unlock is the expected
    /// reason. The chain continues (the successor was submitted before the pipeline started); this
    /// run did nothing.
    case acquisitionFailed

    /// The task's grant was spent and the expiration handler cancelled the run. The coordinator has
    /// ALREADY completed the task `false` by the time this is produced, so it must never complete
    /// again — which is why it is a distinct case rather than a flavour of ``writeFailed``.
    case cancelled

    /// What the system is told at `setTaskCompleted(success:)`.
    ///
    /// `true` means "the work this task carried finished on the app's terms", and a refresh that
    /// correctly found nothing to do finished on the app's terms — reporting `false` for
    /// ``unchanged`` would teach the scheduler to stop granting the very refreshes that are
    /// working. ``widgetActionsPending`` answers `true` for the same reason: deciding not to
    /// publish is a decision the handler made correctly, not a failure it suffered.
    ///
    /// ``scoringContextUnavailable`` answers `true` on the same reading: refusing to publish a
    /// score the app disagrees with is the handler working, and a `false` would cost the chain the
    /// very refreshes that would start succeeding the moment a foreground attached the bridges.
    ///
    /// ``cancelled`` answers `false` for completeness; the coordinator never asks, because the
    /// expiration door completed the task before the run could return.
    var completesSuccessfully: Bool {
        switch self {
        case .reloaded, .unchanged, .widgetActionsPending: true
        case .publishedDespitePendingActions, .scoringContextUnavailable: true
        case .writeFailed, .acquisitionFailed, .cancelled: false
        }
    }
}

// MARK: - CompanionRefreshRun

/// Everything one run of the pipeline produced, as one value.
///
/// The trace and the outcome are separate on purpose: the outcome says what the system is told, and
/// the trace says how far the run got before saying it — and those two answers come apart exactly
/// at ``CompanionRefreshOutcome/cancelled``.
///
/// ## Concurrency
///
/// `nonisolated`; four value fields.
nonisolated struct CompanionRefreshRun: Equatable, Sendable {

    /// What the system is told.
    let outcome: CompanionRefreshOutcome

    /// The steps that ran, in order.
    let steps: [CompanionRefreshStep]

    /// Whether the day roll actually crossed local midnight. Reported rather than acted on: a day
    /// that advanced is the one case where the snapshot's `dateKey` is guaranteed to differ, so a
    /// run with ``dayAdvanced`` true and no ``CompanionRefreshStep/reload`` in the trace is a defect
    /// the acceptance battery can name.
    let dayAdvanced: Bool

    /// The companion state's raw value at the recompute, or `nil` if the run never got that far.
    let companionStateRaw: String?
}

// MARK: - CompanionRefreshSteps

/// The eight steps that need the acquired store, as closures.
///
/// Bound to the real store by ``CompanionRefreshWiring/productionPipeline()`` and to counters by
/// the suite.
///
/// ## Concurrency
///
/// `@MainActor`, and deliberately NOT `Sendable`: these closures hold the store, which never leaves
/// the main actor. Each closure TYPE is spelled `@MainActor` explicitly rather than inherited from
/// the enclosing type — a function type does not pick up a global actor from the type it is stored
/// in, and the TEST target does not build with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so the
/// annotation is load-bearing where the fakes are written rather than decoration.
@MainActor
struct CompanionRefreshSteps {

    /// Whether the widget's inbound action queue still holds rows the app has not folded in.
    ///
    /// Asked FIRST, before the day roll, and a `true` ends the run unless the day has moved on
    /// (see ``publishedSnapshotIsForCurrentDay``). §17.2 limits the handler to its listed steps, so
    /// draining the queue here is not on the table — and publishing without draining would
    /// republish the app's own lower water count over the provisional one the widget's "+1" App
    /// Intent already wrote into the same file, making the count visibly go backwards until the
    /// next foreground. The roll is skipped along with the publish because a warm process's roll
    /// PUBLISHES on its own (through the store's internal path), which would regress the count by a
    /// second route this decision cannot see.
    let hasUndrainedWidgetActions: @MainActor () -> Bool

    /// Whether the snapshot the widget is currently rendering is for the current wall-clock day.
    ///
    /// Asked only when the queue check said `true`, and it is what stops that skip from lasting
    /// across midnight (decision D-10.4.8). One undrained row used to suspend every background
    /// publish until the next foreground; a snapshot left on yesterday's `dateKey` fails
    /// `WidgetDayGate.snapshotReflectsDay` and the widget stops drawing the companion entirely. So
    /// the skip holds only while the thing it is protecting is still on screen: `false` here — a
    /// stale day, or nothing published at all — and the run publishes regardless.
    let publishedSnapshotIsForCurrentDay: @MainActor () -> Bool

    /// Whether every scoring adjustment the person turned on has its bridge attached.
    ///
    /// `false` ends the run before anything is rolled or published (decision D-10.4.6): the
    /// recompute below would return a score missing the period and stress adjustments, and a widget
    /// carrying a companion the app disagrees with is worse than a widget carrying an older one.
    /// See `FernletStore.hasCompleteScoringContext` for why the handler cannot simply attach them.
    let scoringContextIsComplete: @MainActor () -> Bool

    /// The snapshot currently published to the widget, or `nil` when there is none.
    ///
    /// Read either side of the day roll, and for one purpose: the roll PUBLISHES on its own when it
    /// advances (through the store's internal path), and on a warm process that write lands before
    /// the diff below can read the previous value — so the diff sees no change, reports
    /// ``CompanionRefreshOutcome/unchanged``, and the run ends with `dayAdvanced` true and no
    /// reload in its trace, which is precisely the combination the acceptance battery calls a
    /// defect. Comparing the two reads OBSERVES that reload instead of assuming it, which also
    /// keeps a failed write from being recorded as one.
    ///
    /// Must not install the mirror; `FernletStore.publishedWidgetSnapshot()` says why.
    let publishedSnapshot: @MainActor () -> WidgetSnapshot?

    /// Rolls the diary to the current wall-clock day.
    ///
    /// - Returns: Whether the day ADVANCED. `false` — still the same day — is the overwhelmingly
    ///   common answer and is not a failure.
    let rollDay: @MainActor () -> Bool

    /// Recomputes the companion and answers its raw value.
    ///
    /// The raw value rather than the state itself, because that is the spelling the snapshot
    /// carries, and carrying both would invite them to disagree.
    let recompute: @MainActor () -> String

    /// Builds the snapshot the widget would render right now.
    let makeSnapshot: @MainActor () -> WidgetSnapshot

    /// Hands the snapshot to the widget bridge, which writes it and reloads only on a content
    /// change.
    let publish: @MainActor (WidgetSnapshot) -> WidgetSnapshotPublication
}

// MARK: - CompanionRefreshPipeline

/// §17.2's handler: acquire, check the queue, check the scoring context, roll, recompute,
/// diff-and-publish — and nothing else, ever.
///
/// ## What this type may not grow
///
/// A mesh call, a HealthKit read, a CloudKit force-sync, a Foundation Models prompt, or a store
/// construction of its own — the acquisition is the process's one store and may build it on a cold
/// wake, which this file's header spells out. `BackgroundRefreshBoundaryTests` holds the whole
/// directory to that mechanically; this paragraph is the part a reviewer reads.
///
/// ## Cancellation
///
/// ``run()`` checks `Task.isCancelled` at the two places a cancellation can have landed: before it
/// acquires anything, and immediately after the acquisition — the pipeline's ONE suspension point,
/// and therefore the only window in which the expiration handler can interleave. Everything after
/// it is synchronous main-actor work that a cancellation cannot cut into, so a third check there
/// would be theatre. The real guard against completing a task twice is not here at all: it is the
/// coordinator refusing to complete a handle its run no longer holds.
///
/// ## Concurrency
///
/// `@MainActor`. One stored closure, which holds nothing until it is called.
@MainActor
struct CompanionRefreshPipeline {

    /// Acquires the existing store and binds the remaining steps to it.
    ///
    /// Throws rather than returning an optional, because the one expected failure —
    /// `ExchangeIntentServiceError.deviceLocked`, thrown before anything is opened when protected
    /// data is unavailable — is a "try again once unlocked" condition the audit line must name.
    let acquire: @MainActor () async throws -> CompanionRefreshSteps

    /// A pipeline that acquires nothing and does nothing, ending
    /// ``CompanionRefreshOutcome/unchanged``.
    ///
    /// Exists so a test of the COORDINATOR — registration, submission, the completion table — can
    /// build one without reaching a store, and so the coordinator's initialiser has something
    /// harmless to be handed. It is not a production path: ``CompanionRefreshWiring`` is. Its
    /// snapshot is built inline rather than off a shared constant, so nothing in the app target
    /// grows a "blank snapshot" value production code could reach for by mistake.
    static let noOp = CompanionRefreshPipeline(acquire: {
        CompanionRefreshSteps(
            hasUndrainedWidgetActions: { false },
            publishedSnapshotIsForCurrentDay: { true },
            scoringContextIsComplete: { true },
            publishedSnapshot: { nil },
            rollDay: { false },
            recompute: { "" },
            makeSnapshot: {
                WidgetSnapshot(
                    companionStateRaw: "",
                    score: 0,
                    bottleCount: 0,
                    hydrationTarget: 0,
                    macroSummary: WidgetSnapshot.MacroSummary(protein: 0, carbs: 0, fat: 0),
                    dateKey: "",
                    computedAt: Date(timeIntervalSince1970: 0)
                )
            },
            publish: { _ in .unchanged }
        )
    })

    /// Runs the pipeline once.
    ///
    /// Never throws and never traps: a background handler that threw would leave the coordinator
    /// with a task it still owes the system a completion for, so every failure is a value.
    ///
    /// - Returns: The trace, the verdict, and the two facts worth reporting.
    func run() async -> CompanionRefreshRun {
        if Task.isCancelled { return Self.ending(.cancelled, []) }
        let steps: CompanionRefreshSteps
        do {
            steps = try await acquire()
        } catch {
            FernletAuditLog.log("companionRefresh.acquireFailed",
                                context: ["error": String(describing: error)])
            return Self.ending(.acquisitionFailed, [])
        }
        var trace: [CompanionRefreshStep] = [.acquire]
        if Task.isCancelled { return Self.ending(.cancelled, trace) }
        trace.append(.inspectWidgetQueue)
        var despitePendingActions = false
        if steps.hasUndrainedWidgetActions() {
            guard !steps.publishedSnapshotIsForCurrentDay() else {
                // R7: never silent. A skipped publish is invisible from the outside, and a queue
                // that never drains would otherwise look exactly like a refresh chain doing its job.
                FernletAuditLog.log("companionRefresh.widgetActionsStillPending")
                return Self.ending(.widgetActionsPending, trace)
            }
            // R7: never silent. The run is about to republish over a provisional count, which is
            // D-10.4.8's accepted cost and not something to discover from a screenshot.
            FernletAuditLog.log("companionRefresh.widgetActionsPendingAcrossDayBoundary")
            despitePendingActions = true
        }
        trace.append(.inspectScoringContext)
        guard steps.scoringContextIsComplete() else {
            // R7: never silent. A cold wake that publishes nothing all day looks identical to a
            // chain the system stopped granting, and only this line tells them apart.
            FernletAuditLog.log("companionRefresh.scoringContextUnavailable")
            return Self.ending(.scoringContextUnavailable, trace)
        }
        return finish(steps: steps, trace: trace, despitePendingActions: despitePendingActions)
    }

    /// The synchronous tail: roll, recompute, publish, and read the reload off the verdict.
    ///
    /// Split out of ``run()`` so neither body argues with Power of 10's length rule, and because
    /// everything here runs in one main-actor turn — there is no suspension point below this line,
    /// which is the fact the cancellation paragraph above rests on.
    ///
    /// - Parameters:
    ///   - steps: The acquired store's steps.
    ///   - trace: What has run so far.
    ///   - despitePendingActions: Whether the widget queue held rows the day boundary overrode.
    /// - Returns: The finished run.
    private func finish(
        steps: CompanionRefreshSteps,
        trace: [CompanionRefreshStep],
        despitePendingActions: Bool
    ) -> CompanionRefreshRun {
        var trace = trace
        // The cost of seeing the roll's own publish, stated: ONE coordinated read of a small
        // app-group file on every run — it has to happen before the roll, and the roll is what
        // makes it interesting. The second read is taken only on an advance, because the roll
        // returns `false` before it touches anything when the day key has not changed, so nothing
        // can have been published on the overwhelmingly common path.
        let beforeRoll = steps.publishedSnapshot()
        let dayAdvanced = steps.rollDay()
        trace.append(.rollDay)
        if dayAdvanced, Self.republished(from: beforeRoll, to: steps.publishedSnapshot()) {
            trace.append(.reload)
        }
        let raw = steps.recompute()
        trace.append(.recompute)
        let snapshot = steps.makeSnapshot()
        if snapshot.companionStateRaw != raw {
            // R7: never silent. The companion is a PURE function of the rolled day, so two reads in
            // one turn that disagree mean something under it is not deterministic — a clock, a
            // random, a cache warming underneath. Nothing here can fix that; naming it is what makes
            // it findable on a device instead of showing up as a companion that flickers.
            FernletAuditLog.log("companionRefresh.companionNotDeterministic",
                                context: ["recomputed": raw, "published": snapshot.companionStateRaw])
        }
        trace.append(.publish)
        let publication = steps.publish(snapshot)
        if publication == .reloaded { trace.append(.reload) }
        return CompanionRefreshRun(
            outcome: Self.outcome(for: publication, trace: trace, despitePendingActions: despitePendingActions),
            steps: trace,
            dayAdvanced: dayAdvanced,
            companionStateRaw: raw
        )
    }

    /// Whether the day roll's own publish reached the widget.
    ///
    /// Answered by comparing what was on disk either side of the roll on CONTENT, the same notion
    /// the handler's own diff uses — so a roll whose app-group write failed reports `false` and is
    /// not recorded as a reload it never caused.
    ///
    /// - Parameters:
    ///   - before: The published snapshot before the roll.
    ///   - after: The published snapshot after it.
    /// - Returns: Whether the store republished changed content.
    private static func republished(from before: WidgetSnapshot?, to after: WidgetSnapshot?) -> Bool {
        guard let after else { return false }
        guard let before else { return true }
        return !before.contentEquals(after)
    }

    /// A run that ended before it could recompute anything.
    ///
    /// - Parameters:
    ///   - outcome: What the system is told.
    ///   - trace: The steps that ran.
    /// - Returns: The finished run.
    private static func ending(
        _ outcome: CompanionRefreshOutcome,
        _ trace: [CompanionRefreshStep]
    ) -> CompanionRefreshRun {
        CompanionRefreshRun(outcome: outcome, steps: trace, dayAdvanced: false, companionStateRaw: nil)
    }

    /// Maps the bridge's verdict, and what the trace saw, onto the pipeline's.
    ///
    /// Three rules, in order. A failed write is a failed write whatever else happened. A run that
    /// published over a pending queue names itself, because republishing over a provisional count
    /// is a decision worth reading in the audit line rather than an ordinary reload. Otherwise the
    /// TRACE decides: a day roll that reloaded through the store's own publish leaves the handler's
    /// diff with nothing to change, and reporting that as ``CompanionRefreshOutcome/unchanged``
    /// would call the most consequential refresh of the day a dull one.
    ///
    /// - Parameters:
    ///   - publication: What the widget bridge did.
    ///   - trace: The steps that ran, including any reload.
    ///   - despitePendingActions: Whether the widget queue held rows the day boundary overrode.
    /// - Returns: What the system is told.
    private static func outcome(
        for publication: WidgetSnapshotPublication,
        trace: [CompanionRefreshStep],
        despitePendingActions: Bool
    ) -> CompanionRefreshOutcome {
        if publication == .writeFailed { return .writeFailed }
        if despitePendingActions { return .publishedDespitePendingActions }
        return trace.contains(.reload) ? .reloaded : .unchanged
    }
}
