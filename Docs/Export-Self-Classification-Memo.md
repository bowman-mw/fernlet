# Encryption Self-Classification Memorandum — Fernlet (iOS)

**Item:** Fernlet, iOS application (bundle identifier `MBO.Fernlet`)
**Classification:** **ECCN 5D992.c** — mass market encryption software
**Authorization:** License Exception ENC, self-classification under **15 CFR §740.17(b)(1)**
**Determined:** 2026-08-19 · **Revision 2 drafted:** 2026-10-17 — *unsigned until the owner signs it below*
**Determined by:** Michael Bowman Olay, sole developer *(confirm the legal name/entity exactly as it appears on the App Store listing before this is relied on)*
**Retention:** five years past the date of the last export — 15 CFR §762.6(a)

> **Purpose.** This memorandum is the record of a self-classification. Under §740.17(b)(1) nothing is
> filed with BIS to *create* a classification; the obligation is to have made a defensible
> determination and to be able to produce it. This document is that determination. It is engineering
> and regulatory analysis by the developer, **not legal advice**, and §8 lists the two questions that
> warrant counsel.
>
> Supporting analysis, with citations: [Export-Compliance-Encryption.md](Export-Compliance-Encryption.md).

> **Revision 2 (draft, 2026-10-17) — why it exists.** §9 requires this memorandum to be re-issued when a
> new cryptographic protocol is introduced. Since revision 1 was signed on 2026-08-23 the peer-to-peer
> link moved from MultipeerConnectivity to **QUIC with TLS 1.3** over Apple's Network.framework, with
> app-minted self-signed P-256 certificates (MultipeerConnectivity left the source on 2026-09-22). The
> peer-to-peer code also moved into its own public Apache-2.0 repository, and new sealed surfaces were
> added: every period log in a sealed store, Sealed backup v2, session photos held until chosen, sealed
> photo backup, and rotating presence tags. §2, §3, §5, §6 and §9 are revised and §10 lists every change.
> **The determination does not change**: every primitive and the new transport protocol are published
> standards, and the source of every bespoke protocol is public. The signed revision 1 is preserved as
> `20d404b8:Docs/Export-Self-Classification-Memo.md`.

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
   text, every menstrual-cycle log, intimate-activity notes, and photos (including photos from an
   in-person session, held sealed until the user chooses which to keep) — so that this material is
   protected independently of the device passcode.
