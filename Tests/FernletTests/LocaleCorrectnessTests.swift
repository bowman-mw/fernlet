import Foundation
import SwiftUI
import Testing
import FernletFoundation
@testable import Fernlet

/// The month grid must start its week where the *calendar* says, not always on Sunday.
///
/// `veryShortWeekdaySymbols` is always Sunday-indexed regardless of locale; the locale's own
/// preference lives in `Calendar.firstWeekday`. Rendering the symbols unrotated over blanks padded
/// as `firstWeekday - 1` printed a Sunday-first header above a Monday-first grid, so every day cell
/// in Spain, France, Germany — and most of Europe — sat under the wrong letter.
struct MonthGridWeekStartTests {
    /// 2026-05-01 is a Friday, which makes each expectation below distinct.
    private func mayFirst(_ calendar: Calendar) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 1)))
    }

    private func calendar(firstWeekday: Int, locale: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: locale)
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    @Test func sundayFirstPadsToFridayAndLeadsWithSunday() throws {
        let calendar = calendar(firstWeekday: 1, locale: "en_US")
        let date = try mayFirst(calendar)
        let model = MonthGridModel(date: date, todayKey: FernletDate.dayKey(for: date), calendar: calendar)

        // Friday is the 6th column when the week starts on Sunday.
        #expect(model.leadingBlanks == 5)
        #expect(model.weekdaySymbols.first == calendar.veryShortWeekdaySymbols.first)
    }

    @Test func mondayFirstPadsToFridayAndLeadsWithMonday() throws {
        for locale in ["es_ES", "fr_FR", "de_DE"] {
            let calendar = calendar(firstWeekday: 2, locale: locale)
            let date = try mayFirst(calendar)
            let model = MonthGridModel(date: date, todayKey: FernletDate.dayKey(for: date), calendar: calendar)

            // Friday is the 5th column when the week starts on Monday — one blank fewer.
            #expect(model.leadingBlanks == 4, "wrong pad for \(locale)")
            // Index 1 of the Sunday-indexed symbol array is Monday.
            #expect(model.weekdaySymbols.first == calendar.veryShortWeekdaySymbols[1], "wrong lead for \(locale)")
            #expect(model.weekdaySymbols.last == calendar.veryShortWeekdaySymbols[0], "Sunday should wrap to last")
        }
    }

    @Test func saturdayFirstWrapsCorrectly() throws {
        let calendar = calendar(firstWeekday: 7, locale: "en_AE")
        let date = try mayFirst(calendar)
        let model = MonthGridModel(date: date, todayKey: FernletDate.dayKey(for: date), calendar: calendar)

        // Friday is the 7th and last column when the week starts on Saturday.
        #expect(model.leadingBlanks == 6)
        #expect(model.weekdaySymbols.first == calendar.veryShortWeekdaySymbols[6])
    }

    @Test func everyFirstWeekdayKeepsSevenSymbolsAndAPadInsideTheWeek() throws {
        for firstWeekday in 1...7 {
            let calendar = calendar(firstWeekday: firstWeekday, locale: "en_US")
            let date = try mayFirst(calendar)
            let model = MonthGridModel(date: date, todayKey: FernletDate.dayKey(for: date), calendar: calendar)

            #expect(model.weekdaySymbols.count == 7)
            #expect(Set(model.weekdaySymbols) == Set(calendar.veryShortWeekdaySymbols))
            #expect((0...6).contains(model.leadingBlanks), "pad escaped the week for \(firstWeekday)")
        }
    }
}

/// The gentle-support row must offer a number that connects *where the person is*.
///
/// Keyed on region, never language: a German speaker in the US needs 988, an American in Spain
/// needs 024. Anywhere Fernlet has no verified line, the row must show no number at all rather
/// than a plausible-looking one that fails to dial.
struct CrisisResourceTests {
    private let listedRegions = ["US", "CA", "GB", "IE", "ES", "FR", "DE", "AU", "NZ"]

    @Test func listedRegionsEachOfferAtLeastOneWorkingAction() {
        for identifier in listedRegions {
            let resource = CrisisResources.resource(for: Locale.Region(identifier))

            #expect(resource.actions.isEmpty == false, "\(identifier) lost its actions")
            #expect(resource.name.isEmpty == false)
            #expect(resource.blurb.isEmpty == false)
        }
    }

    @Test func actionURLsAreDialableAndNeverDropped() {
        // Actions are built through a failable URL path, so a typo would silently vanish; the
        // counts below turn that into a test failure instead of a dead button.
        let expectedActionCount = ["US": 2, "CA": 2, "NZ": 2, "GB": 1, "IE": 1, "ES": 1, "FR": 1, "DE": 1, "AU": 1]
        for (identifier, count) in expectedActionCount {
            let resource = CrisisResources.resource(for: Locale.Region(identifier))

            #expect(resource.actions.count == count, "\(identifier) has \(resource.actions.count) actions")
            for action in resource.actions {
                let scheme = action.url.scheme
                #expect(scheme == "tel" || scheme == "sms", "\(identifier) action \(action.id) is \(scheme ?? "nil")")
                #expect(action.title.isEmpty == false)
                #expect(action.systemImage.isEmpty == false)
            }
        }
    }

