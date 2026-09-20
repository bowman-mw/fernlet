//
//  RecipeShareLaneHarness.swift
//  Fernlet
//
//  DEBUG-only launch hooks for P9 item 3's Lane C run (Docs/Mesh-Network-Feasibility-Runbook.md,
//  § "Lane C — P9 item 3"): two or three Simulators on one Mac running the PRODUCTION recipe-share
//  radio over QUIC, driven with no UI navigation, so a `simctl launch --console-pty` transcript
//  beside the `com.fernlet` audit stream is the whole evidence.
//
//  Everything is wrapped in `#if DEBUG`; in release the surface is a hard-coded no-op that reads no
//  environment, starts nothing and sends nothing. Same convention as MeshRejectionMatrixHarness.
//
//  **It speaks no radio verb.** The recipe listener is started and stopped by the run policy alone:
//  this harness only puts the store's own facts — the selected tab and the nearby-recipe opt-in —
//  where `ProximityRunPolicy.recipeShareState` answers `.foregroundOnly`, and lets the funnel reach
//  the radio through `FernletStore.executeProximityRunActions` exactly as every other edge does.
//  The one manager door it uses is `sendRecipeShare(_:to:)`, which is the share sheet's own.
//
//  Nothing here is persisted beyond the ONE shipping setting it writes through the shipping setter
//  (`setAllowNearbyRecipeShares`, which already ships ON by default), so this owes no new row on the
//  persisted-surface wipe ledger.
//

import CoreGraphics
import FernletDomainModel
import Foundation
import ProximityKit
import UIKit

// MARK: - RecipeShareLaneRole

/// The part a Simulator plays in a recipe-share lane run.
///
/// Frozen automation tokens parsed from a DEBUG-only environment variable: never localized, never
/// persisted, never on a wire. An absent or unrecognized value installs nothing at all, which is
/// the behaviour every launch had before this file existed.
enum RecipeShareLaneRole: String, CaseIterable, Sendable {

    /// Run the radio and report what it sees; never send. The receiving side of a pair, and the
    /// third Simulator that watches a pairing go quiet and come back.
    case watch

    /// Run the radio and send a recipe to the first recipient that appears (or, with
    /// `FERNLET_RECIPE_LANE_DIAL_AT`, at a shared wall-clock instant, which is how a glare row is
    /// produced without two human taps).
    case dial
}

// MARK: - RecipeShareLaneRunState

/// What a lane run has already done, and what it last printed.
///
/// The poll runs at 1 Hz for minutes; echoing every tick would bury the handful of lines that
/// matter. Every field here is "the last value printed" or "the step already taken", so a line is
/// emitted exactly when something changed.
struct RecipeShareLaneRunState {

    /// The last summary line printed.
    var reported = ""

    /// The pending-share count at the last report.
    var pending = -1

    /// The newest diagnostic line printed.
    var diagnostic = ""

    /// Whether the first share has been handed to the manager.
    var dialed = false

    /// Whether `sending` has been observed for the first share — the send-state display clears
    /// itself 2.5 s after `sent`, so a 1 Hz poll cannot rely on catching the terminal value alone.
    var sawSending = false

    /// When the first share finished, or nil until it has.
    var finishedAt: Date?

    /// Whether the second (idle-survival) share has been handed over.
    var dialedSecond = false

    /// Whether the run has left the recipe tab.
    var left = false

    /// Whether the run has returned to it.
    var returned = false
}

// MARK: - RecipeShareLaneOptions

/// DEBUG launch switches for the recipe-share lane, read once per process so `xcrun simctl launch`
/// can drive a whole run without touching the app's UI.
///
/// Every switch is off when its variable is absent, and off means *exactly* today's behaviour: the
/// harness is not installed, no recipe is built, and nothing is echoed anywhere. The variable names
/// are frozen automation tokens, never display strings.
enum RecipeShareLaneOptions {

    #if DEBUG
    /// `FERNLET_RECIPE_LANE=watch|dial` — the part this Simulator plays. Absent means no harness.
    static let roleKey = "FERNLET_RECIPE_LANE"

