import FernletUI
import SwiftUI
import WorldMapStore

/// One day of "Where you've been" (`b2-where-been`'s top card): the day's name and "kept 30 days", its
/// stops in time order, a sketch of the day, and (on the page's first card) the note on what is collected.
struct WorldPlacesDayCard: View {
    let day: Date
    let stops: [PlaceStop]
    let places: [PlaceRecord]
    var store: FernletStore
    let showsNote: Bool

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(WorldPlacesCopy.dayName(day))
                        .font(FernletFramedFont.cardTitle)
                        .foregroundStyle(WorldPalette.bark)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Text(WorldPlacesCopy.kept)
                        .font(FernletFramedFont.rowDetail)
                        .foregroundStyle(WorldPalette.dim)
                }
                ForEach(stops) { stop in
                    FernletDottedRule()
                    WorldPlaceStopRow(stop: stop, place: places.first { $0.id == stop.placeID })
                }
                WorldDaySketch(lines: lines, points: points)
                    .frame(height: 130)
                    .accessibilityHidden(true)
                if showsNote {
                    Text(WorldPlacesCopy.note)
                        .font(FernletFramedFont.note)
                        .foregroundStyle(WorldPalette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The day's saved walk and run lines, as they are on this iPhone now.
    private var lines: [[GeoPoint]] {
        stops.compactMap { stop in stop.workoutID.flatMap { store.worldRoute(for: $0)?.map(\.point) } }
            .filter { $0.count >= 2 }
    }

    /// The day's places' points.
    private var points: [GeoPoint] {
        stops.compactMap { stop in places.first { $0.id == stop.placeID }?.point }
    }
}

/// One stop: the time, then the place's name and its kind, or "A walk" / "A run" and its length.
struct WorldPlaceStopRow: View {
    let stop: PlaceStop
    let place: PlaceRecord?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(stop.at, format: .dateTime.hour().minute())
                .font(FernletFramedFont.rowValue)
                .foregroundStyle(WorldPalette.dim)
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: WorldPlacesCopy.stopTitle(stop, place: place))
                    .font(FernletFramedFont.rowTitle)
                    .foregroundStyle(WorldPalette.bark)
                Text(verbatim: WorldPlacesCopy.stopDetail(stop, place: place))
                    .font(FernletFramedFont.rowDetail)
                    .foregroundStyle(WorldPalette.dim)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Places you return to": each place and its visit count, never a date. A tap renames it.
struct WorldReturnedPlacesCard: View {
    let places: [PlaceRecord]
    let onRename: (PlaceRecord) -> Void

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(WorldPlacesCopy.returnedTitle)
                        .font(FernletFramedFont.cardTitle)
                        .foregroundStyle(WorldPalette.bark)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Text(WorldPlacesCopy.countNoDates)
                        .font(FernletFramedFont.rowDetail)
                        .foregroundStyle(WorldPalette.dim)
                }
                if places.isEmpty {
                    Text(WorldPlacesCopy.noPlaces)
                        .font(FernletFramedFont.body)
                        .foregroundStyle(WorldPalette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(places) { place in
                    Button { onRename(place) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: place.name).font(FernletFramedFont.rowTitle)
                            Spacer(minLength: 8)
                            Text(verbatim: WorldPlacesCopy.visits(place.visits)).font(FernletFramedFont.button)
                        }
                        .foregroundStyle(WorldPalette.bark)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(WorldPlacesCopy.renameHint))
                }
            }
        }
    }
}

