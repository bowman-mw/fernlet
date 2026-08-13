# Custom Clothing, Friend Shops & Coins — Implementation Plan

**Status:** Increment 1 shipped (design/wear your own items) + code-reviewed + fixed. Increments 2–3 pending.
**Branch:** `claude/wonderful-bardeen-1969f6` (Increment 1 work is **uncommitted** as of 2026-06-29).
**Owner-facing memory:** `~/.claude/.../memory/custom-clothing-feature-2026-06-29.md`.

## How to use this doc

Each increment below is sized to be done in **its own fresh session**. A session has no memory of the
others, so each increment section is self-contained: it states the goal, the locked decisions, the exact
files/seams to touch, the existing patterns to mirror, and a "Definition of done" with tests. Start a
session by reading **§1 (vision), §2 (locked decisions), §3 (what already exists)**, then jump to the
increment you're building. Re-read the cited source files before editing — line numbers drift.

---

## 1. Vision

A privacy-first, "tamagotchi-of-yourself" twist on the Animal Crossing clothing designer:

- **Design** custom clothing/accessories in a **grid pixel-fabric editor** (per-slot canvases).
- **Wear** them on your companion.
- **Share** them with friends **in person** via the proximity mesh — like an ephemeral item shop that
  pops up while you're connected.
- **Provenance**: an item placed in a friend's closet shows "designed by &lt;friend&gt;" — NFT-like
  attribution, but with **no blockchain** (the cryptographically-signed proximity envelope + an
  anonymized designer id *is* the provenance).
- **Coins**, earned from consistent app use, are spent to acquire items from a friend's shop.

---

## 2. Locked product decisions

These are settled (asked & answered 2026-06-29). Do not relitigate without the owner.

