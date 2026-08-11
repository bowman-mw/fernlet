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
  including the wrapped content key, in whichever custody state it exists
  (`WhenUnlockedThisDeviceOnly`), the biometric content-key
  copy (`WhenPasscodeSetThisDeviceOnly` + `.biometryCurrentSet`), the no-lock device journal and
  worry keys, the pending-narrative buffer key, the proximity identity private keys, heart-drop
  prekeys and sidecar key, and the HealthKit/moderation/preferences ancillaries (all
  `…ThisDeviceOnly`, non-synchronizable). Column keys are never stored at all — they are derived
  per call via HKDF-SHA256 from the content key, and those derivations are pinned by
  known-answer tests.
- **Bound further by this change:** new sealed-column writes carry a per-install random ID as
  AEAD associated data (format v2, version-byte-prefixed), so the ciphertext itself — not just
  its keys — refuses to open on any other install. Legacy blobs still open (dual-open fallback)
  and are progressively rebound as they are routinely re-sealed.
- **Hard-bound to the Secure Enclave (§6.1, done):** where a Secure Enclave is present, the lock
  content key is wrapped under a non-exportable enclave-resident key **and the scrypt-wrapped
  copy is deleted** — after, and only after, a freshly re-read enclave wrap is proven to unwrap
  to exactly that key (keep-old-until-verified; every failure path keeps the scrypt item, and
  SE-less hardware keeps it forever). Custody is therefore a two-state machine discriminated by
  the presence of `com.fernlet.lock.wrappedContentKey`: **present** = legacy (scrypt
  authoritative), **absent** = hard-bound (the enclave wrap is the only recoverable copy). The
  passcode still gates entry through the unchanged salt + verifier; what changes is that
  possessing the passcode is no longer *sufficient* — the enclave must also be present. A fresh
  install on enclave hardware is born hard-bound at setup; an existing install flips on its first
  unlock under this build.
- **The two deliberate exceptions**, each of which exists to serve the user, not the developer:
  the **friend-wall media key** (`AfterFirstUnlock`, non-sync) rides the encrypted device backup so
  friends' shared photos survive onto a replacement phone — that is permanent, and it is now the
  *only* media key with that property; the **backup-escrow key** is the *only* synchronizable key
  (iCloud Keychain E2EE) because cross-device restore of the opt-in sealed backup is its entire
  purpose.
- **Bound by the Phase-5 media-key split (§6.3 item 3, done):** the user's OWN photos — meal,
  recipe and gym-progress bytes plus the sealed progress index — moved to a second keychain row
  (`…ownContentKey`) that is re-bound in place to `AfterFirstUnlockThisDeviceOnly` once, and only
  once, two conditions hold: the eager re-seal pass has proven no own file is still under the
  pre-split key, AND the user has a sanctioned cross-device route (the opt-in own-photo escrow
  backup, or an explicit recorded consent that these photos will not restore to a new phone). The
  flip is an in-place `SecItemUpdate` — a delete-then-add re-store would open a window in which no
  own-photos key exists at all — and it never changes the key material, so no photo is stranded by
  it. Afterwards the own read paths drop their pre-split dual-open fallback, which is what makes the
  binding mean anything. Pinned by `KeyCustodyBoundaryTests.ownPhotoKeyBindsToThisDeviceOnceItsGateIsSatisfied`
  and `FernletTests/OwnPhotoKeyBindingTests`. Honest limit: an encrypted device backup taken while
  the row was still backup-restorable already carries the old key, so the binding protects backups
  taken *after* the flip, and a user who takes neither route keeps the old, backup-restorable
  custody rather than being bound without a recovery path.

**What this buys, concretely:** a bulk copy of the app's files plus a keychain dump is
cryptographically worthless off the device — on enclave hardware, *even with the passcode*, which
is what kills off-device PIN brute force (a 4-digit PIN through scrypt is ~10⁴ tries). And a future app version that wanted to make sealed
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
  makes the stronger claim that the key never exists in extractable form — which is what the
  hard binding in §4 now buys on enclave hardware, and it comes with the three costs below.
