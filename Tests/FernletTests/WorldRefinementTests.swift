import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// The owner's refinements 1, 4 and 6 (World Review Refinements, approved 2026-10-24): the companion up
/// close (a pet that changes no score, its motion and Reduce Motion), the Today tab on the status plate,
/// and the blue button's label (every time the action changes, its timing, its words).
@MainActor
struct WorldRefinementTests {

    // MARK: 1 · The companion up close

    /// A fresh governor in its own defaults, so the test never touches the device's real pacing.
    private func governor() -> (PetInteractionGovernor, UserDefaults) {
        let defaults = UserDefaults(suiteName: "WorldRefinementTests.\(UUID().uuidString)") ?? .standard
        return (PetInteractionGovernor(defaults: defaults), defaults)
    }

    /// Petting up close is a reaction only: the care score, the day and the settings stay as they were,
    /// while the governor still paces it (four playful pets, then the one that settles it).
    @Test func aPetChangesNoScore() throws {
        let store = makeTestStore()
        let (governor, defaults) = governor()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let score = store.score
        let day = try encoder.encode(store.day)
        let settings = try encoder.encode(store.settings)
        let status = WorldStatus.current(store: store)
        var responses: [PetInteractionGovernor.Response] = []
        for _ in 0..<5 { responses.append(WorldCompanionPet.register(governor: governor, store: store)) }
        #expect(store.score == score)
        #expect(try encoder.encode(store.day) == day)
        #expect(try encoder.encode(store.settings) == settings)
        #expect(WorldStatus.current(store: store).carePercent == status.carePercent)
        #expect(responses.prefix(4).allSatisfy { $0 == .bounce })
        #expect(responses.last == .settling, "the close-up keeps the governor's pacing")
        #expect(PetInteractionGovernor.lifetimePats(in: defaults) == 5)
    }

    /// In a decoy session a pet keeps nothing on the device: no pacing and no Pats Given.
    @Test func aDecoyPetKeepsNothing() {
        let store = makeTestStore()
        store.duressSessionActive = true
        defer { store.duressSessionActive = false }
        let (governor, defaults) = governor()
        for _ in 0..<6 { #expect(WorldCompanionPet.register(governor: governor, store: store) == .bounce) }
        #expect(PetInteractionGovernor.lifetimePats(in: defaults) == 0)
        #expect(!governor.isSettled)
    }

    /// A playful pet squishes, blushes, sends up three hearts and says "That tickles!"; a settled one
    /// only blushes, saying the soft line once.
    @Test func eachAnswerHasItsReaction() {
        let playful = WorldCloseUpReaction.make(for: .bounce, name: "Sprout")
        #expect(playful.squishes && playful.blushes && playful.hearts == 3)
        #expect(playful.line == WorldCloseUpCopy.tickles)
        #expect(WorldCloseUpCopy.tickles == "That tickles!")
        let settling = WorldCloseUpReaction.make(for: .settling, name: "Sprout")
        #expect(settling.squishes && settling.hearts == 3 && settling.line == HomeCopy.settledThought(name: "Sprout"))
        #expect(HomeCopy.settledThought(name: "Pip").hasPrefix("Pip "), "the settled line names the companion")
        let calm = WorldCloseUpReaction.make(for: .calmIdle(showsSettledLine: false), name: "Sprout")
        #expect(!calm.squishes && calm.blushes && calm.hearts == 0 && calm.line == nil)
        #expect(WorldCloseUpReaction.make(for: .calmIdle(showsSettledLine: true), name: "Sprout").line
                == HomeCopy.settledAgainLine(name: "Sprout"))
    }

    /// The idle bob is one pixel (ten points up close) for one second in every two; Reduce Motion
    /// holds it still, never hops and lets the hearts fade in place.
    @Test func theMotionAndReduceMotion() {
        #expect(WorldCloseUpMotion.pixelScale == 10)
        #expect(WorldCloseUpMotion.bobPeriod == 2)
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(WorldCloseUpMotion.bobLift(at: base, reduceMotion: false) == 0)
        #expect(WorldCloseUpMotion.bobLift(at: base.addingTimeInterval(1.2), reduceMotion: false) == -10)
        #expect(WorldCloseUpMotion.bobLift(at: base.addingTimeInterval(2.1), reduceMotion: false) == 0)
        #expect(WorldCloseUpMotion.bobLift(at: base.addingTimeInterval(1.2), reduceMotion: true) == 0)
        #expect(WorldCloseUpMotion.hopsOnArrival(state: .thriving, reduceMotion: false))
        #expect(!WorldCloseUpMotion.hopsOnArrival(state: .thriving, reduceMotion: true))
        #expect(!WorldCloseUpMotion.hopsOnArrival(state: .okay, reduceMotion: false))
        #expect(WorldCloseUpMotion.heartsRise(reduceMotion: false) > 0)
        #expect(WorldCloseUpMotion.heartsRise(reduceMotion: true) == 0)
    }

