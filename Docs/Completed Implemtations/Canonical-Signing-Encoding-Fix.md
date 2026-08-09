> **CLOSED 2026-08-09 — SHIPPED.** Delivered as WI-6 of [Security-Hardening-Plan-2026-06-27.md](Security-Hardening-Plan-2026-06-27.md) §1a: `CanonicalSignatureSerializer` (positional, length-prefixed binary) replaced the `JSONEncoder(.sortedKeys)` signing path, envelopes bump to `currentSchemaVersion = 2` with dual v1/v2 verify, `makeCanonicalSignatureEncoder()` is deleted, and golden-vector tests live in `FernletTests/FernletIdentityEnvelopeTests.swift`. The §7 checklist below was never ticked but every item is verified done on `main`. Live tracker: [RemainingWork-2026-07-19.md](../RemainingWork-2026-07-19.md).

# Canonical Signing Encoding — Cross-Platform Fix

**Status:** Proposed (prerequisite for the Android port; see [cross-platform direction]).
**Scope:** The deterministic byte sequence that Ed25519 signatures are computed over for
`FernletIdentityEnvelope` and `MeshAdmissionToken`.
**Severity:** Latent. **Not a bug on iOS-only today** — it becomes a hard, silent
interoperability failure the moment a non-Apple (Android / `swift-corelibs-foundation`) peer
signs or verifies. Must be fixed **before the first non-Apple peer ships**.

---

## 1. TL;DR

Every peer-to-peer message in the proximity mesh is **signed over canonical JSON** produced by
Apple's `Foundation.JSONEncoder` (`makeCanonicalSignatureEncoder()` in
[`FernletIdentityEnvelope.swift`](../../FernletKit/Sources/ProximityKit/Wire/FernletIdentityEnvelope.swift)). The
signature is **recomputed independently by the receiver** from the decoded struct, so **sender and
receiver must produce byte-identical canonical bytes** or the signature fails to verify.

`JSONEncoder` is a **platform-provided implementation**. On iOS it is Apple Foundation; on Android
it is `swift-corelibs-foundation`. The *same Swift source* (`encoder.outputFormatting = [.sortedKeys, …]`)
calls into **two different implementations** that are **not guaranteed to emit the same bytes** for
dates, non-ASCII strings, dictionary-key ordering, optional omission, and base64. A single differing
byte breaks every cross-stack signature.

**The fix:** stop signing over `JSONEncoder` output. Replace the canonical path with an **explicit,
self-contained, versioned serializer** that has *zero* platform-dependent behavior, carry signed
timestamps as **integer epoch-millis** (not `Date`/ISO8601), add **domain-separation tags**, and pin
the format with **golden-vector tests** run on both platforms. This is necessary even if the shared
core is written in Swift — because the divergence lives in Foundation, not in your code.

---

## 2. Where canonical signing is used

Two types are signed. Both zero their signature field, encode via the shared canonical encoder, and
Ed25519-sign the result.

### 2.1 `FernletIdentityEnvelope` — every P2P transfer
([`FernletIdentityEnvelope.swift:11`](../../FernletKit/Sources/ProximityKit/Wire/FernletIdentityEnvelope.swift))

```
schemaVersion: Int
envelopeID: UUID
senderSigningPublicKey: Data            // Ed25519 raw, 32 B
senderKeyAgreementPublicKey: Data       // X25519 raw, 32 B
senderDisplayName: String               // ⚠ user-controlled (emoji/accents)
recipientFingerprint: String?           // ⚠ optional (nil = broadcast)
payloadType: PayloadType                // enum: String raw value
payloadEncryption: PayloadEncryption    // ⚠ enum WITH associated value
payloadSummary: PayloadSummary          // ⚠ nested, see below
payload: Data
createdAt: Date                         // ⚠ ISO8601 in canonical form
expiresAt: Date?                        // ⚠ optional + ISO8601
signature: Data                         // zeroed during signing
```

`PayloadSummary` ([`PayloadType.swift:53`](../../FernletKit/Sources/FernletDomainModel/PayloadType.swift)) is the
worst offender — it concentrates three divergence vectors at once:

```
title: String                  // ⚠ user-controlled string
subtitle: String?              // ⚠ optional + user-controlled
itemCount: Int
dateRange: DateRange?          // ⚠ optional; nested DateRange { start: Date; end: Date }
extraDetails: [String: String] // ⚠ ARBITRARY keys + values (sort order + escaping)
```

`PayloadEncryption` ([`PayloadType.swift:41`](../../FernletKit/Sources/FernletDomainModel/PayloadType.swift)) is an
enum with an associated value (`case sealedTo(recipientKeyAgreementPublicKey: Data)`), which Swift
synthesizes into a nested `{"sealedTo": { … }}` JSON shape.

