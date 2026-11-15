# G9 Data integrity & recovery: plan (2026-11-15)

Status: **plan, awaiting owner approval. Nothing is built.** Each "Owner call" below is also on
the review page; the recommended option is marked. Code references are against `origin/main`
db319b76.

Reviewed with the owner 2026-11-15 (second pass): the calls below were stress-tested against the
code and nine were changed. R2 is no longer an owner call (settled as engineering design), R7 is
new, and S3, S4, S5, M1, M2, M4 and M6 were reworded or gained an option.

## Goals

| Part | Goal | Who it reaches |
| --- | --- | --- |
| 1 Sync | Sync stops losing or reviving entries | Someone with a phone and an iPad on one Apple ID: the iPad out for recipes while cooking, and food logged on it too, with the phone as the main device. (The target is iPhone-only today, `TARGETED_DEVICE_FAMILY = 1`, so the iPad runs the iPhone app.) |
| 2 Recovery | A recovery code opens backups when iCloud Keychain is lost | Anyone with an encrypted backup, on one phone |
| 3 Memory | The person controls what Fernlet remembers | Everyone who journals |

Order of importance, agreed with the owner 2026-11-15: recovery, memory, sync. The owner's
phone-plus-iPad case makes same-day edits on two devices ordinary (a meal logged on the iPad in
the kitchen, the rest on the phone) and is why saved recipes are in S3. The owner also confirmed
memories should follow the person to another device, so M1 = A stays recommended over C.

G9 has three parts, one PR each:

| PR | Part | Depends on |
| --- | --- | --- |
| G9-1 | Sync: per-device day rows, entry stamps, tombstones, soft-deleted custom items | — |
| G9-2 | Recovery codes for the sealed backups | — (independent of G9-1) |
| G9-3 | Memory controls: forget/edit, `userEdited`, wipes, extraction switch, private memories | G9-1 if M1 = A; nothing if M1 = C |

G9-1 and G9-2 can be built in parallel (different files). G9-3 stacks on G9-1 only if Core
memories move to their own rows (call M1).

---

## Part 1: Sync tombstones and per-entry merge (PR G9-1)

### What happens today

- Sync is Core Data mirrored by `NSPersistentCloudKitContainer`
  (`FernletKit/Sources/CloudKitSync/Persistence.swift`). There is no hand-written CloudKit code.
  The view context merges with `mergeByPropertyObjectTrump` (`Persistence.swift:715`). Every
  record is one JSON `payloadData` blob, so in practice **the whole row is last-writer-wins**.
- Six entities: the aggregate `FernletDatabaseRecord` blob (settings, Core memories, …),
  `SavedRecipeRecord`, `CustomItemRecord`, `CoinLedgerRecord`, `MilestoneLedgerRecord`, `DayRecord`.
- **An emptied day deletes its row.** `CoreDataFernletRepository.writeDayRow`
  (`CoreDataFernletRepository.swift:342-355`) upserts a day with content and hard-deletes it when
  empty. The delete does reach the other phone, and that phone reloads on a remote change
  (`FernletStore.apply(_:)`). The day returns only when the other phone saves that same day before
  the delete has arrived (offline, or inside the sync delay): its upsert finds no row and writes
  its whole stale day as a new one.
