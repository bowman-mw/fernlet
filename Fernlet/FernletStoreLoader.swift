import Foundation
import Observation

@MainActor
@Observable
final class FernletStoreLoader {
    enum Phase {
        case preparing
        case ready(FernletStore)
        case failed(Error)
    }

    private(set) var phase: Phase = .preparing
    private(set) var statusMessage: String = LaunchPreparationService.initialStatusMessage

    @ObservationIgnored private var didStart = false

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
