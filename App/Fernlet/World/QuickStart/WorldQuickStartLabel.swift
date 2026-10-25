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

    /// What VoiceOver says, politely, each time the label shows: "Quick start: Camera".
    var announcement: String {
        let base = String(localized: WorldQuickStartCopy.buttonLabel)
        let word = String(localized: title)
        return String(localized: "worldQuickStart.label.announcement", defaultValue: "\(base): \(word)",
                      comment: "World Home: what VoiceOver says when the blue button's action changes, 'Quick start: Camera'")
    }
}

/// When the label shows (`ref-blue-how`; owner's form answer 28, 2026-10-25: "Everytime it changes, but it
/// should slide back in after 30s"): every time the button's action changes to one with a label, and it
/// slides back in after 30 seconds. A change to an action with no label (Walk together, the resting day)
/// tucks a showing label away at once, so the word never names an action the button no longer has. The
/// first glyph the button shows is where it starts, not a change. Pure, so the tests drive it.
nonisolated struct WorldQuickStartLabelRule: Equatable, Sendable {
    /// The glyph last seen, and whether one has been seen at all.
    private(set) var glyph: WorldQuickStartGlyph?
    private(set) var hasSeen = false

    /// The label slides out in 0.3 s, stays 30 s, then slides back in 0.3 s.
    static let slideDuration: TimeInterval = 0.3
    static let holdDuration: TimeInterval = 30
    static let shrinkDuration: TimeInterval = 0.3

    /// Notes the button's glyph and returns what the label does now.
    mutating func observe(_ next: WorldQuickStartGlyph?) -> WorldQuickStartLabelStep {
        let changed = hasSeen && next != glyph
        glyph = next
        hasSeen = true
        guard changed else { return .stay }
        guard let label = WorldQuickStartLabel.label(for: next) else { return .tuckAway }
        return .show(label)
    }

    /// How the label moves in and out: a 0.3-s slide, or with Reduce Motion a fade in place.
    static func transition(reduceMotion: Bool) -> WorldQuickStartLabelMotion {
        reduceMotion ? .fade : .slide
    }
}

/// What the label does when the button's glyph is noted: nothing, slide out with a word (said politely
/// to VoiceOver), or tuck a showing word away.
nonisolated enum WorldQuickStartLabelStep: Equatable, Sendable {
    /// No change: a showing label keeps its 30 seconds.
    case stay
    /// The action changed to one with a label: show it.
    case show(WorldQuickStartLabel)
    /// The action changed to one without a label: tuck any showing label away.
    case tuckAway
}

/// How the label appears: sliding out from the button and shrinking back, or (Reduce Motion) fading
/// in and out where it stands.
nonisolated enum WorldQuickStartLabelMotion: Sendable, Equatable {
    case slide
    case fade
}

extension View {
    /// The blue button's label (`ref-blue-how`, form answer 28): watches `glyph` and, every time the action
    /// changes, slides the action's word out beside the button for 30 seconds and says it to VoiceOver.
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
                switch rule.observe(next) {
                case .stay: break
                case .show(let label): show(label)
                case .tuckAway: tuckAway()
                }
            }
    }

    /// Notes the first glyph (where the button starts, not a change). DEBUG screenshots (`label`) show
    /// its label and keep it out; the scene list is empty in release builds.
    private func start() {
        _ = rule.observe(glyph)
        guard UITestSupport.worldHomeScenes.contains("label"), let label = WorldQuickStartLabel.label(for: glyph) else { return }
        show(label, holds: true)
    }

    /// Slides `label` out, says it politely, holds it 30 seconds, then slides it back in (unless `holds`).
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

    /// The action changed to one without a word: a showing label goes back in now, and its pending
    /// hold is forgotten.
    private func tuckAway() {
        showID += 1
        guard isOut else { return }
        withAnimation(.easeIn(duration: WorldQuickStartLabelRule.shrinkDuration)) { isOut = false }
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
