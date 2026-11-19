import FernletUI
import SwiftUI
import WorldMapStore

/// One aircraft type in the Hangar (owner 2026-11-19: the plane types you've flown, as a Hangar page rather than
/// stamps): made from the person's own flight records only, never from planes seen live. Pure.
nonisolated struct PassportHangarPlane: Identifiable, Equatable, Sendable {
    /// The type as the Hangar names it ("737-800"): the listed name less its maker, or the record's own words.
    let name: String
    /// The full name VoiceOver reads ("Boeing 737-800").
    let fullName: String
    let family: LiveAircraftFamily
    /// Flights flown on it.
    let count: Int
    /// The first flight on it.
    let first: Date
    var id: String { fullName }

    /// The most types the Hangar holds.
    static let maxPlanes = 120
    /// Makers whose names run to two words.
    static let twoWordMakers = ["McDonnell Douglas", "De Havilland", "Lockheed Martin", "Daher TBM"]

    /// A plane per type among the flights flown by `now` that name one, the first flown first.
    static func planes(from flights: [PassportFlight], now: Date = Date()) -> [PassportHangarPlane] {
        var byName: [String: (type: LiveAircraftType?, count: Int, first: Date)] = [:]
        // Bounded: at most `PassportBook.maxFlights` flights.
        for flight in flights.prefix(PassportBook.maxFlights) where flight.departure <= now {
            guard let written = flight.aircraftType?.trimmingCharacters(in: .whitespaces), !written.isEmpty else { continue }
            let listed = LiveAircraftTypes.codes(forName: written).sorted().first.flatMap { LiveAircraftTypes.type($0) }
            let key = listed?.name ?? written
            let held = byName[key]
            byName[key] = (listed, (held?.count ?? 0) + 1, min(held?.first ?? flight.departure, flight.departure))
        }
        return byName.map { key, entry in
            PassportHangarPlane(name: shortName(key), fullName: key,
                                family: entry.type?.family ?? .narrowbody, count: entry.count, first: entry.first)
        }
        .sorted { ($0.first, $0.fullName) < ($1.first, $1.fullName) }
        .prefix(maxPlanes)
        .map { $0 }
    }

    /// `name` less its maker ("Boeing 737-800" → "737-800"); a one-word name stays as it is.
    static func shortName(_ name: String) -> String {
        if let maker = twoWordMakers.first(where: { name.hasPrefix($0 + " ") }) {
            return String(name.dropFirst(maker.count + 1))
        }
        let words = name.split(separator: " ", maxSplits: 1)
        return words.count == 2 ? String(words[1]) : name
    }
}

/// The Hangar page of Sprout's passport, right after Flights (owner 2026-11-19, the pick "Hangar page"): "HANGAR" with
/// how many types, then every type flown parked as its pixel plane, nose up, in its family's plain colours (the
/// airline isn't kept, so no airline's), with its name, its flights and its first flight. First flown first; the
/// planes scroll within the page. One VoiceOver element each ("Boeing 737-800, 14 flights, first March 2019").
struct PassportHangarPage: View {
    let planes: [PassportHangarPlane]
    @Environment(\.displayScale) private var displayScale
    /// A bay's narrowest width, growing with the text so large sizes reflow to fewer columns.
    @ScaledMetric(relativeTo: .caption) private var bayWidth: CGFloat = 88

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PassportPageHeader(title: Text(PassportHangarCopy.title), detail: Text(PassportHangarCopy.types(planes.count)))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: bayWidth), spacing: 10, alignment: .top)], spacing: 14) {
                    ForEach(planes) { plane in
                        PassportHangarBay(plane: plane, scale: LiveAircraftLayer.scale(displayScale: displayScale))
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .accessibilityIdentifier("passport.hangar")
    }
}

/// One parked type: its plane on a pale bay, its name, its flights and its first flight.
struct PassportHangarBay: View {
    let plane: PassportHangarPlane
    /// Points per sprite pixel.
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 3) {
            WorldSpriteView(sprite: LiveAircraftSprites.sprite(plane.family, livery: .plain(plane.family), eighths: 0), scale: scale)
                .frame(width: 84, height: 60)
                .background(PassportBookPalette.paper2, in: RoundedRectangle(cornerRadius: 6))
            Text(verbatim: plane.name)
                .font(Font.custom(FernletFontName.dmSansBold, size: 12, relativeTo: .caption))
                .foregroundStyle(PassportBookPalette.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(PassportFlightsCopy.count(plane.count))
                .font(Font.custom(FernletFontName.dmSansMedium, size: 11, relativeTo: .caption2))
                .foregroundStyle(PassportBookPalette.dim)
            Text(PassportHangarCopy.first(plane.first))
                .font(Font.custom(FernletFontName.dmSansMedium, size: 11, relativeTo: .caption2))
                .foregroundStyle(PassportBookPalette.dim)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(PassportHangarCopy.spoken(plane.fullName, plane.count, plane.first)))
    }
}

/// The Hangar's words.
nonisolated enum PassportHangarCopy {
    /// The page's name and header.
    static let title = LocalizedStringResource("passport.hangar.title", defaultValue: "Hangar",
                                               comment: "Sprout's passport: the Hangar page's name and header, the aircraft types you've flown")

    /// "6 types" beside the header.
    static func types(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("passport.hangar.types", defaultValue: "\(count) types",
                                comment: "Sprout's passport Hangar page header: how many aircraft types you've flown")
    }

    /// "First Mar 2019" under a plane.
    static func first(_ date: Date) -> LocalizedStringResource {
        LocalizedStringResource("passport.hangar.first", defaultValue: "First \(date.formatted(.dateTime.month(.abbreviated).year()))",
                                comment: "Sprout's passport Hangar: the month and year of your first flight on that type")
    }

    /// "Boeing 737-800, 14 flights, first March 2019" for VoiceOver.
    static func spoken(_ name: String, _ count: Int, _ first: Date) -> LocalizedStringResource {
        LocalizedStringResource("passport.hangar.spoken",
                                defaultValue: "\(name), \(count) flights, first \(first.formatted(.dateTime.month(.wide).year()))",
                                comment: "VoiceOver, a plane in the Hangar: the aircraft type, how many flights, and the month of the first")
    }
}
