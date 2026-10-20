import SwiftUI
import FernletDomainModel
import FernletUI

/// "Weights I have" — the location editor's optional list of the dumbbells, kettlebells, bar and
/// plates a space has (``WorkoutWeightInventory``), below the equipment grid.
///
/// With weights set, the planner suggests only loads the space can make and adds reps before a jump
/// that is too big or missing (``WorkoutLoadEngine/loadCap(from:step:lowerBody:ladder:)``). Each block
/// shows only while its equipment is ticked: dumbbell presets (a home set, an adjustable pair, a full
/// rack) and pairs, kettlebell sizes, and a bar with plate pairs. Values are in the user's unit
/// (``WorkoutLoadContextBuilder/defaultUnit(for:)``) from the first edit on; an inventory set in the
/// other unit keeps its own.
///
/// Accessibility: every control is a button, chip or stepper named by its visible text ("15 lb",
/// "Home set 5–25 lb", "45 lb plates") — Voice Control answers to that word — with the selected
/// trait on chips that are on; a pair's chip removes it, so VoiceOver hears "Remove 15 lb" while
/// "15 lb" still works by voice. Chips wrap (one per row at accessibility sizes), and the entry and
/// plate rows stack at accessibility sizes.
struct WorkoutWeightInventorySection: View {
    @Binding var weights: WorkoutWeightInventory
    /// The space's coarse capabilities: which blocks show.
    let capabilities: Set<Equipment>
    /// The user's unit, used while nothing is set yet.
    let userUnit: LoadUnit

    /// Whether the space has any equipment this section describes.
    static func applies(to location: WorkoutLocation) -> Bool {
        location.has(.dumbbell) || location.has(.kettlebell) || location.has(.barbell)
    }

    /// The inventory as the blocks edit it: an empty one takes the user's unit, so the first value
    /// added is in that unit.
    private var editable: Binding<WorkoutWeightInventory> {
        Binding(
            get: {
                guard weights.isEmpty else { return weights }
                var fresh = weights
                fresh.unit = userUnit
                return fresh
            },
            set: { weights = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Weights I have")
                    .font(.fernlet(.labelSmall))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.slate)
                    .accessibilityAddTraits(.isHeader)
                Text("Optional. With these set, Fernlet suggests only weights you can make here, and adds reps before a big jump.",
                     comment: "Location editor: what listing the weights a space has does")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            if capabilities.contains(.dumbbell) { WeightDumbbellBlock(weights: editable) }
            if capabilities.contains(.kettlebell) { WeightKettlebellBlock(weights: editable) }
            if capabilities.contains(.barbell) { WeightBarbellBlock(weights: editable) }
        }
    }
}

// MARK: - Formatting

/// Weights as the editor draws them: the runner's measurement style (the locale's number format and
/// unit abbreviation, "62,5 kg"), with two decimals allowed so a 1.25 kg plate reads as itself.
enum WeightInventoryText {
    static func unitMass(_ unit: LoadUnit) -> UnitMass {
        unit == .kg ? .kilograms : .pounds
    }

    /// "15 lb", "1.25 kg".
    static func weight(_ value: Double, _ unit: LoadUnit) -> String {
        Measurement(value: value, unit: unitMass(unit)).formatted(
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...2)))
        )
    }

    /// "5–25 lb".
    static func range(_ low: Double, _ high: Double, _ unit: LoadUnit) -> String {
        let lowText = low.formatted(.number.precision(.fractionLength(0...2)))
        return "\(lowText)–\(weight(high, unit))"
    }

    /// "lb" or "kg", in the reader's language.
    static func symbol(_ unit: LoadUnit) -> String {
        let formatter = MeasurementFormatter()
        formatter.unitStyle = .short
        return formatter.string(from: unitMass(unit))
    }
}

// MARK: - Blocks

/// A block's title (a heading for VoiceOver's rotor) and its one-line caption.
private struct WeightBlockTitle: View {
    let title: LocalizedStringKey
    let caption: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
                .accessibilityAddTraits(.isHeader)
            Text(caption)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
    }
}

