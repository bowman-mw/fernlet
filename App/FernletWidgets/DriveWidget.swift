// DriveWidget.swift
// FernletWidgets
//
// The drive widget (owner's pick 2026-11-13, "Small widget: new tiles"): small only, so iOS 26 can show it in CarPlay
// with no CarPlay app or entitlement. During a drive it reads "+12 new tiles · this drive", for three hours after
// one "last drive", and otherwise it is Sprout. It reads the app's `WidgetDrive.json` (a count and two times, never a
// place). The widget runs on the iPhone, so it saves no battery: the drive's cost is the app's trace.

import SwiftUI
import WidgetKit

/// The drive as the app hands it over: twin of the app's `WorldDriveWidgetState` (the JSON keys are the contract).
struct WidgetDriveState: Codable, Equatable {
    /// The one format this widget reads.
    static let currentVersion = 1

    var version: Int
    /// New tiles the drive uncovered.
    var tiles: Int
    /// When it started.
    var startedAt: Date
    /// When it was last heard from.
    var updatedAt: Date
    /// Whether it was under way as of ``updatedAt``.
    var isDriving: Bool
}

/// Reads the drive's file from the app group.
struct WidgetDriveStore {
    /// The file's name (twin of `WorldDriveWidget.fileName`).
    static let fileName = "WidgetDrive.json"

    /// The drive on disk, or nil (none, unreadable, or another format).
    func read() -> WidgetDriveState? {
        let url = WidgetBridgeFiles.containerDirectory().appendingPathComponent(Self.fileName)
        guard let data = try? Data(contentsOf: url), data.count <= 4_096,
              let state = try? JSONDecoder().decode(WidgetDriveState.self, from: data),
              state.version == WidgetDriveState.currentVersion else { return nil }
        return state
    }
}

/// What the widget shows at a moment, and when that changes. Pure: a state and a date in.
enum WidgetDriveShelf {
    /// What shows.
    enum Shown: Equatable {
        /// The drive under way, with its new tiles.
        case thisDrive(Int)
        /// The drive just ended, with its new tiles.
        case lastDrive(Int)
        /// No drive to show: Sprout.
        case sprout
    }

    /// A drive not heard from for this long has ended (the app hands the count over at least every 20 minutes).
    static let quietEnd: TimeInterval = 30 * 60
    /// How long an ended drive's count stays.
    static let keepsFor: TimeInterval = 3 * 60 * 60

    /// When `state`'s drive ended, or will count as ended if nothing more is heard.
    static func end(of state: WidgetDriveState) -> Date {
        state.isDriving ? state.updatedAt.addingTimeInterval(quietEnd) : state.updatedAt
    }

    /// What shows at `date`. A drive with no new tiles shows Sprout.
    static func shown(_ state: WidgetDriveState?, at date: Date) -> Shown {
        guard let state, state.tiles > 0 else { return .sprout }
        let end = end(of: state)
        if state.isDriving, date < end { return .thisDrive(state.tiles) }
        return date < end.addingTimeInterval(keepsFor) ? .lastDrive(state.tiles) : .sprout
    }

    /// The moments after `now` when what shows changes.
    static func changes(_ state: WidgetDriveState?, after now: Date) -> [Date] {
        guard let state, state.tiles > 0 else { return [] }
        let end = end(of: state)
        return [end, end.addingTimeInterval(keepsFor)].filter { $0 > now }
    }
}

/// One moment of the drive widget: the companion's entry and the drive.
struct FernletDriveEntry: TimelineEntry {
    let companion: FernletCompanionEntry
    let drive: WidgetDriveState?

    var date: Date { companion.date }
    var shown: WidgetDriveShelf.Shown { WidgetDriveShelf.shown(drive, at: date) }
}