1. **Currency = coins for BUYING only.** Designing/publishing your own items is **free** (no
   credit gate — this diverges from the spec's CreationCredit model, intentionally). Instead the *shop*
   is throttled: a **cap on items listed for sale at once** (default **6**) and you can **re-publish your
   shop only once per calendar day**.
2. **Coins are a pure personal sink.** Earned from consistent use, spent to acquire friends' items. The
   seller is **not** credited (no server, can't credit an offline peer). An "active day" = a calendar day
   with any logged data.
3. **Shops are ephemeral + in-person only.** A friend's catalog is broadcast over the mesh **during the
   session** and discarded the moment you leave proximity. Only items you actually **buy** persist.
   (Matches the spec's "shop access window / session ends, no persistent connection.")
4. **Per-slot grid sizes.** `ItemSlot`: hat 16×12, face 18×8, body/outfit 24×20, heldItem 14×14.
5. **Anonymized provenance.** `ItemDesigner` carries **only** an anonymous random `id: UUID` — never a
   name or key. The id→name mapping is learned **only when you connect in person** (stored locally in
   `FernletSettings.knownDesignerNames`). "Is this mine?" is computed (`designer.id == localDesignerID`),
   never stored on the item. So an item — even passed friend-to-friend — leaks nothing about who made it
   to anyone who hasn't met them.

**Tunable defaults (constants, easy to change):** shop listing cap = 6; designer-set bounded price per
item; coin accrual = N per active day; moderation runs on item name at list-for-sale time.

---

## 3. What already exists (Increment 1 — DONE)

Build on these; don't duplicate. Items live in their **own per-row store**, mirroring saved recipes —
**not** in the settings/snapshot blob — so a growing closet never bloats the character/day state and items
sync row-by-row.

### Domain types — `FernletKit/Sources/FernletDomainModel/`
- `CustomItemModels.swift`: `ItemSlot` (per-slot `gridCols`/`gridRows`), `ItemGridTexture`
  (palette-indexed `pixels: [Int]`, `-1` = transparent; `.blank(for:)`, `.hex(x:y:)`, `.sanitized(...)`,
  `.isBlank`), `CustomizationItem` (`id, name, slot, texture, designer, createdAt, isShareable, price`),
  `ItemDesignPalette.hexes` (16-color editor palette).
- `ItemDesigner.swift`: anonymized provenance — `{ id: UUID }` only.

### Persistence — the saved-recipe pattern, cloned
- `FernletPersistence/CustomItemRepositoring.swift` — `@MainActor` protocol (`load`/`loadAsync`/`save`).
- `CloudKitSync/CustomItemRepository.swift` — Core Data + iCloud impl; per-row `CustomItemRecord`
  (`idString`, `payloadData` JSON blob, `createdAt`). **Plain binary — never `allowsExternalBinaryDataStorage`
  (CloudKit rejects it).**
- `CloudKitSync/Persistence.swift` — `makeCustomItemRecordEntity()` is registered in
  `makeManagedObjectModel()`.
- `StoreCore/CustomItemService.swift` — `@MainActor @Observable`; in-memory `items`, debounced save
  (`upsert`/`delete`/`setShareable`/`reset`/`flushPendingSave`).

### App wiring
- `FernletSettings` (SettingsModel.swift) holds only the **small** state: `equippedItemIDsBySlot`
  (`ItemSlot.rawValue → item UUID`), `localDesignerID: UUID?`, `knownDesignerNames: [String: String]`.
- `DiaryStore` — equip-map ops (`equipCustomItem`/`unequipSlot`/`clearEquipReferences`), `localDesignerID`
  (pure getter) + `ensureLocalDesignerID()` (called once at store init), `setKnownDesignerName(id:name:)`.
- `FernletStore` — `customItemService` wired in both init paths + async factory + reset + background flush;
  forwarders: `customItems`, `equippedCustomItems`, `saveCustomItem`, `deleteCustomItem`,
  `equipCustomItem`, `unequipCustomSlot`, `setCustomItemShareable`, `localDesignerID`, `isSelfDesigned(_)`,
  `designerDisplayName(for:)`.

### UI — `App/Fernlet/`
- `CustomItemRendering.swift` — `ItemTextureRenderer` (texture → cached `CGImage`), `CustomItemThumbnail`,
  `Color(itemHex:)`.
- `CompanionVectorAssets.swift` — `CompanionView` gained `equippedItems` param + `CompanionCustomItemLayer`
  (per-slot placement, z-ordered via `CompanionView.itemPaintOrder`).
- `CreationStudioView.swift` — the grid editor (per-slot canvas, palette, eraser, live preview, `editorPixels`
  reprojection on edit).
- `WardrobeView.swift` — the closet (equip/edit/delete/list-for-sale); entry via a link in
  `CompanionCustomizationSheet` (HomeView).
- Tests: `Tests/FernletTests/CustomItemModelTests.swift` (8 tests).

### Increment-1 review fixes already applied (don't re-introduce)
External-binary-storage removed; background-flush of `customItemService`; eager `localDesignerID` mint
(no mutate-during-render); `CustomItemRecord` added to `CloudKitDataService.allRecordTypes`; explicit
companion z-order; bounds-guarded editor canvas + slot-sized `editorPixels`; coordinate-correct
`ItemGridTexture.sanitized`.

---

## 4. Reuse seams (mirror, don't reinvent)

| Need | Reuse | Location |
|---|---|---|
| Separate synced per-row store | `SavedRecipeService` / `SavedRecipeRepository` / `SavedRecipeRepositoring` | StoreCore / CloudKitSync / FernletPersistence |
| Versioned P2P payload (Codable, sealed/signed) | `RecipeSharePayloads.swift`, `PayloadType` enum | ProximityKit/Wire, FernletDomainModel |
| Send/receive lifecycle, rate-limit, diagnostics | `ProximityRecipeShareManager.swift` | ProximityKit/RecipeSharing |
| Ed25519 sign + ChaCha20 seal, `senderDisplayName` | `FernletIdentityEnvelope.swift`, `IdentityService` | ProximityKit |
| Domain↔wire codec | `RecipeShareCodec.swift` | App/Fernlet/ |
| Review/commit sheet | `ProximityRecipeShareReviewSheet.swift`, `FriendPhotoReviewSheet.swift` | App/Fernlet/Proximity |
| Grid picker + shareable filter | `PhotowallPhotoSelector`, `FriendPhotoReviewSheet` LazyVGrid | LaunchPreparationService / Proximity |
| Text classifier (see caveat) | `DiagnosticLanguage.contains(_:)` | FernletDomainModel/DiagnosticLanguage.swift |
| Active-day source | `DailyHealthScore.dateKey` history | WellbeingModels.swift |

---

## 5. Increment 2 — Coins (earn from consistent use)

**Goal:** a coin balance that grows with consistent app use and can be spent (spending lands in
Increment 3). Self-contained; ships a visible wallet but no shop yet.

### Design
- **Earned coins are derived, not granted** (idempotent, sync-race-free): `earnedCoins =
  cumulativeActiveDayCount × coinsPerActiveDay`. An "active day" = a calendar day with a
  `DailyHealthScore` (or any logged entry) — define one helper `cumulativeActiveDayCount` on `FernletStore`
  (count distinct `dateKey`s). Spending is tracked separately as `coinsSpent`.
- **Balance** = `max(0, earnedCoins − coinsSpent)`. Never negative.
- **New settings field:** `coinsSpent: Int = 0` (FernletSettings, `decodeIfPresent`). `coinsPerActiveDay`
  is a constant (propose 5). Do **not** store `coinBalance` — derive it, so two devices can't double-grant.
- **Spend API** on `FernletStore`/`DiaryStore`: `spendCoins(_ amount: Int) -> Bool` (guards balance,
  increments `coinsSpent`, persists). Returns false if insufficient. Increment 3 calls this on buy.
- **Anti-streak guardrail:** accrual is per *cumulative* active day, never consecutive — the spec forbids
  streak-like mechanics. Keep language gentle ("coins for showing up", not "don't break your streak").

### Steps / files
1. `FernletSettings`: add `coinsSpent: Int = 0` (+ decode line). [SettingsModel.swift]
2. `FernletStore`: `var coinBalance: Int { max(0, cumulativeActiveDayCount * Self.coinsPerActiveDay - settings.coinsSpent) }`,
   `var cumulativeActiveDayCount: Int` (distinct active `dateKey`s), `func spendCoins(_:) -> Bool`
   (via DiaryStore). [FernletStore.swift / DiaryStore.swift]
3. Wallet UI: show the balance in the Wardrobe header (and/or a small "how you earn coins" note). Gentle,
   non-streak copy. [WardrobeView.swift]

### Definition of done
- Build green; `xcodebuild ... -only-testing:Tests/FernletTests/CustomItemModelTests` + a new
  `CoinEconomyTests` green: balance derives correctly, never negative, `spendCoins` debits and refuses
  when short, accrual is idempotent across repeated reads, legacy settings decode with `coinsSpent == 0`.
- Manual: balance visible in Wardrobe; increments as logged days accumulate.

---

## 6. Increment 3 — In-person friend shop (the big one)

**Goal:** while connected in person, browse a friend's shareable items, buy one with coins, and have it
land in your closet stamped "designed by &lt;friend&gt;". Catalog is ephemeral (gone on disconnect).

Build in sub-steps; each compiles. Mirror the recipe-share pipeline throughout.

### 3a. Wire payloads — `ProximityKit/Wire/ClothingSharePayloads.swift` (new)
- `PayloadType` cases: `clothingCatalog = "fernlet.clothing.catalog.v1"` (a peer's current shop listing)
  and `clothingItem = "fernlet.clothing.item.v1"` (one purchased/transferred item). [PayloadType.swift]
- `ClothingItemPayload` (nonisolated, Sendable): `format/version/id/sentAt`, the `CustomizationItem`
  (slot, texture, name, price, **designer.id**), and the sender's `localDesignerID` + `senderDisplayName`
  so the receiver can populate `knownDesignerNames[designer.id] = name`.
- `ClothingCatalogPayload`: sender's `localDesignerID` + `displayName` + `[ClothingItemPayload]` (only
  shareable items, capped). **Deterministic ordering** (sort by item id/createdAt) so signed bytes are
  stable. Mirror `RecipeSharePayloads.swift`.
- Register the new types in `FernletIdentityEnvelope.sealingRequiredTypes` so they're sealed.

### 3b. Codec — `App/Fernlet/ClothingShareCodec.swift` (new), mirror `RecipeShareCodec.swift`
Domain `CustomizationItem` ↔ wire payload. **Sanitize on receive** via `ItemGridTexture.sanitized()`
(clamp dims, coerce bad indices) before storing — never trust wire bytes.

### 3c. Exchange manager — `ProximityKit/.../ProximityClothingShareManager.swift` (new)
Clone `ProximityRecipeShareManager`: on an active friend session, exchange `ClothingCatalogPayload`s; hold
the **peer's catalog in memory for the session only**, cleared on disconnect (ephemeral, decision §2.3).
Reuse rate-limiting + diagnostics. A buy sends a `clothingItem` request/transfer (or simply transfers the
chosen item, since it's already in the broadcast catalog — simplest: buy is local, see 3e).

### 3d. Designer-name directory
On receiving a catalog/item, call `store.diary.setKnownDesignerName(id: payload.designerID, name:
payload.senderDisplayName)` so future "designed by …" resolves. (The identity handshake already carries
`senderDisplayName`; the clothing payload carries the matching `localDesignerID`.)

### 3e. Shop UI — `App/Fernlet/FriendShopView.swift` (new)
- Reuse the `PhotowallPhotoSelector` / `FriendPhotoReviewSheet` LazyVGrid + `CustomItemThumbnail` pattern.
- Show the connected friend's **shareable** items (their broadcast catalog), each with name, price, and
  "designed by &lt;friend&gt;".
- **Buy flow:** guard `store.coinBalance >= price` → `store.spendCoins(price)` → `customItemService.upsert`
  the item with `designer.id` = friend's designer id (provenance preserved) → de-dup if already owned
  (same item id). Show "owned" state for items you already have.
- Entry point: opens during an active in-person session from `ConnectView`/proximity surface (the "open
  shop" intent is just a payload over the existing friend session — **no new handshake intent**).

### 3f. Shop management — extend `WardrobeView.swift`
- Mark items shareable (`setCustomItemShareable` exists) + set a **bounded price** per item (add a `price`
  editor; `CustomizationItem.price` already exists).
- Enforce the **listing cap** (6) and **once-per-day re-publish** throttle: add
  `shopLastPublishedDayKey: String?` to settings; block listing changes until the next calendar day after a
  publish. Surface the cap/throttle gently.
- **Moderation** at list-for-sale time: run the item **name** through a text classifier; if flagged, keep
  it unlisted with a gentle, dismissible, editable notice (not silent-drop). **Caveat:** the existing
  `DiagnosticLanguage.contains` targets *diagnostic/medical* language, **not** profanity — so this
  increment likely needs a small profanity/offensive-name classifier (or an allowlist of safe chars +
  a wordlist). Image moderation of the drawn grid is **deferred** (text-only at MVP, per spec §14:653).

### Definition of done
- Build green; `ClothingShareCodecTests` (payload round-trip + sanitize-on-receive), `FriendShopTests`
  (buy debits coins, adds item with correct provenance, de-dups, refuses when short), listing
  cap/throttle tests, catalog-ephemerality test (cleared on disconnect), moderation-gate test.
- Run the **S3 wall check** (`Scripts/spm-wall-check.sh`) — new wire types stay in
  ProximityKit/FernletDomainModel, never in `Private*`.
- Manual two-device (or simulator-pair) check: connect → browse friend's shop → buy → item appears in
  closet as "designed by &lt;friend&gt;" → disconnect → catalog gone, purchased item remains.

### Risks / watch-items
- **Payload size:** a per-slot palette-indexed texture is ~1 KB → fits a single sealed envelope, no
  chunking. If the catalog (≤6 items) ever exceeds the MTU, adopt the `friendPhotoManifest` chunking
  pattern. Keep textures small.
- **Determinism:** sort all payload lists by id/createdAt or sign-time ≠ verify-time bytes.
- **Sanitize on receive** (3b) — never index wire textures without `.sanitized()`.
- **Coins are derived** (Increment 2): buying only ever increments `coinsSpent`; never write a balance.

---

## 7. Deferred / future (Increment 4+ / polish)

- **Friends see your custom look:** the cached-appearance handshake snapshot currently carries only the
  base `CompanionAppearance`, not equipped item textures — so a friend's cached view of you shows the base
  avatar. Rendering your equipped custom items on their device needs the avatar snapshot to carry the
  equipped textures (size-bounded).
- **Image moderation** of the drawn grid (Core ML) — text-only at MVP.
- **Cosmetic tuning pass (on device):** `CompanionCustomItemLayer.placement` per-slot offsets and the
  `ItemDesignPalette` 16 colors are best-guess; eyeball and nudge on a real device.

---

## 8. Commands & conventions

```bash
# Build (authoritative compile check)
xcodebuild build-for-testing -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'

# Test a suite (batch by suite; full run ~7 min)
xcodebuild test-without-building -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:Tests/FernletTests/<SuiteName>

# S3 module-wall check (run if you touch module deps / add wire types)
Scripts/spm-wall-check.sh
```

- New Swift files in `App/Fernlet/` and `FernletKit/Sources/<module>/` are auto-included (synced folder groups
  / SPM) — no pbxproj surgery.
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`), `@MainActor` for store/service tests.
- Keep clothing/coin/shop types **out of `Private*` modules** (S3 wall) — they belong in
  `FernletDomainModel` / `ProximityKit` (wall-safe).
- After each increment: build + the owning test suite + a quick `/code-review` of the diff before commit.

---

## 9. Kickoff prompts (one increment per session)

Paste the matching block into a fresh session. The flow mirrors how Increment 1 was built: **read docs →
plan → ask questions → implement → code review**.

### Increment 2 — Coins

```
I want to implement Increment 2 (Coins) of the custom-clothing feature.

First read the plan: Docs/Custom-Clothing-Plan-2026-06-29.md — read §1 (vision), §2 (locked
decisions), §3 (what already exists), §4 (reuse seams), §5 (Increment 2 — Coins), and §8
(commands & conventions). Also skim the project CLAUDE.md and Docs/StoreRepositoryFunctionIndex.md
since this touches the store/persistence layer. Read the actual source files the plan cites before
trusting line numbers — they drift.

Then, in this order:
1. Plan how Increment 2 should be implemented, grounded in the current code. Confirm the design in §5
   (coin balance DERIVED from cumulative active days + coinsSpent in settings; spendCoins; wallet UI)
   still fits, and adjust if the code has moved.
2. Ask me any clarifying questions before writing code (e.g. coins-per-active-day value; exactly what
   counts as an "active day"; where the wallet surfaces in the UI; gentle non-streak copy).
3. After I answer, implement it — build incrementally with
   `xcodebuild build-for-testing -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'`
   and add Swift Testing coverage (a CoinEconomyTests suite). Keep coin types out of Private* modules
   (S3 wall).
4. When it builds and tests pass, run `/code-review` on the diff and fix the findings. Then summarize.

Increment 1 (grid editor, wardrobe, per-row item store, anonymized provenance) is already built,
reviewed, and committed — build on it and don't reintroduce its fixed bugs (§3). Don't start
Increment 3 (the shop) in this session.
```

### Increment 3 — In-person friend shop

```
I want to implement Increment 3 (the in-person friend shop) of the custom-clothing feature.

Work on the branch wonderful-bardeen. First read, in this order:
- Docs/Custom-Clothing-Plan-2026-06-29.md — §1 (vision), §2 (locked decisions), §3 (what already
  exists), §4 (reuse seams), and §6 (Increment 3 — the shop, your spec).
- Docs/Coin-Ledger-Design-2026-06-29.md — Increment 2 shipped coins as an append-only LEDGER (this
  SUPERSEDES §5's derived-balance design). The buy flow spends via store.spendCoins(price, ref:)
  where `ref` is the purchased item's id (idempotent — a retried buy with the same ref can't debit
  twice). Read how earned/spend rows + CoinEconomy aggregation work.
- Docs/ProximityFunctionIndex.md — the mesh/identity/recipe-share/friend-photo subsystem you'll clone.
- Docs/Multi-Device-Without-iCloud-Design-2026-06-29.md — multi-device context. NOTE two things from
  it that touch this increment: (1) CustomItemRepository/SavedRecipeRepository use full-replace
  (delete-unlisted) save and are NOT mesh/multi-device safe — when you add the *bought* item to the
  closet, make sure that path can't clobber rows that synced in from another device (mirror the coin
  ledger's append-only upsert, or fix the item store to append-only as part of this work). (2) Cross-
  device spend reconciliation: the ledger reloads on remote sync via FernletStore.apply(); a buy
  should reload the ledger before guarding the spend so it sees other devices' rows.
Also skim the project CLAUDE.md. Read the actual source files the plans cite before trusting line
numbers — they drift.

Then, in this order:
1. Plan how Increment 3 should be implemented, grounded in the current code (the coin ledger now
   exists; mirror the recipe-share pipeline for the catalog/item exchange). Confirm §6's sub-steps
   (3a wire payloads → 3b codec → 3c exchange manager → 3d designer-name directory → 3e shop UI/buy →
   3f shop management: listing cap 6, once-per-day re-publish throttle, text moderation at list time)
   still fit, and adjust if the code has moved.
2. Ask me any clarifying questions before writing code (e.g. the moderation wordlist/approach since
   DiagnosticLanguage targets clinical language not profanity; exact buy UX; price bounds; whether to
   fix the items/recipes append-only clobber now or defer).
3. After I answer, implement it — build incrementally with
   `xcodebuild build-for-testing -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'`
   and add Swift Testing coverage (ClothingShareCodecTests + FriendShopTests: buy debits coins via
   spendCoins, adds item with correct anonymized provenance, de-dups if already owned, refuses when
   short; listing cap/throttle; catalog ephemerality on disconnect; moderation gate). Keep clothing/
   coin/shop wire types OUT of Private* modules (S3 wall) — they belong in ProximityKit/
   FernletDomainModel.
4. When it builds and tests pass: run the S3 wall check (`Scripts/spm-wall-check.sh`), run /code-review
   on the diff and fix the findings, and do a two-device (or simulator-pair) manual check: connect →
   browse friend's shop → buy → item lands in closet as "designed by <friend>" → disconnect → catalog
   gone, purchased item remains. Then summarize.

Increment 1 (grid editor, wardrobe, anonymized provenance) and Increment 2 (coin ledger) are built,
reviewed, and committed — build on them. Don't reintroduce their fixed bugs (§3 + the coin-ledger
review: earn idempotency is structural via deterministic ids; dedup happens in CoinEconomy aggregation,
NOT the storage layer). This is the biggest increment — build it in the compiling sub-steps of §6.
```
