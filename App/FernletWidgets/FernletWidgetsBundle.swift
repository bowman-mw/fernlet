// FernletWidgetsBundle.swift
// FernletWidgets
//
// The extension's entry point, the companion widget's timeline, and the palette the widgets and the
// Live Activities share. Design round 2 (2026-10-21): the companion is drawn as the person dressed
// it (WidgetCompanionFigure.swift), the small card shows the companion and its care bar, the medium
// card its thought, the Lock Screen its face alone; water has its own widget and Control Center
// control (WaterWidget.swift). Companion mood, look and water only — never anything sensitive.

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
}

/// The deep links a widget tap opens. The app's `FernletWidgetLinkRouter` reads the same two
/// spellings; `WidgetBridgeTests` pins that they match.
enum FernletWidgetLink {
    /// Opens the app on Home.
    static let home = URL(string: "fernlet-world://widget/home")
    /// Opens the app's Water sheet, where a mis-tapped bottle can be undone.
    static let water = URL(string: "fernlet-world://widget/water")
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

    /// The care score for the bar — nil (no bar) on a stale day, before today has a state, and while
    /// the companion is asleep, when nothing of the day shows.
    var careScore: Double? {
        guard let snapshot, currentDayCompanionState != nil, !hidesTheDay else { return nil }
        return snapshot.score
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
        var entries = [FernletCompanionEntry(date: now, snapshot: snapshot)]

        // One entry at each upcoming emotion transition (bedtime, falling asleep, the hunger onset, the
        // wake time…), so the face changes on time with the app closed. Bounded, and never at `now`.
        let transitions = WidgetEmotionTimeline.transitionDates(in: snapshot?.companionEmotionTimeline ?? [], after: now)
        entries += transitions.map { FernletCompanionEntry(date: $0, snapshot: snapshot) }

        // Noon (the thought card's morning line gives way to the afternoon one) and the next local
        // midnight (the day gate turns the same snapshot into a fresh, empty day), each from the
        // SAME snapshot and each only once.
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let fixedMoments = [
            calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now),
            calendar.date(byAdding: .day, value: 1, to: startOfToday)
        ]
        for moment in fixedMoments.compactMap({ $0 }) where moment > now && !entries.contains(where: { $0.date == moment }) {
            entries.append(FernletCompanionEntry(date: moment, snapshot: snapshot))
        }
        entries.sort { $0.date < $1.date }

        let nextHour = calendar.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: entries, policy: .after(nextHour)))
    }
}

/// The companion widget: the small companion card, the medium thought card, and the Lock Screen
/// face.
///
/// A `StaticConfiguration` (no user options) keyed by ``FernletWidgetKind/companion`` and driven by
/// ``FernletCompanionProvider``; ``FernletCompanionWidgetView`` picks the per-family layout. The
/// rectangular Lock Screen card was retired (owner, 2026-10-21): the Lock Screen keeps the face.
struct FernletCompanionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: FernletWidgetKind.companion, provider: FernletCompanionProvider()) { entry in
            FernletCompanionWidgetView(entry: entry)
        }
        .configurationDisplayName("Fernlet")
        .description("Your companion, as you dressed it, and how its day is going.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}

/// The companion widget's root view: switches on the family and applies the two cross-family
/// modifiers (privacy redaction and the container background).
///
/// `.privacySensitive()` is deliberate policy, not decoration — the companion state encodes
/// wellbeing (including sickness), so the whole widget redacts on a locked Lock Screen.
struct FernletCompanionWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    let entry: FernletCompanionEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                CompanionLockView(entry: entry)
            case .systemMedium:
                if entry.snapshot == nil { PlaceholderView() } else { CompanionThoughtView(entry: entry) }
            default:
                if entry.snapshot == nil { PlaceholderView() } else { CompanionSmallView(entry: entry) }
            }
        }
        // Companion state encodes wellbeing (incl. sickness) — redact on a locked Lock Screen.
        .privacySensitive()
        .containerBackground(for: .widget) { containerBackground }
    }

    @ViewBuilder private var containerBackground: some View {
        switch family {
        case .accessoryCircular:
            Color.clear                 // the Lock Screen draws its own material
        case .systemMedium:
            WidgetTheme.current(scheme).cardAlt
        default:
            WidgetTheme.current(scheme).card
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
