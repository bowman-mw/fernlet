import FernletDomainModel
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Who maps a road trip (`rt-mapper`, owner's pick "auto", 2026-11-10) and what that means for the location source: the
/// rule's table, "Map from this iPhone" and when it lapses, and that a passenger's iPhone never traces the drive.
@MainActor
struct RoadTripMapperTests {
    private static let members = ["mike", "rae", "sam"]
    private static let carPlay = RoadTripDeviceState(onCarPlay: true, isCharging: false)
    private static let charging = RoadTripDeviceState(onCarPlay: false, isCharging: true)
    private static let neither = RoadTripDeviceState(onCarPlay: false, isCharging: false)

    // MARK: The rule

    /// The phone on CarPlay or charging maps; with none or several, the person who started; with the starter gone, the
    /// first member.
    @Test func theRulesTable() {
        let rows: [(states: [String: RoadTripDeviceState], starter: String, expected: String?)] = [
            ([:], "mike", "mike"),
            (["rae": Self.neither, "sam": Self.neither], "mike", "mike"),
            (["rae": Self.charging], "mike", "rae"),
            (["sam": Self.carPlay], "mike", "sam"),
            (["sam": RoadTripDeviceState(onCarPlay: true, isCharging: true)], "mike", "sam"),
            (["rae": Self.charging, "sam": Self.carPlay], "mike", "mike"),
            (["mike": Self.charging, "rae": Self.charging, "sam": Self.charging], "rae", "rae"),
            (["stranger": Self.carPlay], "mike", "mike"),
            ([:], "gone", "mike"),
            (["rae": Self.charging, "sam": Self.charging], "gone", "mike"),
        ]
        for row in rows {
            #expect(RoadTripMapperRule.ruleAnswer(members: Self.members, starter: row.starter, states: row.states) == row.expected,
                    "\(row.states) started by \(row.starter)")
        }
        #expect(RoadTripMapperRule.ruleAnswer(members: [], starter: "mike", states: [:]) == nil)
        #expect(RoadTripMapperRule.mapper(members: [], starter: "mike", states: [:], override: nil) == nil)
    }

    /// "Map from this iPhone" holds while the rule answers what it did when it was made, and lapses at a stop where the
    /// rule answers someone else, or when its member is no longer on the trip.
    @Test func anOverrideHoldsUntilTheRuleChanges() throws {
        let override = RoadTripMapperOverride(memberID: "sam", at: Date(timeIntervalSince1970: 0), ruleAnswer: "mike")
        let held = try #require(RoadTripMapperRule.mapper(members: Self.members, starter: "mike", states: [:], override: override))
        #expect(held.mapper == "sam" && held.override == override)
        let changed = try #require(RoadTripMapperRule.mapper(members: Self.members, starter: "mike", states: ["rae": Self.carPlay],
                                                             override: override))
        #expect(changed.mapper == "rae" && changed.override == nil, "Rae went on CarPlay: the rule decides again")
        let gone = try #require(RoadTripMapperRule.mapper(members: ["mike", "rae"], starter: "mike", states: [:], override: override))
        #expect(gone.mapper == "mike" && gone.override == nil)
    }

    /// On the keeper: a passenger's "Map from this iPhone" makes it the mapper, recording what the rule said; a stop
    /// with the same answer keeps it, one with another answer gives the mapping back. The passenger callback follows.
    @Test func mapFromThisPhoneAndTheNextStop() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = RoadTripKeeper(vault: vault)
        var told: [Bool] = []
        keeper.onPassengerChanged = { told.append($0) }
        keeper.load()
        #expect(keeper.start(RoadTripCoreTests.trip(mapper: "rae", starter: "rae")))
        #expect(keeper.isPassenger && told == [true])
        #expect(keeper.mapFromThisPhone(states: ["me": Self.neither], now: Date(timeIntervalSince1970: 5)))
        let trip = try #require(keeper.active)
        #expect(trip.isMapping && trip.mapperOverride?.ruleAnswer == "rae" && told == [true, false])
        #expect(!keeper.mapFromThisPhone(states: [:]), "already mapping")
        #expect(keeper.applyMapperRule(states: ["sam": Self.neither]))
        #expect(keeper.isMapping, "the rule still answers Rae: the override holds")
        #expect(keeper.applyMapperRule(states: ["sam": Self.charging]))
        #expect(keeper.active?.mapperID == "sam" && keeper.active?.mapperOverride == nil && told == [true, false, true])
        let reread = RoadTripKeeper(vault: vault)
        reread.load()
        #expect(reread.active == keeper.active, "every change is sealed")
    }

    // MARK: Passengers don't trace

    /// A road trip's passenger never starts a drive's trace, and no listen while driving; a bike ride and everything
    /// off a trip are as they were.
    @Test func aPassengerTracesNoDrive() {
        #expect(!WorldLocationSource.startsTrace(.drive, roadTripPassenger: true))
        #expect(WorldLocationSource.startsTrace(.drive, roadTripPassenger: false))
        #expect(WorldLocationSource.startsTrace(.ride, roadTripPassenger: true))
        #expect(WorldLocationSource.startsTrace(.ride, roadTripPassenger: false))
        #expect(!WorldLocationSource.listens(roadTripPassenger: true, driving: true))
        #expect(WorldLocationSource.listens(roadTripPassenger: true, driving: false))
        #expect(WorldLocationSource.listens(roadTripPassenger: false, driving: true))
        #expect(WorldLocationSource.listens(roadTripPassenger: false, driving: false))
    }

    /// The gate on the source: told by the keeper, readings at a car's speed still make a drive (Sprout rides along),
    /// and no trace or listen runs (the test host has no Always, so the pure rules above carry the trace's half);
    /// mapping again lifts it.
    @Test func thePassengerGateOnTheSource() {
        let source = WorldLocationSource()
        source.setRoadTripPassenger(true)
        #expect(source.isRoadTripPassenger)
        let here = GeoPoint(45.5205, -122.6255), now = Date(timeIntervalSince1970: 2_000_000_000)
        for step in 0..<4 {
            source.deliver(WorldFix(point: here.offset(east: Double(step) * 200, north: 0), accuracy: 8,
                                    at: now.addingTimeInterval(Double(step) * 10), isPrecise: true, speed: 20))
        }
        #expect(source.rides.isDriving, "car detection still runs")
        #expect(!source.isTracingDrive && !source.isListening)
        source.setRoadTripPassenger(false)
        #expect(!source.isRoadTripPassenger)
    }

    /// Trip info's VoiceOver label and default name read the approved copy.
    @Test func theChipAndTitleReadTheApprovedCopy() {
        #expect(RoadTripCopy.spokenChip(others: ["Rae", "Sam"]) == "Road trip with Rae and Sam")
        #expect(RoadTripCopy.spokenChip(others: ["Rae"]) == "Road trip with Rae")
        #expect(RoadTripCopy.spokenChip(others: []) == "Road trip")
        #expect(AddressedCopy.plain(RoadTripCopy.chip(members: 3)) == "Road trip · 3")
        #expect(AddressedCopy.plain(RoadTripCopy.mapping("Mike")) == "Mapping: Mike's iPhone")
        #expect(AddressedCopy.plain(RoadTripCopy.photos(6)) == "6 photos")
        #expect(AddressedCopy.plain(RoadTripCopy.photos(1)) == "1 photo")
        #expect(RoadTripCopy.name(of: RoadTripCoreTests.trip()).hasPrefix("Road trip · "))
    }
}
