import Foundation
import FernletFoundation
import FernletLock
import HealthKit
import Testing
import SwiftUI
import FernletDomainModel
import PrivateHealthStore
import HealthKitGateway
@testable import Fernlet

@MainActor
struct PeriodPredictionUITests {
    @Test func showsPredictionIsFalseWhenPredictionsAreHidden() throws {
        let store = makeTestStore()
        let periodStore = PeriodTrackerStore(healthService: HealthKitService())
        periodStore.prediction = try syntheticPrediction(in: gregorianCalendar(), month: 6)
        store.settings.hidePredictions = true
        var activeSheet: FernletSheet?
        var isTabBarCompact = false
        var tabResetToken = 0

        let view = CycleTrackerView(
            store: store,
            periodStore: periodStore,
            intimacyStore: IntimacyLogStore(),
            activeSheet: Binding(get: { activeSheet }, set: { activeSheet = $0 }),
            isTabBarCompact: Binding(get: { isTabBarCompact }, set: { isTabBarCompact = $0 }),
            tabResetToken: Binding(get: { tabResetToken }, set: { tabResetToken = $0 })
        )

        #expect(view.showsPrediction == false)
    }

    @Test func monthModelProjectsPredictedFlowAndLoggedDaysWin() throws {
        let calendar = gregorianCalendar()
        let month = try testDate(2026, 6, 1, calendar: calendar)
        let prediction = try syntheticPrediction(in: calendar, month: 6)
        let loggedDate = try testDate(2026, 6, 15, calendar: calendar)
        let loggedSamples = try HealthKitService.periodSamples(
            for: UserLoggedCycleEvent(date: loggedDate, flowLevel: .medium),
            externalUUID: UUID()
        )
        let loggedEntry = CycleDayEntry(
            date: loggedDate,
            dateKey: FernletDate.dayKey(for: loggedDate),
            samples: loggedSamples,
            narrative: nil,
            phase: .menstrual
        )

        let model = CycleMonthModel(
            date: month,
            entriesByKey: [loggedEntry.dateKey: loggedEntry],
            intimacyDayKeys: ["2026-06-10", loggedEntry.dateKey],
            todayKey: "2026-06-01",
            prediction: prediction,
            calendar: calendar
        )
        let cellsByDay = Dictionary(uniqueKeysWithValues: model.cells.compactMap { cell in
            cell.day.map { ($0, cell) }
        })

        #expect(cellsByDay[14]?.projectedLevel == .medium)
        #expect(cellsByDay[15]?.projectedLevel == nil)
        #expect(cellsByDay[15]?.entry?.flowLevel == .medium)
        #expect(cellsByDay[16]?.projectedLevel == .medium)
        #expect(cellsByDay[17]?.projectedLevel == .light)

        // The intimacy layer rides the same grid as its own flag: marked days carry it, a marked
        // day can coexist with a logged flow entry, and unmarked days stay clean.
        #expect(cellsByDay[10]?.hasIntimacyEvent == true)
        #expect(cellsByDay[15]?.hasIntimacyEvent == true)
        #expect(cellsByDay[16]?.hasIntimacyEvent == false)
    }

    /// The merge dropped the hub's structural gate (pre-merge, `if isPeriodTrackingVisible`
    /// removed the whole period page in the same render transaction as a flip). This pins the
    /// replacement view-seam BACK-STOP: with the derived gate off, the calendar's flow-tint map
    /// must be empty even while `periodStore.entries` is still populated — a non-setter writer
    /// (profile edit, HealthKit body-profile import) can flip the gate before ContentView's
    /// value-keyed scrub runs. The seam gate in `PeriodTrackerStore` remains the enforcement.
    @Test func calendarFlowInputsAreEmptyAtTheViewSeamWhilePeriodHidden() throws {
        let calendar = gregorianCalendar()
        let store = makeTestStore()
        let periodStore = PeriodTrackerStore(healthService: HealthKitService())
        let entry = try loggedEntry(on: testDate(2026, 6, 15, calendar: calendar))
        periodStore.entries = [entry]
        let view = makeCycleView(store: store, periodStore: periodStore)

        store.settings.periodTrackingVisible = false
        #expect(view.entriesByKey.isEmpty)

        // Hiding never deletes: the same resident entries come straight back on un-hide.
        store.settings.periodTrackingVisible = true
        #expect(view.entriesByKey[entry.dateKey]?.flowLevel == .medium)
    }

    /// Same back-stop for the day-detail push: while the period half is hidden, `entry(for:)`
    /// must synthesize the blank placeholder instead of looking up the resident entry, so a
    /// stale render can never carry period plaintext into `CycleDayDetailView`.
    @Test func dayDetailEntryIsBlankAtTheViewSeamWhilePeriodHidden() throws {
        let calendar = gregorianCalendar()
        let date = try testDate(2026, 6, 15, calendar: calendar)
        let store = makeTestStore()
        let periodStore = PeriodTrackerStore(healthService: HealthKitService())
        periodStore.entries = [try loggedEntry(on: date)]
        let view = makeCycleView(store: store, periodStore: periodStore)

        store.settings.periodTrackingVisible = false
        let hidden = view.entry(for: date)
        #expect(hidden.samples.isEmpty)
        #expect(hidden.narrative == nil)
        #expect(hidden.phase == .unknown)

        store.settings.periodTrackingVisible = true
        #expect(view.entry(for: date).flowLevel == .medium)
    }

