import FernletDomainModel
import FernletUI
import SwiftUI

// MARK: - TapToConnectRings

/// The rings that ripple from the top edge while someone with Fernlet is within about 3 m of Home
/// (`fr-tap-home` draft 2, `fr-locoff` draft 2), stronger as the phones come together
/// (``TapToConnectRingStyle``). Reduce Motion stills them; only their opacity follows the closeness then.
/// Decoration: VoiceOver hears the plate instead, and touches pass through to Home.
struct TapToConnectRings: View {
    let cue: TapToConnectHomeCue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if cue.isRinging {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                    Canvas { context, size in
                        let time = reduceMotion ? nil : timeline.date.timeIntervalSinceReferenceDate
                        Self.draw(TapToConnectRingStyle.rings(strength: cue.strength, time: time), in: &context, size: size)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: cue.isRinging)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Strokes `rings` round the point just below the top edge's middle.
    private static func draw(_ rings: [TapToConnectRingStyle.Ring], in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let centre = CGPoint(x: size.width / 2, y: TapToConnectRingStyle.centreDrop)
        // R2: bounded by the style's three rings.
        for ring in rings where ring.opacity > 0 {
            let box = CGRect(x: centre.x - ring.radius, y: centre.y - ring.radius, width: ring.radius * 2, height: ring.radius * 2)
            context.stroke(Path(ellipseIn: box), with: .color(TapToConnectRingStyle.colour.opacity(ring.opacity)),
                           lineWidth: ring.lineWidth)
        }
    }
}

// MARK: - TapToConnectPlate

/// The plate while someone with Fernlet is within about 3 m: "Someone with Fernlet is close · Hold your phones
/// together to connect", in the map notice's look (the kit's `.ntc`: paper in a 3-pt ink frame, the pair sprite, a
/// bold line and a line under it). It sits under the status plate on the map Home and under the status plate on
/// the location-off Home, and draws nothing otherwise, so the stacks it sits in keep their spacing. VoiceOver reads
/// it as one element; its appearance is announced once (``TapToConnectHomeLayer``).
struct TapToConnectPlate: View {
    /// The room above it (the location-off Home's enlarged status plate overhangs its own frame).
    var topPadding: CGFloat = 0
    @Environment(TapToConnectHomeCue.self) private var cue: TapToConnectHomeCue?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if cue?.isRinging == true {
            ViewThatFits(in: .horizontal) {
                plate.fixedSize()
                plate.frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 380 : 360)
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("tap.plate")
            .frame(maxWidth: .infinity)
            .padding(.top, topPadding)
            .transition(.opacity)
        }
    }

    /// The framed plate.
    private var plate: some View {
        HStack(alignment: .center, spacing: 10) {
            // The pair sprite is drawn white for the blue button; on the plate's paper it takes the ink.
            WorldSpriteView(sprite: WorldSprites.pair, scale: 2, tint: WorldPalette.iconInk)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(TapToConnectCopy.plateTitle)
                    .font(WorldNoticeType.title)
                Text(TapToConnectCopy.plateDetail)
                    .font(WorldNoticeType.detail)
            }
            .foregroundStyle(WorldPalette.bark)
            .fernletWrappingText()
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .background(WorldPalette.paper, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(WorldPalette.ink, lineWidth: 3))
        .background {
            RoundedRectangle(cornerRadius: 9).fill(WorldPalette.ink.opacity(0.35)).offset(y: 3)
        }
    }
}

// MARK: - TapToConnectQuestionSheet

/// The question each phone shows after the tap (World Friends §1.3, `fr-tap-found`): a full-height sheet titled
/// "Start a hangout with Rae?", Not now top left, the other person's companion large with the name they appear as,
/// what a hangout is, and Start hangout. After Start hangout it waits: "Waiting for Rae…" in the button's place and
/// no Not now, since a yes can't be taken back; it goes when the hangout starts or the other says Not now.
///
/// The companion is decoration (the name says who); VoiceOver's escape gesture is Not now, as the top-left button.
struct TapToConnectQuestionSheet: View {
    let question: TapToConnectQuestion
    let isWaiting: Bool
    /// The person's answer: true for Start hangout.
    let onAnswer: (Bool) -> Void
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                meeting
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
            FernletSheetFooter { footer }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SheetHeader(title: Text(TapToConnectCopy.question(question.shownName))) {
                if !isWaiting { notNowButton }
            }
        }
        .fernletSheet()
        // VoiceOver's escape gesture (the two-finger scrub) is Not now while Not now is offered.
        .accessibilityAction(.escape) { if !isWaiting { onAnswer(false) } }
        .accessibilityIdentifier("tap.question")
    }

    /// Not now, where the sheet chrome's Cancel stands (the kit's left slot).
    private var notNowButton: some View {
        Button { onAnswer(false) } label: { Text(TapToConnectCopy.notNow) }
            .buttonStyle(.plain)
            .font(look == nil ? .fernlet(.label) : FernletFramedFont.sheetControl)
            .foregroundStyle(look?.dim ?? Color.slate)
            .fernletTapTarget()
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("tap.question.notNow")
    }

    /// Their companion, their name and the line under it, and what a hangout is.
    private var meeting: some View {
        VStack(spacing: 14) {
            WorldCompanionSprite(state: .thriving,
                                 look: WorldCompanionLook(appearance: question.appearance ?? .standard, state: .thriving, asleep: false),
                                 isActive: false, pixelScale: dynamicTypeSize.isAccessibilitySize ? 4 : 6)
                .padding(.vertical, 14)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(verbatim: question.shownName)
                    .font(Self.nameFont)
                    .foregroundStyle(look?.text ?? WorldPalette.bark)
                if question.hasName {
                    Text(TapToConnectCopy.appearsAs(question.shownName))
                        .font(FernletFramedFont.note)
                        .foregroundStyle(look?.dim ?? WorldPalette.dim)
                }
            }
            .multilineTextAlignment(.center)
            .fernletWrappingText()
            .accessibilityElement(children: .combine)
            Text(TapToConnectCopy.explainer)
                .font(FernletFramedFont.body)
                .foregroundStyle(look?.dim ?? WorldPalette.dim)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
        }
        .frame(maxWidth: .infinity)
    }

    /// Start hangout, or the wait once it was said.
    @ViewBuilder private var footer: some View {
        if isWaiting {
            Text(TapToConnectCopy.waiting(question.shownName))
                .font(FernletFramedFont.button)
                .foregroundStyle(look?.dim ?? WorldPalette.dim)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
                .frame(maxWidth: .infinity, minHeight: 50)
                .accessibilityIdentifier("tap.question.waiting")
        } else {
            Button { onAnswer(true) } label: { Text(TapToConnectCopy.start).frame(maxWidth: .infinity) }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .accessibilityIdentifier("tap.question.start")
        }
    }

    /// The name, as the approved page sets it: DM Sans Bold 24.
    private static let nameFont = Font.custom(FernletFontName.dmSansBold, size: 24, relativeTo: .title2)
}
