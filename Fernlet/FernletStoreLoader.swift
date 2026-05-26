import Combine
import SwiftUI

@MainActor
final class FernletStoreLoader: ObservableObject {
    enum Phase {
        case preparing
        case ready(FernletStore)
        case failed(Error)
    }

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var statusMessage: String = LaunchPreparationService.initialStatusMessage

    private var didStart = false

    func startIfNeeded() async {
        guard !didStart else { return }
        didStart = true
        await loadStore()
    }

    func retry() async {
        didStart = false
        phase = .preparing
        statusMessage = LaunchPreparationService.initialStatusMessage
        await startIfNeeded()
    }

    private func loadStore() async {
        do {
            let store = try await FernletStore.load { [weak self] message in
                self?.statusMessage = message
            }
            statusMessage = "Getting Fernlet ready..."
            phase = .ready(store)
        } catch {
            phase = .failed(error)
        }
    }
}
