# Export Compliance — Encryption Documentation

**Status:** determination 2026-08-13, **materially revised 2026-08-19**. Supersedes the one-paragraph
"Encryption" section in [App-Privacy-Nutrition-Labels.md](App-Privacy-Nutrition-Labels.md) and the
compliance bullet in [RemainingWork-2026-07-19.md](RemainingWork-2026-07-19.md) §1.

> **2026-08-19 revision.** The determination below — mass market, ECCN 5D992.c, self-classify, no
> CCATS — was independently re-checked against the current eCFR text and **holds**. Its *filing
> consequences* did not, and two things changed:
>
> 1. **The annual February 1 report is almost certainly not owed** (§6). §740.17(e)(3) was rewritten
>    on 2021-03-29 to cover only encryption *components* and *"executable software"*; a finished
>    consumer app is neither. The earlier text of this document stated a recurring legal obligation
>    that does not exist.
> 2. **The repository is now public** (Apache-2.0, complete crypto source). That opens the
>    publicly-available route in §742.15(b) / §734.7(b) — omitted entirely from the first draft — and
>    materially strengthens §7, because "non-standard cryptography" is a **conjunctive** test that
>    publication defeats on its own.
>
> Every exemption in §4 was separately re-audited against the shipping code. All five, plus Note 4,
> remain unavailable; the reasoning in §4 is now tighter but the answers are unchanged.

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
| `ITSAppUsesNonExemptEncryption` | **`YES`** — shipped in commit `4802416` |
| CCATS / classification request to BIS | **Not required** (see §7 caveat) |
| Documents to upload to App Store Connect | None, except the French declaration if France is a release country (§8) |
| `ITSEncryptionExportComplianceCode` | Not applicable (Apple only issues one after a document review) |
| BIS annual self-classification report | **Almost certainly not required** — see the rewritten §6 |

---

## 5. Why `ITSAppUsesNonExemptEncryption` must flip to `YES`

> **Done.** Both configurations of the `Fernlet` target now read `YES` (commit `4802416`).

The key's meaning is precisely "does the app use encryption that is **not exempt** from the
documentation requirements". `NO` is correct only when the app uses no encryption at all, or only
exempt forms. Fernlet uses non-exempt (albeit standard, self-classifiable) encryption, so `NO` was a
misstatement in the shipped binary.

Note that "publicly available / not subject to the EAR" (§6A) is a **different legal status** from
"exempt", and is **not** on Apple's exemption list. Becoming publicly available does not let this key
go back to `NO`.

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

## 6. What is actually owed (Obligation B) — and why the annual report is not

**Revised 2026-08-19.** The earlier text of this section said a Supplement No. 8 report was due every
February 1. That was wrong, and had been since 2021.

### 6.1 The report was scoped out of existence for finished apps

The rule of **2021-03-29 (86 FR 16482)** rewrote §740.17(e)(3). The current text applies the report to:

> "mass market" encryption **components** and **'executable software'** that meet the criteria of the
> Cryptography Note … and are classified under ECCN 5A992 or 5D992 following self-classification, as
> well as to non-"mass market" encryption commodities and software that remain classified in ECCN
> 5A002, 5B002 or 5D002 …

with an attached note defining the term narrowly — `'executable software'` means software "from an
existing hardware component," and expressly **"does not include complete binary images of the
'software' running on an end item."** A finished consumer iOS app is neither a component nor that.

BIS's own [Table of Changes for the 2021 ENC rule](https://www.bis.gov/media/documents/table-changes-enc-wa2019-rule-final-version.pdf),
row 1, is explicit for exactly this bucket — *"5x992.c – mass market items described in 740.17(b)(1)"*:
**before**, a report or classification was required; **after**, *"No self-classification report or
classification required."* The preamble estimated a 60% reduction in reports on this basis.

**The honest complication.** Three BIS *web guidance* artifacts still recite the broad pre-2021 rule
without the carve-out (the annual self-classification page, the mass-market page, the ENC summary
PDF), and the BIS Encryption FAQs are dated March 2017. The regulation governs over stale guidance —
but the conflict is real, and it is the reason for the cheap hedge in §6.3.

Even on the conservative reading this was never truly annual: §740.17(e)(3)(iii) says *"Each product
must be included in a report only one time."*

### 6.2 Filing mechanics, if a report is ever filed

Confirmed current as of 2026-08-19, and correcting two errors in the first draft:

- **The mailboxes did not move.** §740.17(e)(3)(ii)(A) still names `crypt-supp8@bis.doc.gov` and
  `enc@nsa.gov`. The *website* migrated from bis.doc.gov to bis.gov; the *mail domain* did not. The
  email subject must be **"self-classification report"** — a requirement the first draft omitted.
- **Format:** Supplement No. 8 to Part 742, **`.csv` only**, received by **February 1**. See the
  corrected §10.5 — the first draft's row had five columns; **twelve are mandatory**, none may be
  blank, and the ECCN field takes **`5D992`**, not `5D992.c`.

