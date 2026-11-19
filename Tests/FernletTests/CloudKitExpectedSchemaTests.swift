import CoreData
import Foundation
import Testing
@testable import CloudKitSync

/// Holds `Docs/CloudKit-Expected-Schema.json` to the code (release review 2026-11-18, finding F2).
///
/// CloudKit's Production environment creates no record type or field on the fly, so a build that
/// writes one Production lacks is refused, and before this suite nothing tied the list the owner
/// deploys from to what the code writes: `CD_DayRecord.CD_deviceKey` and `CD_MemoryRecord` shipped
/// in code with no row in the deploy doc. These tests fail when the Core Data model, a hand-built
/// `CKRecord` or the delete sweep gains a type or field the expected-schema file does not list, and
/// when the file lists one the code no longer has. `Scripts/cloudkit-schema-check.py` compares that
/// same file with an export of the real container.
@MainActor
struct CloudKitExpectedSchemaTests {
    /// One expected field: its CloudKit Schema Language data type and the indexes a query needs.
    private struct Field: Decodable {
        let type: String
        let indexes: [String]?
    }

    /// One expected record type.
    private struct RecordType: Decodable {
        let source: String
        let entity: String?
        let recordNameQueryable: Bool
        let fields: [String: Field]
    }

    /// The types swept if present and written by no current build.
    private struct Legacy: Decodable {
        let names: [String]
    }

    /// The expected-schema file.
    private struct Expected: Decodable {
        let container: String
        let teamID: String
        let recordTypes: [String: RecordType]
        let legacyRecordTypes: Legacy
    }

    private static func expected() throws -> Expected {
        let data = try Data(contentsOf: RepoRoot.url("Docs/CloudKit-Expected-Schema.json"))
        return try JSONDecoder().decode(Expected.self, from: data)
    }

    /// The schema-language type the mirror gives a Core Data attribute, or nil for one this suite
    /// has no rule for (the test then fails, so a new attribute type gets a rule on purpose).
    private static func cloudType(_ type: NSAttributeType) -> String? {
        switch type {
        case .stringAttributeType: "STRING"
        case .binaryDataAttributeType: "BYTES"
        case .dateAttributeType: "TIMESTAMP"
        case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType: "INT64"
        case .doubleAttributeType, .floatAttributeType: "DOUBLE"
        default: nil
        }
    }

    @Test func everyMirroredEntityAndAttributeIsInTheExpectedSchema() throws {
        let expected = try Self.expected()
        let model = PersistenceController(inMemory: true).container.managedObjectModel
        var derived: [String: [String: String]] = [:]
        for entity in model.entities {
            let name = try #require(entity.name)
            #expect(entity.relationshipsByName.isEmpty, "a relationship adds fields this suite has no rule for: \(name)")
            var fields = ["CD_entityName": "STRING"]
            for (attribute, description) in entity.attributesByName {
                let type = try #require(Self.cloudType(description.attributeType), "no rule for \(name).\(attribute)")
                fields["CD_\(attribute)"] = type
                // Every String and Binary Data attribute gets an asset twin for values over 1 MB.
                if type == "STRING" || type == "BYTES" { fields["CD_\(attribute)_ckAsset"] = "ASSET" }
            }
            derived["CD_\(name)"] = fields
        }
        let listed = expected.recordTypes.filter { $0.value.source == "mirror" }.mapValues { $0.fields.mapValues(\.type) }
        #expect(derived.count == 7, "the model has \(derived.count) entities; a new one needs a deploy")
        #expect(derived == listed, "Docs/CloudKit-Expected-Schema.json and the Core Data model disagree: \(Self.difference(derived, listed))")
        for (name, type) in expected.recordTypes where type.source == "mirror" {
            #expect(type.entity.map { "CD_\($0)" } == name)
        }
    }

