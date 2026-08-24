# Fernlet — App Privacy "Nutrition Label" Spec (App Store Connect)

> Draft for the App Store Connect **App Privacy** questionnaire. Reflects the shipped architecture as
> of 2026-08-12 (post 2026-08-10/11 security-hardening round: P3 journal/intimacy escrow payloads,
> P4 hard SE-binding, P5 photo escrow backup, P6 default device-backup exclusion). Re-review with
> legal before submission, and re-review whenever a data type gains a new
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
| User Content — journal entries | Only if user opts into the encrypted sealed backup | Ciphertext only | No | App Functionality | Sealed/encrypted on device; never in plaintext CloudKit sync (only the entry structure/days ride core-data sync). Since P3 (2026-08-11), journal text leaves the device only as client-side AES-256-GCM ciphertext via the opt-in encrypted backup — same classification as the Sensitive-info row. Developer cannot read. |
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

`ITSAppUsesNonExemptEncryption = NO` (set from the build settings —
`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption` in both configurations of the `Fernlet` target, not the
`Info.plist` file). This is the App Store Connect result recorded on 2026-08-23: for Fernlet's current
distribution, with France excluded and no proprietary/non-standard algorithms declared, Apple requires
no encryption documentation and provides no compliance code. `NO` means exempt from Apple's
documentation requirement; it does **not** mean Fernlet has no encryption.

Fernlet still ships CryptoKit-based confidentiality encryption and CryptoSwift's third-party scrypt
implementation. Its separate EAR classification remains mass-market **5D992.c**, self-classified under
License Exception ENC §740.17(b)(1). Re-run the App Store Connect declaration before adding France as a
release country or introducing proprietary/unpublished cryptography; France may require an ANSSI
declaration.

Revised 2026-08-19: there is **no recurring BIS filing**. §740.17(e)(3) was rewritten in 2021 to cover
only encryption components and "executable software", which a finished consumer app is not — at most
one Supplement No. 8 report, once. And because Fernlet is free and its source is public, the shipped
app can fall **outside the EAR** altogether once self-classification is done.

Full determination, the App Store Connect questionnaire answers, the crypto inventory, and the
filing checklist: [Export-Compliance-Encryption.md](Export-Compliance-Encryption.md).

## Post-S2 note (carried from spec §18) — resolved 2026-08-12

Journal text is sealed and excluded from plaintext CloudKit sync. The open question this note used
to carry is settled: since P3 (4ed7437, 2026-08-11) journal narratives and intimacy logs are
first-class opt-in encrypted-backup payloads — client-side AES-256-GCM ciphertext only, never
plaintext sync — and the journal row above now declares "Only if user opts into the encrypted
sealed backup / Ciphertext only", matching the Sensitive-info row. The sealed categories may still
be argued as not "collected" at all; confirm the final questionnaire answers with legal before
submission.
