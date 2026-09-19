// MeshContinuationDriverTests.swift
// FernletTests
//
// Network migration P8 item 5 (plan §14, §24.1, §25.1), in three suites:
//
// 1. `MeshContinuationRaiseWallTests` — **pass 1's wall.** `MeshSessionEvent.backgrounded` and
//    `.foregrounded` had NO shipping raiser at all before this item (P7's own honesty cell counted
//    zero and said so), so `MeshSessionState.continuingInBackground` was unreachable and the heart
//    stage's third leg could not be exercised by anything but a test. The wall says the raises now
//    exist and that there is exactly ONE of each, in one place, reached from the app through one
//    narrow public pair and from one file: three counts, comment-stripped, path-anchored, floored on
//    the file count so a moved root fails loudly rather than passing over nothing.
//
// 2. `MeshContinuationDriverTests` — the driver's own behaviour over a manager with no session:
//    which deliveries are adopted and how, which endings complete, and — the load-bearing negative —
//    that an ending with no task in hand raises nothing at all. On an `idle` manager every raise is
//    refused BY NAME (`lastSessionTransitionRejection == .noSessionYet`), which makes "a raise
//    arrived" and "no raise arrived" two different observable values rather than one silence.
//    Under the spot cells sits the **exhaustive sweep** (the fix round's F3): every sequence of
//    driver calls to depth three — 258 walks over a six-wide alphabet — with the two raises COUNTED
//    through the `MeshContinuationRaising` seam and held to one per entry into `running` and one per
//    exit from it. It is item 4's 48-row table one layer up: item 4 walls the table, this walls the
//    two guards that decide when the driver speaks.
//
// 3. `MeshContinuationDisagreementTests` — **pass 2, the cell §24.1 and §25.1 name**, on a real
//    two-node founding: a task running with the scene backgrounded means the pushed gate leg is
//    false AND the session is `continuingInBackground`, the re-entry pass does not run, the heart
//    stage's predicate is closed, a custodied heart DEFERS with nothing marked, and one foreground
//    edge plus one reopened gate judge it exactly once. Then the four corners of the two legs, which
//    is the independence claim: neither leg is written in terms of the other, and only both together
//    open the stage. The fix round adds the two round trips that are only observable on a live
//    session: a `reset()` **mid-task** gives the session leg back (F1 — the adversarial verify's
//    probe, red on all three legs before `reset()` was split), and an ownerless delivery leaves
//    nothing behind once it is ended (F5).
//
// **The deferred-quarter cell this copies** is `MeshRoutedHeartCeremonyTests`'
// `aBackgroundedRecipientDefersAndTheNextForegroundEdgeJudges`, which drives the state machine
// directly. The difference is the whole item: this one drives it through the SHIPPING path —
// `MeshContinuationDriver.taskDidStart()` → `MeshNetworkManager.beginBackgroundContinuation()` —
// so `MeshP6HonestyAcceptanceTests`' note that "no shipping path reaches it yet" is false as of this
// commit, and is corrected there in the same commit.
//
// The rig helper here is deliberately its own: the ceremony's `founded(...)` is `private` to that
// suite, and this one closes the recipient's gate rather than leaving it open, which is the
// difference the cell is about.

@testable import Fernlet
@testable import FernletCrypto
import Foundation
@testable import ProximityKit
import Testing

// MARK: - The wall

/// **Pass 1's wall.** The two session-state raises have one home each in ProximityKit, the app
/// reaches them through one public pair spoken in one file, and the app reaches the session machine
/// no other way.
struct MeshContinuationRaiseWallTests {

    /// The one file in ProximityKit allowed to raise either scene event.
    private static let manager = "MeshNetworkManager.swift"

    /// The one file in the app target allowed to speak either public raise.
    private static let driver = "MeshContinuationDriver.swift"

    /// Every `.swift` file under one repo-relative directory, comment-stripped — and the
    /// per-occurrence home list over it.
    ///
    /// **Reused, not copied a fifth time.** `MeshP7Acceptance.sources(under:)` /
    /// `homes(of:in:)` are the same two functions four suites already spell
    /// (`ProximityRunSeamsTests`, `ProximitySessionPollerTests`, `MeshRoutedLockedDeviceTests`,
    /// `MeshP7AcceptanceTests`); both are `nonisolated static`, so a non-isolated wall may call
    /// them. Whole-line comments go so a wall states something about CODE rather than about the
    /// prose explaining it — the raise pair's own doc names its callers at length.
    private static func codeSources(under relativePath: String) throws -> [(name: String, code: String)] {
        try MeshP7Acceptance.sources(under: relativePath)
    }

    /// The file names in which `needle` occurs, one entry per occurrence.
    private static func homes(of needle: String, in sources: [(name: String, code: String)]) -> [String] {
        MeshP7Acceptance.homes(of: needle, in: sources)
    }

