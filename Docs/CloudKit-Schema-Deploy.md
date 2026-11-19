# CloudKit Schema Deploy (STEP 0c)

How to push the Core Data model to CloudKit's server-side schema. This is a **manual,
developer-run ritual** — there was no process before this doc (`grep -rn initializeCloudKitSchema`
returned zero hits). Do it whenever a Core Data model change adds record types or attributes that
must exist in CloudKit, **before the build that writes them ships**.

The synced store is `NSPersistentCloudKitContainer` against **`iCloud.MBO.Fernlet`**
(`FernletKit/Sources/CloudKitSync/Persistence.swift`). The store's lightweight migration
(`shouldMigrateStoreAutomatically` / `shouldInferMappingModelAutomatically`) only covers the
**on-device SQLite** — it does **not** create or update the **server-side record types**. That is
what this ritual does.

## The expected schema, and how to check a container against it

**`Docs/CloudKit-Expected-Schema.json` is the list of record.** It holds every record type and
field the app at that commit writes, each field's type, and every index a query or delete sweep
needs: the `CD_` types of the mirror (with their `CD_entityName` field and the `_ckAsset` twin of
every String and Binary Data attribute) and the hand-built `CKRecord` types. The tables further down
this page are the history and the reasons; the JSON file is what a deploy is checked against.

- **It cannot drift from the code.** `CloudKitExpectedSchemaTests` reads the Core Data model, the
  `CKRecord`s `CloudKitDataService` and `HeartDropCloudTransport` build, and the delete sweep's type
  list, and fails when any of them has a type or field the file lacks (or the file has one the code
  lacks).
- **Any PR that adds a record type or field updates `Docs/CloudKit-Expected-Schema.json` in the same
  commit**, adds a row to the pending table below, and says in its description that a deploy is
  owed. The test above is red until the file is updated; the row and the deploy are the part only a
  person can do.
- **Check a container** with `Scripts/cloudkit-schema-check.py`, which compares the file with a
  schema exported by `cktool` and prints what is missing, what has the wrong type and which indexes
  are absent. It only reads two files; it never talks to CloudKit.

Export needs a CloudKit **management token**: [CloudKit Console](https://icloud.developer.apple.com/)
▸ your account menu ▸ **Settings** ▸ **Tokens** ▸ create a management token, then save it to the
keychain once (the command prompts for the token; paste it there, not on the command line):

```bash
xcrun cktool save-token --type management
```

Export Production's schema and check it (team `3RTUPF8FFH`, container `iCloud.MBO.Fernlet`; use
`--environment development` to check Development the same way):

```bash
xcrun cktool export-schema --team-id 3RTUPF8FFH --container-id iCloud.MBO.Fernlet --environment production --output-file ~/Downloads/fernlet-production.ckdb
```

```bash
Scripts/cloudkit-schema-check.py ~/Downloads/fernlet-production.ckdb
```

`RESULT: nothing missing` (exit status 0) means Production has everything this commit writes. Each
other line names one gap:

| Line | What to do |
| --- | --- |
| `MISSING TYPE` / `MISSING FIELD` on a `CD_` type | Run the ritual below (it puts the whole model in Development), then promote. |
| `MISSING TYPE` / `MISSING FIELD` on a hand-built type | Make Development have it (a Debug build doing that save once: turn on the photo backup, make a recovery code, send a heart drop; or add it by hand in the Console under Development ▸ Schema ▸ Record Types), then promote. |
| `MISSING INDEX … recordName needs QUERYABLE` | Console ▸ Development ▸ Schema ▸ **Indexes** ▸ the record type ▸ **Add Basic Index** ▸ field `recordName`, type **Queryable**, save, then promote. `initializeCloudKitSchema` never adds this index, so every new swept type needs it by hand. |
| `MISSING INDEX` on another field | The same, for the named field and index type. |
| `WRONG TYPE` | Stop. A deployed field cannot be retyped; the code must change to a new field name. |