/// Dumbbells: the three presets, the pairs owned (each chip removes its pair), and a custom weight.
private struct WeightDumbbellBlock: View {
    @Binding var weights: WorkoutWeightInventory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WeightBlockTitle(title: "Dumbbells", caption: "Pairs, by the weight of one dumbbell.")
            WeightChipFlow {
                ForEach(WorkoutWeightPresets.Dumbbells.allCases, id: \.self) { preset in
                    Button { weights.setDumbbells(preset.weights(in: weights.unit)) } label: { label(preset) }
                        .buttonStyle(ChipButtonStyle(selected: weights.dumbbells == preset.weights(in: weights.unit)))
                        .accessibilityHint(Text("Replaces your dumbbell list"))
                        .accessibilityIdentifier("workout.location.weights.dumbbells.\(preset.rawValue)")
                }
            }
            if !weights.dumbbells.isEmpty {
                WeightChipFlow {
                    ForEach(weights.dumbbells, id: \.self) { weight in
                        WeightRemoveChip(text: WeightInventoryText.weight(weight, weights.unit),
                                         identifier: "workout.location.weights.dumbbell") {
                            weights.removeDumbbell(weight)
                        }
                    }
                    Button("Clear dumbbells") { weights.setDumbbells([]) }
                        .buttonStyle(ChipButtonStyle(selected: false))
                        .accessibilityIdentifier("workout.location.weights.dumbbells.clear")
                }
            }
            WeightEntryRow(title: "Dumbbell weight", addTitle: "Add dumbbell", unit: weights.unit,
                           identifier: "workout.location.weights.dumbbells.add") { weights.addDumbbell($0) }
        }
    }

    private func label(_ preset: WorkoutWeightPresets.Dumbbells) -> Text {
        let values = preset.weights(in: weights.unit)
        let low = values.first ?? 0
        let high = values.last ?? 0
        switch preset {
        case .homeSet: return Text("Home set \(WeightInventoryText.range(low, high, weights.unit))")
        case .adjustable: return Text("Adjustable to \(WeightInventoryText.weight(high, weights.unit))")
        case .fullRack: return Text("Rack \(WeightInventoryText.range(low, high, weights.unit))")
        }
    }
}

/// Kettlebells: the common sizes and any owned ones as on/off chips, and a custom weight.
private struct WeightKettlebellBlock: View {
    @Binding var weights: WorkoutWeightInventory

    /// The standard sizes in this unit plus any owned size that isn't one, lightest first.
    private var sizes: [Double] {
        let standard = WorkoutWeightPresets.kettlebells(weights.unit)
        let extra = weights.kettlebells.filter { owned in !standard.contains { abs($0 - owned) < 0.005 } }
        return (standard + extra).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WeightBlockTitle(title: "Kettlebells", caption: "Tap each size you have.")
            WeightChipFlow {
                ForEach(sizes, id: \.self) { size in
                    Button { toggle(size) } label: {
                        Text(verbatim: WeightInventoryText.weight(size, weights.unit))
                    }
                    .buttonStyle(ChipButtonStyle(selected: weights.ownsKettlebell(size)))
                    .accessibilityIdentifier("workout.location.weights.kettlebell")
                }
                if !weights.kettlebells.isEmpty {
                    Button("Clear kettlebells") { weights.setKettlebells([]) }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .accessibilityIdentifier("workout.location.weights.kettlebells.clear")
                }
            }
            WeightEntryRow(title: "Kettlebell weight", addTitle: "Add kettlebell", unit: weights.unit,
                           identifier: "workout.location.weights.kettlebells.add") { weights.addKettlebell($0) }
        }
    }

    /// Adds a size not owned, removes one that is.
    private func toggle(_ size: Double) {
        guard weights.ownsKettlebell(size) else {
            weights.addKettlebell(size)
            return
        }
        weights.removeKettlebell(size)
    }
}

/// The barbell: which bar, how many pairs of each plate, and the loads they make.
private struct WeightBarbellBlock: View {
    @Binding var weights: WorkoutWeightInventory

    /// The standard bars in this unit plus the owned one if it isn't one of them.
    private var bars: [Double] {
        let standard = WorkoutWeightPresets.bars(weights.unit)
        guard let bar = weights.barWeight, !standard.contains(where: { abs($0 - bar) < 0.005 }) else { return standard }
        return standard + [bar]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WeightBlockTitle(title: "Barbell", caption: "The bar, and how many pairs of each plate.")
            WeightChipFlow {
                ForEach(bars, id: \.self) { bar in
                    Button { weights.setBar(bar) } label: {
                        Text("\(WeightInventoryText.weight(bar, weights.unit)) bar")
                    }
                    .buttonStyle(ChipButtonStyle(selected: weights.barWeight == bar))
                    .accessibilityIdentifier("workout.location.weights.bar")
                }
            }
            ForEach(WorkoutWeightPresets.plates(weights.unit), id: \.self) { plate in
                WeightPlateRow(plate: plate, unit: weights.unit, count: Binding(
                    get: { weights.pairs(of: plate) },
                    set: { weights.setPairs($0, of: plate) }
                ))
            }
            if let low = weights.barbellTotals.first, let high = weights.barbellTotals.last {
                Text("Loads you can make: \(WeightInventoryText.range(low, high, weights.unit))")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                Button("Clear barbell") { weights.clearBarbell() }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .accessibilityIdentifier("workout.location.weights.barbell.clear")
            }
        }
    }
}

