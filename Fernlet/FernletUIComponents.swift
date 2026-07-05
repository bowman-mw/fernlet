//
//  FernletUIComponents.swift
//  Fernlet
//
//  Created by Coding Assistant on 5/17/26.
//

import SwiftUI
import FernletDomainModel
import PrivateHealthStore

extension Color {
    static let parchment = Color(UIColor { trait in
        FernletThemePalette.current(for: trait.userInterfaceStyle).background
    })
    static let cream = Color(UIColor { trait in
        FernletThemePalette.current(for: trait.userInterfaceStyle).box
    })
    static let bark = Color(UIColor { trait in
        FernletThemePalette.current(for: trait.userInterfaceStyle).primaryText
    })
    static let slate = Color(UIColor { trait in
        FernletThemePalette.current(for: trait.userInterfaceStyle).secondaryText
    })
    static let moss = Color(
        light: Color(red: 0.369, green: 0.518, blue: 0.302),
        dark:  Color(red: 0.498, green: 0.690, blue: 0.412)
    )
    static let fern = Color(
        light: Color(red: 0.447, green: 0.639, blue: 0.392),
        dark:  Color(red: 0.561, green: 0.753, blue: 0.467)
    )
    static let goldenrod = Color(
        light: Color(red: 0.824, green: 0.592, blue: 0.231),
        dark:  Color(red: 0.878, green: 0.663, blue: 0.329)
    )
    static let softTaupe = Color(
        light: Color(red: 0.721, green: 0.658, blue: 0.572),
        dark:  Color(red: 0.639, green: 0.588, blue: 0.506)
    )
    static let dustyRose = Color(
        light: Color(red: 0.714, green: 0.439, blue: 0.451),
        dark:  Color(red: 0.847, green: 0.549, blue: 0.561)
    )
    static let terracotta = Color(
        light: Color(red: 0.724, green: 0.329, blue: 0.239),
        dark:  Color(red: 0.839, green: 0.459, blue: 0.345)
    )
    static let sun = Color(
        light: Color(red: 0.922, green: 0.710, blue: 0.318),
        dark:  Color(red: 0.949, green: 0.761, blue: 0.408)
    )
}

extension Color {
    /// Resolves to `light` in light mode, `dark` in dark mode.
    init(light: Color, dark: Color) {
        self.init(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

extension View {
    /// Tags a screen or sheet root with a stable, queryable accessibility identifier for
    /// UX appearance tests, while keeping every descendant element individually
    /// accessible (`.contain`). Shipping accessibility identifiers is harmless for users.
    func uxScreenAnchor(_ identifier: String) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }
}

enum FernletTab: String, CaseIterable, Hashable, Identifiable {
    case home
    case food
    case move
    case social
    case personal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .food: "Food"
        case .move: "Move"
        case .social: "Friends"
        case .personal: "Private"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "leaf.fill"
        case .food: "fork.knife"
        case .move: "figure.walk"
        case .social: "person.2.fill"
        case .personal: "lock.fill"
        }
    }

    var label: Label<Text, Image> {
        Label(title, systemImage: systemImage)
    }

    var next: FernletTab? {
        guard let index = Self.allCases.firstIndex(of: self) else { return nil }
        let nextIndex = Self.allCases.index(after: index)
        return nextIndex < Self.allCases.endIndex ? Self.allCases[nextIndex] : nil
    }

    var previous: FernletTab? {
        guard let index = Self.allCases.firstIndex(of: self), index > Self.allCases.startIndex else { return nil }
        let previousIndex = Self.allCases.index(before: index)
        return Self.allCases[previousIndex]
    }
}

enum FernletSheet: Identifiable {
    case meal
    case recipe
    case water
    case sleep
    case journal
    case quickExercise
    case workout
    case workoutSuggestion
    case goals
    case hygiene
    case settings
    case recipeBook
    case trends
    case stressExplainer
    /// Calm first-aid tools (breathing / grounding / worry box); the optional tool deep-links
    /// straight into one of them (gentle-offer cards use it).
    case firstAid(FirstAidTool?)
    case logPeriod(targetDate: Date?, editingEntry: CycleDayEntry?)
    case logIntimacy
    case editRecipe(RecipeDefinition)
    case editSavedRecipe(RecipeDefinition)

    var id: String {
        switch self {
        case .meal: "meal"
        case .recipe: "recipe"
        case .water: "water"
        case .sleep: "sleep"
        case .journal: "journal"
        case .quickExercise: "quickExercise"
        case .workout: "workout"
        case .workoutSuggestion: "workoutSuggestion"
        case .goals: "goals"
        case .hygiene: "hygiene"
        case .settings: "settings"
        case .recipeBook: "recipeBook"
        case .trends: "trends"
        case .stressExplainer: "stressExplainer"
        case .firstAid: "firstAid"
        case .logPeriod: "logPeriod"
        case .logIntimacy: "logIntimacy"
        case .editRecipe(let r): "editRecipe-\(r.id)"
        case .editSavedRecipe(let r): "editSavedRecipe-\(r.id)"
        }
    }
}

