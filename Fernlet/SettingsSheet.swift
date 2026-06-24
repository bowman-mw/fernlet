#if canImport(UIKit)
import UIKit
#endif
import HealthKit
import LocalAuthentication
import SwiftUI

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Bindable var store: FernletStore
    @Environment(FernletLockService.self) private var lockService
    @AppStorage("fernletDarkModeEnabled") private var isDarkModeEnabled = false
    @AppStorage(FernletThemeDefaults.customLightBackgroundKey) private var customLightBackgroundHex = FernletThemeDefaults.lightBackgroundHex
    @AppStorage(FernletThemeDefaults.customDarkBackgroundKey) private var customDarkBackgroundHex = FernletThemeDefaults.darkBackgroundHex
    @State private var confirmReset = false
    @State private var editingMemory: MemoryNote?
    @State private var memorySearch = ""
    @State private var newCareTaskName = ""
    @State private var newCareTaskGroup = "Anytime"
    @State private var healthKit = HealthKitAuthorizationViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                } header: {
                    Text("Your data stays local by default. iCloud sync and web nutrition lookup are off unless you turn them on.")
                        .font(.callout.italic())
                        .foregroundStyle(Color.slate)
                        .textCase(nil)
                        .fernletWrappingText()
                }
                .listSectionSeparator(.hidden)
                .listSectionSpacing(.compact)

                Section("General") {
                    NavigationLink("Appearance") {
                        settingsDestination(title: "Appearance") { appearanceTab }
                    }
                    NavigationLink("Goal & nutrition") {
                        settingsDestination(title: "Goal & nutrition") { generalTab }
                    }
                    NavigationLink("Layout & shortcuts") {
                        settingsDestination(title: "Layout & shortcuts") { layoutTab }
                    }
                }
                .listRowBackground(Color.cream)

                Section("Wellness") {
                    NavigationLink("Health") {
                        settingsDestination(title: "Health") { healthTab }
                    }
                    NavigationLink("Sleep") {
                        settingsDestination(title: "Sleep") { sleepTab }
                    }
                    NavigationLink("Move") {
                        settingsDestination(title: "Move") { moveTab }
                    }
                    .accessibilityIdentifier("settings.move")
                }
                .listRowBackground(Color.cream)

                Section("Period") {
                    Toggle("Hide predictions", isOn: hidePredictionsBinding)
                    Toggle("Hide fertile window", isOn: hideFertileWindowBinding)
                }
                .listRowBackground(Color.cream)

                Section("Advanced") {
                    NavigationLink("Core memory") {
                        settingsDestination(title: "Core memory") { memoriesTab }
                    }
                    NavigationLink("Signals") {
                        settingsDestination(title: "Signals") { signalsTab }
                    }
                    NavigationLink("Debug") {
                        settingsDestination(title: "Debug") { debugTab }
                    }
                    NavigationLink("Connection Inspector") {
                        settingsDestination(title: "Connection Inspector") { connectionInspectorTab }
                    }
                    NavigationLink("Connection History") {
                        ConnectionInspectorHistoryView(inspector: store.connectionInspector)
                    }
                }
                .listRowBackground(Color.cream)

                Section("Privacy") {
                    NavigationLink("Privacy & Data") {
                        PrivacyDataSettingsView(store: store)
                            .environment(lockService)
                    }
                    NavigationLink("App lock") {
                        AppLockSettingsView()
                            .environment(lockService)
                            .fernletLockGate(active: lockService.state != .notConfigured)
                            .environment(lockService)
                    }
                    Toggle(
                        "Allow nearby recipe shares",
                        isOn: Binding(
                            get: { store.settings.allowNearbyRecipeShares },
                            set: { store.setAllowNearbyRecipeShares($0) }
                        )
                    )
                }
                .listRowBackground(Color.cream)

                Section("Danger zone") {
                    resetSection
                }
                .listRowBackground(Color.cream)
            }
            .scrollContentBackground(.hidden)
            .background(Color.parchment)
            .navigationTitle("Settings")
            .safeAreaInset(edge: .bottom) {
                doneBar
            }
        }
        .background(Color.parchment)
        .onAppear { healthKit.refresh() }
    }

    private var hidePredictionsBinding: Binding<Bool> {
        Binding(
            get: { store.settings.hidePredictions },
            set: { store.setHidePredictions($0) }
        )
    }

    private var hideFertileWindowBinding: Binding<Bool> {
        Binding(
            get: { store.settings.hideFertileWindow },
            set: { store.setHideFertileWindow($0) }
        )
    }

    private var connectionInspectorModeBinding: Binding<ConnectionInspectorMode> {
        Binding(
            get: { store.settings.connectionInspectorMode },
            set: { store.setConnectionInspectorMode($0) }
        )
    }

    private func settingsDestination<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            content()
                .padding(20)
                .padding(.bottom, 20)
        }
        .scrollContentBackground(.hidden)
        .background(Color.parchment)
        .navigationTitle(title)
    }

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Dark mode", isOn: $isDarkModeEnabled)
                .padding(14)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
            SectionLabel("Backgrounds")
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose separate backgrounds for light and dark mode. Cards and input boxes stay in the same color family so the existing text colors remain readable.")
                    .font(.callout.italic())
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                themeColorRow(
                    title: "Light mode",
                    color: themeColorBinding(
                        keyPath: \.customLightBackgroundHex,
                        defaultHex: FernletThemeDefaults.lightBackgroundHex
                    ),
                    hex: customLightBackgroundHex,
                    defaultHex: FernletThemeDefaults.lightBackgroundHex
                ) {
                    customLightBackgroundHex = FernletThemeDefaults.lightBackgroundHex
                }

                themeColorRow(
                    title: "Dark mode",
                    color: themeColorBinding(
                        keyPath: \.customDarkBackgroundHex,
                        defaultHex: FernletThemeDefaults.darkBackgroundHex
                    ),
                    hex: customDarkBackgroundHex,
                    defaultHex: FernletThemeDefaults.darkBackgroundHex
                ) {
                    customDarkBackgroundHex = FernletThemeDefaults.darkBackgroundHex
                }
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func themeColorRow(title: String, color: Binding<Color>, hex: String, defaultHex: String, reset: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            ColorPicker(title, selection: color, supportsOpacity: false)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.bark)
            Text(hex.uppercased())
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.slate)
            Button("Reset", action: reset)
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.moss)
                .disabled(hex.caseInsensitiveCompare(defaultHex) == .orderedSame)
        }
        .padding(12)
        .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }

    private func themeColorBinding(keyPath: ReferenceWritableKeyPath<SettingsSheet, String>, defaultHex: String) -> Binding<Color> {
        Binding(
            get: {
                #if canImport(UIKit)
                return Color(UIColor(hex: self[keyPath: keyPath]) ?? UIColor(hex: defaultHex) ?? .systemBackground)
                #else
                return Color.parchment
                #endif
            },
            set: { newValue in
                #if canImport(UIKit)
                self[keyPath: keyPath] = UIColor(newValue).hexString ?? defaultHex
                #endif
            }
        )
    }

    private var layoutTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Home widgets")
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose what appears on the main page and put the widgets in the order you want.")
                    .font(.callout.italic())
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                ForEach(Array(store.settings.homeWidgets.enumerated()), id: \.element.id) { index, widget in
                    homeWidgetLayoutRow(widget, index: index)
                }

                FlowLayout(spacing: 8) {
                    ForEach(availableHomeWidgets) { widget in
                        Button {
                            addHomeWidget(widget)
                        } label: {
                            Label(widget.title, systemImage: widget.systemImage)
                        }
                        .buttonStyle(ChipButtonStyle(selected: false))
                    }
                }

                Button("Reset home widgets") {
                    store.setHomeWidgets(HomeWidget.defaultWidgets)
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.moss)
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))

            SectionLabel("Quick log")
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose the six home shortcuts and put them in the order you want.")
                    .font(.callout.italic())
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                ForEach(0..<6, id: \.self) { index in
                    quickLogLayoutRow(index)
                }
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))

        }
        .onAppear {
            store.setHomeWidgets(store.settings.homeWidgets)
            store.setQuickLogItems(FernletShortcut.visibleQuickLog(store.settings.quickLogItems, allowsIntimacy: store.isIntimateLoggingAllowed))
        }
        .onChange(of: store.isIntimateLoggingAllowed) { _, allowsIntimacy in
            store.setQuickLogItems(FernletShortcut.visibleQuickLog(store.settings.quickLogItems, allowsIntimacy: allowsIntimacy))
        }
    }

    private var availableHomeWidgets: [HomeWidget] {
        HomeWidget.allCases.filter { !store.settings.homeWidgets.contains($0) }
    }

    private func homeWidgetLayoutRow(_ widget: HomeWidget, index: Int) -> some View {
        HStack(spacing: 10) {
            VStack(spacing: 4) {
                Button {
                    moveHomeWidget(from: index, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 28, height: 24)
                }
                .disabled(index == 0)

                Button {
                    moveHomeWidget(from: index, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 28, height: 24)
                }
                .disabled(index == store.settings.homeWidgets.count - 1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.slate)

            Label(widget.title, systemImage: widget.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.bark)

            Spacer(minLength: 4)

            Button {
                removeHomeWidget(widget)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.slate)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }

    private func addHomeWidget(_ widget: HomeWidget) {
        var widgets = store.settings.homeWidgets
        guard !widgets.contains(widget) else { return }
        widgets.append(widget)
        store.setHomeWidgets(widgets)
    }

    private func removeHomeWidget(_ widget: HomeWidget) {
        var widgets = store.settings.homeWidgets
        widgets.removeAll { $0 == widget }
        store.setHomeWidgets(widgets)
    }

    private func moveHomeWidget(from index: Int, by offset: Int) {
        let destination = index + offset
        var widgets = store.settings.homeWidgets
        guard widgets.indices.contains(index), widgets.indices.contains(destination) else { return }
        widgets.swapAt(index, destination)
        store.setHomeWidgets(widgets)
    }

    private func quickLogLayoutRow(_ index: Int) -> some View {
        let currentItem = FernletShortcut.visibleQuickLog(store.settings.quickLogItems, allowsIntimacy: store.isIntimateLoggingAllowed)[index]

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(spacing: 4) {
                    Button {
                        moveQuickLogItem(from: index, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .frame(width: 28, height: 24)
                    }
                    .disabled(index == 0)

                    Button {
                        moveQuickLogItem(from: index, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: 28, height: 24)
                    }
                    .disabled(index == 5)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.slate)

                Label("Slot \(index + 1): \(currentItem.title)", systemImage: currentItem.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.bark)

                Spacer(minLength: 4)
            }

            FlowLayout(spacing: 8) {
                ForEach(availableQuickLogItems(for: index)) { item in
                    Button {
                        setQuickLogItem(item, at: index)
                    } label: {
                        Label(item.title, systemImage: item.systemImage)
                    }
                    .buttonStyle(ChipButtonStyle(selected: currentItem == item))
                }
            }
        }
        .padding(10)
        .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }

    private func availableQuickLogItems(for index: Int) -> [FernletShortcut] {
        let items = FernletShortcut.visibleQuickLog(store.settings.quickLogItems, allowsIntimacy: store.isIntimateLoggingAllowed)
        let currentItem = items[index]
        let selectedElsewhere = Set(items.enumerated().compactMap { itemIndex, item in
            itemIndex == index ? nil : item
        })

        return FernletShortcut.selectableQuickLogItems(allowsIntimacy: store.isIntimateLoggingAllowed).filter { item in
            item == currentItem || !selectedElsewhere.contains(item)
        }
    }

    private func setQuickLogItem(_ item: FernletShortcut, at index: Int) {
        guard store.isIntimateLoggingAllowed || item != .intimacyTracking else { return }
        var items = FernletShortcut.visibleQuickLog(store.settings.quickLogItems, allowsIntimacy: store.isIntimateLoggingAllowed)
        if let existingIndex = items.firstIndex(of: item), existingIndex != index {
            items[existingIndex] = items[index]
        }
        items[index] = item
        store.setQuickLogItems(FernletShortcut.visibleQuickLog(items, allowsIntimacy: store.isIntimateLoggingAllowed))
    }

    private func moveQuickLogItem(from index: Int, by offset: Int) {
        let destination = index + offset
        guard (0..<6).contains(destination) else { return }
        var items = FernletShortcut.visibleQuickLog(store.settings.quickLogItems, allowsIntimacy: store.isIntimateLoggingAllowed)
        items.swapAt(index, destination)
        store.setQuickLogItems(items)
    }

    private var moveTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Apple Fitness sync")
            VStack(alignment: .leading, spacing: 10) {
                Text("When enabled, Fernlet writes your logged workouts to Apple Health so they appear in the Fitness app, and pulls workouts logged elsewhere back into Fernlet.")
                    .font(.callout.italic())
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Status")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.slate)
                        Text("Available after Apple Fitness integration lands (M2)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                    }
                    Spacer(minLength: 8)
                    Button("Request access") {}
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.slate.opacity(0.55))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.parchment.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                        .disabled(true)
                }
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var memoriesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit or remove the notes Fernlet keeps from journals, plus the local trends it is inferring.")
                .font(.callout.italic())
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(Color.slate)
                TextField("Search or type \"forget [keyword]\"", text: $memorySearch)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                if !memorySearch.isEmpty {
                    Button { memorySearch = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.slate)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))

            if let keyword = forgetKeyword {
                forgetShellView(keyword: keyword)
            }

            let displayed = filteredMemories
            if displayed.isEmpty && memorySearch.isEmpty {
                FernletCard { EmptyState(text: "Nothing yet. Memories grow as you write.") }
            } else if displayed.isEmpty {
                FernletCard { EmptyState(text: "No memories match that search.") }
            } else {
                let keys = groupedMemoryKeys(for: displayed)
                let groups = groupedMemories(for: displayed)
                ForEach(keys, id: \.self) { key in
                    SectionLabel(key)
                    ForEach(groups[key] ?? []) { memory in
                        memoryRow(memory)
                    }
                }
            }
        }
        .sheet(item: $editingMemory) { memory in
            MemoryEditorSheet(store: store, memory: memory)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
    }

    private var forgetKeyword: String? {
        let trimmed = memorySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("forget ") else { return nil }
        let keyword = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        return keyword.isEmpty ? nil : keyword
    }

    private var filteredMemories: [MemoryNote] {
        let trimmed = memorySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.memories }
        let needle = forgetKeyword ?? trimmed.lowercased()
        return store.memories.filter {
            $0.text.localizedCaseInsensitiveContains(needle) ||
            $0.category.localizedCaseInsensitiveContains(needle)
        }
    }

    @ViewBuilder private func forgetShellView(keyword: String) -> some View {
        let matches = store.memories.filter {
            $0.text.localizedCaseInsensitiveContains(keyword) ||
            $0.category.localizedCaseInsensitiveContains(keyword)
        }
        if matches.isEmpty {
            FernletCard { EmptyState(text: "No memories match \"\(keyword)\".") }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Forget \(matches.count) memor\(matches.count == 1 ? "y" : "ies") matching \"\(keyword)\"?")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.bark)
                HStack(spacing: 16) {
                    Button("Delete \(matches.count)", role: .destructive) {
                        matches.forEach { store.deleteMemory($0) }
                        memorySearch = ""
                    }
                    .font(.subheadline.weight(.semibold))
                    Button("Cancel") { memorySearch = "" }
                        .font(.subheadline)
                        .foregroundStyle(Color.slate)
                }
            }
            .padding(14)
            .background(Color.terracotta.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var signalsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local trends Fernlet is inferring from journals, meals, sleep, and workouts.")
                .font(.callout.italic())
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
            if store.derivedSignals.isEmpty {
                FernletCard { EmptyState(text: "More logs will make trends useful.") }
            } else {
                ForEach(store.derivedSignals) { signal in
                    SignalDetailRow(signal: signal)
                }
            }
        }
    }

    private var sleepTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Last sleep logged for today.")
                .font(.callout.italic())
                .foregroundStyle(Color.slate)
            FernletCard {
                if let sleep = store.day.sleep {
                    HStack {
                        Circle().fill(sleep.quality == .poor ? Color.terracotta : Color.moss).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sleep.quality.label).font(.headline).foregroundStyle(Color.bark)
                            Text(sleep.hours.map { "\($0, specifier: "%.1f") hours" } ?? "Hours not logged")
                                .font(.caption).foregroundStyle(Color.slate)
                        }
                        Spacer()
                    }
                } else {
                    EmptyState(text: "No sleep logged yet.")
                }
            }
        }
    }

    private var healthTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Health access is optional and requested by feature. Apple does not reveal read-denial status, so empty Health results are handled as normal.")
                .font(.callout.italic())
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            if !healthKit.snapshot.isAvailable {
                FernletCard { EmptyState(text: "Health data is not available on this device.") }
            } else {
                ForEach(store.visibleHealthCapabilities) { capability in
                    healthCapabilityRow(capability)
                }
            }

            if !healthKit.statusMessage.isEmpty {
                Text(healthKit.statusMessage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
    }

    private func healthCapabilityRow(_ capability: HealthCapability) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: healthIcon(for: capability))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.moss)
                    .frame(width: 34, height: 34)
                    .background(Color.moss.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(capability.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.bark)
                    Text(capability.summary)
                        .font(.caption)
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                    Text(writeStatusSummary(for: capability))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.slate)
                }
                Spacer(minLength: 8)
            }

            Button {
                handleHealthPrimaryAction(for: capability)
            } label: {
                Label(healthActionTitle(for: capability), systemImage: healthActionSystemImage(for: capability))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 11)
            .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
            .disabled(healthKit.isRequesting)
            .opacity(healthKit.isRequesting ? 0.55 : 1)

            if canShowRevokeAccess(for: capability) {
                Button {
                    openHealthPermissionSettings(for: capability)
                } label: {
                    Label("Revoke access", systemImage: "xmark.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 11)
                .background(Color.terracotta, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private func writeStatusSummary(for capability: HealthCapability) -> String {
        let statuses = HealthAuthorizationPresentation.writeTypeIdentifiers(for: capability).compactMap { identifier in
            healthKit.snapshot.status(for: identifier)?.fernletLabel
        }
        if statuses.isEmpty { return "Read-only access requested when enabled." }
        let unique = Array(Set(statuses)).sorted()
        return "Write status: \(unique.joined(separator: ", "))"
    }

    private func hasWritableAccess(for capability: HealthCapability) -> Bool {
        HealthAuthorizationPresentation.writeTypeIdentifiers(for: capability).contains { identifier in
            healthKit.snapshot.status(for: identifier) == .sharingAuthorized
        }
    }

    private func hasAccessActionCompleted(for capability: HealthCapability) -> Bool {
        hasWritableAccess(for: capability) || healthKit.hasRequested(capability)
    }

    private func canShowRevokeAccess(for capability: HealthCapability) -> Bool {
        hasAccessActionCompleted(for: capability)
    }

    private func healthActionTitle(for capability: HealthCapability) -> String {
        hasAccessActionCompleted(for: capability) ? "Update data" : "Give access"
    }

    private func healthActionSystemImage(for capability: HealthCapability) -> String {
        hasAccessActionCompleted(for: capability) ? "arrow.clockwise" : "heart.text.square"
    }

    private func handleHealthPrimaryAction(for capability: HealthCapability) {
        guard canUseHealthCapability(capability) else { return }
        if hasAccessActionCompleted(for: capability) {
            updateHealthData(for: capability)
            return
        }

        switch capability {
        case .bodyProfile:
            Task {
                if let profile = await healthKit.importBodyProfile(current: store.settings.userProfile) {
                    store.settings.userProfile = profile
                }
            }
        case .cycleTracking, .bodyContext, .workoutLogging, .activityContext, .mindfulness, .intimateLogging:
            Task {
                await healthKit.request(capability)
                if let context = await healthKit.updateHealthContext(for: capability) {
                    store.updateHealthContext(context)
                }
            }
        }
    }

    private func canUseHealthCapability(_ capability: HealthCapability) -> Bool {
        guard capability != .intimateLogging || store.isIntimateLoggingAllowed else {
            healthKit.showIntimateLoggingAgeWallMessage()
            return false
        }
        return true
    }

    private func updateHealthData(for capability: HealthCapability) {
        guard canUseHealthCapability(capability) else { return }
        switch capability {
        case .bodyProfile:
            Task {
                if let profile = await healthKit.updateBodyProfile(current: store.settings.userProfile) {
                    store.settings.userProfile = profile
                }
            }
        case .bodyContext, .workoutLogging, .cycleTracking, .activityContext, .mindfulness, .intimateLogging:
            Task {
                if let context = await healthKit.updateHealthContext(for: capability) {
                    store.updateHealthContext(context)
                }
            }
        }
    }

    private func openHealthPermissionSettings(for capability: HealthCapability) {
        healthKit.showRevocationInstructions(for: capability)
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
        #endif
    }

    private func healthIcon(for capability: HealthCapability) -> String {
        switch capability {
        case .bodyProfile: "person.text.rectangle"
        case .cycleTracking: "calendar.badge.clock"
        case .bodyContext: "waveform.path.ecg"
        case .workoutLogging: "figure.run"
        case .activityContext: "figure.walk"
        case .mindfulness: "figure.mind.and.body"
        case .intimateLogging: "lock.shield"
        }
    }

    private var healthSyncedProfileBinding: Binding<UserNutritionProfile> {
        Binding(
            get: { store.settings.userProfile },
            set: { profile in
                store.settings.userProfile = profile
                Task { await healthKit.syncBodyProfileMeasurements(profile) }
            }
        )
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Goal")
            VStack(alignment: .leading, spacing: 10) {
                Picker("Goal", selection: $store.settings.selectedGoal) {
                    ForEach(GoalType.allCases) { goal in
                        Text(goal.displayName).tag(goal)
                    }
                }
                Text(store.settings.selectedGoal.tagline)
                    .font(.caption.italic())
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                Divider().overlay(Color.bark.opacity(0.08))
                Toggle("Sick mode", isOn: Binding(
                    get: { store.isSick(on: store.todayKey) },
                    set: { store.setSick($0, on: store.todayKey) }
                ))
                Toggle("Show calories", isOn: $store.settings.showCalories)
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))

            SectionLabel("Body & preferences")
            ProfileEditor(profile: healthSyncedProfileBinding, preferences: $store.settings.nutritionPreferences)

            FernletCard {
                let targets = store.nutritionTargets
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Current targets")
                    HStack(spacing: 10) {
                        NutritionPill(title: "Calories", value: "\(targets.calories)")
                        NutritionPill(title: "Protein", value: "\(targets.protein)g")
                        NutritionPill(title: "Fiber", value: "\(targets.fiber)g")
                    }
                    Text("Targets update automatically from goal, profile, activity, and eating pattern.")
                        .font(.caption.italic())
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
            }

            SectionLabel("AI")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Current")
                    Spacer()
                    Text(store.settings.aiStatus.label)
                        .font(.headline)
                        .foregroundStyle(Color.bark)
                }
                Toggle("Manual off mode", isOn: aiManualOffBinding)
                Divider().overlay(Color.bark.opacity(0.08))
                Toggle("Web nutrition lookup", isOn: $store.settings.webNutritionLookupEnabled)
                    .disabled(store.settings.aiStatus == .off)
                Text("Fernlet can search the web for chain and packaged-food nutrition. Your meal description is sent to a search provider only when this is on.")
                    .font(.caption.italic())
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                Divider().overlay(Color.bark.opacity(0.08))
                Toggle("Weather-aware recovery prompts", isOn: Binding(
                    get: { store.settings.weatherPromptsEnabled },
                    set: { newValue in
                        if newValue {
                            Task {
                                let granted = await WeatherKitService.shared.requestAuthorization()
                                store.settings.weatherPromptsEnabled = granted
                            }
                        } else {
                            store.settings.weatherPromptsEnabled = false
                        }
                    }
                ))
                Text("On heavy, gloomy days Fernlet can offer a gentle recovery nudge. Uses your approximate location for weather only, never stored or shared.")
                    .font(.caption.italic())
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                Text(FernletVoice.message(for: store.settings.aiStatus == .off ? .aiUnavailable : .retryAvailable))
                    .font(.caption.italic())
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))

            SectionLabel("Hydration")
            VStack(alignment: .leading, spacing: 10) {
                Stepper("Bottle: \(store.settings.bottleOz) oz", value: $store.settings.bottleOz, in: 4...64)
                Divider().overlay(Color.bark.opacity(0.08))
                Stepper("Daily target: \(store.settings.hydrationTarget) bottles", value: $store.settings.hydrationTarget, in: 1...30)
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))

            personalCareSettings
        }
    }

    private var aiManualOffBinding: Binding<Bool> {
        Binding(
            get: { store.settings.aiStatus == .off },
            set: { store.settings.aiStatus = $0 ? .off : .ready }
        )
    }

    private var personalCareSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Personal care tasks")
            VStack(alignment: .leading, spacing: 10) {
                TextField("Moisturizer, meds, stretch...", text: $newCareTaskName)
                    .sheetTextInput()
                FlowLayout(spacing: 8) {
                    ForEach(PersonalCareTask.groups, id: \.self) { group in
                        Button(group) { newCareTaskGroup = group }
                            .buttonStyle(ChipButtonStyle(selected: newCareTaskGroup == group))
                    }
                }
                Button {
                    store.addPersonalCareTask(label: newCareTaskName, group: newCareTaskGroup)
                    newCareTaskName = ""
                } label: {
                    Label("Add task", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 11)
                .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
                .disabled(newCareTaskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(newCareTaskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))

            ForEach(PersonalCareTask.groups, id: \.self) { group in
                let tasks = store.personalCareTasks.filter { $0.group == group }
                if !tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.slate)
                        ForEach(tasks) { task in
                            HStack(spacing: 10) {
                                Label(task.label, systemImage: task.systemImage)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.bark)
                                Spacer()
                                Button { store.removePersonalCareTask(task) } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Color.terracotta)
                                        .frame(width: 32, height: 32)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(12)
                            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }
    }

    private var debugCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Debug")
                Text("Storage: local JSON database")
                Text("File: \(store.storageLocation)")
                Text("Today key: \(store.todayKey)")
            }
            .font(.caption)
            .foregroundStyle(Color.slate)
        }
    }

    private var debugTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Prototype only — not production-private. Debug surfaces for local inspection during development.")
                .font(.callout.italic())
                .foregroundStyle(Color.terracotta)
                .fernletWrappingText()

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Friends tab")
                Toggle(
                    "Proximity debug tools",
                    isOn: Binding(
                        get: { store.settings.showProximityDebugTools },
                        set: { store.setShowProximityDebugTools($0) }
                    )
                )
                Text("Shows the connection inspector button and a Force override on the Friends tab that bypasses distance requirements.")
                    .font(.caption.italic())
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }

            debugCard

            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Tier 2 memory (test-only view)")
                Text("Tier 2 memories are inferred context records. In production these will not be readable. This view exists for prototype inspection only.")
                    .font(.caption.italic())
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                let tier2 = store.tierTwoMemories
                if tier2.isEmpty {
                    FernletCard { EmptyState(text: "No tier 2 memories yet. They are extracted from journals when Foundation Models are available.") }
                } else {
                    ForEach(tier2) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(record.category.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.slate)
                                Spacer()
                                Text(record.extractedDate.formatted(.dateTime.month(.abbreviated).day().year()))
                                    .font(.caption2)
                                    .foregroundStyle(Color.slate)
                            }
                            Text(record.text)
                                .font(.body)
                                .foregroundStyle(Color.bark)
                                .fernletWrappingText()
                            if !record.active {
                                Text("Inactive")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.terracotta)
                            }
                        }
                        .padding(14)
                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Derived signals (test-only view)")
                let signals = store.derivedSignals
                if signals.isEmpty {
                    FernletCard { EmptyState(text: "No signals computed yet. More logs will make trends useful.") }
                } else {
                    ForEach(signals) { signal in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(signal.signalName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.slate)
                                Spacer()
                                Text(signal.value.capitalized)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(SignalPresentation.color(for: signal.value))
                            }
                            Text("Window: \(signal.windowStart) → \(signal.windowEnd)")
                                .font(.caption2)
                                .foregroundStyle(Color.slate)
                        }
                        .padding(12)
                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }

    private var connectionInspectorTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connection Inspector captures proximity pairing diagnostics for local troubleshooting.")
                .font(.callout.italic())
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Mode")
                Picker("Connection Inspector", selection: connectionInspectorModeBinding) {
                    ForEach(ConnectionInspectorMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(connectionInspectorModeDescription)
                    .font(.caption)
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))

            NavigationLink {
                ConnectionInspectorHistoryView(inspector: store.connectionInspector)
            } label: {
                HStack {
                    Label("Connection History", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Text("\(store.connectionInspector.historicalLogs.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.slate)
                }
                .font(.headline)
                .foregroundStyle(Color.bark)
                .padding(14)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private var connectionInspectorModeDescription: String {
        switch store.settings.connectionInspectorMode {
        case .disabled:
            return "No overlay and no saved history."
        case .passive:
            return "Records session history without showing the live overlay."
        case .live:
            return "Records session history and shows the live inspector when you open it manually."
        }
    }

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if confirmReset {
                Button("Yes, reset everything", role: .destructive) {
                    store.resetAll()
                    dismiss()
                }
                Button("Cancel") { confirmReset = false }
            } else {
                Button("Reset everything", role: .destructive) { confirmReset = true }
            }
        }
        .font(.headline)
    }

    private var doneBar: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(Color.moss, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(20)
        .background(Color.parchment)
    }

    private func groupedMemories(for memories: [MemoryNote]) -> [String: [MemoryNote]] {
        Dictionary(grouping: memories) { $0.category.uppercased() }
    }

    private func groupedMemoryKeys(for memories: [MemoryNote]) -> [String] {
        groupedMemories(for: memories).keys.sorted()
    }

    private func memoryRow(_ memory: MemoryNote) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(memory.text)
                    .font(.body)
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                Text(memory.sourceDate.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.caption2)
                    .foregroundStyle(Color.slate)
            }
            Spacer()
            Button { editingMemory = memory } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(Color.slate)
                    .frame(width: 34, height: 34)
                    .background(Color.bark.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
            Button { store.deleteMemory(memory) } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(Color.slate)
                    .frame(width: 34, height: 34)
                    .background(Color.bark.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct MemoryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: FernletStore
    var memory: MemoryNote
    @State private var category: String
    @State private var text: String
    @State private var confirmDelete = false

    init(store: FernletStore, memory: MemoryNote) {
        self.store = store
        self.memory = memory
        _category = State(initialValue: memory.category)
        _text = State(initialValue: memory.text)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Core memory")
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(Color.bark)

                    SheetField("Category") {
                        TextField("note", text: $category)
                            .sheetTextInput()
                    }

                    SheetField("Memory") {
                        SheetTextEditor(text: $text, placeholder: "What should Fernlet remember?", minHeight: 150)
                    }

                    Text("\(text.count)/240")
                        .font(.caption)
                        .foregroundStyle(Color.slate)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Source date")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.slate)
                        Text(memory.sourceDate.formatted(.dateTime.month(.wide).day().year()))
                            .font(.body)
                            .foregroundStyle(Color.bark)
                    }
                    .padding(14)
                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))

                    if confirmDelete {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Delete this memory?")
                                .font(.headline)
                                .foregroundStyle(Color.bark)
                            HStack {
                                Button("Delete", role: .destructive) {
                                    store.deleteMemory(memory)
                                    dismiss()
                                }
                                Button("Cancel") { confirmDelete = false }
                            }
                            .font(.headline)
                        }
                    } else {
                        Button("Delete memory", role: .destructive) { confirmDelete = true }
                            .font(.headline)
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }
            .onChange(of: text) { _, newValue in
                if newValue.count > 240 { text = String(newValue.prefix(240)) }
            }

            SheetSaveBar(disabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                store.updateMemory(memory, category: category, text: text)
                dismiss()
            }
        }
        .background(Color.parchment)
    }
}

