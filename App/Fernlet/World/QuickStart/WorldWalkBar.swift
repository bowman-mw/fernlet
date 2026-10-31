import FernletUI
import Foundation
import SwiftUI

/// The walk bar across the top while walking together (design `b1-home-walk`, approved 2026-10-23): the
/// distance so far, "Walking together", the precise-location line, and End. It takes the photo strip's
/// place under the status plate.
///
/// VoiceOver hears the distance in 100 m steps, not every reading, and End is the first control after the
/// status plate.
struct WorldWalkBar: View {
    /// Metres walked so far.
    let metres: Double
    /// A walk, or a run on a saved route ("Running", "Precise location on for this run").
    var kind: WorldWalkRecorder.Kind = .walk
    let onEnd: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: WorldWalkCopy.distance(metres))
                        .font(WorldWalkType.distance)
                        .monospacedDigit()
                    Text(kind == .run ? WorldWalkCopy.running : WorldWalkCopy.walking)
                        .font(WorldWalkType.title)
                }
                .foregroundStyle(WorldPalette.bark)
                Text(kind == .run ? WorldWalkCopy.preciseRun : WorldWalkCopy.precise)
                    .font(WorldWalkType.line)
                    .foregroundStyle(WorldWalkPalette.preciseInk)
            }
            .fernletWrappingText()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: WorldWalkCopy.spoken(metres, kind: kind)))
            .accessibilityAddTraits(.updatesFrequently)
            Spacer(minLength: 4)
            endButton
        }
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 9))
        .background(WorldPalette.paper, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldPalette.ink, lineWidth: 3))
        .background {
            RoundedRectangle(cornerRadius: 10).fill(WorldPalette.ink.opacity(0.4)).offset(y: 3)
        }
        .accessibilityElement(children: .contain)
        // Over the map it grows with text size up to the first accessibility size, so End stays in view.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityIdentifier("world.walkBar")
    }

    /// End: stops the walk and logs it.
    private var endButton: some View {
        Button(action: onEnd) {
            Text("End")
                .font(FernletFramedFont.button)
                .foregroundStyle(WorldWalkPalette.onEnd)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(WorldWalkPalette.end, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorldPalette.ink, lineWidth: 3))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(kind == .run ? WorldWalkCopy.endRunLabel : WorldWalkCopy.endLabel))
        .accessibilityInputLabels([Text("End"), Text(kind == .run ? WorldWalkCopy.endRunLabel : WorldWalkCopy.endLabel)])
        .accessibilityIdentifier("world.walkBar.end")
    }
}

/// The note that a walk was logged, over the map's bottom edge with Undo (the approved bike-ride note
/// of `b1-home-bike`: a dark pill above the item bar, cream text, a light moss Undo). It stays four
/// seconds, or the longer assistive window.
struct WorldWalkToast: View {
    let walk: WorldLoggedWalk
    let onUndo: () -> Void

    var body: some View {
        WorldLoggedNote(line: Text(verbatim: WorldWalkCopy.logged(walk)), identifier: .walk, onUndo: onUndo)
    }

    /// The note's distance off the physical bottom, as the approved note sits (just above the item bar).
    static let bottomLift = WorldItemBar.height + WorldItemBar.bottomGap + 14
}

/// The dark note that something was logged, with Undo: the approved `b1-home-bike` note (the kit's
/// `.toast`), shared by the walk's note (``WorldWalkToast``) and the bike ride's (``WorldRideNote``,
/// round 7). Friend shops' closing note (`fr-shop-close`) is the same note with no Undo.
struct WorldLoggedNote: View {
    /// What was logged ("Walk logged · 0.6 km · 12 min").
    let line: Text
    /// Whose note it is, for its automation identifiers.
    let identifier: Identifier
    /// The note's Undo; nil draws the note as text only.
    let onUndo: (() -> Void)?

    /// The note's automation identifiers (frozen tokens): the walk's, the bike ride's, a Flighty import's and
    /// Friend shops' closing note.
    enum Identifier: String {
        case walk = "world.walkToast"
        case ride = "world.rideToast"
        case flights = "world.flightsToast"
        case shopsClosed = "friendShop.closedToast"

        /// The Undo button's.
        var undo: String { rawValue + ".undo" }
    }

