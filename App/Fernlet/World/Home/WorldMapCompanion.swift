import SwiftUI
import UIKit
import FernletDomainModel
import FernletScoring
import FernletUI

/// The companion on the World map (design `b1-home-day`, draft 3; World app plan step 3): the pixel
/// sprite standing where the person is, its speech bubble above it, tap to see it up close
/// (``WorldCompanionCloseUp``, refinement `ref-comp-close`, where a tap pets it) and hold to customize.
/// VoiceOver's "Pet" action still pets it here.
///
/// **One companion, two drawings.** Everything it does is Home's: the same `PetInteractionGovernor`
/// (its pacing lives in device-local defaults, so pets here and on Today count together), the same
/// cue for each answer (`HomeView.petFeedbackEvent`, nothing while settled), the same silly-stats
/// re-tally, the same tap lines (`HomeCopy`) and the same ambient line
/// (`FernletStore.companionAmbientThought`). Only the drawing differs: a hop and a rising pixel heart
/// instead of Home's squash, both held still under Reduce Motion.
///
/// **Accessibility** is Home's companion's: one button named "Fernlet companion", the band and feeling
/// as its value, the line as custom content (the bubble itself is decoration and fades), the default
/// action opens it up close, "Pet" pets it in place and "Edit your companion" opens the customize sheet
/// (a VoiceOver user cannot make the long press).
struct WorldMapCompanion: View {
    var store: FernletStore
    /// The opt-in body-signal reading, already gated on the setting (Home's `companionBodySignal`).
    var bodySignal: CompanionBodySignal?
    /// Whether the map is on screen; off, the breath and the emotion clock stop.
    var isActive: Bool
    /// The map's own line when it has one (``WorldMapLine``): a friend arriving, the weather, an unwell
    /// day, where the map is. Nil keeps the companion's usual line.
    var mapLine: String? = nil
    /// Points per sprite pixel; nil takes the theme's.
    var pixelScale: CGFloat? = nil
    /// Whether the bubble stays down: the quick-start card is open over the map (`b1-qs-*` draw the
    /// companion without one), so the two never overlap.
    var isQuiet = false
    /// The map's night (`b1-home-night`; the DEBUG night override too): the companion winds down, its
    /// eyes closing, before its own bedtime makes it sleepy and then asleep.
    var isNight = false
    /// Whether the one-time "Tap me to say hi!" hint is showing (``WorldCompanionHint``, `ref-hint`).
    var hint = false
    /// Whether the person is driving: the companion rides along in its small red car (``WorldRideCar``,
    /// `b1-home-car`, round 7).
    var isRiding = false
    /// The hint ended: the first tap, or its 12 seconds on Home.
    var onHintEnded: () -> Void = {}
    let onCustomize: () -> Void
    @State private var petGovernor = PetInteractionGovernor()
    @State private var playfulUntil: Date?
    @State private var tapCount = 0
    @State private var tapThought: String?
    @State private var isThoughtVisible = false
    @State private var isSettled = false
    @State private var hopLift: CGFloat = 0
    @State private var settledResync: Task<Void, Never>?
    /// Whether the companion is open up close (``WorldCompanionCloseUp``).
    @State private var isCloseUpOpen = false
    @Environment(\.fernletTermOfAddress) private var termOfAddress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            figure(now: now(at: context.date))
        }
        .task(id: LineKey(isActive: isActive, line: mapLine)) { await sayAmbientLine() }
        .task(id: HintKey(hint: hint, isActive: isActive)) { await endHintWhenDue() }
    }

    /// What restarts the hint's 12 seconds: the hint starting, or Home coming back to the front.
    private struct HintKey: Equatable {
        let hint: Bool
        let isActive: Bool
    }

    /// Ends the hint after its 12 seconds on Home; with VoiceOver on it waits for the first activation.
    private func endHintWhenDue() async {
        guard hint, isActive, !UIAccessibility.isVoiceOverRunning else { return }
        do {
            try await Task.sleep(for: WorldCompanionHint.duration)
        } catch {
            return
        }
        onHintEnded()
    }

    /// A tap or VoiceOver's activation: ends the hint, then opens the companion up close.
    private func activate() {
        if hint { onHintEnded() }
        openCloseUp()
    }

    /// The bubble over the sprite, and the sprite with its pet heart.
    private func figure(now: WorldCompanionNow) -> some View {
        VStack(spacing: 12) {
            WorldSpeechBubble(text: thought)
                .opacity((isThoughtVisible || hint) && !isQuiet ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: hint)
                .offset(x: 8)
                .accessibilityHidden(true)
            ZStack {
                if hint { WorldHintRing() }
                WorldCompanionSprite(now: now, settled: isSettled, isActive: isActive,
                                     pixelScale: isRiding ? WorldRideCar.riderScale : pixelScale)
                    .modifier(WorldRideCar(isRiding: isRiding))
                    .offset(y: hopLift)
                if tapCount > 0 { WorldPetHeart().id(tapCount) }
            }
            .contentShape(Rectangle())
            // Refinement 1 (`ref-comp-close`): a tap opens the companion up close, where it is petted.
            .onTapGesture { activate() }
            .onLongPressGesture(minimumDuration: 0.45) {
                FernletFeedback.system.play(.held)
                onCustomize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Fernlet companion")
            .accessibilityValue(CompanionEmotion.accessibilityValue(state: now.state, emotion: now.emotion))
            .accessibilityCustomContent("Thought", Text(verbatim: spokenThought))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { activate() }
            .accessibilityAction(named: "Pet") { pet() }
            .accessibilityAction(named: "Edit your companion") { onCustomize() }
            .accessibilityHint(Text(WorldCompanionHint.companionHint))
            .accessibilityIdentifier("world.companion")
        }
        // Up close it stands over the map itself; the small one would show through the veil.
        .opacity(isCloseUpOpen ? 0 : 1)
        .worldCompanionCloseUp(isPresented: $isCloseUpOpen, store: store, bodySignal: bodySignal, onCustomize: onCustomize)
        // DEBUG screenshots (`closeup`) open it at launch; the scene list is empty in release builds.
        .task { if UITestSupport.worldHomeScenes.contains("closeup") { openCloseUp() } }
    }

    /// Opens the close-up without the cover's slide; it fades in by itself.
    private func openCloseUp() {
        withTransaction(WorldCompanionCloseUpPresenter.instant) { isCloseUpOpen = true }
    }

    /// The line in the bubble: the hint while it shows, else the one a pet produced, else the map's own,
    /// else the companion's own.
    private var thought: String {
        if hint { return String(localized: WorldCompanionHint.line) }
        return tapThought ?? mapLine ?? store.companionAmbientThought(addressing: termOfAddress)
    }

    /// The bubble as VoiceOver reads it: "Double-tap Sprout to say hi" while the hint shows.
    private var spokenThought: String {
        guard hint else { return thought }
        let chosen = store.settings.companionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorldCompanionHint.spoken(name: chosen.isEmpty ? "Fernlet" : chosen)
    }

    /// What re-shows the bubble: the map coming to the front, or a new line of the map's own.
    private struct LineKey: Equatable {
        let isActive: Bool
        let line: String?
    }

    /// The companion at `date` as every World picture draws it (W-06a): the live state, the person's
    /// look with the pieces it wears, and the map's night (``WorldCompanionNight/map``), with the map's
    /// own body signal and pets.
    private func now(at date: Date) -> WorldCompanionNow {
        WorldCompanionLook.current(store: store, at: date, night: .map, bodySignal: bodySignal, playfulUntil: playfulUntil,
                                   mapNight: isNight)
    }

    /// Whether the companion is asleep at `date` (its feeling hides the day), for the Today panel's
    /// companion card, so the card and the map sleep together. Only the yes or no leaves this file.
    static func isAsleep(store: FernletStore, at date: Date) -> Bool {
        nightFeeling(store: store, at: date)?.hidesTheDay == true
    }

    /// Whether the companion's own bedtime has come at `date` (sleepy, or asleep after the wind-down),
    /// for the map's night line. Only the yes or no leaves this file.
    static func isPastBedtime(store: FernletStore, at date: Date) -> Bool {
        let feeling = nightFeeling(store: store, at: date)
        return feeling == .sleepy || feeling?.hidesTheDay == true
    }

    /// The feeling at `date` without the moment's touches (no body signal, no pet), as the night reads it.
    private static func nightFeeling(store: FernletStore, at date: Date) -> CompanionEmotion? {
        store.companionEmotion(at: date, bodySignal: nil, playfulUntil: nil,
                               appetiteCuesEnabled: CompanionEmotionPreferences.appetiteCuesEnabled(),
                               sleepWindow: CompanionEmotionPreferences.sleepWindow())
    }

    /// One pet, answered as Home answers it: the governor decides, its cue plays (nothing while
    /// settled), and the first pat ever begins Pats Given.
    private func pet() {
        playfulUntil = Date().addingTimeInterval(3 * 60)
        // The one pet path, shared with the close-up: pacing and Pats Given, nothing kept in a decoy.
        let response = WorldCompanionPet.register(governor: petGovernor, store: store)
        if let cue = HomeView.petFeedbackEvent(for: response) { FernletFeedback.system.play(cue) }
        tapCount += 1
        switch response {
        case .bounce:
            hop()
            say(tapCount.isMultiple(of: 3) ? HomeCopy.tapThoughts[tapCount % HomeCopy.tapThoughts.count] : nil)
        case .settling:
            hop()
            say(HomeCopy.settledThought)
        case .calmIdle(let showsSettledLine):
            say(showsSettledLine ? HomeCopy.settledAgainLine : nil)
        }
        syncSettled()
    }

    /// A short hop in whole points; none under Reduce Motion.
    private func hop() {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.14)) { hopLift = -12 }
        withAnimation(.easeIn(duration: 0.2).delay(0.14)) { hopLift = 0 }
    }

    /// Shows a pet's line for the notice window, as Home's tap thought does; nil says nothing new.
    private func say(_ line: String?) {
        guard let line else { return }
        let tapID = tapCount
        tapThought = line
        withAnimation(.easeInOut(duration: 0.22)) { isThoughtVisible = true }
        Task {
            do {
                try await Task.sleep(for: Self.noticeWindow(standard: .seconds(4)))
            } catch {
                return
            }
            guard tapCount == tapID else { return }
            withAnimation(.easeInOut(duration: 0.3)) { isThoughtVisible = false }
            tapThought = nil
        }
    }

    /// The companion's own line each time the map comes to the front, for Home's arrival window.
    private func sayAmbientLine() async {
        guard isActive else {
            isThoughtVisible = false
            return
        }
        withAnimation(.easeInOut(duration: 0.22)) { isThoughtVisible = true }
        // DEBUG screenshots (`hold`) keep the line up; the scene list is empty in release builds.
        guard !UITestSupport.worldHomeScenes.contains("hold") else { return }
        do {
            try await Task.sleep(for: Self.noticeWindow(standard: .seconds(6)))
        } catch {
            return
        }
        guard tapThought == nil else { return }
        withAnimation(.easeInOut(duration: 0.35)) { isThoughtVisible = false }
    }

    /// Mirrors the governor's settled window into the pose, and re-checks once when it ends.
    private func syncSettled() {
        let settled = petGovernor.isSettled
        withAnimation(.easeInOut(duration: 0.5)) { isSettled = settled }
        guard settled else { return }
        settledResync?.cancel()
        settledResync = Task {
            do {
                try await Task.sleep(for: .seconds(petGovernor.settleDuration))
            } catch {
                return
            }
            withAnimation(.easeInOut(duration: 0.5)) { isSettled = petGovernor.isSettled }
        }
    }

    /// A notice's time on screen: `standard`, or the longer assistive window.
    private static func noticeWindow(standard: Duration) -> Duration {
        FernletDismissalWindow.system.window(standard: standard, assistive: FernletDismissalWindow.assistiveNoticeWindow)
    }
}

