# ``FernletConnections``

Fernlet's connection rules on top of ProximityKit's mechanisms. Today it holds `ProximityNamespace.fernlet`, Fernlet's protocol identity on the wire, in the keychain and on disk; `FernletDeviceBindingAdapter`, Fernlet's install binding for ProximityKit's column seal; and ``FernletAuditBridge``, the sink that sends ProximityKit's audit lines to `FernletAuditLog`.

## Overview

`FernletConnections` is where Fernlet's side of the ProximityKit split lives. ProximityKit is
becoming a drop-in package any app can use, with nothing Fernlet-specific in its API
(`Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md` §3.2); owner decision O3 puts Fernlet's own
connection types and rules in FernletKit instead, on top of ProximityKit's mechanisms. This module
is that place.

**What it holds now (plan step A0.2.2).** One value and its parts, all in `FernletProtocolNamespace.swift`:

- `ProximityNamespace.fernlet`, Fernlet's whole protocol identity, built from the two halves below.
- `ProximityNamespace.Family.fernlet`, what every app on Fernlet's wire shares: the 39
  domain-separation labels (`Purposes.fernlet`, grouped as `Signature`, `KeyDerivation`, `AEAD` and
  `Hash`, each `.fernlet`), the three radios' service types, ALPNs and the mesh heartbeat
  (`Radios.fernlet`), and the `fernlet` QR scheme.
- `ProximityNamespace.Installation.fernletApp`, what belongs to the Fernlet app on one device: the
  identity's keychain service and four accounts, the two seal-key rows, the `Fernlet` storage
  directory with its three on-disk names, and the radios' log subsystem.

Every literal is today's, byte for byte, and pinned: `ProximityNamespaceGoldenTests` (on the
`crypto-goldens` CI line) compares each value with the frozen literal column written before any
A0.2 commit, requires `ProximityNamespace.fernlet.soundness == .sound`, holds the 38 labels
FernletCrypto's registry also declares to the same spelling and the same signing acceptance, runs
the "no label is a byte prefix of another" check over FernletCrypto's 81 registry labels and these
39 together, and checks that the bytes each hash and transcript consumer writes today begin with
the field's prefix.

**How the app supplies it (plan step A0.2.3).** ProximityKit's `ProximityHost` requires a
`proximityNamespace` and gives it no default, so the app is what hands `.fernlet` over: the
`FernletStore` adapter (`App/Fernlet/ProximityHostAdapter.swift`) answers `.fernlet`, `nonisolated`
because it is inert value data. The mesh, presence and recipe-share managers read it once at
construction, keep their own copy and build their default identity from it; every other
`IdentityService` the app builds says `IdentityService(namespace: .fernlet)` (the sealed-backup,
own-photo, duress-recovery and launch paths, the readout and the DEBUG probe), and the heart-drop
service's identity is built from the store's `proximityNamespace`. The identity's keychain service,
`com.fernlet.identity`, is the first value ProximityKit reads off it. The test target's eleven
`ProximityHost` doubles supply the same value, and its `ProximityNamespaceTestBindings.swift`
restores the old `IdentityService()` and `IdentityService(keychainService:)` call shapes by passing
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
target's `ProximityHost` doubles and store fixtures.

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

**What joins it later.** A0.3 adds the payload vocabulary (payload type tokens, capability raw values, the sealing set, routed-type rows,
membership record kinds), the session trust policies and the presentation strings that must become
per-host (instance prefixes, the TLS certificate name, the display default). A0.4 makes Fernlet's
feature labels host purposes. C1 adds the Coach app's installation (`fernletCoach`, beside
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
step A0.2.9 on `FernletCrypto` (for `DeviceBindingID`, which the binding adapter delegates to); and
since step A0.2.10, for the audit bridge, on `FernletFoundation` (Layer 0, which `FernletAuditLog`
lives in). It imports nothing else but Foundation and Security. Through ProximityKit it reaches
`PrivateMediaStore` transitively, which puts it on the protected side of the S3 wall: the walled `AIProviders` and
`CloudKitSync` targets have no edge to it, and
`S3BoundaryTests.proximityAndCloudSyncDoNotImportEachOther()` holds it to ProximityKit's own pair
of rules (nothing here imports CloudKit, and CloudKitSync never imports this module).
`BackgroundRefreshBoundaryTests` forbids the companion refresh handler from importing it, as it
forbids ProximityKit. The directory is code-owned (`.github/CODEOWNERS`) beside FernletCrypto and
ProximityKit's `Namespace/`: a changed literal here is a wire, keychain or on-disk format change for
every device already in the field.

**Isolation.** The module is main-actor by default (`defaultIsolation(MainActor.self)` in
`Package.swift`), matching ProximityKit, and every extension, static and type here is `nonisolated`:
the namespace is inert `Sendable` value data, and its readers are ProximityKit's nonisolated
serializers, verifiers and stores; the binding adapter is a stateless `Sendable` value the column
seal calls synchronously from inside those stores. ``FernletAuditBridge`` is a `nonisolated` struct
for the same reason: ProximityKit's `nonisolated` stores call it synchronously, which a main-actor
conformance would not allow.