    /// **(a)** Each scene event is raised exactly once in the whole package, and each raise sits
    /// inside the public door named for it — brace-matched, so a raise that drifted out of the pair
    /// into the file around it reddens.
    @Test func eachSceneEventIsRaisedExactlyOnceAndInsideItsOwnPublicDoor() throws {
        let kit = try Self.codeSources(under: "FernletKit/Sources")
        #expect(kit.count >= 100, "the package scan lost its files")
        #expect(Self.homes(of: "applySessionEvent(.backgrounded", in: kit) == [Self.manager],
                "the backgrounded raise has exactly one home, and it is the manager's own door")
        #expect(Self.homes(of: "applySessionEvent(.foregrounded", in: kit) == [Self.manager],
                "and so does the foregrounded raise")
        let source = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/\(Self.manager)"))
        let began = try #require(
            MeshRoutedSourceScan.bracedBody(after: "public func beginBackgroundContinuation()", in: source),
            "the public begin door is gone")
        #expect(began.contains("applySessionEvent(.backgrounded)"),
                "and it is what raises the backgrounded event")
        let ended = try #require(
            MeshRoutedSourceScan.bracedBody(after: "public func endBackgroundContinuation()", in: source),
            "the public end door is gone")
        #expect(ended.contains("applySessionEvent(.foregrounded)"),
                "and its sibling raises the foregrounded one")
    }

    /// **(b)** The app speaks each public raise exactly once, from the continuation driver and from
    /// nowhere else. A second caller — a scene handler, a view, the store's funnel — would mean two
    /// answers to "is this mesh being continued", which is the shape P7's gate leg already fixed
    /// once for the foreground fact.
    @Test func theAppSpeaksEachRaiseExactlyOnceAndOnlyFromTheDriver() throws {
        let app = try Self.codeSources(under: "App")
        #expect(app.count >= 100, "the app-target scan lost its files")
        #expect(Self.homes(of: "beginBackgroundContinuation()", in: app) == [Self.driver],
                "the begin raise is spoken once, by the continuation driver")
        #expect(Self.homes(of: "endBackgroundContinuation()", in: app) == [Self.driver],
                "and the end raise is spoken once, by the same file")
    }

    /// **(c)** The app reaches the session machine through that pair and nothing else: zero
    /// `applySessionEvent(` anywhere under `App/`. It is `internal` to ProximityKit today, so this
    /// is a wall against the widening as much as against the call.
    @Test func theAppNeverOffersTheSessionMachineAnEventDirectly() throws {
        let app = try Self.codeSources(under: "App")
        #expect(app.count >= 100, "the app-target scan lost its files")
        #expect(Self.homes(of: "applySessionEvent(", in: app).isEmpty,
                "the app's only session-state verbs are the two public raises")
    }

    /// The driver submits nothing, spins nothing, speaks no radio verb, writes no routed access
    /// gate and calls no store setter. Item 6 adds the `BackgroundTasks` half to this same file, so
    /// the needles it will legitimately bring are named here rather than assumed absent forever —
    /// removing one is then a deliberate edit with this list in front of the person making it.
    @Test func theDriverIsSessionStateOnly() throws {
        let code = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/\(Self.driver)"))
        #expect(!code.isEmpty, "the driver is gone")
        let forbidden = [
            "applyRoutedAccessGate(", "MeshRoutedAccessGate(",          // W8: the gate has one writer
            "reapplyProximityRunPolicy(", "applyProximityRunPolicyFromView(",
            ".startJoin(", ".stopJoin(", ".resumeSearchingForPartitionedMesh(",
            ".holdCommittedLinks(", ".leaveSession()", ".endSessionAfterDiscoveryTimeout(",
            "presenceManager.", "recipeShareManager.",                  // the retirement wall's listeners
            "BackgroundTasks", "BGTaskScheduler", "BGContinuedProcessingTask",  // item 6's
            "Task {", "Timer", "DispatchQueue",                         // nothing spins (ML1/ML4, R2)
            "UserDefaults"                                              // no persisted surface
        ]
        // R2: bounded by the literal list.
        for needle in forbidden {
            #expect(!code.contains(needle),
                    "the continuation driver's session-state half must not contain `\(needle)`")
        }
    }

    /// **The independence pin, in source.** The gate writer decides nothing from the session
    /// machine, and neither raise reads the gate. Two legs that read each other are one leg with two
    /// names, and the disagreement §24.1 asks for would be unstatable.
    @Test func neitherLegIsWrittenInTermsOfTheOther() throws {
        let store = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/FernletStore.swift"))
        let funnel = try #require(
            MeshRoutedSourceScan.bracedBody(after: "private func runProximityPolicy(", in: store),
            "the run-policy core is gone from the store")
        #expect(!funnel.contains("sessionState") && !funnel.contains("continuingInBackground"),
                "the gate writer reads no session state — the scene phase is its only foreground fact")
        let source = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/\(Self.manager)"))
        // R2: bounded by the two doors.
        for door in ["public func beginBackgroundContinuation()", "public func endBackgroundContinuation()"] {
            let body = try #require(MeshRoutedSourceScan.bracedBody(after: door, in: source),
                                    "a public raise door is gone")
            #expect(!body.contains("routedAccessGate") && !body.contains("Gate"),
                    "a raise that read the routed access gate would make one leg the other")
        }
    }
}

