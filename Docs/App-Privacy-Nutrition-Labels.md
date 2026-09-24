# Fernlet — App Privacy "Nutrition Label" Spec (App Store Connect)

> Draft for the App Store Connect **App Privacy** questionnaire. Reflects the shipped architecture as
> of 2026-09-24: the 2026-08-10/11 security-hardening round (P3 journal/intimacy escrow payloads, P4
> hard SE-binding, P5 photo escrow backup, P6 default device-backup exclusion) and the 2026-09-23
> owner-decisions round (HealthKit values off iCloud, Tier-2 memories device-only, Core memory without
> journal text, the iMessage app, the Open Food Facts barcode lookup). Re-review with legal before
> submission, and re-review whenever a data type gains a new egress path.
>
> **Social data does sync to CloudKit.** This header used to say no social/friend type did — false for
> as long as the roster has lived in the aggregate blob. When iCloud sync is on, the friend roster and
> an in-person session log ride the user's own private CloudKit database, unencrypted beyond Apple's own
> protection (owner decision 2026-09-23: acceptable there, not end-to-end encrypted); see the Contacts
> row. And the opt-in away-hearts sit, sealed, in the developer's CloudKit **public** database; see the
> away-hearts row.

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
| Health & Fitness (meals, workouts logged in Fernlet, sleep the user logs, hydration, hygiene, the body profile the user types, wellbeing score) | Only via user's own iCloud (opt-in) | Yes (Apple ID, if sync on) | No | App Functionality | On-device by default; syncs only to the user's private CloudKit DB — user-entered data and the wellbeing score only. Values read from HealthKit (readings, Apple Health workout imports, the imported body profile) never sync and stay on the device that read them (App Review 5.1.3(ii); next row). The wellbeing score, its per-area components, the companion state and the coin rows for an active day are the app's own results, computed partly from HealthKit readings, and they DO sync. Foods kept from an Open Food Facts lookup are ordinary user foods here. Not received by developer. |
| HealthKit readings (steps, active energy, exercise minutes, sleep incl. stages, resting heart rate, HRV, mindful minutes, workouts imported from Apple Health, the imported age/sex/height/weight; respiratory rate and wrist temperature for the opt-in body-tension estimate) | No | — | No | App Functionality | Read on-device only; stripped at the one sanitize boundary before any synced row or blob (owner decision 2026-09-23). Kept in a device-local residue file that is backup-excluded; the opt-in body-tension history (`StressLocalState.json`) is likewise device-only and backup-excluded (re-flagged after every write). Never in the encrypted sealed backup; never sent to the developer. |
| User Content — journal entries | Only if user opts into the encrypted sealed backup | Ciphertext only | No | App Functionality | Sealed/encrypted on device; never in plaintext CloudKit sync (only the entry structure/days ride core-data sync). Since P3 (2026-08-11), journal text leaves the device only as client-side AES-256-GCM ciphertext via the opt-in encrypted backup — same classification as the Sensitive-info row. Core memories never carry journal text (owner decision 2026-09-23): an entry leaves only its mood token or, with the on-device AI helper on, a short on-device summary checked to be non-verbatim (next row). Developer cannot read. |
| User Content — core memories (journal moods; short on-device AI summaries of journal entries; notes the user types) | Only via user's own iCloud (opt-in) | Yes (Apple ID, if sync on) | No | App Functionality | Plain in the user's private CloudKit DB, like the rest of the synced blob; never journal text. An AI summary is refused if it runs past 140 characters, uses diagnostic language, or copies the entry (verbatim, a prefix, or any 5-word run of it) — but a summary still describes what the entry was about. Not received by developer. |
| Sensitive info — period/cycle, intimate notes | Only if user opts into encrypted backup | Ciphertext only | No | App Functionality | Client-side AES-256-GCM before upload; Apple sees only ciphertext. Off by default. |
| Sensitive (Tier-2) memories — the behavioral observations the app infers | No | — | No | — | Device-local only since 2026-09-23: never synced, never in the encrypted backup (the "sensitive notes" payload is retired) or a device backup (backup-excluded, complete file protection); a copy an earlier build uploaded is deleted by the app's launch pass. Re-derived from the day history on a new device. |
| Photos | Only if user opts into the encrypted photo backup | Ciphertext only (Apple ID, if that backup is on) | No | App Functionality | Encrypted in app container; by default only in the standard device backup. The opt-in "Sealed backup for your photos" (own meal/recipe/progress photos ONLY — never friends' shared photos) uploads client-side AES-256-GCM ciphertext to the user's own private CloudKit DB. Off by default; never received by the developer; user-initiated Save-to-Photos export only. Apple's on-device Vision reads barcodes, nutrition labels and (AI on, on request) the food in a photo taken to log food; nothing leaves the device. |
| Contacts — the in-app friends list (social graph) and in-person session log | Only via user's own iCloud (opt-in sync) | Yes (Apple ID, if sync on) | No | App Functionality | The roster (`trustedProximityPeers`: display names, key fingerprints, signing and key-agreement public keys, first-accepted / last-seen times, revoked / blocked / reported state and the report reason) and the in-person session log (`trainerAuditEvents`, ≤ 500 events: time, event kind, peer fingerprint and display name, item TYPE — never item content) ride the aggregate blob to the user's private CloudKit DB when sync is on, unencrypted beyond Apple's own protection — owner decision 2026-09-23 that this is acceptable. The blob's `connectionSessionLogs` diagnostic history can also hold entries written by older builds; the current build records none (no session is wired to the Connection log). Not received by developer. Confirm with legal whether Contacts is the right category for an in-app social graph. |
| User Content — sealed away-hearts ("Deliver hearts later", opt-in) | In the developer's CloudKit **public** database, sealed, only while the setting is on | Contents: no. Records carry Apple's per-container pseudonymous `creatorUserRecordID` | No | App Functionality | One sealed (ChaChaPoly) heart per record under a rotating pseudonymous day tag; unreadable to the developer; deleted on pickup or by the sending device (only the creator can delete; no server-side expiry). The developer's CloudKit dashboard can see one anonymous account's send-activity timeline (records per day, distinct tags per day). Disclosed in Privacy Policy §6/§12. Confirm with legal whether this is "collected": if it is, the candidate answers are Other User Content (and possibly Identifiers → User ID, for the creator ID) → Not Linked to You → App Functionality. |
| User Content — recipes and planned workouts sent as Messages cards | No | — | No | — | Leaves the device only when the user sends a card, to recipients the user picks, through Apple's Messages service; the developer never receives or can access it. The App Group catalog the extension reads stays on the device, and the Messages extension keeps nothing of its own (its only writes are the review-inbox records of cards received, which the app consumes, expires after seven days, and wipes). |
| Search History — typed product searches (DuckDuckGo) and barcode lookups (Open Food Facts) | Not collected by the developer; sent to a third-party lookup service only when the user taps to look something up, behind the Web-nutrition-lookup consent (off by default; AI helper on) | No (no account, email or device identifier is sent; the service sees an IP address) | No | App Functionality | The request carries only the typed query or the barcode digits plus standard HTTP metadata (OFF also gets the app's name/version User-Agent); the developer never receives it, and neither service is a partner or receives data for advertising. Confirm with legal whether Apple's "collected" definition reaches a third-party lookup the user initiates; if it does, declare **Search History → Not Linked to You → App Functionality**. The saved product itself is covered by the Health & Fitness row (user's own foods, iCloud sync if on). |
| Identifiers — public key | Peer-to-peer only | Yes (device identity) | No | App Functionality | Ed25519 public key exchanged in person with friends; no server. A friend's key also rides the roster in the Contacts row. |
| Coarse location | Optional, on-device | No | No | App Functionality | WeatherKit prompts + optional activity tagging; never tracked over time, never sent to developer. |
| Contact info / Browsing / Purchases / Financial / etc. | No | — | — | — | Not collected. |

## Required-reason API declarations (`PrivacyInfo.xcprivacy`)

Four bundles, four manifests — App Store Connect checks each executable against the manifest of the
bundle that carries it. Declared reasons, per bundle (re-read from the files 2026-09-24):
- **App** (`App/Fernlet/PrivacyInfo.xcprivacy`):
  - `NSPrivacyAccessedAPICategoryUserDefaults` — **CA92.1** (the app's own settings).
  - `NSPrivacyAccessedAPICategoryFileTimestamp` — **C617.1**.
  - `NSPrivacyAccessedAPICategorySystemBootTime` — **35F9.1** (monotonic anti-tamper timing for the
    app lock and the moderation ban clock).
- **Widgets** (`App/FernletWidgets/PrivacyInfo.xcprivacy`): `NSPrivacyAccessedAPICategoryUserDefaults`
  — **1C8F.1** (App Group). Verify on a Release archive before relying on it: a Debug widget build
  references no `NSUserDefaults`, so the declaration may be broader than the binary needs.
- **Share extension** (`App/FernletShareExtension/PrivacyInfo.xcprivacy`): none.
- **Messages extension** (`App/FernletMessagesExtension/PrivacyInfo.xcprivacy`): none — true since
  2026-09-23, when its one `UserDefaults` write was removed, and enforced by
  `MessagesExtensionBoundaryTests.theExtensionManifestDeclaresExactlyTheRequiredReasonAPIsItsBinaryUses`
  (the manifest must declare exactly the required-reason categories its compiled sources use).
- All four: `NSPrivacyTracking` = `false`; `NSPrivacyTrackingDomains` empty;
  `NSPrivacyCollectedDataTypes` empty (developer collects nothing server-side — keep empty unless a
  type starts syncing to a developer backend, which Fernlet has none of; revisit if legal reads the
  away-hearts row as "collected"). `NoTrackingBoundaryTests` pins all four for tracking flags.

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

**Amendment owed (noted 2026-09-24, owner-signed documents not edited here).** The signed
[self-classification memo](Export-Self-Classification-Memo.md) and Export-Compliance-Encryption.md still
describe the peer-to-peer link as MultipeerConnectivity and name `URLSession` TLS as the only OS-level
cryptography. HEAD ships the friend mesh, presence and recipe-share radios over Network.framework QUIC
(TLS 1.3) with app-minted, never-persisted self-signed P-256 certificates, and MultipeerConnectivity
left the tree on 2026-09-22. The memo's own §9 ("a new cryptographic … protocol is introduced") calls
for it to be re-issued; whether the classification moves is the owner's call (with counsel), and every
primitive involved is a published standard.

## Post-S2 note (carried from spec §18) — resolved 2026-08-12

Journal text is sealed and excluded from plaintext CloudKit sync. The open question this note used
to carry is settled: since P3 (4ed7437, 2026-08-11) journal narratives and intimacy logs are
first-class opt-in encrypted-backup payloads — client-side AES-256-GCM ciphertext only, never
plaintext sync — and the journal row above now declares "Only if user opts into the encrypted
sealed backup / Ciphertext only", matching the Sensitive-info row. The sealed categories may still
be argued as not "collected" at all; confirm the final questionnaire answers with legal before
submission.

## Owner action — re-review the App Store Connect questionnaire (2026-09-24)

The answers entered in App Store Connect's App Privacy questionnaire must be re-reviewed against this
document before the next submission; nothing here updates them. The 2026-09-24 revision changes or may
change these answers:

- **Health & Fitness** — narrowed: what syncs is user-entered data plus the app-computed wellbeing
  score; HealthKit readings no longer ride iCloud at all.
- **Contacts** (new) — the friend roster and in-person session log DO sync to the user's private
  CloudKit DB; the old header said no social type did.
- **User Content** — core memories (moods and short AI summaries, no journal text); the away-hearts
  in the developer's public CloudKit DB (a "collected" question for legal, with the creator ID); the
  Messages cards (not collected).
- **Search History** (new) — the DuckDuckGo search and the Open Food Facts barcode lookup, pending
  legal's reading of "collected" for a third-party lookup the user initiates.
- **Sensitive info** — sensitive (Tier-2) memories left the encrypted-backup row; they are now
  device-only.
- **Required-reason APIs** — four manifests now, each declared per bundle above.