- **Two devices editing one day lose entries.** Both write the same `DayRecord`; CloudKit keeps
  the newer payload, and entries only the other device had are gone. The read side (#24) unions
  entries when it sees *duplicate rows* for a day (`DayRecordRepository.swift:229-393`), but it
  cannot tell "deleted on A" from "B never had it", so a deleted entry comes back once
  (`:342-349` says the write-side merge is "still owed").
- Entries (meals, workouts, journal stubs, …) carry no stamp of their own. `DayRecord.updatedAt`
  is the only clock, and the migration backfill gave old rows all the same stamp (ties).
- **Custom clothing designs** (`CustomItemRecord`) are hard-deleted
  (`CustomItemRepository.swift:75-93`). The delete syncs, and `CustomItemService.reloadFromStore()`
  runs on every remote change, so the design returns only when the other phone changed it (price,
  shop listing, an edit) before hearing of the delete: its upsert-by-id then writes a fresh row.
- **Saved recipes** (`SavedRecipeRecord`) are erased the same way (`SavedRecipe.swift:278`, same
  upsert-only discipline) and can return the same way.
- `WorkoutTombstoneStore` is a device-local 200-UUID ring that stops a just-deleted workout's
  Health sample from being re-imported. It has nothing to do with CloudKit and stays as it is.

### The 2026-08-21 decision, read carefully

"Custom items and day records stay disclose-don't-tombstone" was made about **Delete Everything
resurrection** (a second device syncing old days back after a wipe). It added the multi-device
sentence on `DeleteEverythingSheet.swift:217-224` and a reset marker for milestones only. It did
not decide anything about ordinary deletes (removing a meal, emptying a day, deleting one design),
which is what G9 is about. This plan keeps that decision exactly for Delete Everything and adds
tombstones only for ordinary deletes. Call **S2** asks the owner to confirm this reading.

### Design (recommended: S1 = A)

**1. One row per device per day.** `DayRecord` gains an additive `deviceKey` attribute (a random
per-install id kept in device-local defaults; not the proximity identity, not a hardware id). Each
device only ever writes its own row for a day, so two devices never write the same CloudKit
record and CloudKit's last-writer-wins can no longer drop anything. Reading a day merges every
device's row for that `dateKey`.

**2. Every entry gets a stamp.** Each entry inside a day payload gains `modifiedAt` (wall clock)
and `modifiedBy` (the device key, used only to break exact ties). Payload change, decoded with
`decodeIfPresent`; a missing stamp reads as the row's `updatedAt`.

**3. Deletes become tombstones.** A day payload gains `removed: [entryID: Date]`. Deleting an
entry moves it from the list into `removed`. An emptied day keeps its row (no live entries, some
tombstones) instead of being deleted.

**4. The merge rule** (a last-writer-wins element set, per entry):
- For each entry id across all device rows, the newest stamp wins, whether it is an entry or a
  tombstone. Ties break by device key, so every device computes the same answer.
- Within one entry the fields are not merged separately: an entry edited on two phones keeps the
  later edit whole. Field-by-field merge inside a meal is not worth its cost for one person's
  phones.
- Day-level fields that are not entries (water count, mood, sleep note, …) get the same
  treatment as a single pseudo-entry each, so "water went to 5 on A, mood set on B" keeps both.

**5. Compaction (S4 = C recommended: none).** A device never deletes another device's row (that
would be a write to a record it does not own). Tombstones are kept for good: each is an id and a
date inside the day payload, bounded by the entries ever made, so there is no pruning code and no
window after which a long-offline phone could bring an entry back. Delete Everything clears them
with the rows. If the owner picks a window instead (S4 = A or B), a device prunes only its own
row's tombstones older than the window, and a phone offline longer than that is the documented
residual. Row count is days × phones, which is small.

**6. "Does iCloud hold data?"** `CloudKitDataService.swift:416-423` assumes empty days have no
row. It changes to "a day with at least one live entry".

**Custom clothing designs and saved recipes (S3 = A).** Soft delete: the `CustomItemRecord` and
`SavedRecipeRecord` payloads gain `deletedAt`. Deleting writes `deletedAt` instead of deleting the
row; custom-item readers already go through `CustomItemService.deduplicatedByID()` and now also
drop soft-deleted ones (newest of `createdAt`/`deletedAt` wins), and `SavedRecipeService` gets
the same filter. The tombstone follows S4 (kept for good under C). S3 = B does designs only and
leaves recipes as a follow-up.

**Row format number (S5 = C).** Every synced row payload this PR writes carries
`format: Int` (`decodeIfPresent`, missing = 0). A build that reads a row with a format newer than
it knows leaves that row alone: it does not heal, merge away or overwrite it. Pre-G9 builds ignore
the field, so this protects later releases, not today's test phones.

**Alternative considered: one row per entry.** Each meal or workout as its own record would let
CloudKit carry deletes natively. Rejected: a much larger migration and read path (thousands of
rows, every day assembled from a fetch), for the same result per-device rows give.

