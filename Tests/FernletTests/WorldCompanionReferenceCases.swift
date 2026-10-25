import Foundation
import FernletDomainModel
@testable import Fernlet

/// The reference cases' inputs, one for one with the design session's dump of its reference painter
/// (the cases that drew `Docs/World-Companion-Reference-Grids.txt`).
extension WorldCompanionWardrobeTests {
    static let moss: UInt32 = 0x5E844D, rose: UInt32 = 0xB67073, sun: UInt32 = 0xEBB551, slate: UInt32 = 0x71808C
    static let clay: UInt32 = 0xB8543D, cream: UInt32 = 0xF3E6CB, bark: UInt32 = 0x3A2414, night: UInt32 = 0xB8A892

    static let wizard = art(1, -1, ["..........kk......", ".........kpk......", "........kppk......", ".......kpppk......",
                                    "......kppspk......", ".....kpppppk......", "....kppsppppk.....", "...kpppppppppk....",
                                    ".kkkkkkkkkkkkkkkk.", "kbbbbbbbbbbbbbbbbk", ".................."],
                            ["k": 0x2A1A10, "p": 0x6B5BA8, "s": 0xEBB551, "b": 0x4E4285], hat: true)
    static let balloon = art(12, 10, ["......rrr.", ".....rrrrr", ".....rlrrr", ".....rrrrr", "......rrr.", ".......k..",
                                      "......k...", ".....k....", "....k.....", "...k......", "..........", ".........."],
                             ["r": 0xD9532F, "l": 0xF2A48F, "k": 0x2A1A10])
    static let beanie = art(3, 1, ["......ww......", ".....wwww.....", "....hhhhhh....", "...hhhhhhhh...", "..hhhhhhhhhh..",
                                   "..rrrrrrrrrr..", "...rrrrrrrr..."],
                            ["w": 0xF3E6CB, "h": clay, "r": WorldCompanionPainter.mix(clay, 0x1E1008, 0.3)], hat: true)
    static let mask = art(2, 9, ["................", "..kkkkk..kkkkk..", "..kwwwkkkkwwwk..", "..kkkkk..kkkkk.."],
                          ["k": 0x3C5A6B, "w": 0xFFFFFF])
    static let shirt = art(1, 10, ["..................", "..................", "..................", "..................",
                                   "..................", "....ssssssssss....", "...ssssssssssss...", "...ssttssssttss...",
                                   "...ssssssssssss...", "....ssssssssss...."], ["s": 0x8C6FB0, "t": 0xFFFFFF])

    /// The plain companion in its band's colour.
    nonisolated static func plain(_ state: CompanionState, _ shape: WorldCompanionShape = .circle) -> WorldCompanionLook {
        WorldCompanionLook(body: hexOf(state), shape: shape)
    }

    nonisolated static func hexOf(_ state: CompanionState) -> UInt32 { WorldCompanionLook.stateHex(state) }

    static let cases: [String: Case] = {
        var all: [String: Case] = [:]
        for state in [CompanionState.thriving, .okay, .tired, .resting, .sick] {
            all["circle-\(state.rawValue.lowercased())"] = Case(state: state, look: plain(state))
        }
        all["circle-breath"] = Case(state: .okay, look: plain(.okay), pose: WorldCompanionPose(breathIn: true))
        all["circle-settled"] = Case(state: .thriving, look: plain(.thriving), pose: WorldCompanionPose(settled: true))
        all["circle-settled-tired"] = Case(state: .tired, look: plain(.tired), pose: WorldCompanionPose(settled: true))
        all["circle-asleep"] = Case(state: .thriving, look: WorldCompanionLook(body: night), pose: WorldCompanionPose(asleep: true))
        all["circle-drowsy"] = Case(state: .okay, look: plain(.okay), pose: WorldCompanionPose(drowsy: true))
        all["soft-thriving"] = Case(state: .thriving, look: plain(.thriving, .soft))
        all["pear-thriving"] = Case(state: .thriving, look: plain(.thriving, .pear))
        all["puddle-thriving"] = Case(state: .thriving, look: plain(.thriving, .puddle))
        all["soft-resting"] = Case(state: .resting, look: plain(.resting, .soft))
        all["pear-sick"] = Case(state: .sick, look: plain(.sick, .pear))
        all["puddle-resting"] = Case(state: .resting, look: plain(.resting, .puddle))
        all["pear-breath"] = Case(state: .okay, look: plain(.okay, .pear), pose: WorldCompanionPose(breathIn: true))
        all["soft-settled"] = Case(state: .thriving, look: plain(.thriving, .soft), pose: WorldCompanionPose(settled: true))
        all["puddle-asleep"] = Case(state: .tired, look: WorldCompanionLook(body: night, shape: .puddle), pose: WorldCompanionPose(asleep: true))
        for group in [toppers, clothes, sides, frames] {
            all.merge(group) { first, _ in first }
        }
        return all
    }()

