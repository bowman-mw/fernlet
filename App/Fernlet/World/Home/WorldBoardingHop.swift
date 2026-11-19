import FernletDomainModel
import FernletScoring
import FernletUI
import SwiftUI

/// One play of the boarding hop: its direction, when it started, and when it was tapped to skip.
struct WorldBoardingHopPlay: Equatable, Identifiable {
    let id: UUID
    let direction: WorldBoardingHopDirection
    /// When it starts moving (until then it holds its first frame).
    let start: Date
    /// The line VoiceOver hears, with the companion's name in it.
    let line: String
    var skippedAt: Date?
}

/// Home's boarding hop (owner 2026-11-18, page UABPFeySzGuLEisj7bMKn3): the scene playing, if any, and the
/// in-flight scene's last place on screen, held by Home for as long as it lives. ``consider(sky:canPlay:isDecoy:companion:)``
/// asks ``WorldBoardingHopGate`` each time what Home shows, or whether it is in front, changes; the Home it should
/// show is remembered on this iPhone (``WorldMapPreferences``) the moment a scene starts. Main actor.
@MainActor
@Observable
final class WorldBoardingHopState {
    /// The scene playing, or nil.
    private(set) var play: WorldBoardingHopPlay?
    /// The in-flight view's scene on screen (global coordinates), as last seen; the hop plays in that frame.
    var flightSceneFrame: CGRect?
    /// DEBUG `FERNLET_UI_TEST_WORLD_HOME=hopBoarding|hopLanding`: the staged scene has played.
    @ObservationIgnored private var playedTestScene = false

    /// How long a scene holds its first frame before it moves: it covers the new Home at once, while a cold launch
    /// fades Home in from the launch screen and the map draws, so none of it is missed.
    static let lead: TimeInterval = 0.8

    /// Whether a scene is on screen (Home's banners wait for it).
    var isPlaying: Bool { play != nil }

    /// Home shows `sky`, in front (`canPlay`) or not, in a decoy or not: plays the scene for a switch since the Home
    /// last seen here, remembering the new one, or only remembers it the first time.
    func consider(sky: WorldHomeSky, canPlay: Bool, isDecoy: Bool, companion: String,
                  defaults: UserDefaults = .standard) {
        guard play == nil else { return }
        if canPlay, !isDecoy, let staged = stagedTestScene() {
            begin(staged, companion: companion)
            return
        }
        let decision = WorldBoardingHopGate.decide(remembered: WorldMapPreferences.lastHomeSky(in: defaults), now: sky,
                                                   canPlay: canPlay, isDecoy: isDecoy)
        if let remember = decision.remember { WorldMapPreferences.setLastHomeSky(remember, in: defaults) }
        if let direction = decision.play { begin(direction, companion: companion) }
    }

    /// Skips the scene `id` to its end (a tap, or VoiceOver's Skip).
    func skip(_ id: UUID) {
        guard play?.id == id, play?.skippedAt == nil else { return }
        play?.skippedAt = Date()
    }

    /// The scene `id` has finished.
    func finish(_ id: UUID) {
        guard play?.id == id else { return }
        play = nil
    }

    /// Starts `direction`'s scene and says its line once.
    private func begin(_ direction: WorldBoardingHopDirection, companion: String) {
        let line = WorldBoardingHopCopy.line(direction, companion: companion)
        play = WorldBoardingHopPlay(id: UUID(), direction: direction, start: Date().addingTimeInterval(Self.lead), line: line)
        FernletAnnouncer.system.announce(.status, resolved: line)
    }

    /// The scene `FERNLET_UI_TEST_WORLD_HOME` stages, once (DEBUG builds; the scene list is empty in release).
    private func stagedTestScene() -> WorldBoardingHopDirection? {
        guard !playedTestScene else { return nil }
        let scenes = UITestSupport.worldHomeScenes
        let staged: WorldBoardingHopDirection? = scenes.contains("hopBoarding") ? .boarding
            : scenes.contains("hopLanding") ? .landing : nil
        if staged != nil { playedTestScene = true }
        return staged
    }
}

