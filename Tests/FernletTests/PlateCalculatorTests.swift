// PlateCalculatorTests.swift
// FernletTests
//
// Pins the runner's plate calculator (comparison report idea 12, 2026-10-20): which plates go on each
// side of a standard bar — 45 lb with 45/35/25/10/5/2.5 plates, 20 kg with 25/20/15/10/5/2.5/1.25 —
// greedy and heaviest first; exact when the weight can be made, otherwise the closest load (a tie to
// the lighter, anything under the bar to the bar alone); the lift's own unit; and the words, drawn
// ("Each side: 45, 10, and 2.5 lb", "Closest: 135 lb") and spoken ("… 2.5 pounds").
//
// How the disclosure reads with VoiceOver and at the largest text sizes is owed on a device.

import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

@MainActor
struct PlateCalculatorTests {

    nonisolated static let english = Locale(identifier: "en_US")

    func loadout(_ weight: Double, _ unit: LoadUnit = .lb) -> PlateLoadout {
        PlateCalculator.loadout(for: weight, on: .standard(unit))
    }

    func plain(_ text: String?) -> String? {
        text.map { $0.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ") }
    }

    // MARK: - The plates

    @Test func theStandardSetsAreTheGymsBarsAndPlates() {
        let pounds = BarbellPlateSet.standard(.lb)
        let kilos = BarbellPlateSet.standard(.kg)
        let poundPlates: [Double] = [45, 35, 25, 10, 5, 2.5]
        let kiloPlates: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25]
        #expect(pounds.bar == 45)
        #expect(pounds.plates == poundPlates)
        #expect(kilos.bar == 20)
        #expect(kilos.plates == kiloPlates)
        #expect(pounds.unit == .lb)
        #expect(kilos.unit == .kg)
    }

    @Test func exactWeightsLoadGreedilyHeaviestFirst() {
        let cases: [(weight: Double, side: [Double])] = [
            (135, [45]), (160, [45, 10, 2.5]), (185, [45, 25]), (225, [45, 45]), (95, [25]),
            (315, [45, 45, 45]), (50, [2.5]), (145, [45, 5]),
        ]
        for entry in cases {
            let result = loadout(entry.weight)
            #expect(result.perSide == entry.side, "\(entry.weight) lb")
            #expect(result.isExact, "\(entry.weight) lb")
            #expect(result.total == entry.weight, "\(entry.weight) lb")
        }
        let bar = loadout(45)
        #expect(bar.isJustTheBar)
        #expect(bar.isExact)
    }

    @Test func aWeightThePlatesCannotMakeGetsTheClosestOne() {
        let odd = loadout(137)
        #expect(!odd.isExact)
        #expect(odd.requested == 137)
        #expect(odd.total == 135)
        let oddSide: [Double] = [45]
        #expect(odd.perSide == oddSide)
        let up = loadout(138)
        #expect(up.total == 140, "138 is closer to 140")
        let tie = loadout(47.5)
        #expect(tie.total == 45, "a tie goes to the lighter load")
        let underBar = loadout(30)
        #expect(underBar.isJustTheBar)
        #expect(underBar.total == 45)
        #expect(!underBar.isExact)
        #expect(PlateCalculator.closestLoadable(137, on: .standard(.lb)) == 135)
        #expect(PlateCalculator.isLoadable(135, on: .standard(.lb)))
        #expect(!PlateCalculator.isLoadable(137, on: .standard(.lb)))
    }

    @Test func kilogramLiftsLoadKilogramPlates() {
        let hundred = loadout(100, .kg)
        let hundredSide: [Double] = [25, 15]
        #expect(hundred.perSide == hundredSide)
        #expect(hundred.unit == .kg)
        #expect(hundred.bar == 20)
        let small = loadout(102.5, .kg)
        let smallSide: [Double] = [25, 15, 1.25]
        #expect(small.perSide == smallSide)
        #expect(small.isExact)
        let odd = loadout(61, .kg)
        #expect(!odd.isExact)
        #expect(odd.total == 60)
        let poundPlatesInKilos = loadout(100, .kg).perSide.filter { $0 == 45 || $0 == 35 }
        #expect(poundPlatesInKilos.isEmpty)
        let kiloPlatesInPounds = loadout(160, .lb).perSide.filter { $0 == 1.25 || $0 == 20 || $0 == 15 }
        #expect(kiloPlatesInPounds.isEmpty)
    }

