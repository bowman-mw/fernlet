//
//  ExerciseDemonstrationView.swift
//  Fernlet
//
//  Draws the how-to sheet's demonstration (comparison report idea 8) when the exercise has no approved
//  animation (a custom exercise): a bundled GIF played a frame at a time with ImageIO, a still
//  illustration or frozen first frame, or the placeholder tile. Frames are decoded downsampled to the
//  drawn size, one at a time, so a long GIF never sits in memory whole. Playback stops when the tile
//  scrolls out of view, the app leaves the foreground or the sheet closes, and a tap pauses a loop on
//  the frame it shows (WCAG 2.2.2; tracker row C1), with a small pause or play mark in the corner so
//  the tap is discoverable. The owner's approved animations (r12) draw in `ExerciseAnimationTile.swift`,
//  which shares this file's layout, spoken name, pause words, pause access and corner mark.
//

import SwiftUI
import ImageIO
import FernletDomainModel
import FernletUI

/// The demonstration tile's geometry. The media is a picture, not text, so it does not grow with
/// Dynamic Type; the sheet scrolls instead.
///
/// The tile is square (the approved animation tile, ``ExerciseAnimationTile``, is 4:3 at the same
/// width), and its side follows the height the sheet shows. At the medium detent it is about half of
/// what is visible, so the first cues still show under it. At the large detent it is the full
/// ``maxSide``.
enum ExerciseDemonstrationLayout {
    /// The longest side a demonstration is drawn at, in points (square, centred, narrower on a
    /// narrow sheet). Frames are decoded at this size times the display scale.
    static let maxSide: CGFloat = 320
    /// The smallest side, however short the sheet.
    static let minSide: CGFloat = 160
    /// The share of the sheet's visible height the tile takes before it reaches ``maxSide``.
    static let visibleShare: CGFloat = 0.5
    static let glyphSize: CGFloat = 40
    static let cornerRadius: CGFloat = 16

    /// The tile's side for a sheet showing `visibleHeight` points of content: half of it, held between
    /// ``minSide`` and ``maxSide``. Zero (not yet measured) or anything unusable gives ``maxSide``.
    static func side(forVisibleHeight visibleHeight: CGFloat) -> CGFloat {
        guard visibleHeight.isFinite, visibleHeight > 0 else { return maxSide }
        return min(max(visibleHeight * visibleShare, minSide), maxSide)
    }
}

/// One bundled demonstration file drawn as a square tile: a looping animation or a still.
///
/// VoiceOver reads it as one image, "Demonstration of <display name>"; the numbered cues below it
/// are the description an animation cannot give. It ignores Smart Invert, like a photo. The loop
/// runs only while the tile is on screen, the app is in the foreground and the person has not paused
/// it: `.task` is cancelled when the sheet closes, and the playback key changes (ending the loop)
/// when the tile scrolls out of view, the scene leaves `.active` or a tap pauses it.
///
/// **Pausing (WCAG 2.2.2, tracker row C1).** A tap on a looping tile pauses it on the frame it
/// shows and a second tap carries on from that frame; a small pause or play mark in the corner
/// (``ExerciseDemonstrationPauseBadge``) says the tap is there. VoiceOver keeps the one image
/// element and gains a value ("Playing" or "Paused") and an action ("Pause" or "Play"), which a
/// double-tap also performs; Voice Control answers to "Pause" or "Play" and "Demonstration" (rule
/// A9). A still, the Reduce Motion picture or the placeholder has nothing to pause and shows none
/// of it.
struct ExerciseDemonstrationMedia: View {
    let fileName: String
    let animates: Bool
    /// The frozen catalog name; the spoken label draws its display name.
    let exerciseName: String
    /// The tile's side, from ``ExerciseDemonstrationLayout/side(forVisibleHeight:)``.
    let side: CGFloat

    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    /// The frame on screen; nil until the first decode.
    @State private var currentFrame: CGImage?
    /// Which frame ``currentFrame`` is, so a pause, a scroll away or a trip to the background holds
    /// it and the next playback carries on from it.
    @State private var frameIndex = 0
    @State private var isOnScreen = true
    /// The person paused the loop: a tap on the tile, or the Pause action.
    @State private var isPaused = false

    /// "Demonstration of Bulgarian split squat": three spoken words around the drawn name.
    private var spokenName: Text {
        ExerciseDemonstrationSpokenName.text(for: exerciseName)
    }

    private var playback: ExerciseDemonstrationPlayback {
        ExerciseDemonstrationPlayback(
            fileName: fileName,
            loops: ExerciseDemonstrationPlayback.loops(
                animates: animates, isOnScreen: isOnScreen, isActive: scenePhase == .active, isPaused: isPaused),
            maxPixelSize: Int((ExerciseDemonstrationLayout.maxSide * displayScale).rounded(.up))
        )
    }