/// The card a day's place takes while nothing is collected yet (or in a decoy, or before Private opens it).
struct WorldPlacesEmptyCard: View {
    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(WorldPlacesCopy.emptyTitle)
                    .font(FernletFramedFont.cardTitle)
                    .foregroundStyle(WorldPalette.bark)
                    .accessibilityAddTraits(.isHeader)
                Text(WorldPlacesCopy.note)
                    .font(FernletFramedFont.note)
                    .foregroundStyle(WorldPalette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A day sketched by Fernlet alone: plain ground in a frame, the day's lines in the trail's green, and its
/// places as small ink squares, fitted to the frame. No base map, so no one is asked for the area of a past
/// day. Decoration: the stops above say the same in words.
struct WorldDaySketch: View {
    let lines: [[GeoPoint]]
    let points: [GeoPoint]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        Canvas { context, size in
            guard let fit = WorldSketchFit(lines.flatMap { $0 } + points, size: size) else { return }
            for line in lines {
                var path = Path()
                path.addLines(line.map(fit.place))
                context.stroke(path, with: .color(dark ? WorldPalette.nightTrail : WorldPalette.trail),
                               style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            for point in points {
                let at = fit.place(point)
                context.fill(Path(CGRect(x: at.x - 5, y: at.y - 5, width: 10, height: 10)), with: .color(WorldPalette.ink))
                context.fill(Path(CGRect(x: at.x - 3, y: at.y - 3, width: 6, height: 6)), with: .color(WorldPalette.paperLight))
            }
        }
        .background(dark ? WorldPalette.nightPlainGround : WorldPalette.plainGround)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldPalette.ink, lineWidth: 2))
    }
}

/// Fits a set of points into a size with a margin, keeping the map's proportions (a flat local step).
nonisolated struct WorldSketchFit {
    let origin: GeoPoint
    let scale: Double
    let offset: CGPoint
    let height: Double

    /// The fit for `points` in `size`, or nil with none. A single point (or a tiny spread) sits in the
    /// middle at a street's scale.
    init?(_ points: [GeoPoint], size: CGSize, margin: Double = 18) {
        guard let first = points.first, size.width > 2 * margin, size.height > 2 * margin else { return nil }
        let metres = points.map { $0.metres(from: first) }
        let minEast = metres.map { $0.east }.min() ?? 0, maxEast = metres.map { $0.east }.max() ?? 0
        let minNorth = metres.map { $0.north }.min() ?? 0, maxNorth = metres.map { $0.north }.max() ?? 0
        let spanEast = max(maxEast - minEast, 200), spanNorth = max(maxNorth - minNorth, 200)
        let scale = min((size.width - 2 * margin) / spanEast, (size.height - 2 * margin) / spanNorth)
        origin = first
        self.scale = scale
        height = size.height
        offset = CGPoint(x: size.width / 2 - (minEast + maxEast) / 2 * scale,
                         y: size.height / 2 + (minNorth + maxNorth) / 2 * scale)
    }

    /// Where `point` goes in the frame (north up).
    func place(_ point: GeoPoint) -> CGPoint {
        let step = point.metres(from: origin)
        return CGPoint(x: offset.x + step.east * scale, y: offset.y - step.north * scale)
    }
}

/// "Where you've been"'s words (`b2-where-been`, approved; Spanish drafts in the lane's file).
nonisolated enum WorldPlacesCopy {
    static let tab = LocalizedStringResource("privatePlaces.tab", defaultValue: "Places",
                                             comment: "Private: the fourth tab, Where you've been (Spanish: Lugares)")
    static let title = LocalizedStringResource("privatePlaces.title", defaultValue: "Where you've been",
                                               comment: "Private, Places tab: the page's heading")
    static let kept = LocalizedStringResource("privatePlaces.kept", defaultValue: "kept 30 days",
                                              comment: "Private, Places: beside a day's name; the timeline keeps 30 days")
    static let note = LocalizedStringResource("privatePlaces.note",
                                              defaultValue: "Walks, runs and places you opened Fernlet. Turn on background mapping for the whole day.",
                                              comment: "Private, Places: what the timeline collects, under the day's card")
    static let emptyTitle = LocalizedStringResource("privatePlaces.empty", defaultValue: "Nothing here yet",
                                                    comment: "Private, Places: the day card before anything is collected")
    static let returnedTitle = LocalizedStringResource("privatePlaces.returned", defaultValue: "Places you return to",
                                                       comment: "Private, Places: the card of everyday places and their visit counts")
    static let countNoDates = LocalizedStringResource("privatePlaces.countNoDates", defaultValue: "a count, no dates",
                                                      comment: "Private, Places: beside 'Places you return to'; only a visit count is kept")
    static let noPlaces = LocalizedStringResource("privatePlaces.noPlaces",
                                                  defaultValue: "Food and drink, gyms, parks, beaches and campgrounds show here. Doctors, lawyers and therapists never do.",
                                                  comment: "Private, Places: the empty 'Places you return to' card")
    static let lastDays = LocalizedStringResource("privatePlaces.lastDays", defaultValue: "The last 30 days",
                                                  comment: "Private, Places: the row that opens every day's card")
    static let deleteDay = LocalizedStringResource("privatePlaces.deleteDay", defaultValue: "Delete a day",
                                                   comment: "Private, Places: the row that opens the list of days to delete")
    static let deleteAll = LocalizedStringResource("privatePlaces.deleteAll", defaultValue: "Delete all of it",
                                                   comment: "Private, Places: deletes the whole timeline and the places")
    static let deleteDayTitle = LocalizedStringResource("privatePlaces.deleteDay.title", defaultValue: "Delete this day?",
                                                        comment: "Private, Places: confirming a day's delete")
    static let deleteDayNote = LocalizedStringResource("privatePlaces.deleteDay.note",
                                                       defaultValue: "The day's places and the lines of its walks and runs go. The walks and runs stay in Move.",
                                                       comment: "Private, Places: what deleting a day does")
    static let deleteAllTitle = LocalizedStringResource("privatePlaces.deleteAll.title", defaultValue: "Delete all of it?",
                                                        comment: "Private, Places: confirming deleting the whole timeline")
    static let deleteAllMessage = LocalizedStringResource("privatePlaces.deleteAll.message",
                                                          defaultValue: "The 30 days, the places you return to, and the lines of those walks and runs go. The walks and runs stay in Move.",
                                                          comment: "Private, Places: what deleting all of it does")
    static let renameTitle = LocalizedStringResource("privatePlaces.rename.title", defaultValue: "Rename this place",
                                                     comment: "Private, Places: the rename alert's title")
    static let renameHint = LocalizedStringResource("privatePlaces.rename.hint", defaultValue: "Renames it.",
                                                    comment: "Private, Places, VoiceOver: what tapping a place does")

    /// A day's name: "Today", "Yesterday", else the weekday and date.
    static func dayName(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) {
            return String(localized: "privatePlaces.today", defaultValue: "Today", comment: "Private, Places: today's card")
        }
        if calendar.isDateInYesterday(day) {
            return String(localized: "privatePlaces.yesterday", defaultValue: "Yesterday", comment: "Private, Places: yesterday's card")
        }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    /// A stop's bold line.
    static func stopTitle(_ stop: PlaceStop, place: PlaceRecord?) -> String {
        switch stop.kind {
        case .visit: return place?.name ?? String(localized: "privatePlaces.placeGone", defaultValue: "A place",
                                                  comment: "Private, Places: a stop whose place was removed")
        case .walk: return String(localized: "privatePlaces.walk", defaultValue: "A walk", comment: "Private, Places: a walk on the timeline")
        case .run: return String(localized: "privatePlaces.run", defaultValue: "A run", comment: "Private, Places: a run on the timeline")
        }
    }

    /// The line under it: the place's kind, or the walk's or run's length.
    static func stopDetail(_ stop: PlaceStop, place: PlaceRecord?) -> String {
        guard stop.kind == .visit else { return WorldWalkCopy.distance(stop.metres ?? 0) }
        return place.map { kind($0.category) } ?? ""
    }

    /// A place's kind, as the stop's line says it.
    static func kind(_ category: PlaceCategory) -> String {
        switch category {
        case .foodAndDrink: String(localized: "privatePlaces.kind.food", defaultValue: "Food and drink", comment: "Private, Places: a kind of place")
        case .gym: String(localized: "privatePlaces.kind.gym", defaultValue: "Gym", comment: "Private, Places: a kind of place")
        case .park: String(localized: "privatePlaces.kind.park", defaultValue: "Park", comment: "Private, Places: a kind of place")
        case .beach: String(localized: "privatePlaces.kind.beach", defaultValue: "Beach", comment: "Private, Places: a kind of place")
        case .campground: String(localized: "privatePlaces.kind.campground", defaultValue: "Campground", comment: "Private, Places: a kind of place")
        }
    }

    /// "4 visits".
    static func visits(_ count: Int) -> String {
        String(localized: "privatePlaces.visits", defaultValue: "\(count) visits",
               comment: "Private, Places: a place's visit count. Plural on the number (1 visit)")
    }

    /// "3 stops", under a day on the delete list.
    static func stopCount(_ count: Int) -> String {
        String(localized: "privatePlaces.stops", defaultValue: "\(count) stops",
               comment: "Private, Places: how many stops a day has, on the delete list. Plural on the number (1 stop)")
    }
}
