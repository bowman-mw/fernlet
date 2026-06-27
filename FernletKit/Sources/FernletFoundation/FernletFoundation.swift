// FernletFoundation
//
// Layer-0 of the FernletKit carve-up (plan §2). This target will hold the
// cross-cutting primitives and the platform *seam protocols*
// (`SecureKeyValueStore`, `BiometricGate`, `HealthSampleSource`,
// `CloudSyncTransport`) plus `StoragePreferences`, `StartupTiming`, and
// `FernletDate`, so nothing above it names Security / HealthKit / CloudKit
// directly.
//
// Phase 1 intentionally stands the package up EMPTY; real types migrate here in
// a later, leaf-first extraction phase. This placeholder gives SPM a source
// file so the target compiles and the app can link the product.

import Foundation
