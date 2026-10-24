import SwiftUI

/// The World build's "one design language" for cards (owner-approved 2026-10-23, `b1-language`):
/// every container is paper in a 2-pt ink frame with a solid drop shadow, section labels carry a small
/// framed square, and chips, tiles and switches share the frame.
///
/// An environment value, unset by default, so nothing changes until a surface opts in: the World build
/// sets it once at the app's root (`worldDesignLanguage()`), so every screen and every sheet the root
/// presents takes it. ``FernletCard`` and ``SectionLabel`` read it here; the framed primitives
/// (``FernletFramedSection``, ``FernletDropdown``, ``FernletFocusedFlow``, the sheet chrome) read it
/// too, and app views read it for their own inner pieces. The colours come from the caller's theme, so
/// this module owns the shape of the look and none of its palette.
///
/// The tokens added for the foundation lane (`page` … `warn`) default from the original nine, so a
/// look built with the original initializer arguments still compiles and draws sensibly.
public struct FernletFramedLook: Sendable {
    /// A card's fill.
    public var paper: Color
    /// Recessed surfaces inside a card: a bar's track, a switch that is off.
    public var paperLow: Color
    /// Raised pieces on a card: chips, icon tiles, fields, secondary buttons.
    public var raised: Color
    /// Every frame.
    public var ink: Color
    /// Titles and labels on the look's paper: dark ink in light mode, cream in dark mode (a frame's
    /// ink would vanish on dark paper).
    public var text: Color
    /// The solid drop shadow under a card (drawn 3 pt down).
    public var shadow: Color
    /// The calm card's fill (First aid).
    public var sage: Color
    /// The gentle-day row's fill ("I'm unwell today").
    public var rose: Color
    /// The small square before a section label, and a switch that is on.
    public var mark: Color
    /// Primary buttons and selected chips (the App colors accent; moss ink by default).
    public var accent: Color
    /// Text on ``accent``.
    public var onAccent: Color
    /// Secondary text on paper.
    public var dim: Color
    /// A page's parchment, under its faint dot grid (``FernletDottedPage``).
    public var page: Color
    /// The page's dot grid.
    public var pageDot: Color
    /// The 1-pt hairline between rows (`.sr`, `.kv`; the frame rule, ``FernletFrameRule``): ink at 16 %
    /// in light mode, cream at 16 % in dark, 40 % under Increase Contrast.
    public var rule: Color
    /// Accent as text: Done in a sheet, links and quiet buttons on paper ("Adjust targets").
    public var link: Color
    /// Wood, for navigation only: the sheet's grabber and a tag (`.ptag`).
    public var wood: Color
    /// The light edge along the top of a piece of wood.
    public var woodHigh: Color
    /// A warning notice's fill (`.notice3.warn`).
    public var warn: Color

    /// The original nine-plus-three tokens; the rest follow from them unless given.
    public init(paper: Color, paperLow: Color, raised: Color, ink: Color, text: Color, shadow: Color,
                sage: Color, rose: Color, mark: Color, accent: Color, onAccent: Color, dim: Color,
                page: Color? = nil, pageDot: Color? = nil, rule: Color? = nil, link: Color? = nil,
                wood: Color? = nil, woodHigh: Color? = nil, warn: Color? = nil) {
        self.paper = paper
        self.paperLow = paperLow
        self.raised = raised
        self.ink = ink
        self.text = text
        self.shadow = shadow
        self.sage = sage
        self.rose = rose
        self.mark = mark
        self.accent = accent
        self.onAccent = onAccent
        self.dim = dim
        self.page = page ?? paper
        self.pageDot = pageDot ?? ink.opacity(0.07)
        self.rule = rule ?? ink.opacity(FernletFrameRule.hairlineOpacity(increasedContrast: false))
        self.link = link ?? accent
        self.wood = wood ?? raised
        self.woodHigh = woodHigh ?? raised
        self.warn = warn ?? rose
    }

