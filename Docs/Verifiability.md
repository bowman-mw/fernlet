# Verifiability — how to check Fernlet's privacy claims yourself

**Status:** Standing commitment. This document is the bridge between the promises in
[`Docs/Privacy-Policy.md`](Privacy-Policy.md) (what we say to users) and the machinery in this
repository (what a machine or an outside auditor can actually check). Its companion documents are
[`Docs/No-Tracking-Wall.md`](No-Tracking-Wall.md) (the network-egress wall) and
[`Docs/SPM-Module-Carveup-Plan.md`](SPM-Module-Carveup-Plan.md) (the S3 sealed-data wall).

The premise: **a privacy policy is a claim; this repo is the evidence.** Every guarantee below
names the exact command, test, or file that backs it, so "trust us" can be replaced with
"run this".

> **Publishing status.** The repository is not yet public and `fernlet.com` is not yet deployed
> (see §7). Everything in this document is written so that the moment the owner flips the repo
> public and deploys [`Site/`](../Site/README.md), every verification step below works for anyone
> — nothing here depends on being an insider except access to the source itself.

---

## 1. What Fernlet guarantees

1. **No developer server, no telemetry, no tracking.** No user data reaches the developer or any
   third party for advertising, attribution, analytics, crash telemetry, or any other form of
   tracking — there is no backend, no account, no install ping, no crash reporter, no
   "anonymous usage statistics". ([`No-Tracking-Wall.md`](No-Tracking-Wall.md) §1)
2. **Every byte that leaves the device is enumerable, and enumerated.** The complete outbound
   surface — five hardcoded hosts, Apple-operated system services the user opts into, URLs the
   user themself supplies, and link-local peer-to-peer — is written down in
   [`No-Tracking-Wall.md`](No-Tracking-Wall.md) §3–§4 and enforced by tests.
3. **Sealed data is structurally unreachable by AI and sync code.** The on-device AI
   (`AIProviders`) and iCloud-sync (`CloudKitSync`) modules cannot import the sealed `Private*`
   stores — a forbidden `import` is a hard build error, not a code-review catch.
4. **The sealed corpus is device-bound at rest.** Every key that can open the sealed
   journal/worry/cycle/intimacy ciphertext is a `ThisDeviceOnly` keychain item (restorable only
   onto the same physical device), and new sealed writes are additionally bound to a per-install
   random ID via AEAD associated data (§4). The two deliberate exceptions — the media key and the
   backup-escrow key — are documented with their reasons in §4.
5. **These promises bind future versions.** Privacy-Policy §13 makes the no-retroactive-use and
   no-collection commitments perpetual; this document plus the CI walls make a quiet violation
   *mechanically loud* (§4, §5); and the governance layer (CODEOWNERS on the wall files, signed
   release tags, required status checks — [`Release-Process.md`](Release-Process.md)) makes a
   deliberate violation *attributable*.

## 2. How to verify each guarantee

All commands run from the repo root and need Xcode with an iOS simulator. Build once:

```
xcodebuild build-for-testing -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'
```

