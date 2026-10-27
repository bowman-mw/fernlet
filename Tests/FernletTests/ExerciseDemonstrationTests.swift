import Foundation
import CoreGraphics
import ImageIO
import Testing
import FernletDomainModel
@testable import Fernlet

/// Exercise demonstration media (comparison report idea 8), built for media the repository never
/// holds.
///
/// The Gym Visual files are licensed (N-CRFL: no redistribution, no AI use) and the repository is
/// public, so they live only in the gitignored drop folder on the owner's machine. Pinned here: the
/// resolver's order across sex, availability and Reduce Motion; the committed mapping covers every
/// catalog exercise by its frozen name and holds IDs only; a build without media shows the
/// placeholder; the drop folder tracks only its README and `.gitignore`, and the project keeps both
/// out of the bundle; the licence carve-out is stated; and nothing on the AI path can reach the
/// demonstrations.
@MainActor
struct ExerciseDemonstrationTests {

    static let mappingPath = "App/Fernlet/ExerciseDemonstrations.json"
    static let dropFolder = "App/Fernlet/ExerciseMedia"
    /// The IDs the mapping research asked the owner to check by eye before buying.
    static let flaggedIDs = ["029213", "037813", "041013", "157613", "209913", "430113", "068413",
                             "394413", "600213", "600313", "086213", "120813", "022813", "088013", "232413"]

    /// Every version of one exercise, with short IDs so the expectations read easily.
    static let everyVersion = ExerciseDemonstrationIDs(
        gifMale: "1113", gifFemale: "2213", illustrationMale: "11", illustrationFemale: "22")

    static func resolve(_ ids: ExerciseDemonstrationIDs?, _ sex: BiologicalSex, reduceMotion: Bool,
                        _ bundled: Set<String>) -> ExerciseDemonstration {
        ExerciseDemonstrationResolver.resolve(ids, sex: sex, reduceMotion: reduceMotion, bundled: bundled)
    }

    /// The catalog's rows, read from the repository.
    static func catalogRows() throws -> [ExerciseTarget] {
        let data = try Data(contentsOf: RepoRoot.url("App/Fernlet/WorkoutExercises.json"))
        return try JSONDecoder().decode([ExerciseTarget].self, from: data)
    }

    /// The committed mapping, decoded the way the app decodes it.
    static func committedMapping() throws -> [String: ExerciseDemonstrationIDs] {
        try ExerciseDemonstrationLibrary.decodeMapping(Data(contentsOf: RepoRoot.url(mappingPath)))
    }

    // MARK: - The resolver

    @Test func withoutReduceMotionTheProfilesGIFComesFirstThenTheOtherThenAnIllustration() {
        let all = Self.everyVersion
        let everything: Set<String> = ["1113.gif", "2213.gif", "11.png", "22.png"]
        #expect(Self.resolve(all, .male, reduceMotion: false, everything) == .animation(fileName: "1113.gif"))
        #expect(Self.resolve(all, .female, reduceMotion: false, everything) == .animation(fileName: "2213.gif"))
        // The profile's GIF is missing: the other sex's GIF still beats a still.
        #expect(Self.resolve(all, .female, reduceMotion: false, ["1113.gif", "22.png"]) == .animation(fileName: "1113.gif"))
        #expect(Self.resolve(all, .male, reduceMotion: false, ["2213.gif", "11.png"]) == .animation(fileName: "2213.gif"))
        // No GIF at all: an illustration, the profile's sex first, PNG before JPEG.
        #expect(Self.resolve(all, .female, reduceMotion: false, ["11.png", "22.png"]) == .illustration(fileName: "22.png"))
        #expect(Self.resolve(all, .female, reduceMotion: false, ["11.jpg"]) == .illustration(fileName: "11.jpg"))
        #expect(Self.resolve(all, .male, reduceMotion: false, ["11.jpg", "11.png"]) == .illustration(fileName: "11.png"))
        // Nothing of this exercise's is bundled.
        #expect(Self.resolve(all, .male, reduceMotion: false, []) == .placeholder)
        #expect(Self.resolve(all, .male, reduceMotion: false, ["9913.gif", "99.png"]) == .placeholder)
    }