struct ScreenHeader: View {
    var title: String
    var subtitle: String
    var subtitleFirst = false
    /// Optional stable accessibility identifier so UX appearance tests can anchor a
    /// screen's header (e.g. "screen.home"). Empty when unset — a no-op for users.
    var identifier: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if subtitleFirst { subtitleView }
            Text(title)
                .font(.system(size: 36, weight: .bold, design: .serif))
                .foregroundStyle(Color.bark)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            if !subtitleFirst { subtitleView }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier ?? "")
    }

    private var subtitleView: some View {
        Text(subtitle)
            .font(.system(size: subtitleFirst ? 13 : 17, weight: .medium, design: .serif).italic())
            .foregroundStyle(Color.slate)
            .lineLimit(2)
            .minimumScaleFactor(0.82)
    }
}

struct HeaderActionButton: View {
    var title: String?
    var systemImage: String?
    var action: () -> Void

    init(title: String? = nil, systemImage: String? = nil, action: @escaping () -> Void) {
        assert(title != nil || systemImage != nil, "header action needs title or image")
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.title3.weight(.semibold))
                }
                if let title {
                    Text(title)
                        .font(.headline.weight(.semibold))
                }
            }
            .foregroundStyle(Color.bark)
            .frame(minWidth: title == nil ? 58 : 72, minHeight: 58)
            .padding(.horizontal, title == nil ? 0 : 10)
            .background(Color.cream.opacity(0.9), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.bark.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title ?? systemImage ?? "Action")
    }
}

struct PolaroidTile: View {
    var color: Color
    var caption: String
    var rotation: Double
    var imageData: Data? = nil
    var imageWidth: CGFloat = 98
    var imageHeight: CGFloat = 86

    var body: some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: imageWidth, height: imageHeight)
                .overlay {
                    if let imageData, let image = UIImage(data: imageData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(caption)
                .font(.system(size: 11, design: .serif).italic())
                .foregroundStyle(Color.slate.opacity(0.58))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.top, 7)
        .padding(.bottom, 14)
        .background(Color.cream.opacity(0.82), in: RoundedRectangle(cornerRadius: 4))
        .shadow(color: Color.bark.opacity(0.08), radius: 12, x: 0, y: 6)
        .rotationEffect(.degrees(rotation))
    }
}

extension View {
    func fernletSheetStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Color.parchment)
            .tint(Color.moss)
    }

    func fernletWrappingText() -> some View {
        self
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }

    func sheetTextInput() -> some View {
        self
            .textInputAutocapitalization(.sentences)
            .autocorrectionDisabled(false)
            .textContentType(.none)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }
}

// MARK: - Sheet Layout Components

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct SheetField<Content: View>: View {
    var label: String
    var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.slate)
                .tracking(0.8)
            content
        }
    }
}

struct ChipButtonStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? Color.parchment : Color.bark)
            .background(
                selected ? Color.bark : Color.cream,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.bark.opacity(selected ? 0 : 0.12), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1.0)
    }
}

struct SheetTextEditor: View {
    @Binding var text: String
    var placeholder: String
    var minHeight: CGFloat = 120

    // TextEditor (UITextView) has intrinsic insets: 5pt horizontal (lineFragmentPadding)
    // and 8pt top (textContainerInset). External padding of (9h, 6v) makes the text
    // land at 9+5=14pt horizontal and 6+8=14pt vertical — matching .padding(14) on
    // the placeholder so cursor and placeholder text are perfectly aligned.
    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(Color.slate.opacity(0.45))
                    .padding(14)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .frame(minHeight: minHeight)
                .scrollContentBackground(.hidden)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
                .textContentType(.none)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
        }
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.bark.opacity(0.10), lineWidth: 1))
    }
}

struct HubSectionPicker<Section: Hashable>: View {
    var sections: [Section]
    @Binding var selection: Section
    var label: (Section) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(sections.indices, id: \.self) { index in
                let section = sections[index]
                let isSelected = selection == section
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        selection = section
                    }
                } label: {
                    Text(label(section))
                        .font(.subheadline.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.bark : Color.slate)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            isSelected ? Color.cream : Color.clear,
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                        )
                        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isSelected)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.parchment)
    }
}

extension View {
    func fernletTabBarCompaction(_ isCompact: Binding<Bool>, resetToken: Binding<Int>) -> some View {
        modifier(FernletTabBarCompactionModifier(isCompact: isCompact, resetToken: resetToken))
    }
}

private struct FernletTabBarCompactionModifier: ViewModifier {
    @Binding var isCompact: Bool
    @Binding var resetToken: Int
    @State private var scrollPosition = ScrollPosition(edge: .top)

    func body(content: Content) -> some View {
        content
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let scrollableOverflow = geometry.contentSize.height - geometry.containerSize.height
                return scrollableOverflow > 24 && geometry.contentOffset.y > geometry.contentInsets.top + 24
            } action: { _, shouldCompact in
                guard isCompact != shouldCompact else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    isCompact = shouldCompact
                }
            }
            .onChange(of: resetToken) { _, _ in
                scrollPosition.scrollTo(edge: .top)
                isCompact = false
            }
            .onDisappear {
                isCompact = false
            }
    }
}

struct SheetSaveBar: View {
    var label: String = "Save"
    var disabled: Bool = false
    var action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(label, action: action)
                .buttonStyle(.plain)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(disabled ? Color.moss.opacity(0.4) : Color.moss, in: RoundedRectangle(cornerRadius: 16))
                .disabled(disabled)
        }
        .padding(20)
        .background(Color.parchment)
    }
}
