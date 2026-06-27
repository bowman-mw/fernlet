import Foundation

/// Where the AI call is routed. Currently only on-device FoundationModels are used.
/// Adding any cloud/OHTTP destination here requires S3 to be fully complete first.
public enum AIDestination: String, Codable, Sendable {
    case onDeviceFoundationModels
    case webNutritionLookup
}