    @Test func underReduceMotionAStillComesFirstAndALoneGIFHoldsItsFirstFrame() {
        let all = Self.everyVersion
        let everything: Set<String> = ["1113.gif", "2213.gif", "11.png", "22.png"]
        #expect(Self.resolve(all, .male, reduceMotion: true, everything) == .illustration(fileName: "11.png"))
        #expect(Self.resolve(all, .female, reduceMotion: true, everything) == .illustration(fileName: "22.png"))
        // The other sex's still beats the profile's GIF: nothing moves under Reduce Motion.
        #expect(Self.resolve(all, .female, reduceMotion: true, ["1113.gif", "2213.gif", "11.png"]) == .illustration(fileName: "11.png"))
        // GIFs only: the first frame, frozen, the profile's sex first.
        #expect(Self.resolve(all, .female, reduceMotion: true, ["1113.gif", "2213.gif"]) == .firstFrame(fileName: "2213.gif"))
        #expect(Self.resolve(all, .male, reduceMotion: true, ["2213.gif"]) == .firstFrame(fileName: "2213.gif"))
        #expect(Self.resolve(all, .male, reduceMotion: true, []) == .placeholder)
        #expect(ExerciseDemonstration.animation(fileName: "1113.gif").animates)
        #expect(!ExerciseDemonstration.firstFrame(fileName: "1113.gif").animates)
        #expect(!ExerciseDemonstration.illustration(fileName: "11.png").animates)
        #expect(ExerciseDemonstration.placeholder.fileName == nil)
    }

    @Test func aSingleSexExerciseShowsItsOneVersionToEitherProfile() {
        let maleOnly = ExerciseDemonstrationIDs(gifMale: "064813", gifFemale: nil, illustrationMale: "0648", illustrationFemale: nil)
        let bundled: Set<String> = ["064813.gif", "0648.png"]
        #expect(Self.resolve(maleOnly, .female, reduceMotion: false, bundled) == .animation(fileName: "064813.gif"))
        #expect(Self.resolve(maleOnly, .female, reduceMotion: true, bundled) == .illustration(fileName: "0648.png"))
        let femaleOnly = ExerciseDemonstrationIDs(gifMale: nil, gifFemale: "094513", illustrationMale: nil, illustrationFemale: "0945")
        #expect(Self.resolve(femaleOnly, .male, reduceMotion: false, ["094513.gif"]) == .animation(fileName: "094513.gif"))
        #expect(Self.resolve(femaleOnly, .male, reduceMotion: true, ["094513.gif"]) == .firstFrame(fileName: "094513.gif"))
    }

    /// Only bundled files count, an exercise the mapping does not know gets the placeholder, and an
    /// ID that is not a Gym Visual ID can never name a file.
    @Test func onlyBundledFilesWithGymVisualIDsCount() {
        #expect(Self.resolve(nil, .male, reduceMotion: false, ["1113.gif"]) == .placeholder)
        let odd = ExerciseDemonstrationIDs(gifMale: "../x", gifFemale: "", illustrationMale: "12a", illustrationFemale: nil)
        #expect(Self.resolve(odd, .male, reduceMotion: false, ["../x.gif", ".gif", "12a.png"]) == .placeholder)
        #expect(ExerciseDemonstrationResolver.isMediaFileName("002513.gif"))
        #expect(ExerciseDemonstrationResolver.isMediaFileName("0025.png"))
        #expect(ExerciseDemonstrationResolver.isMediaFileName("1098413.gif"))
        #expect(ExerciseDemonstrationResolver.isMediaFileName("10984.jpg"))
        for name in ["README.md", ".gitignore", ".DS_Store", "0025.jpeg", "0025.GIF", "bench.gif", "0025.png.gif", "0025", "12345678901.gif"] {
            #expect(!ExerciseDemonstrationResolver.isMediaFileName(name), "\(name) is not a drop-folder media name")
        }
    }

    // MARK: - The mapping

