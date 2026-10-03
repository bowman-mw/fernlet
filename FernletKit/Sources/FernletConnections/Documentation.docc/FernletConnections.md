# ``FernletConnections``

Fernlet's connection rules on top of ProximityKit's mechanisms. Today it holds `ProximityNamespace.fernlet`, Fernlet's protocol identity on the wire, in the keychain and on disk, with its payload vocabulary and the app's peer-name policy; `FernletDeviceBindingAdapter`, Fernlet's install binding for ProximityKit's column seal; ``FernletAuditBridge``, the sink that sends ProximityKit's audit lines to `FernletAuditLog`; ``ProximityTrustVault``, Fernlet's trusted-peer records and audit rows, which answers ProximityKit's trust questions; and Fernlet's session rules: ``FriendSessionTrustPolicy``, the policy the app hands ProximityKit for every connection, ``CoachSessionTrustPolicy`` and ``CoachSessionContract`` for the coach channel, ``FriendMintingReview`` for the keep-as-friend review, ``TrainerExportPayload``, the coach channel's export body, and the one conversion from the session audit ProximityKit's coordinator reports to Fernlet's persisted `TrainerAuditEvent`.

## Overview

`FernletConnections` is where Fernlet's side of the ProximityKit split lives. ProximityKit is
becoming a drop-in package any app can use, with nothing Fernlet-specific in its API
(`Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md` §3.2); owner decision O3 puts Fernlet's own
connection types and rules in FernletKit instead, on top of ProximityKit's mechanisms. This module
is that place.

**The namespace (plan step A0.2.2).** One value and its parts, in `FernletProtocolNamespace.swift`:

- `ProximityNamespace.fernlet`, Fernlet's whole protocol identity, built from the two halves below.
- `ProximityNamespace.Family.fernlet`, what every app on Fernlet's wire shares: the 39
  domain-separation labels (`Purposes.fernlet`, grouped as `Signature`, `KeyDerivation`, `AEAD` and
  `Hash`, each `.fernlet`), the three radios' service types, ALPNs and the mesh heartbeat with the
  three presentation strings (`Radios.fernlet`), the `fernlet` QR scheme, and the payload vocabulary
  (`Vocabulary.fernlet`, below).
- `ProximityNamespace.Installation.fernletApp`, what belongs to the Fernlet app on one device: the
  identity's keychain service and four accounts, the two seal-key rows, the `Fernlet` storage
  directory with its three on-disk names, the radios' log subsystem, and the peer-name policy
  (`PeerNames.fernlet`, below).

Every literal is today's, byte for byte, and pinned: `ProximityNamespaceGoldenTests` (on the
`crypto-goldens` CI line) compares each value with the frozen literal column written before any
A0.2 commit, requires `ProximityNamespace.fernlet.soundness == .sound`, holds the 38 labels
FernletCrypto's registry also declares to the same spelling and the same signing acceptance, runs
the "no label is a byte prefix of another" check over FernletCrypto's 81 registry labels and these
39 together, and checks that the bytes each hash and transcript consumer writes today begin with
the field's prefix.

That `.sound` verdict is load-bearing at run time: ProximityKit refuses an unsound namespace on its
own, failing closed with a named audit event before an identity provisions or wraps a group key and
before a radio starts, so it is what lets the app's identities provision and its three radios come
up. Each ProximityKit manager also refuses to start its radio under an identity of another namespace
than its host's, which no app path hands it: the managers build their own identities from the
store's `.fernlet`, and so does every other `IdentityService` the app builds.

