import Foundation
import FernletFoundation
import HealthKit
import Testing
import FernletDomainModel
import PrivateHealthStore
@testable import Fernlet

struct CyclePredictionEngineTests {
    @Test func fewerThanThreeStartsReturnsNil() throws {
        let calendar = gregorianCalendar()
        let start = try date(2026, 1, 1, calendar: calendar)
        let entries = entriesForPeriods(starts: [start, calendar.date(byAdding: .day, value: 28, to: start)!], calendar: calendar)

        let prediction = CyclePredictionEngine.predict(from: entries, today: start, calendar: calendar)

        #expect(prediction == nil)
    }

    @Test func threeRegularStartsPredictTwentyEightDaysWithModerateConfidence() throws {
        let calendar = gregorianCalendar()
        let start = try date(2026, 1, 1, calendar: calendar)
        let starts = cycleStarts(from: start, intervals: [28, 28], calendar: calendar)
        let entries = entriesForPeriods(starts: starts, pattern: [.medium], calendar: calendar)

        let prediction = try #require(CyclePredictionEngine.predict(from: entries, today: starts.last!, calendar: calendar))

        #expect(prediction.predictedCycleLength == 28)
        #expect((0.30...0.55).contains(prediction.confidence))
        #expect(prediction.predictedFlow.map(\.level) == [.medium, .heavy, .medium, .light, .spotting])
        #expect(prediction.predictedFlow.allSatisfy { $0.confidence <= 0.4 })
    }

    @Test func sixRegularCyclesHaveHighConfidenceAndNarrowRange() throws {
        let calendar = gregorianCalendar()
        let start = try date(2026, 1, 1, calendar: calendar)
        let starts = cycleStarts(from: start, intervals: [28, 28, 28, 28, 28, 28], calendar: calendar)
        let entries = entriesForPeriods(starts: starts, calendar: calendar)

        let prediction = try #require(CyclePredictionEngine.predict(from: entries, today: starts.last!, calendar: calendar))

        #expect(prediction.predictedCycleLength == 28)
        #expect(prediction.confidence >= 0.75)
        #expect((1...3).contains(rangeHalfWidth(for: prediction, calendar: calendar)))
    }

    @Test func irregularCyclesLowerConfidenceAndWidenRange() throws {
        let calendar = gregorianCalendar()
        let start = try date(2026, 1, 1, calendar: calendar)
        let starts = cycleStarts(from: start, intervals: [18, 27, 39, 22, 35, 30], calendar: calendar)
        let entries = entriesForPeriods(starts: starts, calendar: calendar)

        let prediction = try #require(CyclePredictionEngine.predict(from: entries, today: starts.last!, calendar: calendar))

        #expect(prediction.confidence < 0.60)
        #expect((4...8).contains(rangeHalfWidth(for: prediction, calendar: calendar)))
    }

    @Test func missedLogIntervalDoesNotPullPredictionLong() throws {
        let calendar = gregorianCalendar()
        let start = try date(2026, 1, 1, calendar: calendar)
        let starts = cycleStarts(from: start, intervals: [28, 28, 56, 28, 28, 28], calendar: calendar)
        let entries = entriesForPeriods(starts: starts, calendar: calendar)

        let prediction = try #require(CyclePredictionEngine.predict(from: entries, today: starts.last!, calendar: calendar))

        #expect((26...30).contains(prediction.predictedCycleLength))
    }

    @Test func gradualDriftUsesEWMAToMoveAboveMedian() throws {
        let calendar = gregorianCalendar()
        let start = try date(2026, 1, 1, calendar: calendar)
        let starts = cycleStarts(from: start, intervals: [27, 27, 28, 28, 29, 30], calendar: calendar)
        let entries = entriesForPeriods(starts: starts, calendar: calendar)

        let prediction = try #require(CyclePredictionEngine.predict(from: entries, today: starts.last!, calendar: calendar))

        #expect(prediction.averageCycleLength == 28)
        #expect(prediction.predictedCycleLength >= 28)
    }

    @Test func splitPeriodAcrossOneMissingDayIsSinglePeriod() throws {
        let calendar = gregorianCalendar()
        let start = try date(2026, 1, 1, calendar: calendar)
        let secondStart = calendar.date(byAdding: .day, value: 28, to: start)!
        let thirdStart = calendar.date(byAdding: .day, value: 56, to: start)!
        var entries = try flowEntries(start: start, pattern: [.medium, .medium, .medium, .medium], calendar: calendar)
        entries += try flowEntries(start: calendar.date(byAdding: .day, value: 5, to: start)!, pattern: [.medium, .medium, .medium, .medium], calendar: calendar)
        entries += entriesForPeriods(starts: [secondStart, thirdStart], calendar: calendar)

        let prediction = try #require(CyclePredictionEngine.predict(from: entries, today: thirdStart, calendar: calendar))

        #expect(prediction.cyclesObserved == 3)
        #expect(prediction.predictedCycleLength == 28)
    }

