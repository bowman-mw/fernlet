import Foundation
import Testing
import FernletFoundation
import FernletDomainModel
import FernletPersistence
@testable import Fernlet

/// The device-local HealthKit residue cache's file store: persistent, bounded, excluded from device
/// backup, fully cleared, and never trusting (or overwriting) a file it cannot read.
///
/// Every store here lives in its own temporary directory — never `FileDeviceHealthResidueStore.production`,
/// which is the simulator's real Application Support file.
@MainActor
@Suite
struct DeviceHealthResidueStoreTests {
    @Test func recordsSurviveANewInstanceOverTheSameDirectory() throws {
        let directory = Self.uniqueDirectory()
        let first = FileDeviceHealthResidueStore(directory: directory)
        #expect(first.record(Self.residue(steps: 4_000), for: "2026-09-19"))
        #expect(first.markLegacySyncedRowsScrubbed())

        let second = FileDeviceHealthResidueStore(directory: directory)
        #expect(second.residue(for: "2026-09-19") == Self.residue(steps: 4_000))
        #expect(second.legacySyncedRowsScrubbed)
    }

    @Test func theCacheIsBoundedToMaxDays() throws {
        let directory = Self.uniqueDirectory()
        let store = FileDeviceHealthResidueStore(directory: directory)
        let start = try #require(FernletDate.date(fromDayKey: "2025-01-01"))
        let keys = (0...FileDeviceHealthResidueStore.maxDays).compactMap { offset in
            Calendar(identifier: .gregorian).date(byAdding: .day, value: offset, to: start).map(FernletDate.dayKey(for:))
        }
        for key in keys {
            #expect(store.record(Self.residue(steps: 1), for: key))
        }
        #expect(store.allResidues().count == FileDeviceHealthResidueStore.maxDays)
        #expect(store.residue(for: "2025-01-01") == nil)            // the oldest day went
        #expect(store.residue(for: keys[keys.count - 1]) != nil)
        #expect(FileDeviceHealthResidueStore(directory: directory).allResidues().count
                == FileDeviceHealthResidueStore.maxDays)
    }

    @Test func theDirectoryIsExcludedFromDeviceBackup() throws {
        let directory = Self.uniqueDirectory()
        let store = FileDeviceHealthResidueStore(directory: directory)
        #expect(store.record(Self.residue(steps: 2_000), for: "2026-09-19"))
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func clearAllRemovesTheFileAndTheMarker() throws {
        let directory = Self.uniqueDirectory()
        let store = FileDeviceHealthResidueStore(directory: directory)
        #expect(store.record(Self.residue(steps: 2_000), for: "2026-09-19"))
        #expect(store.markLegacySyncedRowsScrubbed())

        #expect(store.clearAll())

        let file = directory.appendingPathComponent(FileDeviceHealthResidueStore.fileName)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.allResidues().isEmpty)
        #expect(!store.legacySyncedRowsScrubbed)
        #expect(FileDeviceHealthResidueStore(directory: directory).allResidues().isEmpty)
    }

    @Test func anUndecodableFileIsReplacedNotTrusted() throws {
        let directory = Self.uniqueDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a residue cache".utf8)
            .write(to: directory.appendingPathComponent(FileDeviceHealthResidueStore.fileName))
        let store = FileDeviceHealthResidueStore(directory: directory)
        #expect(store.allResidues().isEmpty)
        #expect(store.record(Self.residue(steps: 3_000), for: "2026-09-19"))
        #expect(FileDeviceHealthResidueStore(directory: directory).residue(for: "2026-09-19") != nil)
    }

    @Test func recordingNilOrAnEmptyResidueRemovesTheDay() {
        let store = FileDeviceHealthResidueStore(directory: Self.uniqueDirectory())
        #expect(store.record(Self.residue(steps: 3_000), for: "2026-09-19"))
        #expect(store.record(DeviceHealthResidue(context: nil, importedWorkouts: []), for: "2026-09-19"))
        #expect(store.residue(for: "2026-09-19") == nil)
        #expect(store.record(Self.residue(steps: 3_000), for: "2026-09-19"))
        #expect(store.record(nil, for: "2026-09-19"))
        #expect(store.allResidues().isEmpty)
        #expect(!store.record(Self.residue(steps: 1), for: ""))
    }

    /// Cycle and intimate groups are never carried, not even device-locally, and a day's imported
    /// workouts are capped — on construction AND on decode (a hand-edited file cannot smuggle them in).
    @Test func theResidueNormalizesOnConstructionAndDecode() throws {
        let context = HealthDailyContext(
            activity: HealthActivitySummary(steps: 10),
            cycle: HealthCycleContext(menstrualFlowEventCount: 2),
            intimate: HealthIntimateContext(eventCount: 1)
        )
        let workouts = (0...DeviceHealthResidue.maxImportedWorkouts).map { index in
            Workout(name: "Import \(index)", type: .cardio, exercises: "", rpe: nil, notes: "", duration: 10,
                    healthKitUUID: UUID(), intensity: .light)
        }
        let built = DeviceHealthResidue(context: context, importedWorkouts: workouts)
        #expect(built.context?.cycle == nil)
        #expect(built.context?.intimate == nil)
        #expect(built.importedWorkouts.count == DeviceHealthResidue.maxImportedWorkouts)

        struct Raw: Encodable { let context: HealthDailyContext; let importedWorkouts: [Workout] }
        let data = try JSONEncoder().encode(Raw(context: context, importedWorkouts: workouts))
        let decoded = try JSONDecoder().decode(DeviceHealthResidue.self, from: data)
        #expect(decoded.context?.cycle == nil)
        #expect(decoded.context?.intimate == nil)
        #expect(decoded.importedWorkouts.count == DeviceHealthResidue.maxImportedWorkouts)
    }

    // MARK: - Fixtures

    private static func residue(steps: Int) -> DeviceHealthResidue {
        DeviceHealthResidue(
            context: HealthDailyContext(syncedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                        activity: HealthActivitySummary(steps: steps)),
            importedWorkouts: []
        )
    }

    private static func uniqueDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fernlet-health-residue-\(UUID().uuidString)", isDirectory: true)
    }
}
