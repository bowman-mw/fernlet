# Plan: Fernlet Coach, a standalone ProximityKit, and coach plan links (2026-10-01)

**Status:** detailed plan, owner decisions recorded through O17. Nothing is built yet.
**Supersedes in part:** [FernletCoach-Specification-2026-07-19.md](FernletCoach-Specification-2026-07-19.md)
(see §2) and §5 of [Data-Provenance-Coach-Trust-2026-07-12.md](Data-Provenance-Coach-Trust-2026-07-12.md)
(App Attest).
**Design brief for Claude Design:** `Docs/Handoff/fernlet-coach-2026-10-01/design-prompts.md`
(local only, like earlier design prompts).

Grounded in seven read-only code inventories and two web research passes run on 2026-10-01 against
main `a9181ab0`. File and line references below are from those inventories; re-check them before
editing, because other sessions keep moving the tree.

---

## 1. Decisions (owner, 2026-10-01)

| # | Decision |
|---|---|
| O1 | Fernlet Coach is a **separate app** for iPhone, iPad and Mac, in the private `fernletcoach` repo (exists, empty apart from a README). A web builder on fernlet.com was rejected. |
| O2 | **ProximityKit leaves FernletKit for its own repository** and becomes a drop-in package for any app, Fernlet or not. It depends on nothing in FernletKit, FernletUI included. |
| O3 | **FernletKit defines Fernlet's connection types and rules** on top of ProximityKit's mechanisms. |
| O4 | **FernletUI works on iPhone, iPad and native Mac** (not Catalyst). FernletUI may depend on ProximityKit, never the reverse. |
| O5 | The **coach connection mirrors the recipe radio**: one to one, in person. |
| O6 | `fernletcoach` gets FernletKit as a **git submodule** of `fernlet`, referenced by local path. |
| O7 | Coach data **syncs across the coach's own devices** through iCloud ("no need to be as siloed"). |
| O8 | Coach is **free** at launch and available in the **US only**. |
| O9 | Plans carry **rest times** and optional per-exercise **demo links (any https link)**. |
| O10 | Off-week delivery is a **fernlet.com link** in a text message (a universal link), not an iMessage card. |
| O11 | A plan from the trainee's own paired coach, addressed to them, is **saved quietly with a confirmation**. Fernlet asks only about exercises that clash with the trainee's avoid list or equipment, and about days that already have workouts. |
| O12 | A plan or recipe **meant for someone else** shows a notice ("This workout was intended for someone else and may not be what's best for you") and can still be kept. Links are **signed and addressed, not encrypted**. |
| O13 | Without Fernlet installed, the link opens a **fernlet.com preview** of the workout or recipe with an App Store link. |
| O14 | Paired-coach plans have **their own consent**. The Manual plan exchange setting covers only the unverified paths (paste, Shortcuts, Messages cards). |
| O15 | **Out of scope:** the drone ground-control work, Android, the CloudKit dead-drop, App Attest, a Coach iMessage app, and group classes (later). |
| O16 | **One coach identity key, synced** across the coach's devices through iCloud Keychain. A trainee pairs once, and any of the coach's devices can hand over or sign links (C3). |
| O17 | **Session start:** the coach's device broadcasts a session; the coachee taps it to connect; only those two connect, and the session then **locks** (it stops advertising and accepts nobody else) until it ends (C5). |

---

## 2. What this changes in existing docs

- **Coach spec (2026-07-19):**
  - §3.2: App Attest is dropped. Trust is the in-person pairing.
  - §3.3, §3.4, §3.6: replaced by in-person handover (§6) and signed, unencrypted fernlet.com links (§7). The "Incorrect message sent" screen becomes O12's notice.
  - F1: universal links become real (§7).
  - F3: the review screen becomes O11's quiet save.
  - F8: the App Clip is dropped.
  - C2: per-trainee sealed partitions become a synced store with encrypted fields (§9).
  - D1, D3, D7, D8, D9 and D11: superseded by O7, O8, O10 and O12.
  - §9 still excludes a coach web app and Android.
- **Provenance memo §5:** App Attest is not pursued.
- **Not edited by this plan:** `Docs/FernletSpecificationV3.md` and `Docs/ImplementationPlan.md`, because another session holds their working copies. Their coach sections should point here once that session lands.

---

## 3. Target architecture

### 3.1 Repositories

```
proximitykit  (new, public, Apache-2.0, semver tags)
   │  Swift package: ProximityKit
   ▼
fernlet  (public)
   FernletKit/  local package, depends on proximitykit at a pinned tag
   App/Fernlet  the trainee app
   Site/        fernlet.com
   ▲
   │  git submodule (vendor/fernlet), FernletKit by local path
fernletcoach  (private)
   FernletCoach app (iPhone, iPad, Mac), also depends on proximitykit at the SAME tag
```

- **ProximityKit must be public.** The public `fernlet` repo depends on it, so anyone building
  Fernlet has to be able to fetch it. Its code is already public today, inside `fernlet`.
- **"Exactly the same dependency":** FernletKit's manifest pins the ProximityKit version. Coach
  resolves through the submodule's FernletKit, so Swift's package manager unifies both to one
  version. A CI step in `fernletcoach` fails if its `Package.resolved` ProximityKit revision
  differs from the one the submodule's FernletKit resolves.
- **Why not a URL dependency on FernletKit:** SwiftPM can only fetch packages whose
  `Package.swift` sits at a repository root, and FernletKit lives in a subfolder. The submodule
  (O6) avoids moving it, which would also break the code walls that read `FernletKit/Sources` by
  path.

### 3.2 Layers

