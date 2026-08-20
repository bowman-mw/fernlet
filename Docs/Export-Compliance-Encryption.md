# Export Compliance — Encryption Documentation

**Status:** research + determination, 2026-08-13. Supersedes the one-paragraph "Encryption" section in
[App-Privacy-Nutrition-Labels.md](App-Privacy-Nutrition-Labels.md) and the compliance bullet in
[RemainingWork-2026-07-19.md](RemainingWork-2026-07-19.md) §1.

> Not legal advice. Export classification is the developer's own responsibility — Apple explicitly
> disclaims it, and a wrong classification is a customs/BIS matter, not an App Review matter. The
> determination below is the defensible reading for this app; §7 is the one genuine judgment call
> and is worth a lawyer's eye before the first non-US release.

---

## 1. Why this applies at all

Uploading a build to App Store Connect puts it on a server in the United States. If the app is then
distributed outside the US and Canada, that is an **export of encryption software** under the US
Export Administration Regulations (EAR), *regardless of where the developer lives*. Apple states this
directly in [Complying with Encryption Export Regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations).

Two independent obligations follow, and they are frequently confused:

| # | Obligation | Owed to | Trigger |
|---|---|---|---|
| A | Answer the encryption questions / upload documentation | **Apple** (App Store Connect) | Every version submitted, unless answered in the Info.plist |
| B | Classify the item, and file an **annual self-classification report** | **US BIS** (+ NSA ENC coordinator) | Exporting non-exempt encryption under License Exception ENC / mass-market |

Obligation B is the one people miss. Apple's own note: *"If your app uses exempt forms of encryption,
you might alternatively be required to submit a year-end self-classification report to the U.S.
government."*

There is also a third, jurisdiction-specific item (France/ANSSI) covered in §8.

---

## 2. What Apple asks (Obligation A)

### 2.1 The questionnaire

App Store Connect → **Apps → Fernlet → App Information → App Encryption Documentation (+)**, or via
**Manage** on a build flagged "Missing Compliance". Requires Account Holder, Admin, or App Manager.
The flow is a decision tree:

1. **Is your app designed to use cryptography, or does it contain or incorporate cryptography?**
   (This includes any third-party library you link against — not just your own code.)
2. **Does your app qualify for any of the exemptions in Category 5, Part 2 of the EAR?**
   Answer Yes only if the app's encryption is:
   - (a) specially designed for **medical end-use**;
   - (b) limited to **intellectual property / copyright protection**;
   - (c) limited to **authentication, digital signature, or the decryption of data or files**;
   - (d) specially designed and limited for **banking use or "money transactions"**;
   - (e) limited to **"fixed" data compression or coding techniques**;
   - or the app meets the descriptions in **Note 4** to Category 5 Part 2 (encryption is ancillary to
     the primary function).
3. **Does your app implement any encryption algorithms that are proprietary or not accepted as
   standards by international standards bodies** (IEEE, IETF, ISO, ITU, ETSI, 3GPP, TIA, GSMA)?
4. **Does your app implement any standard encryption algorithms instead of, or in addition to, using
   or accessing the encryption in Apple's operating system?**

### 2.2 What each answer costs you

| Encryption in the app | Documentation Apple requires |
|---|---|
| Only Apple OS encryption (e.g. HTTPS via `URLSession`) | None |
| **Standard** algorithms you implement/link yourself | French encryption declaration (if distributing in France) — see §8 |
| **Proprietary / non-standard** algorithms | US **CCATS** from BIS **+** French declaration |

Apple reviews uploaded documents in roughly **2 business days** and then issues a code.

### 2.3 Answering once, in the build

Rather than answering per submission, the answer can live in the build:

- `ITSAppUsesNonExemptEncryption` (Boolean) — `NO` if the app uses no encryption, **or only exempt
  forms**; `YES` otherwise.
- `ITSEncryptionExportComplianceCode` (String) — the code Apple issues after it approves the uploaded
  documentation. Only meaningful when the key above is `YES` and documents were required.

