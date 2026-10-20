//
//  ExerciseDemonstrationView.swift
//  Fernlet
//
//  Draws the how-to sheet's demonstration (comparison report idea 8): a bundled GIF played a frame at
//  a time with ImageIO, a still illustration or frozen first frame, or the placeholder tile. Frames
//  are decoded downsampled to the drawn size, one at a time, so a long GIF never sits in memory whole.
//  Playback stops when the tile scrolls out of view, the app leaves the foreground or the sheet closes.
//

import SwiftUI
import ImageIO
import FernletDomainModel
import FernletUI

/// The demonstration tile's fixed geometry. The media is a picture, not text, so it does not grow
/// with Dynamic Type; the sheet scrolls instead.
enum ExerciseDemonstrationLayout {
    /// The longest side a demonstration is drawn at, in points (square, centred, narrower on a
    /// narrow sheet). Frames are decoded at this size times the display scale.
    static let maxSide: CGFloat = 320
    /// The placeholder tile's height: lower than the media, so a build without media keeps the cues
    /// near the top of the sheet.
    static let placeholderHeight: CGFloat = 132
    static let glyphSize: CGFloat = 56
    static let cornerRadius: CGFloat = 16
}

/// One bundled demonstration file drawn as a square tile: a looping animation or a still.
///
/// VoiceOver reads it as one image, "Demonstration of <display name>"; the numbered cues below it
/// are the description an animation cannot give. It ignores Smart Invert, like a photo. The loop
/// runs only while the tile is on screen and the app is in the foreground: `.task` is cancelled when
/// the sheet closes, and the playback key changes (ending the loop) when the tile scrolls out of
/// view or the scene leaves `.active`.
struct ExerciseDemonstrationMedia: View {
    let fileName: String
    let animates: Bool
    /// The frozen catalog name; the spoken label draws its display name.
    let exerciseName: String

    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    /// The frame on screen; nil until the first decode.
    @State private var currentFrame: CGImage?
    @State private var isOnScreen = true

    /// "Demonstration of Bulgarian split squat": three spoken words around the drawn name.
    private var spokenName: Text {
        Text("Demonstration of \(ExerciseHowToCatalog.displayName(for: exerciseName))",
             comment: "VoiceOver label for the exercise demonstration animation or picture in the how-to sheet. %@ is the exercise name.")
    }

    private var playback: ExerciseDemonstrationPlayback {
        ExerciseDemonstrationPlayback(
            fileName: fileName,
            loops: animates && isOnScreen && scenePhase == .active,
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
        .frame(maxWidth: ExerciseDemonstrationLayout.maxSide)
        .clipShape(RoundedRectangle(cornerRadius: ExerciseDemonstrationLayout.cornerRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenName)
        .accessibilityAddTraits(.isImage)
        .accessibilityIgnoresInvertColors()
        .frame(maxWidth: .infinity)
        .onScrollVisibilityChange(threshold: 0.1) { isOnScreen = $0 }
        .task(id: playback) { await play(playback) }
    }

    /// Draws the first frame, then, for a looping playback, each next frame after the current one's
    /// delay until the task is cancelled or ``ExerciseDemonstrationFrames/maxTicks`` frames have
    /// shown.
    private func play(_ playback: ExerciseDemonstrationPlayback) async {
        guard let url = ExerciseDemonstrationLibrary.url(for: playback.fileName),
              let frames = ExerciseDemonstrationFrames(url: url, maxPixelSize: playback.maxPixelSize) else {
            currentFrame = nil
            return
        }
        currentFrame = frames.image(at: 0)
        guard playback.loops, frames.count > 1 else { return }
        // Bounded by maxTicks (Power of 10 rule 2); cancellation ends it far sooner in practice.
        for tick in 1...ExerciseDemonstrationFrames.maxTicks {
            do {
                try await Task.sleep(for: .seconds(frames.delay(at: (tick - 1) % frames.count)))
            } catch {
                // Cancelled: the sheet closed, the tile left the screen, or the playback changed.
                return
            }
            currentFrame = frames.image(at: tick % frames.count)
        }
    }
}

/// What a demonstration tile is playing, as its `.task` identity: a change restarts playback.
struct ExerciseDemonstrationPlayback: Equatable {
    let fileName: String
    /// Animate in a loop; false draws the first frame only (a still, Reduce Motion, off screen or
    /// in the background).
    let loops: Bool
    /// The longest side, in pixels, frames are decoded at.
    let maxPixelSize: Int
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

/// The tile shown when this build carries no demonstration for the exercise: the exercise's equipment
/// glyph, small and muted, on the cream card colour, in light and dark.
///
/// Decorative, so VoiceOver skips it: the heading above names the exercise and the facts below name
/// the equipment. It says nothing about media to come.
struct ExerciseDemonstrationPlaceholder: View {
    let target: ExerciseTarget?

    var body: some View {
        EquipmentGlyph(item: Self.glyph(for: target), size: ExerciseDemonstrationLayout.glyphSize)
            .foregroundStyle(Color.softTaupe)
            .frame(maxWidth: .infinity)
            .frame(height: ExerciseDemonstrationLayout.placeholderHeight)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: ExerciseDemonstrationLayout.cornerRadius))
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