- **ProximityKit: mechanism only.** Nothing Fernlet-specific in its API.
  - Connections: QUIC over Bonjour with peer-to-peer Wi-Fi, framing, ephemeral TLS identities, and
    a **one-to-one session with profiles** (today's recipe radio, generalized). The routed mesh
    engine follows later (§4).
  - Identity and trust: identity keys, envelopes, sealing, the replay cache, trust-store machinery,
    verification ceremonies, the session coordinator.
  - Rules plumbing: a payload-type registry, capability negotiation and run-policy hooks.
  - Wire naming: a **host-supplied protocol namespace** for every domain-separation tag, so a
    non-Fernlet app never shares Fernlet's wire identity.
  - Builds for iOS 26 and macOS 26. No UI, no app features, no FernletKit.
- **FernletKit: Fernlet's rules and features.**
  - `FernletConnections` (new):
    - the `fernlet` namespace;
    - the connection profiles: friend mesh, presence, recipe and coach;
    - the Fernlet payload vocabulary and capability tokens;
    - app identities (Fernlet, Coach, a future item designer) with per-app allow lists, deny by
      default;
    - coach relationship records;
    - the coach link signing purposes.
  - `FernletSocial` (new, name to confirm): the Fernlet features that live in ProximityKit today:
    - hearts, presence, the recipe-share manager, the clothing shop, activities, chat, moderation
      and friend photos;
    - until the routed mesh is generalized, also the Fernlet parts of the mesh manager.
  - `FernletProximityUI` (new): the three proximity views from ProximityKit's `UI/` folder.
    FernletUI itself stays free of the networking stack and Photos, which keeps it light for Coach.
  - `FernletUI`: multiplatform (§5).
- **Fernlet app:** FernletKit, plus ProximityKit through it.
- **Coach app:** ProximityKit plus a narrow set of FernletKit products (§9.1).

---

## 4. Workstream A: ProximityKit as its own package

**Today:**
- ProximityKit is 143 Swift files and 67,357 lines, plus a 31-key English string catalog and a DocC
  catalog. It builds for iOS only (`FernletKit/Package.swift:27–29`, target at :381).
- It imports five FernletKit modules.
- 53 app files use it, 79 of its 141 public types are used, and nothing else in FernletKit imports
  it. 169 test files import it, 116 of them with `@testable`.
- No blocker to extraction was found. The work is in four tangles: crypto labels, Fernlet feature
  code, the routed mesh manager, and tests that read repo files.

**End state:** ProximityKit contains the transport, identity, trust, wire, engine, ranging
abstraction **and the routed multi-device mesh engine**, all app-agnostic. Fernlet's features move
to FernletKit. The routed mesh stays in the package because family apps (an item designer selling
into a friend session, group classes later) will want it.

### A0. Decouple in place (inside FernletKit, Fernlet behaviour identical)

Each step lands separately with the mesh batteries green (CI mesh line: 155 suites, floor 1353).

**A0.1 Move the screens out.**
- Move `FingerprintText`, `KeepFriendsPromptSheet` and `FriendPhotoReviewSheet` (with its Photos
  saver and save-failure alert) into a new `FernletProximityUI` module that depends on ProximityKit
  and FernletUI.
- Split `ProximityUICopy`: 28 keys move with the screens; the 3 Camera/Peer keys stay.
- Remove `"FernletUI"` from ProximityKit's dependencies.
- **Why a separate module:** FernletUI keeps no networking or Photos dependency, so Coach's design
  system stays light. The direction still matches O4: the UI depends on ProximityKit, never the
  reverse.

**A0.2 A host-supplied namespace with byte-identical Fernlet values.**
- Add `ProximityNamespace`, an explicit table rather than prefix composition, because today's
  strings don't share one shape. It holds:
  - every domain-separation label with its framing;
  - service types, ALPNs and the heartbeat datagram;
  - keychain services and accounts;
  - the storage directory and on-disk file names;
  - the QR URL scheme and the log subsystem.
- Ship a `.fernlet` instance that reproduces today's literals exactly.
- **Must stay byte-identical** (wire or on-disk compatibility):
  - the 38 protocol labels, including the TLS exporter label (`NetworkMeshSession.swift:2393`),
    `fernlet.verify.qr.v1` / `response.v1` and `fernlet.mesh.epoch.v1`;
  - `PayloadType` tokens and capability raw values;
  - routed-type tokens and membership record kinds;
  - `_fernlet-mesh2/_near2/_recipe2._udp` with their ALPNs;
  - `fernlet-mesh-heartbeat` and the `fernlet` QR scheme;
  - keychain services (`com.fernlet.identity`, `.mesh-session`, `.mesh-routed`, `.heartdrop`,
    `.moderation`, the device-binding row) and accounts;
  - on-disk format tokens, and `Application Support/Fernlet` with its file names.
- **Free to change:** the logger subsystem, the TLS certificate name, the Bonjour instance prefix,
  the `"Fernlet"` display default and user-facing copy.
- **Copied into ProximityKit:**
  - its own purpose type with a host-callable initializer (today's `CryptographicPurpose` init is
    fileprivate);
  - `ColumnCrypto`, byte for byte (used by the mesh session and routed stores);
  - the `KeychainItem` mechanism (not Fernlet's `Account` enum).
- **Injected by the host:**
  - an audit sink protocol replacing ~428 `FernletAuditLog.log` calls (295 in the mesh manager),
    which Fernlet bridges back so audit-capture tests keep working;
  - the `DeviceBindingID`, so its keychain row stays shared with Fernlet's private stores.
- **Golden-byte tests** pin every `.fernlet` value against today's literals before anything moves.
  Run the "no label is a prefix of another" check over Fernlet's and ProximityKit's labels together.

**A0.3 Inject the vocabulary and rules (O3).**
- ProximityKit gets generic token types and protocols. `FernletConnections` supplies Fernlet's:
  - `PayloadType` (78 references in 13 files), `ProximityCapability` and `ProximityMode`;
  - `sealingRequiredTypes`;
  - display-name moderation (`ItemNameModeration`, 46 references);
  - the Friend and Coach session trust policies and `FriendMintingReview`;
  - the engine's `"Fernlet"` defaults and `serviceType(for:)`;
  - the routed-type policy rows (`MeshRoutedTypeRegistry:104–112` and :318, `MeshRoutedAck`
    tokens, `MeshRoutedHeartAck`).
- **Persisted records stay Fernlet types.** `ProximityTrustedPeerRecord` (41 references),
  `TrainerAuditEvent` (23) and `ConnectionSessionLog` are persisted by Fernlet's snapshot and
  repository. ProximityKit defines trusted-peer and audit protocols, and Fernlet converts. That also
  keeps CloudKitSync from reaching ProximityKit through persistence.
- **Generic types move in:** `PayloadEncryption`, `PayloadSummary`/`DateRange` (type only; its
  English text stays host policy), `ProximityRole`, `ProximityRangingMode` and `EnumDecodeCompat`.

**A0.4 Move the feature code out** to `FernletSocial`, in FernletKit.
- **What moves:**
  - hearts (all of `HeartSharing/` except `ProtectedSidecar`, which is core and used by the mesh
    session store);
  - presence (`PresenceManager`, `ClosenessLedger`, `FriendStateCache`) and the recipe-share
    manager;
  - clothing, activities, chat and moderation (~5,200 lines);
  - their wire payload files and the serializer's activity and moderation domains;
  - the friend-photo, moderation, activity, heart, closeness, shop and recipe model types;
  - the 13 feature crypto labels.
- **`IdentityService`:**
  - the sealed-backup escrow key (:178–224, :773–1074) moves to Fernlet's backup side;
  - heart-drop derivations (:316–372) and presence tags (:373–446) become generic
    `pairSecret(purpose:)` and `epochTag(purpose:)` in the core, called with Fernlet's purposes.
- **Stays in core:** the one-to-one mechanism pieces of `RecipeSharing/` (`RecipeShareTransfer`,
  `RecipeShareAdvertisement`, `RecipeShareOutcome`), generalized in A0.7. Feature-only date helpers
  (`FernletDate.dayKey`, `MonotonicClock`) move out with the features.

**A0.5 Split the routed mesh manager** (`MeshNetworkManager.swift`, 16,579 lines).
- **Engine, about 12.9k lines, stays:** join and seating, the access gate, lifecycle and admission,
  the handler registry and dispatch door (:3577–3803), membership, key adverts, quorum, merge,
  routed drain and origination, durable context and partition, transport and slots, the QR
  ceremony, removal voting, envelope sending, group-key rotation, continuation.
- **Fernlet features, about 2.9k lines, move** to FernletSocial through the existing handler
  registry plus small extension points:
  - photo-wall types and the wall;
  - the registered shop, moderation, friend-state and activity handlers;
  - hearts and the heart ceremony;
  - friend minting;
  - `addPhoto`;
  - projection into the photo wall, transcript and heart ledger;
  - vouch labels;
  - the capability list;
  - photos, shop and temporary messages.
- **Also out of `Mesh/`:**
  - the photo, text and heart bodies in `MeshRoutedItemBody` (its framing at :43 stays);
  - `MeshContentIngest`, `MeshContentMerge:272–402`, `MeshSessionTypes:167–298` and
    `MeshRoutedOrigination:39–157`;
  - `FriendsDiscoveryEntry`, `MeshNameGenerator` and `MeshSessionResumePresentation`.
- **Size cap:** `MeshRoutedItemSeal.swift:95` takes its size cap from the routed-type registry
  instead of PrivateMediaStore. That cuts the last PrivateMediaStore edge; the photo-store code at
  :355–396, :645–690, :2276–2728, :3362–3438, :9345, :13891–14088 and :14559 has moved with the
  photo feature.
- **Test seams stay test-only:** ~0.8k lines (UI-test injection at 16113–16193 and the DEBUG
  hooks).
- This is the biggest and riskiest step. Do it in several commits, each with the mesh batteries
  green.

**A0.6 Mac readiness.**
- Add `.macOS(.v26)`.
- Wrap `NIRangingSession` in `#if canImport(NearbyInteraction) && !os(macOS)` behind an injected
  `RangingProvider`, which is a no-op or signal-strength only on Mac and iPad.
- Inject the default device name instead of reading `UIDevice` (`PeerDisplayNames.swift:26`).
- The photo `UIImage` code has already left in A0.5.
- Delete three unused `import UIKit` lines (`ProximityCoordinator.swift:4`, `PresenceManager.swift:61`,
  `ProximityRecipeShareManager.swift:3`).
- Move the ActivityKit Live Activity reaper (`ProximityForegroundAnchor.swift:48–116`) to the app.
- The storage directory always comes from the host. On an unsandboxed Mac, Application Support isn't
  per app.

**A0.7 Generalize the one-to-one radio** into a profile-driven pair session.
- The recipe profile reproduces today's bytes. The coach profile is added in C5.
- `RecipeShareRadioSession` (`NetworkRecipeShareSession.swift:22`) is already a generic protocol.

**A0.8 Sort the tests.**
- **73 core suites move into an in-tree ProximityKit package test target**, then travel with the
  package:
  - 44 are self-contained;
  - 13 swap `makeTestStore` for a `ProximityHost` test double;
  - 19 read repo files through `RepoRoot`.

  The helpers they need move with them (Mocks, the routed fixture clock, the proximity directory
  and keychain helpers).
- **11 feature suites follow the features.**
- **83 integration suites and 2 Fernlet walls stay.**
- **Acceptance batteries:** `MeshP9AcceptanceTests` behaviour suites can move, but its suites that
  read Fernlet docs and workflows stay. The same applies to the P7, P8 and P10 acceptance files.

### A1. Move to the `proximitykit` repo

**A1.1 Create the repo.**
- Split `FernletKit/Sources/ProximityKit` plus its package tests out with history (`git filter-repo`
  or a subtree split).
- Root `Package.swift`: tools 6.2; iOS 26 and macOS 26; `defaultIsolation(MainActor.self)` as today.
- Apache-2.0 `LICENSE`/`NOTICE` and the DocC catalog.
- **CI** (`swift test` / `xcodebuild` on an iOS simulator and macOS) running its own walls:
  - no tracking SDKs and no `URLSession` at all;
  - local-link APIs only in the radio files;
  - the Power-of-10 scanner with the 3 ProximityKit allowlist entries (`power-of-10-allowlist.json:51, :56, :61`);
  - doc coverage;
  - the CloudKit half of the S3 pair;
  - golden bytes;
  - a protected label registry, mirroring the `FernletCrypto/` CODEOWNERS rule.
- Tag `0.1.0`.

**A1.2 Prove "drop-in for anything".** Add a tiny example app in the package repo that uses a
different namespace (not `.fernlet`). Two devices pair and exchange a message, and a test shows its
labels never validate as Fernlet's.

**A1.3 Fernlet consumes the tag.** In the same commit as removing the in-tree target and its
umbrella entry:
- **`FernletKit/Package.swift`:** depend on `proximitykit` at `0.1.0`.
- **`NoTrackingBoundaryTests`:**
  - add the repo URL to `allowedPackageURLs` (:168), with a `Docs/No-Tracking-Wall.md` row;
  - drop the radios from `permittedLocalLinkFiles` (:332–344), or the missing-file check fails;
  - keep the Bonjour classification app-side.
- **`S3BoundaryTests`:** move the ProximityKit/CloudKit pair (:216–241) to the new repo.
- **Power-of-10:** delete the 3 moved allowlist entries.
- **`LocalizationBoundaryTests`:** drop the moved catalog and keys (:2749, :2525, :2578, :2614), plus
  the matching `sync-string-catalogs.sh:88` line.
- **Re-point:** `PrivacyWipeCoverageTests:270–272` with 9 `PrivacyWipeCoverage.md` rows,
  `TransportNeutralityBoundaryTests`, `MemoryLifecycleBoundaryTests` and
  `PhotoSaveFailureAcknowledgementTests`.
- **`s3-wall.yml`:** re-scope key-custody and crypto-goldens, re-measure the mesh-batteries floor
  after the moved suites leave, and update `CIGateSelectorBoundaryTests` with it.
- **Docs:** split `Docs/FileIndex.md` (122 mentions) and `Docs/ProximityFunctionIndex.md`, and
  update CLAUDE.md and AGENTS.md (the S3 wall paragraph names the Proximity subtree).

**A1.4 `@testable` across repos.** 116 Fernlet test files use `@testable import ProximityKit`.
Verify early that the remote dependency's Debug build allows it. If not, expose what integration
tests need with `@_spi(Testing)`, or use test doubles.

**A1.5 Developing across repos.** Develop with a local package override (a sibling checkout dragged
into the workspace). Never commit the override, and CI always builds the tag.

### A2. Releases and wire compatibility

- **Semver tags:** wire or on-disk breaks are major versions.
- **Cross-version fixtures:** older peers' bytes must keep decoding, or be parked politely, never
  crash. The repo already follows "updates must never brick old clients".
- Fernlet and Coach move to a new tag together. The `fernletcoach` CI check in §3.1 enforces it.

---

## 5. Workstream B: FernletUI on iPhone, iPad and Mac

FernletUI doesn't build for macOS today. The package declares only `.iOS(.v26)`, and 6 of its 13
Swift files use UIKit.

**B1. Package**
- Add `.macOS(.v26)` to `platforms`.
- Add a separate `FernletUI` library product, so Coach doesn't link the all-in-one `FernletKit`
  product (which drags in HealthKit, CloudKit and the AI modules).
- FernletUI keeps depending only on FernletDomainModel.

**B2. Colors (the biggest job)**
- Move `FernletThemeDefaults` (`FernletTheme.swift:19`) out of the file-wide `#if canImport(UIKit)`.
- Do the palette maths on a plain RGB struct. `fitInk` already works on raw values (:341–371).
- Add one `dynamicColor` helper:
  - iOS: `UIColor { trait in … }`.
  - macOS: `NSColor(name:dynamicProvider:)`, using
    `appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])`
    for Increase Contrast.
  - Keep the `@Sendable` providers (see the 2026-07-20 off-main render crash).
- Convert NSColor to sRGB before reading its components, because `getRed` raises on non-RGB colors.
- Replace the `.systemBackground` fallbacks (:166, :198) and the `UIColor(hex:)` use at
  `FernletDesignSystem.swift:126`.
- Re-point the unguarded call sites at `FernletUIComponents.swift:21–32` and :207–216.

**B3. Smaller UIKit shims**
- `PolaroidTile` `UIImage(data:)`: decode with CGImageSource.
- `.textInputAutocapitalization`: a helper that does nothing on macOS.
- `keyboardDoneToolbar`: use `@FocusState`.
- `FernletDismissalWindow`: `UIAccessibility` checks become `NSWorkspace` equivalents on Mac.
- `FernletAnnouncer`: only its `import UIKit` line needs guarding.

**B4. Platform behaviour**
- **CaptureProtection on Mac:** use `NSWindow.sharingType = .none` from a view representable. There
  is no screenshot reaction on Mac. Decide whether the inactive cover applies when a Mac window just
  loses focus; the recommendation is no.
- **ActivityShareView:** wrap it in one cross-platform share modifier. On Mac that's
  `NSSharingServicePicker` with completion callbacks; ShareLink was rejected because it has no
  completion hook.
- **Tab bar helpers:** the iPhone tab-bar clearance helpers already fall to 0 on iPad and Mac, so
  they stay as they are.

**B5. Fonts as package resources**
- Move the 7 TTFs from `App/Fernlet/Fonts/` into `FernletUI/Resources/Fonts`.
- Add `FernletFonts.registerIfNeeded()`:
  - `CTFontManagerRegisterFontURLs` with process scope;
  - treat "already registered" (code 105) as success.
- Call it from each app's `init` and from any extension or preview that draws FernletUI.
- Remove `UIAppFonts` afterwards.
- Rewrite `FernletFontRegistrationTests` on CoreText so it runs on Mac too.
- **Prerequisite:** ship the OFL licence texts, which are missing today (separate task filed
  2026-10-01). Check the Reserved Font Name rule for the re-instanced files before any rename.

**B6. Tests and CI**
- Add a FernletKit test target for FernletUI, so its tests run on macOS as well (today every
  FernletUI test runs inside the iOS app).
- Add macOS and iPad simulator build lanes for FernletUI to CI.

**B7. Wire FernletLockUI** after B2, then parameterize its journal and cycle copy (11 strings) so
Coach can use it (§9.1).

---

## 6. Workstream C: Fernlet's connection rules and the coach connection

**C1. `FernletConnections` module** (FernletKit). It holds Fernlet's namespace, the payload
vocabulary, capability tokens, connection profiles, app identities with per-app allow lists, and
link purposes (§3.2). Everything Fernlet-specific that ProximityKit hard-codes today moves here and
is passed in.

**C2. Coach relationship records, separate from the friend trust store**
- **Why separate:**
  - The trust store keeps one record per key, and `trust(_:mode:)` overwrites the mode.
  - Friend features ignore `mode`. Heart recipients, close-friend slots, the friend cap and the
    friend list (`FernletStore.swift:385, :2225, :2294`; `FriendListView.swift:880`) would all
    treat a coach as a friend.
- **Record fields:**
  - the coach identity key(s);
  - the display name captured at pairing (never the unverified `coachDisplayName` from a plan);
  - paired and last-plan dates;
  - trust basis;
  - revoked date;
  - a random per-relationship **addressee ID**;
  - consent settings.
- **Addressing by a random ID, not the trainee's device fingerprint:** the trainee's iPad, or the
  same phone after Delete everything, still matches, and the fingerprint never appears in a link.
- **Storage:** beside `trustedProximityPeers` (`LocalFernletRepository.swift:89, :121, :617, :716`),
  in the wipe (near `FernletStore.swift:6561`) and in the data export (`DataExportBuilder.swift:336`).
  It still honours the trust store's block list.
- **Coach side:** Coach keeps the mirror record per trainee (§9.2).

**C3. Coach identity across the coach's devices (decided: O16)**
- **The coach identity** is one key pair: Ed25519 for signing, X25519 for receiving sealed data.
  - It is created once in Coach onboarding.
  - It is stored as a **synchronizable** iCloud Keychain item in Coach's own keychain access group.
    On Mac that means the data-protection keychain plus an access group from the provisioning
    profile (TN3137).
- **ProximityKit's per-device identity is unchanged.** Transport keys still never leave their
  device (`IdentityService.swift:100–101`).
- **Device certificate.** Each coach device carries one, signed by the coach key, binding:
  - the device's transport signing key;
  - a device label;
  - issue and expiry dates.

  A certificate is minted the first time Coach runs on a device that has the synced coach key.
- **Handshake:** the coach device presents its certificate after the identity handshake. The
  trainee's Fernlet checks that it chains to the coach key stored in their coach record. A new coach
  device therefore needs no new pairing.
- **Links** (D1) are signed with the coach key, so any coach device can send them.
- **Training summaries** are sealed to the coach's X25519 key, so every coach device can open them,
  and they sync with the rest of Coach's data.
- **Losing a device:** the coach removes it in Coach settings. Its certificate goes on a short
  revoked list that travels in the next handover, and certificates also expire (proposed: 1 year).
  The coach key itself rotates only if the coach chooses to re-pair everyone.
- **iCloud Keychain off:** Coach works on that one device only, and onboarding says so plainly.
  Pairing and links still work from that device.

**C4. Coach pairing ceremony**
- Today's `CoachVerificationCeremony` (`Trust/CoachVerificationCeremony.swift:23`) reuses the friend
  QR crypto purposes (`CryptographicPurpose.swift:263–264`), so friend and coach codes are
  interchangeable. Give it coach-specific purposes.
- **The coach's screen shows the code and the trainee's iPhone scans it.** Macs have no system
  scanner, and code direction isn't enforced today.
- Keep the 2026-07-26 nonce rules: bind the nonce to the peer, sign only after checking, and drop a
  wrong-peer challenge without clearing.

**C5. The coach connection: a profile of the one-to-one session** (the recipe radio,
generalized in A).
- **Roles:** the coach only listens and the trainee only dials (`CoachSessionContract`, which
  nothing enforces today).
- **Starting a session (decided: O17)**
  1. **The coach starts a session.** Their device advertises a coach session, listener only. The
     advertisement carries the protocol version, a random per-session ID, the coach's chosen
     display name, and a short session code also shown on the coach's screen
     ("Coach Sam · 4821"). It carries no keys, fingerprints or trainee details.
  2. **The coachee taps to connect.** In Fernlet, "Connect to a coach" lists nearby coach
     sessions; the session code tells two coaches in one gym apart. Fernlet browses only while
     that screen is open, never in the background.
  3. **It locks.** The coach's listener takes the first dialer and stops advertising, the way the
     recipe radio pauses discovery, so nobody else can join (`maxTunnels = 1`).
  4. **Identity before any data:**
     - The TLS and identity handshake runs, then the coach device presents its certificate (C3).
     - **A returning pair** recognizes each other from their records, and the session continues
       with no extra step.
     - **A new coachee:** the coach sees "Alex's iPhone wants to connect" (Accept / Decline).
       First-time pairing then runs the ceremony from C4: the code on the coach's screen,
       scanned by the coachee's iPhone, plus the matching safety code.
     - **The wrong person:** if they tapped first, the coach declines. The session unlocks and
       advertises again.
     - The coach's device sends nothing to a peer that is neither paired nor accepted.
  5. **Unlocking:** ending the session, or "Let someone else connect", unlocks it for the next
     coachee.
- **Admission:** the coach accepts or refuses the dialer after the identity handshake, not from a
  browse-resolved hello. That replaces the recipe radio's inbound check, which can't work for a
  listener that never browses.
- **Abuse:** a stranger can hold the slot only until the coach declines. Rate-limit repeat dials
  from the same transport key.
- **Privacy note for the policy:** anyone nearby with Fernlet can see that "Coach Sam" is hosting a
  session while it's advertising. The coach chooses that display name, and it can be generic.
- **Fixes the coordinator needs:**
  - a sealed send that works before confirmation; `sendPayload` throws `.notConnected` until then
    (coordinator :414–417);
  - a confirmation timeout long enough for pairing; it is 30 s today (:350);
  - binding the introduction to the TLS exporter, as the mesh does, so a dialer doesn't learn the
    coach's key for free;
  - the 4 MiB size gate before decoding stays.
- **Run policy:** a coach row in `ProximityRunPolicy`: foreground only, opt in, with the standard
  hard stops.
- **Bonjour:** a new QUIC service type (for example `_fernlet-coach2._udp`) and ALPN
  `fernlet-coach-v1`, in both apps' `NSBonjourServices`. Retire the held `_fernlet-coach._tcp/_udp`.
  Rewrite `NSLocalNetworkUsageDescription`, which mentions friends only. The Mac app needs the
  sandbox `network.server` and `network.client` entitlements.
- **No UWB:** nothing on this path needs it, so iPad and Mac work.

**C6. What travels over the coach connection** (sealed and signed; the types are defined in C1)
- Coach to trainee: plan (CoachPlan v2 packet), plan changes, recipe (`SharedRecipePayload`).
- Trainee to coach:
  - the training summary (`TrainerExportPayload`, sealed to the coach, only when the trainee
    chooses);
  - a small **decision receipt** (saved, needs a decision, kept both, removed an exercise), so the
    coach sees results during the session.
- The O11 quiet-save rule applies to in-person handovers as well as links.

---

## 7. Workstream D: coach plan links (fernlet.com)

**D1. Link format**
- `https://fernlet.com/plan/#<payload>` and `https://fernlet.com/recipe/#<payload>`. Use the
  trailing slash: GitHub Pages redirects `/plan` to `/plan/`.
- The fragment never reaches GitHub or Apple.
- **Payload:**
  - a version prefix, then unpadded base64url of a frame;
  - frame = a 4-byte header + raw DEFLATE of the document;
  - document = the exact packet bytes plus a signed header: kind, packet ID, SHA-256 of the packet
    bytes, coach identity key, addressee ID, created date, and an optional expiry.
- **Signature:** over a `CanonicalByteWriter` transcript, with new purposes
  `fernlet.coach.plan-link.v1` and `fernlet.coach.recipe-link.v1`, registered through
  FernletConnections. This bumps the registry pin (`MeshRoutedItemSealTests.swift:511–523`) and
  adds rows to `CryptographicDomainSeparationTests` and `Docs/Crypto-Domain-Separation.md`. Signing
  the hash of the packet bytes avoids re-encoding the plan.
- **Framer:** reuse the Messages v2 framer, made public with its limits passed in. It hard-codes
  Messages limits today and its 2-byte length caps documents at 65,535 bytes.
- **Not `FernletIdentityEnvelope`:** it requires sealing for plan types, and it throws on a
  recipient mismatch, which breaks O12.
- **Size:**
  - Measured: a 4-week plan with demo links compresses to roughly 2.8 KB of URL text.
  - Proposed link caps: about 6 KB compressed and 64 KB inflated.
  - The device prototype (§10, P0.1) confirms them.

**D2. Fernlet: receiving a link**
- Add the Associated Domains entitlement `applinks:fernlet.com` to `App/Fernlet/Fernlet.entitlements`.
- **Dispatcher.** SwiftUI delivers a universal link to `.onOpenURL`, which today
  (`FernletApp.swift:409`) would silently drop it. Replace that handler with one dispatcher:
  - `fernlet://messages/...` keeps the existing route;
  - https on host `fernlet.com` with path `/plan/` or `/recipe/` becomes a link request.
  - Compare scheme and host as separate values. A `"https://fernlet.com"` string literal would fail
    `NoTrackingBoundaryTests`, because fernlet.com is deliberately not an allowed destination.
- **Holding the request:** verify in memory, then store the packet in a protected inbox record and
  keep only its ID, with an expiry, in UserDefaults. Never park the plan itself there.
- **Consuming it:** a third ContentView consumer, gated like the others on launch completion and
  `rootSheetIsCoveringTabs` (:920–926).
- **Flows, in order:**
  1. Malformed, tampered or bad signature: refuse. "This link is incomplete or damaged." Nothing is
     saved.
  2. Newer format: "Update Fernlet to open this plan."
  3. Signed by the trainee's paired, unrevoked coach, addressed to them, with link consent on:
     **quiet save** (O11, see E4).
  4. Anything else: the O12 notice, with Keep it / Don't keep. Keeping runs the trainee's own safety
     check and the E4 decision flow, with provenance "from a coach you haven't paired with" or
     "meant for someone else".
- **Replay ledger:** reuse `ExchangeImportLedger` so opening the same link twice does nothing. It is
  per device.
- **Wipe coverage:** pin the new inbox and keys in `PersistedSurfaceWipeBoundaryTests` and
  `PrivacyWipeCoverageTests`.

**D3. Coach: sending a link** (Mac, iPad, iPhone)
- Build the link, then offer the system share sheet (`NSSharingServicePicker` on Mac) with
  suggested text ("Week 3 is ready. Tap to open it in Fernlet."), plus "Copy link".
- Optional: fetch the demo pages' titles on the coach's device and carry them in the plan, so the
  trainee's phone never has to contact those sites to show a title.

**D4. Site: universal-link file and preview pages**
- **Association file:** `Site/.well-known/apple-app-site-association` containing:

  ```json
  {"applinks":{"details":[{"appIDs":["3RTUPF8FFH.MBO.Fernlet"],"components":[{"/":"/plan/*"},{"/":"/recipe/*"}]}]}}
  ```
  - GitHub Pages serves it as `application/octet-stream`. Apple's association CDN accepts that; it
    was tested on github.io sites on 2026-10-01.
  - **Keep `upload-pages-artifact@v3` pinned** (`pages.yml:84`) with a comment, because v4 silently
    drops dot-folders. Add a workflow step that checks the file is in the uploaded artifact.
  - Lift the "do NOT add yet" reservation in `Site/README.md:108–115` and add `/recipe/` to it.
- **`/plan/` and `/recipe/` pages:**
  - The same CSP meta as every page. One new same-origin script (`preview.js`). No network
    requests, no storage.
  - Decode the fragment in the browser (base64url → header → `DecompressionStream('deflate-raw')`
    → JSON).
  - Render **as text only**: `textContent`, never `innerHTML`. Anyone can craft a fernlet.com link,
    so demo links show as host text, not clickable links, and the coach name is shown as written,
    never as verified.
  - A broken link shows "incomplete or damaged" and never partial content.
- **Without JavaScript,** the page still explains the link and offers the App Store link. That keeps
  the site's "works without JavaScript" rule.
- **App Store:**
  - the Smart App Banner meta tag (`apple-itunes-app`), once Fernlet has a public App Store ID;
  - a plain App Store link, which needs `apps.apple.com` added to the off-origin allowlist in
    `pages.yml:73–80`.
- **Open Graph:** title, description and a same-origin 1200×630 card image. The card is the same for
  every link.
- **Tests:**
  - the same golden vectors (§11) decoded by a small `node --test` step in `pages.yml`, which runs
    on ubuntu with no packages;
  - a check that every page carries the CSP meta.
- **Docs:** update `Site/README.md` and `Docs/No-Tracking-Wall.md` §1. The claim becomes one more
  first-party script, still with no storage and no requests.
- **Privacy policy:**
  - a short clause on coach links: what a link contains, that the fragment never reaches a server,
    and what the preview page does;
  - also the in-person coach connection;
  - in all three copies, with `PrivacyPolicyParityTests` and the workflow markers updated and the
    effective date bumped (owner wording, light touch).

---

## 8. Workstream E: Fernlet trainee side

**E1. CoachPlan v2** (`FernletDomainModel/CoachPlan.swift`, schemaVersion 2)
- **Rest times:**
  - `restSeconds` is honoured end to end.
  - One agreed range in both the format and the in-app editor: proposed 0–600 s. Today the format
    allows 0–900 and the editor 20–300 (`WorkoutRestGuidance.swift:47–51`). 0 allows supersets.
- **Demo links:**
  - New `demoURL`: https only, public host, up to 2,048 characters, validated with the
    `isSafePublicHTTPSURL` rules.
  - Optional `demoTitle`: up to 120 characters, fetched on the coach's device.
- **Catalog IDs:** honour `catalogID` (accepted today but never read).
- **Older builds:** a v1-only Fernlet blocks v2 with "Update Fernlet", which is already the
  behaviour (:779). A hard cutover is fine while there is no real user data.

**E2. Keep the coach's structure, so rest times reach the runner**
- **Store:**
  - New device-local `CoachSessionStore`, keyed by `PlannedWorkout.id`, plus `planID` mapped to the
    coach record.
  - `applyCoachPlan` writes it on every path, so even pasted plans keep their rest times.
  - It follows row delete, copy and edit (ids survive edits and restores).
  - The flattened text rows keep being written, so logs and older views read as today.
- **Runner:**
  - A pure `CoachSession → SessionSuggestion` projector: catalog resolution sets `fromCatalog`, the
    editor's `makeRow` rules infer the role, and the coach's rest becomes `restSecondsOverride`,
    clamped to the E1 range.
  - A store method commits today's coach rows as the guided plan. It is rebuilt at launch and at day
    rollover, because the guided plan lives in memory.
  - Add `plannedWorkoutID` to `GuidedWorkoutRunState` and to the logged `Workout`, so finishing a
    run completes the planned row.
- **Undo fix:** `reconstructPlannedWorkout` recognises `.coach` from the stored source, not from note
  text. Today it brings a removed coach log back as a user plan.
- **Unchanged:** the Live Activity and its intents already read rest times from the run file.
- **Wipe and export:** a `PrivacyWipeCoverage.md` row, a `wipeManifest` token, a call in the delete
  path, a `DeleteAllDataTests` assertion, and an export entry.

**E3. Demo links on the trainee side**
- A "How to" button in the runner and a link chip on plan rows.
- Tapping shows a confirmation naming the site, plus the title if the coach sent one: "This opens
  youtube.com outside Fernlet. Your coach added this link."
- Then `openURL`, which hands off to Safari or the YouTube app.
- Never prefetch or preview on the trainee's phone; follow the peer-supplied URL pattern.
- No `SFSafariViewController`: it leaves the wall's presenter pin unchanged, and macOS doesn't have
  it.

**E4. Quiet save, asking only when needed** (O11)
- **Start:** verify, then preview with "keep existing workouts", which re-runs the safety filter
  (avoid lists and equipment) and the collision check.
- **Clean:** apply it, then show a brief "Saved: Week 3 strength, 5 workouts from Coach Sam" with
  View and Undo.
  - Undo removes the imported rows and their coach-session records. Nothing was replaced, so there
    is nothing to restore.
- **Not clean:** show a "Needs your decision" sheet that lists only the clashing exercises (Keep or
  Remove, with the reason) and the overlapping days (Replace or Keep both), then apply.
- **Never** keep a flagged exercise automatically.
- **Recipes:** recipes have no safety or collision step, so they always save quietly: "Saved to your
  recipes" with Undo.

**E5. Plan provenance**
- Give `applyCoachPlan` and `CoachPlanReviewView` a provenance input: pasted, Shortcuts, Messages
  card, in person (paired), link (paired), or link (not paired / someone else).
- Use it for the screen copy, the audit wording (today every import logs "Imported a pasted plan",
  `CoachPlanImporter.swift:648–655`) and a stored fingerprint.

**E6. Your coach** (Settings)
- A list of coaches and a detail page: trust basis, paired date, last plan, and consent switches
  ("Receive plans and recipes", "Ask before sharing my summary").
- "Remove coach" keeps accepted plans and logged workouts.
- **Pairing:** browse and dial the coach connection, scan the coach's code, confirm.

**E7. Recipes from a coach**
- Reuse `SharedRecipePayload`, the incoming-recipe review sheet and the importer.
- Add a provenance label.
- Give no friend-closeness credit.
- Follow the E4 quiet-save and O12 notice rules.

**E8. Sharing back:** "Send to Coach Sam" on the existing Share-with-a-trainer screen while
connected (`TrainerExportPayload`, sealed to the coach).

**E9. Manual plan exchange setting**
- Fix the doc comment at `SettingsModel.swift:245–252`. It wrongly claims a default install has no
  unverified-plan path; the test message at `CoachPlanExchangeTests.swift:1016–1019` repeats the
  claim.
- Gate **all** unverified paths with it: paste, the Shortcuts import intents, and Messages-card
  imports (O14).
- Links and in-person plans use the per-coach consent instead.

---

## 9. Workstream F: the Coach app (`fernletcoach`)

**F1. FernletKit prerequisites** (done in `fernlet`, behaviour-identical for Fernlet)
- Move `WorkoutExercises.json` into FernletDomainModel as a `Bundle.module` resource. Today
  `Bundle.main` (`WorkoutModels.swift:1210`) gives Coach an empty catalog.
- Decouple FernletLock from PrivateHealthStore. It links the cycle store only for
  `PeriodLockContext` and draining narratives; use injected on-unlock hooks instead.
- Narrow library products: FernletUI, FernletDomainModel, FernletExchange, FernletConnections,
  FernletLock (+UI), FoodCatalog, FernletScoring.
- Parameterize what Coach would otherwise inherit from Fernlet: App Group, iCloud container and
  keychain service names in the modules Coach links, and FernletLockUI's Fernlet-specific copy.

**F2. Repository layout**
- `vendor/fernlet` as the submodule (pinned commit).
- One multiplatform SwiftUI app target (iPhone, iPad, native Mac).
- Packages: the submodule's FernletKit by local path, plus ProximityKit at the same tag (§3.1).
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, to match FernletKit's modules.

**F3. Data, synced (O7)**
- Core Data with CloudKit in a new container, `iCloud.MBO.FernletCoach`.
- **Entities:**
  - Trainee: the coach-side relationship record and the latest shared profile;
  - Exercise: custom exercises with required metadata, demo link and cues, plus coach links and cues
    attached to built-ins;
  - Plan: a CoachPlan v2 document, status and trainee;
  - Template;
  - Recipe;
  - HandoverItem: what's queued for each trainee;
  - ReceivedSummary;
  - AuditEvent.
- **Encryption:** trainee health details (injuries, avoid lists, summaries) are stored with
  `allowsCloudEncryption`, so they're end-to-end encrypted in iCloud.
- **Identity keys** are never stored in Core Data. The coach key is a synced keychain item and
  device keys stay on their device (C3).

**F4. V1 features** (they match the design brief, batches 0–7c)
- **App shell:** iPhone tabs; sidebar on iPad and Mac.
- **Onboarding:** coach name, sync and an optional lock (FernletLock).
- **Settings:** identity, sync, lock, audit log and Delete everything.
- **Trainees:** the roster, in-person pairing (the coach shows the code), and a trainee page with
  overview, plans and profile.
- **Exercise bank:** the 90 built-ins plus the coach's own.
  - Required muscles, equipment and pattern, because Fernlet's safety check depends on them.
  - Name-collision rule: a built-in name wins.
- **Plan builder:**
  - 1–30 days; a calendar grid on Mac and iPad, a day list on iPhone;
  - a session editor showing rest suggestions from `WorkoutRestGuidance`;
  - safety flags checked against the trainee's shared profile;
  - templates, duplicating a day or week, and preview as the trainee.
- **Recipes:** an editor with ingredient lookup in the on-device food catalog (FoodCatalog), parts,
  and per-serving macros.
- **Handover session (C5):** the coach radio, quiet-save results and decision receipts.
- **Send by link (D3).**
- **A demo mode for App Review:** Guideline 4.2.3 requires Coach to be useful on its own, which plan
  authoring, templates and export cover. Use a simulated trainee, plus a video in the review notes.

**F5. App Store:** one universal-purchase app record (iOS and macOS), free, US-only (O8). No EU
trader status is needed while it's free and US-only.

**F6. Code walls in `fernletcoach`**
- Copy the Power-of-10 scanner with its own allowlist.
- No-tracking checks: dependencies are exactly ProximityKit and FernletKit; no outbound hosts except
  any demo-title fetch the owner approves.
- Doc coverage, warnings as errors, and CI on a current macOS runner.

---

## 10. Sequencing

**P0: prototypes and setup** (in parallel)
- P0.1 **Link prototype on devices:** does the fragment survive Messages → universal link →
  `.onOpenURL`, on cold and warm launch? Also check the card's look, 6–8 KB links, the SMS
  fallback, and a Mac recipient getting the preview page.
  - Needs the AASA live on fernlet.com and an associated-domains dev build.
  - **Note the standing owner rule from 2026-09-22: no new build on the owner's phone before the
    soak read-out.** Use a second device or wait.
- P0.2 **Connection prototype:** Mac↔iPhone and iPad↔iPhone over QUIC with peer-to-peer Wi-Fi, and
  iPhone↔iPhone in a gym with no Wi-Fi network. There is an open Apple forum report of
  peer-to-peer failing between cellular phones.
- P0.3 The Claude Design round (the brief is ready).
- P0.4 Create the empty `proximitykit` repo. Add the submodule and an empty multiplatform target to
  `fernletcoach`.

**P1: in-tree refactors** (Fernlet behaviour identical)
- A0.1–A0.8 in order, alongside B (FernletUI on Mac). A0.5, the mesh manager split, is the biggest
  step.
- Both edit `Package.swift`, so land B's manifest change first.
- C1–C5 can start against the in-tree code once A0.2, A0.3 and A0.7 land, so Coach's networking
  doesn't wait for the move.

**P2: the move.**
- A1: ProximityKit moves to its repo, tagged 0.1.0, with the example app.
- FernletKit depends on it, and the mesh test batteries stay green.

**P3: in parallel**
- C (FernletConnections, the coach connection, pairing).
- E (plan v2, structured sessions, runner, links UX, consent).
- D4 (the site), once P0.1 passes.

**P4: Coach app V1 (F).** UI starts after B and the design round; networking after C; links after
D.

**P5: end to end.** Device validation (in person and by link), the privacy policy update, App Store
setup and TestFlight.

**Later:** session notes, progress dashboards, a live session mirror, group classes (the routed mesh
engine generalized in ProximityKit), and the item design app as the second family profile.

---

## 11. Testing and code walls

- **Mesh batteries:** they stay green through A0 and A1 (the CI mesh line and its floors).
- **Golden vectors for links:**
  - Fernlet's Swift tests produce fixtures checked into `fernlet`.
  - Fernlet's importer tests decode them, and so does the site's `node --test` step.
  - Coach's encoder is tested against the same fixtures.
- **Cross-version wire fixtures** in ProximityKit: older-peer bytes that newer builds must keep
  accepting or politely park.
- **New build lanes:** macOS and iPad for FernletUI, ProximityKit and Coach.
- **Fernlet wall updates:**
  - `NoTrackingBoundaryTests`: the package allowlist gains ProximityKit's URL, the Bonjour types are
    reclassified, and the local-link permits move to ProximityKit's repo.
  - Power-of-10 allowlist entries for ProximityKit paths move with it.
  - `LocalizationBoundaryTests`: ProximityKit's strings move.
  - Persisted-surface and wipe rows for the coach records, the link inbox and the coach-session
    store; `DeleteAllDataTests`.
  - `CryptographicDomainSeparationTests` (new purposes); `PrivacyPolicyParityTests`.
- **ProximityKit's own walls:** no tracking SDKs, the local-link API only in the radio files, no
  URLSession at all, the Power-of-10 scan, doc coverage, and builds for iOS and macOS.

---

## 12. Risks

1. **Extraction size.** ProximityKit is ~67k lines, and the routed mesh manager alone is ~16.6k with
   Fernlet features woven in. Stage it, keep Fernlet behaviour identical, and lean on the mesh
   batteries.
2. **Device testing vs the soak rule** (P0.1 note).
3. **Peer-to-peer Wi-Fi with cellular phones** in gyms (P0.2).
4. **The link fragment surviving Messages.** If it doesn't, the fallbacks are a file, or the
   deferred dead-drop. Never the query string, which would reach GitHub's logs.
5. **Coach identity across devices** (C3).
6. **Quiet save must never auto-keep a flagged exercise** (E4).
7. **App Review 4.2.3:** Coach must stand on its own (F4).
8. **Wire compatibility:** a hard cutover is acceptable while there is no real user data, but the
   owner's own devices need matching builds.
9. **Font licensing:** OFL texts (task filed).
10. **Crafted fernlet.com links:** someone can make the site display text they chose. Mitigated by
    text-only rendering, no clickable links, and a label saying the app checks who sent it.
11. **`@testable` across repos** (A1.4): 116 Fernlet test files rely on it. Check this before the
    move.

---

## 13. Small decisions still open

1. ProximityKit's repo name, and the shape of its protocol-namespace API.
2. **Rest range:** 0–600 s in both the format and the editor (proposed).
3. **Link expiry:** none, or a soft limit (for example "This plan link is 60 days old. Save it
   anyway?").
4. **Coach on Mac:** a handover device too (needs the coach connection on Mac), or planning only.
   Decide after P0.2.
5. **Privacy policy wording** for coach links and the coach connection (owner).

Decided 2026-10-01 and moved to §1: the synced coach key (O16) and broadcast, tap, lock session
start (O17).
