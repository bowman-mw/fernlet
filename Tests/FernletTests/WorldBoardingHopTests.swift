import Foundation
import Testing
@testable import Fernlet

/// The boarding hop (owner 2026-11-18, page UABPFeySzGuLEisj7bMKn3): once per switch between the map and the plane,
/// never stacked, nothing on the first look or in a decoy; the keyframes' story in both directions; and the side-on
/// plane's art.
@MainActor
struct WorldBoardingHopTests {
    /// A fresh defaults suite.
    private func defaults() throws -> UserDefaults {
        let name = "WorldBoardingHopTests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    @Test func gatePlaysOnlyForASwitchSinceTheLastLook() {
        let gate = WorldBoardingHopGate.self
        #expect(gate.decide(remembered: nil, now: .air, canPlay: true, isDecoy: false) == .init(play: nil, remember: .air))
        #expect(gate.decide(remembered: .ground, now: .ground, canPlay: true, isDecoy: false) == .init(play: nil, remember: nil))
        #expect(gate.decide(remembered: .ground, now: .air, canPlay: true, isDecoy: false) == .init(play: .boarding, remember: .air))
        #expect(gate.decide(remembered: .air, now: .ground, canPlay: true, isDecoy: false) == .init(play: .landing, remember: .ground))
        // Not in front: nothing now, and nothing remembered, so it plays when Home comes back.
        #expect(gate.decide(remembered: .air, now: .ground, canPlay: false, isDecoy: false) == .init(play: nil, remember: nil))
        // A decoy plays nothing and leaves the real Home's memory alone.
        #expect(gate.decide(remembered: .air, now: .ground, canPlay: true, isDecoy: true) == .init(play: nil, remember: nil))
    }

    @Test func stateRemembersAsItStartsSoAChangePlaysOnce() throws {
        let defaults = try defaults()
        let hop = WorldBoardingHopState()
        hop.consider(sky: .ground, canPlay: true, isDecoy: false, companion: "Sprout", defaults: defaults)
        #expect(hop.play == nil)
        #expect(WorldMapPreferences.lastHomeSky(in: defaults) == .ground)
        // Took off while the app was away: nothing until Home is in front.
        hop.consider(sky: .air, canPlay: false, isDecoy: false, companion: "Sprout", defaults: defaults)
        #expect(hop.play == nil)
        hop.consider(sky: .air, canPlay: true, isDecoy: false, companion: "Sprout", defaults: defaults)
        let play = try #require(hop.play)
        #expect(play.direction == .boarding)
        #expect(play.line.contains("Sprout"))
        #expect(WorldMapPreferences.lastHomeSky(in: defaults) == .air)
        hop.skip(play.id)
        #expect(hop.play?.skippedAt != nil)
        hop.finish(play.id)
        #expect(hop.play == nil)
        // The same change again (a relaunch, Home coming back to the front): nothing more.
        hop.consider(sky: .air, canPlay: true, isDecoy: false, companion: "Sprout", defaults: defaults)
        #expect(hop.play == nil)
    }

    @Test func aRoundTripWhileAwayPlaysNothing() throws {
        let defaults = try defaults()
        WorldMapPreferences.setLastHomeSky(.ground, in: defaults)
        let hop = WorldBoardingHopState()
        hop.consider(sky: .ground, canPlay: true, isDecoy: false, companion: "Sprout", defaults: defaults)
        #expect(hop.play == nil)
    }

    @Test func clearAllForgetsTheLastHome() throws {
        let defaults = try defaults()
        WorldMapPreferences.setLastHomeSky(.air, in: defaults)
        WorldMapPreferences.clearAll(in: defaults)
        #expect(WorldMapPreferences.lastHomeSky(in: defaults) == nil)
    }

    @Test func boardingTellsItsStory() {
        let timeline = WorldBoardingHopTimeline.self
        let start = timeline.boarding(at: 0)
        #expect(start.sprout == timeline.ground && start.doorOpen && start.steps == 1 && start.climb == 0)
        let aboard = timeline.boarding(at: 1.5)
        #expect(aboard.sprout == nil && !aboard.doorOpen && aboard.windowLit)
        let cruising = timeline.boarding(at: 3.6)
        #expect(cruising.climb == 1 && !cruising.gearDown && cruising.zoom == 0)
        let handOver = timeline.boarding(at: 4.7)
        #expect(handOver.zoom == 1 && handOver.flightView > 0.8)
        #expect(timeline.boarding(at: timeline.duration).opacity == 0)
    }

    @Test func landingTellsItsStoryBackwards() {
        let timeline = WorldBoardingHopTimeline.self
        let start = timeline.landing(at: 0)
        #expect(start.zoom == 1 && start.flightView == 1 && start.climb == 1 && start.sprout == nil)
        let down = timeline.landing(at: 2.4)
        #expect(down.climb == 0 && down.gearDown && down.puff > 0)
        let off = timeline.landing(at: 4.5)
        #expect(off.sprout == timeline.ground && off.doorOpen && off.steps == 1 && !off.windowLit)
        #expect(timeline.landing(at: timeline.duration).opacity == 0)
    }

    @Test func reduceMotionHoldsTheEndStillThenFades() {
        let timeline = WorldBoardingHopTimeline.self
        let held = timeline.frame(.landing, at: 0.5, reduceMotion: true)
        #expect(held.sprout == timeline.ground && held.opacity == 1 && held.zoom == 0)
        #expect(timeline.frame(.boarding, at: 0.5, reduceMotion: true).climb == 1)
        #expect(timeline.frame(.boarding, at: timeline.length(reduceMotion: true), reduceMotion: true).opacity == 0)
    }

    @Test func hopsStayOnThePixelGrid() {
        let timeline = WorldBoardingHopTimeline.self
        // Bounded: one sample a twentieth of a second.
        for step in 0...100 {
            let t = Double(step) / 20
            for point in [timeline.boardingSprout(at: t), timeline.landingSprout(at: t)].compactMap({ $0 }) {
                #expect(point.x.truncatingRemainder(dividingBy: timeline.pixel) == 0)
                #expect(point.y.truncatingRemainder(dividingBy: timeline.pixel) == 0)
            }
        }
    }

    @Test func sideJetArtIsWholeAndItsLooksDiffer() {
        let jet = WorldSideJetSprite.self
        #expect(jet.rows.count == jet.height)
        #expect(jet.rows.allSatisfy { $0.count == jet.width })
        #expect(jet.rows.allSatisfy { row in row.allSatisfy { $0 == "." || jet.palette[$0] != nil } })
        #expect(jet.parked != jet.rolling && jet.rolling != jet.flying)
        // The window Sprout looks out of is glass on every look.
        let window = jet.sproutWindow
        let row = Array(jet.flying.rows[window.y])
        #expect(row[window.x] == "w")
    }

    @Test func colourRunsCoverEveryPixelOnce() {
        let sprite = WorldSideJetSprite.parked
        let painted = sprite.rows.reduce(0) { $0 + $1.filter { $0 != "." }.count }
        let runs = WorldSideJetSprite.colourRuns(of: sprite)
        #expect(runs.reduce(0) { $0 + $1.length } == painted)
        #expect(runs.count < painted / 2)
    }
}
