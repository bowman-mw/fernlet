# Encryption Self-Classification Memorandum — Fernlet (iOS)

**Item:** Fernlet, iOS application (bundle identifier `MBO.Fernlet`)
**Classification:** **ECCN 5D992.c** — mass market encryption software
**Authorization:** License Exception ENC, self-classification under **15 CFR §740.17(b)(1)**
**Determined:** 2026-08-19
**Determined by:** Michael Bowman Olay, sole developer *(confirm the legal name/entity exactly as it appears on the App Store listing before this is relied on)*
**Retention:** five years past the date of the last export — 15 CFR §762.6(a)

> **Purpose.** This memorandum is the record of a self-classification. Under §740.17(b)(1) nothing is
> filed with BIS to *create* a classification; the obligation is to have made a defensible
> determination and to be able to produce it. This document is that determination. It is engineering
> and regulatory analysis by the developer, **not legal advice**, and §8 lists the two questions that
> warrant counsel.
>
> Supporting analysis, with citations: [Export-Compliance-Encryption.md](Export-Compliance-Encryption.md).

---

## 1. Determination

Fernlet is **mass market encryption software** under Note 3 to Category 5 — Part 2, classified
**ECCN 5D992.c**, self-classified under License Exception ENC §740.17(b)(1).

It does **not** qualify for any Category 5 Part 2 exemption (§4). It does **not** implement
non-standard cryptography (§5), so it is eligible for self-classification rather than a classification
request. Because the application is distributed free of charge and is therefore **publicly
available**, the shipped object code is **not subject to the EAR** once this self-classification is
complete (§6).

No CCATS is required. No document upload to Apple is required outside France.

---

## 2. Description of the item

Fernlet is a free consumer iOS application — a privacy-first health and self-care companion. A
companion creature reflects the user's daily wellbeing, computed on-device from food, movement,
sleep, cycle, journaling and hygiene signals.

It operates with **no backend of its own**. Its uses of cryptography are:

1. **At-rest confidentiality** on the user's own device for sensitive personal content — journal
   text, menstrual-cycle narratives, intimate-activity notes, and photos — so that this material is
   protected independently of the device passcode.
2. **End-to-end encrypted peer-to-peer exchange** between users who have met in person, over a
   short-range local link (MultipeerConnectivity with NearbyInteraction ranging): recipe sharing,
   friend photos, companion clothing, group activities, and short "heart" messages.
3. **Client-side encryption of backups** and of an offline "heart drop" delivered through a CloudKit
   public database, which the developer cannot read.

Distribution is via the Apple App Store, **free of charge**, with no purchase price, subscription,
in-app purchase or advertising. The complete source, including all cryptographic source code, is
published under the Apache License 2.0 at <https://github.com/bowman-mw/fernlet>. Both of these are
permanent product commitments, not launch conditions.

---

## 3. Cryptographic functionality

All primitives are published international standards. There is no proprietary or home-grown cipher,
hash, key-derivation function or key schedule.

| Component | Primitive | Standard | Purpose |
|---|---|---|---|
| `FernletCrypto/ColumnCrypto` | ChaCha20-Poly1305, HKDF-SHA256 | RFC 8439, RFC 5869 | Per-column sealing of journal / worry / menstrual / intimacy text |
| `PrivateMediaStore/MediaAtRestCrypto` | AES-256-GCM | NIST SP 800-38D | At-rest sealing of meal, progress and private photos |
| `FernletLock/FernletLockService` | scrypt (N=65536, r=8, p=1), via CryptoSwift | RFC 7914 | Passcode → content-key wrapping key |
| `FernletLock/SecureEnclaveContentKeyWrap` | ECIES over Secure Enclave P-256 | SEC 1, NIST P-256 | Hardware device-binding of the content key |
| `ProximityKit/IdentityService` | Ed25519 signing, X25519 ECDH | RFC 8032, RFC 7748 | Per-device peer identity, session key agreement |
| `ProximityKit/HeartDropSealer` | X25519 ECDH → HKDF-SHA256 → ChaCha20-Poly1305, one-time prekeys | RFC 7748, 5869, 8439 | Sealed-sender offline heart-drop envelopes |
| `ProximityKit/Wire`, `Moderation` | SHA-256, SHA-512, HMAC | FIPS 180-4, RFC 2104 | Envelope integrity, content hashing |
| Sealed backup / escrow | AES-256-GCM, X25519, HKDF-SHA256 | as above | Client-side-encrypted backup blobs; escrow key held in iCloud Keychain |
| `WebScrapingKit/EphemeralWebSession` | TLS, via `URLSession` | — | The only OS-level cryptography; exempt in its own right |

