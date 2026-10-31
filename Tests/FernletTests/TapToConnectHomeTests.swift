// TapToConnectHomeTests.swift
// FernletTests
//
// World Friends §1.2–1.3 (screens 1, 2 and 8): what Home draws for meeting someone new by tapping phones. The
// rings' strength mapping (stronger as the phones come together; still under Reduce Motion, only the opacity
// following), the once-per-appearance gate behind Sprout's "Ooh! Who's that?" and VoiceOver's one announcement of
// the plate, Sprout's line winning the bubble, the question sheet staying up through the wait, and the name shown
// for someone who set none. The radio and its privacy are TapToConnectTests' and ProximityKit's.

import Foundation
import Testing
@testable import Fernlet

/// The rings' drawing (``TapToConnectRingStyle``).
struct TapToConnectRingStyleTests {

    @Test func theStrengthIsTheClosenessClampedAndNothingIsZero() {
        #expect(TapToConnectRingStyle.strength(nil) == 0)
        #expect(TapToConnectRingStyle.strength(.nan) == 0)
        #expect(TapToConnectRingStyle.strength(-0.5) == 0)
        #expect(TapToConnectRingStyle.strength(0.4) == 0.4)
        #expect(TapToConnectRingStyle.strength(3) == 1)
    }

    @Test func theRingsGrowStrongerAsThePhonesComeTogether() {
        let far = TapToConnectRingStyle.rings(strength: 0.1, time: nil)
        let near = TapToConnectRingStyle.rings(strength: 0.9, time: nil)
        #expect(far.count == 3 && near.count == 3)
        for (a, b) in zip(far, near) {
            #expect(b.opacity > a.opacity)
            #expect(b.lineWidth > a.lineWidth)
        }
    }

    @Test func reduceMotionStillsTheRingsAtThePagesSizesAndOnlyTheOpacityFollows() {
        let far = TapToConnectRingStyle.rings(strength: 0, time: nil)
        let touching = TapToConnectRingStyle.rings(strength: 1, time: nil)
        #expect(far.map(\.radius) == [150, 215, 280])
        #expect(touching.map(\.radius) == far.map(\.radius))
        // Touching, the rings are the approved page's 90 %, 60 % and 35 %.
        #expect(zip(touching.map(\.opacity), [0.9, 0.6, 0.35]).allSatisfy { abs($0 - $1) < 0.0001 })
    }

    @Test func theRippleMovesTheRingsOutwardAndStaysWithinItsBand() {
        let start = TapToConnectRingStyle.rings(strength: 0.5, time: 0)
        let later = TapToConnectRingStyle.rings(strength: 0.5, time: 0.5)
        #expect(later[0].radius > start[0].radius)
        // R2-style sweep: every frame over two periods keeps every ring inside its band and visible-or-faded.
        for step in 0..<48 {
            for ring in TapToConnectRingStyle.rings(strength: 0.5, time: Double(step) * 0.1) {
                #expect(ring.radius >= TapToConnectRingStyle.innerRadius && ring.radius <= TapToConnectRingStyle.outerRadius)
                #expect(ring.opacity >= 0 && ring.opacity <= 1)
            }
        }
    }
}