/// Asks the boarding hop's gate whenever what Home shows, whether it is in front, or whether a scene is playing
/// changes (a finished scene asks again, so a switch during one still gets its turn).
struct WorldBoardingHopTrigger: ViewModifier {
    let hop: WorldBoardingHopState
    let sky: WorldHomeSky
    let canPlay: Bool
    let isDecoy: Bool
    let companion: String

    /// What the gate is asked about.
    private struct Asked: Equatable {
        let sky: WorldHomeSky
        let canPlay: Bool
        let isDecoy: Bool
        let isPlaying: Bool
    }

    func body(content: Content) -> some View {
        content.onChange(of: Asked(sky: sky, canPlay: canPlay, isDecoy: isDecoy, isPlaying: hop.isPlaying), initial: true) {
            hop.consider(sky: sky, canPlay: canPlay, isDecoy: isDecoy, companion: companion)
        }
    }
}

/// Places the playing scene over Home in the in-flight view's scene frame (owner's P1 A: the date, photos, hearts
/// and status plate stay put), or, before that frame has been seen this launch, where it stands on the
/// location-off Home. Lets every touch outside the scene through.
struct WorldBoardingHopLayer: View {
    var store: FernletStore
    let hop: WorldBoardingHopState
    var bodySignal: CompanionBodySignal?
    var isNight: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Where the scene stands before the in-flight view has been on screen: under the date, name and photos.
    static let fallbackTop: CGFloat = 176

    var body: some View {
        GeometryReader { proxy in
            if let play = hop.play {
                let band = band(in: proxy)
                WorldBoardingHopScene(store: store, play: play, layout: WorldFlyingLayout(large: dynamicTypeSize.isAccessibilitySize),
                                      bodySignal: bodySignal, isNight: isNight,
                                      onSkip: { hop.skip(play.id) }, onFinish: { hop.finish(play.id) })
                    .frame(width: band.width, height: band.height)
                    .position(x: band.midX, y: band.midY)
                    .id(play.id)
            }
        }
    }

    /// The scene's frame in this layer.
    private func band(in proxy: GeometryProxy) -> CGRect {
        let origin = proxy.frame(in: .global).origin
        guard let frame = hop.flightSceneFrame, frame.width > 0, frame.height > 0 else {
            let height = WorldFlyingLayout(large: dynamicTypeSize.isAccessibilitySize).sceneHeight
            return CGRect(x: 0, y: Self.fallbackTop, width: proxy.size.width, height: height)
        }
        return frame.offsetBy(dx: -origin.x, dy: -origin.y)
    }
}

/// The boarding hop's words (owner's P6 A).
nonisolated enum WorldBoardingHopCopy {
    /// What VoiceOver hears once as the scene starts, and the scene's label.
    static func line(_ direction: WorldBoardingHopDirection, companion: String) -> String {
        switch direction {
        case .boarding:
            String(localized: "\(companion) hopped on the plane. Taking off.",
                   comment: "World Home: VoiceOver, once, as the boarding scene plays (the map switches to the plane). The argument is the companion's name.")
        case .landing:
            String(localized: "Landed. \(companion) hopped off the plane.",
                   comment: "World Home: VoiceOver, once, as the landing scene plays (the plane switches back to the map). The argument is the companion's name.")
        }
    }

    /// VoiceOver's action that skips the scene.
    static var skip: LocalizedStringKey { "Skip" }
}

/// The pieces of Home that glide between the map Home and the plane Home as one switches to the other (owner
/// 2026-11-18): the status plate (top left on the map, under the scene in the air) and the prints (the corner grid
/// on the map, the row under the name in the air). Everything else cross-fades.
nonisolated enum WorldHomeGlide: String, Hashable, Sendable {
    case plate
    case prints

    /// How long the switch eases.
    static let duration = 0.9
}

extension View {
    /// Glides this piece of Home to and from its place on the other Home in `namespace` (by position only, as the
    /// two places differ in shape); nil leaves it where it is.
    @ViewBuilder
    func worldHomeGlide(_ piece: WorldHomeGlide, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedGeometryEffect(id: piece, in: namespace, properties: .position, isSource: true)
        } else {
            self
        }
    }
}
