// FernletWidgetsBundle.swift
// FernletWidgets
//
// The extension's entry point, the companion widget's timeline, and the palette the widgets and the
// Live Activities share. World Review Batch 4 (approved 2026-10-24): the companion is the pixel
// companion as the person dressed it (WidgetPixelCompanion.swift), with Home's six hearts and a
// friend's gold hearts after them; the medium card speaks in the pixel speech bubble; the Lock Screen
// has the face alone and a rectangle with the hearts and water; water has its own widget and Control
// Center control (WaterWidget.swift); the stamp widget shows a stamp from the book (StampWidget.swift).
// Companion mood, look, water, gold hearts and stamps only — never anything sensitive, never a place —
// except the large map widget (MapWidget.swift, owner's Q36, round 6b), which draws the picture of the
// map around you the app hands it, with your marked places and saved trails: never visits or history.

import SwiftUI
import WidgetKit

/// Namespace for the extension's WidgetKit `kind` identifiers.
///
/// The app addresses widget timelines by these strings (`WidgetSnapshotMirror` reloads every one of
/// them after a snapshot mirror, and ``WaterPlusOneIntent`` after a tap), so they are persisted
/// identity — never change a value once shipped. `WidgetBridgeTests` pins the app's copies.
enum FernletWidgetKind {
    /// The companion widget (`FernletCompanionWidget`): small card, thought card, Lock Screen face.
    static let companion = "FernletCompanion"
    /// The water widget (`FernletWaterWidget`): small card and the Lock Screen "+1" circle.
    static let water = "FernletWater"
    /// The Control Center / Action button control (`FernletWaterControl`).
    static let waterControl = "FernletWaterControl"
    /// The stamp widget (`FernletStampWidget`): a stamp from the book, small and medium.
    static let stamp = "FernletStamp"
    /// The map widget (`FernletMapWidget`): Sprout on a picture of the map around you, large.
    static let map = "FernletMap"
}

/// The deep links a widget tap opens. The app's `FernletWidgetLinkRouter` reads the same
/// spellings; `WidgetBridgeTests` pins that they match.
enum FernletWidgetLink {
    /// Opens the app on Home.
    static let home = URL(string: "fernlet://widget/home")
    /// Opens the app's Water sheet, where a mis-tapped bottle can be undone.
    static let water = URL(string: "fernlet://widget/water")
    /// Opens the Stamp book (the stamp widget's tap).
    static let stamps = URL(string: "fernlet://widget/stamps")
}

/// The extension's `@main` entry point: registers every widget, control and Live Activity this
/// target ships.
///
/// Anything not listed here never appears in the widget gallery, Control Center or on the Lock
/// Screen, so a new surface must be added to this body.
@main
struct FernletWidgetsBundle: WidgetBundle {
    var body: some Widget {
        FernletCompanionWidget()
        FernletWaterWidget()
        FernletWaterControl()
        FernletStampWidget()
        FernletMapWidget()
        WorkoutLiveActivity()
        CookingLiveActivity()
    }
}

/// One timeline entry for the companion and water widgets: an entry date plus the mirrored app
/// snapshot (nil before first launch or when the app-group file is unreadable).
///
/// The load-bearing part is the day gate: every rendered value flows through accessors that compare
/// the snapshot's `dateKey` against THIS entry's `date` (via `WidgetDayGate`), so the same snapshot
/// renders as live data in a same-day entry and as a fresh, empty day in the midnight-rollover entry
/// ``FernletCompanionProvider`` appends. Views must read these accessors — never `snapshot` fields
/// directly — or the rollover gate is lost.
struct FernletCompanionEntry: TimelineEntry {
    /// The moment this entry represents (now, an emotion change, noon, or the next local midnight).
    let date: Date
    /// The mirrored app-group snapshot this entry renders from; nil → the "Open Fernlet" placeholder.
    let snapshot: WidgetSnapshot?

