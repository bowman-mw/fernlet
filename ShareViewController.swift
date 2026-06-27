import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private var didStartImport = false

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

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel(_ error: Error) {
        extensionContext?.cancelRequest(withError: error)
    }
}

private enum ShareExtensionError: LocalizedError {
    case noURL

    var errorDescription: String? {
        "Fernlet could not find a recipe URL in this share."
    }
}