    @Test func everyLoadoutIsBoundedSortedAndSane() {
        for weight in stride(from: 0.0, through: 1_000.0, by: 2.5) {
            let result = loadout(weight)
            let sorted = result.perSide == result.perSide.sorted(by: >)
            let close = abs(result.total - max(45, weight)) <= 2.5
            #expect(sorted, "\(weight) lb")
            #expect(close, "\(weight) lb: \(result.total)")
            #expect(result.perSide.count <= PlateCalculator.maxPlatesPerSide)
        }
        let corrupt = loadout(.nan)
        #expect(corrupt.isJustTheBar)
        let huge = loadout(1_000_000)
        #expect(huge.perSide.count <= PlateCalculator.maxPlatesPerSide)
        #expect(huge.total <= ExerciseResult.maxWeight)
    }

    @Test func aPlateSetFromUserDataIsCleaned() {
        let set = BarbellPlateSet(unit: .lb, bar: .nan, plates: [10, 45, -5, .infinity, 10, 2.5, 0])
        let plates: [Double] = [45, 10, 2.5]
        #expect(set.plates == plates)
        #expect(set.bar == 0)
        #expect(set.smallestPlate == 2.5)
        let womens = BarbellPlateSet(unit: .lb, bar: 35, plates: [45, 25, 10, 5, 2.5])
        let side: [Double] = [45, 10]
        #expect(PlateCalculator.loadout(for: 145, on: womens).perSide == side)
    }

    // MARK: - The words

    @Test func eachSideIsListedHeaviestFirstWithTheUnitOnce() {
        let drawn = plain(GuidedPlateText.sides(loadout(160), width: .abbreviated, locale: Self.english))
        let spoken = plain(GuidedPlateText.sides(loadout(160), width: .wide, locale: Self.english))
        #expect(drawn == "Each side: 45, 10, and 2.5 lb")
        #expect(spoken == "Each side: 45, 10, and 2.5 pounds")
        let two = plain(GuidedPlateText.sides(loadout(225), width: .wide, locale: Self.english))
        #expect(two == "Each side: 45 and 45 pounds")
        let one = plain(GuidedPlateText.sides(loadout(135), width: .wide, locale: Self.english))
        #expect(one == "Each side: 45 pounds")
        #expect(GuidedPlateText.sides(loadout(45), width: .wide, locale: Self.english) == "Just the bar")
    }

    @Test func kilogramPlatesKeepTheirQuarterKilo() {
        let drawn = plain(GuidedPlateText.sides(loadout(102.5, .kg), width: .abbreviated, locale: Self.english))
        let spoken = plain(GuidedPlateText.sides(loadout(102.5, .kg), width: .wide, locale: Self.english))
        #expect(drawn == "Each side: 25, 15, and 1.25 kg")
        #expect(spoken == "Each side: 25, 15, and 1.25 kilograms")
        let bar = plain(GuidedPlateText.bar(loadout(100, .kg), width: .abbreviated, locale: Self.english))
        #expect(bar == "Bar: 20 kg")
    }

    @Test func anUnloadableWeightSaysSoAndNamesTheClosest() {
        let odd = loadout(137)
        let notExact = plain(GuidedPlateText.notExact(odd, width: .abbreviated, locale: Self.english))
        let closest = plain(GuidedPlateText.closest(odd, width: .abbreviated, locale: Self.english))
        let spokenClosest = plain(GuidedPlateText.closest(odd, width: .wide, locale: Self.english))
        #expect(notExact == "Can't load 137 lb exactly.")
        #expect(closest == "Closest: 135 lb")
        #expect(spokenClosest == "Closest: 135 pounds")
        let exact = loadout(135)
        let noNotExact = GuidedPlateText.notExact(exact, width: .abbreviated, locale: Self.english) == nil
        let noClosest = GuidedPlateText.closest(exact, width: .abbreviated, locale: Self.english) == nil
        #expect(noNotExact)
        #expect(noClosest)
        let bar = plain(GuidedPlateText.bar(exact, width: .wide, locale: Self.english))
        #expect(bar == "Bar: 45 pounds")
    }

    @Test func numbersFollowTheLocale() {
        let german = Locale(identifier: "de_DE")
        let side = plain(GuidedPlateText.sides(loadout(102.5, .kg), width: .abbreviated, locale: german)) ?? ""
        #expect(side.contains("1,25"), "\(side)")
    }
}