    var body: some View {
        ZStack {
            Color.cream
            if let currentFrame {
                Image(decorative: currentFrame, scale: displayScale)
                    .resizable()
                    .scaledToFit()
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .bottomTrailing) {
            if animates {
                ExerciseDemonstrationPauseBadge(isPaused: isPaused)
            }
        }
        .frame(maxWidth: side)
        .clipShape(RoundedRectangle(cornerRadius: ExerciseDemonstrationLayout.cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: ExerciseDemonstrationLayout.cornerRadius))
        .onTapGesture { togglePause() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenName)
        .accessibilityAddTraits(.isImage)
        .modifier(ExerciseDemonstrationPauseAccess(pausable: animates, isPaused: isPaused, toggle: togglePause))
        .accessibilityIgnoresInvertColors()
        .frame(maxWidth: .infinity)
        .onScrollVisibilityChange(threshold: 0.1) { isOnScreen = $0 }
        .task(id: playback) { await play(playback) }
    }

    /// Pauses a looping demonstration, or plays it again. A still has nothing to pause.
    private func togglePause() {
        guard animates else { return }
        isPaused.toggle()
    }

    /// Draws the frame the last playback stopped on (the first, for a still), then, for a looping
    /// playback, each next frame after the current one's delay until the task is cancelled or
    /// ``ExerciseDemonstrationFrames/maxTicks`` frames have shown.
    private func play(_ playback: ExerciseDemonstrationPlayback) async {
        guard let url = ExerciseDemonstrationLibrary.url(for: playback.fileName),
              let frames = ExerciseDemonstrationFrames(url: url, maxPixelSize: playback.maxPixelSize) else {
            currentFrame = nil
            return
        }
        var index = ExerciseDemonstrationPlayback.startFrame(saved: frameIndex, count: frames.count, animates: animates)
        show(frames, at: index)
        guard playback.loops, frames.count > 1 else { return }
        // Bounded by maxTicks (Power of 10 rule 2); cancellation ends it far sooner in practice.
        for _ in 1...ExerciseDemonstrationFrames.maxTicks {
            do {
                try await Task.sleep(for: .seconds(frames.delay(at: index)))
            } catch {
                // Cancelled: the sheet closed, the tile left the screen, it was paused, or the
                // playback changed. The frame on screen stays, and so does its index.
                return
            }
            index = (index + 1) % frames.count
            show(frames, at: index)
        }
    }

    /// Puts frame `index` on screen and remembers which it is.
    private func show(_ frames: ExerciseDemonstrationFrames, at index: Int) {
        currentFrame = frames.image(at: index)
        frameIndex = index
    }
}

/// What a demonstration tile is playing, as its `.task` identity: a change restarts playback.
struct ExerciseDemonstrationPlayback: Equatable {
    let fileName: String
    /// Animate in a loop; false holds one frame (a still, Reduce Motion, off screen, in the
    /// background, or paused).
    let loops: Bool
    /// The longest side, in pixels, frames are decoded at.
    let maxPixelSize: Int

    /// Whether a tile loops: an animation that is on screen, in an active scene, and not paused by
    /// the person. Anything else holds the frame on screen.
    static func loops(animates: Bool, isOnScreen: Bool, isActive: Bool, isPaused: Bool) -> Bool {
        animates && isOnScreen && isActive && !isPaused
    }

