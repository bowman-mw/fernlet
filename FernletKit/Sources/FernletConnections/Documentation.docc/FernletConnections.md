# ``FernletConnections``

Fernlet's connection rules on top of ProximityKit's mechanisms. Today it holds `ProximityNamespace.fernlet`, Fernlet's protocol identity on the wire, in the keychain and on disk, with its payload vocabulary, the app's peer-name policy and the two feature salts ProximityKit's pair-secret door derives under (``FernletFeaturePurposes``); `FernletDeviceBindingAdapter`, Fernlet's install binding for ProximityKit's column seal; ``FernletAuditBridge``, the sink that sends ProximityKit's audit lines to `FernletAuditLog`; ``ProximityTrustVault``, Fernlet's trusted-peer records and audit rows, which answers ProximityKit's trust questions; Fernlet's session rules: ``FriendSessionTrustPolicy``, the policy the app hands ProximityKit for every connection, ``CoachSessionTrustPolicy`` and ``CoachSessionContract`` for the coach channel, ``FriendMintingReview`` for the keep-as-friend review, ``TrainerExportPayload``, the coach channel's export body, and the one conversion from the session audit ProximityKit's coordinator reports to Fernlet's persisted `TrainerAuditEvent`; and the name placeholders the app's in-person surfaces show when ProximityKit's `PeerNameDisplay` refuses a name, this module's extension of that type, over its own string catalog.

## Overview

`FernletConnections` is where Fernlet's side of the ProximityKit split lives. ProximityKit is
becoming a drop-in package any app can use, with nothing Fernlet-specific in its API
(`Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md` §3.2); owner decision O3 puts Fernlet's own
connection types and rules in FernletKit instead, on top of ProximityKit's mechanisms. This module
is that place.

**The namespace.** One value and its parts, in `FernletProtocolNamespace.swift`:

- `ProximityNamespace.fernlet`, Fernlet's whole protocol identity, built from the two halves below.
- `ProximityNamespace.Family.fernlet`, what every app on Fernlet's wire shares: the 39 protocol
  labels (`Purposes.fernlet`, grouped as `Signature`, `KeyDerivation`, `AEAD` and `Hash`, each
  `.fernlet`) and the two feature salts its `feature` group declares (`FeaturePurposes.fernlet`,
  below), the three radios' service types, ALPNs and the mesh heartbeat with the three presentation
  strings (`Radios.fernlet`), the `fernlet` QR scheme, and the payload vocabulary
  (`Vocabulary.fernlet`, below).
- `ProximityNamespace.Installation.fernletApp`, what belongs to the Fernlet app on one device: the
  identity's keychain service and four accounts, the two seal-key rows, the `Fernlet` storage
  directory with its three on-disk names, the radios' log subsystem, and the peer-name policy
  (`PeerNames.fernlet`, below).

Every literal is today's, byte for byte, and pinned: `ProximityNamespaceGoldenTests` (on the
`crypto-goldens` CI line) compares each value with its frozen literal column, requires
`ProximityNamespace.fernlet.soundness == .sound`, holds the 40 labels FernletCrypto's registry also
declares (38 protocol labels and both feature salts) to the same spelling and the signature twins to
the same signing acceptance, runs the "no label is a byte prefix of another" check over
FernletCrypto's 81 registry labels and these 41 together, and checks that the bytes each hash and
transcript consumer writes today begin with the field's prefix.

That `.sound` verdict is load-bearing at run time: ProximityKit refuses an unsound namespace on its
own, failing closed with a named audit event before an identity provisions or wraps a group key and
before a radio starts, so it is what lets the app's identities provision and its three radios come
up. (The app's sealed-backup escrow checks no verdict: it rides each identity as its provisioning
participant, which a refused provisioning never calls, and its paths provision the identity first.)
Each ProximityKit manager also refuses to start its radio, and the mesh manager to found a mesh, under
an identity of another namespace than its host's, which no app path hands it: the managers take their
identities from the store's `makeProximityIdentity()`, which answers the app's factory
(`IdentityService.fernletApp(keychainService:)`, under `.fernlet`), and so does every other
`IdentityService` the app builds.