| Claim | Verification |
|---|---|
| No tracking SDK, no unlisted network destination, no third-party dependency beyond CryptoSwift, private-tab-only fetching, clean privacy manifests | `xcodebuild test-without-building -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FernletTests/NoTrackingBoundaryTests` — eight independent scans, each with planted-violation fixtures proving the scan itself works. What each test forbids is tabled in [`No-Tracking-Wall.md`](No-Tracking-Wall.md) §2. |
| AI/sync modules structurally cannot reach sealed stores | `Scripts/spm-wall-check.sh` (the enforcement build), and `Scripts/spm-wall-selftest.sh` — the negative test: it *plants* a forbidden `import PrivateHealthStore` inside the walled `AIProviders`, asserts the build fails, reverts, and re-confirms the clean tree passes. Plus the grep half: `-only-testing:FernletTests/S3BoundaryTests`. |
| The complete egress inventory is accurate | Read [`No-Tracking-Wall.md`](No-Tracking-Wall.md) §3 (hardcoded-host allowlist — the test fails on both an unlisted host AND a stale listed one) and §4 (Apple services, user-supplied URLs, link-local mesh). Then grep the tree yourself: every HTTP client must live in one of the three pinned files, so there is very little to read. |
| Key custody: every sealed-data key is device-bound; only the two sanctioned exceptions exist | `-only-testing:FernletTests/KeyCustodyBoundaryTests` — writes through each production key store and reads the keychain row's actual `kSecAttrAccessible` / `kSecAttrSynchronizable` attributes back, then greps shipping code so `synchronizable: true` and any non-`ThisDeviceOnly` accessibility class appear only at the sanctioned sites. |
| The at-rest crypto formats cannot drift silently | `-only-testing:FernletTests/FernletLockCryptoTests` (scrypt/verifier/wrap primitives + known-answer vectors pinning all four sealed-column HKDF labels), `-only-testing:FernletTests/ColumnCryptoDeviceBindingTests` (device-bound format v2 + legacy compatibility), `-only-testing:FernletTests/SealedBackupFormatPinTests` (pins record format **v1 and v2**: both escrow HKDF derivations — the legacy static one and the per-generation-salted one — plus the sealed-backup AAD v2 byte layout, which v2 leaves unchanged, all pinned end-to-end, including that a v1 and a v2 record both open on one identity. It also pins **every payload type's raw value** and round-trips all four on v2 — the raw value keys the CloudKit record name *and* is bound into the AAD, so a rename would orphan existing backups; a relabelled chunk is proved unopenable as another payload). |
| Observe the app's actual traffic (no source trust required) | Run the app in a simulator behind an intercepting proxy (e.g. mitmproxy: `mitmproxy --mode local`, or set the Mac's system proxy and trust the mitm CA in the simulator). You should see: nothing at install, nothing at launch, nothing during normal logging. Traffic appears **only** when you invoke a feature that names its egress: the off-by-default packaged-food lookup (one request to `html.duckduckgo.com`), a recipe/product URL you pasted, the one-time GET for a saved recipe's own picture on first open of its detail page (to the image host the recipe page itself named via JSON-LD/`og:image` — often a third-party CDN, not the pasted URL's host), the `SFSafariViewController` connection pre-warm to a saved recipe's source host when its detail or notes sheet appears (a DNS lookup + TLS handshake only, no HTTP request), or Apple's own CloudKit/WeatherKit endpoints when you enabled those features. The complete expected-traffic inventory is [`No-Tracking-Wall.md`](No-Tracking-Wall.md) §3–§4 — judge any capture against that list, not this summary. Note Apple system services (APNs, App Store, CloudKit) use certificate pinning and will not decrypt — but their *hosts* are visible and are Apple's, not ours. |
| Release binaries correspond to the source | Byte-exact reproduction of an App Store build is not possible on iOS (Apple re-signs, re-encrypts, and may recompile bitcode-free binaries server-side; see §5). The honest substitute: every release is an annotated **signed git tag**, `Scripts/release-checksum.sh` publishes SHA-256 checksums of the exact archived products for that tag, and anyone can build the same tag themselves and diff behavior — plus sideload their own build; nothing in the app depends on being the App Store copy. |

## 3. Standing invitation: independent traffic audit

**We invite — at any time, without notice or permission — anyone to intercept, record, and
publish Fernlet's complete network traffic.** Security researchers, journalists, or a user with
an afternoon and mitmproxy: instrument the app, use every feature, and publish everything you
find, favorable or not.

- No terms of service restrict analyzing Fernlet's own traffic; this invitation is the opposite
  of a gag.
- Report findings to **fernletapp@gmail.com** (or a public issue once the repo is public). A
  finding that contradicts §1 is a release-blocking bug, treated with the same severity as data
  loss.
- The falsifiable claim on record: **apart from the enumerated egress in
  [`No-Tracking-Wall.md`](No-Tracking-Wall.md) §3–§4, the app makes no network requests.** If you
  observe one, we are wrong somewhere, and we want the capture.

## 4. Device binding — what it does, and what a future "make it shareable" must visibly do

The sealed corpus (journal narratives, Worry Box notes, cycle narratives, intimacy logs) is
protected by keys that never leave the device:

- **Already bound (attribute-verified by `KeyCustodyBoundaryTests`):** every lock keychain item
  including the wrapped content key (`WhenUnlockedThisDeviceOnly`), the biometric content-key
  copy (`WhenPasscodeSetThisDeviceOnly` + `.biometryCurrentSet`), the no-lock device journal and
  worry keys, the pending-narrative buffer key, the proximity identity private keys, heart-drop
  prekeys and sidecar key, and the HealthKit/moderation/preferences ancillaries (all
  `…ThisDeviceOnly`, non-synchronizable). Column keys are never stored at all — they are derived
  per call via HKDF-SHA256 from the content key, and those derivations are pinned by
  known-answer tests.
- **Bound further by this change:** new sealed-column writes carry a per-install random ID as
  AEAD associated data (format v2, version-byte-prefixed), so the ciphertext itself — not just
  its keys — refuses to open on any other install. Legacy blobs still open (dual-open fallback)
  and are progressively rebound as they are routinely re-sealed. Additionally, where a Secure
  Enclave is present, the lock content key gains a second, non-exportable Secure-Enclave wrap
  (verified by round-trip before it is ever preferred; the legacy scrypt wrap is kept intact —
  removing it is an owner decision, §6).
