# ``FernletCrypto``

Layer-0 sealing primitives: the ChaChaPoly column-encryption helper the sealed private stores use to encrypt sensitive fields at rest.

## Overview

FernletCrypto is the smallest module in the FernletKit package — a single public type, ``ColumnCrypto`` — and it exists to give the sealed ("S3") stores one shared, well-audited way to encrypt individual sensitive columns. A column here is one field of one Core Data row: a journal entry's text, its emotion list, a menstrual narrative's note and symptom flags, an intimacy log's note, a worry-box entry. Each of those is sealed independently with ChaCha20-Poly1305 (CryptoKit's `ChaChaPoly`) and stored as the sealed box's `combined` blob (nonce ‖ ciphertext ‖ tag) in a single binary attribute of the local-only private Core Data store.

The central concept is the two-level key hierarchy. A single 256-bit **content key** protects the whole private area; it is minted, wrapped under a passcode-derived key, and vended by `FernletLockService` (in the `FernletLock` module), which returns it only while the user has unlocked the private area. ``ColumnCrypto`` never sees that lifecycle — every seal/open call receives the content key as a parameter and derives a per-column **subkey** from it on the fly, via HKDF-SHA256 with the instance's `ColumnCrypto.label` as the domain-separating `info` input. Nothing in this module stores key material, caches derived keys, or touches the keychain; it is a pure, stateless value type.

The label is what keeps different kinds of ciphertext cryptographically isolated even though they share one content key. Four repositories each own one instance with a fixed label: `JournalNarrativeRepository` ("journal-narrative") and `WorryNarrativeRepository` ("worry-box") in `PrivateMemoryStore`, and `MenstrualNarrativeRepository` ("menstrual-narrative") and `IntimacyLogRepository` ("intimacy-log") in `PrivateHealthStore`. Because HKDF is deterministic, a label is part of the at-rest data format: ciphertext sealed under one label can never be opened under another, so changing a repository's label (or the derivation itself) without a migration orphans all existing rows. Opening also fails — with a thrown CryptoKit authentication error — for truncated or tampered blobs and for data sealed under a different content key, which is exactly the fail-closed behavior the sealed stores rely on.

In the package dependency graph (see `FernletKit/Package.swift`), FernletCrypto sits at Layer 0: it imports only CryptoKit and Foundation and declares **no** in-package dependencies. Its position relative to the S3 privacy wall is "on the protected side by usage": its only importers are the sealed stores `PrivateHealthStore` and `PrivateMemoryStore`, and neither walled consumer (`AIProviders`, `CloudKitSync`) lists it as a dependency — so under the `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` enforcement, walled code cannot even name these types. Two deliberate non-users are worth knowing: `PrivateMediaStore` seals photos through CryptoKit directly with its own keychain key rather than through ``ColumnCrypto``, and `FernletLock` wraps/unwraps the content key with its own `FernletLockCrypto` helpers (it does not import this module). The HKDF column-key derivation itself lives in one place — ``ColumnCrypto``'s internal `deriveColumnKey` static — which the crypto unit tests characterize directly (via `@testable import`), including a pinned known-answer vector.

Concurrency: the target declares `defaultIsolation(MainActor.self)` in `Package.swift`, but ``ColumnCrypto`` is explicitly `nonisolated` — it must be callable synchronously from the `NSManagedObjectContext.performAndWait` closures of the nonisolated sealed-store repositories, where a MainActor-isolated call would be illegal under Swift 6. Each repository constructs and owns its own instance, so the value never needs to cross an isolation boundary.

## Topics

### Column sealing

- ``ColumnCrypto``
