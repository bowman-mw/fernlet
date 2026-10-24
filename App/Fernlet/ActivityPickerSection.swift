import SwiftUI
import FernletDomainModel
import HealthKitGateway
import FernletUI

/// Device-local memory of the last five workout types picked, backing ``ActivityPickerSection``'s
/// Recent chips.
///
/// The `BarcodeServingMemory` sidecar pattern: plain `UserDefaults`, never synced, never in the
/// snapshot. Exposed as a named seam so the store's wipe paths (`resetAll` / `deleteAllData`) can
/// clear it — otherwise opening Log activity on a wiped phone still shows the previous owner's
/// recent picks. The view's `@AppStorage` reads the same constant, so key and clear cannot drift.
enum RecentActivityTypeMemory {
    /// Frozen persisted token (a comma-joined `WorkoutActivityType` rawValue list) — never rename
    /// or localize; renaming strands every device's existing chips.
    static let defaultsKey = "fernlet.recentActivityTypes"

    /// Forgets the recent picks. A plain `UserDefaults` removal — no failure signal, so the wipe
    /// funnel reports no incomplete store for it.
    static func clearAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// The activity half of the workout sheets' Kind toggle: pick a `WorkoutActivityType`, then fill
/// its duration / distance / energy / effort fields.
///
/// 2026-08-21 redesign (MOVE-10): the nested 260pt inner ScrollView is gone. Before a type is
/// chosen the section shows six everyday-type chips plus the search, with results rendered inline
/// in the presenting sheet's ONE scroll surface; after a choice it collapses to the chosen row
/// with a "Change" action, exactly like the exercise picker, and the value fields (duration,
/// distance, effort — energy only behind the calories opt-in) sit directly beneath. Effort reads
/// its value in its label ("Effort · 5 of 10") over a comfort sentence and a moss track (MOVE-09).
///
/// Recent picks persist as a comma-joined raw-value list in `@AppStorage` (capped at five, most
/// recent first) and render as one-tap chips. Selecting a type seeds sensible defaults into
/// still-empty duration/effort fields; all value fields are bound to the presenting sheet
/// (``WorkoutSheet`` / ``WorkoutPlanSheet``), which owns the save.
struct ActivityPickerSection: View {
    @Binding var selectedActivityType: WorkoutActivityType?
    @Binding var duration: String
    @Binding var distance: String
    @Binding var energyKcal: String
    @Binding var effort: String
    /// Mirrors `settings.showCalories`, the same opt-in the macros card and nutrition label honor: a
    /// user who turned calories off shouldn't be asked for kcal on every activity log. Energy that
    /// arrives from Health is still stored — it just isn't asked for here.
    var showsEnergyField: Bool = false
    @AppStorage(RecentActivityTypeMemory.defaultsKey) private var recentActivityTypeRawValues = ""
    @State private var query = ""
    // 1g·AX3: numeric fields take a full row each at accessibility sizes — two side-by-side
    // numeric fields are the classic AX truncation.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// World build (`b3-workout-activity`): framed chips, rows and cards, and the wooden-handle slider.
    @Environment(\.fernletFramedLook) private var look

    /// The six everyday types offered as one-tap chips before anything is chosen (MOVE-10).
    private static let commonTypes: [WorkoutActivityType] = [
        .walking, .running, .cycling, .yoga, .swimmingPool, .hiking,
    ]

    private var recentActivityTypes: [WorkoutActivityType] {
        recentActivityTypeRawValues
            .split(separator: ",")
            .compactMap { WorkoutActivityType(rawValue: String($0)) }
    }

    private var results: [WorkoutActivityType] {
        // Eight inline results, mirroring the exercise picker — the presenting sheet's scroll is
        // the one scroll surface; typing narrows the catalog.
        Array(ActivityTypeCatalog.search(query).prefix(8))
    }

    private var effortValue: Binding<Double> {
        Binding(
            get: { Double(Int(effort) ?? 5) },
            set: { effort = String(Int($0.rounded())) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let selectedActivityType {
                chosenTypeRow(selectedActivityType)
                activityDetailFields(for: selectedActivityType)
            } else {
                pickerSurface
            }
        }
    }

    // MARK: Picker (no type chosen yet)

    /// Recent chips, the six common-type chips, the search, and the inline results — no nested
    /// scroll (MOVE-10).
    @ViewBuilder private var pickerSurface: some View {
        if !recentActivityTypes.isEmpty {
            SheetField("Recent") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(recentActivityTypes) { type in
                            activityChip(type, idPrefix: "activity.recent")
                        }
                    }
                }
            }
        }

