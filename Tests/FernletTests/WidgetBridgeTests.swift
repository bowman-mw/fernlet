import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
@testable import Fernlet

/// Batch G: the FernletWidgets bridge — the benign outbound snapshot mirrored to the app-group
/// container and the inbound "+1 water" pending-action queue. Pins: codec round-trip (the JSON
/// files are the only contract with the standalone widget extension), the mirror publishing on the
/// SnapshotSaveCoordinator flush path, atomic claim-based drain idempotency, day-rollover
/// application against the row's OWN dateKey, and nil/corrupt-file tolerance.
@MainActor
struct WidgetBridgeTests {

    private let testDate = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WidgetBridgeTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeSnapshot(dateKey: String = "2026-07-05", bottleCount: Int = 2) -> WidgetSnapshot {
        WidgetSnapshot(
            companionStateRaw: "Okay",
            score: 0.62,
            bottleCount: bottleCount,
            hydrationTarget: 4,
            macroSummary: WidgetSnapshot.MacroSummary(protein: 42, carbs: 118, fat: 31),
            dateKey: dateKey,
            computedAt: Date(timeIntervalSince1970: 1_780_000_123)
        )
    }

    // MARK: - Snapshot codec + file store

    @Test func snapshotCodecRoundTrips() throws {
        let original = makeSnapshot()
        let data = try WidgetBridgeFiles.makeEncoder().encode(original)
        let decoded = try WidgetBridgeFiles.makeDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(decoded == original)
    }

    @Test func snapshotFileStoreWritesAndReadsBack() {
        let dir = makeTempDirectory()
        let store = WidgetSnapshotFileStore(directory: dir)
        let snapshot = makeSnapshot()
        #expect(store.write(snapshot))
        #expect(store.read() == snapshot)
    }

    @Test func snapshotFileStoreToleratesMissingAndCorruptFiles() throws {
        let dir = makeTempDirectory()
        let store = WidgetSnapshotFileStore(directory: dir)
        // Missing file/directory → nil, no crash (the widget shows its placeholder).
        #expect(store.read() == nil)
        // Corrupt bytes → nil, no crash.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("WidgetSnapshot.json"))
        #expect(store.read() == nil)
    }

    // MARK: - Mirror on the save/flush path

    @Test func mirrorPublishesOnSnapshotFlush() {
        let dir = makeTempDirectory()
        var reloadCount = 0
        let store = makeTestStore(date: testDate)
        let mirror = WidgetSnapshotMirror(directory: dir, reloadTimelines: { reloadCount += 1 })
        store.widgetSnapshotMirror = mirror

        store.addBottle()
        store.flushPendingSnapshotSave()

        let published = mirror.currentSnapshot()
        #expect(published != nil)
        #expect(published?.bottleCount == 1)
        #expect(published?.dateKey == store.todayKey)
        #expect(published?.hydrationTarget == store.settings.hydrationTarget)
        #expect(published?.companionStateRaw == store.companionState.rawValue)
        #expect(reloadCount > 0)
    }

    @Test func storeWithoutMirrorStaysSilent() {
        // Hermeticity pin: no mirror wired (the default in every other test) → mutations must not
        // touch the app-group container or WidgetKit.
        let store = makeTestStore(date: testDate)
        store.addBottle()
        store.flushPendingSnapshotSave()  // must not crash publishing to a nil mirror
        #expect(store.widgetSnapshotMirror == nil)
    }

    // MARK: - Pending-action queue

    @Test func pendingActionQueueRoundTripsAndDedupesByID() {
        let dir = makeTempDirectory()
        let queue = PendingWidgetActionQueue(directory: dir)
        // Whole-second date: the .iso8601 codec (shared queue convention) truncates fractional
        // seconds, so an Equatable round-trip comparison needs a second-aligned fixture.
        let action = PendingWidgetAction(
            id: UUID(), dateKey: "2026-07-05", action: PendingWidgetAction.waterPlusOne,
            createdAt: Date(timeIntervalSince1970: 1_780_000_200)
        )
        #expect(queue.append(action))
        #expect(queue.append(action))  // duplicate row id → dropped (idempotent append)
        #expect(queue.records() == [action])

        let claimed = queue.claimAll()
        #expect(claimed == [action])
        #expect(queue.records().isEmpty)   // claim atomically cleared the file
        #expect(queue.claimAll().isEmpty)  // second claim finds nothing (drain idempotency)
    }

    @Test func drainAppliesWaterToTodayAndIsIdempotent() {
        let dir = makeTempDirectory()
        let store = makeTestStore(date: testDate)
        store.pendingWidgetActionQueue = PendingWidgetActionQueue(directory: dir)
        let todayKey = store.todayKey

        for _ in 0..<2 {
            _ = store.pendingWidgetActionQueue.append(PendingWidgetAction(
                id: UUID(), dateKey: todayKey, action: PendingWidgetAction.waterPlusOne, createdAt: Date()
            ))
        }

        store.processPendingWidgetActions()
        #expect(store.day.bottleCount == 2)

        // Re-draining after the atomic claim applies nothing twice.
        store.processPendingWidgetActions()
        #expect(store.day.bottleCount == 2)
    }

