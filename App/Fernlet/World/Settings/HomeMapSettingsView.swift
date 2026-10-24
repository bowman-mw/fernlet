import FernletFoundation
import FernletUI
import SwiftUI
import UIKit
import WorldMapStore

/// Settings → Home map (design `b1-settings-map`, approved 2026-10-23; World build step 5c, owner's
/// option A): every map setting on one page, reached from the Settings root's Home map section.
///
/// - **Location:** what iOS allows (a tap opens the map intro while iOS hasn't asked, else Fernlet's page in
///   the Settings app), and background mapping, off by default: Always, in low power. Turning it on asks
///   iOS to change location to Always; it runs once Always is allowed.
/// - **The map:** "Uncover the map as you go" and "Save new routes" (both on by default), how many routes
///   are stored on this iPhone, and Delete all stored routes (the walks and runs stay in Move).
/// - **Places:** "Remember where my workout spaces are", the kinds of place Fernlet can name, how many
///   spaces are pinned, and Forget workout-space locations.
/// - **Delete map history:** the fog, the walk and run lines, Where you've been and the pins, after a
///   confirmation.
///
/// Bike rides stay off this page until the car and bike states exist (owner's option A). A decoy shows the
/// page with none of the history: no routes, no pins, and its deletes touch nothing real.
struct HomeMapSettingsView: View {
    @Bindable var store: FernletStore
    @State private var uncovers = WorldMapPreferences.uncoverAsYouGo()
    @State private var savesRoutes = WorldMapPreferences.saveNewRoutes()
    @State private var remembersSpaces = WorldMapPreferences.rememberSpaces() == true
    @State private var routeCount = 0
    @State private var pinCount = 0
    /// Background mapping was turned on while only While Using is allowed: it starts once iOS says Always.
    @State private var awaitsAlways = false
    @State private var confirming: HomeMapDeletion?
    @State private var isIntroUp = false
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Whether the text is at an accessibility size: values move under their names.
    private var isLarge: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                locationSection
                mapSection
                placesSection
                historySection
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 30)
        }
        .fernletPageBackground()
        .fernletPushedPage("Home map")
        .task { reload() }
        .onChange(of: store.worldLocation.permission) { _, permission in permissionChanged(permission) }
        .alert(Text(confirming?.title ?? HomeMapDeletion.history.title), isPresented: isConfirming, presenting: confirming) { deletion in
            Button("Delete", role: .destructive) { delete(deletion) }
            Button("Cancel", role: .cancel) {}
        } message: { deletion in
            Text(deletion.message)
        }
        .fullScreenCover(isPresented: $isIntroUp) {
            WorldLocationIntro(onTurnOn: turnOnFromIntro, onNotNow: { isIntroUp = false })
        }
        .accessibilityIdentifier("screen.settings.homeMap")
    }

    // MARK: Sections

    /// Location: what iOS allows, and background mapping.
    private var locationSection: some View {
        FernletFramedSection("Location") {
            Button(action: openLocation) {
                // At the accessibility sizes the value takes the second line, so the name never breaks mid-word.
                let value = Text(HomeMapCopy.permission(store.worldLocation.permission))
                FernletRowLabel(title: Text("Location"), detail: isLarge ? value : nil, value: isLarge ? nil : value)
            }
            .buttonStyle(FernletRowButtonStyle(showsChevron: true))
            .accessibilityIdentifier("settings.homeMap.location")
            Toggle(isOn: backgroundBinding) {
                FernletRowLabel("Map the world in the background", detail: "Always, in low power. Fills the fog along your day.")
                    .padding(.vertical, 7)
            }
            .disabled(store.worldLocation.permission == .notAsked || store.worldLocation.permission == .denied)
            .accessibilityIdentifier("settings.homeMap.background")
        }
    }

    /// The map: uncovering, saving routes, the routes stored and their delete.
    private var mapSection: some View {
        FernletFramedSection("The map") {
            Toggle(isOn: $uncovers) { FernletRowLabel("Uncover the map as you go").padding(.vertical, 7) }
                .onChange(of: uncovers) { _, on in WorldMapPreferences.setUncoverAsYouGo(on) }
                .accessibilityIdentifier("settings.homeMap.uncover")
            Toggle(isOn: $savesRoutes) {
                FernletRowLabel("Save new routes", detail: "Walk and run lines, on this iPhone.").padding(.vertical, 7)
            }
            .onChange(of: savesRoutes) { _, on in WorldMapPreferences.setSaveNewRoutes(on) }
            .accessibilityIdentifier("settings.homeMap.saveRoutes")
            FernletRowLabel("Routes stored on this iPhone", value: Text(routeCount, format: .number))
                .accessibilityElement(children: .combine)
            Button { confirming = .routes } label: {
                FernletRowLabel("Delete all stored routes", destructive: true)
            }
            .buttonStyle(FernletRowButtonStyle(showsChevron: false))
            .disabled(routeCount == 0)
            .accessibilityIdentifier("settings.homeMap.deleteRoutes")
        }
    }

    /// Places: remembering spaces, the kinds Fernlet names, the pins and their forget.
    private var placesSection: some View {
        FernletFramedSection("Places") {
            Toggle(isOn: $remembersSpaces) {
                FernletRowLabel("Remember where my workout spaces are").padding(.vertical, 7)
            }
            .onChange(of: remembersSpaces) { _, on in WorldMapPreferences.setRememberSpaces(on) }
            .accessibilityIdentifier("settings.homeMap.rememberSpaces")
            FernletRowLabel(title: Text("Places Fernlet can name"),
                            detail: isLarge ? Text("Food, drink, gyms, parks") : Text("Never doctors, lawyers or therapists."),
                            value: isLarge ? nil : Text("Food, drink, gyms, parks"))
                .accessibilityElement(children: .combine)
            FernletRowLabel("Places pinned", value: Text(pinCount, format: .number))
                .accessibilityElement(children: .combine)
            Button { confirming = .spaces } label: {
                FernletRowLabel("Forget workout-space locations", destructive: true)
            }
            .buttonStyle(FernletRowButtonStyle(showsChevron: false))
            .disabled(pinCount == 0)
            .accessibilityIdentifier("settings.homeMap.forgetSpaces")
        }
    }

    /// Delete map history, under its note.
    private var historySection: some View {
        FernletFramedSection(footer: "Map history stays on this iPhone. A decoy session shows none of it.") {
            Button { confirming = .history } label: {
                FernletRowLabel("Delete map history", destructive: true)
            }
            .buttonStyle(FernletRowButtonStyle(showsChevron: true))
            .accessibilityIdentifier("settings.homeMap.deleteHistory")
        }
    }
}