    var body: some View {
        HStack(spacing: 12) {
            line
                .font(FernletFramedFont.notice)
                .foregroundStyle(WorldWalkPalette.toastText)
                .fernletWrappingText()
            Spacer(minLength: 4)
            if let onUndo {
                Button(action: onUndo) {
                    Text("Undo")
                        .font(FernletFramedFont.buttonSmall)
                        .foregroundStyle(WorldWalkPalette.toastAction)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier.undo)
            }
        }
        .frame(minHeight: 44)
        .padding(EdgeInsets(top: 2, leading: 15, bottom: 2, trailing: 11))
        .background(WorldWalkPalette.toast, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityIdentifier(identifier.rawValue)
    }
}

/// A walk just logged, for its toast and its Undo.
nonisolated struct WorldLoggedWalk: Equatable, Identifiable, Sendable {
    /// The logged workout's id (Undo removes it, and its line with it).
    let id: UUID
    /// The day it was logged to.
    let dayKey: String
    let metres: Double
    let minutes: Int
    /// Whether it was logged (false in a decoy, where a walk leaves nothing behind; Undo then only closes
    /// the note).
    let isKept: Bool
    /// A walk or a run.
    var kind: WorldWalkRecorder.Kind = .walk
}

/// The walk bar's colours: the End button's brick and the precise line's blue (both from the
/// approved kit, AA on paper in both modes).
nonisolated enum WorldWalkPalette {
    static let end = WorldPalette.adaptive(light: 0x9A4A31, dark: 0x9A4A31)
    static let onEnd = WorldPalette.rgb(0xFFF6E6)
    static let preciseInk = WorldPalette.adaptive(light: 0x1F4E8C, dark: 0x9CC3F0)
    /// The walk note's pill, its text and its Undo (the kit's `.toast`): dark on light, light on dark.
    static let toast = WorldPalette.adaptive(light: 0x3D2E1E, dark: 0xF1EDE3)
    static let toastText = WorldPalette.adaptive(light: 0xF5EFE0, dark: 0x1C1E1B)
    static let toastAction = WorldPalette.adaptive(light: 0xC8DBC2, dark: 0x3F6534)
}

/// The walk bar's type (DM Sans): the distance 21 pt bold, the title 15 pt, the line 13 pt semibold.
nonisolated enum WorldWalkType {
    static let distance = Font.custom(FernletFontName.dmSansBold, size: 21, relativeTo: .title3)
    static let title = Font.custom(FernletFontName.dmSans, size: 15, relativeTo: .subheadline)
    static let line = Font.custom(FernletFontName.dmSansBold, size: 13, relativeTo: .footnote)
}

/// The walk's words.
nonisolated enum WorldWalkCopy {
    static let walking = LocalizedStringResource("worldWalk.title", defaultValue: "Walking together",
                                                 comment: "World Home walk bar: what is happening while a walk records")
    static let precise = LocalizedStringResource("worldWalk.precise", defaultValue: "Precise location on for this walk",
                                                 comment: "World Home walk bar: precise location is used for this walk only")
    static let endLabel = LocalizedStringResource("worldWalk.end", defaultValue: "End walk",
                                                  comment: "World Home walk bar, VoiceOver: the End button stops and logs the walk")
    static let undone = LocalizedStringResource("worldWalk.undone", defaultValue: "Walk removed.",
                                                comment: "World Home, VoiceOver: said after the walk note's Undo removed the walk")
    static let running = LocalizedStringResource("worldWalk.running", defaultValue: "Running",
                                                 comment: "World Home walk bar: what is happening while a run on a saved route records")
    static let preciseRun = LocalizedStringResource("worldWalk.precise.run", defaultValue: "Precise location on for this run",
                                                    comment: "World Home walk bar during a run: precise location is used for this run only")
    static let endRunLabel = LocalizedStringResource("worldWalk.end.run", defaultValue: "End run",
                                                     comment: "World Home walk bar, VoiceOver: the End button stops and logs the run")
    static let undoneRun = LocalizedStringResource("worldWalk.undone.run", defaultValue: "Run removed.",
                                                   comment: "World Home, VoiceOver: said after the run note's Undo removed the run")

    /// The distance as the person's region writes a road distance ("0.6 km", "0.4 mi").
    static func distance(_ metres: Double) -> String {
        Measurement(value: max(0, metres), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.significantDigits(1...2))))
    }

    /// What VoiceOver reads: the distance in 100 m steps, so it changes every 100 m, not every reading.
    static func spoken(_ metres: Double, kind: WorldWalkRecorder.Kind = .walk) -> String {
        let stepped = (max(0, metres) / 100).rounded(.down) * 100
        let distance = Measurement(value: stepped, unit: UnitLength.meters)
            .formatted(.measurement(width: .wide, usage: .road, numberFormatStyle: .number.precision(.significantDigits(1...2))))
        guard kind == .walk else {
            return String(localized: "worldWalk.spoken.run", defaultValue: "Running, \(distance)",
                          comment: "World Home walk bar, VoiceOver: the run so far, e.g. 'Running, 0.6 kilometres'")
        }
        return String(localized: "worldWalk.spoken", defaultValue: "Walking together, \(distance)",
                      comment: "World Home walk bar, VoiceOver: the walk so far, e.g. 'Walking together, 0.6 kilometres'")
    }

    /// The toast's line: "Walk logged · 0.6 km · 12 min".
    static func logged(_ walk: WorldLoggedWalk) -> String {
        let distance = Self.distance(walk.metres)
        guard walk.kind == .walk else {
            return String(localized: "worldWalk.logged.run", defaultValue: "Run logged · \(distance) · \(walk.minutes) min",
                          comment: "World Home: the note after a run ends; its distance and minutes")
        }
        return String(localized: "worldWalk.logged", defaultValue: "Walk logged · \(distance) · \(walk.minutes) min",
                      comment: "World Home: the note after a walk ends; its distance and minutes")
    }
}