    @Test func nextStartUsesCalendarDayArithmeticAcrossDST() throws {
        var calendar = gregorianCalendar()
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let start = try date(2026, 2, 8, calendar: calendar)
        let starts = cycleStarts(from: start, intervals: [28, 28, 28, 28, 28, 28], calendar: calendar)
        let entries = entriesForPeriods(starts: starts, calendar: calendar)
        let expected = calendar.date(byAdding: .day, value: 28, to: starts.last!)!

        let prediction = try #require(CyclePredictionEngine.predict(from: entries, today: starts.last!, calendar: calendar))

        #expect(prediction.nextStart == expected)
    }

    @Test func repeatedFiveDayPatternPredictsMatchingFlowShape() throws {
        let calendar = gregorianCalendar()
        let start = try date(2026, 1, 1, calendar: calendar)
        let starts = cycleStarts(from: start, intervals: [28, 28, 28, 28], calendar: calendar)
        let pattern: [PeriodFlowLevel] = [.medium, .heavy, .heavy, .medium, .light]
        let entries = entriesForPeriods(starts: starts, pattern: pattern, calendar: calendar)

        let prediction = try #require(CyclePredictionEngine.predict(from: entries, today: starts.last!, calendar: calendar))

        #expect(Array(prediction.predictedFlow.prefix(5)).map(\.level) == [.medium, .heavy, .heavy, .medium, .light])
    }

    @Test func inconsistentSparseTailsHaveLowFlowConfidence() throws {
        let calendar = gregorianCalendar()
        let start = try date(2026, 1, 1, calendar: calendar)
        let starts = cycleStarts(from: start, intervals: [28, 28, 28, 28, 28, 28], calendar: calendar)
        let patterns: [[PeriodFlowLevel]] = [
            [.medium, .heavy, .medium, .light],
            [.medium, .heavy, .medium, .light],
            [.medium, .heavy, .medium, .light],
            [.medium, .heavy, .medium, .light],
            [.medium, .heavy, .medium, .light],
            [.medium, .heavy, .medium, .light, .light, .light],
            [.medium, .heavy, .medium, .light, .heavy, .heavy]
        ]
        let entries = zip(starts, patterns).flatMap { start, pattern in
            (try? flowEntries(start: start, pattern: pattern, calendar: calendar)) ?? []
        }

        let prediction = try #require(CyclePredictionEngine.predict(from: entries, today: starts.last!, calendar: calendar))
        let tail = Dictionary(uniqueKeysWithValues: prediction.predictedFlow.map { ($0.dayIndex, $0) })

        #expect((tail[4]?.confidence ?? 1.0) < 0.4)
        #expect((tail[5]?.confidence ?? 1.0) < 0.4)
    }

    @Test func zeroStreaksReturnNil() throws {
        let calendar = gregorianCalendar()
        let start = try date(2026, 1, 1, calendar: calendar)

        let prediction = CyclePredictionEngine.predict(from: [], today: start, calendar: calendar)

        #expect(prediction == nil)
    }
}

private func entriesForPeriods(
    starts: [Date],
    pattern: [PeriodFlowLevel] = [.medium, .heavy, .medium, .light, .light],
    calendar: Calendar
) -> [CycleDayEntry] {
    starts.flatMap { start in
        (try? flowEntries(start: start, pattern: pattern, calendar: calendar)) ?? []
    }
}

private func flowEntries(start: Date, pattern: [PeriodFlowLevel], calendar: Calendar) throws -> [CycleDayEntry] {
    try pattern.enumerated().map { index, level in
        let day = calendar.date(byAdding: .day, value: index, to: start)!
        let samples = try HealthKitService.periodSamples(
            for: UserLoggedCycleEvent(date: day, flowLevel: level),
            externalUUID: UUID()
        )
        return CycleDayEntry(
            date: day,
            dateKey: FernletDate.dayKey(for: day),
            samples: samples,
            narrative: nil,
            phase: .menstrual
        )
    }
}

private func cycleStarts(from firstStart: Date, intervals: [Int], calendar: Calendar) -> [Date] {
    intervals.reduce(into: [firstStart]) { starts, interval in
        starts.append(calendar.date(byAdding: .day, value: interval, to: starts[starts.count - 1])!)
    }
}

private func rangeHalfWidth(for prediction: CyclePrediction, calendar: Calendar) -> Int {
    calendar.dateComponents([.day], from: prediction.likelyStartRange.lowerBound, to: prediction.nextStart).day ?? 0
}

private func gregorianCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) throws -> Date {
    try #require(calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: year, month: month, day: day)))
}