    /// The frame a playback starts on: for an animation, the one the last playback stopped on
    /// (`saved`), wrapped into this file's `count` frames, so a pause holds its frame and play carries
    /// on from it; for a still (Reduce Motion's frozen first frame included), always the first.
    static func startFrame(saved: Int, count: Int, animates: Bool) -> Int {
        guard animates, count > 0, saved > 0 else { return 0 }
        return saved % count
    }
}

/// The words a pausable demonstration speaks and answers to, written once so each catalog key
/// carries one comment.
enum ExerciseDemonstrationPauseWords {
    /// The action that stops the loop, and its Voice Control name while it plays.
    static var pause: Text {
        Text("Pause", comment: "Exercise how-to sheet: the action that pauses the looping demonstration; also its Voice Control name while it plays")
    }
    /// The action that starts the loop again, and its Voice Control name while it is paused.
    static var play: Text {
        Text("Play", comment: "Exercise how-to sheet: the action that plays a paused demonstration again; also its Voice Control name while paused")
    }
    /// The spoken value while the loop is paused.
    static var paused: Text {
        Text("Paused", comment: "Exercise how-to sheet: VoiceOver value of the demonstration while its loop is paused")
    }
    /// The spoken value while the loop plays.
    static var playing: Text {
        Text("Playing", comment: "Exercise how-to sheet: VoiceOver value of the demonstration while its loop plays")
    }
    /// The demonstration's short Voice Control name, whatever its state.
    static var demonstration: Text {
        Text("Demonstration", comment: "Exercise how-to sheet: short Voice Control name of the demonstration picture")
    }
}

/// The spoken name every demonstration tile shares, written once so its catalog key carries one
/// comment: ``ExerciseDemonstrationMedia`` and the approved animation tile (``ExerciseAnimationTile``)
/// both read "Demonstration of <display name>".
enum ExerciseDemonstrationSpokenName {
    /// "Demonstration of Bulgarian split squat": three spoken words around the drawn name of the
    /// frozen catalog name `exerciseName`.
    static func text(for exerciseName: String) -> Text {
        Text("Demonstration of \(ExerciseHowToCatalog.displayName(for: exerciseName))",
             comment: "VoiceOver label for the exercise demonstration animation or picture in the how-to sheet. %@ is the exercise name.")
    }
}

/// The pause controls a moving demonstration adds to its one image element, and nothing for a
/// still: the value ("Playing" or "Paused"), the named action ("Pause" or "Play"), the same toggle
/// on activation (a VoiceOver double-tap, Voice Control's "Tap Pause"), short input labels (rule A9)
/// and the flag that makes Voice Control offer the element at all. Shared by the looping
/// demonstration (``ExerciseDemonstrationMedia``) and the approved animation tile
/// (``ExerciseAnimationTile``).
struct ExerciseDemonstrationPauseAccess: ViewModifier {
    /// The tile animates, so there is a loop to pause.
    let pausable: Bool
    let isPaused: Bool
    let toggle: () -> Void

    func body(content: Content) -> some View {
        if pausable {
            content
                .accessibilityValue(isPaused ? ExerciseDemonstrationPauseWords.paused : ExerciseDemonstrationPauseWords.playing)
                .accessibilityAction(named: isPaused ? ExerciseDemonstrationPauseWords.play : ExerciseDemonstrationPauseWords.pause) { toggle() }
                .accessibilityAction(.default) { toggle() }
                .accessibilityInputLabels([
                    isPaused ? ExerciseDemonstrationPauseWords.play : ExerciseDemonstrationPauseWords.pause,
                    ExerciseDemonstrationPauseWords.demonstration,
                ])
                .accessibilityRespondsToUserInteraction(true)
        } else {
            content
        }
    }
}

/// The small mark in a moving demonstration's bottom-trailing corner (a looping GIF or an approved
/// animation): a pause glyph while it plays and a play glyph while it is paused, so a sighted person
/// knows a tap pauses it.
///
/// Drawn in theme tokens so it holds its contrast in light, dark, Increase Contrast and a custom
/// theme alike: a `bark` glyph on a `parchment` disc (the theme's own body-text pair), ringed in
/// full-strength `slate`, which the theme keeps at 4.5:1 or more against `parchment`, so the disc
/// stands apart from a white frame and a dark one. The glyph's shape, not its colour, carries the
/// state. Decorative to assistive technologies: the tile's own value and action say the same.
/// The tile is the tap target; the mark only shows it. Its glyph grows with Dynamic Type up to
/// extra large, inside a disc that stays small so it never covers the demonstration.
struct ExerciseDemonstrationPauseBadge: View {
    let isPaused: Bool
    /// The disc's diameter, in points.
    static let diameter: CGFloat = 34

    var body: some View {
        Image(systemName: isPaused ? "play.fill" : "pause.fill")
            .font(.callout.weight(.bold))
            .foregroundStyle(Color.bark)
            .frame(width: Self.diameter, height: Self.diameter)
            .background(Color.parchment, in: Circle())
            .overlay(Circle().strokeBorder(Color.slate, lineWidth: 1.5))
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .padding(10)
            .accessibilityHidden(true)
    }
}

/// One bundled image file, decoded a frame at a time at a bounded pixel size with ImageIO.
///
/// A thumbnail decode per frame keeps memory to one display-sized bitmap however long the GIF is;
/// ImageIO composites each GIF frame over its predecessors itself. Frame delays follow the GIF's own
/// timing, with the browsers' rule for a near-zero delay.
struct ExerciseDemonstrationFrames {
    /// Frames played per file; a longer GIF loops its first `maxFrames`.
    static let maxFrames = 600
    /// Frames shown per playback before it rests on the current one (about half an hour at the
    /// GIFs' usual 10 to 20 frames a second).
    static let maxTicks = 36_000
    /// A frame's delay when the file gives none, or one under 11 ms (drawn at 100 ms, as browsers do).
    static let defaultDelay = 0.1
    /// The longest a single frame is held.
    static let maxDelay = 5.0

    let count: Int
    private let source: CGImageSource
    private let maxPixelSize: Int
    private let delays: [Double]