**How the app supplies it.** ProximityKit's `ProximityHost` requires a
`proximityNamespace` and gives it no default, so the app is what hands `.fernlet` over: the
`FernletStore` adapter (`App/Fernlet/ProximityHostAdapter.swift`) answers `.fernlet`, `nonisolated`
because it is inert value data. The mesh, presence and recipe-share managers read it once at
construction, keep their own copy and build their default identity and their radio from it; every
other `IdentityService` the app builds says `IdentityService(namespace: .fernlet)` (the sealed-backup,
own-photo, duress-recovery and launch paths, the readout and the DEBUG probe), the heart-drop
service's identity is built from the store's `proximityNamespace`, and the app hands `.fernlet` to
both storage scopes and resolves its proximity root from it.

ProximityKit reads every protocol label of `Purposes.fernlet` and every value of `Radios.fernlet`, the
QR scheme and `Installation.fernletApp` off the namespace its reader holds, so every signature, seal,
hash, id, advertisement, file and keychain row is spelled from `.fernlet`'s bytes, which are the ones
Fernlet always shipped:

- the 39 labels: the identity envelope's, the admission token's, the membership, quorum,
  key-agreement, channel-introduction, six routed and two verify-QR transcripts', the membership
  inventory digest's and the routed hash and id domains, the five AEAD labels, the three HKDF salts,
  the TLS exporter label, the two column seals the mesh stores seal under (each read off the store's
  scope namespace), and the epoch id's domain, `fernlet.mesh.epoch.v1`, which ProximityKit takes
  from `Hash.fernlet` like any other label and never spells for itself;
- the legacy pair, which `.fernlet` accepts so that Fernlet's schema-v1 and pre-WI-6 peers verify
  exactly as before (a family that refuses legacy peers would reject them);
- the `fernlet` QR scheme, which every verify code the app shows carries and every code it scans must
  match (the duress-recovery ceremony's view parses a scanned code with
  `ProximityVerifyQR.parse(url, in: .fernlet)`). `fernlet.verify.response.v1` is ProximityKit's,
  supplied here: the app's duress-recovery ceremony signs and checks ProximityKit's response
  transcript under its identity's `purposes`, and only the two duress labels stay the app's own;
- the three radios' service types, ALPNs and heartbeat, read by the radios their managers build, and
  `Installation.fernletApp`'s log subsystem;
- the at-rest names and rows: the identity's keychain service, `com.fernlet.identity`, and its four
  accounts, the mesh stores' file names, chunk directory and seal-key accounts, the production
  seal-key services and the default sidecar root.

Eleven of the test target's sixteen `ProximityHost` doubles supply the same value (the other five,
`ProximityNamespaceGoldenTests`' three hosts and `ProximityVocabularyGoldenTests`' two, take theirs
from the cell that builds them: another app's, or Fernlet's with some of its groups replaced, in the
cells that test one). The test target's `ProximityNamespaceTestBindings.swift` restores, by passing
`.fernlet`, the call shapes the namespace took out of ProximityKit: the identity's argument-less and
keychain-service initializers, the serializers' and verifiers' shapes, the routed and QR shapes, the
radios' argument-less initializers, the seal-key reads and the identity-row classifier.

**The feature salts.** `FernletFeaturePurposes.swift` holds ``FernletFeaturePurposes``, Fernlet's
feature labels that a ProximityKit door consumes: `heartDropPairV1` (`fernlet.heartdrop.v1`) and
`presencePairV1` (`fernlet.presence.tag.v1`), the heart dead-drop's and presence's pair-secret salts,
each minted with ProximityKit's `ProximityCryptographicPurpose.featureKeyDerivationSalt(_:)`, the one
role a host mints for itself. `ProximityNamespace.FeaturePurposes.fernlet` declares the same two
values, in that order, and `Purposes.fernlet` carries it as its `feature` group, so `.fernlet`'s one
soundness verdict judges both salts with the 39 protocol labels (each is a row of `labelRows`, at
`family.purposes.feature.<name>`, after the hash rows). ProximityKit's
`IdentityService.pairSecret(with:purpose:)` derives a pair secret only under a salt its identity's
namespace declares and refuses any other purpose (`IdentityError.undeclaredPurpose`), so a caller
passes these constants and the declaration is what lets them derive: one spelling per label on
Fernlet's side. `FernletSocial`'s heart-drop and presence pair secrets pass `heartDropPairV1` and
`presencePairV1` to the door; `ProximityNamespaceGoldenTests` holds each declared salt to its
frozen literal and its FernletCrypto registry twin, and `FernletFeatureGoldenTests` pins the door's
pair secrets under the two salts to the heart-drop and presence derivations' known answers. Fernlet's other feature labels,
which its features hand CryptoKit themselves, stay FernletCrypto registry entries: no ProximityKit
door consumes them.

