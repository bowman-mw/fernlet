import SwiftUI

/// Settings: first the prototype's fixture controls (this shell only), then the Home map
/// settings the design page lists, as inert rows with their decided defaults.
struct SettingsPanel: View {
    @Bindable var model: WorldShellModel

    var body: some View {
        FixtureControls(model: model)
        ShellCard {
            CardLabel(text: "Home map")
            settingRow("Location", "While using")
            settingRow("Map the world in the background", "Off")
            settingRow("Save new routes", "On")
            settingRow("Places Fernlet can name", "Food, drink, gyms, parks")
            settingRow("Uncover the map as you go", "On")
            settingRow("Remember where my workout spaces are", model.level == .dayOne ? "Not asked yet" : "On")
            settingRow("Remember places I eat out", model.level == .dayOne ? "Not asked yet" : "On")
            settingRow("Places pinned", model.decoy || model.level == .dayOne ? "None" : "3")
            LinkRow(title: "Delete map history") { model.showToast("A confirmation sheet in the app. The shell keeps nothing.") }
        }
        ShellCard {
            CardLabel(text: "Your day")
            LinkRow(title: "Goal & nutrition") { model.showToast("Opens as today.") }
            LinkRow(title: "Reminders") { model.showToast("Opens as today.") }
            LinkRow(title: "Personal care tasks") { model.showToast("Opens as today.") }
        }
    }

    private func settingRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.footnote.weight(.semibold))
            Spacer(minLength: 8)
            Text(value).font(.caption).foregroundStyle(FernColors.dim).multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The shell's fixture controls: the states the design page's sketch could switch, for trying
/// the live map on a phone without GPS, history or friends.
private struct FixtureControls: View {
    @Bindable var model: WorldShellModel

    var body: some View {
        ShellCard {
            CardLabel(text: "Prototype fixtures")
            Text("This is a shell: fixture data only, nothing saved, nothing sent. Relaunch to reset.")
                .font(.caption).foregroundStyle(FernColors.dim)
            picker("Where you are", selection: Binding(get: { model.spot }, set: { model.move(to: $0) }), FixtureSpot.allCases, \.label)
            picker("Moving", selection: Binding(get: { model.ride }, set: { model.changeRide(to: $0) }), CompanionRide.allCases, \.label)
            Toggle("Decoy session", isOn: Binding(get: { model.decoy }, set: { model.setDecoySession($0) }))
                .font(.footnote.weight(.semibold))
                .tint(FernColors.moss)
            picker("Time of day", selection: $model.phaseOverride, [nil] + SkyPhase.allCases.map(Optional.some)) { $0?.label ?? "Live clock" }
            picker("Fernlet today", selection: $model.careState, ShellCompanionState.allCases, \.label)
            picker("Time with Fernlet", selection: Binding(get: { model.level }, set: { model.setLevel($0) }), TimeWithFernlet.allCases, \.label)
            picker("Base map", selection: $model.baseMap, BaseMapKind.allCases, \.label)
            HStack {
                PillButton(title: model.isWalking ? "Walking…" : "Replay the walk") { model.startWalk(hike: model.spot == .trail) }
                Spacer()
                Button("Reset fixtures") { model.resetFixtures() }
                    .font(.footnote.weight(.semibold)).foregroundStyle(FernColors.terracotta)
            }
            .padding(.top, 4)
        }
    }

    /// A labelled menu picker over `options`.
    private func picker<Value: Hashable>(_ title: String, selection: Binding<Value>, _ options: [Value],
                                         _ label: @escaping (Value) -> String) -> some View {
        HStack {
            Text(title).font(.footnote.weight(.semibold))
            Spacer()
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { option in Text(label(option)).tag(option) }
            }
            .pickerStyle(.menu)
            .tint(FernColors.mossInk)
        }
    }
}
