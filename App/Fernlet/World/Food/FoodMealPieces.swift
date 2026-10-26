import FernletDomainModel
import FernletUI
import FoodCatalog
import SwiftUI

/// The meal-type dropdown every meal screen shares (Batch 3 draft 2, the owner's "meal type is one
/// dropdown"): Auto first, stating what it would choose ("Auto · Dinner"), then the six slots. Nil is
/// Auto. It replaced the seven chips on Log meal.
struct FoodMealTypeDropdown: View {
    @Binding var selection: MealType?
    /// The slot Auto would file the meal under now (`MealParser.classifyMealType`).
    let inferred: MealType

    var body: some View {
        FernletDropdown("Meal type", selection: $selection, options: Self.options) { option in
            if let option {
                Text(verbatim: option.displayName)
            } else {
                Text("Auto \u{00B7} \(inferred.displayName)")
            }
        }
        .accessibilityIdentifier("mealComposer.mealType")
    }

    /// Auto, then every slot in the domain's order.
    static let options: [MealType?] = [nil] + MealType.allCases.map { Optional($0) }
}

/// A field's caption and its content on a sheet: under the World look the framed section label
/// (`■ WHAT DID YOU EAT?`, Batch 3's sheets), today's ``SheetField`` caption without it.
struct FoodSheetField<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let content: () -> Content
    @Environment(\.fernletFramedLook) private var look

    init(_ label: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        if look != nil {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(label)
                content()
            }
        } else {
            SheetField(label) { content() }
        }
    }
}

/// The moss camera at the end of "What did you eat?" (`b3-meal` draft 2): one tap opens the camera, which
/// reads a barcode or a nutrition label by itself and otherwise takes a meal photo. 56 pt, the paper
/// camera sprite on the accent in an ink frame.
struct FoodCaptureCameraButton: View {
    let action: () -> Void

    /// Its spoken name; the button draws only the camera.
    static let label = LocalizedStringResource("mealComposer.camera", defaultValue: "Camera: scan a barcode or label, or take a meal photo",
                                               comment: "Log meal sheet: the camera button beside the description field. It reads barcodes and nutrition labels by itself, or takes a meal photo")

    var body: some View {
        Button(action: action) { FoodCaptureCameraFace() }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(Self.label))
            .accessibilityInputLabels([Text("Camera"), Text("Capture")])
            .accessibilityIdentifier("mealComposer.camera")
    }
}

/// What the capture camera button draws: the paper camera on the accent in an ink frame, 56 pt.
struct FoodCaptureCameraFace: View {
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        WorldSpriteView(sprite: FoodSprites.camera, scale: 3)
            .frame(width: 56, height: 56)
            .background(look?.accent ?? Color.mossFill, in: shape)
            .overlay { if let look { shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth) } }
            .background { if let look { shape.fill(look.shadow).offset(y: 3) } }
            .contentShape(Rectangle())
    }
}

/// One of Log meal's three small helpers (Recent, Import, By hand): a pixel icon and a word on raised
/// paper in an ink frame, sharing the row equally. `isOn` fills it with the accent (By hand while the
/// macro rows are open).
struct FoodHelperButton: View {
    let title: LocalizedStringKey
    let sprite: WorldSprite
    var isOn = false
    let action: () -> Void
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                WorldSpriteView(sprite: sprite, scale: 2, tint: isOn ? (look?.onAccent ?? Color.onMoss) : nil)
                Text(title)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ActionPillButtonStyle(isOn ? .primary : .secondary, size: .small))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// What a tap on Log meal's Import does (owner's form answer 43, 2026-10-25: Import shows always, and
/// asks for web-lookup consent on the tap when lookup is off). Import is a web lookup end to end, so
/// nothing leaves the phone until the person allows it here or in Settings.
nonisolated enum FoodImportTap: Equatable, Sendable {
    /// Web nutrition lookup is on: open Import.
    case open
    /// Lookup is off and AI features are on: ask first; allowing turns lookup on and opens Import, "Not
    /// now" keeps it off and stays on Log meal. The tap is the person's own request, so it asks even after
    /// an earlier "Not now".
    case askFirst
    /// AI features are off, which closes the whole web-nutrition lane (no consent can open it): the tap
    /// says which Settings switches turn it on (``aiOffNotice``) and opens nothing.
    case explainAIOff

    /// The tap's outcome under `settings`.
    static func resolve(for settings: FernletSettings) -> FoodImportTap {
        if settings.allowsWebNutritionLookup { return .open }
        return settings.aiStatus == .off ? .explainAIOff : .askFirst
    }

    /// What is off and where to turn it on, while AI features are off (Import's own notice too).
    static var aiOffNotice: String {
        String(localized: "productImport.notice.lookupOffWithAI",
               defaultValue: "Web nutrition lookup is off. Turn on AI features and Web nutrition lookup in Settings to search the web.",
               comment: "Import product screen: web nutrition lookup is off and AI features are off too. Names the two Settings switches.")
    }
}

