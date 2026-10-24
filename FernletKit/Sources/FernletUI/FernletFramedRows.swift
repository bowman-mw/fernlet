//
//  FernletFramedRows.swift
//  FernletUI
//
//  Rows and sections in the one design language (`kit-b1.css` `.srs` / `.sr`, `kit-v3.css`): a framed
//  paper card whose rows are 54 pt or taller, 16 pt in, split by dotted rules; and the `Form` style that
//  draws every Form that way under the look.
//

import SwiftUI

/// The dotted rule between rows (`.sr`, `.kv`, `.ingr`): 2-pt round dots every 4 pt in the look's
/// ``FernletFramedLook/rule``. A faint hairline without the look.
public struct FernletDottedRule: View {
    @Environment(\.fernletFramedLook) private var look

    public init() {}

    public var body: some View {
        DottedLine()
            .stroke(look?.rule ?? Color.bark.opacity(0.12),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0, 4]))
            .frame(height: 2)
            .accessibilityHidden(true)
    }
}

/// A horizontal line through the middle of its frame, starting one point in so the first dot is whole.
nonisolated private struct DottedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 1, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// A framed section (`.srs`): an optional section label, then the rows on one paper card in a 2-pt ink
/// frame with a solid shadow, each row at least 54 pt tall and 16 pt in, dotted rules between them,
/// and an optional note below.
///
/// ```swift
/// FernletFramedSection("Your day") {
///     NavigationLink(value: Route.appearance) {
///         FernletRowLabel("Appearance", detail: "Theme, backgrounds, companion")
///     }
///     .buttonStyle(FernletRowButtonStyle())
///     Toggle("Hunger and thirst cues", isOn: $cues)
/// }
/// ```
///
/// Every direct child is one row. A switch takes the framed switch's row height by itself; a link or a
/// button takes ``FernletRowButtonStyle`` (the chevron and the 13-pt row padding). Without the look the
/// rows sit on a cream card split by hairlines.
public struct FernletFramedSection<Content: View>: View {
    let header: Text?
    let footer: Text?
    let content: Content
    @Environment(\.fernletFramedLook) private var look

    /// The localizing initializer: the header and note are harvested into the calling target's catalog.
    public init(_ header: LocalizedStringKey? = nil, footer: LocalizedStringKey? = nil,
                @ViewBuilder content: () -> Content) {
        self.header = header.map { Text($0) }
        self.footer = footer.map { Text($0) }
        self.content = content()
    }

    /// The `Text` initializer, for a header or note that is runtime data.
    public init(header: Text?, footer: Text? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let header {
                SectionLabel(header).padding(.horizontal, 4)
            }
            FernletFramedRows { content }
            if let footer {
                footer
                    .font(FernletFramedFont.note)
                    .foregroundStyle(look?.dim ?? Color.slate)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
    }
}

/// The card under ``FernletFramedSection`` and the framed `Form` style: every subview of `content` one
/// row, dotted rules between rows.
struct FernletFramedRows<Content: View>: View {
    let content: Content
    @Environment(\.fernletFramedLook) private var look

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: look == nil ? FernletMetrics.radiusMd : FernletFramedLook.cardRadius,
                                     style: .continuous)
        Group(subviews: content) { rows in
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    if row.id != rows.first?.id { separator }
                    row
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                }
            }
        }
        .environment(\.fernletInFramedRow, true)
        .background(look?.paper ?? Color.cream, in: shape)
        .overlay { if let look { shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth) } }
        .background { if let look { shape.fill(look.shadow).offset(y: 3) } }
    }

    /// The dotted rule under the look, a hairline inset 16 pt without it.
    @ViewBuilder
    private var separator: some View {
        if look != nil {
            FernletDottedRule()
        } else {
            Divider().padding(.leading, 16)
        }
    }
}

/// A row that is a button or a link (`.sr` with its `.chev`): the label full width, the pixel chevron at
/// the end, 13 pt above and below. Dims while pressed and when disabled.
///
/// The framed `Form` style gives it to every button and link in a Form; a Form button that should not
/// show a chevron (Delete everything) sets its own style, which wins.
public struct FernletRowButtonStyle: ButtonStyle {
    var showsChevron: Bool

    /// - Parameter showsChevron: Whether the row ends in a chevron (a link, or a button that opens
    ///   something). A button that acts in place passes false.
    public init(showsChevron: Bool = true) {
        self.showsChevron = showsChevron
    }

    public func makeBody(configuration: Configuration) -> some View {
        RowButton(configuration: configuration, showsChevron: showsChevron)
    }

    /// Nested so the style can read `isEnabled`; a `ButtonStyle` has no environment of its own.
    private struct RowButton: View {
        let configuration: ButtonStyleConfiguration
        let showsChevron: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.fernletFramedLook) private var look

        var body: some View {
            HStack(spacing: 12) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showsChevron {
                    FernletIcon(.chevron, scale: 2, tint: look == nil ? Color.slate : nil)
                }
            }
            .foregroundStyle(look?.text ?? Color.bark)
            .padding(.vertical, 13)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
        }
    }
}

