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
     the simulator).
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
     redo step 1.

3. **Promote Development → Production.**
   - In the console: **Deploy Schema Changes** ▸ review the diff ▸ **Deploy** to Production.
   - **This is an owner action in the CloudKit console UI. Code cannot do it** —
     `initializeCloudKitSchema` only ever writes the Development schema; there is no API to promote
     to Production.

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
must be promoted in the CloudKit console before the build that writes it ships.

| Record type | Field | Added | Why |
| --- | --- | --- | --- |
| `HeartDrop` | `tag` (queryable), `payload` (bytes) | 2026-07-25 | Offline away-hearts dead-drop. |
| `SealedBackupRecord` | `generation` (Int64) | 2026-08-09 | Sealed-backup rollback defense (code review finding 14). It is bound into the GCM AAD and required on decode, so **a Production container without this field cannot restore any backup at all** — promote it before shipping. |
