import Foundation

final class ProximityCommitDetector {
    private var window: [(timestamp: Date, distance: Double)] = []
    private let proximityThreshold: Double
    private let dwellSeconds: Double
    private let minimumSamples: Int

    init(proximityThreshold: Double = 0.15, dwellSeconds: Double = 0.8, minimumSamples: Int = 3) {
        self.proximityThreshold = proximityThreshold
        self.dwellSeconds = dwellSeconds
        self.minimumSamples = minimumSamples
    }

    func ingest(distanceMeters: Double, at timestamp: Date) -> Bool {
        window.append((timestamp, distanceMeters))
        let cutoff = timestamp.addingTimeInterval(-dwellSeconds)
        window.removeAll { $0.timestamp < cutoff }
        guard window.count >= minimumSamples else { return false }
        guard timestamp.timeIntervalSince(window.first!.timestamp) >= dwellSeconds else { return false }
        let average = window.reduce(0.0) { $0 + $1.distance } / Double(window.count)
        return average < proximityThreshold
    }

    func reset() { window.removeAll() }
}