### 2.2 `MeshAdmissionToken` — mesh join authorization
([`MeshPayloads.swift:77`](../../FernletKit/Sources/ProximityKit/Wire/MeshPayloads.swift))

```
meshID: UUID
joinerFingerprint: String               // hex, ASCII
joinerSigningPublicKey: Data
admitterFingerprint: String             // hex, ASCII
grantedAt: Date                         // ⚠ ISO8601
expiresAt: Date                         // ⚠ ISO8601 (non-optional here)
admitterSigningPublicKey: Data
admitterSignature: Data                 // zeroed during signing
```

### 2.3 The current encoder & flow

```swift
// FernletIdentityEnvelope.swift:31
func makeCanonicalSignatureEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder                       // NOTE: no dataEncodingStrategy → default base64
}

func canonicalBytes(for envelope: FernletIdentityEnvelope) -> Data {
    var copy = envelope
    copy.signature = Data()
    return try! makeCanonicalSignatureEncoder().encode(copy)
}
```

Sign = `IdentityService.sign` → `Curve25519.Signing.PrivateKey.signature(for:)`.
Verify = `Curve25519.Signing.PublicKey.isValidSignature(_:for:)`.

**Critical:** the wire/transport encoding is a *separate, plain* `JSONEncoder()` (e.g.
[`ProximityCoordinator.swift:299`](../../FernletKit/Sources/ProximityKit/Engine/ProximityCoordinator.swift)). The
receiver **decodes the wire JSON, then re-runs `canonicalBytes(for:)` on the decoded struct** and
checks the signature ([`FernletIdentityEnvelope.swift:69`](../../FernletKit/Sources/ProximityKit/Wire/FernletIdentityEnvelope.swift)).
So the canonical bytes are reconstructed independently on each peer — which is exactly why
cross-platform determinism is mandatory.

> The Ed25519 **algorithm** itself is fully portable and byte-identical via `swift-crypto`
> (BoringSSL). The risk is *only* the canonical byte production feeding it.

---

## 3. Why it is not cross-platform safe

The root cause: **`JSONEncoder` is a platform library, not your code.** Apple Foundation and
`swift-corelibs-foundation` are independent implementations and have historically differed on
exactly the knobs this path leans on. Identical Swift source therefore does **not** guarantee
identical bytes. The specific vectors, mapped to the fields that trigger them:

| # | Vector | Triggering fields | Why it diverges |
|---|--------|-------------------|-----------------|
| a | **Date / ISO8601** | `createdAt`, `expiresAt`, `grantedAt`, `DateRange.start/end` | Apple's `.iso8601` strategy emits whole-second UTC (`2026-06-26T15:30:00Z`, **no fractional seconds**). A different ISO8601 implementation may add fractional seconds, use a numeric offset instead of `Z`, or round vs. truncate. |
| b | **String-value escaping** | `senderDisplayName`, `PayloadSummary.title/subtitle`, `extraDetails` values | Non-ASCII scalars (emoji, accents): Apple emits raw UTF-8; other encoders may emit `\uXXXX`. `.withoutEscapingSlashes` only covers `/`. |
| c | **Dictionary key order + escaping** | `PayloadSummary.extraDetails` **keys** | `.sortedKeys` sorts by code-unit order. Fixed struct keys are all ASCII (safe), but `extraDetails` keys are arbitrary/app-supplied — non-ASCII keys expose sort-order *and* escaping divergence. |
| d | **Optional omission** | `recipientFingerprint`, `expiresAt`, `subtitle`, `dateRange` | Apple omits `nil` keys entirely. A hand-written or differing encoder might emit `"key": null`. Either rule is fine — but both stacks must agree. |
| e | **Base64 variant** | all `Data` fields (keys, `payload`) | Standard alphabet vs URL-safe, padding, and line-wrapping must match exactly. |
| f | **Enum associated-value synthesis** | `payloadEncryption` | Nested `{"sealedTo": {...}}` shape is compiler-synthesized (stable across platforms) but still serialized through the diverging JSON layer. Lower risk; document, don't ignore. |
| g | **Number formatting** | (none today — only `Int`) | Ints are safe. Flagged because adding any `Double`/`Float` to a signed type would reintroduce formatting divergence. |

**Float round-trip interaction (subtle):** the wire encoder uses the default
`.deferredToDate` strategy, which serializes `Date` as a `Double`. A receiver does
`Double → Date → ISO8601-truncate`. Floating-point error near a whole-second boundary
(`7.9999999` vs `8.0000001`) can flip the truncated second and break the signature. This is a
second, independent reason to remove `Date`/ISO8601 from the signed path.

