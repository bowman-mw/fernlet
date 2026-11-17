import FernletFoundation
import FernletUI
import SwiftUI
import WorldMapStore

/// What a worn way's sheet opens on: the way a tap found, or (VoiceOver's "Paths near you" on the companion) the
/// ways near the person, each opening the same page.
nonisolated enum WornWaySheetRoute: Identifiable, Equatable, Sendable {
    case way(WornWayKey)
    case nearby([WornWayLookup.Nearby])

    var id: String {
        switch self {
        case let .way(key): "way-\(key.cell.q)-\(key.cell.r)-\(key.kind.rawValue)"
        case let .nearby(ways): "nearby-\(ways.count)-\(ways.first.map { "\($0.key.cell.q)-\($0.key.cell.r)" } ?? "")"
        }
    }
}

/// The kept trips and the counter as the sheet reads and changes them: the fog keeper's seams (lane E), or a DEBUG
/// scene's stand-ins.
@MainActor
struct WornWayBook {
    /// The way's tally as the map draws it (nil once forgotten).
    var tally: (WornWayKey) -> WornTally?
    /// The kept trips through a cell, newest first.
    var trips: (HexCell) -> [WornTrip]
    /// Changes one trip's kind.
    var changeTrip: (UUID, WornWayKind) -> Void
    /// Forgets one trip.
    var forgetTrip: (UUID) -> Void
    /// Forgets every kept trip of a kind through a cell.
    var forgetPath: (HexCell, WornWayKind) -> Void

    /// The fog keeper's (`WorldFogKeeper+WornTrips`).
    static func live(_ store: FernletStore) -> WornWayBook {
        WornWayBook(tally: { store.wornYourWorldTallies()[$0] },
                    trips: { store.worldFog.trips(through: $0) },
                    changeTrip: { store.worldFog.changeTrip($0, to: $1) },
                    forgetTrip: { store.worldFog.forgetTrip($0) },
                    forgetPath: { store.worldFog.forgetPath(through: $0, kind: $1) })
    }
}

/// The small sheet a tap on a worn road, railway or ferry wake opens (ferry and train build, owner's C2 with the note
/// "Add a per trip record", 2026-11-15): "Train path · used 12 times · last 3 days ago", the whole path's fixes
/// (This was a road / a ferry, Forget this path, which asks first), and the rides kept through the spot, newest
/// first, each with its own change and Forget.
struct WornWaySheet: View {
    let route: WornWaySheetRoute
    let book: WornWayBook
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch route {
                case let .way(key):
                    WornWayDetail(key: key, book: book) { dismiss() }
                case let .nearby(ways):
                    WornWayNearbyList(ways: ways, book: book) { dismiss() }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("Done") }
                        .accessibilityIdentifier("wornWay.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("wornWay.sheet")
    }
}

/// VoiceOver's way to the sheet (a hex tap can't be reached): the worn ways near the person, each a link.
struct WornWayNearbyList: View {
    let ways: [WornWayLookup.Nearby]
    let book: WornWayBook
    let onClose: () -> Void

