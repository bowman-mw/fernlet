import FernletUI
import SwiftUI
import WorldMapStore

/// One day of "Where you've been" (`b2-where-been`'s top card): the day's name and "kept 30 days", its
/// stops in time order, a sketch of the day, and (on the page's first card) the note on what is collected.
/// With ``onDeleteStop``, a tap on a stop (or its VoiceOver action) asks to delete it (W-14, `ref-del-stop`).
struct WorldPlacesDayCard: View {
    let day: Date
    let stops: [PlaceStop]
    let places: [PlaceRecord]
    /// The names Apple Maps gave again for this look, by place id.
    let names: [UUID: WorldPlaceName]
    var store: FernletStore
    let showsNote: Bool
    /// The homes and hotel, for the leaves and returns on the timeline (round 6, `ref-home-where`).
    var homes: HomeBook = .empty
    /// How long the person was out and about that day, when they left and got back.
    var outAndAbout: TimeInterval? = nil
    /// Deletes one stop, after its dialog; nil leaves the stops untappable.
    var onDeleteStop: ((PlaceStop) -> Void)? = nil
    /// The stop whose delete dialog is up.
    @State private var deletingStop: PlaceStop?

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
                if let outAndAbout { WorldOutAndAboutLine(duration: outAndAbout) }
                ForEach(stops) { stop in
                    FernletDottedRule()
                    stopRow(stop)
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
        .modifier(WorldStopDeleteDialog(stop: $deletingStop, title: title(of:), message: message(of:)) { onDeleteStop?($0) })
    }

    /// One stop: with ``onDeleteStop``, a button that asks to delete it, with the same VoiceOver action.
    @ViewBuilder
    private func stopRow(_ stop: PlaceStop) -> some View {
        let row = WorldPlaceStopRow(stop: stop, title: title(of: stop), detail: detail(of: stop), spoken: spoken(of: stop))
        if onDeleteStop != nil {
            Button { deletingStop = stop } label: { row.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityAction(named: Text(WorldPlacesDeleteCopy.deleteStop)) { deletingStop = stop }
        } else {
            row
        }
    }

    /// What deleting `stop` does, for its dialog.
    private func message(of stop: PlaceStop) -> String? {
        WorldPlacesDeleteCopy.stopMessage(stop, place: places.first { $0.id == stop.placeID }, name: title(of: stop), homes: homes)
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

    /// A stop's bold line: a home's or hotel's own name for a leave or a return, else the place's.
    private func title(of stop: PlaceStop) -> String {
        guard stop.kind != .leftHome && stop.kind != .cameHome else {
            let label = stop.placeID.flatMap(homes.place)?.label ?? ""
            return label.isEmpty ? WorldHomeCopy.defaultHomeName : label
        }
        let place = places.first { $0.id == stop.placeID }
        return WorldPlacesCopy.stopTitle(stop, place: place, name: place.flatMap { names[$0.id] })
    }

    /// The line under it (a bike ride's minutes from its cycling workout, `ref-ride-timeline`).
    private func detail(of stop: PlaceStop) -> String {
        let place = places.first { $0.id == stop.placeID }
        return WorldPlacesCopy.stopDetail(stop, name: place.flatMap { names[$0.id] }, minutes: store.worldRideMinutes(for: stop))
    }

    /// What VoiceOver reads for a bike ride's row, in words; nil for every other stop (its parts combined).
    private func spoken(of stop: PlaceStop) -> String? {
        guard stop.kind == .ride else { return nil }
        return WorldPlacesCopy.spokenRide(at: stop.at, title: title(of: stop), metres: stop.metres,
                                          minutes: store.worldRideMinutes(for: stop))
    }
}

/// "Out and about 9 h 40 min" under a day with a small house (`ref-home-where`), in the moss ink. VoiceOver
/// reads it as "Out and about 9 hours 40 minutes".
struct WorldOutAndAboutLine: View {
    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 8) {
            WorldSpriteView(sprite: WorldPlaceSprites.house, scale: 2)
                .accessibilityHidden(true)
            Text(verbatim: WorldPlacesCopy.outAndAbout(duration, style: .condensedAbbreviated))
                .font(FernletFramedFont.rowTitle)
                .foregroundStyle(WorldPalette.mossInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: WorldPlacesCopy.outAndAbout(duration, style: .wide)))
    }
}

/// One stop: the time, then the place's name and its kind (when Apple Maps gave them again), or "A walk" /
/// "A run" and its length.
struct WorldPlaceStopRow: View {
    let stop: PlaceStop
    /// The bold line (``WorldPlacesCopy/stopTitle(_:place:name:)``).
    let title: String
    /// The line under it, or empty for none (``WorldPlacesCopy/stopDetail(_:name:minutes:)``).
    let detail: String
    /// What VoiceOver reads instead of the parts combined (a bike ride's, in words); nil for the parts.
    var spoken: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(stop.at, format: .dateTime.hour().minute())
                .font(FernletFramedFont.rowValue)
                .foregroundStyle(WorldPalette.dim)
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(FernletFramedFont.rowTitle)
                    .foregroundStyle(WorldPalette.bark)
                if !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(FernletFramedFont.rowDetail)
                        .foregroundStyle(WorldPalette.dim)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .modifier(WorldSpokenOverride(spoken: spoken))
    }
}

