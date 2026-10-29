import FernletFoundation
import FernletUI
import SwiftUI
import UIKit
import WorldMapStore

/// Settings → Home map (design `b1-settings-map`, approved 2026-10-23; World build step 5c, owner's
/// option A): every map setting on one page, reached from the Settings root's Home map section.
///
/// - **Location:** what iOS allows (a tap opens the map intro while iOS hasn't asked, else Fernlet's page in
///   the Settings app), and background mapping, off by default: Always, in low power except while driving or riding
///   (round 7: a detected drive is traced in full). Turning it on asks iOS to change location to Always (or,
///   once iOS has used its one prompt, opens Fernlet's page in the Settings app); it runs once Always is
///   allowed, and allowing Always there later turns it on (W-09).
/// - **The map:** "Uncover the map as you go" and "Save new routes" (both on by default), "Log my bike
///   rides" (off by default; round 7), how many routes are stored on this iPhone, and Delete all stored
///   routes (the walks and runs stay in Move).
/// - **Log my bike rides** asks for Motion & Fitness only when it is turned on (decided 2026-10-22) and
///   shows the store's answer: on only while Motion is allowed. Once Motion was declined or is restricted,
///   iOS won't ask again, so turning it on opens Fernlet's page in the Settings app, and coming back with
///   Motion allowed turns it on, as the background row does with Always.
/// - **Places:** "Remember where my workout spaces are", "Remember places I stop at" (on by default; off,
///   Where you've been notes nothing new and what it holds stays until deleted; round 5), the kinds of
///   place Fernlet can name, how many spaces are pinned, and Forget workout-space locations.
/// - **Delete map history:** the fog, the walk and run lines, Where you've been and the pins, after a
///   confirmation.
///
/// A decoy shows the page with none of the history: no routes, no pins, and its deletes touch nothing real;
/// its bike-ride switch works but logs nothing (the store sees to that).
struct HomeMapSettingsView: View {
    @Bindable var store: FernletStore
    @State private var uncovers = WorldMapPreferences.uncoverAsYouGo()
    @State private var savesRoutes = WorldMapPreferences.saveNewRoutes()
    @State private var remembersSpaces = WorldMapPreferences.rememberSpaces() == true
    @State private var remembersPlaces = WorldMapPreferences.remembersPlaces()
    @State private var remembersEatingOut = WorldMapPreferences.remembersEatingOut()
    /// "Log my bike rides" as the store last answered.
    @State private var logsBikeRides = WorldMapPreferences.logsBikeRides()
    /// Fernlet's page in the Settings app was opened for Motion & Fitness: coming back with it allowed
    /// turns "Log my bike rides" on.
    @State private var awaitsMotion = false
    @State private var routeCount = 0
    @State private var pinCount = 0
    /// Background mapping was turned on while only While Using is allowed: it starts once iOS says Always.
    @State private var awaitsAlways = false
    /// Whether iOS's Always prompt showed after the switch asked (the app left active for it).
    @State private var alwaysPromptShown = false
    @State private var confirming: HomeMapDeletion?
    @State private var isIntroUp = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Whether the text is at an accessibility size: values move under their names.
    private var isLarge: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                locationSection
                mapSection
                HomesAndHotelsSection(store: store)
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
        .onChange(of: scenePhase) { _, phase in alwaysPromptPhase(phase) }
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
        FernletFramedSection(header: Text(HomeMapCopy.location)) {
            Button(action: openLocation) {
                // At the accessibility sizes the value takes the second line, so the name never breaks mid-word.
                let value = Text(HomeMapCopy.permission(store.worldLocation.permission))
                FernletRowLabel(title: Text(HomeMapCopy.location), detail: isLarge ? value : nil, value: isLarge ? nil : value)
            }
            .buttonStyle(FernletRowButtonStyle(showsChevron: true))
            .accessibilityIdentifier("settings.homeMap.location")
            Toggle(isOn: backgroundBinding) {
                FernletRowLabel("Map the world in the background", detail: "Always. Low power, except while driving or riding.")
                    .padding(.vertical, 7)
            }
            .disabled(store.worldLocation.permission == .notAsked || store.worldLocation.permission == .denied)
            .accessibilityIdentifier("settings.homeMap.background")
        }
    }

    /// The map: uncovering, saving routes, logging bike rides, the routes stored and their delete.
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
            Toggle(isOn: bikeRidesBinding) {
                bikeRidesLabel.padding(.vertical, 7)
            }
            .accessibilityIdentifier("settings.homeMap.bikeRides")
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

    /// Places: remembering spaces and the places stopped at, the kinds Fernlet names, the pins and their
    /// forget.
    private var placesSection: some View {
        FernletFramedSection("Places") {
            Toggle(isOn: $remembersSpaces) {
                FernletRowLabel("Remember where my workout spaces are").padding(.vertical, 7)
            }
            .onChange(of: remembersSpaces) { _, on in WorldMapPreferences.setRememberSpaces(on) }
            .accessibilityIdentifier("settings.homeMap.rememberSpaces")
            Toggle(isOn: $remembersPlaces) {
                FernletRowLabel("Remember places I stop at", detail: "For Where you've been, in Private.").padding(.vertical, 7)
            }
            .onChange(of: remembersPlaces) { _, on in WorldMapPreferences.setRemembersPlaces(on) }
            .accessibilityIdentifier("settings.homeMap.rememberPlaces")
            Toggle(isOn: $remembersEatingOut) {
                FernletRowLabel("Remember places I eat out").padding(.vertical, 7)
            }
            .onChange(of: remembersEatingOut) { _, on in WorldMapPreferences.setRemembersEatingOut(on) }
            .accessibilityIdentifier("settings.homeMap.rememberEatingOut")
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
            alwaysPromptShown = false
            store.worldLocation.requestAlways()
            Task { await openSettingsIfNoPrompt() }
        case .notAsked, .denied:
            return
        }
    }

    /// iOS answered: background mapping starts when Always was allowed, here or later in iOS's Settings
    /// (the location source turns the preference on for either, W-09).
    private func permissionChanged(_ permission: WorldLocationPermission) {
        if permission == .always, WorldMapPreferences.alwaysLowPower() || awaitsAlways {
            WorldMapPreferences.setAlwaysLowPower(true)
            store.applyWorldBackgroundMapping()
        }
        awaitsAlways = false
    }

    /// iOS gives the upgrade to Always one prompt only (W-09): when none showed, the switch says nothing
    /// and stays off, so the person goes to Fernlet's page in the Settings app, where Always is chosen;
    /// coming back with it allowed turns the switch on.
    private func openSettingsIfNoPrompt() async {
        do {
            try await Task.sleep(for: .seconds(1))
        } catch {
            return
        }
        guard awaitsAlways, !alwaysPromptShown, store.worldLocation.permission != .always else { return }
        awaitsAlways = false
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    /// While waiting on iOS's Always prompt: the app leaving active means it showed; coming back with
    /// While Using kept puts the switch back off. Coming back from the Settings app for Motion is read too.
    private func alwaysPromptPhase(_ phase: ScenePhase) {
        motionSettingsPhase(phase)
        guard awaitsAlways else { return }
        guard phase == .active else {
            alwaysPromptShown = true
            return
        }
        Task {
            do {
                try await Task.sleep(for: .milliseconds(600))
            } catch {
                return
            }
            if store.worldLocation.permission != .always { awaitsAlways = false }
        }
    }

    /// "Log my bike rides" and its line: what turning it on asks for or, on an iPhone without motion
    /// activity, why it stays off (owner 2026-10-29: something witty about not going anywhere).
    @ViewBuilder private var bikeRidesLabel: some View {
        if store.worldLocation.rides.motion.permission == .unavailable {
            FernletRowLabel(title: Text("Log my bike rides"),
                            detail: Text(HomeMapCopy.noMotion(companion: WorldRecenterCopy.companionName(store))))
        } else {
            FernletRowLabel("Log my bike rides", detail: "Asks for Motion & Fitness when you turn it on.")
        }
    }

    /// "Log my bike rides": what the store last answered; a turn asks the store (and, the first time, iOS).
    private var bikeRidesBinding: Binding<Bool> {
        Binding(get: { logsBikeRides }, set: { setBikeRides($0) })
    }

    /// Turns "Log my bike rides" on or off through the store, which asks for Motion & Fitness when it is
    /// turned on; the switch shows the answer. Once iOS won't ask again, Fernlet's page in the Settings app
    /// opens instead.
    private func setBikeRides(_ on: Bool) {
        let permission = store.worldLocation.rides.motion.permission
        switch HomeMapBikeRideStep.step(turningOn: on, permission: permission, isDecoy: store.duressSessionActive) {
        case .staysOff:
            logsBikeRides = false
            let line = HomeMapCopy.noMotion(companion: WorldRecenterCopy.companionName(store))
            FernletAnnouncer.system.announce(.status, resolved: String(localized: line))
        case .openSettings:
            awaitsMotion = true
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            openURL(url)
        case .ask:
            logsBikeRides = on
            Task { logsBikeRides = await store.setWorldBikeRides(on) }
        }
    }

    /// Back from Fernlet's page in the Settings app: Motion allowed there turns "Log my bike rides" on.
    private func motionSettingsPhase(_ phase: ScenePhase) {
        guard awaitsMotion, phase == .active else { return }
        awaitsMotion = false
        guard store.worldLocation.rides.motion.permission == .allowed else { return }
        Task { logsBikeRides = await store.setWorldBikeRides(true) }
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

    /// Reads the counts afresh (none in a decoy), and the bike-ride switch.
    private func reload() {
        logsBikeRides = WorldMapPreferences.logsBikeRides()
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
            // Round 6: homes and hotels and the places you eat out at live with the map history and go with it.
            LocalizedStringResource("homeMap.delete.history.message.homes",
                                    defaultValue: "The fog, the walk and run lines, Where you've been, your homes and hotels, and the pins on this iPhone go. Your workouts stay in Move.",
                                    comment: "Settings, Home map: what deleting the map history does")
        }
    }
}