/// The once-per-appearance gate (``TapToConnectAppearanceGate``) and the cue it drives (``TapToConnectHomeCue``).
@MainActor
struct TapToConnectAppearanceTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Runs `events` (showing, seconds after `t0`) through one gate and returns each answer.
    private func run(_ events: [(showing: Bool, at: TimeInterval)]) -> [Bool] {
        var gate = TapToConnectAppearanceGate()
        return events.map { gate.observe(showing: $0.showing, at: t0.addingTimeInterval($0.at)) }
    }

    @Test func theFirstAppearanceCountsAndAClosenessChangeNeverRepeatsIt() {
        #expect(run([(true, 0), (true, 1), (true, 2)]) == [true, false, false])
    }

    @Test func ringsThatBlinkAtTheEdgeAreTheSameAppearance() {
        // Back 9 s after they last went: still the same appearance.
        #expect(run([(true, 0), (false, 5), (true, 8), (false, 9), (true, 18)]) == [true, false, false, false, false])
    }

    @Test func ringsBackAfterTheRearmAreANewAppearance() {
        let rearm = TapToConnectAppearanceGate.rearmSeconds
        #expect(run([(true, 0), (false, 3), (true, 3 + rearm)]) == [true, false, true])
    }

    @Test func theCueSaysOohOnceAndTheLineGoesWithTheRings() {
        let cue = TapToConnectHomeCue()
        let appeared = cue.update(closeness: 0.3, isFrontmost: true, at: t0)
        #expect(appeared && cue.isRinging && cue.line == .someoneClose)
        let closer = cue.update(closeness: 0.8, isFrontmost: true, at: t0.addingTimeInterval(1))
        #expect(!closer && cue.strength == 0.8)
        let gone = cue.update(closeness: nil, isFrontmost: true, at: t0.addingTimeInterval(2))
        #expect(!gone && !cue.isRinging && cue.line == nil)
    }

    @Test func behindAPanelNothingRingsWhateverTheRadioLastHeard() {
        let cue = TapToConnectHomeCue()
        let appeared = cue.update(closeness: 0.6, isFrontmost: false, at: t0)
        #expect(!appeared && !cue.isRinging && cue.line == nil)
    }

    @Test func theRingsGoingLeaveMaybeAnotherTimeStanding() {
        let cue = TapToConnectHomeCue()
        cue.line = .maybeAnotherTime
        let appeared = cue.update(closeness: nil, isFrontmost: true, at: t0)
        #expect(!appeared && cue.line == .maybeAnotherTime)
    }
}

/// Sprout's bubble, the question sheet's presence and the name it shows.
@MainActor
struct TapToConnectHomeCopyTests {

    @Test func sproutsTapLineWinsTheBubbleEvenOverAWaitingStamp() {
        var facts = WorldMapLine.Facts()
        facts.stampWaiting = true
        facts.discovery = "A desert!"
        facts.tapToConnect = "Ooh! Who's that?"
        #expect(WorldMapLine.line(facts) == "Ooh! Who's that?")
        facts.tapToConnect = nil
        #expect(WorldMapLine.line(facts) == nil)
    }

    @Test func theSheetStaysUpThroughTheWaitAndGoesWithBoth() {
        let rae = TapToConnectQuestion(displayName: "Rae", appearance: nil)
        #expect(TapToConnectSnapshot(question: rae).isQuestionUp)
        #expect(TapToConnectSnapshot(isWaitingForPeer: true).isQuestionUp)
        #expect(!TapToConnectSnapshot(closeness: 0.9).isQuestionUp)
    }

    @Test func someoneWhoSetNoNameReadsAsTheAppsPlaceholderWithNoAppearsAsLine() {
        let unnamed = TapToConnectQuestion(displayName: "", appearance: nil)
        #expect(!unnamed.hasName)
        #expect(!unnamed.shownName.isEmpty)
        #expect(unnamed.shownName != unnamed.displayName)
        let rae = TapToConnectQuestion(displayName: "Rae", appearance: nil)
        #expect(rae.hasName && rae.shownName == "Rae")
        // A fingerprint-shaped name is never shown as a name.
        #expect(!TapToConnectQuestion(displayName: "0123456789abcdef", appearance: nil).hasName)
    }

    @Test func theQuestionAndTheWaitNameThePerson() {
        #expect(String(localized: TapToConnectCopy.question("Rae")).contains("Rae"))
        #expect(String(localized: TapToConnectCopy.waiting("Rae")).contains("Rae"))
        #expect(TapToConnectCopy.plateAnnouncement.contains(String(localized: TapToConnectCopy.plateDetail)))
    }
}