    /// `FERNLET_RECIPE_LANE_LABEL=<token>` — names the run in the transcript, so several runs in
    /// one log file can be told apart.
    static let labelKey = "FERNLET_RECIPE_LANE_LABEL"

    /// `FERNLET_RECIPE_LANE_IMAGE_BYTES=<n>` — attach a synthesized picture of at least `n` bytes
    /// (capped by ``ProximityRecipeSharePayload/maxImageBytes``). Absent or 0 sends a text-only
    /// recipe, whose sealed frame stays under `MeshTransferStreamTable.bulkFloorBytes` and so rides
    /// the control stream — the negative half of the transfer-stream row.
    static let imageBytesKey = "FERNLET_RECIPE_LANE_IMAGE_BYTES"

    /// `FERNLET_RECIPE_LANE_DIAL_AT=<unix seconds>` — hold the first share until this wall-clock
    /// instant. Two Simulators given the same value tap each other inside the same tick, which is
    /// the glare row; absent means "send as soon as a recipient appears".
    static let dialAtKey = "FERNLET_RECIPE_LANE_DIAL_AT"

    /// `FERNLET_RECIPE_LANE_SECOND_SHARE_AFTER=<seconds>` — send a SECOND recipe this many seconds
    /// after the first one finished, over the pairing that is already up. Absent means one share.
    static let secondShareAfterKey = "FERNLET_RECIPE_LANE_SECOND_SHARE_AFTER"

    /// `FERNLET_RECIPE_LANE_LEAVE_AFTER=<polls>` — leave the recipe tab at this poll, which is the
    /// policy's own `stop` for the listener (the user walking out of the Food tab). Absent: never.
    static let leaveAfterKey = "FERNLET_RECIPE_LANE_LEAVE_AFTER"

    /// `FERNLET_RECIPE_LANE_RETURN_AFTER=<polls>` — come back to it at this poll, so the
    /// re-advertise under a fresh name is observable. Absent: never.
    static let returnAfterKey = "FERNLET_RECIPE_LANE_RETURN_AFTER"

    /// The part this Simulator plays, or nil when the harness is not installed.
    static let role = RecipeShareLaneRole(rawValue: ProcessInfo.processInfo.environment[roleKey] ?? "")

    /// This run's name in the transcript.
    static let label = ProcessInfo.processInfo.environment[labelKey] ?? "unlabelled"

    /// The picture's target size in bytes, or nil for a text-only recipe.
    static let imageBytes = parseCount(
        ProcessInfo.processInfo.environment[imageBytesKey],
        limit: ProximityRecipeSharePayload.maxImageBytes
    )

    /// The instant the first share may go out. ``Date/distantPast`` — send as soon as there is
    /// somebody to send to — when the variable is absent.
    static let dialAt = parseInstant(ProcessInfo.processInfo.environment[dialAtKey])

    /// Seconds of settled pairing before the second share, or nil for one share.
    static let secondShareAfterSeconds = parseCount(
        ProcessInfo.processInfo.environment[secondShareAfterKey],
        limit: RecipeShareLaneHarness.maxTicks
    )

    /// The poll at which the run leaves the recipe tab, or nil for never.
    static let leaveAfterTicks = parseCount(
        ProcessInfo.processInfo.environment[leaveAfterKey],
        limit: RecipeShareLaneHarness.maxTicks
    )

    /// The poll at which the run returns to it, or nil for never.
    static let returnAfterTicks = parseCount(
        ProcessInfo.processInfo.environment[returnAfterKey],
        limit: RecipeShareLaneHarness.maxTicks
    )

    /// Frozen diagnostic English naming what the launch environment asked for, for the transcript.
    static var summary: String {
        "label=\(label) role=\(role?.rawValue ?? "none") "
            + "imageBytes=\(imageBytes.map(String.init) ?? "none") "
            + "dialAt=\(dialAt == Date.distantPast ? "asap" : String(Int(dialAt.timeIntervalSince1970))) "
            + "secondShareAfter=\(secondShareAfterSeconds.map(String.init) ?? "never") "
            + "leaveAfter=\(leaveAfterTicks.map(String.init) ?? "never") "
            + "returnAfter=\(returnAfterTicks.map(String.init) ?? "never")"
    }