    /// Under the name: the state and the feeling; asleep says only that it is asleep.
    @Test func theStatusLineSaysStateAndFeeling() {
        #expect(WorldCloseUpCopy.status(state: .thriving, emotion: .happy) == "Thriving · feeling happy")
        #expect(WorldCloseUpCopy.status(state: .okay, emotion: nil) == CompanionState.okay.displayName)
        #expect(WorldCloseUpCopy.status(state: .thriving, emotion: .asleep) == CompanionEmotion.asleep.displayName)
        #expect(WorldCloseUpCopy.petInputLabel(name: "Sprout") == "Pet Sprout")
    }

    // MARK: 4 · The Today tab

    /// "Today ›" in DM Sans bold 13.5 pt, 17 pt at the largest text sizes.
    @Test func theTodayTabGrowsToSeventeenPoints() {
        #expect(WorldTodayTab.pointSize(accessibilitySize: false) == 13.5)
        #expect(WorldTodayTab.pointSize(accessibilitySize: true) == 17)
        #expect(String(localized: WorldTodayTab.title) == "Today")
    }

    // MARK: 6 · The blue button's label

    /// The first glyph is where the button starts, not a change; a change to a labelled action shows
    /// its word; a change to Walk together or the resting day tucks a showing word away.
    @Test func theLabelShowsOnlyWhenTheActionChanges() {
        let shown = steps([.camera, .camera, .walk, .space, .rest, .run, .trail, nil])
        #expect(shown == [.stay, .stay, .tuckAway, .show(.workout), .tuckAway, .show(.run), .tuckAway, .tuckAway])
    }

    /// Every time the action changes (owner's form answer 28, 2026-10-25): the same word shows again,
    /// with no daily limit.
    @Test func everyTimeTheActionChanges() {
        let shown = steps([.walk, .camera, .walk, .camera, .space, .camera])
        #expect(shown == [.stay, .show(.camera), .tuckAway, .show(.camera), .show(.workout), .show(.camera)],
                "the camera's word shows each time the button becomes the camera")
    }

    /// Runs one rule over a sequence of glyphs, returning what each did.
    private func steps(_ glyphs: [WorldQuickStartGlyph?]) -> [WorldQuickStartLabelStep] {
        var rule = WorldQuickStartLabelRule()
        return glyphs.map { rule.observe($0) }
    }

    /// It slides out in 0.3 s, stays 30 s (form answer 28) and slides back in 0.3 s; with Reduce Motion
    /// it fades in place.
    @Test func theLabelsTimingAndReduceMotion() {
        #expect(WorldQuickStartLabelRule.slideDuration == 0.3)
        #expect(WorldQuickStartLabelRule.holdDuration == 30)
        #expect(WorldQuickStartLabelRule.shrinkDuration == 0.3)
        #expect(WorldQuickStartLabelRule.transition(reduceMotion: false) == .slide)
        #expect(WorldQuickStartLabelRule.transition(reduceMotion: true) == .fade)
    }

    /// The words: Camera for a session or a hike, Workout at a space, Run on a saved route. The
    /// button's name always carries the action; VoiceOver hears "Quick start: Camera" each time.
    @Test func theWordsAndTheButtonsName() {
        #expect(WorldQuickStartLabel.label(for: .camera) == .camera)
        #expect(WorldQuickStartLabel.label(for: .space) == .workout)
        #expect(WorldQuickStartLabel.label(for: .run) == .run)
        // A saved walk's start (the tree) keeps the icon alone since step 5c gave runs their own glyph.
        #expect(WorldQuickStartLabel.label(for: .trail) == nil)
        #expect(WorldQuickStartLabel.label(for: .walk) == nil)
        #expect(WorldQuickStartLabel.label(for: .rest) == nil)
        #expect(WorldQuickStartLabel.buttonName(for: .camera) == "Quick start, Camera")
        #expect(WorldQuickStartLabel.buttonName(for: .space) == "Quick start, Workout")
        #expect(WorldQuickStartLabel.buttonName(for: .walk) == "Quick start")
        #expect(WorldQuickStartLabel.camera.announcement == "Quick start: Camera")
        #expect(WorldQuickStartLabel.run.announcement == "Quick start: Run")
    }
}