2. **End-to-end encrypted peer-to-peer exchange** between users who have met in person, over a
   short-range local link: QUIC with TLS 1.3 (Apple's Network.framework) on the local Wi-Fi network or
   Apple peer-to-peer Wi-Fi, with NearbyInteraction ranging. It carries recipe sharing, friend photos,
   companion clothing, group activities, short "heart" messages, and the presence signal between
   friends. Inside the TLS channel the application signs and seals its own messages (§3).
3. **Client-side encryption of backups** in the user's own iCloud account — journal, cycle and
   intimacy records and the user's own photos — and of an offline "heart drop" delivered through a
   CloudKit public database. The developer can read none of it.

Distribution is via the Apple App Store, **free of charge**, with no purchase price, subscription,
in-app purchase or advertising. The complete source, including all cryptographic source code, is
published under the Apache License 2.0 at <https://github.com/bowman-mw/fernlet>, and the
peer-to-peer package the app links, ProximityKit, at <https://github.com/bowman-mw/proximitykit>
(Apache-2.0; the app pins one tagged release, `0.1.1` at the date of revision 2). Both of these are
permanent product commitments, not launch conditions.

---

## 3. Cryptographic functionality

All primitives are published international standards. There is no proprietary or home-grown cipher,
hash, key-derivation function or key schedule.

| Component | Primitive | Standard | Purpose |
|---|---|---|---|
| `FernletCrypto/ColumnCrypto` | ChaCha20-Poly1305, HKDF-SHA256 | RFC 8439, RFC 5869 | Per-column sealing of journal / worry / intimacy text and of every period log in the sealed cycle store |
| `PrivateMediaStore/MediaAtRestCrypto` | AES-256-GCM | NIST SP 800-38D | At-rest sealing of meal, progress, private and held session photos |
| `FernletLock/FernletLockService` | scrypt (N=65536, r=8, p=1), via CryptoSwift; ChaCha20-Poly1305 key wrap; SHA-256 verifier | RFC 7914, RFC 8439, FIPS 180-4 | Passcode (and duress PIN) → content-key wrapping key |
| `FernletLock/SecureEnclaveContentKeyWrap` | ECIES over a Secure Enclave P-256 key (X9.63 KDF with SHA-256, AES-GCM), via the Security framework | SEC 1, NIST P-256 | Hardware device-binding of the content key |
| `ProximityKit` transport (all three radios) | QUIC with TLS 1.3, via Network.framework; app-minted, never-persisted self-signed X.509 certificates, ECDSA P-256 with SHA-256, valid 24 hours, minted fresh for each session or presence epoch | RFC 9000, RFC 9001, RFC 8446, RFC 5280, FIPS 186 | Encrypted local channel between nearby devices |
| `ProximityKit` mesh channel introduction | Ed25519 signatures over both peers' keys and nonces and a SHA-256 hash of the TLS 1.3 exporter secret | RFC 8446 §7.5, RFC 8032, FIPS 180-4 | Peer authentication bound to the specific TLS channel (TLS itself accepts any certificate; the application authenticates) |
| `ProximityKit/IdentityService` | Ed25519 signing; X25519 ECDH; sealing = ephemeral X25519 → HKDF-SHA256 → ChaCha20-Poly1305; group-key wrap = X25519 → HKDF-SHA256 → AES-GCM | RFC 8032, RFC 7748, RFC 5869, RFC 8439, SP 800-38D | Per-device peer identity, signed and sealed envelopes, pair secret |
| `ProximityKit` mesh content | AES-256-GCM; per-recipient content-key wrap X25519 → HKDF-SHA256 → AES-GCM | SP 800-38D, RFC 7748, RFC 5869 | Group metadata and routed items (friend photos) |
| `FernletSocial` presence tags | HMAC-SHA256 over an X25519 pair secret and a 15-minute epoch, truncated | RFC 2104, RFC 7748 | Rotating identifiers that let only friends recognise each other |
| `FernletSocial/HeartDropSealer` | X25519 ECDH → HKDF-SHA256 → ChaCha20-Poly1305, one-time prekeys; HMAC-SHA256 record tag | RFC 7748, 5869, 8439, 2104 | Sealed-sender offline heart-drop envelopes |
| Sealed backup v1/v2, sealed photo backup | AES-256-GCM under a key from HKDF-SHA256 over a random 32-byte escrow secret (stored as an X25519 key in iCloud Keychain; no key agreement is performed); SHA-256 writer tags and content hashes | SP 800-38D, RFC 5869, FIPS 180-4 | Client-side-encrypted backup sets in the user's iCloud |
| Duress recovery | The content key sealed to a custodian with `IdentityService` sealing | as above | Recovery after a duress lock |
| Moderation, message filter, exchange packets, fingerprints | SHA-256 | FIPS 180-4 | Content hashing (no secret) |
| `WebScrapingKit/EphemeralWebSession` | TLS, via `URLSession` | — | Outbound web lookups; Apple OS cryptography |

**Key lengths exceed the Cryptographic Note thresholds** — symmetric keys are 256-bit and asymmetric
key agreement/signature is Curve25519 and P-256 — so the item falls within Category 5 Part 2 and the
below-threshold route is unavailable.

**Not solely Apple operating-system cryptography.** Apple frameworks provide most primitives —
CryptoKit, the Security framework (Secure Enclave ECIES, certificate identities) and Network.framework
(QUIC/TLS 1.3, `URLSession` TLS). But the application implements its own key hierarchy, wire formats
and X.509 certificate encoder above them, and links **CryptoSwift**, a third-party cryptographic
library, for scrypt. The "OS encryption only, no documentation required" treatment therefore does not
apply.

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

Fernlet's *algorithms* are published international standards without exception, and since revision 2
so is its peer-to-peer *transport protocol*: QUIC and TLS 1.3 are IETF standards, provided by the
operating system. Several of its *application-layer protocols* are bespoke — the heart-drop
sealed-sender envelope, the wire framing, the identity and trust ceremony, the mesh channel
introduction bound to the TLS exporter, and the presence-tag derivation — and these are Noise-inspired
rather than any standards-body protocol. However, they are constructed entirely from published
primitives, contain no secret or proprietary component, and are **published in full**: the complete
source of both repositories is public under Apache-2.0, and the wire formats are documented in each
repository's DocC documentation. The second prong of the definition is therefore not met, and the item
is not non-standard cryptography.

Accordingly the item is eligible for **self-classification under §740.17(b)(1)**, rather than falling
into §740.17(b)(3)(ii), which would require a classification request and a 30-day waiting period.

---

## 6. Publicly available status

Because the item is mass market and is **distributed free of charge**, it is *publicly available*.
BIS guidance states that a mass-market application made available free of charge is publicly
available, and that once the mass-market requirement has been satisfied by self-classification — a
step completed **once** — the item is then no longer subject to the EAR.

Independently, the corresponding **source code** — the app's and ProximityKit's — is publicly
available under Apache-2.0 (§742.15(b)(1)), which extends to the corresponding object code under §734.7(b) and the Note to
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
- **The source ceases to be published** — either repository, or a ProximityKit release the app pins
  whose source is not public. This would revive the "not otherwise published" prong in §5 and could
  make the item non-standard cryptography.
- **A new cryptographic algorithm, library or protocol is introduced**, or an existing one is
  replaced with a proprietary or unpublished construction.
- **A paid or closed-source companion application** is distributed under this classification. Fernlet
  Coach in particular does **not** inherit this determination and requires its own.

---

## 10. Revision history

**Revision 1** — determined 2026-08-19, signed 08/23/2026. Preserved as
`20d404b8:Docs/Export-Self-Classification-Memo.md`.

**Revision 2** — drafted 2026-10-17 against `main` 20d404b8 and ProximityKit `0.1.1` (e09affe4). It records
these changes:

- **Transport.** MultipeerConnectivity → QUIC/TLS 1.3 through Network.framework, with app-minted
  self-signed ECDSA P-256 certificates. The mesh is the friend radio cut over on 2026-09-21; the presence
  and recipe radios moved under the same plan; MultipeerConnectivity was deleted on 2026-09-22.
- **New P-256 use.** P-256 now also signs the TLS certificates (ECDSA), not only the Secure Enclave key.
- **New protocols over published primitives.** The mesh channel introduction (Ed25519 bound to the TLS
  exporter) and the presence tags (HMAC-SHA256).
- **New sealed surfaces using primitives already listed.** Every period log in the sealed cycle store,
  Sealed backup v2, held session photos, sealed photo backup, and duress recovery.
- **Corrections to revision 1's table.** The sealed backup's escrow key is used only as an HKDF input,
  with no X25519 key agreement. SHA-512 is not used. `HeartDropSealer` lives in FernletKit's
  `FernletSocial`. `URLSession` TLS is not the only OS-level cryptography.
- **Source location.** ProximityKit moved to its own public Apache-2.0 repository; §2, §6 and §9 now name
  both repositories.

The classification, the authorization and every filing answer in §7 are unchanged. The transport
change alters none of App Store Connect's four encryption questions: QUIC/TLS is Apple OS encryption,
and no proprietary algorithm was added.

---

**Revision 1 — Signature** Michael Bowman Olay  
**Date** 08/23/2026

**Revision 2 — Signature** ______________________ *(unsigned draft — the owner signs and dates to re-issue)*  
**Date** ______________________
