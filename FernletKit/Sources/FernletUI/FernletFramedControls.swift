//
//  FernletFramedControls.swift
//  FernletUI
//
//  The framed controls and content pieces every World lane needs, drawn exactly as the approved kits
//  draw them (`kit-v3.css`, `kit-b2.css`, `kit-b3.css`): the dropdown, the segmented control, the
//  stepper, the notice box, the key-value row, the tag, the big time, the ring, the two-wide tile grid
//  and the framed icon tile. Each falls back to today's look when no framed look is set.
//

import SwiftUI

// MARK: - Dropdown

/// A framed dropdown (`.fld` with the ⌄ chevron, Batch 3's meal-type control): the chosen value on
/// raised paper in a 2-pt ink frame; a tap opens the system menu with every option and a check by the
/// chosen one. With `showsLabel` the label sits before it as a section label (the meal sheet's
/// "MEAL TYPE  [Dinner ⌄]" row); `fullWidth` spreads it across the row (`.fld` space-between).
///
/// ```swift
/// FernletDropdown("Meal type", selection: $mealType, options: MealType.allCases) { Text($0.displayName) }
/// ```
///
/// VoiceOver hears one button, "Meal type, Dinner". Changing the value ticks, as the app's own pickers
/// do. Without the look it is a system menu picker.
public struct FernletDropdown<Value: Hashable>: View {
    let label: Text
    @Binding var selection: Value
    let options: [Value]
    var showsLabel: Bool
    var fullWidth: Bool
    let title: (Value) -> Text
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameters:
    ///   - label: The control's name, harvested into the calling target's catalog.
    ///   - options: Every choice, in menu order.
    ///   - showsLabel: Draw the label before the dropdown as a section label.
    ///   - fullWidth: Spread the dropdown across its row.
    ///   - title: Each option's display text (never a raw token).
    public init(_ label: LocalizedStringKey, selection: Binding<Value>, options: [Value], showsLabel: Bool = true,
                fullWidth: Bool = false, title: @escaping (Value) -> Text) {
        self.label = Text(label)
        self._selection = selection
        self.options = options
        self.showsLabel = showsLabel
        self.fullWidth = fullWidth
        self.title = title
    }