    @Test func drainAppliesRowsAgainstTheirOwnDateKeyAcrossDayRollover() throws {
        let dir = makeTempDirectory()
        let store = makeTestStore(date: testDate)
        store.pendingWidgetActionQueue = PendingWidgetActionQueue(directory: dir)
        let yesterday = try #require(FernletDate.date(fromDayKey: store.todayKey)?.addingTimeInterval(-86_400))
        let yesterdayKey = FernletDate.dayKey(for: yesterday)

        // A tap that fired before midnight but is drained today must land on ITS day, not today.
        _ = store.pendingWidgetActionQueue.append(PendingWidgetAction(
            id: UUID(), dateKey: yesterdayKey, action: PendingWidgetAction.waterPlusOne, createdAt: Date()
        ))
        store.processPendingWidgetActions()

        #expect(store.loadDay(for: yesterdayKey).bottleCount == 1)
        #expect(store.day.bottleCount == 0)
    }

    @Test func drainSkipsUnknownMalformedAndFutureRows() {
        let dir = makeTempDirectory()
        let store = makeTestStore(date: testDate)
        store.pendingWidgetActionQueue = PendingWidgetActionQueue(directory: dir)

        _ = store.pendingWidgetActionQueue.append(PendingWidgetAction(
            id: UUID(), dateKey: store.todayKey, action: "someFutureAction", createdAt: Date()
        ))
        _ = store.pendingWidgetActionQueue.append(PendingWidgetAction(
            id: UUID(), dateKey: "not-a-day-key", action: PendingWidgetAction.waterPlusOne, createdAt: Date()
        ))
        _ = store.pendingWidgetActionQueue.append(PendingWidgetAction(
            id: UUID(), dateKey: "2999-01-01", action: PendingWidgetAction.waterPlusOne, createdAt: Date()
        ))

        store.processPendingWidgetActions()
        #expect(store.day.bottleCount == 0)
        #expect(store.loadDays().count == 1)  // no phantom past/future day rows created
        #expect(store.pendingWidgetActionQueue.records().isEmpty)  // junk rows still cleared
    }

    @Test func drainDedupesDuplicateRowIDsWithinOneFile() throws {
        // The widget-side writer dedupes on append, but a raw file with duplicate ids (crash mid-
        // write, manual tampering) must still apply once — simulate by writing the file directly.
        let dir = makeTempDirectory()
        let store = makeTestStore(date: testDate)
        store.pendingWidgetActionQueue = PendingWidgetActionQueue(directory: dir)
        let duplicated = PendingWidgetAction(
            id: UUID(), dateKey: store.todayKey, action: PendingWidgetAction.waterPlusOne, createdAt: Date()
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try WidgetBridgeFiles.makeEncoder().encode([duplicated, duplicated])
        try data.write(to: dir.appendingPathComponent("PendingWidgetActions.json"))

        store.processPendingWidgetActions()
        #expect(store.day.bottleCount == 1)
    }

    @Test func drainRepublishesSnapshotEvenWithNoPendingActions() {
        // The scene-active drain doubles as the day-rollover snapshot refresh: with zero queued
        // actions it must still republish (fresh dateKey) when a mirror is wired.
        let dir = makeTempDirectory()
        let store = makeTestStore(date: testDate)
        store.pendingWidgetActionQueue = PendingWidgetActionQueue(directory: dir)
        var reloadCount = 0
        let mirror = WidgetSnapshotMirror(directory: dir, reloadTimelines: { reloadCount += 1 })
        store.widgetSnapshotMirror = mirror

        store.processPendingWidgetActions()
        #expect(mirror.currentSnapshot()?.dateKey == store.todayKey)
        #expect(reloadCount == 1)
    }

    @Test func claimAllClearsCorruptQueueFile() throws {
        let dir = makeTempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("PendingWidgetActions.json"))
        let queue = PendingWidgetActionQueue(directory: dir)
        #expect(queue.claimAll().isEmpty)
        // A corrupt file is cleared rather than wedging every future drain.
        #expect(queue.records().isEmpty)
        _ = queue.append(PendingWidgetAction(
            id: UUID(), dateKey: "2026-07-05", action: PendingWidgetAction.waterPlusOne, createdAt: Date()
        ))
        #expect(queue.records().count == 1)
    }

    // MARK: - Optimistic +1-water bump (instant widget/Siri feedback before the app republishes)

    @Test func optimisticWaterBumpIncrementsWithinTheSameDay() throws {
        let dir = makeTempDirectory()
        let store = WidgetSnapshotFileStore(directory: dir)
        #expect(store.write(makeSnapshot(dateKey: "2026-07-05", bottleCount: 2)))

        #expect(store.applyOptimisticWaterPlusOne(dayKey: "2026-07-05"))

        let bumped = try #require(store.read())
        #expect(bumped.dateKey == "2026-07-05")
        #expect(bumped.bottleCount == 3)
        // A same-day bump leaves the published mood/score/macros alone.
        #expect(bumped.companionStateRaw == "Okay")
    }