    var body: some View {
        List(ways) { way in
            NavigationLink {
                WornWayDetail(key: way.key, book: book, onClose: onClose)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(WornWayCopy.title(way.key.kind))
                    Text(WornWayCopy.away(WornWayCopy.distance(way.metres)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle(Text(WornWayCopy.nearbyTitle))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One way's page: its line, the whole path's fixes and its rides.
struct WornWayDetail: View {
    let key: WornWayKey
    let book: WornWayBook
    let onClose: () -> Void
    @State private var trips: [WornTrip] = []
    @State private var forgetting: Forgetting?

    /// What the confirmation asks to forget.
    private enum Forgetting: Equatable {
        case path
        case trip(UUID)
    }

    var body: some View {
        List {
            Section {
                Text(verbatim: header)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("wornWay.header")
            }
            Section {
                if !tripsOfKind.isEmpty {
                    ForEach(WornWayCopy.otherKinds(than: key.kind), id: \.self) { kind in
                        Button { changePath(to: kind) } label: { Text(WornWayCopy.thisWas(kind)) }
                            .accessibilityIdentifier("wornWay.path.\(kind)")
                    }
                }
                Button(role: .destructive) { forgetting = .path } label: { Text(WornWayCopy.forgetPath) }
                    .accessibilityIdentifier("wornWay.path.forget")
            } header: {
                Text(WornWayCopy.wholePath)
            }
            Section {
                if trips.isEmpty {
                    Text(WornWayCopy.noRides).foregroundStyle(.secondary)
                } else {
                    ForEach(trips) { trip in row(trip) }
                }
            } header: {
                Text(WornWayCopy.rides)
            }
        }
        .navigationTitle(Text(WornWayCopy.title(key.kind)))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .confirmationDialog(Text(confirmTitle), isPresented: isConfirming, titleVisibility: .visible) {
            Button(role: .destructive) { forgetConfirmed() } label: { Text(confirmButton) }
            Button(role: .cancel) { forgetting = nil } label: { Text("Cancel") }
        } message: {
            Text(confirmBody)
        }
    }

    /// "Train path · used 12 times · last 3 days ago" (the title alone once the way has gone).
    private var header: String {
        guard let tally = book.tally(key) else { return String(localized: WornWayCopy.title(key.kind)) }
        return WornWayCopy.header(kind: key.kind, tally: tally, today: WornDay.number(for: Date()))
    }

    /// The kept rides of this way's kind through the spot.
    private var tripsOfKind: [WornTrip] { trips.filter { $0.kind == key.kind } }

    /// One kept ride: when, what, and its own change and Forget.
    private func row(_ trip: WornTrip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.start.formatted(date: .abbreviated, time: .shortened))
                Text(WornWayCopy.kindName(trip.kind)).font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 16) {
                Menu {
                    ForEach(WornWayCopy.otherKinds(than: trip.kind), id: \.self) { kind in
                        Button { change(trip.id, to: kind) } label: { Text(WornWayCopy.thisWas(kind)) }
                    }
                } label: {
                    Text(WornWayCopy.change).frame(minHeight: 44)
                }
                .accessibilityLabel(Text(WornWayCopy.changeRide))
                Button(role: .destructive) { forgetting = .trip(trip.id) } label: {
                    Text(WornWayCopy.forget).frame(minHeight: 44)
                }
                .accessibilityLabel(Text(WornWayCopy.forgetRide))
            }
            .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .contain)
    }

    private var isConfirming: Binding<Bool> {
        Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })
    }

    private var confirmTitle: LocalizedStringResource {
        forgetting == .path ? WornWayCopy.forgetPathTitle : WornWayCopy.forgetRideTitle
    }

    private var confirmBody: LocalizedStringResource {
        forgetting == .path ? WornWayCopy.forgetPathBody : WornWayCopy.forgetRideBody
    }

    private var confirmButton: LocalizedStringResource {
        forgetting == .path ? WornWayCopy.forgetPathConfirm : WornWayCopy.forgetRideConfirm
    }

    private func reload() {
        trips = book.trips(key.cell)
    }

    /// "This was a road": every kept ride of this kind through the spot changes, and the way moves with them.
    private func changePath(to kind: WornWayKind) {
        // Bounded: the rides kept through one cell.
        for trip in tripsOfKind { book.changeTrip(trip.id, kind) }
        FernletFeedback.system.play(.done)
        FernletAnnouncer.system.announce(.success, resolved: String(localized: WornTransitAskCopy.kept(kind)))
        onClose()
    }

    /// One ride changes.
    private func change(_ id: UUID, to kind: WornWayKind) {
        book.changeTrip(id, kind)
        FernletFeedback.system.play(.done)
        FernletAnnouncer.system.announce(.success, resolved: String(localized: WornTransitAskCopy.kept(kind)))
        reload()
    }

    /// Forgets what the confirmation named.
    private func forgetConfirmed() {
        guard let forgetting else { return }
        self.forgetting = nil
        switch forgetting {
        case .path:
            book.forgetPath(key.cell, key.kind)
        case let .trip(id):
            book.forgetTrip(id)
        }
        FernletFeedback.system.play(.moved)
        FernletAnnouncer.system.announce(.success, resolved: String(localized: WornWayCopy.forgotten))
        if forgetting == .path { onClose() } else { reload() }
    }
}

/// The worn way sheet's copy (ferry and train build, owner's C2).
nonisolated enum WornWayCopy {
    static let wholePath = LocalizedStringResource("wornWay.sheet.wholePath", defaultValue: "This path",
                                                   comment: "Worn way sheet: header over the fixes for the whole path")
    static let rides = LocalizedStringResource("wornWay.sheet.rides", defaultValue: "Rides through here",
                                               comment: "Worn way sheet: header over the list of kept rides through the tapped spot")
    static let noRides = LocalizedStringResource("wornWay.sheet.noRides", defaultValue: "No rides are kept here yet.",
                                                 comment: "Worn way sheet: no ride records through this spot (counted before rides were kept)")
    static let forgetPath = LocalizedStringResource("wornWay.sheet.forgetPath", defaultValue: "Forget this path",
                                                    comment: "Worn way sheet: destructive button that forgets every ride along this path")
    static let forgetPathTitle = LocalizedStringResource("wornWay.sheet.forgetPathTitle", defaultValue: "Forget this path?",
                                                         comment: "Worn way sheet: confirmation title before forgetting a path")
    static let forgetPathBody = LocalizedStringResource(
        "wornWay.sheet.forgetPathBody",
        defaultValue: "Every ride kept along it is forgotten, and it comes off your map. This can't be undone.",
        comment: "Worn way sheet: confirmation message before forgetting a path")
    static let forgetPathConfirm = LocalizedStringResource("wornWay.sheet.forgetPathConfirm", defaultValue: "Forget path",
                                                           comment: "Worn way sheet: destructive confirmation button for forgetting a path")
    static let change = LocalizedStringResource("wornWay.sheet.change", defaultValue: "Change",
                                                comment: "Worn way sheet: menu on one ride to change what it was")
    static let changeRide = LocalizedStringResource("wornWay.sheet.changeRide", defaultValue: "Change this ride",
                                                    comment: "Worn way sheet: VoiceOver label for one ride's change menu")
    static let forget = LocalizedStringResource("wornWay.sheet.forget", defaultValue: "Forget",
                                                comment: "Worn way sheet: destructive button on one ride")
    static let forgetRide = LocalizedStringResource("wornWay.sheet.forgetRide", defaultValue: "Forget this ride",
                                                    comment: "Worn way sheet: VoiceOver label for one ride's Forget button")
    static let forgetRideTitle = LocalizedStringResource("wornWay.sheet.forgetRideTitle", defaultValue: "Forget this ride?",
                                                         comment: "Worn way sheet: confirmation title before forgetting one ride")
    static let forgetRideBody = LocalizedStringResource(
        "wornWay.sheet.forgetRideBody", defaultValue: "Its record is deleted and it comes off your map. This can't be undone.",
        comment: "Worn way sheet: confirmation message before forgetting one ride")
    static let forgetRideConfirm = LocalizedStringResource("wornWay.sheet.forgetRideConfirm", defaultValue: "Forget ride",
                                                           comment: "Worn way sheet: destructive confirmation button for forgetting one ride")
    static let forgotten = LocalizedStringResource("wornWay.sheet.forgotten", defaultValue: "Forgotten.",
                                                   comment: "Spoken after a path or a ride is forgotten")
    static let road = LocalizedStringResource("wornWay.kind.road", defaultValue: "Road",
                                              comment: "Worn way sheet: under a kept ride's date, the ride went by road")
    static let nearbyTitle = LocalizedStringResource("wornWay.nearby.title", defaultValue: "Paths near you",
                                                     comment: "Home: VoiceOver action on the companion, and the sheet listing worn roads, railways and ferry routes nearby")
    static let noneNearby = LocalizedStringResource("wornWay.nearby.none", defaultValue: "No worn paths near you.",
                                                    comment: "Spoken when Paths near you finds no worn road, railway or ferry route nearby")

    /// The way's name: "Train path", "Ferry path" or "Frequent road".
    static func title(_ kind: WornWayKind) -> LocalizedStringResource {
        switch kind {
        case .rail:
            LocalizedStringResource("wornWay.title.rail", defaultValue: "Train path",
                                    comment: "Worn way sheet: the name of a railway the person's rides have worn")
        case .ferry:
            LocalizedStringResource("wornWay.title.ferry", defaultValue: "Ferry path",
                                    comment: "Worn way sheet: the name of a ferry or boat route the person's rides have worn")
        case .road:
            LocalizedStringResource("wornWay.title.road", defaultValue: "Frequent road",
                                    comment: "Worn way sheet: the name of a road the person drives often")
        }
    }

    /// A kept ride's kind under its date: "Train", "Ferry" or "Road".
    static func kindName(_ kind: WornWayKind) -> LocalizedStringResource {
        switch kind {
        case .rail: WornTransitAskCopy.train
        case .ferry: WornTransitAskCopy.ferry
        case .road: road
        }
    }

    /// "This was a road", "This was a train", "This was a ferry".
    static func thisWas(_ kind: WornWayKind) -> LocalizedStringResource {
        switch kind {
        case .rail:
            LocalizedStringResource("wornWay.thisWas.rail", defaultValue: "This was a train",
                                    comment: "Worn way sheet: changes the path, or one ride, to a train")
        case .ferry:
            LocalizedStringResource("wornWay.thisWas.ferry", defaultValue: "This was a ferry",
                                    comment: "Worn way sheet: changes the path, or one ride, to a ferry or boat")
        case .road:
            LocalizedStringResource("wornWay.thisWas.road", defaultValue: "This was a road",
                                    comment: "Worn way sheet: changes the path, or one ride, to a road (a car or a bus)")
        }
    }

    /// The two kinds `kind` isn't, in a fixed order.
    static func otherKinds(than kind: WornWayKind) -> [WornWayKind] {
        [WornWayKind.road, .rail, .ferry].filter { $0 != kind }
    }

    /// "used 12 times" (plural-ruled).
    static func used(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("wornWay.sheet.used", defaultValue: "used \(count) times",
                                comment: "Worn way sheet header, middle part: how many kept trips have used this path")
    }

    /// "last 3 days ago" (`when` is a relative date, already localized).
    static func last(_ when: String) -> LocalizedStringResource {
        LocalizedStringResource("wornWay.sheet.last", defaultValue: "last \(when)",
                                comment: "Worn way sheet header, last part: when the path was last used, e.g. 'last 3 days ago', 'last yesterday'")
    }

    /// "650 ft away" (`distance` already formatted).
    static func away(_ distance: String) -> LocalizedStringResource {
        LocalizedStringResource("wornWay.nearby.away", defaultValue: "\(distance) away",
                                comment: "Paths near you: how far a worn path is from the person, e.g. '650 ft away'")
    }

    /// The sheet's line: "Train path · used 12 times · last 3 days ago".
    static func header(kind: WornWayKind, tally: WornTally, today: UInt16, locale: Locale = .current) -> String {
        let days = max(0, Int(today) - Int(tally.lastDay))
        return [String(localized: title(kind)), String(localized: used(Int(tally.count))),
                String(localized: last(relative(daysAgo: days, locale: locale)))].joined(separator: " · ")
    }

    /// "today", "yesterday", "3 days ago", "2 weeks ago", "4 months ago", "2 years ago", mid-sentence.
    static func relative(daysAgo days: Int, locale: Locale = .current) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        formatter.formattingContext = .middleOfSentence
        var ago = DateComponents()
        switch days {
        case ..<14: ago.day = -days
        case ..<60: ago.weekOfMonth = -(days / 7)
        case ..<730: ago.month = -(days / 30)
        default: ago.year = -(days / 365)
        }
        return formatter.localizedString(from: ago)
    }

    /// A distance on the ground in the person's units.
    static func distance(_ metres: Double) -> String {
        Measurement(value: metres.rounded(), unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }
}