extension HomeMapSettingsView {
    // MARK: Actions

    /// Background mapping: on only while Always is allowed and the person turned it on.
    private var backgroundBinding: Binding<Bool> {
        Binding(
            get: { WorldMapPreferences.alwaysLowPower() && store.worldLocation.permission == .always || awaitsAlways },
            set: { setBackground($0) }
        )
    }

    /// Turns background mapping on (asking iOS for Always when only While Using is allowed) or off.
    private func setBackground(_ on: Bool) {
        guard on else {
            awaitsAlways = false
            WorldMapPreferences.setAlwaysLowPower(false)
            store.applyWorldBackgroundMapping()
            return
        }
        switch store.worldLocation.permission {
        case .always:
            WorldMapPreferences.setAlwaysLowPower(true)
            store.applyWorldBackgroundMapping()
        case .whileUsing:
            awaitsAlways = true
            store.worldLocation.requestAlways()
        case .notAsked, .denied:
            return
        }
    }

    /// iOS answered: background mapping starts when Always was what was asked for.
    private func permissionChanged(_ permission: WorldLocationPermission) {
        if awaitsAlways, permission == .always {
            WorldMapPreferences.setAlwaysLowPower(true)
            store.applyWorldBackgroundMapping()
        }
        awaitsAlways = false
    }