### Important framing — priority

Today **all peers are iOS on Apple Foundation**, so they all produce identical canonical bytes and
signatures verify. **There is no production bug right now.** This is a *latent landmine*: it
detonates the instant an Android peer (or any `swift-corelibs-foundation` build) participates.
Treat it as a **pre-Android prerequisite**, sequenced with the shared-core work — not an emergency
hotfix. And note: **writing the shared core in Swift does not fix this on its own**, because the
same Swift line dispatches to a different `JSONEncoder` underneath on each platform.

---

## 4. The fix

**Stop signing over `JSONEncoder`. Define an explicit, self-contained canonical serializer** with no
hidden platform-dependent behavior, and bump the wire schema. Two acceptable forms:

### Option A — Length-prefixed binary canonical form *(recommended)*

Deterministic *by construction*; eliminates every vector in §3 (no JSON, no key sorting, no string
escaping, no base64, no ISO8601). Primitives:

```
lp(x)        := uint32_be(byteCount(x)) || x          // length-prefixed blob
opt(x)       := 0x00                                    // absent
              | 0x01 || <encoding of x>                 // present
u32(n)       := uint32_be(n)
i64(n)       := int64_be(n)
uuid(u)      := 16 raw bytes (big-endian)
str(s)       := lp(utf8(s))                             // UTF-8, no escaping at all
tag(s)       := the ASCII bytes of s (fixed domain-separation prefix)
```

**Envelope canonical bytes (schemaVersion 2):**

```
tag("FERNLET-ENVELOPE-v2\n")
u32(schemaVersion)
uuid(envelopeID)
lp(senderSigningPublicKey)
lp(senderKeyAgreementPublicKey)
str(senderDisplayName)
opt(str(recipientFingerprint))
str(payloadType.rawValue)
<payloadEncryption>                  // 0x00 for .none ; 0x01 || lp(recipientKeyAgreementPublicKey) for .sealedTo
<payloadSummary>                     // see below
lp(payload)
i64(createdAtEpochMillis)
opt(i64(expiresAtEpochMillis))
// signature field is excluded entirely
```

**PayloadSummary canonical bytes** (recurse with the same primitives; sort `extraDetails` by raw
UTF-8 byte order of the key, which is unambiguous across platforms):

```
str(title)
opt(str(subtitle))
i64(itemCount)
opt( i64(dateRange.start) || i64(dateRange.end) )      // epoch-millis, not ISO8601
u32(extraDetails.count)
for (k, v) in extraDetails sorted by utf8Bytes(k) lexicographically:
    str(k) || str(v)
```

**MeshAdmissionToken canonical bytes (schemaVersion 2):**

```
tag("FERNLET-ADMISSION-v2\n")
uuid(meshID)
str(joinerFingerprint)
lp(joinerSigningPublicKey)
str(admitterFingerprint)
i64(grantedAtEpochMillis)
i64(expiresAtEpochMillis)
lp(admitterSigningPublicKey)
// admitterSignature excluded
```

### Option B — Strict RFC 8785 (JSON Canonicalization Scheme)