**Key lengths exceed the Cryptographic Note thresholds** — symmetric keys are 256-bit and asymmetric
key agreement/signature is Curve25519 and P-256 — so the item falls within Category 5 Part 2 and the
below-threshold route is unavailable.

**Not solely Apple operating-system cryptography.** Although CryptoKit provides most primitives, the
application implements its own key hierarchy and wire formats above them, and links **CryptoSwift**, a
third-party cryptographic library, for scrypt. The "OS encryption only, no documentation required"
treatment therefore does not apply.

---

## 4. No Category 5 Part 2 exemption applies

Each exemption was assessed against the shipping source.

| Exemption | Assessment |
|---|---|
| (a) Specially designed for **medical end-use** | Does not apply. The exemption addresses medical *equipment* incorporating controlled software; Fernlet is standalone consumer software. The cryptography is general-purpose privacy sealing — the identical `ColumnCrypto` type, differing only by an HKDF label, seals a worry-box note and a journal entry as readily as a cycle narrative — and is not designed for medical treatment or the practice of medicine. Fernlet is expressly **not** a medical device, and is presented as a wellness product throughout. |
| (b) **Copyright / IP protection** | Does not apply. No DRM, licence enforcement, or content-protection cryptography. |
| (c) Limited to **authentication, digital signature, or decryption** | Does not apply. Ed25519 envelope signatures would fall inside it, but the application also performs bulk **confidentiality** encryption of user content (journal text, photos, heart drops). The exemption requires the cryptography to be *limited to* the listed uses. |
| (d) **Banking or money transactions** | Does not apply. The in-app coin ledger and clothing shop are cosmetic; there is no payment rail and no StoreKit integration. |
| (e) **"Fixed" data compression or coding** | Does not apply. Compression exists in the wire format but the cryptography is not limited to compression or coding. |
| **Note 4** (cryptography ancillary to a primary non-infosec function) | Does not apply. The peer-to-peer social layer — encrypted person-to-person messaging, photo sharing and identity/trust ceremony — is a primary product function, not support for another function. Consumer applications offering user-to-user encrypted messaging are classified within Category 5 Part 2. |

---

## 5. Mass market status and eligibility to self-classify

**Note 3 to Category 5 — Part 2** is satisfied on each element:

- **Generally available to the public through retail-type transactions** — distributed through the
  Apple App Store to any member of the public. Free distribution qualifies; BIS's published guidance
  uses a free smartphone application as its example of a mass-market item.
- **Cryptographic functionality cannot easily be changed by the user** — algorithms, key sizes and
  parameters are compile-time constants. There is no cryptographic configuration surface, no
  plug-in cipher interface, and no user-selectable algorithm.
- **Designed for installation without further substantial supplier support** — ordinary App Store
  installation.
- **Sold in volume / no customer-specific customization** — a single build, identical for all users.

**Not "non-standard cryptography."** 15 CFR Part 772 defines the term as cryptography involving
*proprietary or unpublished* functionality, including algorithms **or protocols** not adopted by a
recognized standards body **"and have not otherwise been published."** The test is conjunctive.

Fernlet's *algorithms* are published international standards without exception. Several of its
*protocols* are bespoke — the heart-drop sealed-sender envelope, the wire framing, and the identity
and trust ceremony — and these are Noise-inspired rather than any standards-body protocol. However,
they are constructed entirely from published primitives, contain no secret or proprietary component,
and are **published in full**: the complete source is public under Apache-2.0, and the wire formats
are documented in the in-repository DocC documentation. The second prong of the definition is
therefore not met, and the item is not non-standard cryptography.

Accordingly the item is eligible for **self-classification under §740.17(b)(1)**, rather than falling
into §740.17(b)(3)(ii), which would require a classification request and a 30-day waiting period.