**The quick way to close every gap at once** is to let the script write the fix and import it into
Development, instead of clicking each field and index in the Console. Export **Development**, merge
what is missing into it (nothing is removed or retyped), validate, import, then promote:

```bash
xcrun cktool export-schema --team-id 3RTUPF8FFH --container-id iCloud.MBO.Fernlet --environment development --output-file ~/Downloads/fernlet-development.ckdb
```

```bash
Scripts/cloudkit-schema-check.py ~/Downloads/fernlet-development.ckdb --write-merged ~/Downloads/fernlet-merged.ckdb
```

```bash
xcrun cktool validate-schema --team-id 3RTUPF8FFH --container-id iCloud.MBO.Fernlet --environment development --file ~/Downloads/fernlet-merged.ckdb
```

```bash
xcrun cktool import-schema --team-id 3RTUPF8FFH --container-id iCloud.MBO.Fernlet --environment development --file ~/Downloads/fernlet-merged.ckdb
```

Then Console ▸ **Deploy Schema Changes** ▸ read the diff (it should list only additions) ▸ Deploy,
and export Production and run the check again. `import-schema` only ever writes Development; the
merge starts from Development's own export so that nothing Development has is dropped.

Without a token, the same check by eye: Console ▸ `iCloud.MBO.Fernlet` ▸ **Production** ▸ Schema ▸
**Record Types**, and for each type in the JSON file confirm the type exists and lists every field
with the type shown; then Schema ▸ **Indexes**, and for each type whose `recordNameQueryable` is
true confirm a `recordName` ▸ `QUERYABLE` row.

## The mechanism

`PersistenceController` has a **DEBUG-only, launch-argument-gated** path that calls
`NSPersistentCloudKitContainer.initializeCloudKitSchema(options:)`:

- Argument: **`INITIALIZE_CLOUDKIT_SCHEMA`** (constant: `CloudKitSchemaDeploy.launchArgument`).
- The whole path is wrapped in `#if DEBUG` (`Persistence.swift`,
  `initializeCloudKitSchemaIfRequested`). It is compiled out of Release builds — **it cannot be
  triggered in a shipping binary**.
- It runs against a throwaway scratch store with CloudKit options forced on, so it works even
  though `PersistenceController.shared` disables iCloud sync at cold launch, and it never touches
  the real store. The push always targets the **Development** environment.
- Result is logged loudly: `cloudkit.schema.initialize.{started,succeeded,failed,skipped}` via
  `FernletAuditLog`, plus `print` lines with ✅ / ❌ in the Xcode console.

## The ritual

1. **Deploy to Development.**
   - Sign the target simulator into an iCloud account (Settings ▸ sign in). The account only needs
     to exist; no Fernlet data is required.
   - Confirm the scheme's CloudKit environment is **Development** (the default for a Debug build in
     the simulator). `Fernlet.entitlements` carries no
     `com.apple.developer.icloud-container-environment` key, so the signing decides: a TestFlight or
     App Store build uses Production and a run from Xcode uses Development. (The World build pinned it
     to `Production` from 2026-10-25 until it readied for main on 2026-10-26;
     `WorldIdentityBoundaryTests` now pins the key absent.) `initializeCloudKitSchema` cannot write
     Production, and the Simulator works only with Development.
   - Launch the app with the argument. Either:
     - Xcode ▸ Edit Scheme ▸ Run ▸ Arguments ▸ *Arguments Passed On Launch* ▸ add
       `INITIALIZE_CLOUDKIT_SCHEMA`, then Run; **or**
     - `xcrun simctl launch booted MBO.Fernlet INITIALIZE_CLOUDKIT_SCHEMA`.
   - Watch the console for `✅ CloudKit schema initialized in DEVELOPMENT` (audit event
     `cloudkit.schema.initialize.succeeded`). A `❌` / `cloudkit.schema.initialize.failed` line
     means it did not deploy — read the error (most often: not signed into iCloud, or the scheme is
     pointed at Production).
   - **Remove the launch argument afterward** so ordinary runs don't re-push.