    /// Parses a whole non-negative count, clamped to `limit` so a mistyped variable can never ask
    /// for a size or a schedule the run does not reach (Power of 10 rule 2).
    private static func parseCount(_ raw: String?, limit: Int) -> Int? {
        guard let raw, let value = Int(raw), value >= 0 else { return nil }
        return min(value, limit)
    }

    /// Parses a unix-epoch instant, or answers ``Date/distantPast`` — "no wait at all".
    private static func parseInstant(_ raw: String?) -> Date {
        guard let raw, let seconds = TimeInterval(raw), seconds > 0 else { return Date.distantPast }
        return Date(timeIntervalSince1970: seconds)
    }
    #else
    /// Release: there is no role, so the harness is never installed.
    static let role: RecipeShareLaneRole? = nil

    /// Release: there is no run to name.
    static var summary: String { "off" }
    #endif
}

// MARK: - RecipeShareLaneHarness

/// Drives one Simulator through a recipe-share lane run: the radio up on the tab the policy runs it
/// for, a synthesized recipe sent to the first peer that appears, and a bounded 1 Hz report of what
/// the manager's own observable surface says.
///
/// ## What it does, and what it deliberately does not
///
/// It writes two store facts (`selectedTab`, the nearby-recipe opt-in through its shipping setter)
/// and then lets `FernletStore`'s policy funnel start the listener — so the radio is started by the
/// same seam the app uses, and a lane run cannot drift from the product path the way a harness that
/// called `start()` itself could. It sends through `sendRecipeShare(_:to:)`, the share sheet's own
/// door, and it accepts nothing: an inbound share lands in `pendingRecipeShares` exactly as it does
/// for a user, and the harness only reports that it is there.
///
/// **Release cannot install it.** The whole body is compiled out; the release ``install(store:)``
/// is empty, reads no environment and starts no task.
@MainActor
enum RecipeShareLaneHarness {

    /// Frozen console tag so a `--console-pty` transcript can be grepped down to this harness's own
    /// lines, distinct from `[mesh-matrix]`, `[mesh-flow]` and the transport's audit tokens. Never
    /// shown in the UI.
    static let consolePrefix = "[recipe-lane]"

    #if DEBUG
    /// Seconds between polls — one shared poll, as `MeshFlowDriver` has.
    static let pollIntervalSeconds: TimeInterval = 1

    /// Polls a run makes before it stops on its own: ten minutes at 1 Hz, enough for the settled
    /// pairing row (a share after 200 s idle) with room to spare. Bounded rather than `while true`
    /// (Power of 10 rule 2).
    static let maxTicks = 600

    /// The ephemeral instance-name prefix the radios wear. Held here as a literal on purpose: this
    /// is the token the lane asserts NEVER reaches a user-facing string, and a harness that read it
    /// from the transport would stop being an independent check of that claim.
    static let instanceNameToken = "fernlet-mesh-"

    /// The synthesized recipe's name. A frozen token so both transcripts can be grepped for it, and
    /// deliberately not prose: it is never localized and never a display decision.
    static let recipeName = "lane-recipe"

    /// Pixel sides tried when synthesizing the picture, smallest first. Noise at these sizes spans
    /// roughly 30 KB to 600 KB once JPEG-encoded, which brackets both sides of
    /// `MeshTransferStreamTable.bulkFloorBytes`.
    static let imageSideLadder = [256, 384, 512, 640, 768, 1024]

    /// Most pending shares named in one report line (Power of 10 rule 2).
    static let maxReportedPendingShares = 8

