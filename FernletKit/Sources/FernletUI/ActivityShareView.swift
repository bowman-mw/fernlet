//
//  ActivityShareView.swift
//  FernletUI
//
//  The single system-share-sheet wrapper. It used to exist as two private copies in the app target
//  (Privacy & Data's data export, which had the completion hook, and the proximity connection-log
//  export, which didn't); hoisting it here gave the trainer/nutritionist summary — the third share
//  surface, previously a `ShareLink` with no completion callback at all — the same cleanup seam.
//

import SwiftUI
import UIKit

/// Presents the system share sheet (`UIActivityViewController`) for an already-written file.
///
/// SwiftUI's `ShareLink` is deliberately not used by this app's export surfaces: it has no completion
/// callback, and the files Fernlet shares are *plaintext* exports of the user's decrypted data written
/// into tmp/. ``onFinish`` is that missing seam — `completionWithItemsHandler` fires on BOTH the shared
/// and cancelled paths, and only after the chosen activity has finished reading the item, so deleting
/// the file there can't strand a half-shared export or race a still-in-flight copy. Callers sharing
/// nothing sensitive can leave `onFinish` at its no-op default.
///
/// Present it through `.sheet(item:)` with an `Identifiable` payload carrying the file URL, so
/// re-sharing the same file re-presents. Main-actor-bound, like every `UIViewControllerRepresentable`.
public struct ActivityShareView: UIViewControllerRepresentable {
    /// The activity items handed to `UIActivityViewController` — in practice a single file URL.
    public let items: [Any]
    /// Cleanup seam run once the sheet completes or is cancelled, after the activity has read `items`.
    public var onFinish: () -> Void

    /// - Parameters:
    ///   - items: Activity items to share; Fernlet's callers all pass exactly one file URL.
    ///   - onFinish: Runs on completion or cancellation. Defaults to a no-op for non-sensitive shares.
    public init(items: [Any], onFinish: @escaping () -> Void = {}) {
        self.items = items
        self.onFinish = onFinish
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        return controller
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
