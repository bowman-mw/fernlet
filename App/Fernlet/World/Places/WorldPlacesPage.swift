import FernletFoundation
import FernletLock
import FernletUI
import SwiftUI
import WorldMapStore

/// Private's fourth tab, Places: "Where you've been" (design `b2-where-been`, approved 2026-10-23; World
/// build step 5c, owner's option A). Sealed like the journal: read only here, under the Private tab's hub
/// key, after the captures waiting on the device are folded in.
///
/// - **The latest day** (`kept 30 days`): its stops in time order (an everyday place, or a walk or run with
///   its length) and a small sketch of the day drawn by Fernlet alone (the day's saved lines and the places'
///   points on plain ground, never Apple's map: Apple must not receive a past day's area), then the note on
///   what is collected.
/// - **Places you return to**: a visit count each, never dates. Tap one to rename it.
/// - **The last 30 days** (every day's card), **Delete a day** and **Delete all of it**, each delete behind a
///   confirmation; a day's delete also deletes its walks' and runs' saved lines (the workouts stay in Move).
///
/// **Names** (World build round 5, the MapKit terms): a place keeps only Apple's reference to it, so its
/// name and kind are asked for again by that reference while this page is open (`names`, in memory only).
/// A place the person renamed shows their name; offline, or with no reference, a place shows as "A place
/// you return to" until it is renamed.
///
/// A decoy, which never has the hub key, shows the page empty and deletes nothing real.
struct WorldPlacesPage: View {
    var store: FernletStore
    @State private var log: PlaceLog?
    /// The names Apple Maps gave again for this look, by place id (in memory only).
    @State private var names: [UUID: WorldPlaceName] = [:]
    @State private var path: [WorldPlacesRoute] = []
    @State private var renaming: PlaceRecord?
    @State private var newName = ""
    @State private var confirmsDeleteAll = false
    /// The Remember this place sheet, opened from a place to make it a home or a hotel (round 6).
    @State private var homeSheet: WorldPlaceSheetMode?
    @Environment(FernletLockService.self) private var lockService

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(WorldPlacesCopy.title)
                        .font(Font.custom(FernletFontName.frauncesSemiBold, size: 34, relativeTo: .largeTitle))
                        .foregroundStyle(WorldPalette.bark)
                        .accessibilityAddTraits(.isHeader)
                        .fixedSize(horizontal: false, vertical: true)
                    latestDay
                    // Homes and hotels are not places you return to (round 6, `ref-home-where`).
                    WorldReturnedPlacesCard(places: (log?.returnedTo ?? []).filter { !store.worldHomes.isHomeOrHotel($0.point) },
                                            names: names) { place in
                        newName = place.label ?? names[place.id]?.name ?? ""
                        renaming = place
                    }
                    actions
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .fernletPageBackground()
            .navigationDestination(for: WorldPlacesRoute.self) { route in destination(route) }
        }
        // Read again whenever the lock changes: the page is built under the Private tab's gate, before
        // the hub key exists, so the first read finds nothing until the person unlocks.
        .task(id: lockService.state) { reload() }
        .task(id: log) { await resolveNames() }
        .alert(Text(WorldPlacesCopy.renameTitle), isPresented: isRenaming, presenting: renaming) { place in
            TextField("Place name", text: $newName, prompt: .fieldPrompt("Place name"))
            Button("Save") { rename(place) }
            // Round 6 (`ref-home-set`): a place you return to can become a home or your hotel.
            Button { homeSheet = .remember(start: place.point, kind: .home) } label: { Text(WorldHomeCopy.makeHome) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $homeSheet) { mode in
            WorldRememberPlaceSheet(store: store, mode: mode) {
                homeSheet = nil
                reload()
            }
        }
        .alert(Text(WorldPlacesCopy.deleteAllTitle), isPresented: $confirmsDeleteAll) {
            Button("Delete", role: .destructive) { deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(WorldPlacesCopy.deleteAllMessage)
        }
        .accessibilityIdentifier("private.places")
    }

    /// The latest day's card, or the empty one.
    @ViewBuilder
    private var latestDay: some View {
        if let log, let day = log.days().first {
            WorldPlacesDayCard(day: day, stops: log.stops(on: day), places: log.places, names: names, store: store, showsNote: true,
                               homes: store.worldHomes, outAndAbout: log.outAndAbout(on: day))
        } else {
            WorldPlacesEmptyCard()
        }
    }

    /// The last 30 days, Delete a day, Delete all of it.
    private var actions: some View {
        let hasDays = !(log?.days().isEmpty ?? true)
        return FernletFramedSection(header: nil) {
            NavigationLink(value: WorldPlacesRoute.days) {
                FernletRowLabel(title: Text(WorldPlacesCopy.lastDays))
            }
            .buttonStyle(FernletRowButtonStyle(showsChevron: true))
            .disabled(!hasDays)
            NavigationLink(value: WorldPlacesRoute.deleteDay) {
                FernletRowLabel(title: Text(WorldPlacesCopy.deleteDay))
            }
            .buttonStyle(FernletRowButtonStyle(showsChevron: true))
            .disabled(!hasDays)
            Button { confirmsDeleteAll = true } label: {
                FernletRowLabel(title: Text(WorldPlacesCopy.deleteAll), destructive: true)
            }
            .buttonStyle(FernletRowButtonStyle(showsChevron: true))
            .accessibilityIdentifier("private.places.deleteAll")
        }
    }

    /// A pushed page.
    @ViewBuilder
    private func destination(_ route: WorldPlacesRoute) -> some View {
        switch route {
        case .days:
            WorldPlacesDaysPage(log: log ?? .empty, names: names, store: store)
        case .deleteDay:
            WorldPlacesDeleteDayPage(log: log ?? .empty) { day in
                if store.deleteWorldPlaceDay(day) { FernletFeedback.system.play(.done) }
                reload()
            }
        }
    }
}

