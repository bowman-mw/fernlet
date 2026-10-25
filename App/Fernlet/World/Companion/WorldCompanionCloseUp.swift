import FernletDomainModel
import FernletScoring
import FernletUI
import SwiftUI

/// The companion up close (World Review Refinements `ref-comp-close`, `ref-comp-react`, `ref-comp-dark`,
/// approved by the owner on 2026-10-24): tapping the companion on the map fills the view with it, at ten
/// points per pixel on a patch of grass over the softened map, with its name, state and feeling, its line,
/// and its hearts with any gold ones from friends.
///
/// Tap to pet: it squishes, blushes, sends up three pixel hearts and says "That tickles!", with a soft
/// haptic. Petting is a reaction only: it changes no score (``WorldCompanionPet``). Hold it, or the
/// Customize button, for Customize; ✕ top right goes back to the map. It breathes with a one-pixel bob
/// every two seconds and hops once on a thriving day; with Reduce Motion nothing moves and the hearts
/// fade in place.
///
/// Only data Home already shows: in a decoy session the store's companion is the decoy's, and petting
/// keeps nothing (no pacing or Pats Given written).
struct WorldCompanionCloseUp: View {
    var store: FernletStore
    /// The opt-in body-signal reading, as the map companion reads it.
    var bodySignal: CompanionBodySignal?
    let onClose: () -> Void
    let onCustomize: () -> Void
    @State private var governor = PetInteractionGovernor()
    @State private var reaction = WorldCloseUpReaction.none
    @State private var petCount = 0
    @State private var playfulUntil: Date?
    @State private var hopLift: CGFloat = 0
    @State private var isShown = false
    @Environment(\.fernletTermOfAddress) private var termOfAddress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = now(at: context.date)
            let emotion = now.emotion
            ZStack {
                WorldCloseUpVeil()
                VStack(spacing: 0) {
                    WorldCloseUpHeader(name: name, status: statusLine(emotion), onClose: onClose)
                    Spacer(minLength: 12)
                    WorldCloseUpBubble(text: reaction.line ?? store.companionAmbientThought(addressing: termOfAddress))
                    stage(now: now, date: context.date)
                    Spacer(minLength: 12)
                    WorldCloseUpFooter(status: WorldStatus.current(store: store, date: context.date), onCustomize: onCustomize)
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
        }
        .opacity(isShown ? 1 : 0)
        .onAppear(perform: arrive)
        .accessibilityAction(.escape) { onClose() }
    }

    /// The companion on its patch of grass, with the pet's hearts over it: the map's picture of it
    /// (W-06a), the same pixels at ten points each in the 240 × 240 pt item frame (W-07).
    private func stage(now: WorldCompanionNow, date: Date) -> some View {
        var pose = now.pose
        pose.settled = reaction.blushes
        return ZStack(alignment: .bottom) {
            WorldCloseUpGround()
            WorldCompanionCanvas(grid: WorldCompanionPainter.paint(state: now.state, look: now.look, pose: pose,
                                                                   increasedContrast: contrast == .increased),
                                 scale: WorldCloseUpMotion.pixelScale)
                .scaleEffect(x: reaction.squishes ? 1.08 : 1, y: reaction.squishes ? 0.9 : 1, anchor: .bottom)
                .offset(y: WorldCloseUpMotion.bobLift(at: date, reduceMotion: reduceMotion) + hopLift - 26)
                .overlay(alignment: .top) {
                    if reaction.hearts > 0 { WorldCloseUpHearts(count: reaction.hearts).id(petCount) }
                }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: pet)
        .onLongPressGesture(minimumDuration: 0.45) {
            FernletFeedback.system.play(.held)
            onCustomize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(Text(verbatim: spokenValue(emotion: now.emotion, date: date)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { pet() }
        .accessibilityAction(named: Text("Customize"), onCustomize)
        .accessibilityInputLabels([Text(WorldCloseUpCopy.petInputLabel(name: name))])
        .accessibilityIdentifier("world.closeUp.companion")
    }

    /// The companion's own name, or Fernlet (as the Today card names it).
    private var name: String {
        let chosen = store.settings.companionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return chosen.isEmpty ? "Fernlet" : chosen
    }

    /// "Thriving · feeling happy": the state, then the feeling; asleep says only that.
    private func statusLine(_ emotion: CompanionEmotion?) -> String {
        WorldCloseUpCopy.status(state: store.liveCompanionState, emotion: emotion)
    }

    /// What VoiceOver hears after the name: the state and feeling, then the care score as the plate says it.
    private func spokenValue(emotion: CompanionEmotion?, date: Date) -> String {
        let status = CompanionEmotion.accessibilityValue(state: store.liveCompanionState, emotion: emotion)
        return "\(status). \(WorldStatusPlate.spokenCare(WorldStatus.current(store: store, date: date)))"
    }

    /// The companion at `date` as the map draws it (W-06a), with the close-up's own pets.
    private func now(at date: Date) -> WorldCompanionNow {
        WorldCompanionLook.current(store: store, at: date, night: .map, bodySignal: bodySignal, playfulUntil: playfulUntil)
    }

    /// Fades in, and hops once on a thriving day.
    private func arrive() {
        withAnimation(.easeOut(duration: 0.25)) { isShown = true }
        guard WorldCloseUpMotion.hopsOnArrival(state: store.liveCompanionState, reduceMotion: reduceMotion) else { return }
        withAnimation(.easeOut(duration: 0.18).delay(0.25)) { hopLift = -WorldCloseUpMotion.hopHeight }
        withAnimation(.easeIn(duration: 0.22).delay(0.43)) { hopLift = 0 }
    }

    /// One pet: paced and cued as the map's pet, then the reaction for the governor's answer.
    private func pet() {
        playfulUntil = Date().addingTimeInterval(3 * 60)
        let response = WorldCompanionPet.register(governor: governor, store: store)
        if let cue = HomeView.petFeedbackEvent(for: response) { FernletFeedback.system.play(cue) }
        let next = WorldCloseUpReaction.make(for: response)
        petCount += 1
        let id = petCount
        withAnimation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.5)) { reaction = next }
        Task {
            do {
                try await Task.sleep(for: .seconds(WorldCloseUpMotion.reactionHold))
            } catch {
                return
            }
            guard petCount == id else { return }
            withAnimation(.easeOut(duration: 0.3)) { reaction = .none }
        }
    }
}

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

    /// The reaction for the governor's answer.
    static func make(for response: PetInteractionGovernor.Response) -> WorldCloseUpReaction {
        switch response {
        case .bounce:
            WorldCloseUpReaction(squishes: true, blushes: true, hearts: 3, line: WorldCloseUpCopy.tickles)
        case .settling:
            WorldCloseUpReaction(squishes: true, blushes: true, hearts: 3, line: HomeCopy.settledThought)
        case .calmIdle(let showsSettledLine):
            WorldCloseUpReaction(squishes: false, blushes: true, hearts: 0,
                                 line: showsSettledLine ? HomeCopy.settledAgainLine : nil)
        }
    }
}

/// The close-up's motion (`ref-comp-react`), as plain numbers the tests read.
nonisolated enum WorldCloseUpMotion {
    /// Points per sprite pixel up close: ten (the map draws three).
    static let pixelScale: CGFloat = 10
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

    /// The line under the hearts.
    static var hint: String {
        String(localized: "worldCloseUp.hint", defaultValue: "Tap to pet · hold for Customize",
               comment: "World companion up close: how to pet it and how to open Customize")
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