    public var body: some View {
        if let look {
            // At accessibility sizes the label goes above and the dropdown takes the row, so neither
            // breaks a word in two.
            let stacked = dynamicTypeSize.isAccessibilitySize
            let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                 : AnyLayout(HStackLayout(spacing: 10))
            layout {
                if showsLabel {
                    SectionLabel(label).accessibilityHidden(true)
                    if !fullWidth && !stacked { Spacer(minLength: 0) }
                }
                Menu { picker } label: { chrome(look, wide: fullWidth || stacked) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(label)
                    .accessibilityValue(title(selection))
            }
        } else {
            picker.pickerStyle(.menu)
        }
    }

    /// The options, with a check by the chosen one.
    private var picker: some View {
        Picker(selection: ticking) {
            ForEach(options, id: \.self) { option in
                title(option).tag(option)
            }
        } label: {
            label
        }
    }

    /// The value on raised paper with the chevron (compact: 7/10 pt in; wide: `.fld`'s 13/14).
    private func chrome(_ look: FernletFramedLook, wide: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        return HStack(spacing: 8) {
            title(selection)
                .font(wide ? FernletFramedFont.field : FernletFramedFont.chip)
                .foregroundStyle(look.text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if wide { Spacer(minLength: 0) }
            FernletIcon(.chevronDown, scale: 2)
        }
        .padding(.horizontal, wide ? 14 : 10)
        .padding(.vertical, wide ? 13 : 7)
        .frame(maxWidth: wide ? .infinity : nil, minHeight: 36)
        .background(look.raised, in: shape)
        .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    /// The selection, ticking when a choice really changes it (report B6).
    private var ticking: Binding<Value> {
        Binding(get: { selection }, set: { choice in
            var current = selection
            FernletFeedback.system.select(choice, in: &current)
            selection = current
        })
    }
}

// MARK: - Segmented control

/// A framed segmented control (`.seg3`): equal segments in one 2-pt ink frame on raised paper, split by
/// ink rules, the chosen one filled with the accent. VoiceOver and Voice Control see the system
/// segmented picker it stands for. Without the look it is that system picker.
public struct FernletSegmentedPicker<Value: Hashable>: View {
    let label: Text
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> Text
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(_ label: LocalizedStringKey, selection: Binding<Value>, options: [Value],
                title: @escaping (Value) -> Text) {
        self.label = Text(label)
        self._selection = selection
        self.options = options
        self.title = title
    }

    public var body: some View {
        if let look {
            framed(look)
                .accessibilityRepresentation { system }
        } else {
            system
        }
    }

    /// The system picker: the fallback, and what assistive technology reads.
    private var system: some View {
        Picker(selection: $selection) {
            ForEach(options, id: \.self) { option in title(option).tag(option) }
        } label: {
            label
        }
        .pickerStyle(.segmented)
    }

    /// Side by side; one above the other at accessibility sizes, so no segment breaks a word in two.
    private func framed(_ look: FernletFramedLook) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            ForEach(options, id: \.self) { option in
                segment(option, look: look)
                    // The ink rule between segments, as long as the control is deep.
                    .overlay(alignment: stacked ? .top : .leading) {
                        if option != options.first {
                            look.ink.frame(width: stacked ? nil : FernletFramedLook.frameWidth,
                                           height: stacked ? FernletFramedLook.frameWidth : nil)
                        }
                    }
            }
        }
        // Its own height, never the container's: segments share the tallest one's height.
        .fixedSize(horizontal: false, vertical: true)
        .background(look.raised)
        .clipShape(shape)
        .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
        .background { shape.fill(look.shadow).offset(y: 2) }
    }

    private func segment(_ option: Value, look: FernletFramedLook) -> some View {
        let chosen = option == selection
        return Button {
            FernletFeedback.system.select(option, in: &selection)
        } label: {
            title(option)
                .font(FernletFramedFont.chip)
                .multilineTextAlignment(.center)
                .foregroundStyle(chosen ? look.onAccent : look.text)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .frame(minHeight: 40)
                .background(chosen ? look.accent : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Stepper

/// The stepper's arithmetic, apart from any view: one step up or down, kept inside its range.
nonisolated public enum FernletStepperMath {
    /// `value` moved by `step` (negative to go down), clamped to `range`.
    public static func stepped<V: Strideable>(_ value: V, by step: V.Stride, in range: ClosedRange<V>) -> V {
        min(max(value.advanced(by: step), range.lowerBound), range.upperBound)
    }

    /// Whether a step up (`step` > 0) or down from `value` would still move it.
    public static func canStep<V: Strideable>(_ value: V, by step: V.Stride, in range: ClosedRange<V>) -> Bool {
        stepped(value, by: step, in: range) != value
    }
}

/// A framed stepper (`.stepper`): − and + on raised paper in one 2-pt ink frame split by ink rules, with
/// the value between them when given. The label is its name, not drawn (the row says it). VoiceOver and
/// Voice Control get the system stepper it stands for (swipe up or down to adjust).
public struct FernletStepper: View {
    let label: Text
    let value: Text?
    let onDecrement: () -> Void
    let onIncrement: () -> Void
    var canDecrement: Bool
    var canIncrement: Bool
    @Environment(\.fernletFramedLook) private var look

    /// The general form: the caller owns the arithmetic.
    public init(_ label: LocalizedStringKey, value: Text? = nil, canDecrement: Bool = true, canIncrement: Bool = true,
                onDecrement: @escaping () -> Void, onIncrement: @escaping () -> Void) {
        self.label = Text(label)
        self.value = value
        self.canDecrement = canDecrement
        self.canIncrement = canIncrement
        self.onDecrement = onDecrement
        self.onIncrement = onIncrement
    }

    /// A stepper over a bound value, kept inside `range` (``FernletStepperMath``).
    public init<V: Strideable>(_ label: LocalizedStringKey, value: Binding<V>, in range: ClosedRange<V>,
                               step: V.Stride, display: Text? = nil) {
        self.init(label, value: display,
                  canDecrement: FernletStepperMath.canStep(value.wrappedValue, by: -step, in: range),
                  canIncrement: FernletStepperMath.canStep(value.wrappedValue, by: step, in: range),
                  onDecrement: { value.wrappedValue = FernletStepperMath.stepped(value.wrappedValue, by: -step, in: range) },
                  onIncrement: { value.wrappedValue = FernletStepperMath.stepped(value.wrappedValue, by: step, in: range) })
    }

    public var body: some View {
        if let look {
            framed(look)
                .accessibilityRepresentation { system }
        } else {
            HStack(spacing: 10) {
                if let value { value.font(.fernlet(.stat)).foregroundStyle(Color.bark) }
                system.labelsHidden()
            }
        }
    }

    /// The system stepper: the fallback, and what assistive technology reads.
    private var system: some View {
        Stepper { label } onIncrement: {
            if canIncrement { onIncrement() }
        } onDecrement: {
            if canDecrement { onDecrement() }
        }
        .modifier(StepperValue(value: value))
    }

    /// The stepper's spoken value, when it shows one.
    private struct StepperValue: ViewModifier {
        let value: Text?

        func body(content: Content) -> some View {
            if let value {
                content.accessibilityValue(value)
            } else {
                content
            }
        }
    }

    private func framed(_ look: FernletFramedLook) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        let rule = look.ink.frame(width: FernletFramedLook.frameWidth)
        return HStack(spacing: 0) {
            stepButton("\u{2212}", enabled: canDecrement, action: onDecrement, look: look)
            if let value {
                value
                    .font(FernletFramedFont.fieldBold)
                    .foregroundStyle(look.text)
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .frame(minWidth: 40, minHeight: 36)
                    // Both rules on the value, the tallest piece, so they run the control's full depth.
                    .overlay(alignment: .leading) { rule }
                    .overlay(alignment: .trailing) { rule }
            }
            stepButton("+", enabled: canIncrement, action: onIncrement, look: look)
                .overlay(alignment: .leading) { if value == nil { rule } }
        }
        .fixedSize()
        .background(look.raised)
        .clipShape(shape)
        .overlay(shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth))
    }

    private func stepButton(_ glyph: String, enabled: Bool, action: @escaping () -> Void,
                            look: FernletFramedLook) -> some View {
        Button(action: action) {
            Text(verbatim: glyph)
                .font(FernletFramedFont.stepperGlyph)
                .foregroundStyle(look.text)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

// MARK: - Notice, key-value row, tag

/// A notice box (`.notice3`): an icon and a line on raised paper in a 2-pt ink frame; `.warn` on the
/// warning fill (`.notice3.warn`). Inside a section it keeps its fill and drops the frame (the frame
/// rule, ``FernletFrameRule``). Not a control and not a card: it says something about the screen it
/// sits on ("No catalog matches.", "Goals are crafted entirely on your device").
public struct FernletNotice<Icon: View>: View {
    /// The notice's fill.
    public enum Tone: Sendable {
        case info, warn
    }

    let text: Text
    var tone: Tone
    let icon: Icon
    @Environment(\.fernletFramedLook) private var look

    /// - Parameter icon: Its leading glyph (a ``FernletIcon`` or one of the app's pixel sprites).
    public init(_ text: LocalizedStringKey, tone: Tone = .info, @ViewBuilder icon: () -> Icon) {
        self.text = Text(text)
        self.tone = tone
        self.icon = icon()
    }

    /// The `Text` form, for a line that is runtime data.
    public init(text: Text, tone: Tone = .info, @ViewBuilder icon: () -> Icon) {
        self.text = text
        self.tone = tone
        self.icon = icon()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
            text
                .font(FernletFramedFont.notice)
                .foregroundStyle(look?.text ?? Color.bark)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // The frame rule: framed on a page, its tint alone inside a section.
        .fernletFrameRulePiece(.note, fill: fill, cornerRadius: 10)
        .accessibilityElement(children: .combine)
    }

    private var fill: Color {
        switch tone {
        case .info: look?.raised ?? Color.cream
        case .warn: look?.warn ?? Color.terracotta.opacity(0.12)
        }
    }
}

public extension FernletNotice where Icon == EmptyView {
    /// A notice with no icon.
    init(_ text: LocalizedStringKey, tone: Tone = .info) {
        self.init(text, tone: tone) { EmptyView() }
    }
}

/// A key-value row (`.kv`): the key, then the value in bold at the end, on one baseline, with a dotted
/// rule above (pass `showsRule: false` for a card's first row). One element to VoiceOver.
public struct FernletKeyValueRow: View {
    let key: Text
    let value: Text
    var showsRule: Bool
    @Environment(\.fernletFramedLook) private var look

    public init(_ key: LocalizedStringKey, value: Text, showsRule: Bool = true) {
        self.key = Text(key)
        self.value = value
        self.showsRule = showsRule
    }

    /// The `Text` form, for a key that is runtime data.
    public init(key: Text, value: Text, showsRule: Bool = true) {
        self.key = key
        self.value = value
        self.showsRule = showsRule
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            key
                .foregroundStyle(look?.text ?? Color.bark)
                .frame(maxWidth: .infinity, alignment: .leading)
            value
                .font(FernletFramedFont.keyValueBold)
                .foregroundStyle(look?.text ?? Color.bark)
                .multilineTextAlignment(.trailing)
        }
        .font(FernletFramedFont.keyValue)
        // The frame rule: 10 pt above and below each row, a hairline between rows.
        .padding(.vertical, look == nil ? 6 : FernletFrameRule.rowSpacing)
        .overlay(alignment: .top) { if showsRule { FernletDottedRule() } }
        .accessibilityElement(children: .combine)
    }
}

/// A tag (`.ptag`): a short word in DM Sans bold 12 on wood in a 2-pt ink frame ("Catalog", "Rough
/// estimate"). Pass a `fill` for a coloured tag; its word then stays dark ink in both modes, as the kit
/// draws a light fill in dark mode.
public struct FernletTag: View {
    let text: Text
    var fill: Color?
    @Environment(\.fernletFramedLook) private var look

    public init(_ text: LocalizedStringKey, fill: Color? = nil) {
        self.text = Text(text)
        self.fill = fill
    }

    /// The `Text` form, for a word that is runtime data.
    public init(text: Text, fill: Color? = nil) {
        self.text = text
        self.fill = fill
    }

    /// The kit's dark ink on a light tag fill in either mode (`#3A2414`).
    static let inkOnLightFill = Color(.sRGB, red: 58 / 255, green: 36 / 255, blue: 20 / 255, opacity: 1)

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        text
            .font(FernletFramedFont.tag)
            .foregroundStyle(fill == nil ? (look?.text ?? Color.bark) : Self.inkOnLightFill)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(fill ?? look?.wood ?? Color.cream, in: shape)
            .overlay { if let look { shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth) } }
    }
}

// MARK: - Big time, ring

/// The big timer (`.bigtime`): Fraunces 64 in ink, tight tracking, steady digits. Pass a size for the
/// kit's 58- and 66-pt variants; it scales with Dynamic Type.
public struct FernletBigTime: View {
    let text: Text
    var size: CGFloat
    var alignment: TextAlignment
    @Environment(\.fernletFramedLook) private var look

    public init(_ text: Text, size: CGFloat = 64, alignment: TextAlignment = .center) {
        self.text = text
        self.size = size
        self.alignment = alignment
    }

    public var body: some View {
        text
            .font(.custom(FernletFontName.frauncesSemiBold, size: size, relativeTo: .largeTitle))
            .monospacedDigit()
            .tracking(-size * 0.02)
            .foregroundStyle(look?.text ?? Color.bark)
            .multilineTextAlignment(alignment)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The ring (`.ring3`): a 210-pt circle in a 3-pt ink frame with a solid 4-pt shadow, holding its content
/// in the middle (a rest timer's ``FernletBigTime``). Paper inside by default. It grows with the text
/// size, up to half again.
public struct FernletRing<Content: View>: View {
    var diameter: CGFloat
    var fill: Color?
    let content: Content
    @Environment(\.fernletFramedLook) private var look
    @ScaledMetric(relativeTo: .title) private var growth: CGFloat = 1

    public init(diameter: CGFloat = 210, fill: Color? = nil, @ViewBuilder content: () -> Content) {
        self.diameter = diameter
        self.fill = fill
        self.content = content()
    }

    public var body: some View {
        let size = diameter * min(max(growth, 1), 1.5)
        ZStack {
            Circle().fill(fill ?? look?.paper ?? Color.cream)
            content.padding(18)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(look?.ink ?? Color.bark.opacity(0.2), lineWidth: 3))
        .background { Circle().fill(look?.shadow ?? Color.clear).offset(y: 4) }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Tiles

/// The two-wide tile grid (`.tile4`, Batch 3): two equal columns 10 pt apart, one column at
/// accessibility text sizes so a tile's words never clip.
public struct FernletTileGrid<Content: View>: View {
    let content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    /// How many columns the grid draws at a text size.
    public static func columnCount(accessibilitySize: Bool) -> Int {
        accessibilitySize ? 1 : 2
    }

    public var body: some View {
        let count = Self.columnCount(accessibilitySize: dynamicTypeSize.isAccessibilitySize)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: count), spacing: 10) {
            content
        }
    }
}

/// A framed icon tile (`.icci`, `.icsq`, `.ingr .is`): an icon centred on raised paper in a 2-pt ink
/// frame with 9-pt corners, 42 pt by default (30 for an ingredient, 32 for a row's small action).
///
/// The frame rule (``FernletFrameRule``): inside a section a decorative tile sits bare, the icon alone
/// with no fill or frame; a tile that is a control's face (pass `isControl: true`: a row's + or ✕, a
/// swap, a camera's flash) keeps its frame everywhere, as buttons do.
public struct FernletIconTile<Content: View>: View {
    var size: CGFloat
    var fill: Color?
    var isControl: Bool
    let content: Content

    public init(size: CGFloat = 42, fill: Color? = nil, isControl: Bool = false, @ViewBuilder content: () -> Content) {
        self.size = size
        self.fill = fill
        self.isControl = isControl
        self.content = content()
    }

    public var body: some View {
        content
            .frame(width: size, height: size)
            .fernletFrameRulePiece(isControl ? .button : .iconSquare, fill: fill, cornerRadius: size < 36 ? 6 : 9)
    }
}