    /// Installs the harness when the launch environment asked for it.
    ///
    /// The two store writes happen BEFORE the poll starts and in this order for the same reason the
    /// matrix harness selects the Social tab before `startJoin()` (finding L-4): the run policy, not
    /// this harness, decides whether the listener stays up, and it answers `.stop` for the recipe
    /// radio on the Friends and Personal tabs. Food is one of the three tabs it answers
    /// `.foregroundOnly` for; the opt-in setter then re-runs the funnel, which is what performs the
    /// `start()`.
    ///
    /// - Parameter store: The app's store — the harness's only handle on the manager and the policy.
    static func install(store: FernletStore) {
        guard let role = RecipeShareLaneOptions.role else { return }
        echo("run \(RecipeShareLaneOptions.summary)")
        store.selectedTab = .food
        // The shipping setter, which ships ON: called for the run that finds it OFF, and harmless
        // for the rest. Its `reapplyProximityRunPolicy()` is the edge that starts the listener.
        store.setAllowNearbyRecipeShares(true)
        echo("tab=food optIn=on listening=\(store.recipeShareManager.isListening)")
        Task { @MainActor [weak store] in
            guard let store else { return }
            await run(store: store, role: role)
        }
    }

    /// The bounded poll: keep the radio up, report what changed, send what is due, move tabs.
    private static func run(store: FernletStore, role: RecipeShareLaneRole) async {
        var state = RecipeShareLaneRunState()
        for tick in 0..<maxTicks {
            do {
                try await Task.sleep(for: .seconds(pollIntervalSeconds))
            } catch {
                return
            }
            ensureRadio(store: store)
            report(store: store, state: &state)
            noteSendOutcome(store: store, state: &state)
            if let recipient = dialDue(store: store, role: role, state: state) {
                // The wait is at most one poll interval (``dialDue`` refuses a later instant), and
                // it is what makes a glare row reachable: two devices whose polls are up to a
                // second out of phase would otherwise tap ~1.5 s apart, which is long enough for
                // the first pairing to complete and the second tap to ride it instead of racing it.
                let wait = RecipeShareLaneOptions.dialAt.timeIntervalSinceNow
                if wait > 0 {
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                }
                state.dialed = true
                send(store: store, to: recipient, sequence: 1, idleSeconds: nil)
            }
            secondShareIfDue(store: store, role: role, state: &state)
            moveTabIfDue(store: store, state: &state, tick: tick)
        }
        echo("run ended: poll budget spent")
    }

    /// Re-runs the policy while the listener is down.
    ///
    /// Not a second starter: `reapplyProximityRunPolicy()` is the store's own edge, and on a tab the
    /// policy stops the radio for it asks for nothing. It exists because the launch order between
    /// this harness's `.task` and the scene edge that retains the foreground facts is not fixed —
    /// before the first scene edge the policy reads the most restrictive scene and answers `.stop`.
    private static func ensureRadio(store: FernletStore) {
        guard !store.recipeShareManager.isListening else { return }
        store.reapplyProximityRunPolicy()
    }

    /// Prints the manager's observable surface when any of it moved.
    ///
    /// The policy's own verdict is on the line beside the radio's account of itself, because those
    /// are the two different failures a dark lane run has — "the policy said stop" and "the radio
    /// could not start" — and a report that carries only `listening=false` cannot tell them apart.
    private static func report(store: FernletStore, state: inout RecipeShareLaneRunState) {
        let manager = store.recipeShareManager
        let line = "listening=\(manager.isListening) peers=\(manager.nearbyRecipients.count)"
            + " policy=\(describe(store.proximityRunVerdict?.recipeShare))"
            + " engaged=\(manager.engagedRecipientID == nil ? "no" : "yes")"
            + " send=\(describe(manager.sendState))"
            + " pending=\(manager.pendingRecipeShares.count)"
            + " uiToken=\(carriesInstanceNameToken(manager))"
        guard line != state.reported else { return }
        state.reported = line
        echo(line)
        reportDiagnostic(manager, state: &state)
        reportPendingShares(manager, state: &state)
    }