    /// A card's corner radius in this look.
    public static let cardRadius: CGFloat = 12
    /// A frame's width on cards and inner pieces.
    public static let frameWidth: CGFloat = 2
}

public extension EnvironmentValues {
    /// The framed look, when a surface has opted in; nil draws every card as it always has.
    @Entry var fernletFramedLook: FernletFramedLook? = nil
    /// Whether a page's own title is already on a title plate above it (a World panel's root page):
    /// ``ScreenHeader`` then draws only its subtitle, so the title is never said twice. A page pushed
    /// inside the panel, or a sheet, is presented and keeps its title, unless it hands its title to the
    /// plate (``fernletPageTitleOnPlate``).
    @Entry var fernletTitleOnPlate: Bool = false
    /// Whether this pushed page's title is on the plate (`fernletPushedPage(_:)` set it): ``ScreenHeader``
    /// drops its title here too. ``SwiftUI/View/fernletSheet()`` and ``FernletFocusedFlow`` clear it.
    @Entry var fernletPageTitleOnPlate: Bool = false
    /// Set by ``FernletFramedSection`` (and the framed `Form` style) on its rows, so a row's control can
    /// take the row's padding: the framed switch adds the vertical room a 54-pt row needs.
    @Entry var fernletInFramedRow: Bool = false
}

/// The framed look's switch (`b1-language`): a framed track, the look's ``FernletFramedLook/mark`` when
/// on, recessed paper when off, with a framed white knob. The whole row flips it, as a system switch does,
/// and VoiceOver hears a switch with the row's name and its state. Without the look it draws the system
/// switch.
public struct FernletFramedToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        FramedToggle(configuration: configuration)
    }

    /// The switch itself: a nested view because a `ToggleStyle` cannot read the environment.
    private struct FramedToggle: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.fernletFramedLook) private var look
        @Environment(\.fernletInFramedRow) private var inRow

        var body: some View {
            if let look {
                Button { configuration.isOn.toggle() } label: {
                    HStack {
                        configuration.label
                        Spacer(minLength: 12)
                        track(look)
                    }
                    .frame(minHeight: 44)
                    // In a framed row the switch is the row: 44 + 2 × 6 matches the kit's 54–56-pt row.
                    .padding(.vertical, inRow ? 6 : 0)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
            } else {
                Toggle(isOn: configuration.$isOn) { configuration.label }
                    .toggleStyle(.switch)
            }
        }

        private func track(_ look: FernletFramedLook) -> some View {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 8).fill(configuration.isOn ? look.mark : look.paperLow)
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(look.ink, lineWidth: 2))
                    .frame(width: 22, height: 22)
                    .padding(2)
            }
            .frame(width: 52, height: 30)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
            .animation(.easeOut(duration: 0.15), value: configuration.isOn)
        }
    }
}

public extension View {
    /// Frames this view as one of the look's raised pieces (a chip, an icon tile): the raised fill,
    /// a 2-pt ink frame and a 2-pt solid shadow, in `cornerRadius` corners.
    func fernletFramed(_ look: FernletFramedLook, fill: Color? = nil, cornerRadius: CGFloat = 8) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(fill ?? look.raised, in: shape)
            .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
            .background { shape.fill(look.shadow).offset(y: 2) }
    }
}

