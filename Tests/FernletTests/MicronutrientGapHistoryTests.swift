import Foundation
import Testing
import FernletDomainModel
import LocalPersistence
import StoreCore

/// How much history a micronutrient verdict needs, and what it is measured against (bug confirmation
/// 2026-10-15, safety-firstrun §4).
///
/// `MicronutrientGapAnalyzer.gaps` divided intake by the NOMINAL window (the daily value × 7 or × 14)
/// with no minimum history, so on a first day of logging three meals that met every daily value in full
/// read as 1/7 and 1/14 of the window — every tracked nutrient a gap, stamped with the nominal window so
/// the scoring modifier's `windowDays >= 7` and the nudge planner's `>= 14` both passed: a lower food
/// score, a Home nudge naming foods, and an AI prompt line from day 1. Unlogged days counted as zero
/// for everyone. The analyzer now counts the window's days with data, says nothing until the window
/// holds `MicronutrientGapAnalyzer.minimumDataDayFraction` of its days with data (the owner's dial,
/// 1.0 = full), and divides by the days with data.
@MainActor
struct MicronutrientGapHistoryTests {
    /// The production dial is the report's value: a full window.
    @Test func theOwnersDialStandsAtAFullWindow() {
        #expect(MicronutrientGapAnalyzer.minimumDataDayFraction == 1.0)
        #expect(MicronutrientGapAnalyzer.minimumDaysWithData(forWindow: 7) == 7)
        #expect(MicronutrientGapAnalyzer.minimumDaysWithData(forWindow: 14) == 14)
        #expect(MicronutrientGapAnalyzer.minimumDaysWithData(forWindow: 7, fraction: 0.5) == 4)
        #expect(MicronutrientGapAnalyzer.minimumDaysWithData(forWindow: 14, fraction: 0) == 1)
        #expect(MicronutrientGapAnalyzer.minimumDaysWithData(forWindow: 14, fraction: .nan) == 14)
    }

    /// A first day of logging that met every daily value is no gap in either window.
    @Test func aOneDayHistoryAtFullDailyValuesReportsNoGap() {
        let days = Self.history(dayCount: 1, dailyValueShare: 1.0)

        #expect(MicronutrientGapAnalyzer.gaps(from: days, windowDays: 7).isEmpty)
        #expect(MicronutrientGapAnalyzer.gaps(from: days, windowDays: 14).isEmpty)
    }

    /// Six days of full daily values: still short of either window, so still nothing to say.
    @Test func aSixDayHistoryAtFullDailyValuesReportsNoGap() {
        let days = Self.history(dayCount: 6, dailyValueShare: 1.0)

        #expect(MicronutrientGapAnalyzer.gaps(from: days, windowDays: 7).isEmpty)
        #expect(MicronutrientGapAnalyzer.gaps(from: days, windowDays: 14).isEmpty)
    }

    /// The derived signals the score, the nudge and the AI prompt read carry no gap after day 1.
    @Test func aFirstDaysDerivedSignalsCarryNoGap() throws {
        let days = Self.history(dayCount: 1, dailyValueShare: 1.0)
        let signals = DerivedSignalsRebuilder.rebuild(
            allDays: Dictionary(uniqueKeysWithValues: days), todayKey: try #require(days.last?.0)
        )
        for name in ["micronutrientGaps7Day", "micronutrientGaps14Day"] {
            let signal = try #require(signals.first { $0.signalName == name })
            #expect(signal.nutrientGaps.isEmpty)
            #expect(signal.value == "insufficient data")
        }
    }

    /// A full window really under a quarter of the daily values still reports every nutrient a gap.
    @Test func fourteenLowDaysReportGapsInBothWindows() {
        let days = Self.history(dayCount: 14, dailyValueShare: 0.2)
        let keys = Set(MicronutrientGapAnalyzer.trackedNutrients.map(\.key))

        for window in [7, 14] {
            let gaps = MicronutrientGapAnalyzer.gaps(from: days, windowDays: window)
            #expect(Set(gaps.filter { $0.status == .gap }.map(\.nutrientKey)) == keys)
            #expect(gaps.allSatisfy { $0.windowDays == window })
        }
    }