/// What turning "Log my bike rides" does, decided from the Motion & Fitness answer before the store is asked.
nonisolated enum HomeMapBikeRideStep: Equatable, Sendable {
    /// Ask the store (off, or on while iOS may still ask or Motion is allowed; the store answers).
    case ask
    /// Open Fernlet's page in the Settings app: Motion was declined or is restricted, so iOS won't ask.
    case openSettings
    /// Stay off and say why: this iPhone has no motion activity to ask for.
    case staysOff

    /// The step for a turn of the switch. A decoy always asks the store, which logs nothing there.
    static func step(turningOn on: Bool, permission: WorldMotionPermission, isDecoy: Bool) -> Self {
        guard on, !isDecoy else { return .ask }
        switch permission {
        case .denied: return .openSettings
        case .unavailable: return .staysOff
        case .notAsked, .allowed: return .ask
        }
    }
}

/// Home map's words that carry a value.
nonisolated enum HomeMapCopy {
    /// "Log my bike rides" on an iPhone without motion activity: the first of the three lines proposed to the
    /// owner (2026-10-29; the others are in the lane ledger, `r7-carbike`). The companion's name.
    static func noMotion(companion: String) -> LocalizedStringResource {
        LocalizedStringResource("homeMap.bikeRides.noMotion",
                                defaultValue: "This iPhone can't tell a bike from a bench. \(companion) is staying put.",
                                comment: "Settings, Home map: under Log my bike rides on an iPhone without motion activity, so it stays off; the companion's name")
    }

    /// The Location section's label and row name: its own key, because the catalog's bare "Location" is a workout
    /// space's name field (Spanish "Lugar"), and here it is the iPhone's location (Spanish "Ubicación").
    static var location: LocalizedStringResource {
        LocalizedStringResource("homeMap.location", defaultValue: "Location",
                                comment: "Settings, Home map: the section and row for the iPhone's location permission (Spanish: Ubicación)")
    }

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