/// The type sizes the kit draws (World Review kits `kit-v3.css`, `kit-b1.css`, `kit-b2.css`,
/// `kit-b3.css`), each scaling with Dynamic Type through `relativeTo:`. Two typefaces only: Fraunces
/// for titles and big numbers, DM Sans for everything else.
///
/// Use these, not ad-hoc sizes, so a lane's screen matches the approved drafts point for point.
nonisolated public enum FernletFramedFont {
    /// A sheet's title inside the sheet (`.sht3 h4`): Fraunces 30.
    public static let sheetTitle = Font.custom(FernletFontName.frauncesSemiBold, size: 30, relativeTo: .title)
    /// A focused flow's title (`.focus3` head): Fraunces 21.
    public static let flowTitle = Font.custom(FernletFontName.frauncesSemiBold, size: 21, relativeTo: .title3)
    /// A card's title (`.ac-t` in the one design language): Fraunces 21.
    public static let cardTitle = Font.custom(FernletFontName.frauncesSemiBold, size: 21, relativeTo: .title3)
    /// The big timer (`.bigtime`): Fraunces 64.
    public static let bigTime = Font.custom(FernletFontName.frauncesSemiBold, size: 64, relativeTo: .largeTitle)
    /// A row's name (`.sl`): DM Sans 16.5.
    public static let rowTitle = Font.custom(FernletFontName.dmSans, size: 16.5, relativeTo: .body)
    /// A row's second line (`.sl small`): DM Sans 13.
    public static let rowDetail = Font.custom(FernletFontName.dmSans, size: 13, relativeTo: .footnote)
    /// A row's value before its chevron (`.rv`): DM Sans 14.5.
    public static let rowValue = Font.custom(FernletFontName.dmSans, size: 14.5, relativeTo: .subheadline)
    /// Body copy on paper (`.ac-s`, `.ac-p`): DM Sans 15.
    public static let body = Font.custom(FernletFontName.dmSans, size: 15, relativeTo: .body)
    /// A small note under a section (`.cd`, `.ac-d`): DM Sans 13.5.
    public static let note = Font.custom(FernletFontName.dmSans, size: 13.5, relativeTo: .footnote)
    /// What a person types in a field (`.fld`): DM Sans 16.
    public static let field = Font.custom(FernletFontName.dmSans, size: 16, relativeTo: .body)
    /// A framed button's word (`.pxbtn`): DM Sans bold 16.
    public static let button = Font.custom(FernletFontName.dmSansMedium, size: 16, relativeTo: .body).weight(.bold)
    /// A small framed button (`.pxbtn.sm`): DM Sans bold 14.5.
    public static let buttonSmall = Font.custom(FernletFontName.dmSansMedium, size: 14.5, relativeTo: .subheadline).weight(.bold)
    /// A sheet's Cancel (`.sht3 .top button`): DM Sans semibold 16.
    public static let sheetControl = Font.custom(FernletFontName.dmSansMedium, size: 16, relativeTo: .body).weight(.semibold)
    /// Chips, segments and a dropdown's value (`.chip`, `.seg3`): DM Sans semibold 14.5.
    public static let chip = Font.custom(FernletFontName.dmSansMedium, size: 14.5, relativeTo: .subheadline).weight(.semibold)
    /// A section tab (`.tabs3`): DM Sans semibold 15.
    public static let tab = Font.custom(FernletFontName.dmSansMedium, size: 15, relativeTo: .subheadline).weight(.semibold)
    /// A notice's words (`.notice3`): DM Sans 14.5.
    public static let notice = Font.custom(FernletFontName.dmSans, size: 14.5, relativeTo: .subheadline)
    /// A key-value row (`.kv`): DM Sans 15; the value is the bold of it.
    public static let keyValue = Font.custom(FernletFontName.dmSans, size: 15, relativeTo: .subheadline)
    /// A tag (`.ptag`): DM Sans bold 12.
    public static let tag = Font.custom(FernletFontName.dmSansMedium, size: 12, relativeTo: .caption).weight(.bold)
    /// The plate's Back (`.pt .bk`): DM Sans bold 16.
    public static let back = Font.custom(FernletFontName.dmSansMedium, size: 16, relativeTo: .body).weight(.bold)
    /// A stepper's − and + (`.stepper span`): DM Sans bold 18.
    public static let stepperGlyph = Font.custom(FernletFontName.dmSansMedium, size: 18, relativeTo: .body).weight(.bold)
}