// MARK: - Controls

/// Chips that wrap onto new rows (``FlowLayout``) — and, at accessibility sizes, one chip per row at
/// the full width, so a long label ("Adjustable to 52.5 lb") wraps inside its chip instead of
/// running off the screen.
private struct WeightChipFlow<Content: View>: View {
    let content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(FlowLayout(spacing: 8))
        layout { content }
    }
}

/// An owned weight as a chip that removes it: drawn "15 lb ×", heard as "Remove 15 lb", and named
/// by voice either way.
private struct WeightRemoveChip: View {
    let text: String
    let identifier: String
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 5) {
                Text(verbatim: text)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(ChipButtonStyle(selected: true))
        .accessibilityLabel(Text("Remove \(text)"))
        .accessibilityInputLabels([Text(verbatim: text), Text("Remove \(text)")])
        .accessibilityIdentifier(identifier)
    }
}

/// One plate size's pair count: a stepper named "45 lb plates", valued "2 pairs" — the drawn title
/// and count are hidden from VoiceOver because the stepper says both. The label moves above the
/// stepper at accessibility sizes so neither is squeezed.
private struct WeightPlateRow: View {
    let plate: Double
    let unit: LoadUnit
    @Binding var count: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var title: Text { Text("\(WeightInventoryText.weight(plate, unit)) plates") }
    private var value: Text { Text("^[\(count) pair](inflect: true)") }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    title.font(.fernlet(.label)).foregroundStyle(Color.bark).fernletWrappingText()
                        .accessibilityHidden(true)
                    value.font(.fernlet(.stat)).foregroundStyle(Color.slate)
                        .accessibilityHidden(true)
                    stepper.labelsHidden()
                }
            } else {
                HStack(spacing: 10) {
                    title.font(.fernlet(.label)).foregroundStyle(Color.bark)
                        .accessibilityHidden(true)
                    Spacer(minLength: 8)
                    value.font(.fernlet(.stat)).foregroundStyle(Color.slate)
                        .accessibilityHidden(true)
                    stepper.labelsHidden()
                }
            }
        }
    }

    private var stepper: some View {
        Stepper(value: $count, in: 0...WorkoutWeightPresets.maxPairsPerPlate) { title }
            .accessibilityValue(value)
            .accessibilityIdentifier("workout.location.weights.plate")
    }
}

/// A custom weight: a number field in the space's unit and its Add button. The return key adds too;
/// Add stays off until the text reads as a weight.
private struct WeightEntryRow: View {
    let title: LocalizedStringKey
    let addTitle: LocalizedStringKey
    let unit: LoadUnit
    let identifier: String
    /// Adds the weight; false when the list is full.
    let onAdd: (Double) -> Bool
    @State private var draft = ""
    @State private var full = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var parsed: Double? {
        LocaleTolerantNumber.double(from: draft).flatMap { $0 > 0 && $0 <= WorkoutWeightInventory.maxLoad ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                TextField(title, text: $draft, prompt: .fieldPrompt(title))
                    .keyboardType(.numbersAndPunctuation)
                    .submitLabel(.done)
                    .onSubmit(add)
                    .sheetTextInput(font: .fernlet(.label))
                    .accessibilityIdentifier("\(identifier).field")
                Text(verbatim: WeightInventoryText.symbol(unit))
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.slate)
                    .accessibilityHidden(true)
                Button(addTitle, action: add)
                    .buttonStyle(ChipButtonStyle(selected: true))
                    .disabled(parsed == nil)
                    .accessibilityIdentifier(identifier)
            }
            if full {
                Label { Text("That list is full. Remove one to add another.") } icon: { Image(systemName: "exclamationmark.circle") }
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
    }

    private func add() {
        guard let value = parsed else { return }
        full = !onAdd(value)
        if !full { draft = "" }
    }
}