    /// Prints the newest line the manager would draw in "Connection details" when it changes — the
    /// only place a refused start or a turned-away peer says so.
    private static func reportDiagnostic(
        _ manager: ProximityRecipeShareManager, state: inout RecipeShareLaneRunState
    ) {
        guard let newest = manager.diagnosticEvents.last?.message, newest != state.diagnostic else { return }
        state.diagnostic = newest
        echo("diag \(newest)")
    }

    /// Names every inbound share the moment the queue's size changes: the title the review sheet
    /// would draw, and whether the picture survived the crossing.
    private static func reportPendingShares(
        _ manager: ProximityRecipeShareManager, state: inout RecipeShareLaneRunState
    ) {
        guard manager.pendingRecipeShares.count != state.pending else { return }
        state.pending = manager.pendingRecipeShares.count
        // R2: bounded by the manager's own cap and by this file's report cap.
        for share in manager.pendingRecipeShares.prefix(maxReportedPendingShares) {
            echo("received title=\(share.payload.recipe.title) "
                + "imageBytes=\(share.payload.imageJPEGData?.count ?? 0) "
                + "ingredients=\(share.payload.recipe.ingredientCount) "
                + "senderToken=\(share.senderDisplayName.contains(instanceNameToken))")
        }
    }

    /// Whether any user-facing string the manager publishes carries the radio's ephemeral instance
    /// name — the picker's rows and the "Connection details" diagnostics, read as a user would.
    private static func carriesInstanceNameToken(_ manager: ProximityRecipeShareManager) -> Bool {
        // R2: both collections are capped by the manager (recipients by the 2-device cap plus the
        // browse table, diagnostics by `ProximityRecipeShareDiagnostics`).
        for recipient in manager.nearbyRecipients where recipient.displayName.contains(instanceNameToken) {
            return true
        }
        for event in manager.diagnosticEvents where event.message.contains(instanceNameToken) {
            return true
        }
        return false
    }

    /// The policy's verdict for this radio as one frozen token. Exhaustive rather than a
    /// `String(describing:)`, because ``ProximityRunState`` deliberately carries no rawValue.
    private static func describe(_ state: ProximityRunState?) -> String {
        switch state {
        case .none: return "unset"
        case .run: return "run"
        case .foregroundOnly: return "foregroundOnly"
        case .hold: return "hold"
        case .stop: return "stop"
        }
    }

    /// The send pipeline as one frozen token, plus the failure text when there is one.
    private static func describe(_ state: ProximityRecipeShareManager.SendState) -> String {
        switch state {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .sending: return "sending"
        case .sent: return "sent"
        case .failed(let message): return "failed[\(message)]"
        }
    }

    /// Records when the first share stopped being in flight.
    ///
    /// `sendState` clears itself to `.idle` 2.5 s after `.sent`, so a 1 Hz poll can miss the
    /// terminal value outright; "we saw `sending`, and now we do not" is the fact that cannot be
    /// missed, and the settled-pairing row only needs the instant to the nearest poll.
    private static func noteSendOutcome(store: FernletStore, state: inout RecipeShareLaneRunState) {
        guard state.finishedAt == nil else { return }
        switch store.recipeShareManager.sendState {
        case .sending:
            state.sawSending = true
        case .sent, .failed:
            state.finishedAt = Date()
        case .idle where state.sawSending:
            state.finishedAt = Date()
        case .idle, .connecting:
            break
        }
    }

    /// The recipient of the first share when it is due within this poll, or nil.
    ///
    /// "Within this poll" rather than "now": the caller awaits the remaining fraction of a second,
    /// so an instant shared by two devices is honoured to the millisecond instead of to whichever
    /// tick happens to notice it first.
    private static func dialDue(
        store: FernletStore, role: RecipeShareLaneRole, state: RecipeShareLaneRunState
    ) -> ProximityRecipeShareRecipient? {
        guard role == .dial, !state.dialed,
              RecipeShareLaneOptions.dialAt.timeIntervalSinceNow <= pollIntervalSeconds else { return nil }
        return store.recipeShareManager.nearbyRecipients.first
    }