### 6.3 Recommended posture

File **one** Supplement No. 8 CSV, once, if any non-US distribution happens — then never again. It is
a single row; it resolves the regulation-versus-guidance conflict in §6.1; and it is the step BIS's
own guidance (§6A) says to complete *"only once"* before a free app becomes publicly available. Do not
treat it as recurring.

---

## 6A. The publicly-available route (added 2026-08-19)

Omitted entirely from the first draft, and now the most important section here: **the shipped app can
end up outside the EAR altogether.**

### 6A.1 Two routes, one destination

**Route A — mass market + free.** BIS's
[Encryption items not subject to the EAR](https://www.bis.gov/learn-support/encryption-controls/encryption-items-not-subject-to-ear)
addresses this fact pattern by example:

> **1. Mass market encryption object code software that is made "publicly available."** … For
> example, an App made for a smartphone or computer that … meets the Mass Market criteria … **that is
> made available free of charge would be considered "publicly available."** In this case you would
> have to first comply with the mass market requirement … by self-classification as 5D992.c with
> self-classification report (or submitting classification request to BIS) **only once**. Then, if the
> item is made publicly available (e.g., free to download) it would be considered not subject to the
> EAR anymore.

The qualifying act is that **Fernlet is free**, not that the source is on GitHub. Fernlet is
permanently free by product decision (recorded 2026-07-19), so this is durable — **but it is
conditional: if Fernlet ever becomes paid, this analysis must be re-run.**

**Route B — published source, corresponding object code.** §742.15(b)(1) puts publicly available
5D002 *source code* outside the EAR; §734.7(b) and the Note to §734.3(b)(2)–(3) extend that to
*"publicly available encryption object code software … when the corresponding source code meets the
criteria specified in § 742.15(b)."* The repository is public under Apache-2.0 with the complete
crypto source, so the source-side condition is met.

**Ordering matters.** The Note to §740.17(b) is explicit that publication alone does not release a
mass-market item: it *"remains subject to the EAR until all applicable classification or
self-classification requirements … are fulfilled."* Self-classify **first**; publicly-available status
attaches after.

### 6A.2 Residual uncertainty, stated plainly

The App Store binary is not byte-identical to anything published — Apple re-signs, FairPlay-wraps and
thins it, and the EULA restricts redistribution — so a strict reader could argue *that artifact* was
never itself published. No BIS guidance was found addressing this mixed-channel case. **Route A
sidesteps it entirely**, because BIS's own example treats "free to download" as the qualifying act.

### 6A.3 The §742.15(b)(2) notification

Since 2021-03-29 this is required **only** for published source that performs *non-standard
cryptography* — so on the §7 determination it is **not owed**. Send it anyway:

- One email to `crypt@bis.doc.gov` and `enc@nsa.gov` giving the **repository URL**.
- One-time when notified by URL — re-notification is required only if the **URL changes**, expressly
  *not* for updates to the code at that location. (Sending *copies* instead would oblige a fresh copy
  on every crypto change. Notify by URL.)
- It costs one email and creates a **dated government record that the source was published at a
  URL** — precisely the evidence that defeats the second prong of the §7 test.

### 6A.4 The ordering trap: TestFlight

A TestFlight beta is invite-only and capped, so it is **not** "publicly available" — Route A does not
apply during beta, while Apple's documentation confirms TestFlight to testers outside the US/Canada
**is** an export. Until self-classification is done the item is 5D002 and EI-controlled.

**Self-classify before the first overseas TestFlight tester** and this evaporates: 5D992.c is
AT-controlled only, needing no licence outside Country Group E:1.

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

**Updated 2026-08-19 — the test is CONJUNCTIVE, and publication now satisfies it.** Read the Part 772
definition again: non-standard cryptography requires functionality that is *proprietary or
unpublished*, including protocols not adopted by a standards body **"and have not otherwise been
published."** Both prongs must hold. Fernlet's protocols are bespoke framings over published
primitives, and since the repository went public under Apache-2.0 with the complete crypto source,
**the second prong now fails on its own**. Publishing did more for this question than any argument in
this section.

**The counter-risk, which is not settled.** §740.17(b)(2)(i)(C)(2) sweeps in items whose cryptographic
functionality *"can be easily changed by the user,"* and Note 3's mass-market criteria say the same.
A hostile reading is that open source means user-changeable. The structural counter is strong —
§740.17(b)(2)(i)(B) singles out *non-publicly-available* source code for CCATS, which would be
incoherent if publishing pushed items into (b)(2) anyway — and the settled industry reading is that
this targets user-configurable crypto in the shipped product (plug-in ciphers, open cryptographic
interfaces), not the ability to fork and recompile. Fernlet's algorithms and parameters are
compile-time constants with no configuration surface. Worth a lawyer's confirmation; do not treat it
as settled.

**Recommendation:** self-classify as 5D992.c; send the §6A.3 notification even though it is not owed;
do **not** file a CCATS unless counsel says the protocols are non-standard — it is a SNAP-R submission
plus a 30-day wait, and it buys certainty that is probably unnecessary. What is at stake if the call
goes the other way: non-standard items fall under **§740.17(b)(3)(ii)**, which requires a
classification request and a 30-day wait *before* License Exception ENC may be used, and makes the
§742.15(b)(2) notification mandatory. That is the only question in this document carrying real cost.

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

**Revised 2026-08-19.** The controlling deadline is the **first non-US distribution — including the
first overseas TestFlight tester** — not App Store launch. Nothing is owed to any government today.

- [x] **Code:** `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = YES` in both configurations of the
      `Fernlet` target — done in commit `4802416`. Still open: decide whether to mirror it on
      `FernletWidgets` and `FernletShareExtension` (separate bundles; the share extension touches the
      sealed recipe-import path).
- [x] **Docs:** the "Encryption" section of [App-Privacy-Nutrition-Labels.md](App-Privacy-Nutrition-Labels.md)
      now points here rather than asserting the old exemption — done in commit `4802416`.
- [ ] **Write and date the self-classification memo.** One page: mass market under Note 3, all
      primitives published standards, protocols published under Apache-2.0 at the repo URL, therefore
      not "non-standard cryptography", **ECCN 5D992.c** under §740.17(b)(1). This memo *is* the
      compliance artifact — nothing is filed to create it. Retain **five years** past the last export
      (§762.6(a)).
- [ ] **Do this before the first overseas TestFlight tester** — see §6A.4. Self-classifying first is
      what keeps the beta out of 5D002/EI territory.
- [ ] **Send the §742.15(b)(2) notification** to `crypt@bis.doc.gov` and `enc@nsa.gov` with the
      repository URL (§6A.3). Not required on this determination; one email; highest value per minute.
- [ ] **App Store Connect:** walk the App Encryption Documentation flow once. Expected answers: uses
      cryptography **Yes** → qualifies for an exemption **No** → proprietary / non-standard algorithms
      **No** → standard algorithms beyond the OS **Yes**.
- [ ] **France:** prepare/submit the ANSSI declaration if France stays in the release countries.
      Triggered by CryptoSwift's scrypt being a linked third-party implementation rather than an Apple
      OS API. Separate regime — nothing filed with BIS satisfies it.
- [ ] **BIS Supplement No. 8:** **one** filing, once, only if non-US distribution occurred — then
      never again (§6.3). Use the corrected 12-column row in §10.5.
- [ ] **Legal:** the §7 protocol question and the §7 "easily changed by the user" counter-risk are the
      only items carrying real cost. Everything else is settled.
- [ ] **Re-run this analysis if Fernlet ever stops being free** — Route A in §6A.1 depends on it.
- [ ] **Coach app:** repeat separately for Fernlet Coach — different bundle, different crypto surface,
      closed source, App Attest. Its classification does not inherit from this one, and being
      closed-source means neither Route A nor Route B is available to it on the same terms.

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

**Corrected 2026-08-19.** The first draft listed five fields and invented a source-code-URL column;
that file would have been rejected. Supplement No. 8(b)(3) requires the header line to match
**without alteration or variation**, **twelve** fields, and **no field may be left blank** (use
`NONE` / `N/A`). `.csv` only.

```
PRODUCT NAME,MODEL NUMBER,MANUFACTURER,ECCN,AUTHORIZATION TYPE,ITEM TYPE,SUBMITTER NAME,TELEPHONE NUMBER,E-MAIL ADDRESS,MAILING ADDRESS,NON-U.S. COMPONENTS,NON-U.S. MANUFACTURING LOCATIONS
```

| Field | Value |
|---|---|
| PRODUCT NAME | Fernlet |
| MODEL NUMBER | N/A |
| MANUFACTURER | SELF |
| ECCN | **`5D992`** — the enumerated list is 5A002 / 5B002 / 5D002 / 5A992 / 5D992; **the `.c` suffix is not valid in this field** |
| AUTHORIZATION TYPE | MMKT |
| ITEM TYPE | Mobility and mobile applications n.e.s. |
| SUBMITTER NAME | *(your name)* |
| TELEPHONE NUMBER | *(contact number)* |
| E-MAIL ADDRESS | *(contact email)* |
| MAILING ADDRESS | *(postal address)* |
| NON-U.S. COMPONENTS | CryptoSwift (scrypt), Poland — *verify before filing* |
| NON-U.S. MANUFACTURING LOCATIONS | NONE |

There is **no** "publicly available source code URL" column. That URL belongs in the separate
§742.15(b)(2) notification email (§6A.3), which is a different filing to a different mailbox.

Send to `crypt-supp8@bis.doc.gov` and `enc@nsa.gov` with the subject line **"self-classification
report"**.

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
