# ``FernletExchange``

The portable exchange core: versioned recipe and workout-plan packets, the bounded card and
`MSMessage.url` envelope the Messages extension sends, and the App Group catalog and review inboxes
the extension and the containing app share.

## Overview

FernletExchange is the one FernletKit product the Messages extension links
(`.library(name: "FernletExchange", …)` in `FernletKit/Package.swift`), and it is kept small enough
to live in a process Messages hosts: Foundation, CryptoKit, Compression (Apple's system framework,
for the version-2 envelope's DEFLATE, since 2026-09-24) and `FernletDomainModel` (with its
`FernletFoundation` dependency) and nothing else — no repository, no store, no sync, no HealthKit,
no Proximity, no `Private*` module. The containing app links it too, through the umbrella
`FernletKit` product, for three things: the Files and Shortcuts exchange (`ExchangeIntentService`,
`ExchangeFileIntents`, the `.fernletrecipe` / `.fernletplan` document types declared in
`FernletExchangePackets.swift`), the app half of the Messages hand-off
(`FernletMessagesCatalogPublisher`, `FernletMessagesRecipeImport`, the two review sheets), and the
recipe share codec.

**The rule that shapes the whole module: a packet carries data, never a decision.** Nothing here
opens a repository, resolves a duplicate, applies a collision policy, schedules a workout or saves a
recipe. Every type validates bytes and stops. Import policy — the replay ledger
(`ExchangeImportLedger`), the calendar preview, the safety filter, the duplicate policy, the review
gate — lives in the app, which is the only process that can see the canonical stores. That is what
lets both processes reject malformed input *before* either considers touching a store, and what keeps
the extension's footprint down to "can render a card and write one inbox record".

### Packets

``RecipeExchangePacket`` and ``WorkoutPlanExchangePacket`` are the two portable payloads. Each is a
versioned JSON document (`fernlet.exchange.recipe` / `fernlet.exchange.workout-plan`) with a
`packetID`, an `originContentID` and a lowercase-hex SHA-256 `contentHash` over every other field.
The hash is **integrity, not authentication**: it detects a truncated or edited file and proves
nothing about who produced it (signing and trust live in `ProximityKit`). It also gives the app's
replay ledger a stable identity, which is why a forwarded message still maps to the same import.

A workout plan is version 1. A recipe is version 1 when it is one part — byte-for-byte what every
earlier build wrote — and **version 2 when it is made in parts** (2026-09-24): a salad and its
homemade dressing carry the payload's `components` partition, which an older reader could not keep
(it re-hashes the payload it decoded, without the unknown key), so the version is the gate and an
older build refuses the file as a format it does not know rather than calling it corrupt. **The
content-hash scheme is versioned with it**: both schemes are SHA-256 over the canonical pre-image,
the pre-image carries the version, so neither can verify the other's packets, and each version may
carry only its own shape — scheme 1 never holds `components`, scheme 2 always does
(`ExchangeMultipartRecipeTests` checks the scheme-2 digest against a pre-image it builds itself).

Their encodings are **frozen**. `ExchangeCoder` pins `.sortedKeys` and `.withoutEscapingSlashes`, and
the private `RecipeHashInput` / `WorkoutPlanHashInput` pre-images are the hashed bytes — adding,
renaming or retyping a field in either changes the digest of every already-exported file, which then
fails ``ExchangePacketError/invalidHash``. `WorkoutPlanHashInput` transitively freezes `CoachPlan`'s
coding keys, because the whole plan is inside the digest.

``ExchangeRecipePayloadBuilder`` and ``ExchangeWorkoutPlanBuilder`` build the payloads from domain
values only (a `RecipeDefinition` plus its `FoodItem`s; one day's `PlannedWorkout`), and
``ExchangeRecipePayloadValidator`` holds the recipe bounds the app-side share codec historically
enforced (servings, name and note length, ingredient and step counts), plus the shape of a multipart
recipe's `components` partition when a payload carries one. The recipe builder has two forms (multipart
recipes, 2026-09-24). ``ExchangeRecipePayloadBuilder/payload(for:foodItems:)`` is what EVERY build can
read: byte-identical to earlier builds for a one-part recipe, and a multipart recipe comes out flattened
(whole recipe, section-labelled steps, no `components` key) — what an older reader makes of a multipart
share; no shipping wire sends it any more. ``ExchangeRecipePayloadBuilder/componentPayload(for:foodItems:)``
adds the partition. It is the form for the paste text, the mesh, and ``RecipeExchangePacket``, which
versions its own hash (above). It also carries an ingredient's fractional grams
(`SharedRecipeIngredient.preciseMacros`, 2026-09-29) when its food has them. That key is ignorable
on the paste text and the mesh, but not inside a hash: ``RecipeExchangePacket`` strips it before
hashing in both versions and refuses a packet that carries it, and `payload(for:foodItems:)` strips it
too. A file, Shortcut or Messages card therefore rounds a 3.4 g ingredient to whole grams. A web-imported recipe
currently exchanges with **no ingredients** — its ingredient lines live in `webImport`, which the
builder does not read — and `FernletExchangeTests.webImportedRecipesShareWithNoIngredientsAPinnedDefect`
pins that as a known defect awaiting an owner decision, not a specification.

