import UIKit
import UniformTypeIdentifiers

/// The share-sheet entry point: pulls a web URL out of the shared payload and queues it for
/// recipe import by the main app.
///
/// This is the extension's `NSExtensionPrincipalClass` (declared in `Info.plist`), instantiated by
/// iOS whenever the user shares one web URL or plain text (the `NSExtensionActivationRule` accepts
/// either) and picks Fernlet. It presents no UI of its own: on first appearance it extracts the URL,
/// hands it to ``SharedRecipeImportQueueWriter`` — which appends it to the App-Group JSON queue the
/// main app drains via `FernletStore.processSharedRecipeImportQueue()` on launch and foreground —
/// and immediately completes the extension request. Any failure (no usable URL in the payload, a
/// non-web URL, or a queue write error) cancels the request instead, which surfaces the error's
/// `localizedDescription` in the system share UI.
///
/// URL extraction is two-pass: attachments conforming to `UTType.url` are preferred, then
/// plain-text attachments whose string parses as a `URL`. Scheme validation (http/https only)
/// happens in the writer, not here. As a `UIViewController` subclass the class is main-actor
/// isolated; the item-provider loads are bridged into async via checked continuations.
final class ShareViewController: UIViewController {
    /// Guards against a second enqueue if the system calls `viewDidAppear(_:)` more than once
    /// for the same share request.
    private var didStartImport = false

    /// Kicks off the one-shot import: extract the shared URL, enqueue it, and finish the request.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStartImport else { return }
        didStartImport = true

        Task {
            do {
                let url = try await sharedURL()
                try SharedRecipeImportQueueWriter().enqueue(url)
                complete()
            } catch {
                cancel(error)
            }
        }
    }

    /// Finds the first usable URL in the share payload.
    ///
    /// Flattens every attachment across all input items, then makes two passes: URL-typed
    /// providers first, plain-text providers (parsed with `URL(string:)`) second.
    ///
    /// - Returns: The first URL successfully loaded from an attachment.
    /// - Throws: ``ShareExtensionError/noURL`` when no attachment yields a URL, or any error
    ///   the item provider reports while loading.
    private func sharedURL() async throws -> URL {
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try await loadURL(from: provider) {
                return url
            }
        }

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let url = try await loadURLString(from: provider).flatMap(URL.init(string:)) {
                return url
            }
        }

        throw ShareExtensionError.noURL
    }

    /// Bridges `NSItemProvider.loadItem` for the URL type into async.
    ///
    /// Some apps deliver URL-typed items as `String`, so a string payload is also accepted and
    /// parsed. An item of any other shape resolves to `nil` rather than throwing, letting
    /// ``sharedURL()`` move on to the next provider.
    private func loadURL(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let string = item as? String {
                    continuation.resume(returning: URL(string: string))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Bridges `NSItemProvider.loadItem` for the plain-text type into async, returning the raw
    /// string (or `nil` when the item is not a string) for the caller to parse as a URL.
    private func loadURLString(from provider: NSItemProvider) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: item as? String)
            }
        }
    }

    /// Finishes the extension request successfully, dismissing the share sheet.
    private func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Cancels the extension request, letting the system surface the error to the user.
    private func cancel(_ error: Error) {
        extensionContext?.cancelRequest(withError: error)
    }
}

/// Failure raised when the shared payload contains nothing usable as a recipe URL.
///
/// Thrown by ``ShareViewController`` after both extraction passes (URL attachments, then
/// plain text) come up empty; its `errorDescription` is the user-facing copy the system share
/// UI shows when the request is cancelled.
private enum ShareExtensionError: LocalizedError {
    case noURL

    var errorDescription: String? {
        "Fernlet could not find a recipe URL in this share."
    }
}
