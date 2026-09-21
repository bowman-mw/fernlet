//
//  CompanionRefreshPipeline.swift
//  Fernlet
//
//  Network migration P10 item 4 (plan §17.2, §27.3): the companion refresh handler, written as a
//  PIPELINE OVER VALUES rather than as a method on a store.
//
//  **What §17.2 asks for, in order.** Acquire the store that already exists → roll the diary day →
//  recompute the deterministic companion → diff the snapshot → publish through the widget bridge →
//  reload timelines ONLY on a change → complete exactly once. The last step is the coordinator's
//  (it owns the delivered handle); everything before it is this file, and nothing here knows what a
//  background task is.
//
//  **Why closures rather than a `FernletStore` parameter.** A pipeline that named the store could
//  be driven in a unit test only by building one — the single thing §17.2 forbids outright — and
//  that would drag a Core Data stack into a suite that wants to assert an ORDER and a DECISION. The
//  steps arrive as five closures the production wiring binds to the real store
//  (``CompanionRefreshWiring``) and a fake binds to counters. What the pipeline itself speaks is a
//  trace of the steps that ran, a publication verdict, and one outcome.
//
//  **Acquire is a two-phase step, deliberately.** Every step after the first needs the acquired
//  store, so ``CompanionRefreshPipeline/acquire`` returns the REMAINING steps rather than a store.
//  The store therefore appears in no type below, and a fake supplies the same five closures without
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
//  file, or reads the wall clock: the day roll's clock is the store's, and the snapshot's stamp is
//  the store's. The whole memory of a refresh is the snapshot file the app already publishes.
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
/// ``reload`` is the odd one out: it is not a step the pipeline calls but a step the publication
/// REPORTS, so "reload only on change" reads off the trace as the presence or absence of one
/// element.
///
/// ## Concurrency
///
/// `nonisolated`; it is a raw-value enum.
nonisolated enum CompanionRefreshStep: String, CaseIterable, Equatable, Sendable {

    /// The existing store was acquired. Never a construction: the handler asks the shared cache.
    case acquire

    /// The widget's inbound action queue was asked whether it still holds undrained rows.
    case inspectWidgetQueue

    /// The diary day was rolled to the current wall-clock day (it may have been today already).
    case rollDay

    /// The deterministic companion was recomputed off the rolled day.
    case recompute

    /// The snapshot was handed to the widget bridge.
    case publish

    /// …and the bridge reloaded the widget timelines, because the content had changed.
    case reload
}

// MARK: - CompanionRefreshOutcome

/// How one refresh ended, and therefore what the system is told.
///
/// Six cases and no payloads, so the completion table asserts whole values rather than shapes. The
/// error behind ``acquisitionFailed`` is audited where it is caught rather than carried, because a
/// `String` payload would make every row of that table a substring match.
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

    /// The widget's action queue still held undrained rows, so the run skipped everything after the
    /// acquisition. See ``CompanionRefreshSteps/hasUndrainedWidgetActions`` for why that is the
    /// right answer rather than a missed refresh.
    case widgetActionsPending

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
    /// ``cancelled`` answers `false` for completeness; the coordinator never asks, because the
    /// expiration door completed the task before the run could return.
    var completesSuccessfully: Bool {
        switch self {
        case .reloaded, .unchanged, .widgetActionsPending: true
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

/// The five steps that need the acquired store, as closures.
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
    /// Asked FIRST, before the day roll, and a `true` ends the run. §17.2 limits the handler to its
    /// listed steps, so draining the queue here is not on the table — and publishing without
    /// draining would republish the app's own lower water count over the provisional one the
    /// widget's "+1" App Intent already wrote into the same file, making the count visibly go
    /// backwards until the next foreground. The roll is skipped along with the publish because a
    /// warm process's roll PUBLISHES on its own (through the store's internal path), which would
    /// regress the count by a second route this decision cannot see.
    let hasUndrainedWidgetActions: @MainActor () -> Bool

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

/// §17.2's handler: acquire, check the queue, roll, recompute, diff-and-publish — and nothing else,
/// ever.
///
/// ## What this type may not grow
///
/// A mesh call, a HealthKit read, a CloudKit force-sync, a Foundation Models prompt, or a store
/// construction. `BackgroundRefreshBoundaryTests` holds the whole directory to that mechanically;
/// this paragraph is the part a reviewer reads.
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
        if steps.hasUndrainedWidgetActions() {
            // R7: never silent. A skipped publish is invisible from the outside, and a queue that
            // never drains would otherwise look exactly like a refresh chain doing its job.
            FernletAuditLog.log("companionRefresh.widgetActionsStillPending")
            return Self.ending(.widgetActionsPending, trace)
        }
        return finish(steps: steps, trace: trace)
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
    /// - Returns: The finished run.
    private func finish(steps: CompanionRefreshSteps, trace: [CompanionRefreshStep]) -> CompanionRefreshRun {
        var trace = trace
        let dayAdvanced = steps.rollDay()
        trace.append(.rollDay)
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
            outcome: Self.outcome(for: publication),
            steps: trace,
            dayAdvanced: dayAdvanced,
            companionStateRaw: raw
        )
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

    /// Maps the bridge's verdict onto the pipeline's.
    ///
    /// - Parameter publication: What the widget bridge did.
    /// - Returns: What the system is told.
    private static func outcome(for publication: WidgetSnapshotPublication) -> CompanionRefreshOutcome {
        switch publication {
        case .reloaded: .reloaded
        case .unchanged: .unchanged
        case .writeFailed: .writeFailed
        }
    }
}
