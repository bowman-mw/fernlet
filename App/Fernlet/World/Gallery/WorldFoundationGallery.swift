#if DEBUG
import FernletUI
import SwiftUI

/// DEBUG-only: every foundation primitive of the World build in one place, on a panel frame, for the
/// foundation lane's screenshots and for every lane to look at. Opened by
/// `FERNLET_UI_TEST_WORLD_GALLERY=<scene>` in place of the whole app; nothing is loaded, read or stored.
///
/// Scenes: `rows` (a framed Form with links, a switch and a danger row), `push` (a pushed page with the
/// plate's Back; its "App colors and backgrounds" row pushes a second page), `push2` (a stack opened two
/// deep at once: the deep-link case, whose Back names the panel), `controls` (dropdown, segments,
/// stepper, notice, key-value rows, tags, ring, tiles), `sheet` (a full-height sheet), `legacySheet` (a
/// sheet whose presenter still asks for the system grabber and the half detent, which win),
/// `toolbarSheet` (a NavigationStack sheet), `keyboard` (a sheet
/// with the keyboard up) and `focus` (a focused flow). Its words are verbatim: DEBUG copy, never
/// harvested into a catalog. Absent from Release builds entirely (`TestHookBoundaryTests`).
struct WorldFoundationGallery: View {
    let scene: String
    /// The panel's stack, opened where the scene asks; Back and the edge swipe pop it.
    @State private var path: [GalleryRoute]

    init(scene: String) {
        self.scene = scene
        _path = State(initialValue: GalleryRoute.path(for: scene))
    }

    var body: some View {
        WorldPanelFrame(panel: .settings, onClose: {}) {
            NavigationStack(path: $path) {
                GalleryRows()
                    .navigationDestination(for: GalleryRoute.self) { route in
                        GalleryControls()
                            .fernletPushedPage(verbatim: route.title)
                    }
            }
        }
        .sheet(isPresented: .constant(GalleryPresentation.sheet(scene) != nil)) {
            GallerySheet(kind: GalleryPresentation.sheet(scene) ?? .plain)
        }
        .fullScreenCover(isPresented: .constant(scene == "focus")) {
            GalleryFocus()
        }
        .worldDesignLanguage()
    }
}

/// The gallery's pushed pages.
enum GalleryRoute: Hashable {
    case appearance, colors

    /// The page's title on the plate.
    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .colors: "App colors and backgrounds"
        }
    }

    /// The stack a scene opens on.
    static func path(for scene: String) -> [GalleryRoute] {
        switch scene {
        case "push", "controls": [.appearance]
        case "push2": [.appearance, .colors]
        default: []
        }
    }
}

/// Which sheet a scene presents.
enum GalleryPresentation {
    case plain, legacy, toolbar, keyboard

    static func sheet(_ scene: String) -> GalleryPresentation? {
        switch scene {
        case "sheet": .plain
        case "legacySheet": .legacy
        case "toolbarSheet": .toolbar
        case "keyboard": .keyboard
        default: nil
        }
    }
}

/// A key the compiler does not harvest: the gallery's words stay out of every catalog.
private func key(_ text: String) -> LocalizedStringKey {
    LocalizedStringKey(text)
}

/// The panel's root page: a framed Form (the global Form style), then a framed list.
private struct GalleryRows: View {
    @State private var cues = true

    var body: some View {
        Form {
            Section {
                NavigationLink(value: GalleryRoute.appearance) {
                    FernletRowLabel(title: Text(verbatim: "Appearance"),
                                    detail: Text(verbatim: "Theme, backgrounds, companion, Home widgets"))
                }
                NavigationLink(value: GalleryRoute.colors) {
                    FernletRowLabel(title: Text(verbatim: "Reminders"), value: Text(verbatim: "8:30 PM"))
                }
                Toggle(isOn: $cues) { Text(verbatim: "Hunger and thirst cues").font(FernletFramedFont.rowTitle) }
            } header: {
                SectionLabel(verbatim: "Your day")
            } footer: {
                Text(verbatim: "Everything stays on your device unless you turn it on.")
            }
            Section {
                Button {} label: {
                    FernletRowLabel(title: Text(verbatim: "Delete everything"), destructive: true)
                }
                .buttonStyle(FernletRowButtonStyle(showsChevron: false))
            } header: {
                SectionLabel(verbatim: "Danger zone")
            }
        }
        .navigationTitle(Text(verbatim: ""))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A pushed page holding every framed control.
private struct GalleryControls: View {
    @State private var meal = "Dinner"
    @State private var mode = "System"
    @State private var sets = 3
    @State private var note = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FernletFramedSection(header: Text(verbatim: "Appearance")) {
                    FernletSegmentedPicker(key("Theme"), selection: $mode, options: ["System", "Light", "Dark"]) {
                        Text(verbatim: $0)
                    }
                    .padding(.vertical, 8)
                    FernletDropdown(key("Meal type"), selection: $meal, options: ["Breakfast", "Lunch", "Dinner", "Snack"]) {
                        Text(verbatim: $0)
                    }
                    HStack {
                        Text(verbatim: "Sets").font(FernletFramedFont.rowTitle)
                        Spacer()
                        FernletStepper(key("Sets"), value: $sets, in: 1...10, step: 1, display: Text(verbatim: "\(sets)"))
                    }
                    NavigationLink(value: GalleryRoute.colors) {
                        FernletRowLabel(title: Text(verbatim: "App colors and backgrounds"))
                    }
                    .buttonStyle(FernletRowButtonStyle())
                }
                GalleryContent()
            }
            .padding(16)
        }
        .fernletPageBackground()
    }
}