    static let toppers: [String: Case] = {
        func look(_ state: CompanionState, _ topper: WorldCompanionTopper, _ colour: UInt32? = nil,
                  shape: WorldCompanionShape = .circle, body: UInt32? = nil) -> WorldCompanionLook {
            WorldCompanionLook(body: body ?? hexOf(state), shape: shape, topper: topper, topperColor: colour)
        }
        return [
            "sprout-rose": Case(state: .okay, look: look(.okay, .sprout, rose)),
            "bare": Case(state: .okay, look: look(.okay, .none)),
            "flower-default": Case(state: .thriving, look: look(.thriving, .flower)),
            "flower-sun": Case(state: .okay, look: look(.okay, .flower, sun)),
            "flower-asleep": Case(state: .thriving, look: look(.thriving, .flower, body: night), pose: WorldCompanionPose(asleep: true)),
            "flower-puddle": Case(state: .thriving, look: look(.thriving, .flower, rose, shape: .puddle)),
            "glasses-fern": Case(state: .thriving, look: look(.thriving, .glasses)),
            "glasses-rose": Case(state: .thriving, look: look(.thriving, .glasses, rose)),
            "glasses-slate": Case(state: .okay, look: look(.okay, .glasses, slate)),
            "glasses-sun": Case(state: .thriving, look: look(.thriving, .glasses, sun)),
            "glasses-cream": Case(state: .okay, look: look(.okay, .glasses, cream)),
            "glasses-resting": Case(state: .resting, look: look(.resting, .glasses, rose)),
            "glasses-pear": Case(state: .tired, look: look(.tired, .glasses, moss, shape: .pear)),
        ]
    }()

    static let clothes: [String: Case] = {
        let blue = WorldCompanionLook.capBlue, red = WorldCompanionLook.scarfRed
        return [
            "cap-mood": Case(state: .thriving, look: WorldCompanionLook(body: hexOf(.thriving), cap: blue)),
            "cap-slate-asleep": Case(state: .okay, look: WorldCompanionLook(body: night, topper: .flower, cap: slate),
                                     pose: WorldCompanionPose(asleep: true)),
            "cap-glasses": Case(state: .okay, look: WorldCompanionLook(body: hexOf(.okay), topper: .glasses, topperColor: slate, cap: rose)),
            "cap-puddle": Case(state: .thriving, look: WorldCompanionLook(body: hexOf(.thriving), shape: .puddle, cap: clay)),
            "cap-soft-resting": Case(state: .resting, look: WorldCompanionLook(body: hexOf(.resting), shape: .soft, cap: bark)),
            "scarf-default": Case(state: .okay, look: WorldCompanionLook(body: hexOf(.okay), scarf: red)),
            "scarf-pear": Case(state: .thriving, look: WorldCompanionLook(body: hexOf(.thriving), shape: .pear, scarf: moss)),
        ]
    }()

    static let sides: [String: Case] = {
        func look(_ state: CompanionState, _ side: WorldCompanionSide, _ colour: UInt32, shape: WorldCompanionShape = .circle,
                  body: UInt32? = nil) -> WorldCompanionLook {
            WorldCompanionLook(body: body ?? hexOf(state), shape: shape, side: side, sideColor: colour)
        }
        let dressed = WorldCompanionLook(body: hexOf(.thriving), shape: .pear, topper: .flower, scarf: WorldCompanionLook.scarfRed,
                                         side: .mug, sideColor: clay)
        return [
            "bottle": Case(state: .thriving, look: look(.thriving, .bottle, slate)),
            "mug-awake": Case(state: .thriving, look: look(.thriving, .mug, clay)),
            "mug-asleep": Case(state: .thriving, look: look(.thriving, .mug, clay, body: night), pose: WorldCompanionPose(asleep: true)),
            "mug-drowsy": Case(state: .okay, look: look(.okay, .mug, clay), pose: WorldCompanionPose(drowsy: true)),
            "book": Case(state: .tired, look: look(.tired, .book, moss)),
            "dumbbell": Case(state: .okay, look: look(.okay, .dumbbell, bark)),
            "side-resting": Case(state: .resting, look: look(.resting, .bottle, rose)),
            "side-puddle": Case(state: .thriving, look: look(.thriving, .book, sun, shape: .puddle)),
            "dressed": Case(state: .thriving, look: dressed),
            "dressed-hc": Case(state: .thriving, look: dressed, increasedContrast: true),
            "hc-plain": Case(state: .tired, look: plain(.tired), increasedContrast: true),
            "hc-sick-puddle": Case(state: .sick, look: plain(.sick, .puddle), increasedContrast: true),
        ]
    }()

    static let frames: [String: Case] = {
        let everything = WorldCompanionLook(body: hexOf(.thriving), shape: .soft, topper: .flower, scarf: WorldCompanionLook.scarfRed,
                                            side: .mug, sideColor: slate, items: [shirt, balloon, mask, wizard])
        return [
            "frame-plain": Case(state: .thriving, look: plain(.thriving)),
            "frame-puddle-cap": Case(state: .sick, look: WorldCompanionLook(body: hexOf(.sick), shape: .puddle, cap: WorldCompanionLook.capBlue)),
            "frame-wizard": Case(state: .thriving, look: WorldCompanionLook(body: hexOf(.thriving), items: [wizard])),
            "frame-balloon": Case(state: .thriving, look: WorldCompanionLook(body: hexOf(.thriving), items: [balloon])),
            "frame-beanie-flower": Case(state: .okay, look: WorldCompanionLook(body: hexOf(.okay), topper: .flower, items: [beanie])),
            "frame-mask-glasses": Case(state: .thriving, look: WorldCompanionLook(body: hexOf(.thriving), topper: .glasses,
                                                                                    topperColor: rose, items: [mask])),
            "frame-shirt-scarf": Case(state: .okay, look: WorldCompanionLook(body: hexOf(.okay), scarf: WorldCompanionLook.scarfRed,
                                                                               items: [shirt])),
            "frame-all": Case(state: .thriving, look: everything, increasedContrast: true),
            "frame-held-mug": Case(state: .okay, look: WorldCompanionLook(body: hexOf(.okay), side: .mug, sideColor: clay, items: [balloon])),
        ]
    }()
}