/// Replaces a combined element's label with `spoken` when there is one (a bike ride's row reads its distance
/// and minutes in words), else leaves the combined parts.
private struct WorldSpokenOverride: ViewModifier {
    let spoken: String?

    func body(content: Content) -> some View {
        if let spoken {
            content.accessibilityLabel(Text(verbatim: spoken))
        } else {
            content
        }
    }
}

/// "Places you return to": each place and its visit count, never a date. A tap renames it; its long-press
/// menu and VoiceOver actions also open it in Apple Maps and delete it (W-14, `ref-del-menu`). A place shows
/// the person's own name, else the name Apple Maps gave again by its reference, else "A place you return
/// to" (offline, or no reference).
struct WorldReturnedPlacesCard: View {
    let places: [PlaceRecord]
    /// The names Apple Maps gave again for this look, by place id.
    let names: [UUID: WorldPlaceName]
    /// Opens a place with Apple's reference in Apple Maps (form answer 53): the row's long-press menu
    /// and VoiceOver action, beside the rename alert's button.
    let onOpenInMaps: (PlaceRecord) -> Void
    /// Asks to delete a place (its confirmation, `ref-del-confirm`).
    let onDelete: (PlaceRecord) -> Void
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
                    row(place)
                }
            }
        }
    }

    /// One place: its name and visit count; a tap renames it. Its long-press menu (the row lifted on paper)
    /// and its VoiceOver actions are ``WorldPlaceRowAction``'s: Open in Apple Maps with Apple's reference,
    /// and Delete this place; VoiceOver's also Rename.
    private func row(_ place: PlaceRecord) -> some View {
        Button { onRename(place) } label: {
            rowLabel(place)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(WorldPlacesCopy.renameHint))
        .contextMenu {
            ForEach(WorldPlaceRowAction.menu(for: place), id: \.self) { action in
                Button(role: action.isDestructive ? ButtonRole.destructive : nil) { perform(action, on: place) } label: {
                    Label { Text(action.title) } icon: { Image(systemName: action.symbol ?? "ellipsis") }
                }
            }
        } preview: {
            // The row lifted on paper, so the page under the menu never shows through it.
            rowLabel(place)
                .padding(16)
                .frame(width: 320)
                .background(WorldPalette.paperLight)
        }
        .accessibilityActions {
            ForEach(WorldPlaceRowAction.spoken(for: place), id: \.self) { action in
                Button { perform(action, on: place) } label: { Text(action.title) }
            }
        }
    }

    /// Does `action` to `place`.
    private func perform(_ action: WorldPlaceRowAction, on place: PlaceRecord) {
        switch action {
        case .rename: onRename(place)
        case .openInMaps: onOpenInMaps(place)
        case .delete: onDelete(place)
        }
    }

    /// The place's name and its visit count.
    private func rowLabel(_ place: PlaceRecord) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: WorldPlacesCopy.placeTitle(place, name: names[place.id])).font(FernletFramedFont.rowTitle)
            Spacer(minLength: 8)
            Text(verbatim: WorldPlacesCopy.visits(place.visits)).font(FernletFramedFont.button)
        }
        .foregroundStyle(WorldPalette.bark)
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
                // The icon ink, which turns light in dark mode, round a paper centre.
                context.fill(Path(CGRect(x: at.x - 5, y: at.y - 5, width: 10, height: 10)), with: .color(WorldPalette.iconInk))
                context.fill(Path(CGRect(x: at.x - 3, y: at.y - 3, width: 6, height: 6)), with: .color(WorldPalette.paper))
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
    /// The kept place's action that opens it in Apple's Maps app (form answer 53).
    static let openInMaps = LocalizedStringResource("privatePlaces.openInMaps", defaultValue: "Open in Apple Maps",
                                                    comment: "Private, Places: opens a place you return to in Apple's Maps app, which shows its name and address (Spanish: Abrir en Mapas de Apple)")
    /// Said when Apple Maps could not be reached for the place (offline, or the place is gone).
    static let openInMapsFailed = LocalizedStringResource("privatePlaces.openInMaps.failed",
                                                          defaultValue: "Apple Maps couldn't find this place right now.",
                                                          comment: "Private, Places: the alert when Open in Apple Maps finds nothing (offline, or the place is gone)")

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

    /// The name a kept place shows under: the person's own, else the one Apple Maps gave again (`name`),
    /// else "A place you return to" (offline, or no reference).
    static func placeTitle(_ place: PlaceRecord, name: WorldPlaceName?) -> String {
        place.label ?? name?.name ?? String(localized: "privatePlaces.unnamedPlace", defaultValue: "A place you return to",
                                            comment: "Private, Places: a kept place whose name can't be shown (offline, or Apple Maps has none) and that the person hasn't named; tap renames it")
    }

    /// A stop's bold line.
    static func stopTitle(_ stop: PlaceStop, place: PlaceRecord?, name: WorldPlaceName?) -> String {
        switch stop.kind {
        case .visit: return place.map { placeTitle($0, name: name) }
            ?? String(localized: "privatePlaces.placeGone", defaultValue: "A place", comment: "Private, Places: a stop whose place was removed")
        case .walk: return String(localized: "privatePlaces.walk", defaultValue: "A walk", comment: "Private, Places: a walk on the timeline")
        case .run: return String(localized: "privatePlaces.run", defaultValue: "A run", comment: "Private, Places: a run on the timeline")
        case .ride: return String(localized: "privatePlaces.ride", defaultValue: "A bike ride",
                                  comment: "Private, Places: a bike ride Fernlet logged, on the timeline, beside 'A walk' and 'A run' (Spanish draft: Un paseo en bici)")
        case .leftHome, .cameHome: return WorldHomeCopy.defaultHomeName
        }
    }

    /// The line under it: the place's kind as Apple Maps gave it again (empty when it didn't), the walk's or
    /// run's length, a bike ride's distance and minutes (``rideDetail(metres:minutes:)``), or "you left" /
    /// "you got back" at a home or the hotel (`ref-home-where`). `minutes` is a ride's, from its workout.
    static func stopDetail(_ stop: PlaceStop, name: WorldPlaceName?, minutes: Int? = nil) -> String {
        switch stop.kind {
        case .visit: return name?.category.map(kind) ?? ""
        case .walk, .run: return WorldWalkCopy.distance(stop.metres ?? 0)
        case .ride: return rideDetail(metres: stop.metres, minutes: minutes)
        case .leftHome: return String(localized: "privatePlaces.leftHome", defaultValue: "you left",
                                      comment: "Private, Places: under a home's (or the hotel's) name on the timeline, when the person left")
        case .cameHome: return String(localized: "privatePlaces.cameHome", defaultValue: "you got back",
                                      comment: "Private, Places: under a home's (or the hotel's) name on the timeline, when the person got back")
        }
    }

    /// A bike ride's line on the timeline (`ref-ride-timeline`): "4.2 km · 18 min" in the person's units,
    /// "18 min" with no distance (a ride logged later), the distance alone when its workout is gone, or empty
    /// with neither.
    static func rideDetail(metres: Double?, minutes: Int?) -> String {
        let distance = metres.map(WorldWalkCopy.distance)
        let time = minutes.map { rideMinutes($0, width: .abbreviated) }
        guard let distance, let time else { return distance ?? time ?? "" }
        return String(localized: "privatePlaces.ride.detail", defaultValue: "\(distance) · \(time)",
                      comment: "Private, Places: under 'A bike ride' on the timeline: its distance, a middle dot, its minutes (e.g. '4.2 km · 18 min'; Spanish draft keeps the order: '4,2 km · 18 min')")
    }

    /// What VoiceOver reads for a bike ride's row (`ref-ride-timeline`): "15:40, A bike ride, 4.2 kilometres,
    /// 18 minutes", the parts it has, in words.
    static func spokenRide(at date: Date, title: String, metres: Double?, minutes: Int?) -> String {
        let distance = metres.map {
            Measurement(value: max(0, $0), unit: UnitLength.meters)
                .formatted(.measurement(width: .wide, usage: .road, numberFormatStyle: .number.precision(.significantDigits(1...2))))
        }
        let parts = [date.formatted(.dateTime.hour().minute()), title, distance, minutes.map { rideMinutes($0, width: .wide) }]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    /// A ride's minutes in the person's language: "18 min" (abbreviated) or "18 minutes" (wide).
    static func rideMinutes(_ minutes: Int, width: Duration.UnitsFormatStyle.UnitWidth) -> String {
        Duration.seconds(max(0, minutes) * 60).formatted(.units(allowed: [.minutes], width: width))
    }

    /// "Out and about 9 h 40 min" (abbreviated) or "Out and about 9 hours 40 minutes" (VoiceOver).
    static func outAndAbout(_ duration: TimeInterval, style: Duration.UnitsFormatStyle.UnitWidth) -> String {
        let length = Duration.seconds(max(0, duration.rounded())).formatted(.units(allowed: [.hours, .minutes], width: style))
        return String(localized: "privatePlaces.outAndAbout", defaultValue: "Out and about \(length)",
                      comment: "Private, Places: under a day, how long the person was away from home that day, e.g. 'Out and about 9 h 40 min'")
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
