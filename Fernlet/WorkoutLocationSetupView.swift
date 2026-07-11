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
                HStack {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.moss)
                    Spacer()
                    Button {
                        editingIndex = index
                        activeID = location.id
                        step = .equipment
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.slate)
                            .padding(6)
                            .background(Color.parchment.opacity(0.8), in: Circle())
                    }
                    .buttonStyle(.plain)
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
        .contextMenu {
            if locations.count > 1 {
                Button(role: .destructive) { removeLocation(index: index) } label: {
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
                    Button { step = .location } label: {
                        Image(systemName: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.bark)
                            .frame(width: 34, height: 34)
                            .background(Color.cream, in: RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.caption2)
                        Text(editingLocation?.name ?? "Location")
                            .font(.fernlet(.labelSmall))
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
                store.setWorkoutLocations(locations, activeID: activeID)
                dismiss()
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

    private func removeLocation(index: Int) {
        guard locations.count > 1, locations.indices.contains(index) else { return }
        let removed = locations.remove(at: index)
        if activeID == removed.id { activeID = locations.first?.id ?? activeID }
    }
}