**The payload vocabulary and the presentation strings.** `Family.fernlet` also
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
depends on this module for it and for the name placeholders below.
`ProximityVocabularyGoldenTests` holds every `.fernlet` value to its frozen literal, so no
spelling can drift, drives those consumers (and the inventory digest, the routed
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

**The peer-name policy.** `Installation.fernletApp` also carries
`ProximityNamespace.PeerNames.fernlet`, how the Fernlet app shows a name a peer supplied: at most 24
characters of it once sanitized (`ItemNameModeration.maxNameLength`, the cap Fernlet's item names
share, read rather than respelled so the two keep one spelling), and "A friend" for a name with
nothing displayable left. ProximityKit sanitizes a peer's name with its own copy of the generic
sanitizer and applies the cap and the floor of the namespace each reader holds (the mesh, presence
and recipe-share managers, the session message store, the envelope's two sender reads and the name
display), and caps the recipe radio's advertised name at the same cap. Its soundness rules hold the
cap to at most 63 characters and at least a key fingerprint's 16 and the mesh instance-name prefix's
length (13 for Fernlet's `fernlet-mesh-`), so the name display, which cuts a name to the cap before it
looks, still hides both identifiers, and the floor to a non-empty name the sanitizer leaves unchanged;
`ProximityVocabularyGoldenTests` pins both values to the literals ProximityKit shipped and holds
ProximityKit's sanitizer to FernletDomainModel's byte for byte. The activities' titles, locations
and joiners' names still go through `ItemNameModeration` (its fixed 24-character cap, with no floor)
until activities leave ProximityKit with the mesh manager's feature parts (plan step A0.5). The test target's bindings file restores the
old call shapes of the coercion, the envelope's sender reads, the advertised recipe name and the
session message store's ingest with `.fernlet`'s policy.

**The name placeholders.** ProximityKit's `PeerNameDisplay` is the identifier filter:
`personName(_:fingerprint:in:)` answers a peer's chosen name, sanitized under the namespace's cap,
or nil for an empty name, the peer's fingerprint filed as a name, the fingerprint's 16-hex shape or
the QUIC instance name, and the soundness rule above keeps the cap long enough for it to see both
identifiers. Which plain phrase a person reads when it answers nil is Fernlet's display policy, so
it lives here, beside the peer-name policy: `PeerNameDisplay+Placeholders.swift` extends the type
with `Placeholder` (`.nearby`, "Someone nearby", for the connect path's rows, the session's
participants, a join request and a recipe recipient; `.met`, "Someone you met", for the
keep-as-friend rows and the Friends & Blocks list), `shown(_:fingerprint:placeholder:in:)` (the name,
or the placeholder), `firstName(_:fingerprint:placeholder:in:)` (the name's first word for warm
hearts copy, or the WHOLE placeholder, so a nameless friend never reads "Someone") and
`text(for:)` (the placeholder alone). The app's surfaces and `FernletProximityUI`'s two screens call
them with `in: .fernlet`, and `FernletSocial`'s `PresenceManager.firstName(of:in:)` delegates to
`firstName` with `.met` and the namespace it holds. A placeholder is resolved display text and never
a token: it is never persisted, put in a roster or vault row, or sent, which keep reading
ProximityKit's `displayNameOrFingerprint`. `PeerNameDisplayTests` pins the rules, and the test
target's bindings file restores the display's three call shapes without a namespace
(`personName`, `shown` and `firstName`), passing `.fernlet`.

**Localization.** The module owns a `Localizable.xcstrings` and one copy vault,
`FernletConnectionsCopy` (`FernletConnectionsCopy.swift`), whose `Peer` group resolves the two
phrases, `proximity.peer.someoneNearby` and `proximity.peer.someoneYouMet`, with
`String(localized:defaultValue:bundle:comment:)` and `bundle: .module`: inside this module that is
this catalog, and without it the lookup would go to `Bundle.main` and render English forever with a
clean build. The keys keep their `proximity.peer.` spelling, because a key is a token and a renamed
key strands its translations. `Scripts/sync-string-catalogs.sh` syncs the catalog from the code (its
`TARGETS` line) and its `--check` proves the two match, and `LocalizationBoundaryTests` pins that the
catalog exists and that every lookup in the package passes `bundle: .module`. The namespace's values
are data, never copy, and reach no catalog.

**The install binding.** ProximityKit's copy of the column seal,
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

**The audit bridge.** ProximityKit writes every audit line through
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

**The session rules.** ProximityKit is mechanism: which peers a session trusts, how
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
radios owning discovery on the namespace's service types. ProximityKit still names
FernletDomainModel's vocabulary and records (`PayloadType`, `ProximityCapability`,
`ItemNameModeration`, `ProximityTrustedPeerRecord`, `ProximityMode`) only on the lines
`ProximityNamespaceBoundaryTests` allowlists: lines of its feature files and of the typed doors only
those features go through, which leave with the mesh manager's feature parts (A0.5) or with the
recipe profile (A0.7), and the coordinator's session-mode alias, which the connection profiles
replace (A0.7, C5). The heart-drop and presence pair secrets derive through the door under the two
salts declared here, from `FernletSocial`. C1
adds the Coach app's installation (`fernletCoach`, beside `.fernletApp` and sharing its family), the
connection profiles (friend mesh, presence, recipe, coach), app identities with per-app allow lists,
coach relationship records and the coach link signing purposes; FernletCrypto's 40 twins of these
labels then retire.

**Why `.fernlet` lives here and not in ProximityKit.** ProximityKit holds no namespace instance,
offers no default and keeps no global, so a host that supplies nothing gets a compile error, never
another app's identity. The dependency edge runs from this module to ProximityKit, never the
reverse, so ProximityKit cannot name `.fernlet` even by accident; a non-Fernlet app gets Fernlet's
identity only by importing this module or by copying its literals on purpose. It stays in
FernletKit after ProximityKit leaves for its own repository (plan A1), consuming the package by tag.

**Position in the FernletKit graph and the S3 wall.** The target depends on `ProximityKit`; on
`FernletCrypto`, for `DeviceBindingID`, which the binding adapter delegates to; on
`FernletFoundation` (Layer 0, which `FernletAuditLog` lives in), for the audit bridge; and on
`FernletDomainModel`, for the payload vocabulary and the session rules: `PayloadType` and
`ProximityCapability`, whose raw values the vocabulary reads (and the audit conversion reads
`PayloadType` too), `TrainerAuditEvent`, `ProximityMode` and `ProximityTrustedPeerRecord`, which the
policies and the review read and the vault builds and keeps (the audit conversion builds
`TrainerAuditEvent`), and `ItemNameModeration`, whose name cap the peer-name policy reads. It imports
nothing else but Foundation, Observation (the vault is `@Observable`) and Security. Through ProximityKit it reaches
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
but the two trust policies, the vault and the copy vault's caseless outer namespace,
`FernletConnectionsCopy`:
the namespace is inert `Sendable` value data, and its readers are ProximityKit's nonisolated
serializers, verifiers and stores; the binding adapter is a stateless `Sendable` value the column
seal calls synchronously from inside those stores. ``FernletAuditBridge`` is a `nonisolated` struct
for the same reason: ProximityKit's `nonisolated` stores call it synchronously, which a main-actor
conformance would not allow. ``FriendMintingReview``, ``TrainerExportPayload`` and
``CoachSessionContract`` are `nonisolated` pure values. The name placeholders' extension is
`nonisolated`, as the `PeerNameDisplay` it extends is (its `Placeholder` with it), and so is the
`FernletConnectionsCopy.Peer` group it reads: a resolved display string has no actor to protect,
and `Bundle.module` is itself nonisolated. ``FriendSessionTrustPolicy`` and
``CoachSessionTrustPolicy`` stay main-actor classes, like the `@MainActor` protocol they conform to,
the main-actor vault they read and the main-actor coordinator that consults them.
``ProximityTrustVault`` is a main-actor `@Observable` class, like the `@MainActor`
`ProximityTrustStore` it answers and the main-actor managers and store that read it: the Friends UI
observes its records directly.
