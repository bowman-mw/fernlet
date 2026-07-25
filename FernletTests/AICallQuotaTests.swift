import Foundation
import Testing
import AIContext
import FernletDomainModel
import FernletPersistence

@Suite struct AICallQuotaTests {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    // MARK: - Day-boundary rollover

    @Test func recordingCallRollsOverAtDayBoundary() {
        let cal = utc
        let quota = AICallQuota(dayKey: AICallQuota.dayKey(for: date(2026, 7, 23), calendar: cal), count: 59)
        // Same day → increments.
        let same = quota.recordingCall(now: date(2026, 7, 23, 23), calendar: cal)
        #expect(same.count == 60)
        // New day → resets to 1 and re-anchors the day key.
        let next = quota.recordingCall(now: date(2026, 7, 24, 0), calendar: cal)
        #expect(next.count == 1)
        #expect(next.dayKey == AICallQuota.dayKey(for: date(2026, 7, 24), calendar: cal))
    }

    @Test func staleDayCounterReadsAsZeroToday() {
        let cal = utc
        let quota = AICallQuota(dayKey: AICallQuota.dayKey(for: date(2026, 7, 23), calendar: cal), count: 90)
        #expect(quota.effectiveCount(now: date(2026, 7, 24), calendar: cal) == 0)
        #expect(quota.derivedStatus(now: date(2026, 7, 24), calendar: cal) == .ready)
        // Same day still reflects the tally.
        #expect(quota.effectiveCount(now: date(2026, 7, 23), calendar: cal) == 90)
    }

    // MARK: - Sleepy / resting derivation thresholds

    @Test func derivationThresholds() {
        let cal = utc
        let key = AICallQuota.dayKey(for: date(2026, 7, 24), calendar: cal)
        func status(_ n: Int) -> AIStatus {
            AICallQuota(dayKey: key, count: n).derivedStatus(now: date(2026, 7, 24), calendar: cal)
        }
        #expect(status(0) == .ready)
        #expect(status(29) == .ready)
        #expect(status(30) == .sleepy)   // sleepy at >= 30
        #expect(status(59) == .sleepy)
        #expect(status(60) == .resting)  // resting at >= 60
        #expect(status(200) == .resting)
        #expect(AICallQuota.sleepyThreshold == 30)
        #expect(AICallQuota.restingThreshold == 60)
    }

    // MARK: - Overlay: stored intent × local counter

    @Test func overlayOffIntentIsNeverOverriddenByUsage() {
        let cal = utc
        let key = AICallQuota.dayKey(for: date(2026, 7, 24), calendar: cal)
        let busy = AICallQuota(dayKey: key, count: 200)
        #expect(AIStatusOverlay.effectiveStatus(intent: .off, quota: busy, now: date(2026, 7, 24), calendar: cal) == .off)
    }

    @Test func overlayReadyIntentReflectsCounter() {
        let cal = utc
        let key = AICallQuota.dayKey(for: date(2026, 7, 24), calendar: cal)
        func effective(_ n: Int) -> AIStatus {
            AIStatusOverlay.effectiveStatus(intent: .ready, quota: AICallQuota(dayKey: key, count: n), now: date(2026, 7, 24), calendar: cal)
        }
        #expect(effective(0) == .ready)
        #expect(effective(30) == .sleepy)
        #expect(effective(60) == .resting)
    }

    // MARK: - The counter never syncs

    @Test func quotaTypeIsNotCodableSoItCannotRideAnyEncoder() {
        // The STRUCTURAL guarantee behind "the counter never syncs": `AICallQuota` is deliberately not
        // Codable, so it cannot be a `FernletSettings`/`FernletSnapshot` stored field and cannot ride
        // any JSON encoder to CloudKit. If a future edit adds `: Codable` (or `Encodable`/`Decodable`)
        // — the exact regression the substring canary below would MISS if the field were renamed —
        // these casts start succeeding and the test fails. Routed through `Any` so the compiler can't
        // fold the cast to a constant. See review finding #4 (Seam-core).
        let quota: Any = AICallQuota(dayKey: "2026-07-24", count: 5)
        #expect(!(quota is any Encodable))
        #expect(!(quota is any Decodable))
    }

    @Test func quotaCounterIsAbsentFromFernletSnapshotEncode() throws {
        let snapshot = FernletSnapshot(
            todayKey: "2026-07-24",
            day: FernletDay(date: "2026-07-24"),
            settings: FernletSettings(),
            recentMeals: [],
            previousJournals: [],
            memories: [],
            goals: [],
            workshop: WorkshopData()
        )
        let data = try JSONEncoder().encode(snapshot)
        let json = String(decoding: data, as: UTF8.self).lowercased()
        // The device-local counter must never ride the synced blob. (Note: the snapshot legitimately
        // carries `todayKey` — a *day* string, unrelated to the quota — so we assert on the quota's
        // own field names, not the substring "daykey".)
        #expect(!json.contains("quota"))
        #expect(!json.contains("aicallcount"))
        #expect(!json.contains("callcount"))
    }

    // MARK: - EnumDecodeCompat parking for an unknown future AIDestination raw value

    @Test func unknownAIDestinationTokenFreezesAndParks() {
        // Mirrors the freeze/park discipline the codebase applies to synced enums: an unknown raw
        // value from a newer build resolves to the default and is parked, not dropped or crashed.
        let result = EnumDecodeCompat.resolveScalar(
            token: "someFutureDestination2099",
            parkedToken: nil,
            default: AIDestination.onDeviceFoundationModels
        )
        #expect(result.value == .onDeviceFoundationModels)
        #expect(result.parkedToken == "someFutureDestination2099")
    }

    @Test func knownAIDestinationTokenResolvesNormally() {
        let result = EnumDecodeCompat.resolveScalar(
            token: "privateCloudCompute",
            parkedToken: nil,
            default: AIDestination.onDeviceFoundationModels
        )
        #expect(result.value == .privateCloudCompute)
        #expect(result.parkedToken == nil)
    }

    @Test func aiDestinationLeavesDeviceClassification() {
        #expect(AIDestination.onDeviceFoundationModels.leavesDevice == false)
        for d in [AIDestination.webNutritionLookup, .privateCloudCompute, .externalAnthropic, .externalOpenAICompatible] {
            #expect(d.leavesDevice == true)
        }
    }
}