    /// The Location row: the intro while iOS hasn't asked, else Fernlet's page in the Settings app.
    private func openLocation() {
        guard store.worldLocation.permission != .notAsked || store.duressSessionActive else {
            isIntroUp = true
            return
        }
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    /// The intro's Turn on location, from here.
    private func turnOnFromIntro() {
        WorldMapPreferences.setLocationIntroAnswered()
        isIntroUp = false
        store.worldLocation.requestWhileUsing()
    }

    /// Reads the counts afresh (none in a decoy).
    private func reload() {
        routeCount = store.worldStoredRouteCount
        pinCount = store.worldPinnedSpaceCount
    }

    /// Whether a deletion's confirmation is up.
    private var isConfirming: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    /// Does `deletion`, then reads the counts again.
    private func delete(_ deletion: HomeMapDeletion) {
        let done: Bool
        switch deletion {
        case .routes: done = store.deleteAllWorldRoutes()
        case .spaces: done = store.forgetAllWorkoutSpacePins()
        case .history: done = store.deleteWorldMapHistory()
        }
        FernletFeedback.system.play(done ? .done : .failed)
        reload()
    }
}

/// What Home map can delete, each behind its confirmation.
nonisolated enum HomeMapDeletion: String, Identifiable, Sendable {
    case routes
    case spaces
    case history

    var id: String { rawValue }

    /// The confirmation's title.
    var title: LocalizedStringResource {
        switch self {
        case .routes: LocalizedStringResource("homeMap.delete.routes.title", defaultValue: "Delete all stored routes?",
                                              comment: "Settings, Home map: confirming deleting every saved walk and run line")
        case .spaces: LocalizedStringResource("homeMap.delete.spaces.title", defaultValue: "Forget workout-space locations?",
                                              comment: "Settings, Home map: confirming forgetting where the workout spaces are")
        case .history: LocalizedStringResource("homeMap.delete.history.title", defaultValue: "Delete map history?",
                                               comment: "Settings, Home map: confirming deleting the whole map history")
        }
    }

    /// The confirmation's line.
    var message: LocalizedStringResource {
        switch self {
        case .routes:
            LocalizedStringResource("homeMap.delete.routes.message",
                                    defaultValue: "The walk and run lines on this iPhone go. Your walks and runs stay in Move.",
                                    comment: "Settings, Home map: what deleting all stored routes does")
        case .spaces:
            LocalizedStringResource("homeMap.delete.spaces.message",
                                    defaultValue: "The map forgets where your workout spaces are. The spaces themselves stay.",
                                    comment: "Settings, Home map: what forgetting workout-space locations does")
        case .history:
            LocalizedStringResource("homeMap.delete.history.message",
                                    defaultValue: "The fog, the walk and run lines, Where you've been and the pins on this iPhone go. Your workouts stay in Move.",
                                    comment: "Settings, Home map: what deleting the map history does")
        }
    }
}

/// Home map's words that carry a value.
nonisolated enum HomeMapCopy {
    /// The Location row's value for `permission`.
    static func permission(_ permission: WorldLocationPermission) -> LocalizedStringResource {
        switch permission {
        case .notAsked: LocalizedStringResource("homeMap.location.notAsked", defaultValue: "Not turned on",
                                                comment: "Settings, Home map: location has not been asked for yet")
        case .denied: LocalizedStringResource("homeMap.location.off", defaultValue: "Off",
                                              comment: "Settings, Home map: location is off for Fernlet in iOS")
        case .whileUsing: LocalizedStringResource("homeMap.location.whileUsing", defaultValue: "While using",
                                                  comment: "Settings, Home map: location allowed while using the app (Spanish: Al usar la app)")
        case .always: LocalizedStringResource("homeMap.location.always", defaultValue: "Always",
                                              comment: "Settings, Home map: location allowed always (background mapping)")
        }
    }
}