// MARK: - The driver

/// The driver's claim arithmetic and its two raises, over a manager with no session — where every
/// raise is refused by name, which is what makes "a raise arrived" observable at all.
@MainActor
@Suite(.serialized)
struct MeshContinuationDriverTests {

    private let store = makeTestStore()

    /// A driver over a fresh manager that holds no session.
    ///
    /// - Returns: The driver and the manager it raises to.
    private func driverOverAnIdleManager() -> (driver: MeshContinuationDriver, manager: MeshNetworkManager) {
        let manager = MeshNetworkManager(store: store)
        return (MeshContinuationDriver(meshNetworkManager: manager), manager)
    }

    /// A delivered task is adopted from `idle` — ownerless, because nobody asked for it — and the
    /// background raise really reaches the session machine.
    @Test func aDeliveredTaskIsAdoptedOwnerlessAndTheBackgroundEdgeIsRaised() {
        let (driver, manager) = driverOverAnIdleManager()
        #expect(driver.state == .idle, "the precondition: no claim has been made")
        #expect(manager.lastSessionTransitionRejection == nil,
                "and the precondition on the other side: nothing has been offered to the machine")

        let adoption = driver.taskDidStart()

        #expect(adoption == .ownerless,
                "nobody asked for this task, so item 6 must end it at once rather than rest in `running`")
        #expect(driver.state == .running, "but it IS adopted — an unadopted handle is uncompletable")
        #expect(driver.lastAudit == .started, "and the move is named by its frozen token")
        #expect(manager.lastSessionTransitionRejection == .noSessionYet,
                "the raise reached the machine, which refused it BY NAME rather than trapping")
        #expect(manager.sessionState == .idle, "and moved nothing: there is no session to continue")
    }

    /// **The ownerless delivery's obligation** (item 7's verify, obligation 2): end it at once —
    /// which still completes it exactly once, `false` — and then present NOTHING. Leaving
    /// `expired` / `cancelled` standing would put "iOS ended your background session" on the
    /// Friends tab for a session that never existed.
    @Test func anOwnerlessDeliveryIsEndedAtOnceCompletesFailedAndPresentsNothing() {
        let (driver, _) = driverOverAnIdleManager()
        #expect(driver.taskDidStart() == .ownerless, "the precondition")

        driver.taskDidEnd(.cancelled)

        #expect(driver.state == .idle, "an app-side end of a task nobody asked for leaves no claim")
        #expect(driver.lastAudit == nil, "and nothing to present: an ending explains something only if a claim was made")
        #expect(driver.consumePendingCompletion() == .failed,
                "but the system is still owed exactly one failed completion, which the caller takes")
        #expect(driver.consumePendingCompletion() == nil, "once — a second read completes nothing twice")
    }

    /// Every ending of an unclaimed task has the same two halves: the completion item 4's oracle
    /// owes, and a projection reset. The completion's own flag is the only thing that differs.
    @Test func everyEndingOfAnUnclaimedTaskCompletesOnceAndPresentsNothing() {
        let owed: [MeshContinuationEndReason: MeshContinuationCompletion] = [
            .expired: .failed, .cancelled: .failed, .sessionEnded: .succeeded, .appForegrounded: .succeeded
        ]
        let manager = MeshNetworkManager(store: store)
        // R2: bounded by the ending vocabulary.
        for reason in MeshContinuationEndReason.allCases {
            let driver = MeshContinuationDriver(meshNetworkManager: manager)
            driver.taskDidStart()

            driver.taskDidEnd(reason)

            #expect(driver.state == .idle, "\(reason.rawValue): an unclaimed task leaves no claim behind")
            #expect(driver.lastAudit == nil, "\(reason.rawValue): and nothing to present")
            #expect(driver.pendingCompletion == owed[reason],
                    "\(reason.rawValue): the completion the table owes, and exactly one of it")
        }
    }

    /// `reset()` returns the projection, ENDS the task in hand on the way (the fix round's F1) and
    /// forgets the system's debt not at all — a wipe does not excuse the app from completing a
    /// handle it is holding.
    @Test func resetReturnsTheProjectionWithoutForgettingTheSystemsDebt() {
        let manager = MeshNetworkManager(store: store)
        let driver = MeshContinuationDriver(meshNetworkManager: manager)
        driver.taskDidStart()
        #expect(driver.state == .running && driver.lastAudit == .started, "the precondition: a task in hand")

        driver.reset()

        #expect(driver.state == .idle, "the claim is back where a driver is born")
        #expect(driver.lastAudit == nil, "with nothing to present")
        #expect(driver.consumePendingCompletion() == .failed,
                "and the running task was ENDED rather than forgotten: cancelled, completed false, once")
        #expect(driver.consumePendingCompletion() == nil, "once — the debt is a slot, not a queue")
        let owing = MeshContinuationDriver(meshNetworkManager: manager)
        owing.taskDidStart()
        owing.taskDidEnd(.sessionEnded)

        owing.reset()

        #expect(owing.pendingCompletion == .succeeded,
                "and a pending completion survives a reset: dropping it is what loses an app its continuation privilege")
    }

    /// **The load-bearing negative.** An ending with no task in hand moves no claim, owes no
    /// completion and — this is the part a second code path would break — raises NOTHING. The
    /// foreground raise sits behind a completion, never behind an event.
    @Test func anEndingWithNoTaskInHandRaisesNothingAndCompletesNothing() {
        let (driver, manager) = driverOverAnIdleManager()

        // R2: bounded by the reason vocabulary.
        for reason in MeshContinuationEndReason.allCases { driver.taskDidEnd(reason) }

        #expect(driver.state == .idle, "an ending of nothing moves no claim")
        #expect(driver.pendingCompletion == nil, "and owes the system nothing")
        #expect(manager.lastSessionTransitionRejection == nil,
                "and offered the session machine no event at all — not even a refused one")
    }

    /// A second delivery while a task is in hand is absorbed: the claim does not move, so nothing is
    /// re-raised and the handle the caller was just given is not this driver's to complete.
    @Test func aSecondDeliveryIsAbsorbedAndAdoptsNothingNew() {
        let (driver, _) = driverOverAnIdleManager()
        #expect(driver.taskDidStart() == .ownerless, "the precondition: one task adopted")

        let second = driver.taskDidStart()

        #expect(second == .absorbed, "a delivery arriving on a running claim is not a second adoption")
        #expect(driver.state == .running, "and the claim is where it was")
        #expect(driver.lastAudit == .started,
                "and the projection keeps its token — an absorbed row is not a move, so it replaces nothing")
    }

    /// The two frozen vocabularies, and the one mapping between the driver's endings and item 4's
    /// events. A fifth ending, or a renamed token, is a deliberate edit here.
    @Test func theEndingAndAdoptionVocabulariesAreFrozenAndMapOnce() {
        #expect(MeshContinuationEndReason.allCases.map(\.rawValue)
                == ["expired", "cancelled", "sessionEnded", "appForegrounded"],
                "the ending vocabulary is four frozen English tokens")
        #expect(MeshContinuationEndReason.allCases.map(\.event)
                == [.taskExpired, .taskCancelled, .sessionEnded, .appForegrounded],
                "each ending names exactly one of item 4's events, and no ending names an adoption")
        #expect(MeshContinuationAdoption.allCases.map(\.rawValue)
                == ["claimed", "ownerless", "absorbed"],
                "and the adoption vocabulary is three")
    }

    // MARK: The exhaustive sweep

    /// A counting stand-in for the manager's two raise doors, and nothing else.
    ///
    /// This is why ``MeshContinuationDriver`` holds a `MeshContinuationRaising` rather than a
    /// `MeshNetworkManager`: the manager is a `final class`, so the raises could not be counted at
    /// all without the seam, and the spot cells above can only observe a raise indirectly (a named
    /// refusal, or a live session's state moving). A count is what the sweep's invariant needs.
    @MainActor
    private final class RaiseRecorder: MeshContinuationRaising {

        /// How many times the driver said the scene went dark.
        private(set) var beginCount = 0

        /// How many times it said the foreground was carrying the session again.
        private(set) var endCount = 0

        func beginBackgroundContinuation() { beginCount += 1 }

        func endBackgroundContinuation() { endCount += 1 }
    }

    /// One call the sweep may make on a driver — the whole alphabet item 5 gives a caller.
    private enum SweepCall: Equatable {

        /// A `BGContinuedProcessingTask` was delivered.
        case start

        /// The task in hand is over, for one of the four reasons.
        case end(MeshContinuationEndReason)

        /// The projection is being returned (the hard stop, or a new mesh).
        case reset

        /// A frozen diagnostic name, for the failure message.
        var token: String {
            switch self {
            case .start: return "start"
            case .end(let reason): return "end(\(reason.rawValue))"
            case .reset: return "reset"
            }
        }
    }

    /// The six calls, in a frozen order the walk indexes into.
    private static let sweepAlphabet: [SweepCall] =
        [.start] + MeshContinuationEndReason.allCases.map(SweepCall.end) + [.reset]

    /// How many calls deep the sweep goes. **Three**: one move cannot show a re-delivery, two
    /// cannot show a re-delivery after an ending that reset the projection, three can — and every
    /// shorter sequence is a prefix of one, so nothing between the depths is skipped. With a
    /// six-wide alphabet that is 6 + 36 + 216 = 258 walks, each over pure values.
    private static let sweepDepth = 3

    /// **The exhaustive sweep** — item 4's 48-row table's counterpart one layer up, and the wall the
    /// seven spot cells above are not.
    ///
    /// Item 4 walls the TABLE; nothing walled the two guards that decide when the driver speaks. So
    /// this walks every sequence of driver calls up to ``sweepDepth`` from a driver born where every
    /// driver is born, counting the raises through the seam, and asserts three things on each walk:
    ///
    /// - one `begin` per ENTRY into `running` — never a second for the same task, never one without
    ///   an entry;
    /// - one `end` per EXIT from `running` — item 4's oracle (`completion != nil ⟺ (from ==
    ///   .running && next != .running)`) projected onto the driver, which is what keeps the pair
    ///   BALANCED for the system that granted the task;
    /// - the completion an exit owes is takeable exactly once, and no other step owes one.
    ///
    /// The walk consumes after every call on purpose. `pendingCompletion` is a slot, not a queue —
    /// a completion nobody took is overwritten by the next one — so a walk that did not consume
    /// would be asserting a property this type does not have and item 6 is told about instead
    /// ("complete the handle you hold first").
    @Test func everySequenceOfDriverCallsRaisesOncePerEntryAndOncePerExit() {
        var walks = 0
        var adoptions: Set<MeshContinuationAdoption> = []
        // R2: bounded by `sweepDepth`.
        for length in 1...Self.sweepDepth {
            // R2: bounded by the alphabet's size raised to `length`.
            for index in 0..<Self.walkCount(length: length) {
                adoptions.formUnion(Self.walk(Self.sequence(index: index, length: length)))
                walks += 1
            }
        }
        #expect(walks == 258, "6 + 36 + 216 — a six-wide alphabet walked to depth three")
        #expect(adoptions.map(\.rawValue).sorted() == ["absorbed", "ownerless"],
                """
                and `claimed` is NOT reachable through item 5's alphabet: item 4's table does land a \
                foreground return on `requested`, but the driver's unclaimed arm resets the \
                projection before any caller sees it, and nothing here can raise `firstPeerCommitted`. \
                Item 6 adds that edge and this expectation changes with it — deliberately.
                """)
    }

    /// Walks one sequence on a fresh driver over a counting recorder, asserting the invariants.
    ///
    /// - Parameter sequence: The calls to make, in order.
    /// - Returns: The adoptions the deliveries in this walk answered with.
    private static func walk(_ sequence: [SweepCall]) -> [MeshContinuationAdoption] {
        let recorder = RaiseRecorder()
        let driver = MeshContinuationDriver(meshNetworkManager: recorder)
        let name = sequence.map(\.token).joined(separator: " → ")
        var entries = 0
        var exits = 0
        var adoptions: [MeshContinuationAdoption] = []
        // R2: bounded by the sequence's length, which is at most `sweepDepth`.
        for call in sequence {
            let before = driver.state
            if let adoption = perform(call, on: driver) { adoptions.append(adoption) }
            let left = before == .running && driver.state != .running
            if before != .running && driver.state == .running { entries += 1 }
            if left { exits += 1 }
            #expect((driver.consumePendingCompletion() != nil) == left,
                    "\(name): a completion is owed exactly on an exit from `running`, and nowhere else")
            #expect(driver.consumePendingCompletion() == nil,
                    "\(name): and it is takeable exactly once — a second read completes nothing twice")
        }
        #expect(recorder.beginCount == entries, "\(name): one begin raise per entry into `running`")
        #expect(recorder.endCount == exits, "\(name): one end raise per exit from `running`")
        return adoptions
    }

    /// Makes one call.
    ///
    /// - Parameters:
    ///   - call: Which one.
    ///   - driver: The driver under walk.
    /// - Returns: The adoption, for a delivery; nil for the calls that answer nothing.
    private static func perform(_ call: SweepCall, on driver: MeshContinuationDriver) -> MeshContinuationAdoption? {
        switch call {
        case .start: return driver.taskDidStart()
        case .end(let reason): driver.taskDidEnd(reason); return nil
        case .reset: driver.reset(); return nil
        }
    }

    /// The `index`-th sequence of `length` calls: the base-six expansion of the index, which is the
    /// enumeration without a recursive generator (Power of 10 R1).
    ///
    /// - Parameters:
    ///   - index: Which sequence, `0 ..< walkCount(length:)`.
    ///   - length: How many calls.
    /// - Returns: The sequence.
    private static func sequence(index: Int, length: Int) -> [SweepCall] {
        var calls: [SweepCall] = []
        var remaining = index
        // R2: bounded by `length`.
        for _ in 0..<length {
            calls.append(sweepAlphabet[remaining % sweepAlphabet.count])
            remaining /= sweepAlphabet.count
        }
        return calls
    }

    /// How many sequences of `length` calls there are.
    ///
    /// - Parameter length: How many calls.
    /// - Returns: The alphabet's size raised to that power, by multiplication rather than `pow`.
    private static func walkCount(length: Int) -> Int {
        var total = 1
        // R2: bounded by `length`.
        for _ in 0..<length { total *= sweepAlphabet.count }
        return total
    }

    /// **`.claimed` is unreachable through item 5's alphabet, and the reason is the DRIVER's, not
    /// the table's** (the fix round's F4, correcting both the report's handoff sentence and the
    /// verify's correction of it).
    ///
    /// Item 4 really does land a foreground return on `requested` — a foreground glance spends the
    /// task, not the session's claim — so the row is there and item 6 will reach it. What the sweep
    /// above measures is that no sequence of item 5's own calls can: entering `running` claimed
    /// requires `requested` first, `requested` is reachable here only from `running` itself, and the
    /// unclaimed arm resets the projection on the way. `firstPeerCommitted` is the edge that breaks
    /// the circle, and it is item 6's.
    @Test func aForegroundReturnLandsOnRequestedInTheTableAndIsResetByTheUnclaimedArm() {
        #expect(MeshContinuationCoordinator.transition(from: .running, on: .appForegrounded).next == .requested,
                "item 4's row is real: the task is spent, the session's claim is not")
        let (driver, _) = driverOverAnIdleManager()
        #expect(driver.taskDidStart() == .ownerless, "but the first delivery today is unclaimed")

        driver.taskDidEnd(.appForegrounded)

        #expect(driver.state == .idle,
                "so that `requested` landing is reset by the unclaimed arm before any caller sees it")
        #expect(driver.taskDidStart() == .ownerless,
                "and the next delivery is ownerless again — `.claimed` waits for item 6's firstPeerCommitted")
    }
}