/// A pixel heart that rises and fades from the companion; re-created (by id) on each pet. Under
/// Reduce Motion it does not appear at all.
private struct WorldPetHeart: View {
    @State private var rise = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WorldSpriteView(sprite: WorldSprites.heart, scale: 3)
            .offset(y: -36 - (rise ? 30 : 0))
            .opacity(rise || reduceMotion ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 1)) { rise = true } }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The companion's speech bubble (design language: paper, a 3-pt ink frame, a solid drop shadow and an
/// ink tail toward the companion). Crisp DM Sans that grows with text size up to the first
/// accessibility size, wrapping at the design's 236 pt.
struct WorldSpeechBubble: View {
    let text: String
    /// The bubble's type: the map's 14 pt; the close-up draws 17 (``WorldCompanionCloseUp``).
    var font: Font = WorldType.speech
    /// How wide it wraps: the map's 236 pt, the close-up's 300.
    var maxWidth: CGFloat = 236
    var alignment: TextAlignment = .leading
    /// The largest text size it grows to.
    var typeCap: DynamicTypeSize = .accessibility1

    var body: some View {
        Text(verbatim: text)
            .font(font)
            .dynamicTypeSize(...typeCap)
            .foregroundStyle(WorldPalette.bark)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
            .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
            .frame(maxWidth: maxWidth)
            .background(WorldPalette.paperLight, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(WorldPalette.ink, lineWidth: 3))
            .background {
                RoundedRectangle(cornerRadius: 4).fill(WorldPalette.ink.opacity(0.3)).offset(y: 3)
            }
            .overlay(alignment: .bottom) {
                WorldBubbleTail().fill(WorldPalette.ink).frame(width: 14, height: 9).offset(y: 9)
            }
    }
}

/// The bubble's tail: a downward triangle.
private struct WorldBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