// MARK: - Components

// MARK: - App Lock settings view

struct AppLockSettingsView: View {
    @Environment(FernletLockService.self) private var lockService
    @Environment(\.dismiss) private var dismiss

    @State private var showSetup = false
    @State private var showChangePasscode = false
    @State private var showResetConfirm = false
    @State private var showBiometricPasscodeVerify = false
    @State private var verifyCurrentPasscode = ""
    @State private var verifyError: String?
    @State private var pendingBiometricEnable = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusCard

                if lockService.state != .notConfigured {
                    actionsCard
                    biometricCard
                    dangerCard
                } else {
                    setupCTACard
                }
            }
            .padding(20)
            .padding(.bottom, 20)
        }
        .scrollContentBackground(.hidden)
        .background(Color.parchment)
        .navigationTitle("App lock")
        .sheet(isPresented: $showSetup) {
            FernletLockSetupView()
                .environment(lockService)
        }
        .sheet(isPresented: $showChangePasscode) {
            FernletLockChangePasscodeView()
                .environment(lockService)
        }
        .sheet(isPresented: $showBiometricPasscodeVerify) {
            biometricVerifySheet
        }
        .confirmationDialog(
            "Reset app lock?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset app lock", role: .destructive) {
                try? lockService.reset()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Private journal, cycle, and intimacy notes will become permanently unreadable. HealthKit cycle and intimacy entries remain in Apple Health.")
        }
    }

    // MARK: Cards

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Status")
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusLabel)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.bark)
                    if let kind = lockService.credentialKind {
                        Text(kindLabel(kind))
                            .font(.caption)
                            .foregroundStyle(Color.slate)
                    }
                }
                Spacer()
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Manage")

            Button {
                showChangePasscode = true
            } label: {
                settingsRow(icon: "key.fill", title: "Change passcode")
            }

            FernletRowDivider()

            Button {
                lockService.lock(reason: .manual)
            } label: {
                settingsRow(icon: "lock.fill", title: "Lock now")
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private var biometricCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(biometricName(lockService.biometricType))

            if lockService.biometricType != .none {
                Toggle(isOn: biometricToggleBinding) {
                    settingsRow(
                        icon: biometricSystemImage(lockService.biometricType),
                        title: "Use \(biometricName(lockService.biometricType))"
                    )
                }
                .toggleStyle(SwitchToggleStyle(tint: Color.moss))
            } else {
                Text("No biometric authentication available on this device.")
                    .font(.callout.italic())
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private var dangerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Danger zone")
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                settingsRow(icon: "trash", title: "Reset app lock", destructive: true)
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private var setupCTACard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App lock is not set up. Set a passcode to protect your journal, period, and intimacy history.")
                .font(.callout.italic())
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            Button("Set up app lock") { showSetup = true }
                .buttonStyle(.plain)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.moss, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Biometric verify sheet

    private var biometricVerifySheet: some View {
        NavigationStack {
            ZStack {
                Color.parchment.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 20) {
                    Text("Enter your current passcode to \(pendingBiometricEnable ? "enable" : "disable") \(biometricName(lockService.biometricType)).")
                        .font(.callout.italic())
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()

                    if let err = verifyError {
                        Text(err)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.terracotta)
                    }

                    if lockService.credentialKind == .alphanumeric {
                        SecureField("Current password", text: $verifyCurrentPasscode)
                            .textContentType(.password)
                            .sheetTextInput()
                    } else {
                        let total = lockService.credentialKind == .pin4 ? 4 : 6
                        VStack(spacing: 20) {
                            pinDotsRow(current: verifyCurrentPasscode, total: total)
                            FernletNumericPad(value: $verifyCurrentPasscode, maxLength: total)
                        }
                        .onChange(of: verifyCurrentPasscode) { _, new in
                            if new.count == total { commitBiometricToggle() }
                        }
                    }

                    if lockService.credentialKind == .alphanumeric {
                        Button("Confirm") { commitBiometricToggle() }
                            .buttonStyle(.plain)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.moss, in: RoundedRectangle(cornerRadius: 14))
                            .disabled(verifyCurrentPasscode.isEmpty)
                    }

                    Spacer()
                }
                .padding(24)
            }
            .navigationTitle("Verify passcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showBiometricPasscodeVerify = false
                        verifyCurrentPasscode = ""
                        verifyError = nil
                    }
                    .foregroundStyle(Color.slate)
                }
            }
        }
        .tint(Color.moss)
    }

    private func commitBiometricToggle() {
        Task { @MainActor in
            do {
                try await lockService.setBiometricEnabled(pendingBiometricEnable, passcode: verifyCurrentPasscode)
                showBiometricPasscodeVerify = false
                verifyCurrentPasscode = ""
                verifyError = nil
            } catch {
                verifyCurrentPasscode = ""
                verifyError = error.localizedDescription
            }
        }
    }

    // MARK: Helpers

    private var biometricToggleBinding: Binding<Bool> {
        Binding(
            get: { lockService.biometricEnabled },
            set: { newValue in
                if newValue == lockService.biometricEnabled { return }
                if newValue {
                    // Enabling requires passcode verification
                    pendingBiometricEnable = true
                    showBiometricPasscodeVerify = true
                } else {
                    // Disabling doesn't need verification
                    Task { try? await lockService.setBiometricEnabled(false, passcode: "") }
                }
            }
        )
    }

    private var statusLabel: String {
        switch lockService.state {
        case .notConfigured: return "Not configured"
        case .locked(let d):
            if let d { return "Locked (cooldown until \(d.formatted(.dateTime.hour().minute())))" }
            return lockService.requiresReset ? "Locked (reset required)" : "Locked"
        case .unlocked: return "Unlocked"
        }
    }

    private var statusColor: Color {
        switch lockService.state {
        case .notConfigured: Color.softTaupe
        case .locked: Color.terracotta
        case .unlocked: Color.moss
        }
    }

    private func kindLabel(_ kind: FernletLockCredentialKind) -> String {
        switch kind {
        case .pin4: "4-digit PIN"
        case .pin6: "6-digit PIN"
        case .alphanumeric: "Alphanumeric password"
        }
    }

    private func settingsRow(icon: String, title: String, destructive: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(destructive ? Color.terracotta : Color.moss)
                .frame(width: 28)
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(destructive ? Color.terracotta : Color.bark)
            Spacer()
            if !destructive {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.slate.opacity(0.5))
            }
        }
    }
}