    /// Whether the mirrored snapshot is for the SAME local day as THIS entry's date. The water count,
    /// the mood and the care score all gate on this, so a day-rollover entry reads as a fresh, empty
    /// day rather than yesterday's — with the app closed, nothing else corrects it until launch.
    private var reflectsCurrentDay: Bool {
        guard let snapshot else { return false }
        return WidgetDayGate.snapshotReflectsDay(snapshot.dateKey, at: date)
    }

    /// Water progress only counts when the mirrored snapshot is for the CURRENT day; after a day
    /// rollover with the app closed, the fresh day starts at zero bottles.
    var bottleCount: Int {
        guard let snapshot, reflectsCurrentDay else { return 0 }
        return snapshot.bottleCount
    }

    var hydrationTarget: Int { max(snapshot?.hydrationTarget ?? 4, 1) }

    /// Day-gated companion mood — the SINGLE source every family reads for the face and label. A
    /// stale (previous-day) snapshot yields `nil` (the neutral treatment) instead of yesterday's face.
    var currentDayCompanionState: WidgetCompanionState? {
        guard reflectsCurrentDay else { return nil }
        return snapshot?.companionState
    }

    /// The companion's emotion at THIS entry's date (owner decision 2026-09-24) — the only place a
    /// family reads it.
    ///
    /// Day-scoped per moment rather than per snapshot (``WidgetEmotionTimeline``): a moment applies
    /// only on its own local day, so a stale snapshot can never draw yesterday's feeling — while the
    /// moments the app computed for the NEW date (the asleep night carried past midnight, which only
    /// the clock decides) still apply after the rollover, when the state itself has gone neutral.
    var currentCompanionEmotion: WidgetCompanionEmotion? {
        guard let moments = snapshot?.companionEmotionTimeline else { return nil }
        return WidgetEmotionTimeline.emotion(in: moments, at: date)
    }

    /// Whether the drawn feeling hides the day (asleep): no state word, no care bar.
    var hidesTheDay: Bool {
        currentCompanionEmotion?.hidesTheDay == true
    }

    /// The person's companion look; the plain companion until the app publishes one.
    var look: WidgetCompanionLook {
        snapshot?.companionLook ?? .standard
    }