    /// Un-hiding the period half never reloaded while the merged page stayed mounted (it
    /// survives via the intimacy half, so no re-appearance restarts the `.task`). The load task
    /// is keyed on ``CycleTrackerView/LoadTrigger`` — lock state PLUS the DERIVED
    /// `sensitiveSurfaceVisibility` — so any writer's flip changes the task identity and SwiftUI
    /// restarts the load by construction. This pins that identity.
    @Test func loadTaskIdentityChangesWhenADerivedVisibilityGateFlips() {
        let mounted = CycleTrackerView.LoadTrigger(
            lockState: .unlocked(scope: .privateHub),
            visibility: SensitiveSurfaceVisibility(intimacy: true, period: false)
        )

        // Same lock state + same visibility: no spurious restart.
        #expect(mounted == CycleTrackerView.LoadTrigger(
            lockState: .unlocked(scope: .privateHub),
            visibility: SensitiveSurfaceVisibility(intimacy: true, period: false)
        ))
        // Un-hiding the period half restarts the load (the finding's exact scenario).
        #expect(mounted != CycleTrackerView.LoadTrigger(
            lockState: .unlocked(scope: .privateHub),
            visibility: SensitiveSurfaceVisibility(intimacy: true, period: true)
        ))
        // Symmetric for the intimacy half.
        #expect(mounted != CycleTrackerView.LoadTrigger(
            lockState: .unlocked(scope: .privateHub),
            visibility: SensitiveSurfaceVisibility(intimacy: false, period: false)
        ))
        // Lock transitions keep their pre-existing trigger role.
        #expect(mounted != CycleTrackerView.LoadTrigger(
            lockState: .locked(cooldownDeadline: nil),
            visibility: SensitiveSurfaceVisibility(intimacy: true, period: false)
        ))
    }

    /// Builds the merged Cycle page over the given stores with inert bindings — enough view to
    /// exercise its internal gating seams without a hosted hierarchy.
    private func makeCycleView(store: FernletStore, periodStore: PeriodTrackerStore) -> CycleTrackerView {
        CycleTrackerView(
            store: store,
            periodStore: periodStore,
            intimacyStore: IntimacyLogStore(),
            activeSheet: .constant(nil),
            isTabBarCompact: .constant(false),
            tabResetToken: .constant(0)
        )
    }

    /// A real logged medium-flow entry for the given day, built the same way production does
    /// (HealthKit samples from a user-logged event).
    private func loggedEntry(on date: Date) throws -> CycleDayEntry {
        let samples = try HealthKitService.periodSamples(
            for: UserLoggedCycleEvent(date: date, flowLevel: .medium),
            externalUUID: UUID()
        )
        return CycleDayEntry(
            date: date,
            dateKey: FernletDate.dayKey(for: date),
            samples: samples,
            narrative: nil,
            phase: .menstrual
        )
    }

    @Test func predictionPathDoesNotReferenceAICode() throws {
        let output = try runGitGrep(pattern: #"\b(aiCall|FoundationModels|CoreML|MLModel|CreateML|NaturalLanguage|OpenAI|Anthropic)\b"#)

        #expect(output.isEmpty)
    }

    @Test func predictionPathDoesNotWritePredictionsToHealthKit() throws {
        let output = try runGitGrep(pattern: #"healthService\.save\("#)

        #expect(output.isEmpty)
    }

    private func syntheticPrediction(in calendar: Calendar, month: Int) throws -> CyclePrediction {
        let start = try testDate(2026, month, 15, calendar: calendar)
        let lower = try testDate(2026, month, 14, calendar: calendar)
        let upper = try testDate(2026, month, 17, calendar: calendar)
        let levels: [PredictedFlowLevel] = [.medium, .heavy, .medium, .light]
        let flow = try levels.enumerated().map { offset, level in
            let date = try #require(calendar.date(byAdding: .day, value: offset - 1, to: start))
            return PredictedFlowDay(date: date, dayIndex: offset, level: level, confidence: 0.8)
        }
        return CyclePrediction(
            nextStart: start,
            likelyStartRange: lower...upper,
            predictedCycleLength: 28,
            averageCycleLength: 28,
            variationDays: 1,
            confidence: 0.8,
            cyclesObserved: 6,
            predictedFlow: flow
        )
    }

    private func runGitGrep(pattern: String) throws -> String {
        let root = RepoRoot.url
        let paths = [
            "FernletKit/Sources/PrivateHealthStore/CyclePredictionEngine.swift",
            "FernletKit/Sources/PrivateHealthStore/PeriodTrackerStore.swift",
            "App/Fernlet/CycleTrackerView.swift"
        ]
        let regex = try NSRegularExpression(pattern: pattern)
        var matches: [String] = []

        for path in paths {
            let url = root.appendingPathComponent(path)
            let content = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in content.components(separatedBy: .newlines).enumerated() {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    matches.append("\(path):\(index + 1):\(line)")
                }
            }
        }

        return matches.joined(separator: "\n")
    }
}

private func gregorianCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar
}

private func testDate(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) throws -> Date {
    try #require(calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: year, month: month, day: day)))
}
