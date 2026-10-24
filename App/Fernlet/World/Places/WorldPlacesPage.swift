import FernletFoundation
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
/// A decoy, which never has the hub key, shows the page empty and deletes nothing real.
struct WorldPlacesPage: View {
    var store: FernletStore
    @State private var log: PlaceLog?
    @State private var path: [WorldPlacesRoute] = []
    @State private var renaming: PlaceRecord?
    @State private var newName = ""
    @State private var confirmsDeleteAll = false

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
                    WorldReturnedPlacesCard(places: log?.returnedTo ?? []) { place in
                        newName = place.name
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
        .task { reload() }
        .alert(Text(WorldPlacesCopy.renameTitle), isPresented: isRenaming, presenting: renaming) { place in
            TextField("Place name", text: $newName, prompt: .fieldPrompt("Place name"))
            Button("Save") { rename(place) }
            Button("Cancel", role: .cancel) {}
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
            WorldPlacesDayCard(day: day, stops: log.stops(on: day), places: log.places, store: store, showsNote: true)
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
            WorldPlacesDaysPage(log: log ?? .empty, store: store)
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
    /// decoy).
    private func reload() {
        log = store.worldPlaceLog()
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
    var store: FernletStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(log.days(), id: \.self) { day in
                    WorldPlacesDayCard(day: day, stops: log.stops(on: day), places: log.places, store: store, showsNote: false)
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
