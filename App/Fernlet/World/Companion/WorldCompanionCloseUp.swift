import FernletDomainModel
import FernletScoring
import FernletUI
import SwiftUI
import WorldMapStore

// What remains of the companion's close-up (`ref-comp-close`, `ref-comp-react`), retired in round 7 when
// tapping Sprout began opening its passport (World-Passport-Spec §1): the one pet path, the pet's reaction and
// motion, and their words, which page 1 of the passport (`PassportSproutPage`) uses.

/// One pet on the close-up, answered as the map answers it (``WorldMapCompanion``): the same
/// `PetInteractionGovernor` pacing and the silly stats' re-tally of Pats Given. It never touches the
/// care score, the day or the settings: petting is a reaction only. In a decoy session it keeps nothing
/// (no pacing state or Pats Given written to the device) and every pet is a playful one.
enum WorldCompanionPet {
    /// Registers one pet and returns the governor's answer.
    static func register(governor: PetInteractionGovernor, store: FernletStore) -> PetInteractionGovernor.Response {
        guard !store.duressSessionActive else { return .bounce }
        let response = governor.registerPet()
        store.sillyStats.scheduleRetally(store: store)
        return response
    }
}

/// How the close-up reacts to a pet (`ref-comp-react`): a playful pet squishes, blushes, sends up three
/// hearts and says "That tickles!"; the pet that settles it does the same with the settled line; a pet
/// while it is settled only blushes, with the soft settled line once.
struct WorldCloseUpReaction: Equatable {
    var squishes: Bool
    var blushes: Bool
    var hearts: Int
    var line: String?

    /// No reaction showing.
    static let none = WorldCloseUpReaction(squishes: false, blushes: false, hearts: 0, line: nil)

    /// The reaction for the governor's answer; `name` is the companion's, for the settled lines.
    static func make(for response: PetInteractionGovernor.Response, name: String) -> WorldCloseUpReaction {
        switch response {
        case .bounce:
            WorldCloseUpReaction(squishes: true, blushes: true, hearts: 3, line: WorldCloseUpCopy.tickles)
        case .settling:
            WorldCloseUpReaction(squishes: true, blushes: true, hearts: 3, line: HomeCopy.settledThought(name: name))
        case .calmIdle(let showsSettledLine):
            WorldCloseUpReaction(squishes: false, blushes: true, hearts: 0,
                                 line: showsSettledLine ? HomeCopy.settledAgainLine(name: name) : nil)
        }
    }
}

/// The close-up's motion (`ref-comp-react`), as plain numbers the tests read.
nonisolated enum WorldCloseUpMotion {
    /// Points per sprite pixel up close: ten (the map draws three).
    static let pixelScale: CGFloat = 10
    /// How far the 240 × 240 pt frame stands above the grass's bottom edge, so the feet rest on the
    /// grass (the body's old 26 pt, less the frame's empty last row).
    static let standLift: CGFloat = 26 - pixelScale
    /// The idle bob's period: up one pixel for a second, down for the next.
    static let bobPeriod: TimeInterval = 2
    /// The happy hop's height on a thriving day: two pixels.
    static let hopHeight: CGFloat = 2 * pixelScale
    /// How long a pet's reaction stays before the companion settles back.
    static let reactionHold: TimeInterval = 1.6
    /// How long the pet's hearts take to rise and fade (or, with Reduce Motion, to fade in place).
    static let heartsDuration: TimeInterval = 1.1

    /// The idle bob's lift at `date`: one pixel up in the second half of each period; none with
    /// Reduce Motion.
    static func bobLift(at date: Date, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 0 }
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: bobPeriod)
        return phase >= bobPeriod / 2 ? -pixelScale : 0
    }

    /// Whether it hops once when the close-up opens: on a thriving day, never with Reduce Motion.
    static func hopsOnArrival(state: CompanionState, reduceMotion: Bool) -> Bool {
        state == .thriving && !reduceMotion
    }

    /// How far the pet's hearts rise: 40 pt, or not at all with Reduce Motion (they fade in place).
    static func heartsRise(reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 0 : 40
    }
}

/// The close-up's words: resolved here, so the views and the tests read one copy.
enum WorldCloseUpCopy {
    /// What a playful pet says.
    static var tickles: String {
        String(localized: "worldCloseUp.tickles", defaultValue: "That tickles!",
               comment: "World companion up close: what the companion says when petted (Spanish: ¡Me haces cosquillas!)")
    }

    /// "Thriving · feeling happy": the state and the feeling; asleep says only that, as VoiceOver does.
    static func status(state: CompanionState, emotion: CompanionEmotion?) -> String {
        guard let emotion else { return state.displayName }
        guard !emotion.hidesTheDay else { return emotion.displayName }
        return String(localized: "worldCloseUp.status", defaultValue: "\(state.displayName) · \(emotion.feelingPhrase)",
                      comment: "World companion up close, under its name: its state, then its feeling. Example: 'Thriving · feeling happy'")
    }

    /// What Voice Control can say to pet it: "Pet Sprout".
    static func petInputLabel(name: String) -> String {
        String(localized: "worldCloseUp.petInput", defaultValue: "Pet \(name)",
               comment: "World companion up close: the Voice Control name for petting it; the companion's name follows 'Pet'")
    }
}
