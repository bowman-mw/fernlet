# Fernlet ↔ Fernlet Coach — Product & Technical Specification (V1)

**Date:** 2026-07-19 · **Status:** Draft for review — supersedes nothing; builds on
[Data-Provenance-Coach-Trust-2026-07-12.md](Data-Provenance-Coach-Trust-2026-07-12.md) (the trust
model) and the shipped Trainer Export (Social Phase 7). Covers **both apps**: the Fernlet-side
features and the new **Fernlet Coach** app.

**Decided 2026-07-19:** the primary remote coach↔trainee connection is the **hybrid iMessage +
CloudKit dead-drop** design (§3.3–3.4). Decisions D1, D2, and D3 are resolved accordingly.

> ✅ **SHIPPED 2026-08-12 — the manual exchange (the first slice of P0/P1).** The information
> exchange now exists end to end with the **clipboard as the transport**: "Share with a trainer"
> (relocated from Settings → Privacy & Data onto the **Move tab**) copies a training summary plus an
> instruction preamble, and a plan pasted back is review-gated into dated `PlannedWorkout` rows
> tagged `WorkoutPlanSource.coach`. Off by default behind `settings.coachExchangeEnabled`.
>
> What this deliberately builds *properly* rather than as a throwaway, so the Coach app only has to
> change the pipe:
> - **`CoachPlan v1` (§3.5) is real** — implemented in `FernletDomainModel/CoachPlan.swift`, bounded
>   and fail-closed, with the spec's schema plus one addition (below).
> - **The review gate (§F3 steps 2-4) is real** — `CoachPlanReviewView`: safety pass against
>   `WorkoutProfile` with per-exercise strikes, the D4 collision prompt, provenance stamped into the
>   row text, and a `TrainerAuditEvent` on import.
> - **The export bundle is the same `TrainerExportBundle`** the shipped `TrainerExportPayload` wire
>   seam already carries, extended with macro targets, training setup, and a per-exercise
>   progression rollup — so §F6's "share in person" gets those sections for free.
>
> **Editing an existing plan (owner addition, same day) — a partial down-payment on F5/§3.4's
> `trainerPlanDelta`.** The scenario is "I plan my month, then a coach adjusts or replaces it", so the
> exchange is two-way at the *row* level, not just the plan level:
> - The export now carries **upcoming planned workouts with their real `PlannedWorkout.id`s** (a
>   forward-looking window, `plannedDaysAhead`, defaulting to 35 days — one more than `maxDays`). A
>   coach cannot adjust a plan they cannot see, so this was a prerequisite, not a nicety.
> - `CoachPlan.edits: [CoachPlanEdit]` targets those ids with `adjust` | `replace` | `delete`. `adjust`
>   is a partial patch (nil fields keep their current value); `replace` must supply a full exercise
>   list; `delete` removes the planned row.
> - **What an edit can never reach:** anything LOGGED (only `plannedWorkouts` are searched), a target
>   that no longer exists (the user completed or deleted it — the message tells them to copy a fresh
>   summary), or a day before today. All three are blocking, never silently skipped.
> - An `edits`-only plan is valid — "adjust what I have" is a complete hand-off with no new days.
> - Edited exercises go through the **same** `WorkoutSafetyFilter` pass as new days, and the review
>   screen shows a before/after per change (accept-all, per the owner's call; the per-exercise safety
>   strikes remain, because those are safety rather than preference).
>
> This is deliberately NOT the full delta protocol of §3.4/F5: there is no `planID` + base-plan-hash
> binding, no diff-against-a-known-base, and no silent-arrival path. Targeting is by row id, which is
> enough for the manual channel and maps cleanly onto a signed delta later.
>
> **One schema addition beyond §3.5:** `CoachPlan.newExercises` (`CoachExerciseDefinition`), because
> the manual path sends **no exercise catalog** to the plan's author — so an author can name any
> exercise and must define it. Metadata (muscles + equipment + movement pattern) is **required, not
> optional**: those are exactly `WorkoutSafetyFilter`'s inputs, and defaulting any of them would let
> an imported exercise slip past a user's avoid list. Accepted definitions join a persisted custom
> catalog (`FernletSettings.customExercises` → `WorkoutExerciseCatalog`), cleared by "delete
> everything".
>
> **What this is NOT:** there is no signature, no pairing, no coach identity, and no trust basis on
> this path — a pasted plan is unauthenticated by construction and the UI says so. Everything in
> §3.1-§3.4 (originClass, the coach vault, App Attest, the link/dead-drop pipes) remains unbuilt.

---

## 1. Product summary

Fernlet Coach is a separate, closed-source, iOS-only app for personal trainers. A coach manages a
roster of trainees, builds 1–30-day workout plans in a workout creator, delivers plans to trainees
remotely over iMessage, and handles everything sensitive **in person only**. Fernlet (the open-source
trainee app) receives plans, review-gates them, runs them through the existing guided-workout
system, and shares training data back with the coach exclusively in person.

**Non-negotiable principles (inherited from Fernlet):**

1. **No servers anyone operates.** Apple-operated infrastructure (iMessage, App Store, the CloudKit
   public database, static universal-link hosting, App Attest verification chain) is acceptable;
   nothing the developer or user runs. Same standard as the send-heart decision.
2. **Sensitive data never travels remotely.** Nutrition detail, injury notes, session notes, photos,
   sickness/wellbeing — in-person proximity channel only (§6). The remote channels (iMessage link +
   CloudKit dead-drop) carry workout plans, plan deltas, and allowlisted system receipts only.
3. **Review-gated writes.** Nothing a coach sends applies silently. The trainee sees, edits if
   desired, and approves — reusing the existing guided-plan approval gate.
