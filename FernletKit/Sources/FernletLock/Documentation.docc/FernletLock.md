# ``FernletLock``

The app-lock platform shim: passcode/biometric credentials, brute-force cooldowns, and the in-memory content key that unlocks Fernlet's sealed stores.

## Overview

FernletLock is the layer-6 "[S]" platform-shim target in the FernletKit package that owns Fernlet's app lock. Its single service, ``FernletLockService`` (an `@Observable @MainActor` final class conforming to ``FernletLockServicing``), is created once at app launch and injected into the SwiftUI environment; the presentation layer lives in the separate `FernletLockUI` module (setup, unlock, and the `fernletLockGate` view modifier), keeping this target presentation-free. Sealed feature code — the period tracker, worry box, journal, and progress photos — asks the service for the unlocked content key per operation and observes ``FernletLockState`` to know when to render, buffer, or refuse.

**An unlock covers exactly one screen.** Every credential entry point names the surface it speaks for, with no default: ``FernletLockService/configure(credential:grantingScope:)``, ``FernletLockService/unlock(passcode:for:)`` and ``FernletLockService/unlockWithBiometrics(for:)`` each grant a single ``FernletLockScope`` — `.privateHub` (the Private tab), `.progressPhotos` (the gym photo strip and its detail) or `.appLockSettings` (Settings → App lock) — and the grant rides *inside* the state as `.unlocked(scope:)` so it can never drift out of step with the unlock. Gated surfaces therefore ask ``FernletLockServicing/isUnlocked(for:)``, never `if case .unlocked`, and call ``FernletLockService/revokeUnlockOutside(_:)`` as they APPEAR so an arriving screen revokes a foreign unlock instead of inheriting one whose departure-side re-lock a covering sheet or scene transition may legitimately have suppressed. Two invariants hold underneath, and the P0a regressions in `FernletTests/SecureEnclaveWrapTests` pin their intersection: (1) the sealed-content key is released only to `.privateHub` — ``FernletLockService/contentKey(for:)`` is the decrypt seam, and `retainContentKey` keeps the key resident in memory for that scope alone, so a photo-strip or settings unlock recovers it purely as the act of verifying the passcode and then drops it (progress photos seal under `PrivateMediaKeyStore`'s own key; App-lock settings re-derive from the entered passcode); and (2) the additive Secure-Enclave wrap is maintained and round-trip-verified on EVERY successful configure and unlock regardless of scope, because that wrap protects the key at rest rather than the session. `hasResidentContentKey` exists solely so tests can distinguish "scrubbed" from "merely withheld" — it exposes a `Bool`, never a key.

The cryptographic scheme is deliberately small and is centralized in the module-internal `FernletLockCrypto` namespace. Configuring a credential derives a wrapping key from the passcode plus a random salt through the memory-hard scrypt KDF (CryptoSwift, the package's one external dependency; N=65536, r=8, p=1, run off the main actor via `Task.detached`), mints a random 256-bit content key, and seals the content key under the wrapping key with ChaChaPoly. What reaches the keychain is only: the salt, `SHA256(wrappingKey)` as the verifier (never the wrapping key itself), the wrapped content key, the credential kind, and the scrypt N — every item a ThisDeviceOnly, never-synchronized generic password under a ``LockKeychainKey`` account, and every write verified by status check plus read-back so a silently failing keychain cannot masquerade as configured state. While unlocked, the raw content key exists only in memory and is scrubbed on lock; sealed repositories derive per-column subkeys from it via HKDF (`ColumnCrypto` in `FernletCrypto`, whose derivation the crypto tests characterize directly). Verification accepts a legacy raw-key verifier from pre-split builds and migrates it to digest form in place on the next successful passcode entry. Biometric unlock keeps a second copy of the raw content key in a separate keychain item behind a `.biometryCurrentSet` access control, so iOS itself invalidates it when Face ID/Touch ID enrollment changes. Biometric unlock is additionally **PIN-before-biometrics**: it is refused (`FernletLockError.biometricNotAvailable`, which the unlock view turns into a silent passcode fallback) until one passcode success — ``FernletLockService/unlock(passcode:for:)`` or the initial ``FernletLockService/configure(credential:grantingScope:)`` — has happened in the current app process, mirroring iOS's own first-unlock-after-reboot rule. The in-memory, never-persisted `passcodeUnlockedThisProcess` flag records that success (a biometric success never sets it; `reset()` clears it), the fail-closed guard at the top of ``FernletLockService/unlockWithBiometrics(for:)`` is the load-bearing enforcement, and the single computed policy `isBiometricUnlockAvailable` (enabled + usable biometry + first passcode success) is what the lock UI's button and auto-prompt consult — the rule lives in that one property, and the planned duress phase extends it with one more conjunct there rather than at call sites. Where a Secure Enclave exists, the service additionally maintains an ADDITIVE second wrap of the content key under a non-exportable enclave-resident P-256 key (module-internal `SecureEnclaveContentKeyWrap`): established after a successful unlock with a full round-trip verification, preferred at unlock only when it provably matches the scrypt-unwrapped key, self-healed when stale or corrupt, and silently absent wherever the enclave is unavailable. The scrypt-wrapped item stays authoritative and untouched, so no recovery path changes — deleting it (HARD device binding) is an explicit owner decision recorded in `Docs/Verifiability.md` §6, for which this wrap is the pre-built plumbing.

Brute-force protection is a keychain-persisted escalation ladder: every fourth failed passcode attempt starts a cooldown (60 s → 15 min → 1 h → 4 h), tracked against both the wall clock and the monotonic system uptime — the service takes the maximum of the two remainders, so rolling the clock forward cannot shorten a cooldown, while a detected reboot falls back to wall-clock accounting with an audit entry. Exhausting the ladder sets `requiresReset`, after which the only way forward is the destructive `reset()`, which deletes all lock keychain items, purges the sealed encrypted CoreData entities through `PrivatePersistenceController`, and abandons the content key (and with it all sealed content).

In the package dependency DAG, FernletLock sits on the PROTECTED side of the S3 privacy wall. It depends downward on `FernletFoundation` (keychain helpers, `FernletLockError`, `FernletAuditLog`), `FernletDomainModel`, the sealed `PrivateStoreCore` (whose `PendingNarrativeBuffer` it drains and whose `PrivatePersistenceController` it purges on reset), `PrivateHealthStore` (it conforms to that module's narrow `PeriodLockContext` seam — a strictly one-directional edge; `PrivateHealthStore` never names FernletLock), and CryptoSwift. Because it can reach the sealed stores, the walled `AIProviders` and `CloudKitSync` targets must never grow a dependency edge to it — the wall's `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` enforcement makes such an import a hard build error.

Concurrency: the target builds with `defaultIsolation(MainActor.self)`, so the service, its seam protocols (``FernletLockServicing``, ``FernletLockCryptoProviding``, ``FernletDateProviding``, ``FernletUptimeProviding``), and their system conformers are main-actor isolated; the pure crypto statics and free helpers are explicitly `nonisolated`. The two genuinely blocking operations — scrypt derivation and the LocalAuthentication-gated biometric keychain read — run off the main actor (a detached task and a global queue respectively). Every dependency of the service (date, uptime, crypto, keychain store/load closures, the biometric loader, the persistence controller) is constructor-injectable, which is how `FernletTests/FernletLockServiceTests` exercises cooldowns, clock tampering, and keychain failures deterministically. All failures surface as `FernletLockError` (defined in `FernletFoundation`), and every state transition is recorded through `FernletAuditLog`.

## Topics

### The lock service

- ``FernletLockServicing``
- ``FernletLockService``
- ``FernletLockState``
- ``FernletLockScope``
- ``FernletLockReason``

### Credentials and unlock results

- ``FernletLockCredential``
- ``FernletLockCredentialKind``
- ``UnlockMethod``
- ``UnlockResult``

### Cryptography

- ``FernletLockCryptoProviding``

### Keychain storage

- ``LockKeychainKey``

### Time providers (test seams)

- ``FernletDateProviding``
- ``FernletUptimeProviding``