### The Messages envelope

``ExchangeMessageEnvelope`` is the serverless `MSMessage.url` payload: a `data:` URL carrying one
packet, and the bounded ``ExchangeCardMetadata`` that describes it for the bubble. The card is
**display only**: the receiving side decodes the packet through its own `decode`
(``ExchangeMessageEnvelope/validatedPayload()``) and derives the card from it, so a hand-edited
bubble cannot misdescribe what an import would do.

There are two wire versions, and every build from 2026-09-24 on reads both:

- **Version 2** — written since 2026-09-24. The packet travels as raw JSON inside a small document
  (`format`, `formatVersion`, the packet under `recipe` or `workoutPlan`, and a workout plan's
  `scheduledStartDayKey`), which is deflated (raw DEFLATE — Apple Compression's `.zlib`, no zlib
  header) behind a four-byte header — magic `F`, frame version `2`, the document's length as a
  big-endian `UInt16` — and base64url-encoded ONCE, unpadded, after the prefix
  `data:application/vnd.fernlet.exchange.v2,`. No card travels: the receiver derives it.
- **Version 1** — the 2026-09-23 build. The envelope's own JSON (the packet base64'd into
  `packetData`, the card beside it) base64'd again after `data:application/vnd.fernlet.exchange+json;base64,`.
  Read, never written: a card already in a conversation must keep opening, and an envelope whose
  card disagrees with its packet is still rejected.

The prefix picks the reader, and each reader accepts only its own encoding. Version 1's two base64
passes cost 16/9 of the packet's size; version 2's single pass over deflated JSON is why the same URL
now carries about three times as much: on a realistic sixteen-ingredient recipe, version 1 ran out
at five steps (a 2.5 KB packet) and version 2 carries all forty (7.8 KB, deflated to a 3.5 KB frame).
`ExchangeMessageEnvelopeV2Tests` measures that, and pins two version-1 cards minted by the
2026-09-23 build — and the version-1 content-hash pre-images, as literals — so the old wire cannot
silently stop opening.

**The inflate is bounded before it starts.** DEFLATE reaches about 1,032:1, so a 3.7 KB frame could
otherwise claim almost 4 MB inside a process Messages hosts. The frame's declared length is checked
against ``ExchangeLimits/maxMessageDocumentBytes`` (one packet at
``ExchangeLimits/maxMessagePacketBytes``, 12 KiB, plus a 1 KiB margin) before a byte is inflated; it
then becomes the inflater's hard ceiling — the output closure throws the moment the running total
would pass it — and the inflated count must equal it exactly, so a truncated stream or one that lies
about its length is refused rather than half-read. The Swift overlay's `OutputFilter` does the work,
so the seam needs no unsafe pointer and no Power-of-10 allowlist entry.

The bounds in ``ExchangeLimits`` come from Apple, not from taste. Apple documents that an
`MSMessage` URL "cannot be longer than 5,000 characters"; ``ExchangeLimits/maxMessageURLCharacters``
is that number, and both envelope bounds are derived from it: ``ExchangeLimits/maxMessageFrameBytes``
(3,719 — the largest version-2 frame whose unpadded base64url fits after the 41-character prefix) and
``ExchangeLimits/maxMessageEnvelopeBytes`` (3,711 — the version-1 equivalent after its 50-character
prefix). ``ExchangeLimits/maxMessagePacketBytes`` is the review inbox's per-record cap, so every card
that opens can be handed to Fernlet for review. Until 2026-09-23 the envelope bound was 16 KiB, so a
large recipe passed every check here and then failed inside `MSConversation.insert` with nothing to
say why; now anything too large is refused up front with ``ExchangePacketError/tooLarge``. The limit
is still unmeasured on hardware — the first item of `Docs/MessagesExtensionReleaseChecklist.md` —
and raising it needs that measurement, never the file limits (64 KiB recipes, the coach-plan paste
limit for plans).