extension WorldPlacesPage {
    /// Whether the rename alert is up.
    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    /// Reads the log afresh, folding in what waits on the device (nothing while Private is closed or in a
    /// decoy, and then no names are held either).
    private func reload() {
        log = store.worldPlaceLog()
        if log == nil { names = [:] }
        // The homes and hotel name the timeline's leaves and returns (round 6).
        store.reloadWorldHomes()
    }

    /// Asks Apple Maps again, by reference, for the name of each place the person hasn't named (at most
    /// ``PlaceLog/maxPlaces``, one at a time, each shown as it comes); a name already asked for this look is
    /// kept. Stops when the page goes.
    private func resolveNames() async {
        let places = (log?.places ?? []).prefix(PlaceLog.maxPlaces)
        for place in places where place.label == nil && place.placeID != nil && names[place.id] == nil {
            guard !Task.isCancelled else { return }
            if let name = await store.worldPlaceName(for: place) { names[place.id] = name }
        }
    }

    /// Saves the new name of `place`.
    private func rename(_ place: PlaceRecord) {
        if let next = store.renameWorldPlace(place.id, to: newName) { log = next }
        renaming = nil
    }

    /// Delete all of it, after its confirmation.
    private func deleteAll() {
        FernletFeedback.system.play(store.deleteAllWorldPlaces() ? .done : .failed)
        path = []
        names = [:]
        reload()
    }
}

/// The pages Places pushes.
nonisolated enum WorldPlacesRoute: Hashable, Sendable {
    /// Every day's card.
    case days
    /// The days, each with its delete.
    case deleteDay
}

/// "The last 30 days": every day's card, newest first.
struct WorldPlacesDaysPage: View {
    let log: PlaceLog
    /// The names asked for again on the Places page, by place id.
    let names: [UUID: WorldPlaceName]
    var store: FernletStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(log.days(), id: \.self) { day in
                    WorldPlacesDayCard(day: day, stops: log.stops(on: day), places: log.places, names: names, store: store,
                                       showsNote: false, homes: store.worldHomes, outAndAbout: log.outAndAbout(on: day))
                }
            }
            .padding(16)
        }
        .fernletPageBackground()
        .fernletPushedPage(verbatim: String(localized: WorldPlacesCopy.lastDays))
    }
}

/// "Delete a day": the days, newest first, each deleted after a confirmation.
struct WorldPlacesDeleteDayPage: View {
    let log: PlaceLog
    let onDelete: (Date) -> Void
    @State private var days: [Date] = []
    @State private var confirming: Date?

    var body: some View {
        ScrollView {
            FernletFramedSection(header: nil, footer: Text(WorldPlacesCopy.deleteDayNote)) {
                ForEach(days, id: \.self) { day in
                    Button { confirming = day } label: {
                        FernletRowLabel(title: Text(WorldPlacesCopy.dayName(day)),
                                        detail: Text(WorldPlacesCopy.stopCount(log.stops(on: day).count)))
                    }
                    .buttonStyle(FernletRowButtonStyle(showsChevron: false))
                }
            }
            .padding(16)
        }
        .fernletPageBackground()
        .fernletPushedPage(verbatim: String(localized: WorldPlacesCopy.deleteDay))
        .onAppear { days = log.days() }
        .alert(Text(WorldPlacesCopy.deleteDayTitle), isPresented: isConfirming, presenting: confirming) { day in
            Button("Delete", role: .destructive) {
                onDelete(day)
                days.removeAll { $0 == day }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(WorldPlacesCopy.deleteDayNote)
        }
    }

    /// Whether a day's confirmation is up.
    private var isConfirming: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }
}
