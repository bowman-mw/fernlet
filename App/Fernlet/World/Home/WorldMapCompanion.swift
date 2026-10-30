import SwiftUI
import UIKit
import FernletDomainModel
import FernletScoring
import FernletUI

/// The companion on the World map (design `b1-home-day`, draft 3; World app plan step 3): the pixel
/// sprite standing where the person is, its speech bubble above it. A tap or a hold opens Sprout's passport on
/// page 1 (World-Passport-Spec §1, `ps-open`), the book rising from where Sprout stands; page 1's photo is where
/// Sprout is petted now. The close-up (`ref-comp-close`) and "hold for Customize" are retired: page 1 holds what
/// they did (`ps-parity`, ``PassportSproutParity``).
///
/// **One companion, many drawings.** The look is every World picture's (``WorldCompanionLook``), its line the
/// map's own when it has one, else the store's ambient line (`FernletStore.companionAmbientThought`), as Home's.
///
/// **Accessibility:** one button named with the companion's real name, its state and feeling as the value, the
/// line as custom content (the bubble itself is decoration and fades), and the hint "Opens Sprout's passport."
/// (§1: "Sprout, thriving. Opens Sprout's passport."). Voice Control: the name, or "Passport".
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
    /// What the companion rides along in, if anything: its small red car while the person drives
    /// (``WorldRideCar``, `b1-home-car`, round 7), its red bike on a bike ride (``WorldRideBike``,
    /// `ref-ride-home`, Refinements group 19), named as one image on the bike.
    var ride: WorldRideVehicle? = nil
    /// The hint ended: the first tap, or its 12 seconds on Home.
    var onHintEnded: () -> Void = {}
    /// Opens Sprout's passport, rising from the sprite's centre (global coordinates; nil: the screen's centre).
    let onOpenPassport: (CGPoint?) -> Void
    @State private var isThoughtVisible = false
    /// The sprite's centre on the screen, where the book rises from.
    @State private var spriteCentre: CGPoint?
    @Environment(\.fernletTermOfAddress) private var termOfAddress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            figure(now: now(at: context.date))
        }
        .task(id: LineKey(isActive: isActive, line: mapLine)) { await sayAmbientLine() }
        .task(id: HintKey(hint: hint, isActive: isActive)) { await endHintWhenDue() }
        // DEBUG `FERNLET_UI_TEST_HOME_HOOK=tap` sends Sprout's tap once the map settles; nothing in Release.
        .task { if await UITestSupport.homeHookTapsSprout() { activate() } }
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

    /// The companion's real name ("Sprout"; "Fernlet" when none is chosen).
    private var name: String { WorldRecenterCopy.companionName(store) }

    /// What VoiceOver calls the companion: its name; on its bike, one image with the bike ("Sprout, riding a
    /// bike", Refinements group 19).
    private var accessibilityName: Text {
        guard ride == .bike else { return Text(verbatim: name) }
        return Text(verbatim: WorldRideCopy.bikeRider(name: name))
    }

    /// A tap, a hold or VoiceOver's activation: ends the hint, then opens the passport from where Sprout stands.
    private func activate() {
        if hint { onHintEnded() }
        onOpenPassport(spriteCentre)
    }

    /// The bubble over the sprite, and the sprite.
    private func figure(now: WorldCompanionNow) -> some View {
        VStack(spacing: 12) {
            WorldSpeechBubble(text: thought)
                .opacity((isThoughtVisible || hint) && !isQuiet ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: hint)
                .offset(x: 8)
                .accessibilityHidden(true)
            ZStack {
                if hint { WorldHintRing() }
                WorldCompanionSprite(now: now, settled: false, isActive: isActive,
                                     pixelScale: ride?.riderScale ?? pixelScale)
                    .modifier(WorldRideCar(isRiding: ride == .car))
                    .modifier(WorldRideBike(isRiding: ride == .bike))
            }
            .contentShape(Rectangle())
            .onGeometryChange(for: CGPoint.self) { proxy in
                let frame = proxy.frame(in: .global)
                return CGPoint(x: frame.midX, y: frame.midY)
            } action: { spriteCentre = $0 }
            // World-Passport-Spec §1 (`ps-open`): a tap or a hold opens Sprout's passport.
            .onTapGesture { activate() }
            .onLongPressGesture(minimumDuration: 0.45) {
                FernletFeedback.system.play(.held)
                activate()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityName)
            .accessibilityValue(CompanionEmotion.accessibilityValue(state: now.state, emotion: now.emotion))
            .accessibilityCustomContent("Thought", Text(verbatim: spokenThought))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { activate() }
            .accessibilityHint(Text(WorldCompanionHint.opensPassport(name: name)))
            .accessibilityInputLabels([Text(verbatim: name), Text(PassportBookCopy.passport)])
            .accessibilityIdentifier("world.companion")
        }
    }

    /// The line in the bubble: the hint while it shows, else the map's own, else the companion's own.
    private var thought: String {
        if hint { return String(localized: WorldCompanionHint.line) }
        return mapLine ?? store.companionAmbientThought(addressing: termOfAddress)
    }

    /// The bubble as VoiceOver reads it: "Double-tap Sprout to say hi" while the hint shows.
    private var spokenThought: String {
        guard hint else { return thought }
        return WorldCompanionHint.spoken(name: name)
    }

    /// What re-shows the bubble: the map coming to the front, or a new line of the map's own.
    private struct LineKey: Equatable {
        let isActive: Bool
        let line: String?
    }

    /// The companion at `date` as every World picture draws it (W-06a): the live state, the person's
    /// look with the pieces it wears, and the map's night (``WorldCompanionNight/map``), with the map's
    /// own body signal.
    private func now(at date: Date) -> WorldCompanionNow {
        WorldCompanionLook.current(store: store, at: date, night: .map, bodySignal: bodySignal, playfulUntil: nil,
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
        withAnimation(.easeInOut(duration: 0.35)) { isThoughtVisible = false }
    }

    /// A notice's time on screen: `standard`, or the longer assistive window.
    private static func noticeWindow(standard: Duration) -> Duration {
        FernletDismissalWindow.system.window(standard: standard, assistive: FernletDismissalWindow.assistiveNoticeWindow)
    }
}

/// The companion's speech bubble (design language: paper, a 3-pt ink frame, a solid drop shadow and an
/// ink tail toward the companion). Crisp DM Sans that grows with text size up to the first
/// accessibility size, wrapping at the design's 236 pt.
struct WorldSpeechBubble: View {
    let text: String
    /// The bubble's type: the map's 14 pt, or another size a bigger picture asks for.
    var font: Font = WorldType.speech
    /// How wide it wraps: the map's 236 pt, or wider for a bigger picture.
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
