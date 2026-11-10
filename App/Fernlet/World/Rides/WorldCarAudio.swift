import AVFAudio
import Foundation

/// One audio output as iOS reports it, in plain values: its identifier (scrambled by ``WorldCarKeeper`` before anything
/// keeps it), its name and its kind.
nonisolated struct WorldAudioOutput: Equatable, Sendable {
    let identifier: String
    let name: String
    let kind: WorldAudioKind
}

/// Where the phone's audio outputs come from: the audio route on the phone, a scripted list in tests.
@MainActor
protocol WorldAudioReading: AnyObject {
    /// The outputs connected now that car detection reads (CarPlay and Bluetooth audio), at most ``WorldCarAudio/maxOutputs``.
    func outputs() -> [WorldAudioOutput]
    /// Called when the route changes (a car or headphones connect or go), while the app runs.
    var onChange: (@MainActor () -> Void)? { get set }
}

/// The phone's audio route for car detection (owner 2026-11-09, car signals): whether CarPlay or a Bluetooth audio
/// device is connected now. **The only file that reads the audio route**; it reads only the outputs' kind, name and
/// identifier, never plays or records anything, and never touches the audio session's category, so other apps' audio
/// (Maps' voice, music) is left alone.
///
/// iOS tells a running app when the route changes; a suspended app hears nothing, so the location source also reads
/// the route with every reading (``outputs()`` is a property read).
@MainActor
final class WorldCarAudio: WorldAudioReading {
    var onChange: (@MainActor () -> Void)?
    /// The route-change observer, removed with the reader.
    private var observer: (any NSObjectProtocol)?

    /// The most outputs one read hands on (a bound; a route has one or two).
    nonisolated static let maxOutputs = 8

    init() {
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    /// The observer goes with the reader.
    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func outputs() -> [WorldAudioOutput] {
        AVAudioSession.sharedInstance().currentRoute.outputs.prefix(Self.maxOutputs).compactMap { port in
            guard let kind = Self.kind(of: port.portType) else { return nil }
            return WorldAudioOutput(identifier: port.uid, name: port.portName, kind: kind)
        }
    }

    /// Car detection's reading of a port type: CarPlay, a Bluetooth audio device, or nothing it reads (the speaker,
    /// wired headphones, AirPlay).
    nonisolated static func kind(of type: AVAudioSession.Port) -> WorldAudioKind? {
        switch type {
        case .carAudio: .carPlay
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: .bluetooth
        default: nil
        }
    }
}
