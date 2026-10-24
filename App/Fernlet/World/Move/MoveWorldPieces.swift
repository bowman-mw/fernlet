import SwiftUI
import FernletDomainModel
import FernletUI

// The small framed pieces the Move panel's pages share (World Review Batch 2, `b2-move-root`,
// `b2-move-day`, `b2-exercise-history`, `b2-weekly-totals`, `b2-progress-photos`). Each draws the approved
// look under ``FernletFramedLook`` and today's look without it, so a screen keeps one call site.

/// The Move pages' strong text in the World look: the DM Sans **Medium** face at the framed sizes.
/// The app bundles only DM Sans Regular and Medium, so `.weight(.semibold)` on a framed font (the
/// Regular face) draws regular; the approved names, figures and tags are the heavier face.
nonisolated enum MoveFont {
    /// A row's or card's name (`FernletFramedFont.rowTitle`'s size).
    static let rowTitle = Font.custom(FernletFontName.dmSansMedium, size: 16.5, relativeTo: .body)
    /// A strong figure in running text (`FernletFramedFont.body`'s size): "4 × 8–12", "~8 min".
    static let body = Font.custom(FernletFontName.dmSansMedium, size: 15, relativeTo: .body)
    /// A row's strong trailing value (`FernletFramedFont.rowValue`'s size).
    static let rowValue = Font.custom(FernletFontName.dmSansMedium, size: 14.5, relativeTo: .subheadline)
    /// A small strong tag (`FernletFramedFont.rowDetail`'s size).
    static let rowDetail = Font.custom(FernletFontName.dmSansMedium, size: 13, relativeTo: .footnote)
    /// A small uppercase caption ("GOAL", "SET", a weekday letter) at today's `labelSmall` size.
    static let caption = Font.custom(FernletFontName.dmSansMedium, size: 12, relativeTo: .caption)
}

/// A framed button with a pixel icon before its word (`b2-move-root`'s "+ Log" and "Share",
/// `b2-move-day`'s Plan and Log): a secondary action pill, full width when `fills` is on.
struct MoveIconButton: View {
    let title: Text
    let sprite: WorldSprite
    var fills = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                WorldSpriteView(sprite: sprite, scale: 2)
                title.lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: fills ? .infinity : nil)
        }
        .buttonStyle(ActionPillButtonStyle(.secondary))
    }
}

/// A Move link card (`b2-move-root`'s Exercise history and Weekly totals): a framed card holding a pixel
/// icon tile, the page's name and the pixel chevron. The whole card is the button.
struct MoveLinkCard: View {
    let title: Text
    let sprite: WorldSprite
    /// A dim line under the title ("22 pieces of equipment"), when the card has one.
    var detail: Text? = nil
    /// Draws the sprite in the look's ink: for the blue button's white sprites (the dumbbell), which
    /// would vanish on the paper tile in their own colour.
    var inksSprite = false
    let identifier: String
    let action: () -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Button(action: action) {
            FernletCard {
                HStack(spacing: 14) {
                    FernletIconTile(size: 42) {
                        WorldSpriteView(sprite: sprite, scale: 2, tint: inksSprite ? look?.text : nil)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        title
                            .font(MoveFont.rowTitle)
                            .foregroundStyle(look?.text ?? Color.bark)
                            .fernletWrappingText()
                        if let detail {
                            detail
                                .font(FernletFramedFont.rowDetail)
                                .foregroundStyle(look?.dim ?? Color.slate)
                                .fernletWrappingText()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    FernletIcon(.chevron)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// A pushed Move page's own big title and the date under it (`b2-move-day`: "Today" over "Friday, Oct 23"),
/// read as one heading. The plate names the page too; this is the page's printed heading.
struct MovePageTitle: View {
    let title: Text
    let subtitle: Text
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
                .font(.custom(FernletFontName.frauncesSemiBold, size: 34, relativeTo: .largeTitle))
                .foregroundStyle(look?.text ?? Color.bark)
                .fernletWrappingText()
            subtitle
                .font(FernletFramedFont.body)
                .foregroundStyle(look?.dim ?? Color.slate)
                .fernletWrappingText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHeading(.h1)
    }
}

/// A small coloured square in an ink frame (`.legend i`, the Log sheet's exercise rows): a category's
/// colour as a pixel swatch, decorative.
struct MoveSwatch: View {
    let color: Color
    var size: CGFloat = 8
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Rectangle().strokeBorder(look?.ink ?? Color.bark, lineWidth: size > 10 ? 2 : 1.5))
            .accessibilityHidden(true)
    }
}

/// A titled list of Move rows (today's movement, a day's plan and workouts). World build (`b2-move-day`):
/// the section label, then each row on its own framed card. Today: one cream card with hairlines between
/// the rows, as `FernletScrollSection` draws it. Every direct child of `content` is one row.
struct MoveCardList<Content: View>: View {
    let header: Text?
    let content: Content
    @Environment(\.fernletFramedLook) private var look

    init(header: Text?, @ViewBuilder content: () -> Content) {
        self.header = header
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: look == nil ? 8 : 12) {
            if let header { SectionLabel(header).padding(.horizontal, 4) }
            Group(subviews: content) { rows in
                if look != nil {
                    ForEach(rows) { row in
                        FernletCard { row.frame(maxWidth: .infinity, alignment: .leading) }
                    }
                } else {
                    plainCard(rows)
                }
            }
        }
    }

    /// Today's cream card: the rows split by the house hairline.
    private func plainCard(_ rows: SubviewsCollection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                if row.id != rows.first?.id { FernletRowDivider() }
                row
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .bark.opacity(0.06), radius: 10, x: 0, y: 4)
    }
}

/// A Move day page's chrome. World build (`b2-move-day`): the dotted page, its name and Back on the
/// panel's plate (Plan and Log are in the page). Today: parchment, an empty inline bar carrying Plan and
/// Log, as the page draws its own ScreenHeader.
struct MoveDayChrome<Items: ToolbarContent>: ViewModifier {
    let isFramed: Bool
    let plateTitle: String
    @ToolbarContentBuilder let toolbarItems: () -> Items