4. **Fail closed.** Unknown sender, wrong recipient, unknown version, failed decrypt → quarantine +
   honest error, never partial ingestion. Same posture as the trainer-export allowlist and the
   sealed-store decrypt seam.
5. **Provenance everywhere.** Everything ingested is stamped with origin class + sending identity +
   trust basis, carried at rest, revocable per source (memo §7).

---

## 2. Actors, roles, and messaging rules

| Actor | App | Can send workout messages | Can receive workout messages |
| --- | --- | --- | --- |
| **Coach** | Fernlet Coach | ✅ (to paired trainees; to other paired coaches) | ✅ (from other coaches — template sharing) |
| **Trainee** | Fernlet | ❌ — no compose surface exists in Fernlet | ✅ (from their paired coach(es) only) |

This encodes the two requirements "only coaches can send messages" and "coaches can send or receive
messages": Fernlet is strictly a receiver; Fernlet Coach is bidirectional so coaches can share plan
templates with each other (both parties must be coach-class paired). Trainees never compose; the
only trainee→coach remote signal is the system-generated, allowlisted status receipt of §3.4
(decided — **D2**).

"Send" is enforced three independent ways, not just by hiding UI:

1. **Cryptographically:** a plan is sealed to the recipient's X25519 key-agreement key, which a
   coach only possesses after a completed pairing ceremony. No pairing → nothing openable to send.
2. **By policy:** Fernlet accepts `trainerPlan`-family payloads only from keys pinned **coach-class**
   in the coach vault (the ceremony cross-check from memo §3.3). A friend key claiming coach is
   dropped.
3. **By product:** Fernlet has no coach-message compose UI at all.

---

## 3. Shared protocol foundations (both apps)

These are the wire-level pieces both apps implement. All of them extend existing, shipped machinery.

### 3.1 Identity & envelope (existing, extended)

- Both apps use the existing `IdentityService` key model: Ed25519 signing + X25519 key agreement,
  `seal(_:to:)` / `open(_:from:)` (ephemeral ECDH → HKDF-SHA256 → ChaCha20-Poly1305, forward
  secrecy), and `FernletIdentityEnvelope` (signed, replay-cached, `sealingRequiredTypes`
  fail-closed).
- **New (memo §3.2, phasing item 1):** signed `originClass` (`fernlet` | `coach`) added to the
  envelope's canonical bytes and to the `CanonicalSignatureSerializer` domain tags
  (`fernlet.canonical.identity-envelope.coach.v3` style). A coach signature can never validate as a
  friend envelope and vice versa.
- **Payload types:** the four reserved cases in `PayloadType` are the coach vocabulary —
  `trainerPlan` (`fernlet.trainer.plan.v1`), `trainerPlanDelta`, `workoutCompletion`,
  `workoutLiveUpdate` — plus the shipped `TrainerExportPayload` (`fernlet.trainer.export`, 2 MB
  cap). All already listed in `sealingRequiredTypes`; handlers are new work. One **new** case:
  `planReceipt` (`fernlet.trainer.receipt.v1`) for plan-status receipts (§3.4); day-completion
  receipts reuse the reserved `workoutCompletion` type.

### 3.2 Pairing ceremonies (memo §4–5, unchanged here)

- **Coach pairing is not friend pairing.** Separate **coach vault** (a coach-class sibling of
  `ProximityTrustVault`, records extended with `trustBasis: inPerson | remoteVerified` and the
  pinned App Attest receipt). The friend vault is untouched.
- **In-person (default):** proximity handshake on the coach channel (`MultipeerServiceType.trainer`
  = `"fernlet-coach"`, already reserved); Coach presents **App Attest**, Fernlet verifies offline
  against the pinned Apple root + Coach app-ID, pins the coach identity key coach-class.
- **Remote (fallback):** App Attest + short-authentication-string comparison over a live call.
- **Prototype first:** offline peer-side App Attest verification is the gating unknown (memo §9
  item 2). Nothing in §4–§6 ships before that prototype validates.
- Pairing is also when the trainee's key-agreement public key reaches the coach — the capability
  that makes remote plan-sending possible at all.

### 3.3 The coach↔trainee connection — hybrid iMessage + CloudKit

