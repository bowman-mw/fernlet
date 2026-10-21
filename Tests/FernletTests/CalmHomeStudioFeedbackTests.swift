// CalmHomeStudioFeedbackTests.swift
// FernletTests
//
// Tier B and C of the sounds-and-haptics pass for First Aid's calm tools, Home, the companion,
// Settings' reorders and the creation studio (2026-10-20; `Docs/Handoff/Sounds-Haptics-Investigation.md`
// §4, items B2–B5, B11–B13, B16, C3 and C6). Each call site's DECISION — which event plays, if any —
// is a pure function the app calls, and every one is played here through FernletFeedback's injected
// `perform` seam, because UIKit never reports back what it played. Where a call site has no seam of
// its own (a guard that keeps a path silent), a source pin holds it.
//
// Every level read here goes to a private `UserDefaults` suite: the real key is process-global disk
// state shared by every suite running in parallel.

import Foundation
import Testing
import FernletUI
@testable import Fernlet

/// Records what a ``FernletFeedback`` was asked to play.
@MainActor
private final class CueRecorder {
    /// Every cue that reached the player, in order.
    var played: [FernletFeedbackCue] = []
    /// The player's clock, stepped by hand so `logged`'s 150 ms pacing never hides a play.
    var now = ContinuousClock.now
    /// ONE player for the recorder's life.
    lazy var feedback = FernletFeedback(perform: { [unowned self] in played.append($0) }, now: { [unowned self] in now })

    var events: [FernletFeedbackEvent] { played.map(\.event) }

    /// Plays `event` a second after the last play, under `preferences`.
    func play(_ event: FernletFeedbackEvent, _ preferences: FernletFeedbackPreferences) {
        now = now.advanced(by: .seconds(1))
        feedback.play(event, preferences: preferences)
    }
}

@MainActor
@Suite struct CalmHomeStudioFeedbackTests {

    /// A fresh, private defaults suite holding `level` (or nothing).
    private func defaults(level: String? = nil) throws -> UserDefaults {
        let suite = try #require(UserDefaults(suiteName: "CalmHomeStudioFeedbackTests.\(UUID().uuidString)"))
        if let level { suite.set(level, forKey: FernletHapticsLevel.storageKey) }
        return suite
    }