        SheetField("Workout type") {
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 8) {
                    ForEach(Self.commonTypes) { type in
                        activityChip(type, idPrefix: "activity.common")
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.slate)
                    TextField("Search workout type", text: $query, prompt: .fieldPrompt("Search workout type"))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(false)
                        .accessibilityIdentifier("activity.search")
                }
                .sheetTextInput()

                LazyVStack(spacing: 6) {
                    ForEach(results) { type in
                        activityRow(type)
                    }
                }
            }
        }
    }

    @ViewBuilder private func activityChip(_ type: WorkoutActivityType, idPrefix: String) -> some View {
        if look != nil {
            // World build: a framed chip.
            Button { select(type) } label: { Label(type.displayName, systemImage: type.systemImage) }
                .buttonStyle(ChipButtonStyle(selected: false))
                .accessibilityIdentifier("\(idPrefix).\(type.rawValue)")
        } else {
            Button {
                select(type)
            } label: {
                Label(type.displayName, systemImage: type.systemImage)
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.bark)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(idPrefix).\(type.rawValue)")
        }
    }

    private func activityRow(_ type: WorkoutActivityType) -> some View {
        Button {
            select(type)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: type.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(look?.text ?? Color.slate)
                    .frame(width: 26)
                Text(type.displayName)
                    .font(.fernlet(.label))
                    .foregroundStyle(look?.text ?? Color.bark)
                Spacer()
            }
            .padding(12)
            .modifier(MoveInsetCardFrame(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("activity.row.\(type.rawValue)")
    }

    // MARK: Chosen row (type picked)

    /// The collapsed "Activity / Walking / <category>" row with its trailing Change — exactly the
    /// exercise picker's collapse (MOVE-10). Change reopens the picker surface.
    @ViewBuilder private func chosenTypeRow(_ type: WorkoutActivityType) -> some View {
        if look != nil {
            // World build (`b3-workout-activity`): the chosen activity is its own framed card.
            chosenTypeCard(type)
        } else {
            SheetField("Activity") { chosenTypeCard(type) }
        }
    }

    /// The chosen activity: its icon in a framed tile, its name over its category, and Change.
    private func chosenTypeCard(_ type: WorkoutActivityType) -> some View {
        HStack(spacing: 12) {
            activityIcon(type)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: type.displayName)
                    .font(look == nil ? .fernlet(.label) : MoveFont.rowTitle)
                    .foregroundStyle(look?.text ?? Color.bark)
                // The coarse category the log will file under. (The artboard's "Outdoor ·
                // counts toward daily movement" caption needs indoor/outdoor metadata the
                // activity catalog doesn't carry — recorded as a residual.)
                Text(verbatim: type.fernletCategory.displayName)
                    .font(look == nil ? .fernlet(.labelSmall) : FernletFramedFont.rowDetail)
                    .foregroundStyle(look?.dim ?? Color.slate)
            }
            Spacer(minLength: 8)
            Button("Change") {
                selectedActivityType = nil
                query = ""
            }
            .font(look == nil ? .fernlet(.label) : FernletFramedFont.sheetControl)
            .foregroundStyle(look?.link ?? Color.moss)
            .buttonStyle(.plain)
            .fernletTapTarget()
            .accessibilityIdentifier("activity.change")
        }
        .padding(12)
        .modifier(MoveInsetCardFrame(cornerRadius: look == nil ? 10 : 12))
    }

    /// The activity's icon: a pixel sprite in a framed tile under the World look where one is drawn
    /// (running, walking, hiking), its symbol in the tile otherwise; today's moss symbol without the look.
    @ViewBuilder private func activityIcon(_ type: WorkoutActivityType) -> some View {
        if let look {
            FernletIconTile(size: 44) {
                if let sprite = MoveActivitySprites.sprite(for: type) {
                    // The blue button's white sprites, drawn in the look's ink on the paper tile.
                    WorldSpriteView(sprite: sprite, scale: 3, tint: look.text)
                } else {
                    Image(systemName: type.systemImage)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(look.text)
                }
            }
            .accessibilityHidden(true)
        } else {
            Image(systemName: type.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.moss)
                .frame(width: 26)
        }
    }

    // MARK: Value fields

    /// Duration, distance, then effort — the first fields under the chosen type (MOVE-10) — with
    /// energy last, only behind the calories opt-in. The duration/distance pair unstacks to full
    /// rows at accessibility sizes (1g·AX3).
    private func activityDetailFields(for type: WorkoutActivityType) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            AdaptiveStack(spacing: 12, horizontalAlignment: .leading, verticalAlignment: .top) {
                SheetField("Duration (min)", namesControl: true) {
                    TextField("\(type.defaultDurationMinutes)", text: $duration,
                              prompt: .fieldPrompt("\(type.defaultDurationMinutes)"))
                        .keyboardType(.numberPad)
                        .sheetTextInput(font: .fernlet(.label))
                        .accessibilityIdentifier("activity.duration")
                }
                if type.expectsDistance {
                    // Typed in the device's units; the sheet stores miles (`WorkoutMeasurementEntry`).
                    SheetField(WorkoutMeasurementEntry.usesImperial ? "Distance (mi)" : "Distance (km)", namesControl: true) {
                        TextField("3.0", text: $distance, prompt: .fieldPrompt("3.0"))
                            .keyboardType(.decimalPad)
                            .sheetTextInput(font: .fernlet(.label))
                            .accessibilityIdentifier("activity.distance")
                    }
                }
            }

            effortField

            if showsEnergyField {
                SheetField("Energy (kcal)", namesControl: true) {
                    TextField("250", text: $energyKcal, prompt: .fieldPrompt("250"))
                        .keyboardType(.numberPad)
                        .sheetTextInput(font: .fernlet(.label))
                        .accessibilityIdentifier("activity.energy")
                }
            }
        }
    }

    /// Effort with its value read in the label ("Effort · 5 of 10") over the comfort sentence and
    /// a moss track (MOVE-09/MOVE-10) — the value never fights the thumb for attention.
    @ViewBuilder private var effortField: some View {
        if look != nil {
            // World build (`b3-workout-activity`): a framed card, the value in its section label, today's
            // description under it, and a framed slider with a wooden handle.
            FernletCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Effort · \(effortInt) of 10")
                    Text(effortDescription)
                        .font(FernletFramedFont.body)
                        .foregroundStyle(look?.dim ?? Color.slate)
                        .fernletWrappingText()
                    MoveFramedSlider(value: effortValue, range: 1...10, label: Text("Effort"),
                                     valueText: Text("\(effortInt) of 10"))
                        .accessibilityIdentifier("activity.effort")
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Effort · \(effortInt) of 10")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .tracking(0.8)
                    .textCase(.uppercase)
                Text(effortDescription)
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                // Tinted moss: this sheet is presented from the app's root, outside the
                // `mainInterface` tint scope, so an untinted Slider rendered iOS blue — the only
                // blue control in the app. The a11y label/value make it readable to VoiceOver,
                // which otherwise announced just "adjustable".
                Slider(value: effortValue, in: 1...10, step: 1)
                    .tint(Color.moss)
                    .accessibilityIdentifier("activity.effort")
                    .accessibilityLabel("Effort")
                    .accessibilityValue("\(effortInt) of 10")
            }
        }
    }

    private var effortInt: Int { Int(effort) ?? 5 }

    /// The plain-language read of the current effort — gentle, factual, never a grade.
    private var effortDescription: LocalizedStringKey {
        switch effortInt {
        case ...2: "Very easy — barely trying."
        case 3...4: "Easy — you could keep this up for a long while."
        case 5...6: "Comfortable — could hold a conversation."
        case 7...8: "Hard — talking takes effort."
        default: "All-out — nothing left in the tank."
        }
    }

    // MARK: Selection

    private func select(_ type: WorkoutActivityType) {
        selectedActivityType = type
        if duration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            duration = String(type.defaultDurationMinutes)
        }
        if effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            effort = "5"
        }
        updateRecentActivityTypes(with: type)
    }

    private func updateRecentActivityTypes(with type: WorkoutActivityType) {
        var rawValues = recentActivityTypeRawValues
            .split(separator: ",")
            .map(String.init)
        rawValues.removeAll { $0 == type.rawValue }
        rawValues.insert(type.rawValue, at: 0)
        recentActivityTypeRawValues = rawValues.prefix(5).joined(separator: ",")
    }
}