2. **Verify in the CloudKit console.**
   - Open the [CloudKit Console](https://icloud.developer.apple.com/) ▸ container
     **`iCloud.MBO.Fernlet`** ▸ **Development** ▸ Schema ▸ Record Types.
   - Confirm the expected record types and every new attribute are present (Core Data mirrors each
     entity as a `CD_<EntityName>` record type; new attributes appear as `CD_<attributeName>`
     fields). If an expected attribute is missing, the deploy didn't include it — fix the model and
     redo step 1. Or export Development and run `Scripts/cloudkit-schema-check.py` on it (above).
   - Add the `recordName` ▸ Queryable index to any new record type the delete sweep covers
     (Schema ▸ Indexes); the schema initialisation does not.

3. **Promote Development → Production.**
   - In the console: **Deploy Schema Changes** ▸ review the diff ▸ **Deploy** to Production.
   - **This is an owner action in the CloudKit console UI. Code cannot do it** —
     `initializeCloudKitSchema` only ever writes the Development schema; there is no API to promote
     to Production.
   - Then export Production and run the check (above). The deploy is done when it prints
     `RESULT: nothing missing`.

## Rules

- **One batched deploy.** Every Core Data model change in the AI-feature plan
  (`Docs/AI-Feature-Expansion-2026-07-23.md`) is **batched into a single deploy**. Land the model
  changes, deploy once, verify once, promote once — do not deploy per-change.
- **Additive only.** A deployed record type / attribute is **permanent**: CloudKit's mirrored
  schema **cannot remove or retype a deployed attribute**. Only ever **add** record types and
  attributes. Never remove or rename a deployed one. (This is why STEP 0's `SavedRecipeRecord`
  migration must *add* `payloadData` alongside the legacy typed columns and read both shapes
  indefinitely, rather than replace them — see `AI-Feature-Expansion-2026-07-23.md` §9.1.)
- **Deploy precedes the writing build.** The new record type / attribute must exist in the
  **Production** CloudKit schema **before** any shipped build writes it, or paired devices sync
  records the server schema doesn't recognize.
- **The expected schema moves with the code.** A PR that adds a record type or field updates
  `Docs/CloudKit-Expected-Schema.json` in the same commit (`CloudKitExpectedSchemaTests` is red until
  it does) and adds a pending row below. Before the build ships, Production is checked with
  `Scripts/cloudkit-schema-check.py`, not assumed.
- **Modifying the walled `CloudKitSync` module?** Run `Scripts/spm-wall-check.sh` — every change to
  `Persistence.swift` (and this deploy path) touches a walled module and must pass the wall check.

## Checklist for STEP 0 (`SavedRecipeRecord` → `payloadData`)

STEP 0 adds a `payloadData` attribute to the `SavedRecipeRecord` entity
(`Persistence.swift`, additive per §9.1). Before that build ships:

- [ ] Land the additive `payloadData` model change (attribute added, legacy columns kept,
      readers prefer `payloadData` and fall back to the legacy columns).
- [ ] Run this ritual: deploy to Development, verify the new `CD_payloadData` field on
      `CD_SavedRecipeRecord` in the console, promote to Production.
- [ ] Only then ship the build that writes `payloadData`.
- [ ] `Scripts/spm-wall-check.sh` passes for the `CloudKitSync` change.

## Schema changes pending promotion to Production

Development auto-creates new record types and fields on first save; **Production does not** — each
must be promoted in the CloudKit console before the build that writes it ships. This table is the
history and the reasons; `Docs/CloudKit-Expected-Schema.json` is the complete list, and
`Scripts/cloudkit-schema-check.py` (above) is how a row is confirmed. A schema deploy was made
around 2026-11-19 (owner: "not sure if it included everything"), so the four PENDING rows below stay
PENDING until that check prints `nothing missing` for Production.

**Production as exported on 2026-11-19** (owner's export, checked with the script; 24 findings).
Development's export that day was the same schema, so the deploy carried everything Development had,
and every gap below is missing from Development too:

- **Present and complete:** `SealedBackupRecord`, `RecoveryEscrowRecord` (both with `recordName`
  queryable), and the field `CD_DayRecord.CD_deviceKey`.
- **Record types missing:** `CD_MemoryRecord`, `CD_CustomItemRecord` (never in Production, so a
  clothing design cannot have reached iCloud from a TestFlight build, and by the atomic-zone rule
  below a phone holding one would have had its other exports held back too; inferred from the
  schema, not yet seen on a phone), `SealedPhotoRecord`, `HeartDrop`.
- **`recordName` not queryable** on any of the five `CD_` types that exist, so existing-data
  detection and the "delete everything" sweep cannot list them in Production.
- **Asset twins missing** on every `CD_` type except `CD_FernletDatabaseRecord.CD_payloadData_ckAsset`:
  the schema was grown by saves, never by `initializeCloudKitSchema`. A value over 1 MB in any of
  those fields would be refused.

Until the check prints `nothing missing`, treat every row below marked PENDING as still pending,
plus the three bullets above.

What a missing `CD_` row costs: the mirror exports a zone atomically, so one refused field holds
back every day entry, recipe, coin and memory with it. Since 2026-11-19 the app observes the
mirror's events and Privacy & Data says iCloud did not accept the changes
(`MirrorSyncHealth`, audit event `cloudkit.mirror.failed`); before that it was silent.

| Record type | Field | Added | Why |
| --- | --- | --- | --- |
| `HeartDrop` | `tag` (queryable), `payload` (bytes) | 2026-07-25 | Offline away-hearts dead-drop. |
| `SealedBackupRecord` | `generation` (Int64) | 2026-08-09 | **Promoted to Production 2026-08-11 (owner-confirmed).** Sealed-backup rollback defense (code review finding 14). It is bound into the GCM AAD and required on decode, so **a Production container without this field cannot restore any backup at all** — promote it before shipping. |
| `SealedBackupRecord` | `formatVersion` (Int64), `keySalt` (bytes) | 2026-08-10 | **Promoted to Production 2026-08-11 (owner-confirmed).** Record format v2 — the per-generation escrow HKDF salt (`Verifiability.md` §6.4). Every new write stamps `formatVersion = 2` plus a 32-byte `keySalt`; **the salt is the only way to re-derive that generation's key, so a Production container that silently drops it makes those backups permanently unopenable.** Both fields must exist in Production **before** the build that writes v2 ships. Reads are unaffected either way: a record lacking both fields decodes as v1. |
| `SealedPhotoRecord` (**new record type**) | `corpus` (String), `slot` (String), `signingPublicKey` (bytes), `keyAgreementPublicKey` (bytes), `nonce` (bytes), `tag` (bytes), `updatedAt` (Date), `generation` (Int64), `formatVersion` (Int64), `keySalt` (bytes), `encryptedBlob` (CKAsset) | 2026-08-11 | **PENDING — owner action.** The own-photo escrow route (security-hardening Phase 5, step 5b): one sealed record per photo id plus a sealed per-corpus manifest, names `sealed-photo.<corpus>.<photoId|manifest>`. A hand-rolled `CKRecord` type like `SealedBackupRecord`, so Development auto-creates it on the first Debug save but **Production does not**. The teardown path enumerates record IDs by type, so the type must be **queryable** in Production or "delete everything" cannot find the photo records it promises to remove. Every field is required on decode (`decodeSealedPhoto` fails closed), so a partially-promoted type makes uploaded photos unrestorable. Promote before shipping a build with the photo backup switched on. |
| `CD_DayRecord` | `CD_deviceKey` (String), with its asset twin `CD_deviceKey_ckAsset` (Asset) | 2026-11-15 | **PENDING — owner action (G9-1, PR #172).** The writing install's random device key; every day row a build since #172 writes carries it, so without it Production refuses **every day export**, and the batch with it. A mirrored field: it reaches Development only through the ritual above (`INITIALIZE_CLOUDKIT_SCHEMA`), not through an ordinary save. Missing from this table until the 2026-11-18 release review (finding F2). |
| `CD_MemoryRecord` (**new record type**) | `CD_entityName` (String), `CD_idString` (String), `CD_idString_ckAsset` (Asset), `CD_payloadData` (Bytes), `CD_payloadData_ckAsset` (Asset), `CD_updatedAt` (Date) | 2026-11-16 | **PENDING — owner action (G9-3, PR #186).** One Core memory per row, plus a tombstone row per forgotten one. On first launch after the update memories move out of the synced blob into these rows and the blob is saved without them, so **a Production container without this type holds no memories at all** once the blob export lands, and a new phone restores none. Also swept by "delete everything", so `recordName` must be **queryable** (added by hand, see above). Missing from this table until the 2026-11-18 release review (finding F2). |
| `RecoveryEscrowRecord` (**new record type**) | `recoveryPublicKey` (bytes), `escrowPublicKeyHash` (bytes), `encapsulatedKey` (bytes), `ciphertext` (bytes), `codeMadeAt` (Date), `formatVersion` (Int64) | 2026-11-15 | **PENDING — owner action (G9-2).** The recovery code's sealed escrow keys: one record per escrow key, each the escrow private key sealed with HPKE to the recovery code's public key, named `recovery-escrow.<sha256hex(recoveryPublicKey)>.<hex(escrowPublicKeyHash)>`. A hand-rolled `CKRecord` type like `SealedPhotoRecord`, so Development creates it on the first Debug save and **Production does not**. Recovery, "Check my code", "Make a new code" (which deletes the old code's records by name) and "delete everything" all enumerate record IDs by type, so the type must be **queryable** (`recordName`) in Production. Every field is required on decode (`decodeRecoveryEscrow` skips a record missing one), so a partially promoted type makes a code that opens nothing. Promote before shipping the build with recovery codes. |

The 2026-08-11 deploy was batched (the console promotes the whole Development diff), so the
`HeartDrop` fields above may have ridden along **if** they existed in Development at deploy time —
verify in the console (Production ▸ Schema ▸ Record Types ▸ `HeartDrop`) before shipping a
dead-drop-writing build; do not assume.

**Owner action, not a code step.** `SealedBackupRecord` is a hand-rolled `CKRecord` type (not a Core
Data mirrored `CD_*` entity), so the Development schema picks the two v2 fields up automatically on the
first save from a Debug build — but **Production does not**, and no code path can promote it:
`initializeCloudKitSchema` only ever writes Development, and there is no API for the Development →
Production deploy. The owner must open the [CloudKit Console](https://icloud.developer.apple.com/) ▸
`iCloud.MBO.Fernlet` ▸ **Deploy Schema Changes** ▸ review ▸ **Deploy to Production**, and confirm
`formatVersion` and `keySalt` are present on `SealedBackupRecord` there, **before** shipping a build
that writes record format v2.

**Do not ship an intermediate build between the two.** A CloudKit save is a per-**field** update, not a
record replace: keys the saved record never sets are left untouched server-side (clearing one requires
explicitly assigning nil on the record being saved). So a build that writes `generation` but not
`formatVersion`/`keySalt` — i.e. any build from before v2 — rewrites the ciphertext of a v2 record while
the server keeps the previous write's `formatVersion = 2` and 32-byte salt, producing a record whose
label no longer matches its bytes. `SealedBackupCrypto.open` recovers from that (it retries the v1
derivation when a v2-labelled record fails to authenticate, covered by
`CloudKitDataServiceTests.downlevelWriteLeavesStaleV2MetadataAndTheBackupStillOpens`), but the safe
rollout is still to go straight from the current shipped build to a v2 build. Note also that a v2 record
is not readable by a stale build at all — no forward compatibility is promised or attempted.
