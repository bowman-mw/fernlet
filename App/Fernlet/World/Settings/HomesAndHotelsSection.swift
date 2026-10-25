import FernletUI
import SwiftUI
import WorldMapStore

/// Settings › Home map › "Homes and hotels" (`ref-home-settings`, approved 2026-10-25): each home ("Sprout's
/// house is here"), "Add a second home" (up to 2), and the hotel with its name ("Until you check out or get
/// home"), under the footnote. Each row opens the Remember this place sheet to move, rename or remove it;
/// the hotel's has Check out. A decoy shows none and keeps nothing.
struct HomesAndHotelsSection: View {
    var store: FernletStore
    @State private var sheet: WorldPlaceSheetMode?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let book = store.worldHomes
        FernletFramedSection(header: Text(WorldHomeSettingsCopy.title), footer: Text(WorldHomeSettingsCopy.footnote)) {
            ForEach(book.homes) { home in
                row(title: Text(verbatim: home.label), detail: Text(verbatim: WorldHomeSettingsCopy.houseHere(companion: store.worldCompanionName)),
                    id: "settings.homeMap.home") { sheet = .edit(home) }
            }
            if book.homes.count < HomeBook.maxHomes {
                row(title: Text(book.homes.isEmpty ? WorldHomeSettingsCopy.addHome : WorldHomeSettingsCopy.addSecondHome),
                    detail: Text(WorldHomeSettingsCopy.upToTwo), id: "settings.homeMap.addHome") { add(.home) }
                    .disabled(startPoint == nil)
            }
            hotelRow(book.hotel)
        }
        .sheet(item: $sheet) { mode in
            WorldRememberPlaceSheet(store: store, mode: mode) { sheet = nil }
        }
        .onAppear { store.reloadWorldHomes() }
    }

    /// The hotel of the stay, or a row to check in at one.
    @ViewBuilder
    private func hotelRow(_ hotel: HomePlace?) -> some View {
        if let hotel {
            let name = Text(verbatim: hotel.label)
            row(title: Text(WorldHomeSettingsCopy.hotel), detail: Text(WorldHomeSettingsCopy.untilCheckOut),
                value: dynamicTypeSize.isAccessibilitySize ? nil : name, id: "settings.homeMap.hotel") { sheet = .edit(hotel) }
        } else {
            row(title: Text(WorldHomeSettingsCopy.checkIn), detail: Text(WorldHomeSettingsCopy.untilCheckOut),
                id: "settings.homeMap.checkIn") { add(.hotel) }
                .disabled(startPoint == nil)
        }
    }

    /// One row that opens the sheet.
    private func row(title: Text, detail: Text, value: Text? = nil, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            FernletRowLabel(title: title, detail: detail, value: value)
        }
        .buttonStyle(FernletRowButtonStyle(showsChevron: true))
        .accessibilityIdentifier(id)
    }

    /// Where a new home or hotel's pin starts: where the person last stood, else their first home. None
    /// without either (the rows wait for a reading).
    private var startPoint: GeoPoint? {
        guard !store.duressSessionActive else { return nil }
        return store.worldLocation.latest?.point ?? store.worldHomes.homes.first?.point
    }

    /// Opens the sheet to set a new home or check in at a hotel.
    private func add(_ kind: WorldTagKind) {
        guard let startPoint else { return }
        sheet = .remember(start: startPoint, kind: kind)
    }
}

/// Homes and hotels' words in Settings (`ref-home-settings`).
nonisolated enum WorldHomeSettingsCopy {
    static let title = LocalizedStringResource("homeMap.homes.title", defaultValue: "Homes and hotels",
                                               comment: "Settings, Home map: the section of the person's homes and hotel")
    static let addHome = LocalizedStringResource("homeMap.homes.add", defaultValue: "Add a home",
                                                 comment: "Settings, Home map: the row that sets a first home")
    static let addSecondHome = LocalizedStringResource("homeMap.homes.addSecond", defaultValue: "Add a second home",
                                                       comment: "Settings, Home map: the row that sets a second home")
    static let upToTwo = LocalizedStringResource("homeMap.homes.upToTwo", defaultValue: "Up to 2",
                                                 comment: "Settings, Home map: under 'Add a second home'; at most two homes")
    static let hotel = LocalizedStringResource("homeMap.homes.hotel", defaultValue: "Hotel",
                                               comment: "Settings, Home map: the row of the current hotel stay; its name is the value")
    static let checkIn = LocalizedStringResource("homeMap.homes.checkIn", defaultValue: "Check in at a hotel",
                                                 comment: "Settings, Home map: the row that starts a hotel stay")
    static let untilCheckOut = LocalizedStringResource("homeMap.homes.untilCheckOut", defaultValue: "Until you check out or get home",
                                                       comment: "Settings, Home map: under the hotel row")
    static let footnote = LocalizedStringResource("homeMap.homes.footnote",
                                                  defaultValue: "Each home and your hotel uncovers the map for 1 km around it and stays sealed on this iPhone. Getting home checks you out of a hotel; Fernlet remembers hotels for a welcome back.",
                                                  comment: "Settings, Home map: under Homes and hotels")
    static let checkOut = LocalizedStringResource("homeMap.homes.checkOut", defaultValue: "Check out",
                                                  comment: "The hotel's sheet from Settings: ends the stay; the hotel is remembered for a welcome back")

    /// "Sprout's house is here", under a home's row (the companion's name).
    static func houseHere(companion: String) -> String {
        String(localized: "homeMap.homes.houseHere", defaultValue: "\(companion)'s house is here",
               comment: "Settings, Home map: under a home's row; the companion's name, e.g. 'Sprout's house is here'")
    }

    /// "Remove this home" / "Remove this hotel".
    static func remove(_ kind: HomeKind) -> LocalizedStringResource {
        switch kind {
        case .home: LocalizedStringResource("homeMap.homes.removeHome", defaultValue: "Remove this home",
                                            comment: "A home's sheet from Settings: removes it; its circle fogs again except where the person has been")
        case .hotel: LocalizedStringResource("homeMap.homes.removeHotel", defaultValue: "Remove this hotel",
                                             comment: "The hotel's sheet from Settings: forgets it (no welcome back)")
        }
    }
}
