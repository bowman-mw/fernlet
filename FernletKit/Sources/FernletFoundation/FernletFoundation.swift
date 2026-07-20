// FernletFoundation
//
// Layer-0 of the FernletKit carve-up (plan §2): the cross-cutting primitives
// every higher layer may depend on, and nothing else. Today that is
// `FernletDate` (locale-pinned day keys), `StoragePreferences`, `StartupTiming`,
// `KeychainHelpers`, `FernletAuditLog`, `FernletLockError`, `MonotonicClock`,
// and `BackupExclusion` — see the sibling files. Nothing here may import
// HealthKit, CloudKit, or any higher FernletKit target.
//
// This file is the module's doc anchor; it deliberately declares no types.

import Foundation
