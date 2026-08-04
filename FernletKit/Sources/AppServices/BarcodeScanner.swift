import Foundation
import Vision

#if canImport(UIKit)
import UIKit
import FernletDomainModel

// MARK: - Protocol seam

/// Still-photo barcode detection behind a seam so UI flows can be unit-tested with a fake detector
/// (the `NutritionLabelScannerTests` precedent for testing scan parsing without a camera).
///
/// ``VisionBarcodeDetector`` is the production conformer; the app-side `FoodCaptureRouter`,
/// `BarcodeScanView`, and `FoodView` hold an instance of this seam type so tests can substitute a
/// canned payload. Conformers must be `Sendable` — detection runs off the main actor.
public nonisolated protocol BarcodePayloadDetecting: Sendable {
    /// The raw payload string of the first supported product barcode in `image`, or nil.
    func payload(in image: UIImage) async throws -> String?
}

/// Production detector: `VNDetectBarcodesRequest` over a still photo. This is the fallback path for
/// devices/simulators where VisionKit's live `DataScannerViewController` is unsupported; the live
/// path shares ``BarcodeScanner/symbologies``.
///
/// A stateless forwarder to ``BarcodeScanner/detectPayload(in:)`` that exists purely to satisfy the
/// ``BarcodePayloadDetecting`` seam — all real work (and the off-main-thread hop) lives in
/// ``BarcodeScanner``.
public nonisolated struct VisionBarcodeDetector: BarcodePayloadDetecting {
    public init() {}

    public func payload(in image: UIImage) async throws -> String? {
        try await BarcodeScanner.detectPayload(in: image)
    }
}

// MARK: - Vision still-photo detection

/// Caseless namespace for Vision-based still-photo product-barcode detection.
///
/// Owns the canonical retail ``symbologies`` list — shared by the live VisionKit scan path in the
/// app's `BarcodeScanView` — and the `Task.detached` still-photo detection that
/// ``VisionBarcodeDetector`` wraps for the ``BarcodePayloadDetecting`` seam. Raw payloads returned
/// here are normalized downstream by `FoodBarcode.normalized` (in `FernletDomainModel`) before any
/// catalog lookup.
public nonisolated enum BarcodeScanner {
    /// Retail product symbologies (EAN-13 / EAN-8 / UPC-E). UPC-A needs no separate entry — Vision
    /// reports UPC-A codes as EAN-13 with a leading zero, which `FoodBarcode.normalized` folds
    /// together with the 12-digit rendering.
    public static let symbologies: [VNBarcodeSymbology] = [.ean13, .ean8, .upce]

    /// Detects the first product barcode in a still photo, running the Vision work off the calling
    /// thread (same shape as `NutritionLabelScanner.recognizeText`). Returns the raw payload string.
    public static func detectPayload(in image: UIImage) async throws -> String? {
        guard let cgImage = image.cgImage else { return nil }
        return try await Task.detached(priority: .userInitiated) {
            try detectPayloadSynchronously(in: cgImage)
        }.value
    }

    nonisolated private static func detectPayloadSynchronously(in cgImage: CGImage) throws -> String? {
        var detectionError: Error?
        var payloads: [String] = []
        let request = VNDetectBarcodesRequest { request, error in
            if let error {
                detectionError = error
                return
            }
            let observations = request.results as? [VNBarcodeObservation] ?? []
            payloads = observations.compactMap(\.payloadStringValue)
        }
        request.symbologies = symbologies

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        if let detectionError {
            throw detectionError
        }
        return payloads.first
    }
}

#endif
