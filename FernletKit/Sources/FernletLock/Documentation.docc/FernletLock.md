# ``FernletLock``

The app-lock platform shim: passcode/biometric credentials, brute-force cooldowns, and the in-memory content key that unlocks Fernlet's sealed stores.

## Overview

FernletLock is the layer-6 "[S]" platform-shim target in the FernletKit package that owns Fernlet's app lock. Its single service, ``FernletLockService`` (an `@Observable @MainActor` final class conforming to ``FernletLockServicing``), is created once at app launch and injected into the SwiftUI environment; the presentation layer lives in the separate `FernletLockUI` module (setup, unlock, and the `fernletLockGate` view modifier), keeping this target presentation-free. Sealed feature code — the period tracker, worry box, journal, and progress photos — asks the service for the unlocked content key per operation and observes ``FernletLockState`` to know when to render, buffer, or refuse.

The cryptographic scheme is deliberately small and is centralized in the module-internal ``FernletLockCrypto`` namespace. Configuring a credential derives a wrapping key from the passcode plus a random salt through the memory-hard scrypt KDF (CryptoSwift, the package's one external dependency; N=65536, r=8, p=1, run off the main actor via `Task.detached`), mints a random 256-bit content key, and seals the content key under the wrapping key with ChaChaPoly. What reaches the keychain is only: the salt, `SHA256(wrappingKey)` as the verifier (never the wrapping key itself), the wrapped content key, the credential kind, and the scrypt N — every item a ThisDeviceOnly, never-synchronized generic password under a ``LockKeychainKey`` account, and every write verified by status check plus read-back so a silently failing keychain cannot masquerade as configured state. While unlocked, the raw content key exists only in memory and is scrubbed on lock; sealed repositories derive per-column subkeys from it via HKDF (`ColumnCrypto` in `FernletCrypto`, whose derivation the crypto tests characterize directly). Verification accepts a legacy raw-key verifier from pre-split builds and migrates it to digest form in place on the next successful passcode entry. Biometric unlock keeps a second copy of the raw content key in a separate keychain item behind a `.biometryCurrentSet` access control, so iOS itself invalidates it when Face ID/Touch ID enrollment changes.

Brute-force protection is a keychain-persisted escalation ladder: every fourth failed passcode attempt starts a cooldown (60 s → 15 min → 1 h → 4 h), tracked against both the wall clock and the monotonic system uptime — the service takes the maximum of the two remainders, so rolling the clock forward cannot shorten a cooldown, while a detected reboot falls back to wall-clock accounting with an audit entry. Exhausting the ladder sets `requiresReset`, after which the only way forward is the destructive `reset()`, which deletes all lock keychain items, purges the sealed encrypted CoreData entities through `PrivatePersistenceController`, and abandons the content key (and with it all sealed content).

In the package dependency DAG, FernletLock sits on the PROTECTED side of the S3 privacy wall. It depends downward on `FernletFoundation` (keychain helpers, `FernletLockError`, `FernletAuditLog`), `FernletDomainModel`, the sealed `PrivateStoreCore` (whose `PendingNarrativeBuffer` it drains and whose `PrivatePersistenceController` it purges on reset), `PrivateHealthStore` (it conforms to that module's narrow `PeriodLockContext` seam — a strictly one-directional edge; `PrivateHealthStore` never names FernletLock), and CryptoSwift. Because it can reach the sealed stores, the walled `AIProviders` and `CloudKitSync` targets must never grow a dependency edge to it — the wall's `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` enforcement makes such an import a hard build error.

Concurrency: the target builds with `defaultIsolation(MainActor.self)`, so the service, its seam protocols (``FernletLockServicing``, ``FernletLockCryptoProviding``, ``FernletDateProviding``, ``FernletUptimeProviding``), and their system conformers are main-actor isolated; the pure crypto statics and free helpers are explicitly `nonisolated`. The two genuinely blocking operations — scrypt derivation and the LocalAuthentication-gated biometric keychain read — run off the main actor (a detached task and a global queue respectively). Every dependency of the service (date, uptime, crypto, keychain store/load closures, the biometric loader, the persistence controller) is constructor-injectable, which is how `FernletTests/FernletLockServiceTests` exercises cooldowns, clock tampering, and keychain failures deterministically. All failures surface as `FernletLockError` (defined in `FernletFoundation`), and every state transition is recorded through `FernletAuditLog`.

## Topics

### The lock service

- ``FernletLockServicing``
- ``FernletLockService``
- ``FernletLockState``
- ``FernletLockReason``

### Credentials and unlock results

- ``FernletLockCredential``
- ``FernletLockCredentialKind``
- ``UnlockMethod``
- ``UnlockResult``

### Cryptography

- ``FernletLockCrypto``
- ``FernletLockCryptoProviding``
- ``SystemFernletLockCryptoProvider``

### Keychain storage

- ``LockKeychainKey``

### Time providers (test seams)

- ``FernletDateProviding``
- ``SystemFernletDateProvider``
- ``FernletUptimeProviding``
- ``SystemFernletUptimeProvider``