**Not in G9-1:** the aggregate `FernletDatabaseRecord` blob (settings and everything else in it)
stays whole-blob last-writer-wins. Splitting it is a bigger job with its own plan; listed as a
follow-up. Saved recipes change only as far as the S3 soft delete. Core memories leave the blob
only if M1 = A or C (Part 3).

### Schema and migration

- Core Data: one **additive** attribute, `DayRecord.deviceKey` (optional string). Lightweight
  inferred migration covers it. The CloudKit **production** schema must be deployed by the owner
  before a TestFlight build syncs it (`Docs/CloudKit-Schema-Deploy.md`). Owner action, listed in
  the PR.
- Existing rows have no `deviceKey`. They read as a legacy "device" and are folded into this
  device's own row on its first write to that day, so nothing is lost.
- Payload fields (`modifiedAt`, `modifiedBy`, `removed`, `deletedAt`, `format`) are all `decodeIfPresent`.
- **Old builds:** an old build sees the new per-device rows as duplicates. Its read-side merge
  unions entries and deletes the older rows, which undoes tombstones and per-device rows on that
  day. The app is unreleased and multi-device means the owner's own test phones, so the PR says
  **update every phone before syncing** (call S5). No version gate is built; the format number
above is what protects releases after this one. G9-1 should land before the first TestFlight so no
released build predates it.
- New persisted key (the device key) gets a disposition row in
  `PersistedSurfaceWipeBoundaryTests`; Delete Everything clears it.

### Tests (targeted suites)

New `DayRowMergeTests` (two-device and three-device merges, delete vs. never-had, emptied day,
tie-breaks, tombstones kept, legacy rows, clock skew, a newer-format row left alone),
`CustomItemSoftDeleteTests`, `SavedRecipeSoftDeleteTests`; extend
`DayRecordRepositoryTests`, `CloudKitDataServiceTests`, `CloudKitSchemaDeployTests`,
`DeleteAllDataTests`, `CustomItemModelTests`, `FernletPersistenceTests`,
`PersistedSurfaceWipeBoundaryTests`.

### Phone checks owed

Two phones on one Apple ID, both updated: (1) log a meal on each for the same day while one is
offline, then bring it online — both meals stay; (2) delete a meal on A, edit another on B — the
deleted one stays gone; (3) empty a day on A while B is offline — it stays empty when B comes
back; (4) delete a clothing design on A after changing its price on B offline — it does not
return; (5) the same for a saved recipe.

---

## Part 2: Recovery codes (PR G9-2)

### What happens today

- Sealed backups (period, intimacy, journal, body tallies, passport, photos) are encrypted under
  a key derived from the **backup-escrow X25519 key**
  (`App/Fernlet/SealedBackupEscrowKey.swift`), the app's only synchronizable keychain item. A new
  phone gets it through iCloud Keychain; restore tries every escrow key it holds.
- The lock passcode and the lock content key play no part in backups. Local sealed data is bound
  to this phone (Secure Enclave + device binding id) and is never recoverable elsewhere by design.