/// The drive widget's timeline: now, and when the drive's count turns to "last drive" and then to Sprout, over the
/// companion's own moments. Reloaded by the app as a drive's count moves (at most every five minutes).
struct FernletDriveProvider: TimelineProvider {
    func placeholder(in context: Context) -> FernletDriveEntry {
        FernletDriveEntry(companion: FernletCompanionEntry(date: Date(), snapshot: .placeholder), drive: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (FernletDriveEntry) -> Void) {
        let now = Date()
        let preview = WidgetDriveState(version: WidgetDriveState.currentVersion, tiles: 12, startedAt: now,
                                       updatedAt: now, isDriving: true)
        let snapshot = WidgetSnapshotStore().read() ?? (context.isPreview ? .placeholder : nil)
        completion(FernletDriveEntry(companion: FernletCompanionEntry(date: now, snapshot: snapshot),
                                     drive: context.isPreview ? preview : WidgetDriveStore().read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FernletDriveEntry>) -> Void) {
        let snapshot = WidgetSnapshotStore().read()
        let drive = WidgetDriveStore().read()
        let now = Date()
        let dates = Set(FernletCompanionProvider.entryDates(for: snapshot, now: now) + WidgetDriveShelf.changes(drive, after: now))
        let entries = dates.sorted().map {
            FernletDriveEntry(companion: FernletCompanionEntry(date: $0, snapshot: snapshot), drive: drive)
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

/// The small drive widget. A `StaticConfiguration` keyed by ``FernletWidgetKind/drive``, small only (what CarPlay
/// shows).
struct FernletDriveWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: FernletWidgetKind.drive, provider: FernletDriveProvider()) { entry in
            DriveWidgetView(entry: entry)
        }
        .configurationDisplayName(Text("Your drive", comment: "The small drive widget's name in the widget gallery (it also shows in CarPlay)"))
        .description(Text("The new tiles your drive uncovers, or Sprout when you're not driving.",
                          comment: "The small drive widget's description in the widget gallery"))
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

/// The drive widget's words.
enum DriveWords {
    /// "+12".
    static func plus(_ tiles: Int) -> String {
        String(localized: "widget.drive.plus", defaultValue: "+\(tiles)",
               comment: "The drive widget's big number: new map tiles the drive uncovered, with a plus sign")
    }

    /// "new tiles" / "new tile".
    static func tilesWord(_ tiles: Int) -> String {
        tiles == 1
            ? String(localized: "widget.drive.tiles.one", defaultValue: "new tile",
                     comment: "The drive widget, under its +1: one new map tile")
            : String(localized: "widget.drive.tiles.other", defaultValue: "new tiles",
                     comment: "The drive widget, under its big number: new map tiles (never one)")
    }

    /// "this drive" / "last drive".
    static func when(_ shown: WidgetDriveShelf.Shown) -> String {
        if case .thisDrive = shown {
            return String(localized: "widget.drive.this", defaultValue: "this drive",
                          comment: "The drive widget, under the count while the drive is under way")
        }
        return String(localized: "widget.drive.last", defaultValue: "last drive",
                      comment: "The drive widget, under the count for a drive that ended in the last three hours")
    }

    /// VoiceOver: "12 new tiles this drive".
    static func spoken(_ tiles: Int, _ shown: WidgetDriveShelf.Shown) -> String {
        let count = tiles == 1
            ? String(localized: "widget.drive.spoken.one", defaultValue: "1 new tile",
                     comment: "The drive widget's VoiceOver count: one new map tile")
            : String(localized: "widget.drive.spoken.other", defaultValue: "\(tiles) new tiles",
                     comment: "The drive widget's VoiceOver count: new map tiles (never one)")
        let when = when(shown)
        return String(localized: "widget.drive.spoken", defaultValue: "\(count), \(when)",
                      comment: "The drive widget's VoiceOver label: the count, then this drive or last drive")
    }
}

/// The drive widget's face: Sprout over the count while there is a drive to show, else Sprout and its name.
struct DriveWidgetView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: FernletDriveEntry

    var body: some View {
        let mono = renderingMode.drawsInOneColour
        if let scene = entry.companion.cardScene(dark: scheme == .dark, mono: mono) {
            // The person's background fills the card, Sprout on its ground (owner's pick A).
            DriveSceneView(entry: entry)
                .containerBackground(for: .widget) { WidgetCardGround(scene: scene, paper: WidgetTheme.current(scheme).paper) }
        } else {
            paperCard(mono: mono)
        }
    }

    /// The paper card: the plain background, and every one-colour rendering.
    private func paperCard(mono: Bool) -> some View {
        let theme = mono ? WidgetTheme.mono : WidgetTheme.current(scheme, contrast: contrast)
        return Group {
            switch entry.shown {
            case .thisDrive(let tiles), .lastDrive(let tiles):
                VStack(spacing: 2) {
                    sprite(scale: 3, mono: mono)
                    Text(verbatim: DriveWords.plus(tiles))
                        .font(WidgetFont.display(30))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(verbatim: DriveWords.tilesWord(tiles))
                        .font(WidgetFont.label(13))
                        .foregroundStyle(theme.text)
                    Text(verbatim: DriveWords.when(entry.shown))
                        .font(WidgetFont.label(12))
                        .foregroundStyle(theme.muted)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: DriveWords.spoken(tiles, entry.shown)))
            case .sprout:
                VStack(spacing: 4) {
                    sprite(scale: 5, mono: mono)
                    entry.companion.companionLabel
                        .font(WidgetFont.display(17))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .privacySensitive()
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) { theme.paper }
        .overlay { ContainerRelativeShape().strokeBorder(theme.frame, lineWidth: 3) }
        .widgetURL(FernletWidgetLink.home)
    }

    /// Sprout as the person dressed it; its day shows in its face, so it redacts while locked (the count does not).
    private func sprite(scale: CGFloat, mono: Bool) -> some View {
        WidgetCompanionSprite(grid: entry.companion.homeScreenGrid(increasedContrast: contrast == .increased),
                              scale: scale, ink: mono ? .silhouette(0xFFFFFF) : .color,
                              showsZee: entry.companion.hidesTheDay)
            .privacySensitive()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.companion.companionLabel)
    }
}