/// The content pieces: notice, key-value rows, tags, a ring with the big time, tiles, buttons.
private struct GalleryContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FernletNotice(text: Text(verbatim: "Goals are crafted entirely on your device."), icon: { FernletIcon(.lock) })
            FernletNotice(text: Text(verbatim: "No catalog matches."), tone: .warn, icon: { FernletIcon(.search) })
            FernletCard {
                VStack(spacing: 0) {
                    FernletKeyValueRow(key: Text(verbatim: "Main muscles"), value: Text(verbatim: "Abs and obliques"), showsRule: false)
                    FernletKeyValueRow(key: Text(verbatim: "Equipment"), value: Text(verbatim: "Cable"))
                }
            }
            HStack(spacing: 8) {
                FernletTag(text: Text(verbatim: "Catalog"))
                FernletTag(text: Text(verbatim: "Rough estimate"), fill: Color(.sRGB, red: 0.95, green: 0.84, blue: 0.54))
            }
            FernletRing { FernletBigTime(Text(verbatim: "1:12"), size: 66) }
            FernletTileGrid {
                ForEach(["Water", "Snack", "Walk", "Mood"], id: \.self) { name in
                    FernletCard { Text(verbatim: name).frame(maxWidth: .infinity) }
                }
            }
            HStack(spacing: 10) {
                Button {} label: { Text(verbatim: "−15 s") }.buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
                Button {} label: { Text(verbatim: "Log a meal") }.buttonStyle(ActionPillButtonStyle(.primary))
            }
        }
    }
}

/// The sample sheets.
private struct GallerySheet: View {
    let kind: GalleryPresentation

    var body: some View {
        switch kind {
        case .plain, .keyboard:
            GalleryMealSheet(focusesField: kind == .keyboard).fernletSheet()
        case .legacy:
            GalleryMealSheet(focusesField: false)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        case .toolbar:
            NavigationStack {
                GalleryToolbarRoot()
                    .fernletSheetToolbar(title: Text(verbatim: "Plan goals"), onCancel: {}, onDone: {})
            }
            .fernletSheet()
        }
    }
}

/// Log meal, as the sheet frame draws it: header, field, dropdown, notes, Save.
private struct GalleryMealSheet: View {
    let focusesField: Bool
    @State private var food = ""
    @State private var notes = ""
    @State private var meal = "Dinner"
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: Text(verbatim: "Log meal"), onCancel: {}, onDone: nil)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(verbatim: "What did you eat?")
                    TextField(key("Meal"), text: $food, prompt: .fieldPrompt(verbatim: "scrambled eggs and toast"))
                        .sheetTextInput()
                        .focused($focused)
                    FernletDropdown(key("Meal type"), selection: $meal, options: ["Breakfast", "Lunch", "Dinner"]) {
                        Text(verbatim: $0)
                    }
                    SheetTextEditor(text: $notes, verbatimPlaceholder: "Notes", minHeight: 90)
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
            }
            SheetSaveBar(verbatim: "Save", disabled: food.isEmpty) {}
        }
        .onAppear { focused = focusesField }
    }
}

/// A NavigationStack sheet's root page.
private struct GalleryToolbarRoot: View {
    @State private var goal = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(verbatim: "What do you want to work on?")
                TextField(key("Goal"), text: $goal, prompt: .fieldPrompt(verbatim: "strength, running, mobility"))
                    .sheetTextInput()
                FernletNotice(text: Text(verbatim: "Goals are crafted entirely on your device."), icon: { FernletIcon(.lock) })
            }
            .padding(.horizontal, 18)
        }
    }
}

/// A focused flow: a rest timer in the ring, a step card, and the bottom row.
private struct GalleryFocus: View {
    var body: some View {
        FernletFocusedFlow(title: Text(verbatim: "Full Body workout"), subtitle: Text(verbatim: "Set 2 of 3"), onClose: {}) {
            VStack(spacing: 14) {
                Text(verbatim: "Rest").font(FernletFramedFont.flowTitle).foregroundStyle(WorldPalette.mossInk)
                FernletRing { FernletBigTime(Text(verbatim: "1:12"), size: 66) }
                HStack(spacing: 10) {
                    Button {} label: { Text(verbatim: "−15 s") }.buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
                    Button {} label: { Text(verbatim: "+15 s") }.buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
                }
            }
            .padding(.top, 30)
        } footer: {
            Button {} label: { Text(verbatim: "Skip rest").frame(maxWidth: .infinity) }
                .buttonStyle(ActionPillButtonStyle(.primary))
        }
    }
}
#endif
