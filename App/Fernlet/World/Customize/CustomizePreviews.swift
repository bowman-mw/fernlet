import SwiftUI
import FernletDomainModel
import FernletScoring
import FernletUI

/// The two previews at the top of Customize, a slot and Save item (designs `b2-customize`,
/// `b2-slot-picker`, `b2-studio-save`): the companion close up, and as it stands on the map in a small
/// framed box. Both are the pixel companion wearing everything, Creation Studio pieces included, in
/// the 24 × 24 item frame (phone test W-06b, W-07), in the map's live state with a friend's gold heart
/// lifting it (W-06a).
///
/// Customize keeps the companion's bedtime (`comp-cust-night`): after it, both previews sleep as the
/// map does, unless the person holds "Hold to peek". Save item draws it awake, wearing the drawing.
/// Decorative unless `spokenName` says otherwise: the controls below carry the meaning.
struct CustomizePreviewCard: View {
    var store: FernletStore
    /// Pieces worn in the previews instead of the worn ones (the Studio's drawing, before it is saved).
    var previewItems: [CustomizationItem]? = nil
    /// What VoiceOver hears, where the previews are the page's only sign of the drawing (Save item);
    /// nil keeps them decorative.
    var spokenName: Text? = nil
    /// Which night the previews keep: Customize's bedtime, or awake (Save item, a held peek).
    var night = WorldCompanionNight.bedtime
    @Environment(\.colorSchemeContrast) private var contrast

    /// Points per pixel close up (the design's 5: 120 × 120 pt for the whole frame).
    static let closeScale: CGFloat = 5
    /// Points per pixel in the map's box: the map's own 3.
    static let mapScale: CGFloat = 3

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = WorldCompanionLook.current(store: store, at: context.date, night: night, items: previewItems)
            let grid = WorldCompanionPainter.paint(state: now.state, look: now.look, pose: now.pose,
                                                   increasedContrast: contrast == .increased)
            FernletCard {
                HStack(alignment: .bottom, spacing: 34) {
                    VStack(spacing: 6) {
                        WorldCompanionCanvas(grid: grid, scale: Self.closeScale, footprint: .frame)
                        caption(Text("Close up"))
                    }
                    VStack(spacing: 6) {
                        mapPreview(grid)
                        caption(Text("On the map"))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenName ?? Text(verbatim: ""))
        .accessibilityHidden(spokenName == nil)
    }

    /// The pixel companion in the map's framed grey box, at the map's three points a pixel.
    private func mapPreview(_ grid: WorldCompanionGrid) -> some View {
        WorldCompanionCanvas(grid: grid, scale: Self.mapScale, footprint: .frame)
            .frame(width: 86, height: 86)
            .background(WorldPalette.adaptive(light: 0xE7E2D4, dark: 0x2A2017), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldPalette.ink, lineWidth: 3))
    }

    private func caption(_ text: Text) -> some View {
        text
            .font(.fernlet(.bodySmall))
            .foregroundStyle(WorldPalette.dim)
    }
}

/// "Hold to peek" on Customize at night: held with a finger, or switched on and off by VoiceOver
/// (which cannot hold), it shows the companion awake in its day colour, wearing everything.
struct CustomizePeek: Equatable {
    /// A finger is on the button.
    var held = false
    /// VoiceOver switched it on.
    var latched = false

    /// Whether the previews show the awake look.
    var isOn: Bool { held || latched }
}

/// Customize's previews with, after the companion's bedtime, the night note under them
/// (`comp-cust-night`, `comp-slot-night`, approved 2026-10-25): on a slot whose pick the night hides
/// (glasses), the slot's own line.
struct CustomizePreviewSection: View {
    var store: FernletStore
    /// Whether this page's pick is the glasses, which come off while the companion sleeps.
    var showsGlassesLine = false
    @Binding var peek: CustomizePeek

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let tonight = WorldCompanionLook.current(store: store, at: context.date, night: .bedtime)
            VStack(spacing: 14) {
                CustomizePreviewCard(store: store, night: peek.isOn ? .awake : .bedtime)
                if tonight.isSleeping {
                    CustomizeNightNote(text: noteText(tonight), peek: $peek)
                        .accessibilityIdentifier("customize.nightNote")
                }
            }
        }
    }

    /// The note's words for tonight's look.
    private func noteText(_ tonight: WorldCompanionNow) -> String {
        let name = CustomizeNightCopy.companionName(store)
        let appearance = store.settings.companionAppearance
        if showsGlassesLine && appearance.accessory == .glasses { return CustomizeNightCopy.glassesLine(name: name) }
        let moodRests = tonight.pose.asleep && appearance.bodyColor == .state && appearance.bodyCustomColorHex == nil
        return CustomizeNightCopy.note(name: name, bedtime: CustomizeNightCopy.bedtime(WorldCompanionLook.sleepWindow),
                                       glassesOff: appearance.accessory == .glasses, moodRests: moodRests)
    }
}