If keeping a JSON shape is preferred, implement **JCS** yourself (don't delegate to `JSONEncoder`):
sorted keys by UTF-16 code unit, no insignificant whitespace, defined number canonicalization,
defined string escaping. More work to get *exactly* right (number/Unicode edge cases) for marginal
benefit. Choose only if a JSON envelope is a hard requirement.

### Rejected — "pin JSONEncoder knobs + reimplement byte-for-byte on Android"

You would forever chase Foundation's quirks across OS/toolchain versions, with no compiler help and
failures that surface only as signature-verification errors in the field. Don't.

### Representational changes that ride along

1. **Carry signed timestamps as `Int64` epoch-millis end-to-end** (wire *and* canonical), not `Date`.
   Eliminates vector (a) and the float round-trip. This is a model change to the signed structs
   (e.g. `createdAtEpochMillis: Int64` replacing/derived-from `createdAt`), gated behind the schema
   bump.
2. **Define the optional rule once** (absent ⇒ `0x00`, the `opt()` primitive) so omission can never
   diverge.
3. **Add domain-separation tags** (`tag(…)`). Today both types feed the *same* encoder with no type
   tag; explicit tags prevent any cross-type signature confusion and are free to add here.

### Single source of truth

Put `canonicalBytes(for:)` (and the primitives) in the **shared core module** compiled on both
platforms, using only the standard library (`Data`, `UInt32` big-endian, UTF-8) — **no Foundation
`JSONEncoder`**. One implementation, both platforms, nothing to keep in sync.

---

## 5. Migration & versioning

- **Bump `schemaVersion` 1 → 2** and reject mismatches (the verify path already gates
  `schemaVersion == 1`).
- **No persisted-signature migration needed.** Everything signed is ephemeral — envelopes are
  transient and admission tokens expire in ~2 h
  ([`MeshPayloads.swift:165`](../../FernletKit/Sources/ProximityKit/Wire/MeshPayloads.swift)). Nothing signed is
  stored long-term, so there is no historical data to re-sign.
- **It is a coordinated wire change**, not a compatibility shim: a v1 and a v2 peer cannot interop
  (different signed bytes). Since proximity is in-person and both devices run whatever build they
  have, ship v2 as a clean cut aligned with the shared-core/Android rollout. iOS-only deployments
  are unaffected until then.

---

## 6. Testing — golden vectors (the empirical guarantee)

Golden vectors are what make the exact list in §3 *moot*: instead of proving Foundation behaves
identically, you pin the bytes and assert them on every platform.

1. **Frozen fixtures.** Construct an envelope and a token from fully fixed inputs — hard-coded key
   bytes, fixed `UUID`s, fixed epoch-millis timestamps, and a `PayloadSummary` that deliberately
   includes a non-ASCII `senderDisplayName`/`title` (e.g. an emoji) and a multi-key `extraDetails`
   with non-ASCII keys. Assert `canonicalBytes(for:)` equals a checked-in hex string.
2. **Same vectors on Android.** The Android test suite asserts the *identical* hex. Any divergence
   fails CI, not a user's handshake.
3. **Cross-stack round-trip.** Sign on stack A, verify on stack B, and vice-versa, for both types.
4. **Property test:** `verify(sign(x)) == true` and any single-field mutation ⇒ `signatureInvalid`.
5. Home for these: extend
   [`FernletTests/FernletIdentityEnvelopeTests.swift`](../../FernletTests/FernletIdentityEnvelopeTests.swift).

---

## 7. Scope — what NOT to touch

Only the **canonical signing path** must change. Leave these alone (they do not gate signatures):

- Transport encoders (`JSONEncoder()` in `ProximityCoordinator`, `MeshNetworkManager` payloads) —
  these just need to round-trip decode cross-platform, which standard JSON does. *(Exception: if you
  keep `Date` on the wire, mind the float round-trip in §3; moving signed time fields to `Int64`
  resolves it.)*
- `ConnectionInspector` log export (`.sortedKeys` for human-readable logs).
- `PrivateMediaStore` persistence (`.iso8601` for local files).

---

## 8. Related portability notes (adjacent, same files)

Small items in the same signing/crypto path, tracked with the shared-core work (see
[cross-platform direction]):

- **`import CryptoKit` → `import Crypto`** under `#if canImport(CryptoKit)` so `IdentityService`
  builds against `swift-crypto` off-Apple. Byte-compatible; covers every primitive used.
- **RNG:** `MeshNetworkManager` generates the 32-byte rotation key via `SecRandomCopyBytes`
  (Security framework, Apple-only). Switch to `SymmetricKey(size: .bits256)` (swift-crypto) or
  `SystemRandomNumberGenerator` for the shared core.
- **Key custody is not portable:** `FernletLockService` / `IdentityService` provisioning use
  Keychain + Secure Enclave gating, which `swift-crypto` does not provide. Abstract behind a
  platform protocol with an Android Keystore + BiometricPrompt implementation. (Out of scope for
  this doc; noted for sequencing.)

---

## 9. Action checklist

- [ ] Add `canonicalBytes(for:)` v2 serializers (Option A) + primitives in the shared core, std-lib only.
- [ ] Move signed timestamps to `Int64` epoch-millis in the signed structs (schema v2).
- [ ] Add domain-separation tags for both signed types.
- [ ] Recurse the serializer through `PayloadSummary` / `DateRange` / `PayloadEncryption`; sort
      `extraDetails` by UTF-8 key bytes; define optional omission via `opt()`.
- [ ] Bump `schemaVersion` to 2; keep the `== expected` gate in both `verify()` paths.
- [ ] Delete `makeCanonicalSignatureEncoder()` and remove the `JSONEncoder` dependency from the
      signing path.
- [ ] Add golden-vector + cross-stack round-trip tests (iOS now; mirror on Android later).
- [ ] (Adjacent) `import Crypto` shim, RNG swap, key-custody protocol — track with shared-core work.

---

[cross-platform direction]: ./RemainingWork-2026-06-23.md
<!-- Broader cross-platform/shared-core strategy is not yet a standalone doc; the S3 module-split
     context lives in RemainingWork-2026-06-23.md §2. -->