    @Test func theMappingDecodesAndNamesEveryCatalogExerciseByItsFrozenName() throws {
        let mapping = try Self.committedMapping()
        let names = try Self.catalogRows().map(\.name)
        #expect(names.count == 199, "the catalog changed size: add the new exercise's Gym Visual IDs")
        #expect(Set(mapping.keys) == Set(names),
                "unmapped: \(Set(names).subtracting(mapping.keys).sorted()); not in the catalog: \(Set(mapping.keys).subtracting(names).sorted())")
        for (name, ids) in mapping {
            #expect(!ids.gifIDs(preferring: .male).isEmpty, "\(name) has no GIF")
            #expect(!ids.illustrationIDs(preferring: .male).isEmpty, "\(name) has no illustration")
        }
        let both = mapping.values.filter { $0.gifMale != nil && $0.gifFemale != nil }.count
        let maleOnly = mapping.values.filter { $0.gifMale != nil && $0.gifFemale == nil }.count
        let femaleOnly = mapping.values.filter { $0.gifMale == nil && $0.gifFemale != nil }.count
        #expect(both == 177)
        #expect(maleOnly == 17)
        #expect(femaleOnly == 5)
    }

    /// The committed file holds Gym Visual IDs and nothing else: GIF IDs of 6 or 7 digits,
    /// illustration IDs of 4 or 5, every one used once, the flagged ones among them.
    @Test func theMappingHoldsOnlyGymVisualIDs() throws {
        let mapping = try Self.committedMapping()
        var seen: [String] = []
        for (name, ids) in mapping {
            for gif in [ids.gifMale, ids.gifFemale].compactMap({ $0 }) {
                #expect(ExerciseDemonstrationResolver.isGymVisualID(gif) && (6...7).contains(gif.count), "\(name): GIF ID \(gif)")
                seen.append(gif)
            }
            for still in [ids.illustrationMale, ids.illustrationFemale].compactMap({ $0 }) {
                #expect(ExerciseDemonstrationResolver.isGymVisualID(still) && (4...5).contains(still.count), "\(name): illustration ID \(still)")
                seen.append(still)
            }
        }
        #expect(seen.count == 752 && Set(seen).count == seen.count, "an ID is shared or the mapping lost rows")
        #expect(Set(Self.flaggedIDs).isSubset(of: seen), "a flagged ID left the mapping")
        let raw = try RepoRoot.source(Self.mappingPath)
        for key in ["gifMale", "gifFemale", "illustrationMale", "illustrationFemale"] {
            #expect(raw.contains("\"\(key)\""), "the mapping's field \(key) is spelled differently from the decoder")
        }
    }

    /// The app reads the mapping from its own bundle, and every drop-folder file this build carries
    /// is one the mapping names (a mistyped ID shows up here, not as a silent placeholder).
    @Test func theAppBundlesTheMappingAndOnlyMappedMedia() throws {
        let mapping = try Self.committedMapping()
        #expect(ExerciseDemonstrationLibrary.mapping == mapping,
                "the app bundle's ExerciseDemonstrations.json is missing or differs from the committed one")
        let named = Set(mapping.values.flatMap { ids in
            ids.gifIDs(preferring: .male) + ids.illustrationIDs(preferring: .male)
        })
        for file in ExerciseDemonstrationLibrary.bundledFiles {
            let id = String(file.split(separator: ".")[0])
            #expect(named.contains(id), "\(file) is bundled but no exercise's mapping names \(id)")
        }
    }

    /// A build with no media (any clean clone) draws the placeholder for every exercise, sex and
    /// Reduce Motion setting, and the placeholder always has a drawn equipment glyph.
    @Test func withNoMediaEveryExerciseShowsThePlaceholder() throws {
        let mapping = try Self.committedMapping()
        let rows = try Self.catalogRows()
        for row in rows {
            for sex in BiologicalSex.allCases {
                for reduceMotion in [false, true] {
                    #expect(Self.resolve(mapping[row.name], sex, reduceMotion: reduceMotion, []) == .placeholder)
                }
            }
            let glyph = ExerciseDemonstrationPlaceholder.glyph(for: row)
            #expect(EquipmentIconLibrary.equipment[glyph] != nil, "\(row.name) draws \(glyph), which has no vector glyph")
        }
    }

    @Test func thePlaceholderDrawsTheToolOrTheGearABodyweightMoveNeeds() throws {
        let rows = try Self.catalogRows()
        func glyph(_ name: String) throws -> GymEquipment {
            let row = try #require(rows.first(where: { $0.name == name }), "\(name) left the catalog")
            return ExerciseDemonstrationPlaceholder.glyph(for: row)
        }
        #expect(try glyph("Bench press") == .barbell)
        #expect(try glyph("Goblet squat") == .kettlebells)
        #expect(try glyph("Band row") == .resistanceBands)
        #expect(try glyph("Pull-up") == .pullUpBar)
        #expect(try glyph("Medicine ball slam") == .medicineBall)
        #expect(try glyph("Treadmill run") == .treadmill)
        #expect(try glyph("Leg press") == .chestPress)
        #expect(try glyph("Plank") == .yogaMat)
        #expect(ExerciseDemonstrationPlaceholder.glyph(for: nil) == .yogaMat)
    }

    /// The tile is half the sheet's visible height, held between 160 and 320 points. So at the medium
    /// detent (about 380 points of content on a 6.3-inch phone) the first cues show under it, and
    /// expanded it is full size. Before the first measurement it draws full size.
    @Test func theTileIsHalfTheVisibleHeightBetweenItsBounds() {
        let heights: [CGFloat] = [0, .infinity, -40, 200, 380, 640, 800]
        let sides = heights.map { ExerciseDemonstrationLayout.side(forVisibleHeight: $0) }
        #expect(sides == [320, 320, 320, 160, 190, 320, 320])
    }

    /// The placeholder is a square the size of the media, with the exercise's drawn name in a text
    /// box. Its type stops at the first accessibility size because the heading above carries the name
    /// at every size, and both the media and the placeholder take the sheet-sized side. Under the World
    /// look (`b3-howto` draft 2) it is a full-width card no taller than that side.
    @Test func thePlaceholderIsASquareNamingTheExercise() throws {
        let view = try RepoRoot.source("App/Fernlet/ExerciseDemonstrationView.swift")
        let start = try #require(view.range(of: "struct ExerciseDemonstrationPlaceholder"))
        let placeholder = view[start.lowerBound...]
        #expect(placeholder.contains("Text(verbatim: ExerciseHowToCatalog.displayName(for: exerciseName))"))
        #expect(placeholder.contains(".aspectRatio(1, contentMode: .fit)"))
        #expect(placeholder.contains(".frame(maxWidth: side)"))
        #expect(placeholder.contains(".dynamicTypeSize(...DynamicTypeSize.accessibility1)"))
        #expect(placeholder.contains(".frame(height: min(side, Self.framedHeight))"))
        let sheet = try RepoRoot.source("App/Fernlet/ExerciseHowToSheet.swift")
        #expect(sheet.contains("side: ExerciseDemonstrationLayout.side(forVisibleHeight: visibleHeight)"))
        #expect(sheet.contains("fileName: fileName, animates: demonstration.animates, exerciseName: exerciseName, side: side)"))
        #expect(sheet.contains("exerciseName: exerciseName, target: WorkoutExerciseCatalog.exercise(named: exerciseName), side: side)"))
    }

    // MARK: - The player

    /// Frames decode one at a time, downsampled to the requested size, with the GIF's own delays and
    /// the browsers' rule for a near-zero one.
    @Test func framesDecodeDownsampledWithTheGIFsOwnDelays() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("demonstration-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeGIF(to: url, side: 240, delays: [0.25, 0.0])
        let frames = try #require(ExerciseDemonstrationFrames(url: url, maxPixelSize: 60))
        #expect(frames.count == 2)
        #expect(abs(frames.delay(at: 0) - 0.25) < 0.001)
        #expect(frames.delay(at: 1) == ExerciseDemonstrationFrames.defaultDelay)
        #expect(frames.delay(at: 7) == ExerciseDemonstrationFrames.defaultDelay)
        let first = try #require(frames.image(at: 0))
        #expect(max(first.width, first.height) <= 60, "decoded at \(first.width)x\(first.height), not downsampled")
        #expect(frames.image(at: 1)?.width != nil)
        #expect(frames.image(at: 2)?.width == nil)
        #expect(ExerciseDemonstrationFrames(url: url, maxPixelSize: 0)?.count == nil)
        #expect(ExerciseDemonstrationFrames(url: url.appendingPathExtension("missing"), maxPixelSize: 60)?.count == nil)
    }

    @Test func frameDelaysAreClamped() {
        #expect(ExerciseDemonstrationFrames.clampedDelay(0) == ExerciseDemonstrationFrames.defaultDelay)
        #expect(ExerciseDemonstrationFrames.clampedDelay(0.01) == ExerciseDemonstrationFrames.defaultDelay)
        #expect(ExerciseDemonstrationFrames.clampedDelay(.nan) == ExerciseDemonstrationFrames.defaultDelay)
        #expect(ExerciseDemonstrationFrames.clampedDelay(0.05) == 0.05)
        #expect(ExerciseDemonstrationFrames.clampedDelay(60) == ExerciseDemonstrationFrames.maxDelay)
    }

    /// Writes a `side`-pixel square GIF with one solid frame per delay.
    static func writeGIF(to url: URL, side: Int, delays: [Double]) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, "com.compuserve.gif" as CFString, delays.count, nil))
        for (index, delay) in delays.enumerated() {
            let context = try #require(CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: index == 0 ? 1 : 0, green: 0.4, blue: index == 0 ? 0 : 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let image = try #require(context.makeImage())
            let gif: [String: Any] = [kCGImagePropertyGIFDelayTime as String: delay]
            let properties = [kCGImagePropertyGIFDictionary as String: gif] as CFDictionary
            CGImageDestinationAddImage(destination, image, properties)
        }
        #expect(CGImageDestinationFinalize(destination), "could not write the test GIF")
    }

    // MARK: - The view

    /// The placeholder is decorative and says nothing about media to come; a real demonstration is
    /// one labelled image that ignores Smart Invert; Reduce Motion reaches the resolver; the loop
    /// stops off screen, in the background and when the sheet closes.
    @Test func theViewsAreLabelledOrDecorativeAndStopWhenUnseen() throws {
        let view = try RepoRoot.source("App/Fernlet/ExerciseDemonstrationView.swift")
        let placeholder = try #require(view.range(of: "struct ExerciseDemonstrationPlaceholder"))
        #expect(view[placeholder.lowerBound...].contains(".accessibilityHidden(true)"), "the placeholder must be decorative")
        for needle in ["coming soon", "Coming soon", "not available"] {
            #expect(!view.contains(needle), "the placeholder must not promise media")
        }
        #expect(view.contains("Text(\"Demonstration of \\(ExerciseHowToCatalog.displayName(for: exerciseName))\""))
        #expect(view.contains(".accessibilityLabel(spokenName)") && view.contains(".accessibilityAddTraits(.isImage)"))
        #expect(view.contains(".accessibilityIgnoresInvertColors()"))
        #expect(view.contains("animates: animates, isOnScreen: isOnScreen, isActive: scenePhase == .active, isPaused: isPaused)"))
        #expect(view.contains("animates && isOnScreen && isActive && !isPaused"))
        #expect(view.contains(".onScrollVisibilityChange(") && view.contains(".task(id: playback)"))
        let sheet = try RepoRoot.source("App/Fernlet/ExerciseHowToSheet.swift")
        #expect(sheet.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
        #expect(sheet.contains("for: exerciseName, sex: sex, reduceMotion: reduceMotion)"))
        #expect(!sheet.contains("EmptyView()"), "the demonstration slot is filled")
    }

    // MARK: - Pausing a loop (WCAG 2.2.2, tracker row C1)

    /// A tile loops only when it animates, is on screen, the scene is active and the person has not
    /// paused it; any one of those false holds the frame. A pause changes the playback key, so the
    /// running loop is cancelled.
    @Test func theLoopRunsOnlyWhenAnimatedOnScreenActiveAndNotPaused() {
        var looping: [[Bool]] = []
        for animates in [false, true] {
            for isOnScreen in [false, true] {
                for isActive in [false, true] {
                    for isPaused in [false, true] {
                        let loops = ExerciseDemonstrationPlayback.loops(
                            animates: animates, isOnScreen: isOnScreen, isActive: isActive, isPaused: isPaused)
                        if loops { looping.append([animates, isOnScreen, isActive, isPaused]) }
                    }
                }
            }
        }
        let onlyUnpausedVisibleActive: [[Bool]] = [[true, true, true, false]]
        #expect(looping == onlyUnpausedVisibleActive, "only an unpaused animation, on screen and active, loops")
        let playing = ExerciseDemonstrationPlayback(
            fileName: "1113.gif",
            loops: ExerciseDemonstrationPlayback.loops(animates: true, isOnScreen: true, isActive: true, isPaused: false),
            maxPixelSize: 960)
        let paused = ExerciseDemonstrationPlayback(
            fileName: "1113.gif",
            loops: ExerciseDemonstrationPlayback.loops(animates: true, isOnScreen: true, isActive: true, isPaused: true),
            maxPixelSize: 960)
        #expect(playing != paused, "a pause must change the task identity, or the loop would keep running")
        #expect(!paused.loops)
    }

    /// A pause holds the frame on screen and play carries on from it; a frame index from a longer
    /// file wraps; a still always shows its first frame.
    @Test func aPauseHoldsItsFrameAndPlayCarriesOnFromIt() {
        #expect(ExerciseDemonstrationPlayback.startFrame(saved: 0, count: 24, animates: true) == 0)
        #expect(ExerciseDemonstrationPlayback.startFrame(saved: 17, count: 24, animates: true) == 17)
        #expect(ExerciseDemonstrationPlayback.startFrame(saved: 30, count: 24, animates: true) == 6)
        #expect(ExerciseDemonstrationPlayback.startFrame(saved: 17, count: 1, animates: true) == 0)
        // Reduce Motion's frozen first frame, or an illustration: nothing moves, nothing to resume.
        #expect(ExerciseDemonstrationPlayback.startFrame(saved: 17, count: 24, animates: false) == 0)
        #expect(ExerciseDemonstrationPlayback.startFrame(saved: -3, count: 24, animates: true) == 0)
        #expect(ExerciseDemonstrationPlayback.startFrame(saved: 5, count: 0, animates: true) == 0)
    }

    /// A tap on the tile toggles the pause; the corner mark shows only on an animation, drawn in the
    /// theme's body-text pair with a slate ring and hidden from assistive technologies; VoiceOver
    /// keeps the one image element and gains a value and a named action; Voice Control gets short
    /// names. The placeholder has none of it.
    @Test func aLoopPausesByTapVoiceOverAndVoiceControl() throws {
        let view = try RepoRoot.source("App/Fernlet/ExerciseDemonstrationView.swift")
        let mediaStart = try #require(view.range(of: "struct ExerciseDemonstrationMedia"))
        let mediaEnd = try #require(view.range(of: "struct ExerciseDemonstrationPlayback"))
        let media = view[mediaStart.lowerBound..<mediaEnd.lowerBound]
        for needle in [".onTapGesture { togglePause() }", "guard animates else { return }", "isPaused.toggle()",
                       "if animates {\n                ExerciseDemonstrationPauseBadge(isPaused: isPaused)",
                       ".modifier(ExerciseDemonstrationPauseAccess(pausable: animates, isPaused: isPaused, toggle: togglePause))",
                       ".accessibilityElement(children: .ignore)"] {
            #expect(media.contains(needle), "the demonstration lost `\(needle)`")
        }
        let accessStart = try #require(view.range(of: "private struct ExerciseDemonstrationPauseAccess"))
        let access = view[accessStart.lowerBound...]
        for needle in [".accessibilityValue(isPaused ? ExerciseDemonstrationPauseWords.paused : ExerciseDemonstrationPauseWords.playing)",
                       ".accessibilityAction(named: isPaused ? ExerciseDemonstrationPauseWords.play : ExerciseDemonstrationPauseWords.pause)",
                       ".accessibilityAction(.default) { toggle() }", ".accessibilityInputLabels([",
                       "ExerciseDemonstrationPauseWords.demonstration", ".accessibilityRespondsToUserInteraction(true)"] {
            #expect(access.contains(needle), "the pause accessibility lost `\(needle)`")
        }
        for word in ["Text(\"Pause\"", "Text(\"Play\"", "Text(\"Paused\"", "Text(\"Playing\"", "Text(\"Demonstration\""] {
            #expect(view.contains(word), "the pause words lost \(word)")
        }
        let badgeStart = try #require(view.range(of: "struct ExerciseDemonstrationPauseBadge"))
        let badgeEnd = try #require(view.range(of: "struct ExerciseDemonstrationFrames"))
        let badge = view[badgeStart.lowerBound..<badgeEnd.lowerBound]
        for needle in ["isPaused ? \"play.fill\" : \"pause.fill\"", ".foregroundStyle(Color.bark)",
                       ".background(Color.parchment, in: Circle())", ".strokeBorder(Color.slate, lineWidth: 1.5)",
                       ".accessibilityHidden(true)"] {
            #expect(badge.contains(needle), "the pause mark lost `\(needle)`")
        }
        #expect(!badge.contains("opacity("), "the pause mark is drawn at full strength, never thinned")
        let placeholderStart = try #require(view.range(of: "struct ExerciseDemonstrationPlaceholder"))
        let placeholderEnd = try #require(view.range(of: "static func glyph(for target:"))
        let placeholder = view[placeholderStart.lowerBound..<placeholderEnd.lowerBound]
        for needle in ["togglePause", "ExerciseDemonstrationPauseBadge(", "ExerciseDemonstrationPauseAccess(", "onTapGesture"] {
            #expect(!placeholder.contains(needle), "the placeholder has nothing to pause but draws `\(needle)`")
        }
    }

    // MARK: - The drop folder and the licence

    /// The folder holds its README and `.gitignore`; the `.gitignore` ignores everything else; and
    /// anything else sitting there is a drop-named media file (so it is ignored). Read from the
    /// source tree, so on a clean clone the folder holds exactly the two files.
    @Test func theDropFolderTracksOnlyItsReadmeAndGitignore() throws {
        let folder = RepoRoot.url(Self.dropFolder)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.contains("README.md") && names.contains(".gitignore"), "the drop folder lost its README or .gitignore: \(names)")
        let strays = names.filter { name in
            !["README.md", ".gitignore", ".DS_Store"].contains(name) && !ExerciseDemonstrationResolver.isMediaFileName(name)
        }
        #expect(strays.isEmpty, "\(strays) in \(Self.dropFolder) are not <GymVisualID>.gif|png|jpg files")
        let rules = try RepoRoot.source("\(Self.dropFolder)/.gitignore")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        #expect(rules == ["*", "!.gitignore", "!README.md"], "the drop folder's .gitignore must ignore everything but itself and the README")
        let readme = try RepoRoot.source("\(Self.dropFolder)/README.md")
        for needle in ["Never commit", "redistribution", "AI use", "`<GymVisualID>.gif`", "`<GymVisualID>.png`",
                       "placeholder", "Reduce Motion", "ExerciseDemonstrations.json"] + Self.flaggedIDs {
            #expect(readme.contains(needle), "the drop folder's README lost \"\(needle)\"")
        }
    }

    /// The synchronized app target copies the drop folder's files into the bundle, so the project
    /// must except the README and `.gitignore`, and it names nothing else in the folder: media is
    /// picked up from disk, never referenced by name.
    @Test func theProjectKeepsTheReadmeAndGitignoreOutOfTheBundle() throws {
        let project = try RepoRoot.source("App/Fernlet.xcodeproj/project.pbxproj")
        let opener = "/* Exceptions for \"Fernlet\" folder in \"Fernlet\" target */ = {"
        let start = try #require(project.range(of: opener), "the app folder has no membership exception set")
        let end = try #require(project.range(of: "};", range: start.upperBound..<project.endIndex))
        let exceptions = project[start.upperBound..<end.lowerBound]
        #expect(exceptions.contains("ExerciseMedia/README.md,"), "the drop folder's README would ship in the app")
        // Quoted or not: Xcode may rewrite the leading-dot path either way when it saves the project.
        #expect(exceptions.contains("ExerciseMedia/.gitignore"), "the drop folder's .gitignore would ship in the app")
        #expect(project.components(separatedBy: "ExerciseMedia/").count - 1 == 2,
                "the project names something in the drop folder besides its README and .gitignore; licensed media is never referenced by name")
    }

    @Test func theLicenceCarveOutIsStated() throws {
        let notice = try RepoRoot.source("NOTICE")
        #expect(notice.contains("Gym Visual") && notice.contains("are not part of this repository or its license"))
        let readme = try RepoRoot.source("README.md")
        #expect(readme.contains("licensed from Gym Visual are not part of this repository or its license"))
    }

    // MARK: - The AI wall

    /// Roots holding AI-facing code: the app target (outside the compiler wall) and every package.
    static let aiScanRoots = ["App/Fernlet", "App/FernletWidgets", "FernletKit/Sources"]
    /// Markers of an on-device model caller, as `S3BoundaryTests` discovers them.
    static let aiMarkers = ["LanguageModelSession", "SystemLanguageModel", "@Generable", "import FoundationModels"]
    /// Modules that ARE the AI path: every file in them is scanned, Swift or not.
    static let aiModules = ["FernletKit/Sources/AIProviders", "FernletKit/Sources/AIContext"]
    /// Known AI-path files that must be found, so a broken root cannot pass by scanning nothing.
    static let aiFloor = ["FoundationWorkoutAdjustment.swift", "CoachExportPromptBuilder.swift", "FernletAIComposition.swift",
                          "FoundationDishDecomposition.swift", "LaunchPreparationService.swift", "AIContextPayload.swift"]
    /// What reaching the demonstrations looks like: the resolver and library types, the mapping
    /// resource, the drop folder, the licensor.
    static let demonstrationTokens = ["ExerciseDemonstration", "ExerciseMedia", "GymVisual", "Gym Visual", "gymvisual"]
    /// The only files that may name the demonstrations. A new caller is a deliberate change here.
    static let demonstrationFiles: Set<String> = [
        "App/Fernlet/ExerciseDemonstration.swift", "App/Fernlet/ExerciseDemonstrationView.swift",
        "App/Fernlet/ExerciseHowToSheet.swift",
    ]

    /// Every regular file under `root` (repo-relative), sorted.
    static func files(under root: String) -> [String] {
        let base = RepoRoot.url.path + "/"
        guard let walker = FileManager.default.enumerator(at: RepoRoot.url(root), includingPropertiesForKeys: nil) else { return [] }
        var out: [String] = []
        for case let url as URL in walker where !url.hasDirectoryPath {
            out.append(url.path.replacingOccurrences(of: base, with: ""))
        }
        return out.sorted()
    }

    /// The Gym Visual licence forbids AI use: no prompt builder, on-device model caller or AI module
    /// may name the demonstration resolver, its library, the mapping or the media folder.
    @Test func noAIOrPromptBuilderReachesTheDemonstrations() throws {
        var covered: Set<String> = []
        for root in Self.aiScanRoots {
            for path in Self.files(under: root) where path.hasSuffix(".swift") {
                let name = URL(fileURLWithPath: path).lastPathComponent
                let source = try RepoRoot.source(path)
                if name.contains("Prompt") || Self.aiMarkers.contains(where: { source.contains($0) }) {
                    covered.insert(path)
                }
            }
        }
        for module in Self.aiModules {
            covered.formUnion(Self.files(under: module))
        }
        let names = Set(covered.map { URL(fileURLWithPath: $0).lastPathComponent })
        #expect(Set(Self.aiFloor).isSubset(of: names), "AI floor files not found: \(Set(Self.aiFloor).subtracting(names).sorted())")
        #expect(covered.count >= 20, "only \(covered.count) AI-path files found; discovery is broken")
        for path in covered.sorted() {
            guard let source = try? String(contentsOf: RepoRoot.url(path), encoding: .utf8) else { continue }
            for token in Self.demonstrationTokens where source.contains(token) {
                Issue.record("\(path) names `\(token)`: the Gym Visual licence forbids AI use of the demonstrations")
            }
        }
    }

    /// The demonstrations are drawn in the how-to sheet and nowhere else, so a new reader anywhere,
    /// AI-facing or not, is a deliberate edit to ``demonstrationFiles``.
    @Test func onlyTheHowToSheetReachesTheDemonstrations() throws {
        var readers: Set<String> = []
        for root in ["App", "FernletKit/Sources"] {
            for path in Self.files(under: root) where path.hasSuffix(".swift") {
                let source = try RepoRoot.source(path)
                if source.contains("ExerciseDemonstration") || source.contains("ExerciseMedia") {
                    readers.insert(path)
                }
            }
        }
        #expect(readers == Self.demonstrationFiles, "files naming the demonstrations: \(readers.sorted())")
    }
}