**How the app supplies it (plan step A0.2.3).** ProximityKit's `ProximityHost` requires a
`proximityNamespace` and gives it no default, so the app is what hands `.fernlet` over: the
`FernletStore` adapter (`App/Fernlet/ProximityHostAdapter.swift`) answers `.fernlet`, `nonisolated`
because it is inert value data. The mesh, presence and recipe-share managers read it once at
construction, keep their own copy and build their default identity from it; every other
`IdentityService` the app builds says `IdentityService(namespace: .fernlet)` (the sealed-backup,
own-photo, duress-recovery and launch paths, the readout and the DEBUG probe), and the heart-drop
service's identity is built from the store's `proximityNamespace`. The identity's keychain service,
`com.fernlet.identity`, is the first value ProximityKit reads off it. Eleven of the test target's
`ProximityHost` doubles supply the same value (`ProximityNamespaceGoldenTests`' three hosts take
theirs from the cell that builds them, another app's in the cells that test one), and its
`ProximityNamespaceTestBindings.swift` restores the old `IdentityService()` and
`IdentityService(keychainService:)` call shapes by passing
`.fernlet`. Since step A0.2.4 ProximityKit also reads thirteen of `Purposes.fernlet`'s labels: the
identity envelope's, the admission token's, the membership, quorum and key-agreement transcripts',
the inventory digest's hash domain and the legacy pair, which `.fernlet` accepts so that Fernlet's
schema-v1 and pre-WI-6 peers verify exactly as before (a family that refuses legacy peers would
reject them); the bindings file restores those serializers' and verifiers' old call shapes with
`.fernlet` too. Since step A0.2.5 ProximityKit reads nine more labels and the QR scheme: the channel
introduction's, the six routed transcripts' and both verify-QR labels, and `Family.fernlet`'s
`fernlet` scheme, which every verify code the app shows carries and every code it scans must match.
That settles who owns `fernlet.verify.response.v1`: the app's duress-recovery ceremony signs and
checks ProximityKit's response transcript under its identity's `purposes`, so the label is
ProximityKit's, supplied here, and only the two duress labels stay the app's own. The ceremony's
view parses a scanned code with `ProximityVerifyQR.parse(url, in: .fernlet)`, and the bindings file
restores the routed and QR call shapes with `.fernlet`. Since step A0.2.6 ProximityKit reads fourteen
more: the five routed hash and id domains, the five AEAD labels, the three HKDF salts and the epoch
id's domain, `fernlet.mesh.epoch.v1`, which ProximityKit used to spell for itself
(`MeshEpochBounds.derivationDomain`, now deleted) and now takes from `Hash.fernlet` like any other
label. Every sealed payload, group-key wrap, encrypted-metadata wrapper, routed item seal, content-key
wrap, content hash, chunk and receipt id and epoch id is therefore derived from `.fernlet`'s bytes,
which are today's, so none of them moves; the bindings file restores those call shapes with `.fernlet`
too. Since step A0.2.7 the three radios are built from the namespace their manager holds and read
`Radios.fernlet`'s service types, ALPNs and heartbeat, the TLS exporter label and
`Installation.fernletApp`'s log subsystem off it, so every advertisement, negotiation, beat and
channel binding is spelled exactly as before; the bindings file restores the radios' argument-less
initializers with `.fernlet`. Since step A0.2.8 ProximityKit reads `Installation.fernletApp`'s at-rest
names and rows too: the mesh stores' file names, chunk directory and seal-key accounts, the production
seal-key services, the default sidecar root and the identity's four accounts. The app hands
`.fernlet` to both storage scopes and resolves its proximity root from it, so every file and keychain
row keeps its name; the bindings file restores the seal-key reads and the identity-row classifier
with `.fernlet`'s rows. Since step A0.2.9 the two mesh stores seal under `KeyDerivation.fernlet`'s two
column seals too, `fernlet.mesh.session-context.v1` and `fernlet.mesh.routed-store.v1`, the last of the
39 labels to move, each read off the store's scope namespace, so every sealed file opens exactly as
before.

**The payload vocabulary and the presentation strings (plan step A0.3).** `Family.fernlet` also
carries `ProximityNamespace.Vocabulary.fernlet` (`FernletPayloadVocabulary.swift`), Fernlet's shared
wire tokens and the rules that hang on them, each part `.fernlet`:

- `SessionMessages.fernlet`, the coordinator's three session messages: the identity introduction
  ("Hello"), its acknowledgement ("Identity acknowledged") and the session heartbeat ("Heartbeat",
  answered by "Heartbeat ack"), each with its `PayloadType` token. A title is signed into its
  envelope, so it is a wire token like the payload type: frozen English, never localized.
- `PayloadRules.fernlet`, every `PayloadType` token (the 55 the host dispatches; any other token
  authenticates but is parked) and the seventeen whose payload must arrive sealed.
- `Capabilities.fernlet`, every `ProximityCapability` token in declaration order, `wire2` as the
  wire2 framing's token, and photos alone for a peer whose introduction lists no capabilities.
- `MembershipRecordKinds.fernlet`, the four record kinds the inventory digest hashes, each the
  `PayloadType` token of the frame that carries its record, and `RoutedTypes.fernlet`, the routed
  engine's photo, temporary-message, heart and reserved control types.
- `MeshMessages.fernlet`, the mesh engine's thirty messages: the membership, admission,
  routed-delivery, group-key and verify-ceremony frames and the legacy goodbye it parses, each under
  the `PayloadType` token Fernlet's mesh has always sent it under.

Payload and capability tokens are read off FernletDomainModel's `PayloadType` and
`ProximityCapability`, and so are the record kinds (a record kind IS its payload token) and the mesh
messages, so each keeps one spelling. The routed types and the session titles have no `PayloadType`
twin and are spelled here alone. ProximityKit reads every group off the namespace, so it spells none
of them: its identity envelope refuses an unsealed envelope whose token is in the sealing set and
parks one whose token is outside `known`; its coordinator signs its introduction, acknowledgement and
heartbeat under the session messages' tokens and titles, dispatches by them, and reads the wire2
token, the legacy assumption and its receive bound (twice the capability count) off the capabilities,
whose wire2 token the mesh's sealed sends read too and the mesh and presence managers advertise; its
inventory digest tags every record with its family's record kind; its routed type registry builds its
three rows from the routed types (the mesh manager hands it its namespace's); and its mesh manager
names each of its own frames by role (`MeshPayloadRole`), signs it under the mesh messages' token
for that role and resolves every token its payload door receives back to a role by them. Its mesh
features' payload and capability tokens are still `PayloadType` and `ProximityCapability` cases until
plan steps A0.4 and A0.5 move them: the manager sends a feature's payload under the case's token and
keeps its feature handlers by token.

`Radios.fernlet` carries the three presentation strings beside the radio values, and ProximityKit
reads each of them off the namespace: `fernlet-mesh-`, the prefix the mesh and recipe-share radios'
Bonjour instance names begin with and the one `PeerNameDisplay` never shows as a person's name,
`fn-`, the presence posture's (the prefix and its separator together), and `fernlet-mesh`, every
ephemeral certificate's common name. The radios read them from the namespace their manager hands
them, the presence manager's posture mint from its own copy, and the name display from the
namespace each caller passes: the app passes `.fernlet`, and so does `FernletProximityUI`, which
depends on this module for it. `ProximityVocabularyGoldenTests` holds every `.fernlet` value to its
frozen literal, so no spelling can drift, drives those consumers (and the inventory digest, the routed
type registry and a mesh manager) under `.fernlet` and under a namespace whose strings, record kinds
or routed types are its own, drives the envelope, the coordinator and the mesh's sealed sends under
`.fernlet` and under a namespace whose payload rules, session messages or capabilities are its own,
drives a mesh manager's own sends and dispatch under a namespace whose mesh messages are its own,
and holds the bounds ProximityKit's soundness rules apply to the bounds of the consumers they
protect. `ProximityNamespace.fernlet` stays `.sound` under the vocabulary and presentation rules too.
The test target's bindings file restores the routed suites' old call shapes (`MeshRoutedTypeToken`,
the two `increment1` values, the mint without a registry) with `.fernlet`'s routed types, the
membership verifier's, the adoption's and the digest's with `Family.fernlet`, and a peer's capability
gate with `.fernlet`'s capabilities.

**The peer-name policy (plan step A0.3).** `Installation.fernletApp` also carries
`ProximityNamespace.PeerNames.fernlet`, how the Fernlet app shows a name a peer supplied: at most 24
characters of it once sanitized (`ItemNameModeration.maxNameLength`, the cap Fernlet's item names
share, read rather than respelled so the two keep one spelling), and "A friend" for a name with
nothing displayable left. ProximityKit sanitizes every peer's name with its own copy of the generic
sanitizer and applies the cap and the floor of the namespace each reader holds (the mesh, presence
and recipe-share managers, the session message store, the envelope's two sender reads and the name
display), and caps the recipe radio's advertised name at the same cap. Its soundness rules hold the
cap to 1–63 characters and the floor to a non-empty name the sanitizer leaves unchanged;
`ProximityVocabularyGoldenTests` pins both values to the literals ProximityKit shipped and holds
ProximityKit's sanitizer to FernletDomainModel's byte for byte. The activities' titles, locations
and roster names still go through `ItemNameModeration` until activities leave ProximityKit (plan
step A0.4). The test target's bindings file restores the old call shapes of the coercion, the
envelope's sender reads, the advertised recipe name and the session message store's ingest with
`.fernlet`'s policy.

**The install binding (plan step A0.2.9).** ProximityKit's copy of the column seal,
`ProximityColumnCrypto`, mixes the install binding into every mesh blob's authenticated data, and asks
the host for it through `ProximityInstallBinding` instead of reading FernletCrypto's `DeviceBindingID`
itself. `FernletDeviceBindingAdapter` (`FernletDeviceBindingAdapter.swift`) is Fernlet's answer: a
stateless value that delegates to `DeviceBindingID` at each call — `current()` for a seal, which may
mint the row; `currentForOpen()` for an open, which never mints and whose retryable `ReadError` it
translates into ProximityKit's `ProximityInstallBindingReadError` with the same status. Delegating
rather than copying keeps one row, one cache, one mint path and one task-local test seam: the mesh
stores keep sealing under the 16 bytes Fernlet's sealed private stores share, and every
`DeviceBindingID.$testOverride` in the suites, including one flipped in the middle of an operation,
still decides what they seal and open under. The app's `ProximityHost` adapter answers
`proximityInstallBinding` with one, `FernletStore`'s two storage scopes carry it, and so do the test
target's `ProximityHost` doubles and store fixtures, but for the `ProximityNamespaceGoldenTests` cells
that hand a host or scope a pinned binding of their own.

**The audit bridge (plan step A0.2.10).** ProximityKit writes every audit line through
`ProximityAudit.log(_:context:)` to the `ProximityAuditSink` its host installed, and drops the line
while none is. ``FernletAuditBridge`` (`FernletAuditBridge.swift`) is Fernlet's: it hands each event
name and context to `FernletAuditLog.log(_:context:)` unchanged, on the emitting executor, before it
returns, so the unified log and every test that captures a ProximityKit event through
`FernletAuditLog.addCaptureHandler` see exactly what they saw when ProximityKit named
`FernletAuditLog` itself. `FernletApp.init` installs it first, before anything can build a
ProximityKit object, and unconditionally, since the unit tests are hosted in the app.
`ProximityAuditBridgeTests` (on the `s3-grep` CI line) is the canary: a ProximityKit line must reach
a `FernletAuditLog` capture handler verbatim before the call returns, or every test asserting that
an event was NOT logged would pass vacuously; it also holds ProximityKit's code to naming
`FernletAuditLog` nowhere.

**The session rules (plan step A0.3).** ProximityKit is mechanism: which peers a session trusts, how
a coach pairs and what the coach channel carries are Fernlet's rules, and the records they are judged
against are Fernlet's, so they live here, each with its name, members and behaviour as it had in
ProximityKit:

- ``FriendSessionTrustPolicy`` (`FriendSessionTrustPolicy.swift`), the friend radios' policy:
  proximity is the authorization, so every peer is trusted and only a blocked key is refused (a
  revoked-only, "Removed", peer may handshake again in person). ProximityKit's `ProximityHost`
  requires `makeProximityTrustPolicy()` with no default, and the app's adapter answers a fresh one
  over the store's vault for every connection the mesh, presence and recipe-share managers open;
  each manager keeps it beside the connection, because the coordinator holds its policy `weak`.
  Every test double answers the same.
- ``CoachSessionTrustPolicy`` and ``CoachSessionContract`` (`CoachSessionTrustPolicy.swift`): the
  coach channel's remembered, mode-scoped trust (only an unrevoked, unblocked `.trainer` record whose
  mode the build knows auto-confirms; a friend never does) and the written-down role split (Fernlet
  browses, the coach app advertises). No production caller yet; `CoachSessionHardeningTests` holds
  both.
- ``FriendMintingReview`` (`FriendMintingReview.swift`): which session-end review the app presents,
  and which roster entries it may offer as new friends, judged against the trust records when the
  review is presented. `ConnectView`, `DisposableCameraView` and `SessionPhotoReviewCoordinator` call
  it.
- ``TrainerExportPayload`` (`TrainerPayloads.swift`): the coach channel's export body, with its
  `fernlet.trainer.export` format token, its version and two caps derived from ProximityKit's
  `ProximityCoordinator.maxTrainerModeInboundBytes`, the bound a trainer-mode coordinator enforces
  before it decodes anything: the wire cap is that bound and the bundle cap half of it, so Fernlet's
  body always fits inside the mechanism's limit. `ProximityVocabularyGoldenTests` pins the token, the
  version, the body's JSON bytes and both caps beside the coordinator's bound.
- `TrainerAuditEvent.init(_:)` (`TrainerAuditEvent+SessionAudit.swift`): the one conversion from what
  ProximityKit's coordinator records through its policy, a `ProximitySessionAudit`, to the row
  Fernlet's vault keeps and its snapshot persists. The id, timestamp, peer fields and message are
  copied unchanged, the kind maps case for case by an exhaustive switch, and the envelope's token is
  read as a `PayloadType`: a token this build does not know becomes no payload type, with nothing
  parked. Both policies and the app's `FernletStore` record through it, and
  `ProximityVocabularyGoldenTests` holds a converted audit to the frozen row's JSON, byte for byte,
  and each kind to the token its row persists under.
- ``ProximityTrustVault`` (`ProximityTrustVault.swift`): Fernlet's records of the people its radios
  meet, in FernletDomainModel's persisted types: kept friends, revoked ("Removed") peers, blocked keys
  and reported sellers, keyed on the full signing key, and the audit trail, capped at 500 rows. It
  mints them (`trust`; `block` and `report`, with a stub for a key it has never seen), re-derives a
  legacy 8-character fingerprint from the signing key on every load and calls `onChange` after each write;
  the app's `FernletStore` owns it, seeds it from the snapshot and saves on `onChange`. It answers
  ProximityKit's `ProximityTrustStore`, which the app's adapter hands over as `proximityTrustStore`
  (every test double hands over its own vault), so the mesh's kept-friend gates and presence's heart
  eligibility ask it whether a key is a remembered, unrevoked peer and whether it is blocked; the two
  policies above wrap it.

The protocols the policies and the vault answer (`ProximityTrustPolicy`, `ProximityTrustStore`), the
audit type the coordinator reports in (`ProximitySessionAudit`), the roster entry and the coordinator
stay ProximityKit's.

**What joins it later.** Nothing here stands in for the coordinator's display name or a per-mode
service type: ProximityKit has neither, every caller passing the host's resolved name and the
radios owning discovery on the namespace's service types. A0.4 makes Fernlet's feature labels host purposes. C1 adds the Coach app's installation (`fernletCoach`, beside
`.fernletApp` and sharing its family), the connection profiles (friend mesh, presence, recipe,
coach), app identities with per-app allow lists, coach relationship records and the coach link
signing purposes; FernletCrypto's 38 twins of these labels then retire.