- **The hard binding costs a real recovery path: a same-device restore from an encrypted iOS
  backup can no longer unlock sealed data with the passcode.** `ThisDeviceOnly` keychain items
  restore to the *same* device, but Secure Enclave keys never restore anywhere — so an "Erase All
  Content and Settings", a Secure-Enclave reset, or a restore onto replacement hardware destroys
  the content key permanently. Escrow-backed payloads (cycle narratives, journal narratives,
  intimacy logs, sensitive notes, each behind its own opt-in toggle) survive via the sealed iCloud
  backup; **the Worry Box does not and is accepted to die on an Erase All** — "let it go" notes
  are deliberately device-only. When this happens the app says so: a correct passcode surfaces
  "Sealed data can no longer be opened on this device. Reset app lock to continue." rather than
  silently failing to decrypt — and the reset it names is reachable from that very screen (the
  unlock overlay grows its own card for this state, because a correct passcode never trips the
  failed-attempt ladder that the app's other reset button hangs off). Three narrower properties
  keep that message honest. A keychain that merely *would not answer* — the device auto-locked
  during the scrypt derive, protected data unavailable — is a **different, retryable** error that
  never mentions reset; only a provably absent or provably rejecting enclave key is terminal. The
  two surfaces that never receive the content key (the progress-photo strip, which seals under its
  own intact key, and Settings → App lock) still open on the verifier match, so the terminal state
  degrades non-hub entry to a passcode check rather than bricking it. And while biometrics are
  enabled the bypass copy below is a real recovery path: Face ID re-establishes the enclave wrap
  from it, so the app offers that repair *before* it offers the destructive reset.
- **With biometrics enabled, the strongest form of the claim does not hold.** Face ID / Touch ID
  unlock keeps a second copy of the raw content key in its own keychain item
  (`WhenPasscodeSetThisDeviceOnly` + `.biometryCurrentSet`) rather than inside the enclave. It
  never leaves the device, iOS invalidates it when enrollment changes, and `reset()` destroys it —
  but while it exists the content key lives behind a data-protection ACL, not enclave
  non-exportability. **"The key never exists in extractable form except behind the Secure
  Enclave" is exactly true only with biometrics off.** Routing that copy through the enclave too
  is a tracked follow-up, not done here. The same copy is also, honestly, a **recovery path**: if
  the enclave key dies while biometrics are on, a Face ID unlock still opens the corpus and
  re-establishes the wrap, so a hard-bound install is not unconditionally lost — it is lost when
  the enclave key dies *and* no bypass copy exists. The enclave never yields to it, though: an
  openable enclave wrap outranks the bypass, and a bypass whose bytes the enclave contradicts is
  deleted rather than honored (nothing unauthenticated may overwrite the authoritative wrap).
- **The hard binding is an off-device guarantee, not an on-device one.** The enclave key is gated
  on device unlock, not on the app passcode, so a forensic attacker working on the *unlocked
  device itself* can ask the enclave to unwrap the content key without knowing the app PIN. For a
  4-digit PIN that barrier was already worth ~nothing (10⁴ scrypt attempts); for an alphanumeric
  app password it was real, and this trade removes it. Restoring it means SE-wrapping the
  scrypt-sealed blob instead of the raw key (unlock would then need the enclave AND the passcode)
  — recorded as an open owner sub-decision, not silently chosen.
- **Device-binding your own photos costs you those photos on a phone swap, and it only protects
  backups taken after the flip.** Once the own-photos key is bound (§6.3 item 3), meal, recipe and
  gym-progress photos do not restore from a device backup onto a new or erased phone — the opt-in
  own-photo escrow backup is the only route that brings them back, which is why binding requires
  either that backup or an explicit confirmation that says so. And because an encrypted device
  backup taken *before* the flip already contains the loose key, binding cannot retroactively
  protect a copy someone already has. Until a user takes one of those two routes their own photos
  stay under the pre-5c, backup-restorable custody: the hardening is opt-in because its cost is
  theirs to accept. **Known gap, stated rather than hidden:** on a new phone restored from a device
  backup, the sealed photo *files* come back while the bound key does not, and the escrow route's
  per-corpus no-clobber gate is a file-PRESENCE check — so it currently reads those unopenable
  bytes as "this corpus is in use" and skips the restore. Nothing is overwritten or lost beyond
  what the binding already cost, but a user with the photo backup on does not get their photos back
  automatically in that path yet. The fix (teach the gate to tell "not empty" from "holds only
  bytes this install can never open", off the migration sweep's existing classification) is tracked
  against `OwnPhotoBackupCoordinator`.
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

Each one trades away a recovery path or a documented product decision, so each is recorded here
and decided consciously rather than by drift. Items marked **DONE** were subsequently decided and
shipped; the rest are still open.

1. **Hard SE-binding of the lock content key — DONE (2026-08-10, security-hardening Phase 4).**
   The scrypt-wrapped legacy item is deleted once the Secure-Enclave wrap verifies. Gain
   (realized): the sealed corpus plus a full keychain dump are useless off-device *even with the
   passcode* — kills off-device PIN brute force (a 4-digit PIN through scrypt is ~10⁴ tries) and
   forces any future sharing feature into an explicit decrypt-and-re-export migration. Cost
   (accepted): "Erase All Content and Settings" or any Secure Enclave reset destroys the SE key,
   so a same-device restore from an encrypted backup can no longer unlock sealed data with the
   passcode (before this change it could — `ThisDeviceOnly` items restore to the *same* device).
   Escrow-backed payloads survive; sealed types not covered by the backup are lost, and the app
   says so explicitly (§5) instead of failing silently. How the transition avoids destroying data:
   the deletion is **keep-old-until-verified** — the scrypt item goes only after a freshly re-read
   enclave wrap has been proven to unwrap to exactly the authoritative key, and no error path ever
   deletes. Two residuals stay open and are stated in §5: the biometric-bypass copy of the key is
   not enclave-wrapped, and the enclave key is device-unlock gated rather than app-PIN gated, so
   the guarantee is off-device rather than on-device. Four properties keep the terminal state from
   being worse than the trade it was approved as, and each is pinned by a test in
   `FernletTests/SecureEnclaveWrapTests`: the reset the error prescribes is reachable from the
   unlock overlay itself; a transient keychain read failure is a separate retryable error that
   never advises a reset; the two scopes that never receive the content key still unlock on the
   verifier match (so Settings → App lock cannot be bricked); and while a biometric bypass copy
   survives, the repair is offered before the destruction — with the enclave, never the bypass, as
   the authority on what the key is.
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
   A third, narrower gap found in the P3 review and now surfaced rather than silent: a
   lock-CONFIGURED device can still hold journal rows sealed under the **device journal key** —
   entries written before the lock existed, outside the window
   `JournalSealingCoordinator.migrateDeviceKeyEntriesToUserKey` re-keys. The export refuses rather
   than shipping a chunk set that silently omits them, and audits any residual shortfall
   (`sealedBackup.journalPartialExport`), but those rows are still uncovered until a full-store
   re-key pass exists. That pass is what makes them readable at all and is tracked separately.
2. **The same hard-binding decision for the no-lock device journal/worry keys.** SE-wrapping them
   removes the erase-and-restore-same-device recovery those users currently have — and no-lock
   users are the least likely to have sealed backup enabled.
3. **Device-binding the media key — DONE (2026-08-11, security-hardening Phase 5).** (`ThisDeviceOnly`
   for the user's OWN photos; the friend wall deliberately keeps the old custody.) Directly reverses
   the documented product decision in `PrivateMediaKeyStore.swift` for own photos: they no longer
   survive a device-backup restore onto a new phone. Middle path worth pricing: bind the key AND
   add a deliberate export/import ceremony (or fold photos into the escrow-sealed backup) as the
   sanctioned cross-device route. Note: the "harden the photo store before gym progress pics"
   follow-up is gated on this decision.
   **STEP 5a (2026-08-11): custody is split, binding is not yet flipped.**
   The middle path above was chosen. There are now TWO media keys under one keychain service: the
   friend photo wall keeps the original backup-restorable row (`…contentKey`, `AfterFirstUnlock`,
   non-sync — that product decision is unchanged and permanent, because the wall's whole value is
   surviving onto a replacement phone), while the user's OWN photos — meal, recipe, gym-progress
   bytes and the sealed progress index — moved to a new `…ownContentKey` row. The own row is still
   minted `AfterFirstUnlock` today, so **nothing about restore-ability has changed yet**; what has
   changed is that binding is now a one-line policy flip
   (`KeychainPrivateMediaKeyProvider.defaultDeviceBinding(for:)`) instead of a flag-day. An eager,
   idempotent, crash-safe pass (`OwnPhotoKeyMigrator`, run once per launch off the main path)
   re-seals the own corpora onto the own key, with a read-path dual-open fallback so nothing is
   unreadable in the meantime. The flip is gated on `OwnPhotoMigrationLatch` — the persisted proof
   that zero own files are still under the old key — AND on the sanctioned cross-device route
   (escrow photo backup or explicit consent). Honest limit until the latch is set: an un-migrated
   own photo is still openable under the backup-restorable friend key. Pinned by
   `FernletTests/OwnPhotoKeyMigrationTests` and `KeyCustodyBoundaryTests`
   (`ownPhotoKeyIsASecondRowDistinctFromTheFriendWallKey` asserts the two rows really are two
   independent, non-synchronizable keys, so a "split" that vended the same bytes twice fails loudly;
   the row's accessibility class is asserted by the step-5c test named below).
   **UPDATE (2026-08-11, Phase 5 step 5b): the sanctioned cross-device route now exists.** Own photos
   have an **opt-in, per-photo escrow backup** — one AES-GCM-sealed CloudKit record per photo id
   (`sealed-photo.<corpus>.<photoId>`, record type `SealedPhotoRecord`) plus a sealed per-corpus
   manifest written LAST as the commit marker, all derived on the same v2 salted escrow key as item 4
   and domain-separated from it by a v3 AAD layout (`fernlet.sealed-photo.aad.v3`, binding corpus +
   signing key + slot + generation + timestamp). Deliberately NOT a `SealedBackupPayloadType` case:
   delete-all and the settings toggles iterate `allCases`, and photos must not be routed through the
   chunked path, which rewrites its whole set on every change. What that buys the user: adding one
   photo uploads one record plus a small manifest, deleting one drops an entry, and a phone swap
   restores from the manifest — so binding the own key in 5c no longer means "your photos die with
   the phone". Off by default; the enable dialog carries an honest size disclosure (own corpora have
   no count cap, so a large library really can cost 100–250 MB of the user's iCloud quota); turning it
   off runs the WS-5 destructive ceremony and deletes the records. Restore is gated per corpus by a
   FILE-PRESENCE emptiness check and always runs BEFORE any re-upload, so a device that has not
   restored yet can never replace the cloud copy with an empty manifest. The progress corpus's sealed
   timeline index travels inside the (authenticated) manifest — bytes without dates and captions
   would restore as an invisible timeline. Rollback is caught by a photo-namespaced
   `SealedBackupGenerationStore` high-water mark on the manifest, plus a per-id content hash inside
   it. Pinned by `FernletTests/SealedPhotoBackupTests` and the byte-exact AAD v3 pin in
   `SealedBackupFormatPinTests`; the delete-all teardown is enforced by `PrivacyWipeCoverageTests`
   (`deleteOwnPhotoEscrowBackups`).
   **UPDATE (2026-08-11, Phase 5 step 5c): the binding is flipped, and the fallback is gone with it.**
   `…ownContentKey` is re-bound to `AfterFirstUnlockThisDeviceOnly` by `OwnPhotoKeyBinder`, gated on
   `OwnPhotoMigrationLatch` **AND** a sanctioned cross-device route — the escrow photo backup above
   being ON, or an explicit `OwnPhotoDeviceBindingConsent` recorded through Privacy & Data →
   "Lock photos to this device", whose confirmation says in as many words that these photos will not
   come back on a new or erased phone. Both halves are runtime facts about this device, which is why
   the flip is a gate rather than the "one-line policy constant" the plan sketched: a build-time flip
   would bind on devices satisfying neither condition, which is exactly the data-loss shape the gate
   exists to prevent. Three mechanics carry the safety: the flip is an in-place `SecItemUpdate` (a
   delete-then-add would open a window with no own-photos key on the device, and a crash inside it
   destroys every own photo); "is it bound?" is read from the row's live `kSecAttrAccessible` rather
   than a persisted flag (a flag rides the backup onto a phone the bound row never reached); and the
   own read paths drop their pre-split `legacyKeyProvider` exactly when the row is bound —
   `FernletStore` and `OwnPhotoBackupCoordinator` both, pinned as a biconditional. A user who takes
   neither route is not bound and keeps the pre-5c custody: the hardening is opt-in *because* its
   cost is the user's, not because it is unfinished. Honest limit: a device backup taken before the
   flip already carries the loose key, so the binding protects backups taken after it. Pinned by
   `FernletTests/OwnPhotoKeyBindingTests` (including "no own photo becomes unreadable across the
   flip", end to end on the real keychain rows) and by `KeyCustodyBoundaryTests`
   (`ownPhotoKeyBindsToThisDeviceOnceItsGateIsSatisfied`). Item 3 is now **closed**.
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