    /// The companion's name, or nil when the person never gave it one.
    var companionName: String? {
        let name = snapshot?.companionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    /// The care score for the hearts — nil (no hearts) on a stale day, before today has a state, and
    /// while the companion is asleep, when nothing of the day shows.
    var careScore: Double? {
        guard let snapshot, currentDayCompanionState != nil, !hidesTheDay else { return nil }
        return snapshot.score
    }

    /// A friend's gold hearts showing at THIS entry's date, 0...2 (`b4-gold-widgets`): each published
    /// end still ahead. Drawn only beside the hearts, so none on a stale day or while asleep.
    var goldHearts: Int {
        guard careScore != nil, let ends = snapshot?.goldHeartEnds else { return 0 }
        return WidgetHearts.gold(ends: ends, at: date)
    }

    /// The pixel companion for this entry: the person's look in the day's state, asleep or awake. The
    /// state face only — the drawn face never shows a passing feeling but asleep, as on Home's map — so
    /// the Lock Screen's state-only rule holds for every family.
    var companionGrid: WidgetCompanionGrid {
        companionGrid(increasedContrast: false)
    }

    /// The pixel companion for this entry, its outline darker with Increase Contrast (W-03), as the
    /// map draws it.
    func companionGrid(increasedContrast: Bool) -> WidgetCompanionGrid {
        let state = currentDayCompanionState
        let pixelLook = WidgetPixelLook(look: look, state: state, asleep: hidesTheDay)
        return WidgetCompanionPainter.paint(state: state, look: pixelLook, asleep: hidesTheDay,
                                            increasedContrast: increasedContrast)
    }

    /// The written word under the companion: "Asleep" while asleep, else the state's name, else the
    /// app's name when today has no state yet. Display forks only — never a `rawValue`.
    var titleWord: String {
        if let emotion = currentCompanionEmotion, emotion.hidesTheDay { return emotion.displayName }
        return currentDayCompanionState?.displayName ?? String(localized: "Fernlet")
    }

    /// The thought card's caption: "Pip · Thriving", or the word alone when there is no name.
    var caption: String {
        guard let name = companionName else { return titleWord }
        return String(localized: "widget.caption.nameAndWord", defaultValue: "\(name) · \(titleWord)",
                      comment: "Under the companion's thought on the medium widget: its name, then its state word. Example: 'Pip · Thriving'")
    }

    /// The companion's line for this entry's moment (``WidgetThoughtLines``).
    var thought: String {
        WidgetThoughtLines.line(state: currentDayCompanionState,
                                slot: WidgetThoughtSlot.at(date, emotion: currentCompanionEmotion))
    }

    /// What VoiceOver calls the companion: its name, or "Fernlet companion".
    var companionLabel: Text {
        companionName.map { Text(verbatim: $0) } ?? Text("Fernlet companion")
    }
}

/// Timeline provider for the companion and water widgets: reads the mirrored app-group snapshot and
/// builds a timeline of now, every upcoming emotion transition, noon, and the next local midnight,
/// refreshed hourly.
///
/// Every entry reuses the SAME snapshot — each entry's own day gate and emotion lookup (see
/// ``FernletCompanionEntry``) decide what it renders, so the rollover self-corrects with the app
/// closed and no fetch, and a sleepy companion appears at bedtime, an asleep one half an hour later,
/// and the thought card's afternoon line at noon the same way. The hourly `.after` policy only
/// backstops that; real refreshes are pushed by the app via `WidgetCenter` on every snapshot mirror.
struct FernletCompanionProvider: TimelineProvider {
    func placeholder(in context: Context) -> FernletCompanionEntry {
        FernletCompanionEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (FernletCompanionEntry) -> Void) {
        let snapshot = WidgetSnapshotStore().read() ?? (context.isPreview ? .placeholder : nil)
        completion(FernletCompanionEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FernletCompanionEntry>) -> Void) {
        let snapshot = WidgetSnapshotStore().read()
        let now = Date()
        let entries = Self.entryDates(for: snapshot, now: now).map { FernletCompanionEntry(date: $0, snapshot: snapshot) }
        let nextHour = Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: entries, policy: .after(nextHour)))
    }

    /// The moments a timeline over `snapshot` draws from `now` on, in order and each once: now; every
    /// upcoming emotion transition (bedtime, falling asleep, the hunger onset, the wake time…, so the face
    /// changes on time with the app closed; bounded, never at `now`); each of a friend's gold hearts' ends
    /// (at most two); noon (the thought card's morning line gives way to the afternoon one); and the next
    /// local midnight (the day gate turns the same snapshot into a fresh, empty day). The map widget's
    /// timeline (``FernletMapProvider``) shares them.
    static func entryDates(for snapshot: WidgetSnapshot?, now: Date, calendar: Calendar = .current) -> [Date] {
        var dates = [now]
        dates += WidgetEmotionTimeline.transitionDates(in: snapshot?.companionEmotionTimeline ?? [], after: now)
        dates += (snapshot?.goldHeartEnds ?? []).filter { $0 > now }.prefix(WidgetHearts.maxGold)
        let fixedMoments = [
            calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now),
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        ]
        dates += fixedMoments.compactMap { $0 }.filter { $0 > now }
        return Array(Set(dates)).sorted()
    }
}

