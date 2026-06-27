import Foundation

final class ProximityCommitDetector {
    private var thresholdEntryTime: Date?
    private var closeSampleCount = 0
    private let proximityThreshold: Double
    private let dwellSeconds: Double
    private let minimumSamples: Int

    init(proximityThreshold: Double = 0.15, dwellSeconds: Double = 0.8, minimumSamples: Int = 3) {
        self.proximityThreshold = proximityThreshold
        self.dwellSeconds = dwellSeconds
        self.minimumSamples = minimumSamples
    }

    func ingest(distanceMeters: Double, at timestamp: Date) -> Bool {
        guard distanceMeters < proximityThreshold else {
            reset()
            return false
        }

        if thresholdEntryTime == nil {
            thresholdEntryTime = timestamp
        }
        closeSampleCount += 1

        guard closeSampleCount >= minimumSamples,
              let thresholdEntryTime,
              timestamp.timeIntervalSince(thresholdEntryTime) >= dwellSeconds else {
            return false
        }

        return true
    }

    func reset() {
        thresholdEntryTime = nil
        closeSampleCount = 0
    }
}