// MARK: - The disagreement

/// **Pass 2.** The cell plan §24.1 and §25.1 name, on a real two-node founding, plus the four
/// corners that prove the two legs are independent.
@MainActor
@Suite(.serialized)
struct MeshContinuationDisagreementTests {

    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    /// The gate the run policy pushes for a BACKGROUNDED scene on an unlocked device —
    /// `appIsForeground` is `FernletApp.routedGateForeground(for: .background)`, which is `false`,
    /// and the device is still unlocked, so this is the honest value rather than
    /// `MeshRoutedAccessGate.closed`.
    private static let backgroundedGate = MeshRoutedAccessGate(
        protectedDataAvailable: true, appIsForeground: false, duressActive: false
    )

    /// A founded pair with hearts on at both ends, a ledger at each, the vault rows a mesh heart
    /// needs and the recipient's gate open — **seeded, and the same honesty applies as to the
    /// ceremony suite**: production reaches mutual vault rows only across two sessions, so this
    /// proves the mechanics and item 10's Lane C script proves the feature.
    ///
    /// - Parameter label: The diagnostic prefix.
    /// - Returns: The rig and the recipient's ledger.
    private func foundedHeartPair(_ label: String) async throws -> (rig: MeshFoundingRig, ledger: ProximityHeartLedger) {
        let rig = try MeshFoundingRig.build(2, label: label)
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        try await rig.settle()
        let ledger = rig.isolatedHeartLedger(now: day)
        rig.nodes[0].manager.heartLedger = rig.isolatedHeartLedger(now: day)
        rig.nodes[1].manager.heartLedger = ledger
        rig.nodes[0].store.setAllowNearbyHearts(true)
        rig.nodes[1].store.setAllowNearbyHearts(true)
        rig.trustPeer(at: 1, asSeenFrom: 0)
        rig.trustPeer(at: 0, asSeenFrom: 1)
        rig.openGate(at: 1)
        #expect(rig.nodes[1].manager.sessionState == .activeForeground,
                "the precondition: a live FOREGROUND session, which is what this item takes away")
        #expect(rig.nodes[1].manager.mayCommitRoutedHeartLedgerJudgement,
                "and an open heart stage, so the closure below is this cell's doing")
        return (rig, ledger)
    }

    /// Pushes one routed access gate at a node, under the pinned install binding, exactly as the
    /// store's funnel pushes it.
    ///
    /// - Parameters:
    ///   - gate: The facts to push.
    ///   - node: Which node.
    ///   - rig: The rig.
    /// - Returns: What the re-entry pass did, or nil when nothing moved or no leg owed work.
    @discardableResult
    private func pushGate(
        _ gate: MeshRoutedAccessGate, at node: Int, in rig: MeshFoundingRig
    ) -> MeshRoutedReentryReport? {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            let report = rig.nodes[node].manager.applyRoutedAccessGate(gate, now: Date())
            return report
        }
    }

    /// **The item's headline.** A mesh continued in the background by a real
    /// `BGContinuedProcessingTask` — driven here through the shipping path, `taskDidStart()` →
    /// `beginBackgroundContinuation()` — holds a heart's ciphertext, judges nothing, marks nothing,
    /// and judges it exactly ONCE on the foreground edge.
    @Test func aContinuedMeshDefersAHeartAndOneForegroundEdgeJudgesItOnce() async throws {
        let (rig, ledger) = try await foundedHeartPair("p8-continuation-defer")
        defer { rig.teardown() }
        let recipient = rig.nodes[1].manager
        let driver = MeshContinuationDriver(meshNetworkManager: recipient)
        var judged: [UUID] = []
        recipient.onHeartJudgedForTesting = { judged.append($0.giftID) }

        // 1. The scene goes dark. The run policy's own leg falls — and a FALLING leg owes no work.
        let closing = pushGate(Self.backgroundedGate, at: 1, in: rig)
        #expect(closing == nil, "the routed re-entry does NOT run on a falling foreground leg")
        #expect(!recipient.routedAccessGate.isOpen,
                "the pushed gate leg is false, exactly as `routedGateForeground(for: .background)` decides it")

        // 2. The task arrives. The OTHER leg moves, through item 5's raise and nothing else.
        #expect(driver.taskDidStart() == .ownerless, "the task is adopted")
        #expect(recipient.sessionState == .continuingInBackground,
                "and the mesh knows it is being continued rather than merely dark")
        #expect(!recipient.mayCommitRoutedHeartLedgerJudgement,
                "so the heart stage's predicate is closed — a continued mesh custodies ciphertext and judges nothing")

        // 3. A heart sent now is held, unjudged and unmarked.
        let giftID = try #require(rig.sendHeartReturningItemID(from: 0, to: 1, name: "Robin"))
        try await rig.settle()
        let key = rig.key(origin: 0, itemID: giftID)
        #expect(judged.isEmpty, "a continued mesh judges no heart")
        #expect(ledger.receivedHearts.isEmpty, "and its ledger holds none")
        let held = try #require(rig.routedIndex(1)?.record(for: key))
        #expect(held.isComplete, "but it HOLDS the ciphertext — custody is ciphertext-only")
        #expect(held.deliveredAt == nil, "and stamps no delivery")
        #expect(!recipient.routedHeartRefusedKeys.contains(key),
                "and marks nothing: a closed predicate is retryable by construction")

        // 4. The person comes back. One foreground edge on each leg, and exactly one ack.
        driver.taskDidEnd(.appForegrounded)
        #expect(driver.consumePendingCompletion() == .succeeded,
                "the delivered task is completed once, successfully")
        #expect(recipient.sessionState == .activeForeground, "the session leg is back")
        let report = try #require(pushGate(MeshRoutedDrainRig.openGate, at: 1, in: rig),
                                  "a RISING foreground leg runs the re-entry pass")
        #expect(report.legs.foregroundRose, "on the leg the scene moved")
        #expect(judged == [giftID], "the gift is judged exactly ONCE, by its own per-gift witness")
        #expect(ledger.receivedHearts.map(\.id) == [giftID], "and the ledger holds it once")
        let stamped = try #require(rig.routedIndex(1)?.record(for: key))
        #expect(stamped.deliveredAt != nil, "with the delivery stamped")
        #expect(stamped.recipientReceipts.filter { $0.recipientFingerprint == rig.nodes[1].fingerprint }.count == 1,
                "and exactly one receipt of this device's own — the ack, once")
    }

    /// **The independence claim, as four corners.** Gate and session are separate facts: the raise
    /// moves no gate, the gate push moves no session state, and only both together open the stage.
    @Test func theTwoLegsMoveIndependentlyAndOnlyBothTogetherOpenTheStage() async throws {
        let (rig, _) = try await foundedHeartPair("p8-continuation-legs")
        defer { rig.teardown() }
        let recipient = rig.nodes[1].manager
        let driver = MeshContinuationDriver(meshNetworkManager: recipient)
        #expect(recipient.mayCommitRoutedHeartLedgerJudgement, "corner 1: both legs open ⇒ open")

        driver.taskDidStart()

        #expect(recipient.routedAccessGate.isOpen, "the raise touched the gate not at all")
        #expect(!recipient.mayCommitRoutedHeartLedgerJudgement,
                "corner 2: gate OPEN, session continuing in the background ⇒ still closed")

        driver.taskDidEnd(.appForegrounded)
        pushGate(Self.backgroundedGate, at: 1, in: rig)

        #expect(recipient.sessionState == .activeForeground, "the gate push moved the session leg not at all")
        #expect(!recipient.mayCommitRoutedHeartLedgerJudgement,
                "corner 3: gate CLOSED, session foreground ⇒ still closed")

        pushGate(MeshRoutedDrainRig.openGate, at: 1, in: rig)

        #expect(recipient.mayCommitRoutedHeartLedgerJudgement, "corner 4: and only both together open it")
    }

    /// A second delivery on a live session re-raises nothing — the absorbed row, measured where a
    /// raise WOULD be visible: the manager is put back in the foreground by hand first, so a
    /// re-raise would drag it into the background again.
    @Test func aSecondDeliveryReRaisesNothingOnALiveSession() async throws {
        let (rig, _) = try await foundedHeartPair("p8-continuation-absorb")
        defer { rig.teardown() }
        let recipient = rig.nodes[1].manager
        let driver = MeshContinuationDriver(meshNetworkManager: recipient)
        driver.taskDidStart()
        #expect(recipient.sessionState == .continuingInBackground, "the precondition: one raise landed")
        recipient.applySessionEvent(MeshSessionEvent.foregrounded)
        #expect(recipient.sessionState == .activeForeground,
                "and the machine is put back by hand, so a re-raise would be visible")

        #expect(driver.taskDidStart() == .absorbed, "the second delivery is absorbed")

        #expect(recipient.sessionState == .activeForeground,
                "and raised nothing: the raise sits behind the ENTRY into `running`, not behind the event")
    }

    /// **A reset mid-task ends it first** (the fix round's F1 — the adversarial verify's probe,
    /// which was RED on all three legs below before `reset()` was split in two).
    ///
    /// This is the call item 6 is told to wire to the proximity hard stop (delete-all, leg 7b) and
    /// to a new mesh start, so it will be made with a task in hand. A reset that only cleared the
    /// fields would leave the mesh `continuingInBackground` **for the life of the session** —
    /// `endBackgroundContinuation()` is the only shipping raiser of `.foregrounded`, and the driver
    /// has just forgotten the task that would have raised it — with the heart stage closed behind
    /// it and every routed heart deferring silently. The probe is here rather than on the
    /// session-less manager because those two legs are only observable on a live one.
    @Test func aResetMidTaskCompletesTheHandleAndReturnsTheSessionLeg() async throws {
        let (rig, _) = try await foundedHeartPair("p8-continuation-reset-midtask")
        defer { rig.teardown() }
        let recipient = rig.nodes[1].manager
        let driver = MeshContinuationDriver(meshNetworkManager: recipient)
        driver.taskDidStart()
        #expect(recipient.sessionState == .continuingInBackground,
                "the precondition: a task in hand and a mesh being continued behind it")

        driver.reset()

        #expect(driver.pendingCompletion != nil,
                "leg A: a reset mid-task still owes the system a completion for the handle in hand")
        #expect(driver.consumePendingCompletion() == .failed,
                "…the cancelled one — the app cannot serve a task it is wiping — taken exactly once")
        #expect(recipient.sessionState == .activeForeground,
                "leg B: and returns the session leg; nothing else in shipping raises `.foregrounded`")
        #expect(recipient.mayCommitRoutedHeartLedgerJudgement,
                "leg C: so a wipe does not close the heart stage for the life of the mesh")
        #expect(driver.state == .idle && driver.lastAudit == nil,
                "and the projection is back where a driver is born, with nothing to present")
    }

    /// **An unwanted delivery is harmless on a LIVE mesh — once it is ended** (the fix round's F5).
    ///
    /// `taskDidStart()` raises `begin` even when nobody asked for the task, which is the right call
    /// (the alternative is an unpaired `end`), but it means an ownerless delivery backgrounds a live
    /// foreground mesh and defers its hearts for as long as the app holds it. The three ownerless
    /// cells in the suite above run on a session-less manager, where the raise is refused, so the
    /// round trip was unasserted on a live one. Item 6's obligation follows from this cell: dispatch
    /// the `.ownerless` ending immediately, not on a later tick.
    @Test func anOwnerlessDeliveryOnALiveMeshIsHarmlessOnceEnded() async throws {
        let (rig, _) = try await foundedHeartPair("p8-continuation-ownerless-live")
        defer { rig.teardown() }
        let recipient = rig.nodes[1].manager
        let driver = MeshContinuationDriver(meshNetworkManager: recipient)
        #expect(driver.state == .idle, "the precondition: this driver asked for nothing at all")

        #expect(driver.taskDidStart() == .ownerless, "so the delivery is adopted with no claim behind it")

        #expect(recipient.sessionState == .continuingInBackground,
                "and it moves a LIVE foreground mesh into the background for the turn it is held")
        #expect(!recipient.mayCommitRoutedHeartLedgerJudgement, "deferring every routed heart meanwhile")

        driver.taskDidEnd(.cancelled)

        #expect(driver.consumePendingCompletion() == .failed, "the handle is completed once, false")
        #expect(recipient.sessionState == .activeForeground, "the session leg is given straight back")
        #expect(recipient.mayCommitRoutedHeartLedgerJudgement,
                "and the heart stage reopens: the pair on an unwanted task leaves nothing behind")
        #expect(driver.lastAudit == nil,
                "with nothing to present about a background session that never existed")
    }

    /// **What this file does not claim.** No scene, no `BGTaskScheduler`, no real
    /// `BGContinuedProcessingTask` and no device run: `taskDidStart()` / `taskDidEnd(_:)` stand in
    /// for deliveries item 6 has not wired yet, the run policy is never fed `.running` from
    /// anywhere (item 6's line), and the 6-hour ceiling, the 30-minute idle stop and the progress
    /// ratchet are neither exercised nor asserted away here. The physical proof is §15.3's soak.
    @Test func whatThisFileDoesNotClaim() {
        #expect(ProximityContinuationState.allCases.count == 4,
                "the fed vocabulary is unchanged by this item — feeding it is item 6's line")
        #expect(MeshContinuationCoordinator.initialState == .idle,
                "and a driver begins where item 4's table begins")
    }
}