/// The companion widget: the small card, the medium card with its speech bubble, the Lock Screen face
/// and the Lock Screen rectangle with the hearts and water.
///
/// A `StaticConfiguration` (no user options) keyed by ``FernletWidgetKind/companion`` and driven by
/// ``FernletCompanionProvider``; ``FernletCompanionWidgetView`` picks the per-family layout. The
/// rectangle retired on 2026-10-21 returns as the owner's pick of 2026-10-24 (`b4-new-lock-rect`):
/// hearts and water, its name and hearts hidden until the phone is unlocked. Content margins are off
/// so the paper's ink frame can sit at the widget's own edge.
struct FernletCompanionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: FernletWidgetKind.companion, provider: FernletCompanionProvider()) { entry in
            FernletCompanionWidgetView(entry: entry)
        }
        .configurationDisplayName("Fernlet")
        .description("Your companion, as you dressed it, and how its day is going.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

/// The companion widget's root view: switches on the family, applies privacy per family, and sets the
/// container background (paper on the Home Screen, clear on the Lock Screen).
///
/// `.privacySensitive()` is deliberate policy, not decoration — the companion state encodes
/// wellbeing (including sickness), so every family that shows it redacts on a locked Lock Screen (and
/// in StandBy while locked). The Lock Screen rectangle redacts only its name and hearts: its water
/// stays, as the owner chose.
struct FernletCompanionWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: FernletCompanionEntry

    var body: some View {
        content
            .containerBackground(for: .widget) { containerBackground }
    }

    @ViewBuilder private var content: some View {
        let mono = renderingMode.drawsInOneColour
        switch family {
        case .accessoryCircular:
            CompanionLockView(entry: entry).privacySensitive()
        case .accessoryRectangular:
            CompanionLockRectView(entry: entry)
        case .systemMedium:
            if entry.snapshot == nil {
                PlaceholderView(mono: mono)
            } else {
                CompanionThoughtView(entry: entry, mono: mono).privacySensitive()
            }
        default:
            if entry.snapshot == nil {
                PlaceholderView(mono: mono)
            } else {
                CompanionSmallView(entry: entry, mono: mono).privacySensitive()
            }
        }
    }

    @ViewBuilder private var containerBackground: some View {
        switch family {
        case .accessoryCircular, .accessoryRectangular:
            Color.clear                 // the Lock Screen draws its own material
        default:
            WidgetTheme.current(scheme).paper
        }
    }
}

// MARK: - Palette (widget-local; the widget can't use the app's Color.* extension)

/// The widget target's shared colours: the Live Activities' card and ink, and the companion's state
/// colours.
///
/// Widget-target-internal (not private) so the workout and cooking Live Activities can reuse the
/// same colours without re-declaring the literals — see WorkoutLiveActivity.swift. The widget can't
/// use the app's `Color.*` extension, hence the duplication. The state colours are the app's own
/// `CompanionState.color` values, light and dark (design round 2: one palette everywhere).
enum FernletWidgetPalette {
    // Card + text (9b)
    static let card = Color(red: 0.984, green: 0.969, blue: 0.933)     // #FBF7EE
    static let ink = Color(red: 0.239, green: 0.180, blue: 0.118)      // #3D2E1E
    static let inkSoft = Color(red: 0.541, green: 0.478, blue: 0.384)  // #8A7A62
    static let waterAccent = Color(red: 0.369, green: 0.486, blue: 0.549) // #5E7C8C
    static let waterTrack = Color(red: 0.369, green: 0.486, blue: 0.549).opacity(0.18)
    static let buttonFill = Color(red: 0.353, green: 0.478, blue: 0.322) // #5A7A52 deep moss
    static let buttonInk = Color(red: 0.961, green: 0.937, blue: 0.878)  // #F5EFE0
    static let dashed = Color(red: 0.776, green: 0.718, blue: 0.604)   // #C6B79A
    /// Brighter fern (the "thriving" mood colour) — reads on the Dynamic Island's always-black
    /// background where the deep-brown `ink` would vanish.
    static let leaf = Color(red: 0.420, green: 0.620, blue: 0.384)     // #6B9E62
    /// The water in the small water card's bottle.
    static let waterFill = adaptive(light: 0x94AEBF, dark: 0x7E9BAE)