- **The two deliberate exceptions**, each of which exists to serve the user, not the developer:
  the **media key** (`AfterFirstUnlock`, non-sync) rides the encrypted device backup so photos
  survive onto a replacement phone; the **backup-escrow key** is the *only* synchronizable key
  (iCloud Keychain E2EE) because cross-device restore of the opt-in sealed backup is its entire
  purpose.

**What this buys, concretely:** a bulk copy of the app's files plus a keychain dump is
cryptographically worthless off the device. And a future app version that wanted to make sealed
data shareable or cloud-syncable could not do it with a quiet schema flag — it would have to add
new key custody (fails `KeyCustodyBoundaryTests`' exact-set attribute and grep pins), change the
at-rest format (fails the known-answer and format-pin tests), and ship an explicit re-encryption
migration — a loud, reviewable diff across CODEOWNERS-protected files, in a public repo, under a
signed tag.

## 5. Honest limits — what none of this can promise

Aligned with [`No-Tracking-Wall.md`](No-Tracking-Wall.md) §6; stated here without varnish:

- **Nothing can stop a future version from exfiltrating what the *user* can see.** Any build
  running while the user unlocks holds plaintext in memory; the display path is always a
  potential exfil path. What device/SE binding actually buys is narrower and real: bulk theft of
  the at-rest corpus becomes worthless off-device, and a "make it shareable" change must be a
  loud diff (§4). The standing defenses against a quiet-exfil future version are structural, not
  cryptographic: the S3 wall, the no-tracking allowlist, the open-source diff, CODEOWNERS +
  signed tags, and App Store review.
- **A malicious fork or a determined insider can delete the walls.** The walls protect this
  repository against accidental regression and make deliberate regression legible — a visible,
  attributable deletion — not impossible.
- **`ThisDeviceOnly` is an OS promise, not physics.** A jailbroken or forensically imaged device
  with the device passcode can yield those keychain items. Only Secure Enclave non-exportability
  makes the stronger claim that the key never exists in extractable form — which is why the SE
  wrap exists, and why completing it (deleting the legacy scrypt-wrapped item) is on the owner
  list below rather than silently done: it trades away a recovery path.
- **The escrow-sealed iCloud backup is, by design, exactly as strong as the user's Apple
  account.** It is openable on any device holding the user's iCloud Keychain — it can never be
  bound tighter without destroying its purpose. The per-generation-salt hardening (§6.4, done)
  **bounds** a compromise to one generation per derived key; it does not eliminate it — the escrow
  private key still derives every generation's key, one at a time. Records written before that
  change (format v1) remain openable under the single static derivation, by design: re-keying them
  is impossible without the plaintext, and they are replaced by their next re-seal.
- **iOS builds are not byte-exactly reproducible** (§2, last row). Checksums + signed tags are a
  self-build baseline and an attribution trail, not a store-binary proof.
- **Apple frameworks are trusted, not audited.** CloudKit, WeatherKit, APNs, and the OS itself
  make traffic we neither see nor control.
- **The tests are lexical and attribute-level, not semantic.** They read source text and keychain
  attributes; they do not prove the absence of a sufficiently indirect construction. The
  HTTP-client pin and the S3 compiler wall are the structural answers to the realistic versions
  of that.

## 6. Further hardening awaiting an owner decision

Deliberately **not** done in this change, because each one trades away a recovery path or a
documented product decision. Recorded so the trade is decided consciously, not by drift:

1. **Hard SE-binding of the lock content key** — delete the scrypt-wrapped legacy item once the
   Secure-Enclave wrap verifies. Gain: the sealed corpus plus a full keychain dump become useless
   off-device *even with the passcode* — kills off-device PIN brute force (a 4-digit PIN through
   scrypt is ~10⁴ tries) and forces any future sharing feature into an explicit
   decrypt-and-re-export migration. Cost: "Erase All Content and Settings" or any Secure Enclave
   reset destroys the SE key, so a same-device restore from an encrypted backup could no longer
   unlock sealed data with the passcode (today it can — `ThisDeviceOnly` items restore to the
   *same* device). Escrow-backed payloads would survive; sealed types not covered by the backup
   would be lost.
   **Precondition partly satisfied (2026-08-10, security-hardening Phase 3):** journal narratives
   and intimacy logs are now first-class sealed-backup payload types (`journalNarratives`,
   `intimacyLogs`, launched directly on record format v2), each behind its own opt-in toggle, so
   they survive a device reset for any user who enables them. **This REVERSES the earlier
   "intimacy is not part of any sealed backup" decision** — recorded here and in
   `Docs/FernletSpecificationV3.md` § "Encrypted Sealed Backup" rather than left to drift.
   Two gaps remain, both deliberate and both narrowing what #1 may promise:
   the **Worry Box stays out by design** ("let it go" notes are device-only and are accepted to die
   on a device reset), and **no-lock installs are uncovered** — the backup pages the lock content
   key, which is nil when no lock is configured, so a no-lock user's device-key-sealed journals are
   not backed up (§6.2 is the same trade for the same users).
2. **The same hard-binding decision for the no-lock device journal/worry keys.** SE-wrapping them
   removes the erase-and-restore-same-device recovery those users currently have — and no-lock
   users are the least likely to have sealed backup enabled.
3. **Device-binding the media key** (`ThisDeviceOnly` and/or SE-wrap). Directly reverses the
   documented product decision in `PrivateMediaKeyStore.swift`: the photo corpus would no longer
   survive a device-backup restore onto a new phone. Middle path worth pricing: bind the key AND
   add a deliberate export/import ceremony (or fold photos into the escrow-sealed backup) as the
   sanctioned cross-device route. Note: the "harden the photo store before gym progress pics"
   follow-up is gated on this decision.
4. **Sealed-backup escrow: do NOT device-bind it** — cross-device restore is its entire purpose.
   **DONE (2026-08-10): the bounded hardening shipped as record format v2.** Every backup generation
   mints a 32-byte CSPRNG salt, stamped on *every* chunk of that generation (not just the head — the
   head is written last as the commit marker) and mixed into the escrow HKDF under the versioned info
   string `com.fernlet.sealed-backup.v2`. One escrow-key compromise now derives one key per
   generation instead of one key for all of them. Coexistence is pure read-compat with no migration:
   a record with no `formatVersion`/`keySalt` decodes as v1 (empty salt, info
   `com.fernlet.sealed-backup`) and keeps opening byte-identically, while a `formatVersion >= 2`
   record *requires* a 32-byte salt or fails closed as malformed, and a chunk set that mixes formats
   or salts is rejected. All new writes are v2. The device-binding half stays rejected, unchanged:
   binding the escrow key would destroy cross-device restore. Pinned by
   `FernletTests/SealedBackupFormatPinTests`.
5. **The escrow custody model itself.** It is exactly as strong as iCloud Keychain E2EE plus the
   user's Apple account. If that is not acceptable, the alternative is a user-held recovery
   secret or a device-to-device QR ceremony instead of iCloud Keychain — and zero-config
   new-device restore stops being zero-config. A trade to decide, not a code fix.
6. **Default-on backup exclusion for the sealed `FernletPrivate` store file** (currently
   user-preference-driven). Tightens at-rest exposure in backups, but the ciphertext is already
   unreadable off-device (`ThisDeviceOnly` keys), and the settings UI already warns about the
   no-cloud-recovery consequence — changing the default changes user recovery expectations.

## 7. What publishing unlocks

Two steps remain, both owner actions (tracked in [`Release-Process.md`](Release-Process.md)):

1. **Flip the repository public.** Until then, "read the source" and "run the tests" work only
   for the owner. Public, they become the primary guarantee: removing a wall is a visible diff;
   §3's invitation gains an audience; CODEOWNERS + branch protection + signed tags become
   third-party-checkable.
2. **Deploy [`Site/`](../Site/README.md) to `fernlet.com`** (currently a parking page), which
   hosts the privacy policy at a public URL (an App Store submission requirement) and should link
   this document.

Until both happen, every claim above is still *enforced* — CI, hooks, and the tests run
regardless — but only *verifiable* by the owner. This document deliberately over-prepares for
publication rather than waiting for it.

## 8. Related

- [`Docs/Privacy-Policy.md`](Privacy-Policy.md) — the user-facing promises, including the
  perpetual §13 commitments this document backs.
- [`Docs/No-Tracking-Wall.md`](No-Tracking-Wall.md) — the egress wall: guarantee, enforcement
  table, allowlist, full traffic inventory, honest limits.
- [`Docs/Release-Process.md`](Release-Process.md) — signed tags, branch protection, checksum
  publication, and the publish steps.
- [`.github/CODEOWNERS`](../.github/CODEOWNERS) — review gate on every wall file.
- `FernletTests/NoTrackingBoundaryTests.swift`, `FernletTests/S3BoundaryTests.swift`,
  `FernletTests/KeyCustodyBoundaryTests.swift`, `FernletTests/ColumnCryptoDeviceBindingTests.swift`,
  `FernletTests/SealedBackupFormatPinTests.swift` — the mechanical halves.
