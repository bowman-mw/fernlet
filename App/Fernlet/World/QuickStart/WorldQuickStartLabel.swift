import FernletUI
import SwiftUI

/// The short word that slides out beside the blue button when its action changes (World Review
/// Refinements `ref-blue-session`, `ref-blue-space`, `ref-blue-route`, `ref-blue-hike`, `ref-blue-how`,
/// approved by the owner on 2026-10-24): "Camera" when a session or a hike makes it the camera,
/// "Workout" at a workout space, "Run" at the start of a saved run route. Walk together and the resting
/// day keep the icon alone, as approved. The cases are tokens; ``title`` is what is shown.
nonisolated enum WorldQuickStartLabel: String, CaseIterable, Sendable {
    case camera
    case workout
    case run

    /// The label for the button's glyph, or nil when the icon says enough on its own.
    static func label(for glyph: WorldQuickStartGlyph?) -> WorldQuickStartLabel? {
        switch glyph {
        case .camera: .camera
        case .space: .workout
        case .run: .run
        case .walk, .trail, .rest, .friends, .eat, nil: nil
        }
    }

    /// The word on the label (Cámara, Entreno, Correr).
    var title: LocalizedStringResource {
        switch self {
        case .camera:
            LocalizedStringResource("worldQuickStart.label.camera", defaultValue: "Camera",
                                    comment: "World Home: the short label beside the blue button when it becomes the disposable camera (Spanish: Cámara)")
        case .workout:
            LocalizedStringResource("worldQuickStart.label.workout", defaultValue: "Workout",
                                    comment: "World Home: the short label beside the blue button at a workout space (Spanish: Entreno)")
        case .run:
            LocalizedStringResource("worldQuickStart.label.run", defaultValue: "Run",
                                    comment: "World Home: the short label beside the blue button at the start of a saved route (Spanish: Correr)")
        }
    }

    /// The button's name for VoiceOver and Voice Control: always "Quick start, Camera" while the
    /// button is the camera, whether or not the label is showing; "Quick start" for the unlabelled icons.
    static func buttonName(for glyph: WorldQuickStartGlyph?) -> String {
        let base = String(localized: WorldQuickStartCopy.buttonLabel)
        guard let label = label(for: glyph) else { return base }
        let word = String(localized: label.title)
        return String(localized: "worldQuickStart.label.name", defaultValue: "\(base), \(word)",
                      comment: "World Home: the blue button's VoiceOver name with its action, 'Quick start, Camera'")
    }

    /// What VoiceOver says once, politely, when the label shows: "Quick start: Camera".
    var announcement: String {
        let base = String(localized: WorldQuickStartCopy.buttonLabel)
        let word = String(localized: title)
        return String(localized: "worldQuickStart.label.announcement", defaultValue: "\(base): \(word)",
                      comment: "World Home: what VoiceOver says once when the blue button's action changes, 'Quick start: Camera'")
    }
}

/// When the label shows (`ref-blue-how`): only when the button's action changes to one with a label,
/// never on a timer, and never twice for the same action in a day. The first glyph the button shows is
/// where it starts, not a change. Pure, so the tests drive it.
nonisolated struct WorldQuickStartLabelRule: Equatable, Sendable {
    /// The glyph last seen, and whether one has been seen at all.
    private(set) var glyph: WorldQuickStartGlyph?
    private(set) var hasSeen = false
    /// The day the shown labels count for, and the labels already shown that day.
    private(set) var day: Date?
    private(set) var shown: [WorldQuickStartLabel] = []

    /// The label slides out in 0.3 s, stays 3 s, then shrinks back in 0.3 s.
    static let slideDuration: TimeInterval = 0.3
    static let holdDuration: TimeInterval = 3
    static let shrinkDuration: TimeInterval = 0.3

    /// Notes the button's glyph on `day` (the day's start) and returns the label to show now, if any.
    mutating func observe(_ next: WorldQuickStartGlyph?, day: Date) -> WorldQuickStartLabel? {
        if self.day != day {
            self.day = day
            shown = []
        }
        let changed = hasSeen && next != glyph
        glyph = next
        hasSeen = true
        guard changed, let label = WorldQuickStartLabel.label(for: next), !shown.contains(label) else { return nil }
        shown.append(label)
        return label
    }

    /// How the label moves in and out: a 0.3-s slide, or with Reduce Motion a fade in place.
    static func transition(reduceMotion: Bool) -> WorldQuickStartLabelMotion {
        reduceMotion ? .fade : .slide
    }
}

