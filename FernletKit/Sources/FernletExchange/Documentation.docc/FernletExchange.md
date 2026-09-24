# ``FernletExchange``

The portable exchange core: versioned recipe and workout-plan packets, the bounded card and
`MSMessage.url` envelope the Messages extension sends, and the App Group catalog and review inboxes
the extension and the containing app share.

## Overview

FernletExchange is the one FernletKit product the Messages extension links
(`.library(name: "FernletExchange", …)` in `FernletKit/Package.swift`), and it is kept small enough
to live in a process Messages hosts: Foundation, CryptoKit and `FernletDomainModel` (with its
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
versioned JSON document (`fernlet.exchange.recipe` / `fernlet.exchange.workout-plan`, version 1)
with a `packetID`, an `originContentID` and a lowercase-hex SHA-256 `contentHash` over every other
field. The hash is **integrity, not authentication**: it detects a truncated or edited file and
proves nothing about who produced it (signing and trust live in `ProximityKit`). It also gives the
app's replay ledger a stable identity, which is why a forwarded message still maps to the same
import.

Their encodings are **frozen**. `ExchangeCoder` pins `.sortedKeys` and `.withoutEscapingSlashes`, and
the private `RecipeHashInput` / `WorkoutPlanHashInput` pre-images are the hashed bytes — adding,
renaming or retyping a field in either changes the digest of every already-exported file, which then
fails ``ExchangePacketError/invalidHash``. `WorkoutPlanHashInput` transitively freezes `CoachPlan`'s
coding keys, because the whole plan is inside the digest.

``ExchangeRecipePayloadBuilder`` and ``ExchangeWorkoutPlanBuilder`` build the payloads from domain
values only (a `RecipeDefinition` plus its `FoodItem`s; one day's `PlannedWorkout`), and
``ExchangeRecipePayloadValidator`` holds the recipe bounds the app-side share codec historically
enforced (servings, name and note length, ingredient and step counts). A web-imported recipe
currently exchanges with **no ingredients** — its ingredient lines live in `webImport`, which the
builder does not read — and `FernletExchangeTests.webImportedRecipesShareWithNoIngredientsAPinnedDefect`
pins that as a known defect awaiting an owner decision, not a specification.

### The Messages envelope

``ExchangeMessageEnvelope`` is the serverless `MSMessage.url` payload: a `data:` URL whose body is
the base64 of a small JSON document holding the packet bytes plus bounded ``ExchangeCardMetadata``
for the bubble. The card is **display only**: the receiving side re-decodes `packetData` through the
packet's own `decode` (``ExchangeMessageEnvelope/validatedPayload()``) and re-derives the card from
it, and an envelope whose card does not equal the canonical one is rejected, so a hand-edited bubble
cannot misdescribe what an import would do.

The bounds in ``ExchangeLimits`` come from Apple, not from taste. Apple documents that an
`MSMessage` URL "cannot be longer than 5,000 characters"; ``ExchangeLimits/maxMessageURLCharacters``
is that number, and ``ExchangeLimits/maxMessageEnvelopeBytes`` (3,711) is derived from it — the
largest envelope whose base64, after the 50-character prefix, still fits. Until 2026-09-23 the
envelope bound was 16 KiB, so a large recipe passed every check here and then failed inside
`MSConversation.insert` with nothing to say why; now it is refused up front, and the composer's
answer is the Files export. The limit is still unmeasured on hardware — the first item of
`Docs/MessagesExtensionReleaseChecklist.md` — and raising it needs that measurement, never the file
limits (64 KiB recipes, the coach-plan paste limit for plans).

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
**Power-of-10 wall**: every loop is bounded — by a catalog or inbox limit, or by a fixed list.

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
