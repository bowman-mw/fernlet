import Foundation
import FernletFoundation
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

        let view = PeriodTrackerView(
            store: store,
            periodStore: periodStore,
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

        let model = PeriodMonthModel(
            date: month,
            entriesByKey: [loggedEntry.dateKey: loggedEntry],
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
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = [
            "Fernlet/CyclePredictionEngine.swift",
            "Fernlet/PeriodTrackerStore.swift",
            "Fernlet/PeriodTrackerView.swift"
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