    /// A full window at the daily values is covered, measured day for day.
    @Test func sevenFullDaysAreCovered() {
        let gaps = MicronutrientGapAnalyzer.gaps(from: Self.history(dayCount: 7, dailyValueShare: 1.0), windowDays: 7)

        #expect(gaps.count == MicronutrientGapAnalyzer.trackedNutrients.count)
        #expect(gaps.allSatisfy { $0.status == .covered && abs($0.coverageRatio - 1.0) < 0.000_1 })
    }

    /// An unlogged day in the window is never read as zero intake. At the production dial it keeps the
    /// window from speaking at all; at a looser dial the window speaks, measured against the days that
    /// carry data — so seven logged days at 40% of the daily values, with seven unlogged days between
    /// them, read 0.4 (no row), where the nominal divisor read 0.2, a gap.
    @Test func unloggedDaysAreNotCountedAsZeroIntake() {
        let days = Self.history(dayCount: 14, dailyValueShare: 0.4, unloggedEvery: 2)

        #expect(MicronutrientGapAnalyzer.gaps(from: days, windowDays: 14).isEmpty)
        let loose = MicronutrientGapAnalyzer.gaps(from: days, windowDays: 14, minimumDataDayFraction: 0.5)
        #expect(loose.isEmpty)
        let covered = MicronutrientGapAnalyzer.gaps(
            from: Self.history(dayCount: 14, dailyValueShare: 1.0, unloggedEvery: 2),
            windowDays: 14,
            minimumDataDayFraction: 0.5
        )
        #expect(covered.count == MicronutrientGapAnalyzer.trackedNutrients.count)
        #expect(covered.allSatisfy { $0.status == .covered && abs($0.coverageRatio - 1.0) < 0.000_1 })
    }

    /// A day with meals but no micronutrient data is not a day with data.
    @Test func aDayWhoseMealsCarryNoDataIsNotADayWithData() {
        let bare = FernletDay(date: "2026-05-01", meals: [Self.meal(dailyValueShare: nil)])
        let logged = FernletDay(date: "2026-05-02", meals: [Self.meal(dailyValueShare: 0.5)])

        #expect(MicronutrientGapAnalyzer.carriesMicronutrientData(bare) == false)
        #expect(MicronutrientGapAnalyzer.carriesMicronutrientData(FernletDay(date: "2026-05-03")) == false)
        #expect(MicronutrientGapAnalyzer.carriesMicronutrientData(logged))
    }

    // MARK: - Fixtures

    /// `dayCount` consecutive May days, each with three meals that together reach `dailyValueShare` of
    /// every tracked daily value; every `unloggedEvery`-th day (counting from the second) has no meals.
    private static func history(
        dayCount: Int, dailyValueShare: Double, unloggedEvery: Int? = nil
    ) -> [(String, FernletDay)] {
        (1...dayCount).map { dayNumber in
            let key = "2026-05-\(String(format: "%02d", dayNumber))"
            if let unloggedEvery, dayNumber % unloggedEvery == 0 {
                return (key, FernletDay(date: key))
            }
            let meals = (0..<3).map { _ in meal(dailyValueShare: dailyValueShare / 3) }
            return (key, FernletDay(date: key, meals: meals))
        }
    }

    /// One meal carrying `dailyValueShare` of every tracked nutrient's daily value, or none at all.
    private static func meal(dailyValueShare share: Double?) -> Meal {
        let micronutrients = share.map { share in
            Micronutrients(
                fiber: FDADailyValues.fiberGrams * share,
                vitaminC: FDADailyValues.vitaminCMilligrams * share,
                vitaminD: FDADailyValues.vitaminDMicrograms * share,
                vitaminB12: FDADailyValues.vitaminB12Micrograms * share,
                folate: FDADailyValues.folateMicrogramsDFE * share,
                calcium: FDADailyValues.calciumMilligrams * share,
                iron: FDADailyValues.ironMilligrams * share,
                magnesium: FDADailyValues.magnesiumMilligrams * share,
                potassium: FDADailyValues.potassiumMilligrams * share,
                zinc: FDADailyValues.zincMilligrams * share,
                omega3: FDADailyValues.omega3ALAGrams * share
            )
        } ?? Micronutrients()
        return Meal(
            name: "Test meal", mealType: .lunch, macros: Macros(protein: 20, carbs: 30, fat: 10),
            micronutrientSnapshot: micronutrients,
            quality: .good, confidence: "Manual", note: "", source: "Manual"
        )
    }
}