---

## 6. Publicly available status

Because the item is mass market and is **distributed free of charge**, it is *publicly available*.
BIS guidance states that a mass-market application made available free of charge is publicly
available, and that once the mass-market requirement has been satisfied by self-classification — a
step completed **once** — the item is then no longer subject to the EAR.

Independently, the corresponding **source code** is publicly available under Apache-2.0
(§742.15(b)(1)), which extends to the corresponding object code under §734.7(b) and the Note to
§734.3(b)(2)–(3).

**Ordering.** The Note to §740.17(b) provides that a mass-market item remains subject to the EAR
*until the applicable classification or self-classification requirements are fulfilled*. This
memorandum completes that step; publicly-available status attaches afterwards.

---

## 7. Filings and actions

| Item | Status |
|---|---|
| CCATS / classification request | **Not required** — self-classification eligible (§5) |
| BIS annual self-classification report | **Not required** as a recurring obligation. §740.17(e)(3) was amended 2021-03-29 to cover encryption *components* and *"executable software"*, which expressly excludes complete binary images of software running on an end item. One filing may be made once as a conservative measure; it is not annual. |
| §742.15(b)(2) notification | **Not required** — that notification applies only to published source performing non-standard cryptography (§5). Being sent voluntarily to `crypt@bis.doc.gov` and `enc@nsa.gov` with the repository URL, as a dated record that the source is published. |
| `ITSAppUsesNonExemptEncryption` | **`NO`** — App Store Connect's completed 2026-08-23 declaration required no document for the current non-France distribution. This is Apple's documentation-exempt result, not a statement that the app has no encryption. |
| App Store Connect encryption documentation | None required, except the French declaration below |
| France / ANSSI declaration | **Required if France is a release country** — triggered by the linked third-party scrypt implementation rather than by Apple OS cryptography. A separate regime; no BIS filing satisfies it. |
| Country restrictions | 5D992.c is AT-controlled only. No licence is required for export other than to Country Group E:1 embargoed destinations, which App Store distribution settings must exclude. |

**Timing.** The obligation attaches at the first export — the first distribution outside the United
States and Canada, **including TestFlight distribution to testers abroad**, which Apple treats as an
export. A TestFlight beta is invite-only and therefore **not** publicly available, so the release in
§6 does not apply during beta; this self-classification must be complete **before** the first
overseas tester. As of the date above, Fernlet has been distributed to no storefront and nothing is
owed to any government.

---

## 8. Open questions

Recorded honestly rather than resolved:

1. **The bespoke protocols and "non-standard cryptography."** §5 concludes the definition's
   conjunctive test is not met because the protocols are published. A stricter reader could focus on
   the "not adopted by a standards body" prong alone. If that reading prevailed, the item would fall
   under §740.17(b)(3)(ii) and require a classification request with a 30-day wait. This is the only
   question in this determination carrying material consequence.
2. **Open source and "easily changed by the user."** §740.17(b)(2)(i)(C)(2) and Note 3 both speak to
   cryptographic functionality that can easily be changed by the user. Publishing source under a
   permissive licence could be argued to permit that. The counter-argument is structural —
   §740.17(b)(2)(i)(B) singles out *non-publicly-available* source code for a classification
   requirement, which would be incoherent if publication pushed items into (b)(2) — and the shipped
   product exposes no cryptographic configuration. Not treated as settled.

Both warrant review by export-control counsel before large-scale or non-US commercial release.

---

## 9. Conditions on which this determination depends

This memorandum must be re-issued if any of the following changes:

- **Fernlet ceases to be free** — a purchase price, subscription or in-app purchase would remove the
  publicly-available basis in §6.
- **The source ceases to be published** — this would revive the "not otherwise published" prong in §5
  and could make the item non-standard cryptography.
- **A new cryptographic algorithm, library or protocol is introduced**, or an existing one is
  replaced with a proprietary or unpublished construction.
- **A paid or closed-source companion application** is distributed under this classification. Fernlet
  Coach in particular does **not** inherit this determination and requires its own.

---

**Signature** Michael Bowman Olay  
**Date** 08/23/2026
