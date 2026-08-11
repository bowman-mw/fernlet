# Fernlet — App Privacy "Nutrition Label" Spec (App Store Connect)

> Draft for the App Store Connect **App Privacy** questionnaire. Reflects the shipped architecture as
> of 2026-07-11. Re-review with legal before submission, and re-review whenever a data type gains a new
> egress path (esp. if any social/friend type ever syncs to CloudKit — today none do).

## Summary answer

**Data used to track you:** None. Fernlet has no third-party advertising, no analytics SDKs, no
cross-app/cross-site tracking, and no tracking domains.

**Data collected by the developer:** Effectively none in the App Store sense. Fernlet operates no
backend. Health/journal/etc. data is either on-device or in the user's **own** iCloud private database
(Apple's infrastructure, tied to the user's Apple ID) — the developer never receives or can read it.
Where the questionnaire forces a "collected/linked" answer because CloudKit private-DB sync associates
data with the user's Apple ID, classify those types as **Data Linked to You**, **not used for tracking**.

## Per-type declarations

| Data type | Collected? | Linked to user? | Used for tracking? | Purpose | Notes |
|---|---|---|---|---|---|
| Health & Fitness (meals, workouts, sleep, hydration, hygiene, wellbeing score) | Only via user's own iCloud (opt-in) | Yes (Apple ID, if sync on) | No | App Functionality | On-device by default; syncs only to the user's private CloudKit DB. Not received by developer. |
| User Content — journal entries | Only via user's own iCloud (opt-in) | Yes (if sync on) | No | App Functionality | Sealed/encrypted on device; developer cannot read. |
| Sensitive info — period/cycle, sensitive memories, intimate notes | Only if user opts into encrypted backup | Ciphertext only | No | App Functionality | Client-side AES-256-GCM before upload; Apple sees only ciphertext. Off by default. |
| Photos | Only if user opts into the encrypted photo backup | Ciphertext only (Apple ID, if that backup is on) | No | App Functionality | Encrypted in app container; by default only in the standard device backup. The opt-in "Sealed backup for your photos" (own meal/recipe/progress photos ONLY — never friends' shared photos) uploads client-side AES-256-GCM ciphertext to the user's own private CloudKit DB. Off by default; never received by the developer; user-initiated Save-to-Photos export only. |
| Identifiers — public key | Peer-to-peer only | Yes (device identity) | No | App Functionality | Ed25519 public key exchanged in person with friends; no server. |
| Coarse location | Optional, on-device | No | No | App Functionality | WeatherKit prompts + optional activity tagging; never tracked over time, never sent to developer. |
| Contacts / Contact info / Browsing / Purchases / Financial / etc. | No | — | — | — | Not collected. |

## Required-reason API declarations (`PrivacyInfo.xcprivacy`)

Already present on the app, share-extension, and widgets targets. Declared reasons:
- `NSPrivacyAccessedAPICategoryUserDefaults` — reason **CA92.1** (app-group/app-only settings).
- `NSPrivacyAccessedAPICategoryFileTimestamp` — reason **C617.1**.
- `NSPrivacyAccessedAPICategorySystemBootTime` — reason **35F9.1** (monotonic anti-tamper timing for
  the app lock and the moderation ban clock).
- `NSPrivacyTracking` = `false`; `NSPrivacyTrackingDomains` empty; `NSPrivacyCollectedDataTypes` empty
  (developer collects nothing server-side — keep empty unless a type starts syncing to a developer
  backend, which Fernlet has none of).

## Encryption

`ITSAppUsesNonExemptEncryption = false` (Info.plist). Fernlet uses only exempt encryption (standard
Apple crypto for data protection + the sealed-backup/proximity primitives), so no export-compliance
documentation upload is required.

## Post-S2 note (carried from spec §18)

Journal text is sealed and excluded from plaintext CloudKit sync. The "User Content (journal —
synced to CloudKit)" wording above should be reviewed against the actual sealed-store behavior with
legal before shipping; the sealed categories may be argued as not "collected" at all.