**Why `.fernlet` lives here and not in ProximityKit.** ProximityKit holds no namespace instance,
offers no default and keeps no global, so a host that supplies nothing gets a compile error, never
another app's identity. The dependency edge runs from this module to ProximityKit, never the
reverse, so ProximityKit cannot name `.fernlet` even by accident; a non-Fernlet app gets Fernlet's
identity only by importing this module or by copying its literals on purpose. It stays in
FernletKit after ProximityKit leaves for its own repository (plan A1), consuming the package by tag.

**Position in the FernletKit graph and the S3 wall.** The target depends on `ProximityKit`; since
step A0.2.9 on `FernletCrypto` (for `DeviceBindingID`, which the binding adapter delegates to); since
step A0.2.10, for the audit bridge, on `FernletFoundation` (Layer 0, which `FernletAuditLog` lives
in); and for the payload vocabulary and the session rules on `FernletDomainModel` (for
`PayloadType` and `ProximityCapability`, whose raw values the vocabulary reads, for
`TrainerAuditEvent`, `ProximityMode` and `ProximityTrustedPeerRecord`, which the policies and the
review read and the vault builds and keeps, and for `TrainerAuditEvent` and `PayloadType`, which the
audit conversion reads, and for `ItemNameModeration`, whose name cap the peer-name policy reads). It imports nothing else but Foundation, Observation (the vault is
`@Observable`) and Security. Through ProximityKit it reaches
`PrivateMediaStore` transitively, which puts it on the protected side of the S3 wall: the walled `AIProviders` and
`CloudKitSync` targets have no edge to it, and
`S3BoundaryTests.proximityAndCloudSyncDoNotImportEachOther()` holds it to ProximityKit's own pair
of rules (nothing here imports CloudKit, and CloudKitSync never imports this module).
`BackgroundRefreshBoundaryTests` forbids the companion refresh handler from importing it, as it
forbids ProximityKit. The directory is code-owned (`.github/CODEOWNERS`) beside FernletCrypto and
ProximityKit's `Namespace/`: a changed literal here is a wire, keychain or on-disk format change for
every device already in the field.

**Isolation.** The module is main-actor by default (`defaultIsolation(MainActor.self)` in
`Package.swift`), matching ProximityKit, and every extension, static and type here is `nonisolated`
but the two trust policies and the vault:
the namespace is inert `Sendable` value data, and its readers are ProximityKit's nonisolated
serializers, verifiers and stores; the binding adapter is a stateless `Sendable` value the column
seal calls synchronously from inside those stores. ``FernletAuditBridge`` is a `nonisolated` struct
for the same reason: ProximityKit's `nonisolated` stores call it synchronously, which a main-actor
conformance would not allow. ``FriendMintingReview``, ``TrainerExportPayload`` and
``CoachSessionContract`` are `nonisolated` pure values. ``FriendSessionTrustPolicy`` and
``CoachSessionTrustPolicy`` stay main-actor classes, like the `@MainActor` protocol they conform to,
the main-actor vault they read and the main-actor coordinator that consults them.
``ProximityTrustVault`` is a main-actor `@Observable` class, like the `@MainActor`
`ProximityTrustStore` it answers and the main-actor managers and store that read it: the Friends UI
observes its records directly.