    @Test func everyHandBuiltRecordFieldIsInTheExpectedSchema() throws {
        let expected = try Self.expected()
        var derived: [String: Set<String>] = [:]
        // Each `CKRecord(` the service builds, with the `cloudRecord["…"]` keys set before the next one.
        let source = try RepoRoot.source("FernletKit/Sources/CloudKitSync/CloudKitDataService.swift")
        let typePattern = /recordType: "([A-Za-z_]+)"/
        let keyPattern = /cloudRecord\["([A-Za-z_]+)"\]/
        for chunk in source.components(separatedBy: "CKRecord(\n").dropFirst() {
            let type = try #require(chunk.firstMatch(of: typePattern), "a CKRecord built with no literal record type")
            derived[String(type.1), default: []].formUnion(chunk.matches(of: keyPattern).map { String($0.1) })
        }
        derived[HeartDropCloudTransport.recordType] = [HeartDropCloudTransport.tagField, HeartDropCloudTransport.payloadField]

        let listed = expected.recordTypes.filter { $0.value.source == "handBuilt" }.mapValues { Set($0.fields.keys) }
        #expect(derived.count == 4, "found \(derived.keys.sorted()); a new hand-built type needs a deploy")
        #expect(derived == listed, "Docs/CloudKit-Expected-Schema.json and the hand-built records disagree")
        // No other shipping file builds a record: one that did would escape the scan above.
        let builders = try Self.shippingFilesContaining("CKRecord(recordType")
            .union(Self.shippingFilesContaining("CKRecord(\n"))
        #expect(builders == ["CloudKitDataService.swift", "HeartDropCloudTransport.swift"])
        // The one field the app queries on (HeartDrop's `tag IN` fetch) keeps its index.
        #expect(expected.recordTypes["HeartDrop"]?.fields["tag"]?.indexes == ["QUERYABLE"])
    }

    @Test func everySweptRecordTypeIsListedAndQueryableByName() throws {
        let expected = try Self.expected()
        let source = try RepoRoot.source("FernletKit/Sources/CloudKitSync/CloudKitDataService.swift")
        let start = try #require(source.range(of: "private static let allRecordTypes = ["))
        let end = try #require(source.range(of: "\n    ]", range: start.upperBound..<source.endIndex))
        let swept = Set(source[start.upperBound..<end.lowerBound].matches(of: /"([A-Za-z_]+)"/).map { String($0.1) })
        #expect(swept.count >= 24)

        let legacy = Set(expected.legacyRecordTypes.names)
        for type in swept.sorted() {
            if let listed = expected.recordTypes[type] {
                // The sweep lists every record of the type, which needs the recordName index.
                #expect(listed.recordNameQueryable, "\(type) is swept, so its recordName must be queryable")
            } else {
                #expect(legacy.contains(type), "\(type) is swept but not in the expected schema")
            }
        }
        // Every private-database type the app writes is one "delete everything" can find.
        for (name, type) in expected.recordTypes where type.recordNameQueryable {
            #expect(swept.contains(name), "\(name) is marked queryable but never swept")
        }
        #expect(legacy.isSubset(of: swept))
        #expect(legacy.isDisjoint(with: expected.recordTypes.keys))
    }

    @Test func theFileNamesTheContainerAndTeamTheAppIsSignedFor() throws {
        let expected = try Self.expected()
        #expect(expected.container == CloudKitDataService.containerIdentifier)
        let entitlements = try RepoRoot.source("App/Fernlet/Fernlet.entitlements")
        #expect(entitlements.contains("<string>\(expected.container)</string>"))
        let project = try RepoRoot.source("App/Fernlet.xcodeproj/project.pbxproj")
        #expect(project.contains("DEVELOPMENT_TEAM = \(expected.teamID);"))
    }

    /// The names of the shipping Swift files whose text contains `needle`.
    private static func shippingFilesContaining(_ needle: String) throws -> Set<String> {
        var found: Set<String> = []
        for root in ["FernletKit/Sources", "App"] {
            let walker = try #require(FileManager.default.enumerator(at: RepoRoot.url(root), includingPropertiesForKeys: nil))
            for case let url as URL in walker where url.pathExtension == "swift" && !url.path.contains("/build/") {
                if try String(contentsOf: url, encoding: .utf8).contains(needle) { found.insert(url.lastPathComponent) }
            }
        }
        return found
    }

    /// The record types whose field lists differ, for the failure message.
    private static func difference(_ derived: [String: [String: String]], _ listed: [String: [String: String]]) -> String {
        let names = Set(derived.keys).union(listed.keys).filter { derived[$0] != listed[$0] }
        return names.sorted().joined(separator: ", ")
    }
}