// MARK: - Change passcode view (presented as sheet from AppLockSettingsView)

private struct FernletLockChangePasscodeView: View {
    @Environment(FernletLockService.self) private var lockService
    @Environment(\.dismiss) private var dismiss

    @State private var currentPasscode = ""
    @State private var newPasscode = ""
    @State private var confirmPasscode = ""
    @State private var selectedKind: FernletLockCredentialKind
    @State private var step: ChangeStep = .verifyOld
    @State private var errorMessage: String?

    init() {
        _selectedKind = State(initialValue: .pin6)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.parchment.ignoresSafeArea()
                stepContent.padding(24)
            }
            .navigationTitle("Change passcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.slate)
                }
            }
        }
        .tint(Color.moss)
        .onAppear { selectedKind = lockService.credentialKind ?? .pin6 }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .verifyOld:
            verifyOldStep
        case .enterNew:
            enterNewStep
        case .confirmNew:
            confirmNewStep
        }
    }

    // Verify current passcode
    private var verifyOldStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionLabel("Current passcode")
            Text("Enter your current passcode to continue.")
                .font(.callout.italic())
                .foregroundStyle(Color.slate)

            if let msg = errorMessage { errorBanner(msg) }

            let oldKind = lockService.credentialKind ?? .pin6
            if oldKind == .alphanumeric {
                SecureField("Current password", text: $currentPasscode)
                    .textContentType(.password)
                    .sheetTextInput()
            } else {
                let total = oldKind == .pin4 ? 4 : 6
                VStack(spacing: 20) {
                    pinDotsRow(current: currentPasscode, total: total)
                    FernletNumericPad(value: $currentPasscode, maxLength: total)
                }
                .onChange(of: currentPasscode) { _, new in
                    if new.count == total { advanceFromVerifyOld() }
                }
            }
            Spacer()
            if (lockService.credentialKind ?? .pin6) == .alphanumeric {
                continueButton { advanceFromVerifyOld() }
            }
        }
    }

    private func advanceFromVerifyOld() {
        Task { @MainActor in
            do {
                _ = try await lockService.unlock(passcode: currentPasscode)
                errorMessage = nil
                step = .enterNew
            } catch {
                currentPasscode = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    // Enter new passcode
    private var enterNewStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionLabel("New passcode")
            Text("Choose a lock type for your new passcode.")
                .font(.callout.italic())
                .foregroundStyle(Color.slate)

            VStack(spacing: 12) {
                changeKindCard(.pin4, title: "4-digit PIN")
                changeKindCard(.pin6, title: "6-digit PIN")
                changeKindCard(.alphanumeric, title: "Password")
            }

            if let msg = errorMessage { errorBanner(msg) }
            if selectedKind == .alphanumeric {
                SecureField("New password", text: $newPasscode)
                    .textContentType(.newPassword)
                    .sheetTextInput()
            } else {
                let total = selectedKind == .pin4 ? 4 : 6
                VStack(spacing: 20) {
                    pinDotsRow(current: newPasscode, total: total)
                    FernletNumericPad(value: $newPasscode, maxLength: total)
                }
                .onChange(of: newPasscode) { _, new in
                    if new.count == total { step = .confirmNew }
                }
            }
            Spacer()
            if selectedKind == .alphanumeric {
                continueButton(disabled: newPasscode.count < 8) { step = .confirmNew }
            }
        }
        .onChange(of: selectedKind) { _, _ in newPasscode = "" }
    }

    private func changeKindCard(_ kind: FernletLockCredentialKind, title: String) -> some View {
        Button { selectedKind = kind } label: {
            HStack(spacing: 14) {
                Image(systemName: kind == selectedKind ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(kind == selectedKind ? Color.moss : Color.slate.opacity(0.4))
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.bark)
                Spacer()
            }
            .padding(14)
            .background(
                kind == selectedKind ? Color.moss.opacity(0.06) : Color.cream,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        kind == selectedKind ? Color.moss.opacity(0.4) : Color.bark.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // Confirm new passcode
    private var confirmNewStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionLabel("Confirm new passcode")
            if let msg = errorMessage { errorBanner(msg) }
            if selectedKind == .alphanumeric {
                SecureField("Confirm new password", text: $confirmPasscode)
                    .textContentType(.newPassword)
                    .sheetTextInput()
            } else {
                let total = selectedKind == .pin4 ? 4 : 6
                VStack(spacing: 20) {
                    pinDotsRow(current: confirmPasscode, total: total)
                    FernletNumericPad(value: $confirmPasscode, maxLength: total)
                }
                .onChange(of: confirmPasscode) { _, new in
                    if new.count == total { commitChange() }
                }
            }
            Spacer()
            if selectedKind == .alphanumeric {
                continueButton(disabled: confirmPasscode.isEmpty) { commitChange() }
            }
        }
    }

    private func commitChange() {
        guard newPasscode == confirmPasscode else {
            confirmPasscode = ""
            errorMessage = "Passcodes don't match. Try again."
            return
        }
        Task { @MainActor in
            do {
                let newCredential: FernletLockCredential
                switch selectedKind {
                case .pin4: newCredential = .pin4(newPasscode)
                case .pin6: newCredential = .pin6(newPasscode)
                case .alphanumeric: newCredential = .alphanumeric(newPasscode)
                }
                try await lockService.changeCredential(current: currentPasscode, new: newCredential)
                dismiss()
            } catch {
                confirmPasscode = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    private func continueButton(disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button("Continue", action: action)
            .buttonStyle(.plain)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(disabled ? Color.moss.opacity(0.4) : Color.moss, in: RoundedRectangle(cornerRadius: 14))
            .disabled(disabled)
    }

    private func errorBanner(_ msg: String) -> some View {
        Text(msg)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.terracotta)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.terracotta.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private enum ChangeStep { case verifyOld, enterNew, confirmNew }
}

// MARK: - Shared pin dots row helper (used in SettingsSheet-internal views)

private func pinDotsRow(current: String, total: Int) -> some View {
    HStack(spacing: 16) {
        ForEach(0..<total, id: \.self) { index in
            Circle()
                .fill(index < current.count ? Color.bark : Color.clear)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.bark.opacity(0.35), lineWidth: 1.5))
        }
    }
}
