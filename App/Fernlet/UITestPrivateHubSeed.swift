// R8: one DEBUG condition, no nesting.
#if DEBUG
import CryptoKit
import FernletDomainModel
import FernletFoundation
import FernletLock
import Foundation
import PrivateHealthStore

/// DEBUG-only launch hooks for the no-passcode Private tab's UI tests (`PrivateTapGateUITests`):
/// a known key state, and optionally one entry no key on the simulator can open.
///
/// Runs first in `ContentView`'s launch wiring — before the reset funnel is installed, so the reset
/// here sets no restore hold — and only when `UITestSupport.resetsAppLockAtLaunch` is set. Release
/// builds compile none of it.
enum UITestPrivateHubSeed {
    /// Applies the launch flags: reset the app lock, then (optionally) seal one cycle note under a
    /// throwaway key that is dropped at once.
    ///
    /// - Parameter lockService: The app's lock service.
    @MainActor
    static func applyLaunchHooks(lockService: FernletLockService) {
        guard UITestSupport.resetsAppLockAtLaunch else { return }
        do {
            try lockService.reset()
        } catch {
            FernletAuditLog.log("uitest.lockReset.failed", context: ["error": "\(type(of: error))"])
        }
        guard UITestSupport.seedsUnopenableEntry else { return }
        let throwawayKey = SymmetricKey(size: .bits256)
        let narrative = MenstrualNarrative(
            hkExternalUUID: UUID().uuidString,
            dateKey: FernletDate.dayKey(for: Date()),
            note: "Sealed under a key that no longer exists."
        )
        do {
            try MenstrualNarrativeRepository().insert(narrative, contentKey: throwawayKey)
        } catch {
            FernletAuditLog.log("uitest.unopenableSeed.failed", context: ["error": "\(type(of: error))"])
        }
    }
}
#endif
