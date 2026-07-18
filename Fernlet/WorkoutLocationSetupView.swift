import SwiftUI
import FernletDomainModel

/// Location creator + equipment selection, per the design: pick where you train (saved locations or
/// a preset template), then check off the equipment that's there in a categorized grid. Equipment is
/// stored granularly and mapped to coarse capabilities the planning engine reasons about.
struct WorkoutLocationSetupView: View {
    @Environment(\.dismiss) private var dismiss
    var store: FernletStore

    private enum Step { case location, equipment }

    @State private var step: Step = .location
    @State private var locations: [WorkoutLocation]
    @State private var activeID: UUID
    @State private var editingIndex: Int?
    @State private var addingCustom = false
    @State private var customName = ""
    @State private var pendingDestructiveAction: DestructiveConfirmation?

    init(store: FernletStore) {
        self.store = store
        _locations = State(initialValue: store.settings.workoutLocations)
        _activeID = State(initialValue: store.settings.activeWorkoutLocation.id)
    }

    private let twoColumns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 2)
    private let threeColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        Group {
            switch step {
            case .location: locationStep
            case .equipment: equipmentStep
            }
        }
        .background(Color.parchment)
        .destructiveConfirmation($pendingDestructiveAction)
    }

    // MARK: - Location step

    private var locationStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Where will you train?")
                            .font(.fernlet(.displayMedium))
                            .foregroundStyle(Color.bark)
                        Text("So I can plan around what's actually there.")
                            .font(.fernlet(.bubble))
                            .foregroundStyle(Color.slate)
                    }

                    if locations.isEmpty == false {
                        sectionHeader("Your locations")
                        LazyVGrid(columns: twoColumns, spacing: 14) {
                            ForEach(Array(locations.enumerated()), id: \.element.id) { index, location in
                                savedLocationCard(location, index: index)
                            }
                        }
                    }

                    sectionHeader("Add a location")
                    LazyVGrid(columns: twoColumns, spacing: 14) {
                        ForEach(LocationTemplate.all) { template in
                            templateCard(template)
                        }
                        addLocationCard
                    }

                    if addingCustom {
                        HStack(spacing: 8) {
                            TextField("Location name", text: $customName)
                                .sheetTextInput()
                            Button("Add") { addCustomLocation() }
                                .buttonStyle(ChipButtonStyle(selected: true))
                                .disabled(customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Done") {
                store.setWorkoutLocations(locations, activeID: activeID)
                dismiss()
            }
        }
    }

    private func savedLocationCard(_ location: WorkoutLocation, index: Int) -> some View {
        let isActive = location.id == activeID
        return Button {
            activeID = location.id
            store.setWorkoutLocations(locations, activeID: location.id)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.moss)
                    Spacer()
                    // Delete used to be context-menu-only — a long-press with no affordance, sitting next
                    // to a clearly visible pencil, so it read as "you can edit but not delete".
                    if locations.count > 1 {
                        Button { confirmRemoveLocation(index: index) } label: {
                            Image(systemName: "trash")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.terracotta)
                                .padding(6)
                                .background(Color.parchment.opacity(0.8), in: Circle())
                                // The glyph stays ~26pt; the frame + contentShape expand only the tap
                                // target to Apple's 44pt minimum, so a near-miss no longer falls through
                                // to the card button underneath and navigates instead of deleting.
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete \(location.name)")
                        .accessibilityIdentifier("workout.location.delete")
                    }
                    Button {
                        // Edit equipment/name only — deliberately does NOT set `activeID`. It used to,
                        // and because a later delete persists `activeID`, peeking at one location and
                        // then deleting an unrelated one silently switched the user's active gym.
                        editingIndex = index
                        step = .equipment
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.slate)
                            .padding(6)
                            .background(Color.parchment.opacity(0.8), in: Circle())
                            // Same 44pt tap target as its sibling trash chip.
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit \(location.name)")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(location.name)
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(Color.bark)
                    Text("\(location.ownedEquipment.count) items\(isActive ? " · active" : "")")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(isActive ? Color.moss : Color.slate)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .padding(16)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(isActive ? Color.moss.opacity(0.5) : Color.bark.opacity(0.07), lineWidth: isActive ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workout.location.card")
        .contextMenu {
            if locations.count > 1 {
                Button(role: .destructive) { confirmRemoveLocation(index: index) } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }

    private func templateCard(_ template: LocationTemplate) -> some View {
        Button { addFromTemplate(template) } label: {
            VStack(alignment: .leading, spacing: 14) {
                LocationGlyph(templateID: template.id, fallbackSystemImage: template.systemImage, size: 32)
                    .foregroundStyle(Color.moss)
                VStack(alignment: .leading, spacing: 3) {
                    Text(template.name)
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(Color.bark)
                    Text(template.subtitle)
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .padding(16)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.bark.opacity(0.07), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var addLocationCard: some View {
        Button { addingCustom.toggle() } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.moss)
                    .frame(width: 34, height: 34)
                    .background(Color.moss.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add location")
                        .font(.fernlet(.headerMedium))
                        .foregroundStyle(Color.bark)
                    Text("A new place you visit")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .padding(16)
            .background(Color.cream.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                    .foregroundStyle(Color.bark.opacity(0.22))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Equipment step

    private var equipmentStep: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button { commitEdits(); step = .location } label: {
                        Image(systemName: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.bark)
                            .frame(width: 34, height: 34)
                            .background(Color.cream, in: RoundedRectangle(cornerRadius: 11))
                            // Visual stays 34pt; only the tap target grows to the 44pt minimum.
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to locations")
                    .accessibilityIdentifier("workout.location.back")
                    // Editable, not a label: the model has always had `name` and the creator lets you set
                    // it once, but nothing could ever rename a saved location — so a typo lived forever.
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.caption2)
                        TextField("Location", text: editingNameBinding)
                            .font(.fernlet(.labelSmall))
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            // Bounded width, not .fixedSize(): fixedSize grows the chip to the full text
                            // width, so a long name pushed the trailing pencil and the caret off-screen.
                            // A frame lets the field scroll its own content and keeps the row on-screen.
                            .frame(maxWidth: 180)
                            .accessibilityIdentifier("workout.location.name")
                        Image(systemName: "pencil")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.slate)
                    }
                    .foregroundStyle(Color.bark)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.moss.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's available?")
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
                    Text("\(editingLocation?.ownedEquipment.count ?? 0) selected")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.moss)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(EquipmentCategory.allCases) { category in
                        equipmentCategorySection(category)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }

            SheetSaveBar(label: "Save location") {
                commitEdits()
                dismiss()
            }
        }
        // Commit name + equipment edits on ANY exit from this step — including a swipe-dismiss, which
        // routes through neither the save bar nor the back chevron, so an edited-but-unsaved rename used
        // to evaporate exactly the way a delete once did. Guarded to fire only for a location that
        // already exists in the store (compare by id): a brand-new location added at this step lives
        // only in local @State until its save bar is tapped, so committing it on a cancel-swipe would
        // persist a location the user was still deciding on and break the "add commits at the save bar"
        // contract. A deleted row isn't in the store either, so this can never resurrect one. Committing
        // here and then again at a save bar / back chevron writes the same rows, so it stays idempotent.
        .onDisappear {
            if let editing = editingLocation,
               store.settings.workoutLocations.contains(where: { $0.id == editing.id }) {
                commitEdits()
            }
        }
    }

    private func equipmentCategorySection(_ category: EquipmentCategory) -> some View {
        let items = GymEquipment.allCases.filter { $0.category == category }
        let selected = editingLocation?.selectedCount(in: category) ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(category.label.uppercased())
                    .font(.fernlet(.labelSmall))
                    .tracking(0.6)
                    .foregroundStyle(Color.slate)
                Spacer()
                Text("\(selected) of \(items.count)")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
            }
            LazyVGrid(columns: threeColumns, spacing: 10) {
                ForEach(items) { item in
                    equipmentCard(item)
                }
            }
        }
    }

    private func equipmentCard(_ item: GymEquipment) -> some View {
        let isSelected = editingLocation?.ownedEquipment.contains(item) ?? false
        return Button { toggle(item) } label: {
            VStack(spacing: 9) {
                EquipmentGlyph(item: item, size: 28)
                    .foregroundStyle(Color.bark)
                    .frame(height: 28)
                Text(item.displayName)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.bark)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .padding(.vertical, 14)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? Color.moss.opacity(0.10) : Color.cream)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.moss : Color.bark.opacity(0.07), lineWidth: isSelected ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.cream)
                        .frame(width: 22, height: 22)
                        .background(Color.moss, in: Circle())
                        .offset(x: 7, y: -7)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var editingLocation: WorkoutLocation? {
        guard let index = editingIndex, locations.indices.contains(index) else { return nil }
        return locations[index]
    }

    /// Writes straight into the edited location's name. The setter is guarded rather than force-indexed:
    /// `editingIndex` can outlive the row it points at (a delete shifts every later index down), and a
    /// binding that trapped on a stale index would crash the sheet instead of ignoring a dead keystroke.
    ///
    /// A blank name is allowed WHILE typing — clearing the field to retype is normal — and is repaired on
    /// commit, not by fighting the user's keystrokes mid-edit.
    private var editingNameBinding: Binding<String> {
        Binding(
            get: { editingLocation?.name ?? "" },
            set: { newValue in
                guard let index = editingIndex, locations.indices.contains(index) else { return }
                locations[index].name = newValue
            }
        )
    }

    /// Falls back to a usable name if the field was left blank, so a half-finished rename can't produce
    /// an unlabelled card the user can't tell apart from the others.
    private func repairBlankName() {
        guard let index = editingIndex, locations.indices.contains(index) else { return }
        if locations[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            locations[index].name = "Location \(index + 1)"
        }
    }

    /// Repairs a blank name and persists, so leaving the equipment step commits the edit regardless of
    /// HOW the user leaves it. Both exits (Save location, back chevron) go through here, so a rename
    /// can't be lost to a swipe-dismiss the same way a delete could — the bug this whole change is about.
    private func commitEdits() {
        repairBlankName()
        store.setWorkoutLocations(locations, activeID: activeID)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.fernlet(.labelSmall))
            .tracking(0.6)
            .foregroundStyle(Color.slate)
    }

    private func toggle(_ item: GymEquipment) {
        guard let index = editingIndex, locations.indices.contains(index) else { return }
        if locations[index].ownedEquipment.contains(item) {
            locations[index].ownedEquipment.remove(item)
        } else {
            locations[index].ownedEquipment.insert(item)
        }
    }

    private func addFromTemplate(_ template: LocationTemplate) {
        let location = template.makeLocation()
        locations.append(location)
        editingIndex = locations.count - 1
        activeID = location.id
        step = .equipment
    }

    private func addCustomLocation() {
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else { return }
        let location = WorkoutLocation(name: name, ownedEquipment: [])
        locations.append(location)
        editingIndex = locations.count - 1
        activeID = location.id
        customName = ""
        addingCustom = false
        step = .equipment
    }

    /// Deleting a location throws away the equipment the user checked off for it, and there is no undo,
    /// so it routes through the house destructive-confirmation pattern like every other irreversible
    /// action rather than firing straight off a tap.
    private func confirmRemoveLocation(index: Int) {
        guard locations.indices.contains(index) else { return }
        let location = locations[index]
        pendingDestructiveAction = DestructiveConfirmation(
            title: "Delete \(location.name)?",
            message: Self.deleteMessage(equipmentCount: location.ownedEquipment.count),
            confirmLabel: "Delete",
            auditEvent: "workout.location.deleteConfirmed",
            perform: { removeLocation(index: index) }
        )
    }

    /// The delete-confirm body. Pluralizes and special-cases zero, so the one dialog where copy matters
    /// most doesn't read "the 1 pieces" or "the 0 pieces" — an empty custom location is one Add-then-back
    /// away. `static` so it can be unit-tested without standing up the view.
    static func deleteMessage(equipmentCount count: Int) -> String {
        let equipmentClause: String
        switch count {
        case 0: equipmentClause = "its equipment setup"
        case 1: equipmentClause = "the 1 piece of equipment you picked for it"
        default: equipmentClause = "the \(count) pieces of equipment you picked for it"
        }
        return "This deletes the location and \(equipmentClause). Your logged workouts are not affected."
    }

    private func removeLocation(index: Int) {
        guard locations.count > 1, locations.indices.contains(index) else { return }
        let removed = locations.remove(at: index)
        if activeID == removed.id { activeID = locations.first?.id ?? activeID }
        // Persist NOW, not at "Done". `locations` is @State seeded from the store at init, so every
        // mutation here is local until a save bar is tapped — and both steps of this sheet can be
        // swipe-dismissed. A delete that only edited @State looked like it worked and then silently
        // came back on the next open, which is the worst shape for a destructive action: the user
        // believes it's gone. Add/edit still commit at their save bars, where the user has an explicit
        // "I'm finished" moment; a delete's moment is the confirm they just tapped.
        store.setWorkoutLocations(locations, activeID: activeID)
    }
}