/// How the label appears: sliding out from the button and shrinking back, or (Reduce Motion) fading
/// in and out where it stands.
nonisolated enum WorldQuickStartLabelMotion: Sendable, Equatable {
    case slide
    case fade
}

extension View {
    /// The blue button's label (`ref-blue-how`): watches `glyph` and, when the action changes, slides
    /// the action's word out beside the button for three seconds and says it once to VoiceOver.
    func worldQuickStartLabel(for glyph: WorldQuickStartGlyph) -> some View {
        modifier(WorldQuickStartLabelModifier(glyph: glyph))
    }
}

/// Implements `worldQuickStartLabel(for:)`: the label behind the button's left edge, tucked under it.
struct WorldQuickStartLabelModifier: ViewModifier {
    let glyph: WorldQuickStartGlyph
    @State private var rule = WorldQuickStartLabelRule()
    @State private var showing: WorldQuickStartLabel?
    @State private var isOut = false
    @State private var showID = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(alignment: .trailing) {
                if let showing {
                    WorldQuickStartLabelPill(label: showing)
                        .scaleEffect(x: isOut || reduceMotion ? 1 : 0.01, y: 1, anchor: .trailing)
                        .opacity(isOut ? 1 : 0)
                        .offset(x: -56)
                }
            }
            .onAppear(perform: start)
            .onChange(of: glyph) { _, next in
                guard let label = rule.observe(next, day: Calendar.current.startOfDay(for: .now)) else { return }
                show(label)
            }
    }

    /// Notes the first glyph (where the button starts, not a change). DEBUG screenshots (`label`) show
    /// its label and keep it out; the scene list is empty in release builds.
    private func start() {
        _ = rule.observe(glyph, day: Calendar.current.startOfDay(for: .now))
        guard UITestSupport.worldHomeScenes.contains("label"), let label = WorldQuickStartLabel.label(for: glyph) else { return }
        show(label, holds: true)
    }

    /// Slides `label` out, says it once, holds it, then shrinks it back (unless `holds`).
    private func show(_ label: WorldQuickStartLabel, holds: Bool = false) {
        showID += 1
        let id = showID
        showing = label
        isOut = false
        withAnimation(.easeOut(duration: WorldQuickStartLabelRule.slideDuration)) { isOut = true }
        FernletAnnouncer.system.announce(.status, resolved: label.announcement)
        guard !holds else { return }
        Task {
            do {
                try await Task.sleep(for: .seconds(WorldQuickStartLabelRule.slideDuration + WorldQuickStartLabelRule.holdDuration))
            } catch {
                return
            }
            guard showID == id else { return }
            withAnimation(.easeIn(duration: WorldQuickStartLabelRule.shrinkDuration)) { isOut = false }
        }
    }
}

/// The label itself (`kit-ref.css` `.gopill`): the button's teal, 60 pt tall, open on the right where
/// it tucks under the button, the word in DM Sans bold 17 (21 at the accessibility sizes) in deep teal.
struct WorldQuickStartLabelPill: View {
    let label: WorldQuickStartLabel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The pill's face and word: the kit's light teal with deep-teal ink in both modes (8.1:1).
    static let face = WorldPalette.rgb(0x5FB8C9)
    static let ink = WorldPalette.rgb(0x0B2A33)

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10)
        Text(label.title)
            .font(.custom(FernletFontName.dmSansBold, size: dynamicTypeSize.isAccessibilitySize ? 21 : 17, relativeTo: .body))
            // Two steps, as the approved designs draw it beside the 60-pt button: 17, then 21.
            .dynamicTypeSize(...DynamicTypeSize.large)
            .foregroundStyle(Self.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, 18)
            .padding(.trailing, 20)
            .frame(height: 60)
            .background(Self.face, in: shape)
            .overlay(alignment: .bottom) { WorldQuickStartPalette.tealLow.frame(height: 4).padding(.leading, 3).padding(.bottom, 3) }
            .overlay { shape.stroke(WorldQuickStartPalette.tealEdge, lineWidth: 3) }
            .background { shape.fill(Color(.sRGB, red: 20 / 255, green: 40 / 255, blue: 50 / 255, opacity: 0.4)).offset(y: 3) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