    func body(content: Content) -> some View {
        if isFramed {
            content
                .fernletPageBackground()
                .fernletPushedPage(verbatim: plateTitle)
        } else {
            content
                .background(Color.parchment)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarItems() }
        }
    }
}

/// A small card inside a workout sheet (Log it again, the category preview, a chosen activity): World
/// build, paper in a 2-pt ink frame with its solid shadow; today, cream with a hairline.
struct MoveInsetCardFrame: ViewModifier {
    var cornerRadius: CGFloat = 12
    @Environment(\.fernletFramedLook) private var look

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if let look {
            content
                .background(look.paper, in: shape)
                .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
                .background { shape.fill(look.shadow).offset(y: 3) }
        } else {
            content
                .background(Color.cream, in: shape)
                .overlay(shape.stroke(Color.bark.opacity(0.10), lineWidth: 1))
        }
    }
}

/// Pixel sprites the Move screens draw that the World sheet has no entry for, drawn in the approved
/// pages' style (World Review Batch 3). Kept here, not in the shared sprite table, so lanes don't collide.
nonisolated enum MoveSprites {
    /// The terracotta bin on a custom exercise's Delete (`b3-your-exercises`).
    static let trash = WorldSprite(rows: ["..kkk..", "kkkkkkk", ".k...k.", ".k.k.k.", ".k.k.k.", ".k.k.k.", ".kkkkk."],
                                   palette: ["k": 0xB8543D])
    /// The flag on the runner's Start (`b3-runner-ready`).
    static let flag = WorldSprite(rows: ["kk.....", "kkkkkk.", "kkkkkkk", "kkkkkk.", "kk.....", "kk.....", "kk....."],
                                  palette: ["k": 0xFFFFFF])
    /// The wand on the Suggest primary (`b3-suggest-config`), drawn in the button's on-accent ink.
    static let wand = WorldSprite(rows: ["....k.k", ".....k.", "....k.k", "...k...", "..k....", ".k.....", "k......"],
                                  palette: ["k": 0xFFFFFF])
    /// The "i" on an exercise's how-to button (`b3-runner-set`).
    static let info = WorldSprite(rows: ["kkkkkkk", "k..k..k", "k.....k", "k.kk..k", "k..k..k", "k.kkk.k", "kkkkkkk"],
                                  palette: ["k": WorldSprite.ink])
}

/// The pixel sprites the workout screens draw for an activity, where the World art has one.
enum MoveActivitySprites {
    /// The sprite for `type`, or nil to keep its symbol in a framed tile.
    static func sprite(for type: WorkoutActivityType) -> WorldSprite? {
        switch type {
        case .running: WorldSprites.runner
        case .walking: WorldSprites.boot
        case .hiking: WorldSprites.tree
        case .traditionalStrengthTraining, .functionalStrengthTraining: WorldSprites.dumbbell
        default: nil
        }
    }
}

/// The Move root's Share button names what it shares for VoiceOver and keeps its stable identifier, on
/// both the framed button and today's header pill.
struct MoveShareAccessibility: ViewModifier {
    func body(content: Content) -> some View {
        content
            .accessibilityIdentifier("move.trainerShare")
            .accessibilityLabel("Share with a trainer")
            // T2-12: the label is longer than the drawn word, so Voice Control's spoken
            // name and the visible one had diverged; "Share" is what a user reads and says.
            .accessibilityInputLabels([Text("Share")])
    }
}

/// The dim line under a Move page's plate (`.desc` in the kit): what the page shows, in one sentence.
struct MovePageDescription: View {
    let text: Text
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        text
            .font(FernletFramedFont.body)
            .foregroundStyle(look?.dim ?? Color.slate)
            .fernletWrappingText()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