    /// The neutral taupe no state wears: the asleep companion's body (owner decision 2026-10-21),
    /// and the companion's before today has a state. The twin of the app's `softTaupe`.
    static let night = adaptive(light: 0xB8A892, dark: 0xA39681)

    /// The body colour for a state and the emotion drawn over it: ``night`` while the emotion hides
    /// the day (asleep), else the state's colour.
    static func body(_ state: WidgetCompanionState?, _ emotion: WidgetCompanionEmotion?) -> Color {
        emotion?.hidesTheDay == true ? night : mood(state)
    }

    /// The state's colour — the app's `CompanionState.color`. The Lock Screen and the tinted Home
    /// Screen recolour these away; the cut-out EXPRESSION carries the mood there.
    static func mood(_ state: WidgetCompanionState?) -> Color {
        switch state {
        case .thriving: adaptive(light: 0x5E844D, dark: 0x7FB069)   // moss
        case .okay:     adaptive(light: 0xD2973B, dark: 0xE0A954)   // goldenrod
        case .tired:    adaptive(light: 0xB67073, dark: 0xD88C8F)   // dusty rose
        case .resting:  adaptive(light: 0x7B8B99, dark: 0x9BA8B4)   // slate
        case .sick:     adaptive(light: 0xB9543D, dark: 0xD67558)   // terracotta
        case nil:       night
        }
    }

    /// A colour that follows the widget's appearance.
    private static func adaptive(light: Int, dark: Int) -> Color {
        Color(UIColor { @Sendable trait in
            let value = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        })
    }
}

/// The companion's spoken status, for the families that draw the face as their only reading.
///
/// The words come from ``WidgetCompanionState/displayName`` and ``WidgetCompanionEmotion`` 's display
/// forks, never from a `rawValue` — those raw strings are the cross-process wire tokens, so speaking
/// one would read the persistence format aloud and would stay English after translation. With an
/// emotion the value reads "Okay, feeling sleepy". A day-gated `nil` state has no mood to report,
/// so it says so rather than implying yesterday's state still holds. An emotion that hides the day
/// (asleep) is spoken alone, "Asleep", so the voice says no more about the day than the drawing does.
func companionMoodValue(_ state: WidgetCompanionState?, _ emotion: WidgetCompanionEmotion? = nil) -> Text {
    if let emotion, emotion.hidesTheDay { return Text(emotion.displayName) }
    guard let state else {
        guard let emotion else { return Text("No mood yet today") }
        return Text(emotion.displayName)
    }
    guard let emotion else { return Text(state.displayName) }
    return Text(String(localized: "companionEmotion.stateAndFeeling",
                       defaultValue: "\(state.displayName), \(emotion.feelingPhrase)",
                       comment: "The companion's spoken status: its state, then its feeling. Example: 'Okay, feeling sleepy'"))
}

/// Which widget families may draw the companion's emotion.
///
/// PRIVACY-FORWARD, OWNER-CONFIRMED (2026-09-24: "State face only"): the Lock Screen draws the
/// STATE face only, and the Home Screen families draw the emotion. A sad or hungry face on the Lock
/// Screen tells anyone who glances at the phone how the day went; the Home Screen is only seen
/// unlocked. Asleep is the exception (2026-10-21): it says nothing about the day. The whole
/// companion widget is `.privacySensitive()` besides, so a locked Lock Screen redacts it.
enum FernletWidgetEmotionPolicy {
    /// Whether the Lock Screen draws the emotion. `false` = the state face only.
    static let lockScreenShowsEmotion = false

    /// The emotion a Lock Screen family may draw: one that hides the day (asleep) always — it says
    /// nothing about how the day went, which is the whole reason the Lock Screen is state-only — and
    /// any other only when ``lockScreenShowsEmotion`` allows it.
    static func lockScreenEmotion(_ emotion: WidgetCompanionEmotion?) -> WidgetCompanionEmotion? {
        guard let emotion else { return nil }
        return emotion.hidesTheDay || lockScreenShowsEmotion ? emotion : nil
    }
}