/// A row's words (`.sl`, `.rv`): its name (DM Sans 16.5), an optional second line (13, dim) and an
/// optional value before the chevron (14.5, dim, at most 150 pt). `destructive` inks the name terracotta,
/// semibold (`.sr.danger`).
public struct FernletRowLabel: View {
    let title: Text
    let detail: Text?
    let value: Text?
    var destructive: Bool
    @Environment(\.fernletFramedLook) private var look

    /// The localizing initializer.
    public init(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, value: Text? = nil,
                destructive: Bool = false) {
        self.title = Text(title)
        self.detail = detail.map { Text($0) }
        self.value = value
        self.destructive = destructive
    }

    /// The `Text` initializer, for a name or line that is runtime data (a live count, a time).
    public init(title: Text, detail: Text? = nil, value: Text? = nil, destructive: Bool = false) {
        self.title = title
        self.detail = detail
        self.value = value
        self.destructive = destructive
    }

    public var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(FernletFramedFont.rowTitle.weight(destructive ? .semibold : .regular))
                    .foregroundStyle(destructive ? Color.terracottaInk : (look?.text ?? Color.bark))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    detail
                        .font(FernletFramedFont.rowDetail)
                        .foregroundStyle(look?.dim ?? Color.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value {
                value
                    .font(FernletFramedFont.rowValue)
                    .foregroundStyle(look?.dim ?? Color.slate)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 150, alignment: .trailing)
            }
        }
    }
}

/// Draws every `Form` below it as framed sections under the look (`.srs` / `.sr`): each section's
/// header, then its rows on one framed card with dotted rules, then its footer as a dim note, in a
/// scroll view 16 pt in from the edges, on the dotted page. Links and buttons take
/// ``FernletRowButtonStyle`` (a chevron); switches take the framed switch. Without the look it is the
/// system's grouped Form.
///
/// Set once at the root (`worldDesignLanguage()`), so every Form inherits it. A `Picker` inside a framed
/// Form draws as a bare menu; put a ``FernletDropdown`` in the row instead.
public struct FernletFormStyle: FormStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        FramedForm(configuration: configuration)
    }

    /// The Form itself: a nested view because a `FormStyle` cannot read the environment.
    private struct FramedForm: View {
        let configuration: FormStyleConfiguration
        @Environment(\.fernletFramedLook) private var look

        var body: some View {
            if let look {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(sections: configuration.content) { section in
                            FramedFormSection(section: section, look: look)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 30)
                }
                // The page's dotted parchment, over any plain background the Form was given.
                .fernletPageBackground()
            } else {
                Form(configuration).formStyle(.grouped)
            }
        }
    }

    /// One Form section: the header as written, the rows framed, the footer as a note.
    private struct FramedFormSection: View {
        let section: SectionConfiguration
        let look: FernletFramedLook

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                section.header
                    .padding(.horizontal, 4)
                FernletFramedRows { section.content }
                    .buttonStyle(FernletRowButtonStyle())
                section.footer
                    .font(FernletFramedFont.note)
                    .foregroundStyle(look.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
    }
}

public extension View {
    /// One row of a framed list (`.listStyle(.plain)`), for a list that needs what only `List` does
    /// (drag to reorder, swipe actions): the rows together draw one framed card 16 pt in from the edges,
    /// the first with the top corners, the last with the bottom corners and the solid shadow, dotted
    /// rules between. Pass each row's place; without the look it changes nothing.
    ///
    /// ```swift
    /// ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
    ///     row(item).fernletFramedListRow(isFirst: index == 0, isLast: index == items.count - 1)
    /// }
    /// ```
    func fernletFramedListRow(isFirst: Bool, isLast: Bool) -> some View {
        modifier(FernletFramedListRowModifier(isFirst: isFirst, isLast: isLast))
    }
}

/// Implements ``SwiftUI/View/fernletFramedListRow(isFirst:isLast:)``.
struct FernletFramedListRowModifier: ViewModifier {
    let isFirst: Bool
    let isLast: Bool
    @Environment(\.fernletFramedLook) private var look

    func body(content: Content) -> some View {
        if let look {
            content
                .frame(minHeight: 54)
                .environment(\.fernletInFramedRow, true)
                .listRowInsets(EdgeInsets(top: 0, leading: 32, bottom: 0, trailing: 32))
                .listRowSeparator(.hidden)
                .listRowBackground(FramedListRowBackground(look: look, isFirst: isFirst, isLast: isLast))
        } else {
            content
        }
    }
}

/// One row's slice of the framed card: the whole card's outline drawn taller than the row and cut to it,
/// so a middle row shows only the side frames, the first the top, the last the bottom and the shadow.
private struct FramedListRowBackground: View {
    let look: FernletFramedLook
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius, style: .continuous)
        ZStack(alignment: .top) {
            shape.fill(look.paper)
                .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
                .background { if isLast { shape.fill(look.shadow).offset(y: 3) } }
                .padding(.top, isFirst ? 0 : -24)
                .padding(.bottom, isLast ? 3 : -24)
            if !isFirst { FernletDottedRule().padding(.horizontal, 2) }
        }
        .padding(.horizontal, 16)
        // Cuts the outline drawn past a middle row's edges; the last row keeps 3 pt for its shadow.
        .clipped()
    }
}