    @Test func theVerifiedNumbersAreTheOnesShown() {
        // Each of these was checked against the operator's own page before shipping; changing one
        // is a deliberate act that should fail here first.
        #expect(dialedNumbers(for: "US") == ["988", "988"])
        #expect(dialedNumbers(for: "CA") == ["988", "988"])
        #expect(dialedNumbers(for: "GB") == ["116123"])
        #expect(dialedNumbers(for: "IE") == ["116123"])
        #expect(dialedNumbers(for: "ES") == ["024"])
        #expect(dialedNumbers(for: "FR") == ["3114"])
        #expect(dialedNumbers(for: "DE") == ["08001110111"])
        #expect(dialedNumbers(for: "AU") == ["131114"])
        #expect(dialedNumbers(for: "NZ") == ["1737", "1737"])
    }

    @Test func unlistedRegionsAndNilFallBackToNoNumberAtAll() {
        // A number that does not connect in that country is worse than no number.
        for identifier in ["JP", "BR", "IN", "ZA", "PL"] {
            let resource = CrisisResources.resource(for: Locale.Region(identifier))

            #expect(resource.actions.isEmpty, "\(identifier) offered a number Fernlet has not verified")
            #expect(resource.name == CrisisResources.fallback.name)
        }
        #expect(CrisisResources.resource(for: nil).actions.isEmpty)
    }

    @Test func fallbackStillOffersSupportiveCopy() {
        #expect(CrisisResources.fallback.blurb.contains("emergency services"))
        #expect(CrisisResources.fallback.blurb.isEmpty == false)
    }

    private func dialedNumbers(for identifier: String) -> [String] {
        CrisisResources.resource(for: Locale.Region(identifier))
            .actions
            .compactMap { $0.url.absoluteString.split(separator: ":").last.map(String.init) }
    }
}

/// Body weight and height are stored imperial but must be *entered* in the reader's own units.
///
/// Both editors offered pounds and feet/inches only, so a metric user had to convert by hand to
/// enter their own body — and those numbers feed the BMR behind every nutrition target.
struct BodyMeasurementEntryTests {

    @Test func imperialKeepsPoundsAndFeetInches() {
        #expect(BodyMeasurementEntry.weightLabel(pounds: 168.2, imperial: true) == "Weight: 168 lb")
        #expect(BodyMeasurementEntry.heightLabel(inches: 69, imperial: true) == "Height: 5 ft 9 in")
    }

    @Test func metricShowsKilogramsAndCentimetres() {
        #expect(BodyMeasurementEntry.weightLabel(pounds: 165.3, imperial: false) == "Weight: 75 kg")
        #expect(BodyMeasurementEntry.heightLabel(inches: 69, imperial: false) == "Height: 175 cm")
    }

    @Test func metricBindingRoundTripsThroughStoredImperial() {
        var pounds = 165.3465
        let binding = BodyMeasurementEntry.weightBinding(
            Binding(get: { pounds }, set: { pounds = $0 }),
            imperial: false
        )

        #expect(binding.wrappedValue == 75)
        binding.wrappedValue = 76
        #expect(abs(pounds - 76 * BodyMeasurementEntry.poundsPerKilogram) < 0.0001)
        // And reading back gives the same whole number that was written — no stepper drift.
        #expect(binding.wrappedValue == 76)
    }

    @Test func metricHeightBindingRoundTrips() {
        var inches = 68.8976
        let binding = BodyMeasurementEntry.heightBinding(
            Binding(get: { inches }, set: { inches = $0 }),
            imperial: false
        )

        #expect(binding.wrappedValue == 175)
        binding.wrappedValue = 180
        #expect(abs(inches - 180 / BodyMeasurementEntry.centimetresPerInch) < 0.0001)
        #expect(binding.wrappedValue == 180)
    }

    @Test func displayRangesStayInsideTheStoredClamp() {
        // Converting a display bound back to storage must never leave UserNutritionProfile's
        // accepted range, or the profile would clamp the value out from under the stepper.
        let metricWeight = BodyMeasurementEntry.weightRange(imperial: false)
        let storedLow = metricWeight.lowerBound * BodyMeasurementEntry.poundsPerKilogram
        let storedHigh = metricWeight.upperBound * BodyMeasurementEntry.poundsPerKilogram
        #expect(storedLow >= 70)
        #expect(storedHigh <= 500)

        let metricHeight = BodyMeasurementEntry.heightRange(imperial: false)
        #expect(metricHeight.lowerBound / BodyMeasurementEntry.centimetresPerInch >= 48)
        #expect(metricHeight.upperBound / BodyMeasurementEntry.centimetresPerInch <= 84)
    }
}
