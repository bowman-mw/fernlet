import Foundation
import Testing
import FernletDomainModel
import FernletScoring
import FernletSocial
@testable import Fernlet

/// Gold hearts and the World Home's status data (World app plan step 2a; owner's answers 2026-10-23:
/// in-person hearts only, 12 hours each, at most two, +1/12 each to the live score, never to the saved
/// day score).
@MainActor
struct GoldHeartAndStatusTests {

    static let now = Date(timeIntervalSince1970: 1_792_800_000)

    static func hours(_ value: Double) -> Date { now.addingTimeInterval(-value * 3_600) }

    // MARK: The rules

    @Test func aGoldHeartLastsTwelveHours() {
        #expect(GoldHeartRules.activeArrivals([Self.hours(11.9)], at: Self.now).count == 1)
        #expect(GoldHeartRules.activeArrivals([Self.hours(12)], at: Self.now).isEmpty)
        #expect(GoldHeartRules.glowEnds([Self.hours(2)], at: Self.now) == Self.hours(2).addingTimeInterval(12 * 3_600))
        #expect(GoldHeartRules.glowEnds([Self.hours(13)], at: Self.now) == nil)
    }

    @Test func atMostTwoAndTheNewestCount() {
        let arrivals = [Self.hours(5), Self.hours(1), Self.hours(3)]
        #expect(GoldHeartRules.activeArrivals(arrivals, at: Self.now) == [Self.hours(1), Self.hours(3)])
        #expect(GoldHeartRules.glowEnds(arrivals, at: Self.now) == Self.hours(1).addingTimeInterval(12 * 3_600))
    }

    @Test func anArrivalFromTheFutureCountsAsJustArrived() {
        let future = Self.now.addingTimeInterval(600)
        #expect(GoldHeartRules.activeArrivals([future], at: Self.now) == [future])
        #expect(GoldHeartRules.glowEnds([future], at: Self.now) == Self.now.addingTimeInterval(12 * 3_600))
    }

    @Test func eachGoldHeartAddsOneHalfHeartAndTheScoreCaps() {
        #expect(GoldHeartRules.boosted(score: 0.5, goldHearts: 1) == 0.5 + 1.0 / 12)
        #expect(GoldHeartRules.boosted(score: 0.5, goldHearts: 5) == 0.5 + 2.0 / 12)
        #expect(GoldHeartRules.boosted(score: 0.95, goldHearts: 2) == 1)
        #expect(GoldHeartRules.boosted(score: .nan, goldHearts: 2) == 0)
        #expect(GoldHeartRules.boosted(score: 0.4, goldHearts: -1) == 0.4)
    }

    @Test func twoGoldHeartsCanLiftTheCompanionAState() {
        let score = 0.70
        #expect(FernletScoring.state(for: score) == .okay)
        #expect(FernletScoring.state(for: GoldHeartRules.boosted(score: score, goldHearts: 1)) == .thriving)
        #expect(FernletScoring.state(for: GoldHeartRules.boosted(score: 0.30, goldHearts: 2), isSick: true) == .sick)
    }

    // MARK: The status bar's data

    static func status(score: Double = 0.58, gold: Int = 0, bottles: Int = 3, target: Int = 4) -> WorldStatus {
        WorldStatus.make(score: score, goldHearts: gold, macros: MacroTotals(protein: 45, carbs: 300, fat: 0),
                         targets: NutritionTargets(calories: 2_000, protein: 90, carbs: 230, fat: 65, fiber: 30,
                                                   sodiumLimit: 2_300, saturatedFatLimit: 20),
                         bottles: bottles, bottleTarget: target)
    }

    @Test func heartsAreHealthBarsTwelveStepsWithTheBoost() {
        let plain = Self.status(score: 0.58)
        #expect(plain.heartSteps == 7 && plain.carePercent == 58 && plain.livePercent == 58)
        #expect(plain.heartFill(at: 0, of: 6) == 1 && plain.heartFill(at: 3, of: 6) == 0.5 && plain.heartFill(at: 4, of: 6) == 0)
        let lifted = Self.status(score: 0.58, gold: 2)
        #expect(lifted.heartSteps == 9 && lifted.carePercent == 58 && lifted.livePercent == 75 && lifted.goldHearts == 2)
        #expect(lifted.heartFill(at: 2, of: 4) == 1 && lifted.heartFill(at: 3, of: 4) == 0)
        #expect(lifted.heartFill(at: 1, of: 4) == 1 && Self.status(score: 0.5).heartFill(at: 1, of: 4) == 1)
        #expect(plain.heartFill(at: 9, of: 6) == 0 && plain.heartFill(at: 0, of: 5) == 0)
    }

    @Test func macrosAreTodayAgainstTarget() {
        let status = Self.status()
        #expect(status.protein.fraction == 0.5)
        #expect(status.carbs.fraction == 1, "over target fills the bar, no further")
        #expect(status.fat.fraction == 0)
        #expect(WorldStatus.Macro(grams: 10, target: 0).fraction == 0, "no target reads empty, never full")
    }

    @Test func waterIsBottlesAgainstTheTarget() {
        #expect(Self.status(bottles: 3, target: 4).water(accessibilitySize: false) == .drops(filled: 3, total: 4, extra: 0))
        #expect(Self.status(bottles: 6, target: 4).water(accessibilitySize: false) == .drops(filled: 4, total: 4, extra: 2))
        #expect(Self.status(bottles: 6, target: 10).water(accessibilitySize: false) == .count(bottles: 6, target: 10))
        #expect(Self.status(bottles: 6, target: 8).water(accessibilitySize: true) == .count(bottles: 6, target: 8))
        #expect(Self.status(bottles: 2, target: 0).water(accessibilitySize: false) == .count(bottles: 2, target: 0))
    }

    // MARK: The ledger

    @Test func onlyHeartsGivenInPersonTurnGold() {
        // An absent file loads as an empty ledger.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gold-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = ProximityHeartLedger(fileURL: root.appendingPathComponent("HeartLedger.json"), now: { Self.now })
        #expect(ledger.recordReceivedHeart(id: UUID(), senderDisplayName: "Sam", senderFingerprint: "a"))
        #expect(ledger.recordReceivedDropHeart(id: UUID(), senderDisplayName: "Ana", senderFingerprint: "b"))
        let flags = Dictionary(uniqueKeysWithValues: ledger.receivedHearts.map { ($0.senderDisplayName, $0.deliveredInPerson) })
        #expect(flags == ["Sam": true, "Ana": false])
        #expect(ledger.goldHeartArrivals(at: Self.now) == [Self.now])
        #expect(ledger.goldHeartArrivals(at: Self.now.addingTimeInterval(12 * 3_600)).isEmpty)
    }

    @Test func aRecordWrittenBeforeGoldHeartsDecodesAsNotInPerson() throws {
        let old = #"{"id":"6F2C1C7E-2C3B-4F3A-9C3A-8A1E2B3C4D5E","senderDisplayName":"Sam","senderFingerprint":"a","receivedAt":0}"#
        let record = try JSONDecoder().decode(ReceivedHeartRecord.self, from: Data(old.utf8))
        #expect(record.deliveredInPerson == nil)
    }
}
