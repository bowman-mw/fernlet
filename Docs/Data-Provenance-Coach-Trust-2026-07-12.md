# Data Provenance & Coach Trust — Design Memo (2026-07-12)

**Status:** Draft for review. No code yet. Supersedes nothing; extends the mesh/identity design in
[FernletSpecificationV3.md](FernletSpecificationV3.md) and the proximity subsystem.

## 1. Goal

When a device receives data over the mesh (or the coach's online channel), it must know **where the
data came from** — genuine **Fernlet**, genuine **Fernlet Coach**, or **something else** — and enforce a
policy accordingly. This is a *closed ecosystem* (only Fernlet and Fernlet Coach are legitimate
participants) built as *open-source software* (the Fernlet app is public and self-buildable; Fernlet
Coach is closed-source, iOS-only).

## 2. The honest security frame

There are two goals inside "confirm the origin," with opposite feasibility:

- **(A) Disambiguation, routing, tamper-evidence, policy** — never confuse a Coach message for a Fernlet
  one, parse/route each correctly, reject cross-app or out-of-policy data, and carry provenance.
  **Fully achievable**, no server, cross-platform, open-source-safe.
- **(B) Anti-impersonation of a specific app binary** — cryptographically prove a message came from the
  *genuine, unmodified* app. **Impossible for an open-source app** (any baked-in secret is public), and
  only achievable for a *closed-source* app via hardware-backed platform attestation.

This design takes **all of (A)** unconditionally, and gets **(B) exactly where it matters** by exploiting
an asymmetry (§5).

## 3. Origin model

### 3.1 Origin classes

Every envelope carries a signed **origin class**, a small closed set:

- `fernlet` — produced by a Fernlet app instance (a friend, or the user's own other device).
- `coach` — produced by a Fernlet Coach app instance.
- (implicit) **unrecognized** — anything that fails verification or whose class conflicts with how its
  sender was paired. Never ingested; quarantined and surfaced to the user as an unrecognized source.

### 3.2 Signed origin class + per-class domain separation

The origin class (and its schema version) is added to the **signed canonical bytes** of
`FernletIdentityEnvelope`, and it participates in the **domain-separation tag** — the same technique
`CanonicalSignatureSerializer` already uses per message type (`fernlet.canonical.*.v2`). Consequences:

- A signature minted for a `coach` envelope can never validate as a `fernlet` envelope, and vice versa.
- A relay / MITM cannot rewrite the origin claim without breaking the sender's signature (tamper-evident
  in transit).
- The claim is authenticated **to the sending identity** — but on its own it is still *self-declared*
  (an identity could lie about its own class). §3.3 removes that.

### 3.3 Class ↔ ceremony cross-check (the anti-escalation guarantee)

The receiver verifies the **claimed origin class matches the trust class the sender's key was paired
under** (§4). A key paired as a *friend* that sends an envelope claiming `coach` is dropped. This is what
makes the self-declared tag trustworthy for the class dimension: class is verified against *how you
paired*, not against what the message asserts. A friend can never escalate to coach over the wire.

## 4. Trust ceremonies (origin = how the key was paired)

Origin trust is anchored in the **pairing ceremony**, not the app binary.

### 4.1 Friend (existing, unchanged)

In-person proximity handshake → `fernlet` / friend-class vault entry. Low-sensitivity social
capabilities only (§6).

### 4.2 Coach (new) — separate, higher-trust, distinct from the friend vault

A coach is **not** a friend and does not use the friend vault. Two pairing paths:

- **In-person (default, recommended).** Proximity handshake on the coach channel. During it, Coach
  presents **App Attest** and Fernlet verifies it is the genuine official Coach build (§5), then pins the
  coach's identity key as **coach-class**.
- **Remote (fallback).** Same **App Attest** step (attestation is channel-independent), **plus** a
  **short authentication string** the user and coach compare on a live video/voice call (defeats a
  key-exchange MITM). Full coach data set — the combination is strong. *(Conservative alternative, not
  recommended: remote unlocks a reduced set until a first in-person meeting elevates it.)*

Every coach relationship records its **trust basis** (`in-person` vs `remote-verified`), shown to the
user and carried in provenance (§7).

## 5. iOS App Attest — where (B) is bought, and why it's free of the open-source conflict

The sensitive flow is **user → coach** (nutrition + workout logs). So the party that must prove it is
genuine — to protect that data — is the **Coach app** (the receiver). Coach is **closed-source and not
self-buildable**, so it can use attestation **with no open-source conflict and nobody locked out**.

- **Coach → Fernlet:** Coach attests (App Attest) → strong app-genuineness. App Attest chains to Apple's
  public root, so Fernlet can verify it **peer-side, offline** — pin Apple's App Attest root + the Coach
  app-ID, issue a fresh challenge during pairing, verify the attestation, pin the attested key. **No
  server** (fits the no-servers principle). *Risk: this is an off-label use of App Attest (designed for
  app → your own server); prototype and validate offline peer verification before committing.*
- **Fernlet → Coach:** the open-source Fernlet app **never attests**. Coach trusts the user via the
  **in-person-confirmed identity key** — exactly the "in-person confirmation before sharing" rule.

Net property: the sensitive data moves online, but only ever to a key confirmed in person (or via
live-call SAS), running an app attested as genuine. Remote impersonation cannot reach it.

*Caveat: closed source alone is not the security (a baked key can be reverse-engineered) — the value is
that a closed Coach app can additionally use hardware-backed attestation without the self-build problem.*

## 6. Per-(origin-class, capability) policy

Deny-by-default, both directions. The receiver checks `(originClass, capability)` against a fixed table;
anything not listed is dropped. This is the inbound mirror of the existing fail-closed trainer-export
allowlist.

| Capability | Direction | friend-class | coach-class |
| --- | --- | --- | --- |
| hearts, presence, friend-state, activities, clothing shop, photos, moderation | fernlet↔fernlet | ✅ | ❌ |
| social recipe share | fernlet→fernlet | ✅ (labeled "shared by a friend") | — |
| nutrition (calories + nutrients), workout logs | user → coach | ❌ | ✅ (outbound to a coach key only) |
| coach recipe | coach → user | ❌ | ✅ (labeled "from your coach") |
| coach workout / plan | coach → user | ❌ | ✅ |
| **coach adjustment** (writes plan/targets) | coach → user | ❌ | ✅ **review-gated** — coach proposes, user accepts; nothing applies silently |
| coach message | coach → user | ❌ | ✅ |

**Provenance-aware handling:** a `recipe` from coach-class and a `recipe` from friend-class are the same
payload type but different origin — the app labels and routes them differently. Origin class is not just
allow/deny; it changes presentation and handling.

## 7. Provenance tagging & revocation

Anything ingested is stamped with **origin class + sending identity + trust basis + accepted date**, and
that tag is carried with the data at rest — not just checked at receipt. The user can always see "logged
via Fernlet Coach (in person, since 3 May)" and **revoke a source**, which drops the pairing and stops
future ingestion. Mirrors the device-local, never-synced stance of the existing ledgers.

## 8. What this does and does not defend against (stated plainly for an open-source project)

**Defends against:** cross-app confusion; a friend escalating to the coach channel; an unpaired/unknown
key injecting anything; a MITM rewriting origin in transit; a fake app impersonating Coach at pairing
time (attestation); remote harvesting of nutrition/workout data (sealed to an in-person/SAS-confirmed,
attested coach key only); silent plan writes (review-gate).

**Does not defend against (inherent, accepted):** a person who **self-builds a modified Fernlet client
and legitimately completes the friend ceremony** with a consenting user — they can send *friend-class*
(low-sensitivity) data; they still cannot reach coach-class capabilities. This residual is intrinsic to
open source and is bounded to low-sensitivity social data by the class model.

## 9. Open items / phasing (suggested)

1. **Envelope + serializer:** add signed `originClass` + schema and per-class domain separation.
2. **Coach vault + ceremony:** separate coach-class trust store; in-person pairing with App Attest
   pin; remote pairing with App Attest + SAS; record trust basis. **Prototype offline peer verification
   of App Attest first** — it gates the whole coach-genuineness guarantee.
3. **Policy table + inbound allowlist:** enforce `(originClass, capability)`; review-gate coach
   adjustments.
4. **Provenance tagging + per-source revocation UI.**

Order 1 → 2(prototype) → 3 → 4; each is independently shippable, and (1) + (3) already deliver all of
goal (A) even before coach attestation lands.