> ⚠️ **SUPERSEDED on the channel priority (owner, 2026-07-26).** This section, §3.6, §6 and §8 are
> written around the hybrid being primary. It is not. The **in-person mesh session is the primary
> channel**: coach and trainee meet, work out, and the coach hands over the next week's workouts plus
> any recipes, weekly. The hybrid below is the **secondary/off-week fallback** — for when a session is
> missed, so the trainee still has next week's workouts.
>
> Two consequences worth reading before building against this section: pairing/trust bootstrap now
> always happens **in person**, so the remote channel never has to establish trust for a new pair
> (which removes much of what §3.2's App Attest gate existed to solve); and the weekly cadence bounds
> the remote channel to covering a missed week or two.
>
> See "Coach channel model" in
> [Docs/Plan-Prekeys-ProtectedLoad-CoachMesh-2026-07-26.md](Plan-Prekeys-ProtectedLoad-CoachMesh-2026-07-26.md).
> **These four sections need revising to match before implementation.**

**This hybrid is the primary trainer↔trainee connection.** iMessage (a universal link) is the
human-visible delivery surface — the conversation, the summary text, the card. A CloudKit
public-database dead-drop (§3.4) is the programmatic layer underneath — large-plan overflow,
system receipts, silent deltas, and retraction. Both pipes carry the identical sealed envelope;
the crypto story never varies by transport. Sensitive data uses neither (§3.6, §6).

**Platform constraint that shapes the message half:** an interactive iMessage bubble (`MSMessage`)
is bound to the app extension that created it. A chip minted by a *Fernlet Coach* Messages
extension, when tapped by the trainee, prompts the trainee to install **Fernlet Coach** — not
Fernlet. There is no way to make one app's MSMessage open a different app. Therefore the wire
artifact is **not** an MSMessage; it is a **Fernlet universal link**, which iMessage renders as a
rich link card and which opens Fernlet directly on tap.

**Message anatomy (what the trainee's conversation shows):**

1. A short plain-text summary line composed by Coach — e.g.
   `“5-day strength block from Coach Sam — tap to open in Fernlet.”` This is the always-visible
   workout summary (requirement 1.3: summary still shown in iMessage, even to the wrong recipient
   or someone without Fernlet).
2. The universal link: `https://<fernlet-domain>/plan#v1.<base64url(deflate(envelope))>` — or,
   for plans over the inline budget, `…/plan#v1r.<dead-drop token>` (see the delivery rule below).
   - The **fragment** (`#…`) carries the payload (or the dead-drop token). Fragments are never
     sent to the web host, so even the static host learns nothing.
   - iMessage renders the link as a card using the domain's **static** OG metadata — a generic,
     branded "Fernlet Workout Plan" chip (same image for every plan). Per-plan dynamic previews
     would require a server rendering per-URL metadata — excluded in V1 (open decision **D6**).
   - Tapped with Fernlet installed → Fernlet opens straight into the plan-review flow. Without
     Fernlet → the static page, which explains the app and links to the App Store.

**Payload structure — partial encryption (requirement 1.3):**

```
FernletIdentityEnvelope (signed by coach Ed25519, originClass=coach, payloadType=trainerPlan)
├─ plaintext, signed metadata (visible to any Fernlet that opens the link):
│    payloadSummary   — plan title, day count, coach display name   ← the non-sensitive part
│    recipientFingerprint — the intended trainee
│    createdAt / expiresAt
└─ payload: sealed to the trainee's X25519 key  ← only the intended trainee can open
     CoachPlan v1 (§3.5) — includes the receiptToken used for §3.4 receipts
```

- **Intended recipient:** signature verifies, sender is coach-class in their vault, fingerprint
  matches, seal opens → plan-review flow.
- **Any other Fernlet user** (forwarded, group chat, wrong contact): the seal cannot open and/or
  the fingerprint doesn't match → Fernlet shows the error screen — required copy **"Incorrect
  message sent"** (copy refinement tracked as **D9**) — showing only the plaintext summary, never
  partial plan content.
- **Unpaired coach key:** quarantined per memo §3.1; Fernlet explains that plans require pairing
  with the coach first (in person or verified call) and offers nothing else.
- **Expired / replayed / malformed / future schema version:** fail closed. Unknown schema versions
  use the freeze/park pattern (`EnumDecodeCompat` precedent) — tell the user to update Fernlet,
  don't guess.

**Delivery rule (inline vs. dead-drop):** if the envelope after deflate+base64url is ≤ **16 KB**
(a 30-day structured plan compresses to a few KB), it rides inline in the fragment — the link is
self-contained and works with no cloud dependency. Larger plans put nothing in the fragment but a
random 256-bit dead-drop token; Fernlet fetches the envelope from the CloudKit record it names
(§3.4) and continues through the identical verify chain. The summary text and card are the same
either way; Coach picks the path automatically at compose time.

**The card's title ("link name"):** the preview card's title is whatever the page at the URL
declares — Messages fetches the page (fragments are never sent) and renders its metadata; a link
has no display name of its own. Per-plan titles like "7/19–7/26 Workouts" therefore need one of:

1. **Prototype first (D11):** Coach supplies `LPLinkMetadata` (title = "7/19–7/26 Workouts",
   plan-card artwork) via `UIActivityItemSource` when handing the link to the share sheet. If
   Messages carries that metadata into the *sent* bubble — documented behavior only guarantees the
   share-sheet header, so this is a cheap must-test — per-plan titles cost nothing and no page
   changes are needed.
2. **Fallback (works today):** thirty pre-generated per-length static pages — `/plan/7d/` titled
   "7-Day Workout Plan · Fernlet" — with the exact dates in the coach's summary text directly
   above the card.
3. **Rejected:** per-date static pages (~11k/year, and plan dates leak into host request logs) and
   an edge renderer (an operated server that would see every plan's title).

### 3.4 The CloudKit dead-drop channel (the programmatic half)

The send-heart pattern, promoted to the coach connection: a CloudKit **container shared by both
apps** (same team), **public database**, no operated server. One record = one sealed, signed
`FernletIdentityEnvelope` — byte-identical to what the link fragment would otherwise carry.

- **Capability addressing:** record names are random 256-bit tokens; possessing the token (from a
  link fragment, or minted inside a sealed plan) is the only way to find a record. No queries by
  content — fetch by exact record ID only. The single queryable field is an opaque
  per-relationship `channelTag` minted at pairing (known only to the pair), so
  `CKQuerySubscription` can deliver **push without a server** while Apple-visible metadata stays
  pseudonymous.
- **Uses (V1 vocabulary — a closed set):**
  1. **Overflow plan delivery** — plans over the 16 KB inline budget (§3.3 delivery rule).
  2. **Receipts (trainee → coach, system-generated only):** `planReceipt` events
     `delivered | accepted | declined`, and `workoutCompletion` events ("day N completed"). The
     sealed plan carries a random `receiptToken`; Fernlet writes each sealed receipt to an address
     derived from it, and Coach picks them up by subscription or poll. Receipt contents are a
     **hard allowlist** — plan ID, event kind, day index, timestamp — never RPE, notes, nutrition,
     edits, or free text. Governed by a per-coach consent toggle (F2); off simply means the coach
     learns outcomes at the next in-person sync.
  3. **Silent deltas:** a `trainerPlanDelta` for an accepted plan may arrive by subscription push
     with no new message bubble — the review gate (F5) is unchanged; only the pipe is silent.
  4. **Retraction:** Coach deletes a not-yet-picked-up record; the link then resolves to an honest
     "this plan was retracted" state.
- **Sign-in reality:** public-DB reads need no iCloud account; writes do. The coach must be signed
  into iCloud to send; a trainee without iCloud still receives plans (reads) but cannot emit
  receipts — the coach's status view degrades to "known at next in-person sync."
- **Hostile-input posture:** the public DB is writable by any iCloud user, so nothing is parsed
  before signature + coach-class verification; size caps are enforced before decode; unknown
  schema versions freeze/park; one replay cache spans both pipes (same envelope IDs).
- **Garbage collection:** the public DB has no server-side TTL — each app deletes only the records
  it created. Coach sweeps delivered/expired plan records (mirroring `expiresAt`) on launch;
  Fernlet sweeps its own aged receipt records opportunistically.

### 3.5 `CoachPlan v1` — the 1–30-day plan schema

A compact, canonical, versioned structure (new `Codable` type in `FernletDomainModel`), designed to
map 1:1 onto the existing engine types:

```
CoachPlan v1
  planID (UUID), schemaVersion, title, coachDisplayName
  startPolicy: onAccept | fixedDate(dayKey)
  days: [CoachPlanDay]            // 1...30, enforced both ends
    CoachPlanDay { dayIndex, title, isRestDay, sessions: [CoachSession] }
      CoachSession { title, kind (SessionKind raw), notes?, conditioning?,
                     exercises: [CoachExercise] }
        CoachExercise { name, catalogID?, sets: Int, reps: String,
                        restSeconds?, guidance? (e.g. "RPE 7", "2s pause") }
```

Mapping onto shipped types: `CoachExercise` → `PrescribedExercise` (with `restSecondsOverride` —
the field already documented as "the coach app will write"); `CoachSession` →
`SessionSuggestion`; a day → `WorkoutProgram.DayPlan`; persisted days → `PlannedWorkout` rows
tagged `WorkoutPlanSource.coach` (both already exist). Rest defaults, when the coach doesn't
override, come from `WorkoutRestGuidance`. Exercise names may reference the shared catalog
(`WorkoutExercises.json`) by ID or be free-text.

### 3.6 What may NEVER ride the remote channels

Hard allowlist, mirrored in both apps and in tests: the iMessage link carries `trainerPlan` and
`trainerPlanDelta` only; the dead-drop carries those two plus `planReceipt` and the allowlisted
`workoutCompletion` receipt — **and nothing else**. Trainer exports (nutrition, wellbeing,
injuries), session notes, photos, and anything else sensitive are in-person-only (§6) — enforced
at the payload-type level, not by UI convention.

---

## 4. Fernlet (trainee side) — feature spec

### F1. Universal-link / open-URL infrastructure — *new*

Fernlet today has **no** URL scheme, universal links, or associated domains (deep-linking is the
internal `PendingIntentSheet` token). New work:

- Associated-domains entitlement + static AASA hosting on the chosen domain (**D6** decides the
  domain; hosting is a static file — no operated server).
- `onOpenURL` / user-activity handling that routes `/plan` links into a new
  `CoachPlanInbox` service, reusing the `PendingIntentSheet` consume-once pattern for cold/warm
  launch (120 s expiry, single consumption).
- A custom URL scheme as a dev/simulator fallback only; universal link is the product path.

### F2. Coach management (Settings → "Your coach") — *new*

- List paired coaches: display name, fingerprint, **trust basis badge** ("paired in person" /
  "verified on a call"), paired date, last plan received.
- Pair flow: in-person proximity ceremony (default) and remote SAS flow — both per memo §4.
- **Revoke** a coach: drops the pairing, stops all future ingestion, and (user choice) either keeps
  or archives previously accepted plans — never silently deletes logged history. Mirrors the
  provenance/revocation stance in memo §7.
- Per-coach toggles: allow live-session sharing (F6), allow plan deltas (F5), send status
  receipts (§3.4 — asked once at first plan accept; no receipts flow until answered).

### F3. Plan receive → review → accept — *new (the core loop)*

1. Link opens → resolve the payload (inline fragment, or dead-drop fetch for overflow plans,
   §3.3–3.4) → verify chain: signature → coach-class check → fingerprint → seal open → schema.
   Every failure path has a distinct, honest screen; the wrong-recipient screen shows "Incorrect
   message sent" plus the plaintext summary only; a retracted plan says so plainly.
2. **Review screen:** day-by-day preview of the full 1–30-day plan (sessions, exercises,
   sets × reps, rest, coach notes), with the coach's name and trust badge. The trainee can edit any
   session before accepting (same editor as `GuidedWorkoutEditorSheet`) — coach proposes, user
   disposes (memo §6: review-gated, nothing applies silently).
3. **Safety pass before accept:** the plan is run through the existing safety filter against the
   trainee's `WorkoutProfile` (`avoidedMuscles`, `avoidedMovements`, injury notes). Conflicts are
   flagged inline ("Coach programmed barbell squats; you avoid knee-dominant movements") — the
   trainee can strike or keep each flagged item. Nothing is silently removed or silently kept.
4. **Accept →** materialize: one `PlannedWorkout` per session, tagged `WorkoutPlanSource.coach`,
   anchored to day keys per `startPolicy`. Store the plan's provenance stamp (coach identity,
   trust basis, accepted date) with it.
5. **Decline / Report:** decline discards; report records a `TrainerAuditEvent` and offers
   revoke. Accept and decline emit a `planReceipt` when receipts are enabled (§3.4).
6. **Active-plan collision:** receiving a plan while a coach plan is active prompts
   replace-remaining-days vs. keep-current (**D4**); replace never rewrites already-completed days.

### F4. Coach plan in the daily flow — *extends existing*

- On a coach-plan day, the Move tab surfaces the coach's session through the **existing approval
  gate** (`approveTodaysGuidedPlan`) — labeled "From your coach" per the provenance-aware handling
  rule, replacing the self-generated suggestion for that day.
- The guided runner and Live Activity work unchanged; `restSeconds` comes from the coach's
  overrides. Completions log with `WorkoutPlanSource.coach` and `loggedFromGuidedSession`, and a
  completed coach-plan day emits an allowlisted `workoutCompletion` receipt when receipts are
  enabled (§3.4).
- Missed days: plan days don't shift automatically; the trainee can slide the remaining plan
  forward (explicit action, recorded). Skipped coach days are visible as skipped.
- Trainee edits after accept are allowed (their body, their data) but marked "edited by you" so the
  in-person review with the coach is honest.

### F5. Plan deltas — *new, after F3*

`trainerPlanDelta` over the same iMessage link, **or arriving silently via dead-drop push
(§3.4)**: a signed, sealed patch referencing `planID` + base plan hash ("swap day 4 session",
"deload week 3"). Same review gate as F3 — a delta renders as a before/after diff and applies only
to not-yet-completed days. Silent arrival never applies anything — it badges the Move tab and
waits for review. Deltas to unknown or superseded plans fail closed.

### F6. In-person data share to coach — *extends shipped Trainer Export*

- The shipped `TrainerExportView` consent flow (opt-in toggles, never-shared list) stays the single
  consent surface. New: a **"Share in person"** transport next to the file `ShareLink` — sends
  `TrainerExportPayload` over the proximity coach channel, sealed to the paired coach key,
  originClass-checked. The "coming soon" footer becomes real.
- *As of 2026-08-12* that screen lives on the **Move tab** and is already two-way (clipboard out,
  paste back). Adding the mesh transport is a third button beside the existing two, not a new
  screen — and the bundle it sends already carries the targets / equipment / progression sections
  the coach dashboard (C6) wants.
- **Live session mode (later phase):** with the per-coach toggle on and the coach physically
  present (active proximity session), stream `workoutLiveUpdate` (current exercise/set/rest from
  `GuidedWorkoutRunState`) so the coach's device mirrors the run. Session-scoped, never stored on
  the coach side beyond the session note the coach writes, ends when proximity ends.

### F7. Provenance & audit surfaces — *extends existing*

- Everything coach-ingested shows its provenance stamp in detail views ("From Coach Sam, paired in
  person, accepted 19 Jul").
- `TrainerAuditEvent` log (already surfaced via `store.trainerAuditEvents`) gains entries for:
  plan received / accepted / declined / retracted / delta applied / receipt sent / export shared /
  live session / revocation.
- Delete-all-data funnel must clear: coach vault, plan inbox, materialized coach `PlannedWorkout`s,
  any pending universal-link token, the `channelTag` subscriptions, and any dead-drop receipt
  records this device created (same class of bug as the guided-run app-group wipe fixed pre-merge
  on 2026-07-19 — add it to `DeleteAllDataTests`).

### F8. App Clip — *new target: the install funnel for the link*

A minimal `FernletClip` App Clip so a recipient **without Fernlet** who taps the link gets an
instant native preview and App Store handoff instead of the static web page.

- **The fact that shapes everything: clip users are unpaired by construction.** Pairing requires
  the full app, and when Fernlet is installed the full app opens instead of the clip. So the clip
  **can never decrypt a plan** — it parses only the envelope's plaintext (`payloadSummary`: title,
  day count, coach name) and makes no authenticity claims (it has no coach vault to verify class
  against). It is a preview + funnel, deliberately nothing more.
- **Target & size:** bundle ID `<parent>.Clip`; links only the minimal modules (envelope parse +
  UI). Digital invocations allow up to 50 MB (iOS 17+), but aim ≤10 MB. The S3 wall applies — the
  clip must not link `AIProviders`/`CloudKitSync`/`Private*` modules; add the clip target to
  `Scripts/spm-wall-check.sh`.
- **Web + App Store Connect plumbing:** the AASA file gains an `appclips` entry; the `/plan*`
  pages add the `apple-itunes-app` meta tag with `app-clip-bundle-id`; register the default App
  Clip experience in ASC (card image 1800×1200, title ≤30 chars, subtitle, "View" action). The
  Messages card then renders as the richer App Clip card.
- **Invocation gate (P0 prototype):** the clip receives the URL via `NSUserActivity` — **verify
  the URL fragment survives App Clip invocation** before committing. If iOS strips it, the
  fallback is dead-drop-token-in-path: confidentiality holds (the blob is sealed) but
  `payloadSummary` becomes readable to anyone with host logs — prefer the fragment.
- **Handoff:** the clip stores the pending link in the shared app group and presents `SKOverlay`
  for install; on first launch, full Fernlet consumes it and enters the normal F3 flow (for this
  always-unpaired user, that means the pairing explainer).
- **Screens:** three (see §10) plus one terminal error variant. Test via Settings → Developer
  local experiences and TestFlight clip testing.

---

## 5. Fernlet Coach (coach side) — feature spec

Organizing principle (per requirement 3): the app has two top-level spaces — **Trainees** (roster,
everything per-trainee lives behind that trainee's entry) and **Creator** (plans and templates,
trainee-agnostic until assigned).

### C1. Trainee roster

- One entry per paired trainee: display name, fingerprint, trust-basis badge, paired date, active
  plan + progress at a glance, last in-person sync date.
- Add-trainee = the pairing ceremony (§3.2), coach side: advertise on the `fernlet-coach` service,
  present App Attest, receive the trainee's keys. Remote-pairing flow shows the SAS to read aloud.
- Offboard: revoke keys and **wipe that trainee's entire sealed partition** (notes, photos,
  received data) with an explicit destructive confirmation. Export-before-offboard offered.

### C2. Per-trainee protected area (requirement 2)

- **Every byte of trainee data is sealed at rest in a per-trainee partition:** key =
  HKDF(coach master content key, "trainee:" + fingerprint) — the `ColumnCrypto` per-label pattern,
  one label per trainee. Photos go in a sealed media store (the `PrivateMediaStore` pattern).
- The coach master content key sits behind a passcode/biometric lock — the `FernletLockService`
  design (scrypt KDF, verifier-only persistence, wrapped content key). App-level lock on launch
  and on background, configurable grace period.
- **No iCloud sync of trainee partitions in V1.** Backup = sealed backup file export (the
  `SealedBackupCoordinator` pattern), restorable onto a replacement device. Multi-device coach is
  **D8**.
- Provenance stamps (which trainee, which ceremony, when received) are stored with the data, and
  the trainee-side revocation story has a mirror: if a trainee revokes the coach, the coach app
  marks the relationship ended and prompts (does not force) data deletion.

### C3. Workout creator

- **Plan builder:** compose 1–30 day plans (`CoachPlan v1`): day grid → sessions → exercises with
  sets / reps / rest / guidance. Rest pre-fills from `WorkoutRestGuidance` and is overridable per
  exercise (that's `restSecondsOverride` on the wire).
- **Reuse the open engine:** exercise catalog (`WorkoutExercises.json`), split catalog
  (`WorkoutSplitCatalog`'s 14 splits) as starting scaffolds, movement/muscle metadata. Licensing of
  open FernletKit modules inside the closed Coach app is **D5**.
- **Templates:** save any plan as a template; duplicate-and-tailor per trainee; template library
  with tags (goal, days/week, equipment).
- **Per-trainee tailoring guardrails:** when assigning to a trainee whose `TrainingProfile`
  (received via in-person export) lists avoided muscles/movements or injuries, conflicting
  exercises are flagged at author time — the same safety pass the trainee sees at accept time, run
  earlier so plans arrive clean.

### C4. Sending plans

- **Send via iMessage:** pick trainee → pick plan/template → preview exactly what the trainee will
  see (summary line + review screens) → seal + sign → hand off to Messages. Two hand-off styles,
  same wire artifact (§3.3): share-sheet into Messages, and an optional Coach **Messages compose
  extension** that inserts the summary text + link (compose convenience only — it never mints an
  MSMessage bubble, avoiding the wrong-app tap-through trap).
- **Send in person:** same plan over the proximity coach channel when together — no size cap, no
  iMessage dependency; useful at the first session.
- **Coach↔coach template sharing:** identical envelope, recipient is another coach-class-paired
  key; received templates land in the template library marked with origin. Coach↔coach pairing
  requires both sides to attest.
- Sent-plan status per trainee, live via receipts (§3.4): sent → delivered → accepted / declined →
  per-day completion ticks. If the trainee has receipts off (or no iCloud), status shows "known at
  next in-person sync." **Retract** is available until a plan has been picked up.

### C5. Session notes (requirement 3)

- Per trainee, per session: rich text + photos, timestamped, optionally linked to a plan day or a
  received workout log. Explicitly allowed to contain sensitive content — which is why they live in
  the sealed per-trainee partition (C2) and **never leave the device** except inside the coach's
  own sealed backup. No sending notes to anyone, in V1 not even to the trainee (D10 tracks
  "share a note with its trainee, in person" as a possible later feature).
- Photo capture goes straight into the sealed media store — never the system photo library.
- Quick-note templates (form check, PRs, pain flags, next-session focus) to make in-gym capture
  one-handed and fast.

### C6. Received-data dashboard (per trainee)

- Ingests `TrainerExportBundle` (shipped format: workouts with RPE, per-day nutrition summaries,
  training-safety context, opt-in hydration/sleep/sickness/wellbeing) received **in person** over
  the coach channel.
- Views: adherence vs. assigned plan (completed / edited / skipped days), RPE and volume trends,
  nutrition overview when shared, injury/avoid-list surface. All computed on device, stored in the
  trainee's sealed partition, provenance-stamped.
- The dashboard clearly labels the data window and its consent scope ("Sam shared 14 days,
  workouts + nutrition, on 19 Jul") — mirroring the Fernlet-side consent screen so what the coach
  sees is exactly what the trainee agreed to.

### C7. Live session mode (later phase, with F6)

- Coach-side mirror of an in-person guided run: current exercise, set count, rest countdown,
  streamed as `workoutLiveUpdate` over the active proximity session. Coach can jot a session note
  against any moment. On-the-spot plan tweaks go out as a `trainerPlanDelta` — which the trainee
  still approves on their device (the review gate never disappears, even face to face).

### C8. Coach-side audit & trust surfaces

- Per-trainee audit log (pairings, sends, receipts, revocations) mirroring `TrainerAuditEvent`.
- Own-identity screen: coach key fingerprint (for the trainee to verify), App Attest status,
  re-attestation if the key rotates.

---

## 6. Channel policy summary (the one-table version)

| Content | iMessage link | CloudKit dead-drop | In-person proximity | At rest (Coach) |
| --- | --- | --- | --- | --- |
| Workout plan / delta | ✅ sealed+signed, ≤16 KB inline | ✅ sealed+signed (overflow, silent deltas, retraction) | ✅ | plaintext-equivalent (not trainee-sensitive) |
| Plan summary (title, days, coach name) | ✅ plaintext but signed | envelope metadata only | ✅ | — |
| Status receipts (allowlisted, system-generated) | ❌ | ✅ sealed, consent-gated | — (subsumed by sync) | sealed per-trainee partition |
| Trainer export (nutrition, wellbeing, injuries…) | ❌ **never** | ❌ **never** | ✅ sealed+signed | sealed per-trainee partition |
| Session notes + photos | ❌ never (created coach-side, never sent) | ❌ never | ❌ V1 | sealed per-trainee partition |
| Live workout updates | ❌ | ❌ | ✅ session-scoped, not persisted | only what a note captures |
| Hearts / social / friend anything | ❌ | ❌ | coach-class ❌ (friend caps stay friend-only) | — |

---

## 7. Decisions — resolved and open

| # | Decision | Status / recommendation |
| --- | --- | --- |
| **D1** | Remote transport | **DECIDED 2026-07-19 — hybrid.** Universal link (payload inline in the fragment) as the human-visible carrier + CloudKit public-DB dead-drop as the programmatic layer (overflow, receipts, silent deltas, retraction) — §3.3–3.4. MSMessage chips rejected: they'd open Fernlet Coach, not Fernlet, on tap. |
| **D2** | Meaning of "coaches can send or receive" | **DECIDED 2026-07-19.** Coach↔coach template sharing; trainees never compose. The only trainee→coach remote signal is the system-generated, allowlisted receipt (§3.4). |
| **D3** | Remote back-channel for completions/read-receipts | **DECIDED 2026-07-19 — in scope.** CloudKit dead-drop receipts (§3.4): system-generated only, hard content allowlist, per-coach consent toggle, graceful fallback to in-person sync when receipts are off or no iCloud. |
| **D4** | New plan arrives while one is active | **DECIDED 2026-07-19.** Prompt — replace remaining days or keep current; never rewrite completed days. |
| **D5** | Reusing open-source FernletKit modules inside closed-source Coach | **DECIDED 2026-07-19.** The repo is Apache-2.0 (LICENSE at root); closed-source Coach may reuse FernletKit freely, including future outside contributions. |
| **D6** | Universal-link domain + preview card | **DECIDED 2026-07-19.** The domain is **fernlet.com** (owned; currently unhosted/empty — needs a static host, e.g. GitHub/Cloudflare Pages, which also hosts the privacy-policy page). Static AASA (app + appclips entries) + per-length static pages. No edge server. Per-plan titles: see D11. |
| **D7** | Coach app business model / App Store positioning | Out of scope for this spec; note that Coach being paid-up-front fits "closed-source, no accounts, no subscriptions infra" — and Fernlet itself was decided **always free** (2026-07-19), so Coach is the monetization surface if any. |
| **D8** | Coach multi-device | **DECIDED 2026-07-19.** Single device V1 + sealed backup file. Multi-device would need the mesh-offline-sync work already on the Fernlet roadmap. |
| **D9** | Error copy | **DECIDED 2026-07-19.** Shipping copy: **"This workout was sent to someone else"** + explanation; the requirement's phrase is the accepted meaning, not the literal string. |
| **D10** | Sharing a session note with its trainee (in person) | **DECIDED 2026-07-19.** Not in V1; tracked as a candidate follow-up. |
| **D11** | Per-plan link card titles ("7/19–7/26 Workouts") | **Prototype:** sender-supplied `LPLinkMetadata` from Coach's share flow — if Messages carries it into the sent bubble, per-plan titles are free. Likely fallback: per-length static pages + exact dates in the coach's message text (§3.3). Rejected: per-date static pages (date leak to host logs) and an edge renderer (operated server). Harness ready: `Fernlet/LinkMetadataPrototypeView.swift` + [D11-LinkMetadata-Prototype.md](D11-LinkMetadata-Prototype.md). |

---

## 8. Phasing

Order respects the memo's own phasing (§9) and puts the riskiest unknown first.

1. **P0 — Foundations & the gating prototype.** Signed `originClass` + domain-separation v3 in the
   envelope/serializer; `CoachPlan v1` schema in `FernletDomainModel`; **offline peer-side App
   Attest verification prototype** (go/no-go for the whole coach-genuineness story); D5 license
   decision; two cheap link-experience prototypes — App Clip fragment survival (F8 gate) and
   sender-supplied `LPLinkMetadata` titles (D11).
2. **P1 — Pairing + the hybrid plan pipeline (MVP).** Coach vault + in-person ceremony both sides
   (minting the per-relationship `channelTag`); Fernlet universal-link infra (F1) +
   receive/review/accept (F3) + daily-flow surfacing (F4); dead-drop foundation — shared
   container, capability addressing, overflow delivery, retraction, GC (§3.4); Coach roster (C1),
   minimal creator (C3 without templates), send via iMessage + in person (C4). *Milestone: a real
   coach programs a real 2-week block remotely.*
3. **P2 — The sensitive half + receipts.** Coach lock + per-trainee sealed partitions (C2);
   session notes + photos (C5); in-person trainer-export transport (F6 first bullet) +
   received-data dashboard (C6); receipts + `CKQuerySubscription` push with the per-coach consent
   toggle (§3.4, F2); provenance/audit surfaces (F7, C8); delete-all + revocation flows both
   sides.
4. **P3 — Iteration loop.** Plan deltas including silent dead-drop arrival (F5, C4), templates +
   coach↔coach sharing, safety-pass author-time guardrails (C3), remote SAS pairing; App Clip
   target + web/ASC plumbing (F8).
5. **P4 — Live session mode** (F6/C7) and polish; revisit D3 (dead-drop receipts) and D10.

**Testing spine (both apps):** the §6 channel-policy table as an executable allowlist test (the
`S3BoundaryTests` pattern); wrong-recipient / unpaired / expired / replay / future-version fixtures
for the link pipeline; dead-drop hostile-input fixtures (unsigned or foreign records at a guessed
address, oversized records, receipt-allowlist violations, pickup-vs-retract races); ceremony
cross-check tests (friend key claiming coach = dropped); Coach partition-isolation tests (trainee
A's key never opens trainee B's rows); delete-all funnels.

---

## 9. Explicitly out of scope (V1)

Trainee-*composed* messaging of any kind (the §3.4 system receipts are the only trainee→coach
signal); Android/coach-web; scheduling/calendar/payments; coach editing
trainee data directly (coaches propose, trainees accept — always); any remote transport for
trainer exports, notes, or photos; server-rendered per-plan link previews (D11's client-side
metadata prototype is the only sanctioned path to per-plan titles); coach access to anything outside
the trainer-export allowlist (journal, cycle, photos, friends — the "never" list is unchanged).

---

## 10. Screen inventory (design kickoff)

Grouped by app. ▲ marks a state/variant of the screen above it rather than a standalone
navigation. "Reuses" notes a shipped Fernlet surface the design should extend, not reinvent.

### Fernlet (trainee) — ~17 screens

**Plan receive flow** (entered from the universal link or App Clip handoff)

1. **Resolving** — brief branded loading state while dead-drop fetch / verify runs (inline links
   resolve near-instantly; design for sub-second).
2. **Plan review** — coach name + trust badge, plan title + date range, day-by-day accordion
   (sessions → exercises, sets × reps, rest), inline safety-conflict flags, actions: Accept /
   Edit / Decline. The single most important new screen.
3. ▲ **Session edit sheet** — reuses `GuidedWorkoutEditorSheet` as-is.
4. ▲ **Active-plan collision prompt** — replace remaining days vs. keep current (D4).
5. **Error family** — one layout, six contents: *Incorrect message sent* (wrong recipient; shows
   plaintext summary only) · *Not paired yet* (pairing explainer + CTA) · *Expired* · *Retracted*
   · *Update Fernlet* (future schema) · *Unreadable link*.
6. **Delta review** — before/after diff of affected days, Accept / Decline.

**Coach management (Settings → Your Coach)**

7. **Coach list** — paired coaches with trust badges; empty state that sells the feature.
8. **Coach detail** — trust basis + paired date, toggles (receipts / deltas / live sharing),
   audit-log link, Revoke (destructive confirm with keep-vs-archive choice for accepted plans).
9. **Pairing, in person** — proximity search → App Attest check progress → fingerprint compare →
   name + confirm (fingerprint-compare pattern exists in proximity UI today).
10. ▲ **Pairing, remote** — SAS display + "read this aloud on the call" compare step.
11. **Coach audit log** — filterable `TrainerAuditEvent` list.

**Daily flow (Move tab)**

12. **"From your coach" day card** — labeled variant of the existing approved-plan card, plus a
    plan progress strip (day N of M).
13. ▲ **Delta-pending badge** state on that card.

**In-person share**

14. **Share in person** — extends the shipped `TrainerExportView`: nearby-coach-found state,
    sending progress, sent confirmation.

**App Clip**

15. **Clip: plan summary** — plaintext summary card only, no authenticity claims.
16. **Clip: what is Fernlet** — one-screen positioning blurb.
17. **Clip: Get Fernlet** — `SKOverlay` install + terminal error variant ("This plan link can't
    be shown").

### Fernlet Coach — ~23 screens

**Onboarding**

1. **Welcome / positioning.**
2. **Lock setup** — passcode + Face ID (the `FernletLockService` pattern).
3. **Identity created** — coach fingerprint display + "your trainees verify this" explainer.
4. **Backup offer** — sealed backup file export.

**Trainees tab**

5. **Roster** — trainee cards (name, active-plan progress with receipt ticks, last in-person
   sync), Add Trainee CTA, empty state.
6. **Pairing (coach side)** — advertise + App Attest presentation progress → fingerprint compare
   → name the trainee.
7. **Trainee hub** — segmented container: Overview · Plans · Notes · Data · Profile.
8. ▲ **Overview** — active plan status (sent → delivered → accepted → day ticks), quick actions
   (send plan, new note), receipts-off state ("known at next sync").
9. ▲ **Plans** — sent history with status chips; Retract on not-yet-picked-up plans.
10. ▲ **Notes** — session-note list (search, date-grouped).
11. **Note editor** — rich text, photo capture straight into the sealed store, quick-note
    templates (form check / PR / pain flag / next-session focus). One-handed in-gym use is the
    design constraint.
12. ▲ **Data** — received-data dashboard: adherence vs. plan, RPE/volume trends, nutrition
    summary when shared, consent-scope banner ("Sam shared 14 days, workouts + nutrition,
    19 Jul"); empty and locked states.
13. ▲ **Profile** — `TrainingProfile` surface (injuries, avoid-lists, goal), trust info, Offboard
    (destructive wipe confirm + export-first offer).

**Creator tab**

14. **Template library** — grid with tags (goal, days/week, equipment), origin badges on
    coach-shared templates, empty state.
15. **Plan settings** — title, length (1–30), start policy.
16. **Day grid** — 1–30 day overview, rest-day toggles, duplicate-day.
17. **Day / session editor** — session list → exercise editor (catalog picker, sets/reps
    steppers, rest override showing the `WorkoutRestGuidance` default).
18. ▲ **Safety-conflict flags** — when a trainee is attached and the plan hits their avoid-list.
19. **Preview as trainee** — renders exactly the F3 review screen (screen 2 above).
20. **Send flow** — pick trainee → message preview (summary text + card mock) → hand-off
    (Messages share sheet / in-person proximity) → sent confirmation.
21. **Share template with a coach** — pick paired coach → confirm.

**Settings & later phases**

22. **Coach settings** — own identity (fingerprint + attest status), lock, backup
    export/restore, audit log, about/privacy.
23. **Live session (P4)** — live mirror (current exercise / set / rest countdown) with a
    quick-note bar; post-session note prompt.

**Shared design-system pieces (both apps):** trust badges (in-person / remote-verified),
provenance labels ("From your coach" / "Shared by a coach"), receipt tick marks, the six-content
error-family layout, and the fingerprint display + compare pattern.
