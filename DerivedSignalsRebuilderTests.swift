import Foundation
import Testing
@testable import Fernlet

struct DerivedSignalsRebuilderTests {
    @Test func emptyAllDaysReturnsEmptyResult() {
        let signals = DerivedSignalsRebuilder.rebuild(
            allDays: [:],
            todayKey: "2026-05-14"
        )

        #expect(signals.isEmpty)
    }

    @Test func singleDayMatchesDerivedSignalFactoryOutput() {
        let day = FernletDay(
            date: "2026-05-14",
            journals: [JournalEntry(text: "Steady.", tag: .good)],
            sleep: SleepLog(hours: 8, quality: .good, note: "Solid")
        )
        let allDays = ["2026-05-14": day]

        let signals = DerivedSignalsRebuilder.rebuild(
            allDays: allDays,
            todayKey: "2026-05-14"
        )
        let expected = DerivedSignalFactory.makeSignals(
            from: [("2026-05-14", day)],
            todayKey: "2026-05-14"
        )

        #expect(stableFields(from: signals) == stableFields(from: expected))
    }

    @Test func windowRespectsWindowDaysParameter() {
        let allDays = Dictionary(uniqueKeysWithValues: (1...5).map { index in
            let key = "2026-05-\(String(format: "%02d", index))"
            return (key, FernletDay(date: key))
        })

        let signals = DerivedSignalsRebuilder.rebuild(
            allDays: allDays,
            todayKey: "2026-05-05",
            windowDays: 3
        )

        #expect(signals.isEmpty == false)
        #expect(signals.allSatisfy { $0.windowStart == "2026-05-03" })
        #expect(signals.allSatisfy { $0.windowEnd == "2026-05-05" })
    }

    private func stableFields(from signals: [DerivedSignalRecord]) -> [String] {
        signals.map { signal in
            [
                signal.signalName,
                signal.value,
                signal.windowStart,
                signal.windowEnd,
                signal.sourceFields.joined(separator: ",")
            ].joined(separator: "|")
        }
    }
}