    /// Hands one share to the manager through the share sheet's own door.
    private static func send(
        store: FernletStore, to recipient: ProximityRecipeShareRecipient, sequence: Int, idleSeconds: Int?
    ) {
        let payload = lanePayload(sequence: sequence)
        echo("sending seq=\(sequence) at \(Date().timeIntervalSince1970) "
            + "idleSeconds=\(idleSeconds.map(String.init) ?? "none") "
            + "imageBytes=\(payload.imageJPEGData?.count ?? 0) "
            + "recipientToken=\(recipient.displayName.contains(instanceNameToken))")
        store.recipeShareManager.sendRecipeShare(payload, to: recipient)
    }

    /// Hands a second share over the pairing that is already up, after the run's settle time — the
    /// row that asks whether a QUIC tunnel idle for minutes is still a channel.
    private static func secondShareIfDue(
        store: FernletStore, role: RecipeShareLaneRole, state: inout RecipeShareLaneRunState
    ) {
        guard role == .dial, !state.dialedSecond,
              let after = RecipeShareLaneOptions.secondShareAfterSeconds,
              let finishedAt = state.finishedAt,
              Date().timeIntervalSince(finishedAt) >= TimeInterval(after),
              let recipient = store.recipeShareManager.nearbyRecipients.first else { return }
        state.dialedSecond = true
        send(store: store, to: recipient, sequence: 2,
             idleSeconds: Int(Date().timeIntervalSince(finishedAt)))
    }

    /// Leaves the recipe tab, and comes back to it, at the polls the run asked for — the user's own
    /// way of stopping and restarting this radio, through the policy rather than around it.
    private static func moveTabIfDue(
        store: FernletStore, state: inout RecipeShareLaneRunState, tick: Int
    ) {
        if let leave = RecipeShareLaneOptions.leaveAfterTicks, !state.left, tick >= leave {
            state.left = true
            store.selectedTab = .personal
            store.reapplyProximityRunPolicy()
            echo("left the recipe tab: listening=\(store.recipeShareManager.isListening)")
        }
        guard let back = RecipeShareLaneOptions.returnAfterTicks,
              state.left, !state.returned, tick >= back else { return }
        state.returned = true
        store.selectedTab = .food
        store.reapplyProximityRunPolicy()
        echo("returned to the recipe tab: listening=\(store.recipeShareManager.isListening)")
    }

    // MARK: - The synthesized recipe

    /// The recipe a lane run sends: a local (user-authored) recipe, plus the picture the run asked
    /// for. Deliberately built here rather than read from the library, so a fresh Simulator with no
    /// recipes of its own can still run the lane.
    private static func lanePayload(sequence: Int) -> ProximityRecipeSharePayload {
        let recipe = SharedRecipePayload(
            name: "\(recipeName)-\(sequence)",
            servings: 2,
            notes: "lane",
            ingredients: [
                SharedRecipeIngredient(name: "oats", quantity: 100, unit: "g", protein: 13, carbs: 67, fat: 7)
            ]
        )
        return ProximityRecipeSharePayload(
            recipe: ProximitySharedRecipe(kind: .local, local: recipe, saved: nil),
            imageJPEGData: laneImage()
        )
    }

    /// The smallest synthesized picture that meets the run's target and still fits the wire cap, or
    /// the largest that fits when no rung reaches the target; nil for a text-only run.
    private static func laneImage() -> Data? {
        guard let target = RecipeShareLaneOptions.imageBytes, target > 0 else { return nil }
        var best: Data?
        // R2: bounded by the ladder.
        for side in imageSideLadder {
            guard let data = MeshFlowDriver.noiseJPEG(side: side),
                  data.count <= ProximityRecipeSharePayload.maxImageBytes else { continue }
            best = data
            if data.count >= target { return data }
        }
        return best
    }

    /// Mirrors one harness line to stdout, where `simctl launch --console-pty` reads it.
    private static func echo(_ message: String) {
        print("\(consolePrefix) \(message)")
    }
    #else
    /// Release no-op — nothing is read, no task is started, no recipe is built and the store
    /// arrives by reference untouched.
    static func install(store: FernletStore) {}
    #endif
}