/// A catalog match under "What did you eat?" (`b3-meal`): the food's name, its source as a tag (USDA,
/// Your foods), one serving and its grams, and a framed + (a ✓ once chosen). The whole row picks it.
struct FoodCatalogMatchRow: View {
    let foodItem: FoodItem
    var isChosen = false
    var onSelect: (() -> Void)?
    @Environment(\.fernletFramedLook) private var look

    /// A custom food typed as 3.4 g shows "3.4"; every whole-gram food reads as before.
    private var grams: (protein: String, carbs: String, fat: String) {
        let exact = foodItem.exactMacros
        return (MacroGramEntry.display(exact.protein), MacroGramEntry.display(exact.carbs),
                MacroGramEntry.display(exact.fat))
    }

    var body: some View {
        if let onSelect {
            Button(action: onSelect) { content }
                .buttonStyle(.plain)
                .accessibilityInputLabels([Text(verbatim: foodItem.name)])
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isSelected)
        }
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(foodItem.name)
                    .font(FoodFont.rowName)
                    .foregroundStyle(look?.text ?? Color.bark)
                    .fernletWrappingText()
                FlowLayout(spacing: 6) {
                    FernletTag(text: Text(verbatim: foodItem.dataSourceLabel))
                    servingLine
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            FernletIconTile(size: 36, isControl: true) {
                FernletIcon(isChosen ? .check : .plus, scale: 2)
            }
            .accessibilityHidden(true)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var servingLine: some View {
        Text("\(RecipeQuantityDisplay.display(foodItem.servingSize)) \(foodItem.servingUnit) · P\(grams.protein)g C\(grams.carbs)g F\(grams.fat)g")
            .font(FernletFramedFont.rowDetail)
            .foregroundStyle(look?.dim ?? Color.slate)
            .padding(.vertical, 3)
            // "P0g C25g F0g" is a glance format; spoken letter by letter it is noise.
            .accessibilityLabel(Text("\(RecipeQuantityDisplay.display(foodItem.servingSize)) \(foodItem.servingUnit), protein \(grams.protein) grams, carbs \(grams.carbs) grams, fat \(grams.fat) grams"))
            // Voice Control says the food's name, which the row's button carries too.
            .accessibilityInputLabels([Text(verbatim: foodItem.name)])
    }
}

/// One macro typed by hand (`b3-meal-macros` draft 2): the macro's coloured square and name, the amount
/// in moss you tap to type, and a framed − + stepper. Whole grams inside `range`, steps of 1.
struct FoodMacroAmountRow: View {
    let kind: FoodMacroKind
    @Binding var grams: Int
    let range: ClosedRange<Int>
    @State private var isEditing = false
    @State private var textValue = ""
    @FocusState private var isFocused: Bool
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        HStack(spacing: 12) {
            kind.colour
                .frame(width: 14, height: 14)
                .overlay(Rectangle().strokeBorder(look?.ink ?? Color.bark, lineWidth: 2))
                .accessibilityHidden(true)
            Text(name)
                .font(FoodFont.rowName)
                .foregroundStyle(look?.text ?? Color.bark)
            Spacer(minLength: 8)
            amount
            FernletStepper(name, value: $grams, in: range, step: 1)
                .accessibilityValue(Text(verbatim: "\(grams)g"))
        }
        .frame(minHeight: 44)
        .onChange(of: grams) { _, _ in
            if isEditing { isFocused = false; isEditing = false }
        }
    }

    /// The macro's name: the shipped "Protein", "Carbs", "Fat" keys.
    private var name: LocalizedStringKey {
        switch kind {
        case .protein: "Protein"
        case .carbs: "Carbs"
        case .fat: "Fat"
        }
    }

    /// The amount: a moss underlined figure, a number field once tapped.
    @ViewBuilder private var amount: some View {
        if isEditing {
            TextField(text: $textValue, prompt: .fieldPrompt(name)) { Text(name) }
                .keyboardType(.numberPad)
                .textContentType(.none)
                .multilineTextAlignment(.trailing)
                .font(FoodFont.fieldBold)
                .frame(width: 64)
                .focused($isFocused)
                .accessibilityLabel(Text(name))
                .onAppear { isFocused = true }
                .onChange(of: isFocused) { _, focused in if !focused { commit() } }
        } else {
            Button {
                textValue = "\(grams)"
                isEditing = true
            } label: {
                Text(verbatim: "\(grams)g")
                    .font(FoodFont.fieldBold)
                    .foregroundStyle(look?.link ?? Color.moss)
                    .underline()
                    .monospacedDigit()
            }
            .buttonStyle(.plain)
            .fernletTapTarget()
            .accessibilityLabel(Text(name))
            .accessibilityValue(Text(verbatim: "\(grams)g"))
            .accessibilityHint("Double-tap to type an amount.")
        }
    }