In this project the key is set from the build settings, not the `Info.plist` file — currently
`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` in both the Debug and Release configurations of the
`Fernlet` target ([App/Fernlet.xcodeproj/project.pbxproj:528](../App/Fernlet.xcodeproj/project.pbxproj#L528)
and `:585`). Neither extension target sets it.

---

## 3. What Fernlet actually ships

Every item below is real, first-party code (or a linked third-party package), not OS-level TLS:

| Where | Primitive | Standard | Purpose |
|---|---|---|---|
| `FernletCrypto/ColumnCrypto` | ChaCha20-Poly1305, HKDF-SHA256 | RFC 8439, RFC 5869 | Per-column sealing of journal / worry / menstrual / intimacy text |
| `PrivateMediaStore/MediaAtRestCrypto` | AES-256-GCM | NIST SP 800-38D | At-rest sealing of meal, progress, and private photos |
| `FernletLock/FernletLockService` | **scrypt** (N=65536, r=8, p=1) via **CryptoSwift** | RFC 7914 | Passcode → content-key wrapping key |
| `FernletLock/SecureEnclaveContentKeyWrap` | ECIES over Secure Enclave **P-256** | SEC 1 / NIST P-256 | Hardware device-binding of the content key |
| `ProximityKit/IdentityService` | **Ed25519** signing, **X25519** ECDH | RFC 8032, RFC 7748 | Per-device peer identity, session key agreement |
| `ProximityKit/HeartDropSealer` | X25519 ECDH → HKDF-SHA256 → ChaCha20-Poly1305, one-time prekeys | RFC 7748/5869/8439 | Sealed-sender offline "heart drop" envelopes |
| `ProximityKit/Wire`, `Moderation` | SHA-256 / SHA-512, HMAC | FIPS 180-4, RFC 2104 | Envelope integrity, content hashing |
| Sealed backup / escrow | AES-256-GCM, X25519, HKDF | as above | Client-side-encrypted backup blobs; escrow key in iCloud Keychain |
| `WebScrapingKit/EphemeralWebSession` | TLS via `URLSession` | — | The only *OS-level* crypto; exempt on its own |

Two facts matter for classification:

1. **Every algorithm is a published international standard.** Nothing here is a home-grown cipher,
   hash, or KDF.
2. **The app is not merely using OS encryption.** CryptoKit is Apple-provided but the app implements
   its own key hierarchy and wire formats on top of it, and **CryptoSwift** is a third-party crypto
   library linked into the app (scrypt, used by the lock). So the "Apple OS encryption only, no
   documentation required" row of §2.2 does **not** apply.

---

## 4. Determination

**Fernlet does not qualify for an EAR Category 5 Part 2 exemption, and should be classified as a
mass-market item under ECCN 5D992.c, self-classified under License Exception ENC §740.17(b)(1).**

Reasoning against each exemption:

- **Medical end-use** — tempting for a health app, and *wrong here on purpose*: the entire product
  positioning (App Review, MDR, the wellness-not-medical framing throughout the spec) is that Fernlet
  is **not** a medical device. Claiming a medical-end-use export exemption directly contradicts that.
  This was already the decision recorded on 2026-07-19.
- **Authentication / digital signature / decryption only** — the Ed25519 envelope signatures would fit,
  but the app also does bulk **confidentiality** encryption (sealed journals, sealed photos, sealed
  heart drops). The exemption is for encryption *limited to* those uses. Fernlet's is not.
- **Copyright protection, banking, fixed data compression** — inapplicable.
- **Note 4 (ancillary cryptography)** — does not fit. Privacy sealing is not ancillary to Fernlet; it
  is a headline feature of the product ("privacy-first", the sealed private stores, the S3 wall).

Positive case for **5D992.c**:

- **Mass market** under Note 3 to Category 5 Part 2 — generally available to the public at retail
  (a free consumer App Store app), sold in volume, no special technical skill to use, no
  customer-specific customization.
- Symmetric >56-bit and asymmetric >512-bit key lengths put it in Category 5 Part 2 in the first place
  (i.e. it is *not* below the cryptographic note thresholds).
- Standard published algorithms only ⇒ eligible for **self-classification**; **no CCATS required**.

**Consequences of this determination:**

| Item | Answer |
|---|---|
| `ITSAppUsesNonExemptEncryption` | **`YES`** (currently `NO` — this must change) |
| CCATS / classification request to BIS | **Not required** (see §7 caveat) |
| Documents to upload to App Store Connect | None, except the French declaration if France is a release country (§8) |
| `ITSEncryptionExportComplianceCode` | Not applicable (Apple only issues one after a document review) |
| BIS annual self-classification report | **Required**, by Feb 1 each year (§6) |

---

## 5. Why `ITSAppUsesNonExemptEncryption` must flip to `YES`

The key's meaning is precisely "does the app use encryption that is **not exempt** from the
documentation requirements". `NO` is correct only when the app uses no encryption at all, or only
exempt forms. Fernlet uses non-exempt (albeit standard, self-classifiable) encryption, so `NO` is a
misstatement in the shipped binary.

Practically: answering `YES` and having no proprietary algorithms leads App Store Connect to the
"standard algorithms, self-classified" path — which requires no upload at all outside France. So this
change costs nothing at submission time and makes the declaration truthful.

The edit, in both Debug and Release configurations of the `Fernlet` target:

```
INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = YES;
```

Consider setting it on `FernletWidgets` and `FernletShareExtension` too — they are separate bundles;
the share extension in particular touches the sealed recipe-import path.

---

## 6. The annual self-classification report (Obligation B)

This is the one recurring, calendar-driven obligation.

- **Who files:** the exporter — i.e. you, the developer, not Apple.
- **What it covers:** encryption items self-classified under License Exception ENC §740.17(b)(1),
  including mass-market items classified 5A992.c / 5D992.c, that were exported or reexported during
  the calendar year (Jan 1 – Dec 31). Items for which a CCATS has been issued are excluded; so are
  stand-alone toolkits (a 2021 relaxation that does **not** cover finished apps).
- **Deadline:** must be **received by February 1** of the following year.
- **Format:** the fields and layout of **Supplement No. 8 to Part 742**, submitted as an electronic
  file in **CSV only** — no other format is accepted. Typical columns: product name/model, ECCN,
  a short description, and the manufacturer, plus (where applicable) a URL for publicly available
  source code.
- **Where:** by email to BIS and the ENC Encryption Request Coordinator — historically
  `crypt-supp8@bis.doc.gov` and `enc@nsa.gov`. **Verify the BIS address before filing**: BIS migrated
  its web presence from `bis.doc.gov` to `bis.gov`, and the mailbox may have moved with it. Check the
  [BIS annual self-classification page](https://www.bis.gov/learn-support/encryption-controls/annual-self-classification)
  at filing time.

**First filing for Fernlet:** if the app ships to non-US/Canada storefronts at any point during
calendar 2026, the first report is due **1 February 2027**. Nothing is owed for a year with no
export. (TestFlight distribution to testers outside the US counts as export too.)

Two useful notes:

- Filing a classification request (CCATS) instead would *remove* the annual reporting duty — but it
  costs a SNAP-R submission and a BIS review cycle. For a single free consumer app, the annual CSV is
  far cheaper.
- One report can list multiple products, so Fernlet and (later) Fernlet Coach can share a filing —
  provided Coach's own classification is settled first; it will have its own crypto surface and its
  own closed-source/App Attest posture.

---

## 7. The one genuine judgment call: "non-standard cryptography"

EAR Part 772 defines **non-standard cryptography** as:

> any implementation of "cryptography" involving the incorporation or use of proprietary or
> unpublished cryptographic functionality, including encryption algorithms **or protocols** that have
> not been adopted or approved by a duly recognized international standards body (e.g. IEEE, IETF,
> ISO, ITU, ETSI, 3GPP, TIA, GSMA) and have not otherwise been published.

The phrase "or protocols" is the catch. Fernlet's **algorithms** are unambiguously standard, but
several of its **protocols** are bespoke: the heart-drop sealed-sender envelope (its own version byte,
prekey ID, HKDF salt `fernlet.heartdrop.seal.v1`, and AAD construction), the wire2 framing, and the
identity/trust ceremony. These are Noise-inspired but are not the Noise spec, TLS, or any other
standards-body protocol.

Read strictly, a bespoke protocol is "non-standard cryptography", and mass-market items using
non-standard cryptography are **not** eligible for self-classification under §740.17(b)(1) — they need
a classification request under §740.17(b)(2)/(b)(3) instead. Read as the industry actually behaves,
"non-standard" targets **proprietary or unpublished** cryptography, and a protocol assembled from
published primitives with no secret components is treated as standard; the great majority of messaging
and E2EE consumer apps self-classify as 5D992.c on that basis.

Three things materially strengthen the second reading for Fernlet, and are worth doing regardless:

1. **The source is public and Apache-2.0 licensed.** Nothing about the protocol is unpublished — which
   goes to the "and have not otherwise been published" clause of the definition.
2. **The wire formats are documented** in the DocC headers and the proximity docs, so a reviewer can
   read the construction without reverse-engineering the binary.
3. **No secret sauce**: no custom cipher, no custom hash, no obscured key schedule.

**Recommendation:** self-classify as 5D992.c and file the annual report, and put the question to an
export-controls attorney before the first paid/large-scale non-US release. If a definitive answer is
wanted with no residual risk, file a classification request (CCATS) via SNAP-R describing the
heart-drop and mesh protocols; a favorable CCATS both settles the classification *and* retires the
annual reporting duty.

---

## 8. France / ANSSI

Apple's reference table still lists a **French encryption declaration** for apps using standard
encryption algorithms and distributed in France, and a CCATS *plus* the declaration for proprietary
algorithms. France's regime (declaration to ANSSI for supply/import of cryptology means) is separate
from the US rules and is not satisfied by anything filed with BIS.

Practical read: if France is in the release countries — and it will be, absent a deliberate exclusion —
prepare the ANSSI declaration for a means of cryptology providing confidentiality, and upload it in the
App Store Connect encryption-documentation flow if the questionnaire asks for it. Apple's in-flow
questions are the authority on whether it still wants the document; the reference page above is the
fallback. This is a one-time filing, not annual.

---

## 9. Action checklist

- [ ] **Code:** flip `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption` to `YES` in the `Fernlet` target
      (both configurations); decide whether to mirror it on `FernletWidgets` and
      `FernletShareExtension`.
- [ ] **Docs:** correct the "Encryption" section of [App-Privacy-Nutrition-Labels.md](App-Privacy-Nutrition-Labels.md),
      which currently states `false` / "only exempt encryption" — that is the opposite of this
      determination. Point it here.
- [ ] **App Store Connect:** walk the App Encryption Documentation flow once (App Information → +).
      Expected answers: uses cryptography **Yes** → qualifies for an exemption **No** → proprietary /
      non-standard algorithms **No** → standard algorithms beyond the OS **Yes**.
- [ ] **France:** prepare/submit the ANSSI declaration if France stays in the release countries.
- [ ] **BIS:** build the Supplement No. 8 CSV (one row, ECCN 5D992.c) and diarise **1 February 2027**
      for the first filing; confirm the current BIS mailbox before sending.
- [ ] **Legal:** get the §7 protocol question reviewed, and confirm no CCATS is wanted.
- [ ] **Coach app:** repeat this determination separately for Fernlet Coach — different bundle,
      different crypto surface, closed source, App Attest. Its classification does not inherit from
      this one.

---

## 10. Ready-to-paste descriptions

App Store Connect will not assess encryption documentation until the **App Description** field is
populated, and the ANSSI declaration and the BIS report both want a plain-language description of the
product and of what the cryptography does. These are written for those forms — factual, no marketing.

### 10.1 One line

> Fernlet is a free, privacy-first iOS wellbeing companion: a virtual creature that reflects the
> user's daily self-care, with all personal data kept on the user's own devices.

### 10.2 Short description (~60 words) — for the export/encryption forms

> Fernlet is a free consumer iOS app for personal wellbeing. Users log meals, movement, sleep, mood,
> journaling, hygiene and (optionally) menstrual-cycle entries; a virtual companion creature reflects
> that daily care. All data stays on the user's own devices or their personal iCloud account — there
> is no developer server, no account, no advertising and no analytics.

### 10.3 Longer description (~130 words) — for the App Store Connect App Description field

> Fernlet is a gentle, privacy-first wellbeing companion. Instead of streaks and optimisation, it
> gives you a small creature that reflects how you've been caring for yourself: what you've eaten,
> how you've moved and slept, how you've been feeling, and the small daily things that are easy to
> let slip.
>
> You can log meals and recipes, track workouts, keep a private journal and worry box, follow your
> cycle, and set gentle goals. Health data is read from and written to Apple Health with your
> permission. Nearby friends can share recipes and photos directly device-to-device.
>
> Fernlet is free, has no ads, no tracking and no accounts. There is no developer server: your data
> lives on your devices and, if you choose, your own iCloud. Sensitive entries are encrypted with a
> passcode only you know.

### 10.4 Description of the cryptography — for ANSSI / BIS / any Apple follow-up

> Fernlet uses cryptography solely to protect the user's own personal data on the user's own devices
> and between devices the user controls. It implements no cryptography of its own design: all
> primitives are published international standards — AES-256-GCM (NIST SP 800-38D) and
> ChaCha20-Poly1305 (RFC 8439) for data at rest, HKDF-SHA256 (RFC 5869) and scrypt (RFC 7914) for key
> derivation, X25519 (RFC 7748) for key agreement, Ed25519 (RFC 8032) for signatures, ECIES over
> NIST P-256 in the device's secure element for hardware key binding, and SHA-256/SHA-512 and HMAC
> for integrity. Implementations are Apple's CryptoKit and Security frameworks plus the open-source
> CryptoSwift library (scrypt only).
>
> The cryptography serves four purposes: (1) encrypting the user's private journal, worry-box,
> menstrual and intimate-activity entries at rest under a key derived from a user passcode; (2)
> encrypting photos at rest; (3) client-side encryption of optional backups placed in the user's own
> iCloud account, to which the developer has no access; and (4) end-to-end encrypted, signed messages
> exchanged directly between nearby users' devices over Bluetooth/Wi-Fi peer-to-peer links. There is
> no developer-operated server and no key escrow: the developer holds no keys and can decrypt nothing.
>
> The application source code is publicly available under the Apache 2.0 licence, including the wire
> formats and key-derivation constructions.

### 10.5 BIS Supplement No. 8 row (CSV)

One row, values to confirm against the current Supplement No. 8 column list at filing time:

| Field | Value |
|---|---|
| Product name / model | Fernlet (iOS application) |
| ECCN | 5D992.c |
| Item type / description | Mass-market consumer wellbeing application implementing standard published encryption (AES-256-GCM, ChaCha20-Poly1305, X25519, Ed25519, HKDF, scrypt) for at-rest protection of the user's own data and end-to-end encrypted peer-to-peer messaging |
| Manufacturer | *(your name / entity as it appears on the App Store listing)* |
| Publicly available source code URL | *(the public repository URL)* |

---

## 11. Sources

- [Complying with Encryption Export Regulations — Apple Developer](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)
- [Export compliance documentation for encryption — App Store Connect Help](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/)
- [Determine and upload app encryption documentation — App Store Connect Help](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation)
- [Overview of export compliance — App Store Connect Help](https://www.developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)
- [ITSEncryptionExportComplianceCode — Apple Developer Documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/itsencryptionexportcompliancecode)
- [Mass market (Note 3 to Category 5 Part 2) — BIS](https://www.bis.gov/learn-support/encryption-controls/mass-market)
- [License Exception ENC: 740.17(b)(1) — BIS](https://www.bis.gov/learn-support/encryption-controls/license-exception-enc-740.17-b-1)
- [Annual self-classification report — BIS](https://www.bis.gov/learn-support/encryption-controls/annual-self-classification)
- [Supplement No. 8 to Part 742 — Self-Classification Report for Encryption Items (eCFR)](https://www.ecfr.gov/current/title-15/subtitle-B/chapter-VII/subchapter-C/part-742/appendix-Supplement%20No.%208%20to%20Part%20742)
- [15 CFR 742.15 — Encryption items (eCFR)](https://www.ecfr.gov/current/title-15/subtitle-B/chapter-VII/subchapter-C/part-742/section-742.15)
- [15 CFR 740.17 — Encryption commodities, software, and technology (ENC) (eCFR)](https://www.ecfr.gov/current/title-15/subtitle-B/chapter-VII/subchapter-C/part-740/section-740.17)
- [BIS updates reporting requirements for mass-market encryption items (Mar 2021) — Baker McKenzie](https://sanctionsnews.bakermckenzie.com/bis-updates-reporting-requirements-relating-to-mass-market-encryption-items-and-publicly-available-software-and-also-updates-certain-classifications/)
- [Encryption reporting deadline is February 1 — Cooley](https://www.cooley.com/news/insight/2024/2024-01-25-export-control-reminder-encryption-reporting-deadline-is-february-1-2024)