    /// The body of the member function `signature` opens, up to its closing brace at four spaces.
    private func body(of signature: String, in path: String) throws -> String {
        let source = try RepoRoot.source(path)
        let start = try #require(source.range(of: signature), "\(signature) moved out of \(path)")
        let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.upperBound])
    }

    // MARK: The level

    /// Fewer drops the small taps under the thumb — every `tick`, `logged`, `moved` and `held` these
    /// surfaces play — and keeps the calm tools' session moments and the studio's results.
    @Test func fewerDropsTickLoggedMovedAndHeld() throws {
        let used: [FernletFeedbackEvent] = [.tick, .logged, .moved, .held, .pace, .done, .caveat]
        let fewer = FernletFeedbackPreferences.resolved(in: try defaults(level: "fewer"))
        let atFewer = CueRecorder()
        for event in used { atFewer.play(event, fewer) }
        #expect(atFewer.events == [.pace, .done, .caveat])

        let all = FernletFeedbackPreferences.resolved(in: try defaults(level: "all"))
        let atAll = CueRecorder()
        for event in used { atAll.play(event, all) }
        #expect(atAll.events == used)

        let off = FernletFeedbackPreferences.resolved(in: try defaults(level: "off"))
        let atOff = CueRecorder()
        for event in used { atOff.play(event, off) }
        #expect(atOff.played.isEmpty)
    }

    /// The Worry Box, the companion and the calm tools are haptics only: nothing they play can sound,
    /// whatever a caller passes (report §3.5).
    @Test func nothingHereCarriesASound() throws {
        let soundsOn = FernletFeedbackPreferences(hapticsEnabled: true, soundsEnabled: true)
        for event in [FernletFeedbackEvent.tick, .logged, .moved, .held, .pace, .done, .caveat] {
            let cue = try #require(FernletFeedbackCue(event: event, preferences: soundsOn))
            #expect(cue.sound == nil, "\(event) would sound")
        }
    }

    // MARK: B5, the companion

    /// A calm-idle pet plays nothing: the governor's settled period exists to slow petting, and a
    /// tap there would reward exactly what it slows. Driven through the real governor: four bounces
    /// (`logged`), the settling pet (`pace`), then settled pets that play nothing at all.
    @Test func aCalmIdlePetPlaysNothing() throws {
        #expect(HomeView.petFeedbackEvent(for: .bounce) == .logged)
        #expect(HomeView.petFeedbackEvent(for: .settling) == .pace)
        #expect(HomeView.petFeedbackEvent(for: .calmIdle(showsSettledLine: true)) == nil)
        #expect(HomeView.petFeedbackEvent(for: .calmIdle(showsSettledLine: false)) == nil)

        var clock = Date(timeIntervalSince1970: 3_000_000)
        let governor = PetInteractionGovernor(defaults: try defaults(), now: { clock })
        let on = FernletFeedbackPreferences.resolved(in: try defaults(level: "all"))
        let recorder = CueRecorder()
        var responses: [PetInteractionGovernor.Response] = []
        for _ in 0..<8 {
            clock = clock.addingTimeInterval(2)
            let response = governor.registerPet()
            responses.append(response)
            if let event = HomeView.petFeedbackEvent(for: response) { recorder.play(event, on) }
        }
        #expect(Array(responses.prefix(5)) == [.bounce, .bounce, .bounce, .bounce, .settling])
        #expect(responses.dropFirst(5).allSatisfy { if case .calmIdle = $0 { true } else { false } })
        #expect(recorder.events == [.logged, .logged, .logged, .logged, .pace], "a settled pet played a cue")
    }

    /// The pet's cue comes from the governor's answer and nowhere else: one play in the pet handler,
    /// none in the calm-idle squish.
    @Test func thePetHandlerPlaysOnlyTheGovernorsCue() throws {
        let pet = try body(of: "private func interactWithCompanion() {", in: "App/Fernlet/HomeView.swift")
        #expect(pet.contains("if let cue = Self.petFeedbackEvent(for: response) { FernletFeedback.system.play(cue) }"))
        #expect(pet.components(separatedBy: "FernletFeedback").count == 2, "a second cue in the pet handler")
        let calm = try body(of: "private func performCalmIdle(showsSettledLine: Bool) {", in: "App/Fernlet/HomeView.swift")
        #expect(!calm.contains("FernletFeedback") && !calm.contains("fernletFeedback"))
    }

    // MARK: B3 and C3, breathing

    /// Breathing off plays nothing — not a phase tap and not the finish — whatever the app-wide level;
    /// with both on, the taps and the finish play, and both stay at Fewer.
    @Test func breathingOffPlaysNothing() throws {
        let recorder = CueRecorder()
        for level in ["all", "fewer"] {
            let suite = try defaults(level: level)
            BreathingPacerHaptics.tap(hapticsEnabled: false, feedback: recorder.feedback, defaults: suite)
            BreathingPacerHaptics.finish(hapticsEnabled: false, feedback: recorder.feedback, defaults: suite)
        }
        let appOff = try defaults(level: "off")
        BreathingPacerHaptics.tap(hapticsEnabled: true, feedback: recorder.feedback, defaults: appOff)
        BreathingPacerHaptics.finish(hapticsEnabled: true, feedback: recorder.feedback, defaults: appOff)
        #expect(recorder.played.isEmpty)

        let fewer = try defaults(level: "fewer")
        BreathingPacerHaptics.tap(hapticsEnabled: true, feedback: recorder.feedback, defaults: fewer)
        BreathingPacerHaptics.finish(hapticsEnabled: true, feedback: recorder.feedback, defaults: fewer)
        #expect(recorder.events == [.pace, .done])
        #expect(recorder.played.map(\.haptic) == [.softPulse, .success])
    }

    /// C3: the phases feel different. Three taps spread across the inhale, nothing on a hold, one as
    /// the exhale begins; every tap falls inside its phase, and the first one at its start.
    @Test func breathingPhasesFeelDifferent() {
        let inhale = BreathPhase(kind: .inhale, seconds: 4, targetScale: 1)
        let offsets = BreathingPacerHaptics.tapOffsets(for: inhale)
        #expect(offsets.count == BreathingPacerHaptics.inhaleTaps && offsets.count == 3)
        #expect(zip(offsets, [0, 4.0 / 3, 8.0 / 3]).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(BreathingPacerHaptics.tapOffsets(for: BreathPhase(kind: .hold, seconds: 7, targetScale: 1)).isEmpty)
        #expect(BreathingPacerHaptics.tapOffsets(for: BreathPhase(kind: .exhale, seconds: 8, targetScale: 0.55)) == [0])

        for preset in BreathingPreset.all {
            for phase in preset.phases {
                let taps = BreathingPacerHaptics.tapOffsets(for: phase)
                #expect(taps.allSatisfy { $0 >= 0 && $0 < phase.seconds }, "\(preset.id): a tap outside its phase")
                #expect(taps == taps.sorted())
                #expect(taps.first.map { $0 == 0 } ?? true, "\(preset.id): a phase's first tap is late")
            }
        }
        // Box breathing is four taps a cycle: three in, none held, one out, none held.
        #expect(BreathingPreset.box.phases.map { BreathingPacerHaptics.tapOffsets(for: $0).count } == [3, 0, 1, 0])
        #expect(BreathingPreset.relax.phases.map { BreathingPacerHaptics.tapOffsets(for: $0).count } == [3, 0, 1])
        // The words follow the same kind, so a phase can never say "Hold" while it taps like an inhale.
        #expect(BreathingPreset.box.phases.map(\.label) ==
                [BreathingCopy.breatheIn, BreathingCopy.hold, BreathingCopy.breatheOut, BreathingCopy.hold])
    }

    // MARK: B2, the Worry Box

    /// The lid's `pace` lands with the lid: as the spring first meets the box in the full tuck, and as
    /// the crossfade settles under Reduce Motion — both inside their tuck's wait (2.2 s and 600 ms).
    @Test func theLidCueIsTimedToTheLidAndRetimedUnderReduceMotion() {
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        #expect(abs(WorryTuckTiming.lidSpringContact - 0.25) < 0.01, "the spring's first contact moved")
        let full = seconds(WorryTuckTiming.lidCueDelay(reduceMotion: false))
        #expect(abs(full - 1.30) < 0.01)
        #expect(full > WorryTuckTiming.lidSpringDelay && full < 2.2)
        let reduced = seconds(WorryTuckTiming.lidCueDelay(reduceMotion: true))
        #expect(abs(reduced - 0.35) < 1e-6 && reduced < 0.6)
    }

    /// B2's four moments, and the one that stays silent: the timed permanent release is passive —
    /// nobody acted just then — so the "Keep it" window running out plays nothing (report §3.8).
    @Test func theWorryBoxPlaysItsMomentsAndTheTimedReleaseStaysSilent() throws {
        let path = "App/Fernlet/WorryBoxView.swift"
        let moments = [
            "private func feelLidClose() async {": "FernletFeedback.system.play(.pace)",
            "private func release(_ worry: WorryNarrative) {": "FernletFeedback.system.play(.pace)",
            "private func keepPendingRelease() {": "FernletFeedback.system.play(.logged)",
            "private func sealComposedWorry() {": "FernletFeedback.system.play(.done)",
        ]
        for (signature, cue) in moments {
            let moment = try body(of: signature, in: path)
            #expect(moment.contains(cue), "\(signature) lost \(cue)")
        }
        let timed = try body(of: "private func startKeepItWindow(for worry: WorryNarrative) {", in: path)
        #expect(!timed.contains("FernletFeedback"), "the timed release plays a cue")
        let delete = try body(of: "private func performRelease(_ worry: WorryNarrative) {", in: path)
        #expect(delete.components(separatedBy: "FernletFeedback.system.play(").count == 2)
        #expect(delete.contains("FernletFeedback.system.play(.failed)"), "only a failed release is felt")
    }

    // MARK: B4, grounding

    /// Each sense step is a `pace`; leaving the last one completes the exercise with `done`.
    @Test func groundingPacesEachSenseAndFinishesDone() {
        let steps = 5
        #expect((0..<(steps - 1)).map { GroundingView.advanceEvent(from: $0, of: steps) } == [.pace, .pace, .pace, .pace])
        #expect(GroundingView.advanceEvent(from: steps - 1, of: steps) == .done)
    }

    // MARK: B16 and C6, the studio and the wardrobe

    /// Save to closet: `done` when the studio closes on a saved item, `caveat` when a refused listing
    /// keeps the person here with an alert. In the Wardrobe a refused "Sell" is a `caveat` and a
    /// listing that lands plays nothing extra.
    @Test func saveAndSellOutcomesFeelRight() {
        #expect(CreationStudioView.saveFeedbackEvent(for: .listed) == .done)
        #expect(CreationStudioView.saveFeedbackEvent(for: .notAllowed) == .done)
        #expect(CreationStudioView.saveFeedbackEvent(for: .nameFlagged) == .caveat)
        #expect(CreationStudioView.saveFeedbackEvent(for: .capReached) == .caveat)
        #expect(CreationStudioView.saveFeedbackEvent(for: .storeBanned(remainingSeconds: 60)) == .caveat)
        #expect(WardrobeView.listingFeedbackEvent(for: .listed) == nil)
        #expect(WardrobeView.listingFeedbackEvent(for: .notAllowed) == nil)
        #expect(WardrobeView.listingFeedbackEvent(for: .nameFlagged) == .caveat)
        #expect(WardrobeView.listingFeedbackEvent(for: .capReached) == .caveat)
        #expect(WardrobeView.listingFeedbackEvent(for: .storeBanned(remainingSeconds: 60)) == .caveat)
    }

    /// C6: the pixel canvas ticks once at a stroke's start, never per cell — a drag samples dozens of
    /// cells a second. The per-cell path and the canvas itself carry no cue.
    @Test func thePixelCanvasTicksAtStrokeStartOnly() throws {
        let studio = "App/Fernlet/CreationStudioView.swift"
        let stroke = try body(of: "private func beginStroke() {", in: studio)
        #expect(stroke.components(separatedBy: "FernletFeedback.system.play(.tick)").count == 2)
        #expect(try RepoRoot.source(studio).contains("onStrokeBegan: { beginStroke() },"))
        for perCell in ["private func paintCell(x: Int, y: Int) {", "private func setCell(x: Int, y: Int) {"] {
            let cell = try body(of: perCell, in: studio)
            #expect(!cell.contains("FernletFeedback"), "\(perCell) plays a cue")
        }
        let canvas = try RepoRoot.source("App/Fernlet/ZoomablePixelCanvas.swift")
        #expect(!canvas.contains("FernletFeedback.") && !canvas.contains("fernletFeedback("))
    }
}