    init?(url: URL, maxPixelSize: Int) {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let frameCount = min(CGImageSourceGetCount(source), Self.maxFrames)
        guard frameCount > 0 else { return nil }
        self.source = source
        self.count = frameCount
        self.maxPixelSize = maxPixelSize
        self.delays = (0..<frameCount).map { Self.frameDelay(source, at: $0) }
    }

    /// Frame `index`, decoded with its longest side at most `maxPixelSize` pixels.
    func image(at index: Int) -> CGImage? {
        guard (0..<count).contains(index) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    /// How long frame `index` shows, in seconds.
    func delay(at index: Int) -> Double {
        guard delays.indices.contains(index) else { return Self.defaultDelay }
        return delays[index]
    }

    /// The GIF delay ImageIO reports for frame `index`, clamped; a non-GIF frame gets the default.
    private static func frameDelay(_ source: CGImageSource, at index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return defaultDelay
        }
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        return clampedDelay(unclamped ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? defaultDelay)
    }

    /// `seconds` held between 11 ms (anything shorter is drawn at ``defaultDelay``) and ``maxDelay``.
    static func clampedDelay(_ seconds: Double) -> Double {
        guard seconds.isFinite, seconds >= 0.011 else { return defaultDelay }
        return min(seconds, maxDelay)
    }
}

/// The tile shown when this build carries no demonstration for the exercise: a stand-in picture the
/// size and shape of the real one. It's a blank cream square with the equipment glyph, small and muted,
/// over a framed text box holding the exercise's drawn name, in light and dark. The licensed media
/// replaces it file by file as it lands in the drop folder; nothing else changes.
///
/// Decorative, so VoiceOver skips it: the heading above already names the exercise and the facts below
/// name the equipment. It says nothing about media to come. Its name is the heading's copy, so its type
/// stops growing at the first accessibility size and shrinks to fit rather than overflow the square.
/// The heading grows without limit.
struct ExerciseDemonstrationPlaceholder: View {
    /// The frozen catalog name; the box draws its display name.
    let exerciseName: String
    let target: ExerciseTarget?
    /// The tile's side, from ``ExerciseDemonstrationLayout/side(forVisibleHeight:)``.
    let side: CGFloat

    /// World build (`b3-howto`): a framed tile, the equipment glyph in ink, the name in a framed box.
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        ZStack {
            look?.raised ?? Color.cream
            VStack(spacing: 14) {
                EquipmentGlyph(item: Self.glyph(for: target), size: ExerciseDemonstrationLayout.glyphSize)
                    .foregroundStyle(look?.text ?? Color.softTaupe)
                Text(verbatim: ExerciseHowToCatalog.displayName(for: exerciseName))
                    .font(look == nil ? .fernlet(.headerMedium) : MoveFont.rowTitle)
                    .foregroundStyle(look?.text ?? Color.bark)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(look?.paper ?? Color.parchment, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(look?.ink ?? Color.softTaupe, lineWidth: look == nil ? 1 : FernletFramedLook.frameWidth))
            }
            .padding(20)
        }
        .modifier(ExerciseDemonstrationPlaceholderShape(isFramed: look != nil, side: side))
        .overlay {
            if let look {
                RoundedRectangle(cornerRadius: ExerciseDemonstrationLayout.cornerRadius)
                    .strokeBorder(look.ink, lineWidth: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ExerciseDemonstrationLayout.cornerRadius))
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    /// The glyph for an exercise: the tool it is done with, or for a bodyweight move the one piece of
    /// gear it needs (a pull-up bar), else a mat. A generic weight machine draws the seated-machine
    /// glyph.
    static func glyph(for target: ExerciseTarget?) -> GymEquipment {
        guard let target else { return .yogaMat }
        switch target.equipment {
        case .barbell: return .barbell
        case .dumbbell: return .dumbbells
        case .kettlebell: return .kettlebells
        case .band: return .resistanceBands
        case .bench: return .weightBench
        case .cable: return .cableMachine
        case .machine: return target.requiredGear.first ?? .chestPress
        case .cardio: return target.requiredGear.first ?? .treadmill
        case .bodyweight, .none: return target.requiredGear.first ?? .yogaMat
        }
    }
}

/// The placeholder tile's shape: today's square the size of a real demonstration, or under the World look
/// (`b3-howto` draft 2) a full-width card no taller than the kit's, so the steps and the run's footer
/// stay in view. A real demonstration keeps its square either way.
private struct ExerciseDemonstrationPlaceholderShape: ViewModifier {
    let isFramed: Bool
    let side: CGFloat
    /// The kit's card height in points.
    private static let framedHeight: CGFloat = 168

    func body(content: Content) -> some View {
        if isFramed {
            content
                .frame(maxWidth: .infinity)
                .frame(height: min(side, Self.framedHeight))
        } else {
            content
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: side)
        }
    }
}
