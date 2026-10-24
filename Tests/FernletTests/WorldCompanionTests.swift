import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// The companion on the World map (World app plan step 3): the approved pixel art, what it wears, and
/// that it is Home's companion in every way that matters (pacing, cue, lines, VoiceOver).
@MainActor
struct WorldCompanionTests {

    /// Each band draws in its own colour, with the design's mouth, and stays inside the 20 × 22 grid.
    @Test func eachBandDrawsItsFaceInItsColour() {
        for state in [CompanionState.thriving, .okay, .tired, .resting, .sick] {
            let look = WorldCompanionLook(body: WorldCompanionLook.stateHex(state))
            let grid = WorldCompanionPainter.paint(state: state, look: look, pose: WorldCompanionPose())
            #expect(grid.cells.count == WorldCompanionGrid.width * WorldCompanionGrid.height)
            #expect(grid.cells.contains(WorldCompanionLook.stateHex(state)), "\(state) lost its body colour")
            #expect(grid.cells.contains(WorldCompanionPainter.ink), "\(state) has no face")
        }
        #expect(WorldCompanionPainter.mouth(for: .thriving).count == 4)
        #expect(WorldCompanionPainter.mouth(for: .okay).count == 2)
    }

    /// Resting, sick and asleep close the eyes; the others keep them open.
    @Test func lowDaysAndSleepCloseTheEyes() {
        #expect(WorldCompanionPainter.closesEyes(state: .resting, pose: WorldCompanionPose()))
        #expect(WorldCompanionPainter.closesEyes(state: .sick, pose: WorldCompanionPose()))
        #expect(WorldCompanionPainter.closesEyes(state: .thriving, pose: WorldCompanionPose(asleep: true)))
        #expect(!WorldCompanionPainter.closesEyes(state: .okay, pose: WorldCompanionPose()))
    }

    /// The breath changes the frame (two crisp frames, not a scale), and the settled pose has its own.
    @Test func theBreathAndTheSettledPoseAreTheirOwnFrames() {
        let look = WorldCompanionLook(body: 0x5E844D)
        let rest = WorldCompanionPainter.paint(state: .thriving, look: look, pose: WorldCompanionPose())
        let breath = WorldCompanionPainter.paint(state: .thriving, look: look, pose: WorldCompanionPose(breathIn: true))
        let settled = WorldCompanionPainter.paint(state: .thriving, look: look, pose: WorldCompanionPose(settled: true))
        #expect(rest != breath)
        #expect(rest != settled)
    }

    /// Only the wardrobe with approved pixel art is drawn: the sprout, the glasses and the scarf. The
    /// flower and the sleep cap leave the head bare rather than drawing something unapproved.
    @Test func theLookDrawsOnlyTheApprovedWardrobe() {
        var appearance = CompanionAppearance()
        #expect(WorldCompanionLook(appearance: appearance, state: .okay, asleep: false).topper == .sprout)
        appearance.accessory = .glasses
        #expect(WorldCompanionLook(appearance: appearance, state: .okay, asleep: false).topper == .glasses)
        appearance.accessory = .flower
        appearance.clothing = .sleepCap
        let bare = WorldCompanionLook(appearance: appearance, state: .okay, asleep: false)
        #expect(bare.topper == .none && bare.scarf == nil)
        appearance.clothing = .scarf
        #expect(WorldCompanionLook(appearance: appearance, state: .okay, asleep: false).scarf != nil)
    }

    /// The body follows the band by default, wears the night colour asleep, and keeps a fixed colour.
    @Test func theBodyColourFollowsTheBandUnlessTheyPickedOne() {
        let standard = CompanionAppearance()
        #expect(WorldCompanionLook(appearance: standard, state: .tired, asleep: false).body == WorldCompanionLook.stateHex(.tired))
        #expect(WorldCompanionLook(appearance: standard, state: .tired, asleep: true).body == WorldCompanionLook.nightBody)
        var custom = CompanionAppearance()
        custom.bodyCustomColorHex = "#123456"
        #expect(WorldCompanionLook(appearance: custom, state: .tired, asleep: true).body == 0x123456)
    }

    /// The map's pet is Home's pet: the governor answers, its cue plays and nothing else does, and the
    /// first pat begins Pats Given. (Pinned by source: the handler is a private view method.) Since the
    /// close-up (refinement `ref-comp-react`) the governor and the re-tally sit in the one shared path,
    /// `WorldCompanionPet`, which both the map and the close-up call.
    @Test func theMapsPetIsHomesPet() throws {
        let source = try RepoRoot.source("App/Fernlet/World/Home/WorldMapCompanion.swift")
        let pet = try #require(source.range(of: "private func pet() {")).upperBound
        let body = String(source[pet...].prefix(900))
        #expect(body.contains("WorldCompanionPet.register(governor: petGovernor, store: store)"))
        #expect(body.contains("if let cue = HomeView.petFeedbackEvent(for: response) { FernletFeedback.system.play(cue) }"))
        #expect(body.components(separatedBy: "FernletFeedback").count == 2, "a second cue in the map's pet handler")
        let shared = try RepoRoot.source("App/Fernlet/World/Companion/WorldCompanionCloseUp.swift")
        let register = try #require(shared.range(of: "static func register(")).upperBound
        let path = String(shared[register...].prefix(500))
        #expect(path.contains("governor.registerPet()"))
        #expect(path.contains("store.sillyStats.scheduleRetally(store: store)"))
    }

    /// Home and the map say the same thing: Home's line is the store's.
    @Test func homeAndTheMapShareTheAmbientLine() throws {
        let home = try RepoRoot.source("App/Fernlet/HomeView.swift")
        #expect(home.contains("store.companionAmbientThought(addressing: termOfAddress)"))
        let map = try RepoRoot.source("App/Fernlet/World/Home/WorldMapCompanion.swift")
        #expect(map.contains("store.companionAmbientThought(addressing: termOfAddress)"))
    }

    /// Every stamp has its own approved art (`b2-stamp-art`): nineteen distinct sprites, each a rectangle
    /// whose keys all have colours.
    @Test func everyStampHasItsOwnArt() {
        let sprites = SillyStatKind.allCases.map(WorldStampArt.sprite(for:))
        #expect(Set(sprites.map(\.rows)).count == SillyStatKind.allCases.count, "two stamps share art")
        for sprite in sprites {
            #expect(sprite.rows.allSatisfy { $0.count == sprite.width })
            #expect(Set(sprite.rows.joined()).subtracting(["."]).isSubset(of: Set(sprite.palette.keys)))
        }
    }

    /// The four prints keep the approved two-over-two layout inside the strip.
    @Test func thePrintsAreTwoOverTwo() {
        #expect(WorldPhotoPrints.layout.count == 4)
        #expect(WorldPhotoPrints.layout.allSatisfy { $0.x + 72 <= WorldPhotoPrints.size.width + 4 })
        #expect(WorldPhotoPrints.layout.allSatisfy { $0.y + 81 <= WorldPhotoPrints.size.height + 4 })
    }
}