### The App Group documents

Three coordinated files in the `group.MBO.Fernlet` container, all written atomically with
`.completeFileProtection` and read through `NSFileCoordinator`, because two processes touch them:

- ``FernletMessagesCatalogFileStore`` — `FernletMessages/MessagesCatalog.json`, the bounded,
  privacy-filtered ``FernletMessagesCatalog`` (at most 100 recipes and 100 one-day workout plans,
  1 MiB) that **the app publishes** after a durable save and **the extension only reads**. It is the
  extension's whole view of the user's library: ``FernletMessagesRecipePicker`` and
  ``FernletMessagesWorkoutPicker`` search and order it, and nothing here can widen access to a
  repository. Because it is the whole view, the app's publisher leaves out an item these types
  refuse (a recipe past the 24-serving bound, a plan title past 120 characters) instead of failing
  the publish — one such item used to freeze the extension on a stale catalog.
- ``FernletMessagesInboxStore`` and ``FernletMessagesWorkoutInboxStore`` — `FernletMessages/Inbox/`,
  where **the extension enqueues** an independently validated received packet
  (``FernletMessagesInboxRecord`` / ``FernletMessagesWorkoutInboxRecord``) and **the app consumes**
  it once its review is presented. Twenty records, seven days, 384 KiB each; expired records are
  purged at launch and before every enqueue.

The extension hands off with ``FernletMessagesInboxLink`` — `fernlet://messages/recipe?id=<uuid>` or
`…/workout?id=<uuid>` — which carries an **opaque inbox identifier and nothing else**: never a
packet, never a title, so the deep link leaks nothing a URL log could keep.

Production never falls back: if the App Group container cannot be resolved, the stores report
failure rather than writing somewhere less protected.

**Wiping.** All three documents are content the user can delete. The app's "Delete everything"
funnel clears the catalog (`messagesCatalogPublisher.clear`, unconditionally since 2026-09-23) and
both inboxes (`FernletMessagesRecipeInboxCoordinator.clear`); see `Docs/PrivacyWipeCoverage.md`. The
extension itself persists nothing outside these files.

### Position relative to the walls

On the **S3 wall**: a portable, non-walled Layer-1 target over `FernletDomainModel`; it names no
sealed type and reaches no `Private*` store, and `MessagesExtensionBoundaryTests` pins that the
extension imports nothing but this module and Apple UI frameworks. On the **no-tracking wall**: it
holds no HTTP client and names no host — the only URLs it builds are `data:` and `fernlet:` URLs. On
the **localization wall**: every string here is a token (formats, wire keys, the `fernlet` scheme)
and stays English; display copy lives in the extension's `FernletMessagesCopy` and the app. On the
**Power-of-10 wall**: every loop is bounded — by a catalog or inbox limit, or by a fixed list — and
the one decompression is bounded by a declared length checked before it starts (R3's framing rule;
`SealedPayloadFraming` is the precedent).

**Concurrency.** The target declares no default isolation, and every type is `nonisolated`: the
packets, records, cards and limits are `Sendable` values, and the three file stores are plain
structs holding a `FileManager` and a URL, because the MainActor-default extension, the
MainActor-default app and its App Intents all call them. Cross-process safety comes from file
coordination, not from an actor — the other writer is a different process.

## Topics

### Packets and payloads

- ``RecipeExchangePacket``
- ``WorkoutPlanExchangePacket``
- ``ExchangeRecipePayloadBuilder``
- ``ExchangeRecipePayloadValidator``
- ``ExchangeWorkoutPlanBuilder``
- ``ExchangePacketError``

### The Messages envelope

- ``ExchangeMessageEnvelope``
- ``ExchangeMessagePayload``
- ``ExchangeCardMetadata``
- ``ExchangePacketKind``
- ``ExchangeLimits``

### The App Group catalog

- ``FernletMessagesCatalog``
- ``FernletMessagesRecipeCatalogEntry``
- ``FernletMessagesWorkoutCatalogEntry``
- ``FernletMessagesCatalogFileStore``
- ``FernletMessagesCatalogLimits``
- ``FernletMessagesRecipePicker``
- ``FernletMessagesWorkoutPicker``

### The review inboxes and hand-off link

- ``FernletMessagesInboxStore``
- ``FernletMessagesInboxRecord``
- ``FernletMessagesWorkoutInboxStore``
- ``FernletMessagesWorkoutInboxRecord``
- ``FernletMessagesInboxLimits``
- ``FernletMessagesInboxLink``
- ``FernletMessagesInboxTarget``
- ``FernletMessagesInboxDestination``