/// The night note (`.cnight`): night blue with cream words, a 2-pt ink frame, the pixel moon, and
/// "Hold to peek" beside the words (under them at the largest text sizes).
struct CustomizeNightNote: View {
    let text: String
    @Binding var peek: CustomizePeek
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The note's night blue and its cream words (12.9 : 1).
    static let fill = WorldPalette.rgb(0x2E3550)
    static let words = WorldPalette.rgb(0xF3EAD6)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        layout {
            HStack(alignment: .center, spacing: 10) {
                WorldSpriteView(sprite: WorldSprites.moon, scale: 2, tint: Self.words)
                Text(verbatim: text)
                    .font(FernletFramedFont.notice)
                    .foregroundStyle(Self.words)
                    .fernletWrappingText()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            CustomizePeekButton(peek: $peek)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Self.fill, in: shape)
        .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: 2))
    }
}

/// "Hold to peek": the awake look while a finger is on it; VoiceOver's activation switches it on and
/// off instead, and says which.
struct CustomizePeekButton: View {
    @Binding var peek: CustomizePeek

    var body: some View {
        Button {
            // A tap that ends is the hold ending: the press state below already showed the peek.
        } label: {
            Text(verbatim: CustomizeNightCopy.holdToPeek)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(CustomizePeekButtonStyle(held: $peek.held))
        .accessibilityAction { peek.latched.toggle() }
        .accessibilityValue(peek.latched ? Text(verbatim: CustomizeNightCopy.peekingValue) : Text(verbatim: ""))
        .accessibilityHint(Text(verbatim: CustomizeNightCopy.peekHint))
        .accessibilityIdentifier("customize.holdToPeek")
    }
}

/// The small secondary pill, reporting while it is pressed.
private struct CustomizePeekButtonStyle: ButtonStyle {
    @Binding var held: Bool

    func makeBody(configuration: Configuration) -> some View {
        ActionPillButtonStyle(.secondary, size: .small).makeBody(configuration: configuration)
            .onChange(of: configuration.isPressed) { _, pressed in held = pressed }
    }
}

/// Customize's night words (`comp-cust-night`, `comp-slot-night`), resolved here so the views and the
/// tests read one copy.
enum CustomizeNightCopy {
    /// The companion's own name, or Fernlet, as the close-up names it.
    @MainActor
    static func companionName(_ store: FernletStore) -> String {
        let chosen = store.settings.companionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return chosen.isEmpty ? "Fernlet" : chosen
    }

    /// The bedtime as the clock shows it ("10:30 PM", "22:30").
    static func bedtime(_ window: CompanionSleepWindow, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let midnight = calendar.startOfDay(for: Date())
        let date = calendar.date(byAdding: .minute, value: window.bedtimeMinute, to: midnight) ?? midnight
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// The note under the previews after bedtime: what sleep changes tonight.
    static func note(name: String, bedtime: String, glassesOff: Bool, moodRests: Bool) -> String {
        switch (glassesOff, moodRests) {
        case (true, true):
            String(localized: "worldCustomize.night.glassesAndMood",
                   defaultValue: "\(name)'s asleep, as on the map (bedtime \(bedtime)). Its glasses are off and its mood color rests until morning.",
                   comment: "Customize after the companion's bedtime, under the previews: the companion's name, then its bedtime ('10:30 PM'). Spanish: 'Sprout duerme, como en el mapa (se acuesta a las 22:30). Se quitó las gafas y su color de ánimo descansa hasta mañana.'")
        case (false, true):
            String(localized: "worldCustomize.night.mood",
                   defaultValue: "\(name)'s asleep, as on the map (bedtime \(bedtime)). Its mood color rests until morning.",
                   comment: "Customize after the companion's bedtime, under the previews (no glasses worn): the companion's name, then its bedtime")
        case (true, false):
            String(localized: "worldCustomize.night.glasses",
                   defaultValue: "\(name)'s asleep, as on the map (bedtime \(bedtime)). Its glasses are off until morning.",
                   comment: "Customize after the companion's bedtime, under the previews (its body keeps a fixed color): the companion's name, then its bedtime")
        case (false, false):
            String(localized: "worldCustomize.night.plain",
                   defaultValue: "\(name)'s asleep, as on the map (bedtime \(bedtime)).",
                   comment: "Customize after the companion's bedtime, under the previews (nothing it wears changes): the companion's name, then its bedtime")
        }
    }

    /// The Accessory page's line at night while the glasses are picked.
    static func glassesLine(name: String) -> String {
        String(localized: "worldCustomize.night.glassesSlot",
               defaultValue: "Glasses come off while \(name) sleeps. Hold to peek at them.",
               comment: "Customize › Accessory after the companion's bedtime, with glasses picked: why they don't show. The companion's name follows 'while'")
    }

    /// The peek button's words.
    static var holdToPeek: String {
        String(localized: "worldCustomize.night.holdToPeek", defaultValue: "Hold to peek",
               comment: "Customize at night: hold this button to see the companion awake. Spanish: 'Mantén para ver'")
    }

    /// What VoiceOver says while the peek is switched on.
    static var peekingValue: String {
        String(localized: "worldCustomize.night.peeking", defaultValue: "Showing it awake",
               comment: "Customize at night, VoiceOver: the 'Hold to peek' button is on and the previews show the companion awake")
    }

    /// VoiceOver's hint for the peek button.
    static var peekHint: String {
        String(localized: "worldCustomize.night.peekHint", defaultValue: "Shows the previews awake, or asleep again.",
               comment: "Customize at night, VoiceOver hint on 'Hold to peek': activating it switches the previews between awake and asleep")
    }
}