- **If iCloud Keychain is lost** (turned off, reset, account recovered without it, "Reset
  end-to-end encrypted data"), the backups in iCloud can no longer be opened. Today the only
  answer is "Start a new backup" (Sealed Backup v2 Q-B7).
- Spec §2 (2026-08-11, option b) and ImplementationPlan Phase 18a defer "a BIP39-style mnemonic,
  store an escrow key blob, recovery UI". No word list or mnemonic code exists.

### Design (recommended: R1 = A, R3 = A; the construction is settled, not an owner call)

**What the code recovers: backups only.** A recovery code reopens the sealed backups on a phone
that lacks the escrow key. It does **not** unlock a forgotten passcode on the same phone: that
would make a written-down code a lock bypass for anyone holding the phone, and would undercut the
hard enclave binding. A forgotten passcode stays "reset the lock, then restore from backup with
your code". (Call R1.)

**Construction (a recovery key pair, not a wrapped copy).**
1. Make 128 bits of entropy (`SecRandomCopyBytes`), shown as **12 words** from the BIP39 English
   list with the BIP39 4-bit checksum (catches a mistyped word). Only the *encoding* is BIP39;
   Fernlet does not use BIP39's PBKDF2 seed or anything wallet-shaped.
2. Derive the recovery private key: `HKDF-SHA256(entropy, salt: "", info: "fernlet.recovery-code.x25519.v1")`
   → 32 bytes → `Curve25519.KeyAgreement.PrivateKey`. Keep only the **public** key.
3. Seal every escrow private key the phone holds to that public key with **HPKE**
   (CryptoKit, `DHKEM(X25519, HKDF-SHA256)`, `HKDF-SHA256`, `ChaChaPoly`, info
   `fernlet.recovery-escrow.hpke.v1`, AAD = escrow public key hash). Store the sealed copies in a
   new CloudKit private-database record type `RecoveryEscrowRecord` (opaque ciphertext; one record
   per escrow key; plus the recovery public key so any phone can add to the set).
4. When a phone later mints or adopts a different escrow key (a conflict, or a new backup kind
   minted fresh), it seals that key to the stored recovery public key too. **No code needed for
   that,** which is the reason for the key pair: the code never has to be typed again to keep
   recovery current.
5. **Recover:** on a phone where restore reports "key not on this phone"
   (`deferredKeyNotSynced` / `notRecognized`), Privacy & data offers "Use a recovery code". The
   person types 12 words; checksum validates; the phone derives the private key, opens every
   `RecoveryEscrowRecord`, stores the escrow keys locally as `ThisDeviceOnly` rows (then the
   normal WS-2 promote path), and retries restore.
6. **Make a new code** = new entropy, new key pair, re-seal all escrow keys, delete the old
   records. The old code stops working the moment the delete syncs.
7. **Delete Everything** deletes `RecoveryEscrowRecord`s with the rest of the iCloud data.

**If both the code and iCloud Keychain are lost, the backups cannot be opened by anyone.** The
copy says so when a code is made.

**Check my code (R7 = A).** The Recovery code row offers "Check my code": the person types the 12
words, the phone derives the key pair and compares its public key with the one stored beside the
`RecoveryEscrowRecord`s, and says whether the code still opens the backups. Nothing is restored,
nothing is stored, and the same passcode/Face ID check and duress rules apply as for making a code.

Why not the alternatives (formerly call R2, now settled here because the only owner-visible
difference is not having to retype the code): wrapping the escrow key once under a code-derived key (B)
needs the code typed again every time the escrow key changes; making the code *be* the escrow key
(C) is 24 words, can't be revoked without re-sealing every backup, and covers only one key when
two coexist.

### Threat notes

| Who | Has | Gets |
| --- | --- | --- |
| Someone in your iCloud account | `RecoveryEscrowRecord`s + backups | Nothing: 128-bit code, no offline guessing shortcut. |
| Someone who found your written code | the 12 words | Nothing without your iCloud account. |
| Both of the above | code + iCloud | Your backups (the same reach iCloud Keychain gives today). Make a new code if the paper is lost. |
| A thief with your unlocked phone | the phone | Can't see the code: it is never stored. Showing a code needs a fresh passcode/Face ID check and only happens when making one. |
| Coercion with the duress PIN | duress session | "Recovery code" rows are hidden in a duress session; making a code is refused. |
| A phishing page | — | The app only ever asks for the code inside the restore flow; copy says so. |
| Screenshots / screen recording | — | The code screen uses the existing capture protection (`Design-Capture-Protection`) and is excluded from the app switcher snapshot. |

Other notes: buffers holding entropy are zeroed best-effort after use; the recovery key is never
written to the keychain; new purposes go in the `FernletCryptoPurpose` registry
(`CryptographicPurposeBoundaryTests`); no new synchronizable keychain row
(`KeyCustodyBoundaryTests` unchanged); known-answer vectors for entropy → words → key → HPKE in a
new `RecoveryCodeGoldenTests`; the BIP39 vectors from the BIP's test set for the encoding.

**S3 wall:** the word list, derivation and HPKE live in the app/`FernletCrypto` side next to
`SealedBackupEscrowKey`. `CloudKitSync` only gets the opaque `RecoveryEscrowRecord` type (like
`SealedBackupRecord`). `AIProviders` never sees any of it. No sealed `Private*` store is touched.
**No-tracking wall:** no new network destination (CloudKit private DB is already allowlisted).
**Export compliance:** standard CryptoKit algorithms only; the export memo needs one line.
**Word list licence:** the BIP39 English list ships in the bitcoin/bips repo; confirm its licence
before bundling and add an Acknowledgments line.

### UI (copy to be drafted in the PR, not here)

- Privacy & data → Encrypted backups → **Recovery code** row: "Not set up" / "Made on 15 Nov".
- Offered once (not nagged) when a sealed backup is first turned on (call R5).
- Making one: explain → passcode/Face ID → show 12 numbered words → type 3 of them back (R6) →
  done. "Save to Files"/copy are not offered (paper or a password manager is the point; copy
  would put it on the clipboard).
- The existing "Couldn't restore … on this phone yet" banner gains "Use a recovery code".

### Tests (targeted suites)

New `RecoveryCodeEncodingTests` (BIP39 vectors, checksum, 4-letter prefixes, case/spacing),
`RecoveryCodeGoldenTests`, `RecoveryEscrowTests` (seal on make, seal-on-new-escrow-key without
the code, recover, regenerate revokes, check-my-code accepts the current code and refuses an
old or mistyped one without changing anything, duress hides); extend `SealedBackupRestoreOutcomeTests`,
`IdentityServiceEscrowTests`, `CloudKitDataServiceTests` (delete covers the new type),
`CloudKitSchemaDeployTests`, `CryptographicPurposeBoundaryTests`, `KeyCustodyBoundaryTests`,
`S3BoundaryTests`, `PrivacyDataSettingsUITests`.

### Phone checks owed

(1) Make a code on phone A with a backup on. (2) On phone B (or A after erase) with iCloud
Keychain **off**, install, see the restore banner, enter the code, backups restore. (3) A wrong
word is caught before anything is tried. (4) Make a new code; the old one is refused.
(5) VoiceOver reads the words one by one with their numbers. (6) "Check my code" accepts the
current code and refuses the old one.

---

## Part 3: Memory controls (PR G9-3)

### What happens today

- **Core memory** = `MemoryNote` (`FernletDomainModel/WellbeingModels.swift:912`: id, free-string
  category, text, sourceDate). Its only writer is journal capture
  (`FernletStore.rememberJournalEntry`, `FernletStore.swift:4639`): an emotion-only note per
  journal entry ≥ 20 characters, plus an optional on-device summary when AI is on. Capped at 300
  (oldest dropped). It rides the aggregate blob: **not sealed, synced to iCloud when sync is on,
  never fed to any AI prompt.**
- Settings → AI & data sources → Core memory lists, edits and deletes notes, and already has a
  keyword "forget …" field (`SettingsSheet.swift:793-815`).
- **Tier 2** = `TierTwoMemoryRecord`s from the deterministic `TierTwoMemoryEngine` (goal gaps,
  consistency, journal avoidance, workout-mood, travel days). Device-local file, never synced,
  **rebuilt after every save**. Only shown in the DEBUG panel; read by the companion thought.
- There is no `userEdited`, no wipe-all Core, no Tier-2 wipe short of Delete Everything, no
  extraction switch (only the global AI status, and emotion-only notes are made even with AI off),
  and **no Sensitive memory anywhere in code** (spec §8 only).
- There is no AI chat, so "natural language" here means the forget field in Settings (and
  optionally Siri).

### Design

**`userEdited`** — `MemoryNote` gains `userEdited: Bool` (`decodeIfPresent`, default false). Set
by any edit in the editor. Effects: the journal summarizer never fills it (it already only fills
empty text), and the 300 cap drops non-edited notes first.

**Wipe all Core** — a "Delete all memories" row at the bottom of the Core memory page, through
`DestructiveConfirmation` ("Deletes all N memories on this phone and in iCloud. This can't be
undone."). Audit-logged. With M1 = A it writes tombstones so another phone can't re-add them.

**Extraction switch (M2 = A)** — one switch on the Core memory page: "Let Fernlet remember" (not
"…from my journal": patterns also come from workouts and goals). Off stops journal capture (emotion-only and summaries) **and** Tier-2 derivation.
Turning it off asks whether to also delete what is already remembered (two buttons: "Turn off
and delete", "Turn off, keep them"). Stored in settings (synced with the blob, so both phones
agree).

**Tier-2 wipe (M3 = A)** — "Forget patterns" on the same page, explaining in one line what
patterns are. It purges `TierTwoMemoryStore` and records a device-local "learn from" date of
today, so the engine only reads days after it. Without the date the next save would rebuild the
same patterns from history, making the wipe meaningless. The date gets a wipe-boundary row and is
cleared by Delete Everything.

**Natural-language forget (M4 = A)** — the Settings field accepts a sentence ("forget the stuff
about my sister", "forget everything from August"). When on-device AI is ready, a new Foundation
stage (pattern of `FoundationJournalSummary`) turns **only the sentence** into a query
`{keywords, categories, dateRange}`; it never sees any memory. Fernlet matches memories itself
and shows a checklist preview with a warm one-line confirmation; nothing is deleted until the
person taps "Forget these". When AI is off, the current keyword match is used with the same
preview. Two limits: most memories are emotion-only (a feeling token and a date, no words), so
word matching only reaches the ones with an AI summary; and the Foundation model never runs in
the simulator, so the sentence path is phone-test only. **M4 = B** is the no-AI alternative:
search words plus a date range and feeling chips filling the same checklist, identical with AI on
or off and fully testable, but no typed sentence. Keeping memories out of the model is what lets this reach private memories without
breaking the S3 wall (the spec's `aiNaturalLanguageForget(command, core, sensitive)` would pass
sealed text to `AIProviders`; this plan does not).

**Natural-language edit (M5 = A)** — not built. Inline Edit already exists and sets
`userEdited`.

**Private memories (M6 = A)** — the "Sensitive-category UI", sized to what exists: a memory's
editor gets "Keep private". That moves it out of the synced blob into a new sealed repository in
`PrivateMemoryStore` (ColumnCrypto purpose `fernlet.private-memory.v1`, same lock content key as
the journal). Private memories never sync, are excluded from the photo wall and Home, and are
listed on the Core memory page only after the lock is open ("3 private memories — unlock to
see"). Wipe-all and forget reach them (inside the sealed module, after unlock). Private memories
are not in the sealed backup in this PR, so they are lost with the phone; the option text on the
review page says so. The spec's
AI-extracted, never-browsable Sensitive tier stays deferred (RemainingWork §8).

**Core memories leave the blob (M1 = A)** — today a forget on phone A can be undone when phone B
writes the whole blob back. With G9-1's machinery, Core memories move to a `MemoryRecord` row type
with the same soft-delete tombstone as custom items. One-time migration: on first launch the blob's
`memories` are copied into rows, and the blob field is emptied only after the rows save. An old
build still reads the blob, which is now empty (same "update every phone" note as S5).

**Or Core memories stay on this phone (M1 = C)** — memories move out of the blob into a
device-local file (the `TierTwoMemoryStore` pattern), with the same one-time copy-then-empty
migration. They stop syncing: a forget always sticks, journal-derived notes (including on-device
summaries) no longer reach iCloud, no new CloudKit record type is needed, and G9-3 no longer
depends on G9-1. The cost is that memories do not follow the person to a second or new phone.
The new file gets a wipe-boundary row and a `DataExportBuilder` entry.

### Schema and migration

- `MemoryNote.userEdited` (payload, additive).
- Settings: `memoryExtractionEnabled` (default true; blob, additive).
- Device-local: `tierTwoLearnFrom` date (wipe-boundary row).
- M1 = A: new Core Data entity `MemoryRecord` (`idString`, `payloadData`, `updatedAt`); CloudKit
  production schema deploy (owner).
- M6 = A: new sealed table in `PrivateStoreCore`'s model + purpose registry entry; the sealed
  backup v2 envelope does **not** include private memories in this PR (a follow-up if wanted).

### Tests (targeted suites)

New `MemoryControlsTests` (userEdited survives summarizer + cap, wipe-all, switch off stops both
writers, Tier-2 learn-from date), `MemoryForgetQueryTests` (sentence → query, keyword fallback,
preview never deletes on its own), `PrivateMemoryRepositoryTests`, `MemoryRowMigrationTests`;
extend `JournalMemoryCaptureTests`, `TierTwoDeviceLocalTests`, `DeleteAllDataTests`,
`AIContextPayloadTests`, `S3BoundaryTests`, `PersistedSurfaceWipeBoundaryTests`,
`LocalizationBoundaryTests`, `SettingsAppearanceUITests`.

### Phone checks owed

Forget by sentence with AI on and off; switch off then write a journal entry (no new memory);
Forget patterns then save a day (no patterns come back); Keep private then lock (row hidden);
forget on A stays forgotten on B; VoiceOver on the preview checklist.

---

## Walls and housekeeping (every PR)

`Scripts/doc-coverage-scan.py` (zero undocumented types), `Scripts/power-of-10-scan.py`, the
accessibility scan, `Scripts/spm-wall-check.sh`, `Scripts/sync-string-catalogs.sh --check`
(new strings get es + es-MX drafts marked needs_review). Update the DocC landing pages of
`CloudKitSync`, `StoreCore`, `FernletCrypto`, `PrivateMemoryStore`; `Docs/StoreRepositoryFunctionIndex.md`
(it has no sync section today; G9-1 adds one); `Docs/PrivacyWipeCoverage.md`; the Privacy Policy
gets a recovery-code sentence (G9-2) and a private-memories sentence (G9-3).
All builds and tests run under `lockf -k ~/Library/Caches/heavy-job.lock`, targeted
`-only-testing` suites only.

## Follow-ups outside G9

- Split the aggregate `FernletDatabaseRecord` blob (settings etc.) into rows or per-field merge.
- Saved recipes: soft delete like custom items (only if S3 = B; S3 = A does it in G9-1).
- Sealed backup v2 for private memories.
- The spec's AI-extracted Sensitive tier and its Memory Agent use.

## Owner calls

| Id | Question | Recommended |
| --- | --- | --- |
| S1 | Day merge model | A: one row per device per day + entry stamps + tombstones |
| S2 | Reading of the 08-21 decision | A: tombstones for everyday deletes; Delete Everything stays disclose-only |
| S3 | Clothing design and saved recipe deletes | A: soft delete (synced `deletedAt`) for both |
| S4 | How long tombstones are kept | C: forever (no pruning code) |
| S5 | Old builds on a second phone | C: update every phone first, plus a format number on every synced row |
| R1 | What a recovery code recovers | A: backups only, never a passcode |
| R3 | Length | A: 12 words (128-bit) |
| R4 | Word list language | A: English BIP39 list for every app language |
| R5 | When it is offered | A: optional; offered once when a backup is turned on, plus a Privacy & data row |
| R6 | Check they wrote it down | A: type 3 words back |
| R7 | Test a code later | A: "Check my code" on the Recovery code row |
| M1 | Where Core memories live | A: own synced rows with soft delete (owner: memories should follow to another device) |
| M2 | Extraction switch | A: one switch, "Let Fernlet remember", for journal memories and patterns |
| M3 | Tier-2 wipe | A: wipe and learn only from days after today |
| M4 | Natural-language forget | A: on-device AI reads only the sentence; checklist preview; keyword fallback (B: no-AI filters) |
| M5 | Natural-language edit | A: not built; inline Edit stays |
| M6 | Sensitive category | A: "Keep private" moves a memory into the sealed store (not in the backup yet) |

R2 (construction) was an owner call until the 2026-11-15 review; it is now settled as design:
a recovery key pair, escrow keys sealed to it with HPKE. Already answered on the page: R3–R6, all A.