    private func commit() {
        let bounds = Double(range.lowerBound)...Double(range.upperBound)
        if let parsed = MacroGramEntry.parse(textValue, in: bounds, allowsDecimals: false) {
            grams = Macros.clampedInt(parsed)
        }
        isEditing = false
    }
}

/// One nutrition figure on Confirm product (`b3-product-review`): a framed card with the macro's
/// coloured square (none for calories), its name, and the value in bold at the end.
struct FoodProductMacroPill: View {
    let kind: FoodMacroKind?
    let title: LocalizedStringKey
    let value: LocalizedStringKey
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        FernletCard {
            HStack(spacing: 8) {
                if let kind {
                    kind.colour
                        .frame(width: 12, height: 12)
                        .overlay(Rectangle().strokeBorder(look?.ink ?? Color.bark, lineWidth: 2))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(FoodFont.rowName)
                    .foregroundStyle(look?.text ?? Color.bark)
                Spacer(minLength: 4)
                Text(value)
                    .font(FoodFont.rowNameBold)
                    .foregroundStyle(look?.text ?? Color.bark)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A total under a list of items ("Total", "New total"): the word, then the macros as coloured tags.
struct FoodMacroTotalRow: View {
    let title: LocalizedStringKey
    let macros: Macros
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        // One line while it fits; the tags drop under the word at the largest sizes.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                titleText
                Spacer(minLength: 0)
                FoodMacroTagRow(macros: macros, wraps: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                titleText
                FoodMacroTagRow(macros: macros)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var titleText: some View {
        Text(title)
            .font(FoodFont.rowName)
            .foregroundStyle(look?.text ?? Color.bark)
    }
}

/// A matched item on Check this meal and Adjust meal (`b3-meal-review`, `b3-meal-adjust` draft 2): its
/// name, the amount in a small framed field with its unit, a framed − + stepper, and its scaled macros as
/// coloured tags. A low-confidence match is framed in gold; `footer` holds the item's own actions.
struct FoodMatchedItemCard<Footer: View>: View {
    @Binding var component: MealComponentCorrectionInput
    var isLowConfidence = false
    @ViewBuilder let footer: () -> Footer
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The amount field's widest, growing with the text so "150" never truncates.
    @ScaledMetric(relativeTo: .body) private var amountWidth: CGFloat = 64

    /// The amount's step: 5 g for grams, a quarter of anything else.
    private var step: Double {
        component.unit == RecipeUnit.gram.rawValue ? 5 : 0.25
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        // The amount drops under the name at the largest sizes.
        let header = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        VStack(alignment: .leading, spacing: 10) {
            header {
                Text(component.name)
                    .font(FoodFont.rowName)
                    .foregroundStyle(look?.text ?? Color.bark)
                    .fernletWrappingText()
                    .frame(maxWidth: .infinity, alignment: .leading)
                amountField
            }
            controls
            footer()
        }
        .padding(14)
        .background(look?.raised ?? Color.parchment.opacity(0.7), in: shape)
        .overlay(shape.strokeBorder(frameColour, lineWidth: isLowConfidence ? 2.5 : FernletFramedLook.frameWidth))
    }

    /// Ink, or the gold that says "look at this one" without shouting (FOOD-05).
    private var frameColour: Color {
        isLowConfidence ? WorldPalette.carbs : (look?.ink ?? Color.clear)
    }

    /// The stepper beside the tags while they fit on one line; the tags drop under it otherwise (the
    /// largest sizes, a long figure).
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                stepper
                Spacer(minLength: 0)
                FoodMacroTagRow(macros: component.snapshot.macros, wraps: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                stepper
                FoodMacroTagRow(macros: component.snapshot.macros)
            }
        }
    }

    private var stepper: some View {
        FernletStepper("Amount of \(component.name)", value: $component.quantity, in: 0...2000, step: step)
            .accessibilityValue(Text(component.quantity, format: .number.precision(.fractionLength(0...1))))
    }

    /// The typeable amount, so a wrong amount can be corrected directly, then its unit in moss.
    private var amountField: some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        return HStack(spacing: 6) {
            TextField("Qty", value: $component.quantity, format: .number.precision(.fractionLength(0...1)),
                      prompt: .fieldPrompt("Qty"))
                .keyboardType(.decimalPad)
                .textContentType(.none)
                .multilineTextAlignment(.center)
                .font(FoodFont.fieldStrong)
                .foregroundStyle(look?.text ?? Color.bark)
                .frame(minWidth: 30, maxWidth: amountWidth)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(look?.paper ?? Color.cream, in: shape)
                .overlay { if let look { shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth) } }
                .fixedSize()
                .accessibilityLabel(Text("Amount of \(component.name)"))
            Text(verbatim: component.unit)
                .font(FoodFont.rowName)
                .foregroundStyle(look?.link ?? Color.moss)
        }
    }
}