    @Test func optimisticWaterBumpRolloverRestampsDayAndClearsYesterdaysMood() throws {
        let dir = makeTempDirectory()
        let store = WidgetSnapshotFileStore(directory: dir)
        // Yesterday's published snapshot carries a real mood + score + macros.
        #expect(store.write(makeSnapshot(dateKey: "2026-07-05", bottleCount: 5)))

        // The widget/Siri "+1 water" fires on a NEW day, before the app republishes.
        #expect(store.applyOptimisticWaterPlusOne(dayKey: "2026-07-06"))

        let rolled = try #require(store.read())
        #expect(rolled.dateKey == "2026-07-06")   // re-stamped to the fresh day
        #expect(rolled.bottleCount == 1)          // fresh day's first bottle
        // Re-stamping dateKey makes the a0bde6c mood day-gate pass, so yesterday's mood MUST be cleared
        // here — otherwise the widget renders the wrong companion all day until the app opens.
        #expect(rolled.companionStateRaw == "")   // empty raw → nil companionState → neutral treatment
        #expect(rolled.score == 0)
        #expect(rolled.macroSummary == WidgetSnapshot.MacroSummary(protein: 0, carbs: 0, fat: 0))
    }

    // MARK: - Byte-format twin: the queue cap must match on both sides of the app-group file

    /// The widget extension links no FernletKit product and is compiled into its own target, so
    /// `PendingWidgetActionWriter` (widget) and ``PendingWidgetActionQueue`` (app) are hand-copied
    /// twins over ONE file. A cap that differs between them is a silent split-brain: the writer would
    /// evict or refuse at a boundary the reader never sees. Scanned off disk, like
    /// `SharedRecipeImportQueueMirrorTests`, because the widget's sources cannot be imported here.
    @Test func widgetWriterAndAppQueueAgreeOnTheQueueCap() throws {
        let widgetSource = try RepoRoot.source("App/FernletWidgets/WidgetSharedModels.swift")
        let declaration = "static let maxQueuedActions = "
        let range = try #require(
            widgetSource.range(of: declaration),
            "the widget-side writer no longer declares maxQueuedActions — the twins have drifted"
        )
        let digits = widgetSource[range.upperBound...]
            .prefix { $0.isNumber || $0 == "_" }
            .replacingOccurrences(of: "_", with: "")
        let widgetCap = try #require(Int(digits), "maxQueuedActions is no longer an integer literal")
        #expect(
            widgetCap == PendingWidgetActionQueue.maxQueuedActions,
            "widget cap \(widgetCap) != app cap \(PendingWidgetActionQueue.maxQueuedActions)"
        )
    }

    /// Both sides must also REFUSE at the cap rather than evict: an already-queued tap was promised to
    /// the user when it was written, so dropping the oldest row is the one failure neither process can
    /// observe. The app half is exercised directly; the widget half is pinned by source scan.
    @Test func bothSidesRefuseRatherThanEvictWhenTheQueueIsFull() throws {
        let widgetSource = try RepoRoot.source("App/FernletWidgets/WidgetSharedModels.swift")
        #expect(
            widgetSource.contains("guard records.count < Self.maxQueuedActions"),
            "the widget writer must refuse at the cap (it evicted the oldest row before this pin)"
        )
        #expect(
            !widgetSource.contains("records.removeFirst("),
            "the widget writer must not evict queued rows — refuse the new one instead"
        )

        // App half, driven for real: a full queue refuses the append and keeps every queued row.
        // The file is seeded in one write (the queue's own byte format) rather than by 512 appends,
        // each of which rewrites the whole array.
        let dir = makeTempDirectory()
        let queue = PendingWidgetActionQueue(directory: dir)
        let rows = (0..<PendingWidgetActionQueue.maxQueuedActions).map { index in
            PendingWidgetAction(
                id: UUID(), dateKey: "2026-07-05", action: PendingWidgetAction.waterPlusOne,
                createdAt: Date(timeIntervalSince1970: 1_780_000_000 + Double(index))
            )
        }
        let firstID = try #require(rows.first?.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try WidgetBridgeFiles.makeEncoder().encode(rows)
            .write(to: dir.appendingPathComponent("PendingWidgetActions.json"), options: [.atomic])
        #expect(queue.records().count == PendingWidgetActionQueue.maxQueuedActions)

        let overflow = PendingWidgetAction(
            id: UUID(), dateKey: "2026-07-05", action: PendingWidgetAction.waterPlusOne, createdAt: Date()
        )
        #expect(queue.append(overflow) == false)
        let after = queue.records()
        #expect(after.count == PendingWidgetActionQueue.maxQueuedActions)
        #expect(after.first?.id == firstID, "the oldest row must survive a refused append")
        #expect(!after.contains { $0.id == overflow.id })
    }
}
