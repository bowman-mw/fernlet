# Mesh stranger admission on the QUIC radio — the design D-4.3 was waiting for (2026-09-21)

> Written at `b4cd1ac` (main = P10's one-liners on the §15.5 first attempt), for the owner, before any
> cutover code, and **corrected the same day after a blind adversarial verify** (20 findings: two
> mechanism sentences false at HEAD, the security delta the decision turns on omitted, the plan's own
> sketch not engaged, six anchors wrong — all taken; the direction survived). Every anchor below was
> re-grepped at that commit; line numbers are from it. The cutover patches themselves are unchanged
> and ready in [Mesh-P9-Item4-Design-2026-09-20.md](Mesh-P9-Item4-Design-2026-09-20.md); this
> document is the prerequisite that survey named and did not have ("**the prerequisite is a design,
> not a patch**"). It ends with the one decision the owner takes — **D-4.3 as redefined here, with
> D-4.4** — and stops.

## Corrections after implementation (2026-09-21, same day) — read these over §2 where they differ

The owner took D-4.3 (Option 1 + 1b's gating half) and D-4.4 (**pure retire**, against §4's recommendation). The admission path
was then built and blind-verified (ledger items 1.2; commits `5c8d5ac`…`4667d83`). Five statements in §2 turned out wrong or
imprecise at HEAD and are corrected here rather than rewritten in place, so the document stays the record of what was decided:
1. **The pre-commit window is FIVE MINUTES, not 25 s / 60 s.** `timeoutSeconds: isProximityJoin ? 25 : 60` is cancelled the
   moment the identity introduction verifies and `transitionToProximityGate` arms a 5-minute timer
   (`ProximityCoordinator.swift:1317-1320`) — exactly a provisional stranger's state. A bystander holds a seat for up to
   5 min per minted identity, × 5 slots. §2's "two bounds" paragraph inherits this.
2. **The target-mesh rule landed as ONE arm, not three:** `receive` reads the roster verdict before comparing meshIDs and
   tolerates a mismatch only for a provisional stranger; the transcript names the RESPONDER's id on both sides
   (`agreedMeshID`). No dial-policy change, no exchange restructure, no golden moved (unequal ids were unreachable before).
3. **The predicate is `isAdmittingNewPeers && isSessionOpen`** — stricter than §2's "the posture half of the invitation gate"
   (that gate is `isAdmittingNewPeers || hasCommittedSlot` and never reads `isSessionOpen`); a closed session with no mesh
   shuts the door too.
4. **A5 grew a seam:** `MeshSlotEvictionCause` + `MeshTransportSession.disconnectPeer(_:cause:)` (default cause-blind; the
   QUIC radio refunds a pre-commit timeout's re-propose BOOKING, never a refusal's, capped at 2 refunds per endpoint per
   session, never reset).
5. §2's "adding a `MeshTransportHandlers` member would be a transport-seam change `TransportNeutralityBoundaryTests`
   polices" is false — that wall is an MC-import grep. The reason not to add one stands (nothing would read it).
**Still owed and unrun:** the unseeded Lane C pair run (test (vi)); the capability has never been observed on any radio.

## 0. The one-paragraph version

The friend mesh ships on MultipeerConnectivity (`MeshTransportFactory.shippingDefault = .multipeer`,
`FernletKit/Sources/ProximityKit/Transport/MeshTransportSelection.swift:267`). MC's transport-level
admission is *anyone nearby while the join doors are open*: the invitation carries no identity
(`invitePeer(… withContext: nil …)`, `Transport/MeshMultipeerSession.swift:315`) and the gate is
`isAdmittingNewPeers || hasCommittedSlot` (`Mesh/MeshNetworkManager.swift:11008`). Who becomes a
*member* is decided one layer up, at three doors that already exist and are already tested. The QUIC
radio is members-only *before any app frame*: `MeshChannelIntroductionExchange.receive` asks the
roster last, and an empty roster answers `.stranger` → `.unknownIdentity` → the tunnel is torn down
(`Transport/MeshChannelIntroduction.swift:486-490`, `:292-294`; plan §8.7 finding 3). So two phones
that have never met cannot found a mesh on QUIC, and a stranger cannot join an open one. **The
smallest honest fix is to let the QUIC introduction admit a stranger *provisionally* when — and only
when — the owner's existing invitation gate would have admitted an MC invitation, and to let the
existing seat, commit and admission machinery decide membership exactly as it does for MC today.**
That restores MC's shipping posture — *including* the fact that a provisional peer is sent this
device's identity introduction (display name and keys) before any commit, which MC does today and
QUIC does not — with two things MC never had (the stranger's key is proven-held by the signed
transcript, and the tunnel is TLS). It adds **no screen, no wire field and no persisted surface**,
but it is not one arm in one function: joining an *established* open mesh needs a target-mesh rule
the current exchange cannot express (the responder's hello is frozen before it hears the dialer's),
and plan §7.2's "non-roster member" reject bullet is amended, not left alone. The plan's own sketch,
a *bounded* pre-admission channel, is Option 1b: the same admission with the display name withheld
until commit — a join-screen UX change, so an owner call. A two-scan QR pre-admission (Option 2) is
the strongest design and the one to build after the cutover if "no stranger ever gets a tunnel" is
wanted. Recommendation: **Option 1 now, D-4.3 (redefined) taken with §15 still undated, D-4.4 as the
legacy sweep; 1b's frame-gating half taken as a hardening in the same series, its name-deferral half
left to the owner; D-4.2 remains available.**

## 1. What the two radios do today, side by side

| Stage | MultipeerConnectivity (ships) | QUIC (`NetworkMeshSession`) |
|---|---|---|
| Discovery | Bonjour `_fernlet-friend._{tcp,udp}`; TXT `v`, `sid`, and for an **open** mesh `meshID`/`meshName`/`memberCount` — never a name or fingerprint (`MeshNetworkManager.swift:11154-11175`) | Same TXT vocabulary on `_fernlet-mesh2._udp`; random instance name per session; `fp` a withheld key both ways (`Transport/MeshLinkAdvertisement.swift:29-53`) |
| Tunnel admission | Invitation with **no identity**; accepted iff `shouldAcceptInvitation` → `isAdmittingNewPeers \|\| hasCommittedSlot`, refused for a proximity join that may not link, and at the slot cap (`:11001-11016`); fail closed `?? false` (`MeshMultipeerSession.swift:573`) | TLS (ephemeral P-256, *not a trust anchor*, `Transport/EphemeralMeshTLSIdentity.swift:175-188`) → signed hellos → `receive`'s seven checks: well-formed, version, **meshID equal**, epoch rule, not self, nonce fresh, **roster verdict**, then record (`MeshChannelIntroduction.swift:461-493`) → `invitationGate` (the *same* closure as MC's, consulted **after** the introduction, `NetworkMeshSession.swift:384-391`, `:1232`) → `activate` with a `MeshVerifiedPeer` only (`:1406-1408`) |
| A stranger | Gets a tunnel while the doors are open | Refused at the roster check (`.unknownIdentity`); the exchange keeps nothing (`:411-414`) |
| What the manager learns | A channel, through `onChannelReady` → `handleChannelReady(_:)` (`:11329`) | The same, and only that: `onPeerVerified` (`NetworkMeshSession.swift:376`, fired at `:1458`) has **no subscriber** — `wire(_:)` forwards five handlers and no verified-peer hook (`MeshTransportSelection.swift:95-113`, `:196-202`) |
| Identity | `handleChannelReady` builds a `ProximityCoordinator` with this device's `displayName` (`:11376`) and begins it (`:11419-11422`); friend mode sends the identity-introduction envelope **immediately, before any commit** — "skip the tap gate; send identity intro immediately so ranging can start before the commit" (`Engine/ProximityCoordinator.swift:644-647`, `:807-831`): display name, signing key, KA key, NI token, capabilities (`:1003-1009`); dropped only for revoked/blocked keys (`:851`, `:925-945`) | Proven at the introduction: Ed25519 over purpose ‖ version ‖ meshID ‖ epochRef ‖ both keys ‖ both nonces ‖ TLS-exporter hash (`MeshChannelIntroduction.swift:158-187`); then the same envelope, to members only |
| Seat | `channelAdmission(for:)` (`:11316-11327`) and, for a non-members-only radio, `maySeatVerifiedPeer(signingPublicKey:)` in `checkCoordinatorStates` (`:1205-1208`, `:14085-14088`) — refuses a stranger on a **closed** mesh, evicts, audits `mesh.slot.refusedClosedMeshStranger`; on a first meeting it returns `true` (`:1206`) | Same code path; today reached only by members |
| Commit (consent) | The 15 cm / 0.8 s / 3-sample dwell (`Engine/ProximityCommitDetector.swift:7-23`) **or**, on a non-UWB device (`.awaitingManualCommit`, `App/Fernlet/ConnectView.swift:1292`), the in-session QR manual commit (`beginQRVerification`, `:11777-11797`) | Same |
| Pre-commit bound | `timeoutSeconds: isProximityJoin ? 25 : 60` (`:11377`) → `armTimeoutIfNeeded` ends every pre-commit state `.ended(reason: .timeout)` (`ProximityCoordinator.swift:1561-1583`) → the stale sweep drops the slot (`:14102-14106`) | Same |
| Founding | First commit → `promoteToMesh()` (`:11512`, `:11604-11651`): mints `meshID: UUID()` (`:11633`), one-member descriptor, ledger armed, `seedFounderAdmission`; **both halves may found** and the double mint is repaired at `yieldsNewbornMesh` (`:11507-11512`, `:12193-12212`) | Unreachable: no commit, because no tunnel |
| Second member | Descriptor → the joiner sees itself absent → `sendAdmissionRequest` (`:12080-12083`); `.meshAdmissionRequest` is the one *member-family* payload accepted from an **uncommitted** slot (`:12464-12468`); founding pair auto-granted, the dwell being the consent (`autoGrantsFoundingAdmission`, `:12533-12544`, which requires a committed slot whose handshake-verified key equals the request's — set only at `.connected`, `:14090-14091`); a stranger to an established mesh → `JoinPromptSheet` (`App/Fernlet/JoinPromptSheet.swift:17`) → `allowAdmission` → signed `MeshAdmissionToken` filed **before** the grant is sent (`:2645`) → the derived roster names the joiner on every node | Same, once a tunnel exists |
| What an uncommitted slot can reach | The identity introduction and the pre-commit ceremony; `.meshAdmissionRequest`; `.meshAdmissionGrant` (deliberately, `:2807-2814`); `.verifyChallenge`/`.verifyResponse` ("PRE-COMMIT by design", `:2743-2748`); `.meshFriendVouchList` (`:2751-2756`); and the whole **group-key family** — `.meshEncryptedMetadata`, `.meshCoordinatorBeacon`, `.meshRotationSync`, `.meshKeyRotation`, `.meshKeyAck` → `dispatchGroupKeyPayload` with **no** `slot?.fingerprint != nil` guard (`:2759-2760`, `:10708-10750`). Commit-gated: the descriptor (`:12337`, `:2791-2806`), membership events (`:10256`), removal (`:10648`), removal quorum (`:10694`), and every feature — hearts, photos, chat, shop (`:10759-10764`) | Same, once a tunnel exists |

Three facts the survey did not name and every option below owes:

- **The meshID check precedes the roster check, and the exchange cannot adopt one.** A mesh-less
  device answers `unboundMeshID` (the all-zero UUID, `:14770-14775`), so two mesh-less devices agree
  on meshID and fail only at the roster. But a mesh-less joiner dialing an **open** mesh sends
  `unbound` against the founder's real id → `.foreignMesh` at `receive` (`:472`), before any
  admission rule is asked. A "target-mesh rule" — the joiner speaks the id of the mesh it is asking
  into — is therefore owed for "join an open mesh you are not in", and it is **not** one property:
  `MeshIntroductionAuthority.meshID` is a peer-less computed property read once per tunnel by
  `localHello(from:)` (`:14775`, `NetworkMeshSession.swift:1954-1962`), and the **responder's hello is
  frozen before it hears the dialer's** — `introduce()` builds the exchange with `localHello(from:
  authority)` as a `let` (`:1916-1919`, `MeshChannelIntroduction.swift:437`) and only then calls
  `exchangeHellos` (`:1981-1992`). So adoption on the responder side is an exchange restructure. The
  epoch rule, by contrast, already has the joiner arm — an empty `epochRef` against a well-formed
  one is `.converge(remote)` (`Mesh/MeshEpochAcceptance.swift:206-222`).
- **The double mint is a `.foreignMesh` deadlock on QUIC.** Both halves of a founding pair mint
  their own `meshID` at their own first commit ("nobody waits for the other", `:11507-11512`,
  `:11633`); MC has no meshID check at the transport, so the descriptor exchange repairs it at
  `yieldsNewbornMesh`. On QUIC, if the tunnel drops between the two commits and that convergence,
  A and B each hold a different real id and `receive`'s unconditional meshID equality refuses every
  re-dial for the rest of the session — a regression *against the posture Option 1 restores*, and the
  first-meeting case is exactly where it bites.
- **`browsed peers=` logs nearby Bonjour instance names at `.notice`/`.public`**
  (`Self.logger.notice("\(line, privacy: .public)")`, `NetworkMeshSession.swift:1056`) — plan §8.7
  finding 1's "one item owed before QUIC ships". Not in the survey's six patches; it rides the
  cutover series whatever the option.

## 2. The options

### Option 1 — Provisional admission while the join doors are open  *(recommended)*

**Mechanism, as the code is.** `MeshIntroductionAuthority` (`MeshChannelIntroduction.swift:582-612`;
**six** members since P4 — the "kept to five" comment at `:576` is stale) gains a seventh:
`mayAdmitStrangerProvisionally() -> Bool`. `MeshNetworkManager` answers it with the predicate its MC
invitation gate already computes — the three-door flag `isAdmittingNewPeers` (`:260`; doc `:243-259`),
`hasCommittedSlot`, the proximity-join/`mayLinkToDiscoveredPeers` refusal — and **nothing new**. In
`receive`, the `.stranger` arm refuses unless the authority says yes; `.barred` is tested first and
still wins (`:487-488`). **The verdict is transport-local and the manager reads nothing:** the peer
arrives at `handleChannelReady` as a channel, exactly as an MC peer does, and the stage that decides
its fate is the one that already decides an MC peer's — `maySeatVerifiedPeer` at the identity
introduction, then the commit, then the admission request. No field is added to `MeshVerifiedPeer`
(nothing would read it — `onPeerVerified` has no subscriber and `MeshTransportHandlers` no
verified-peer member, and adding one would be a transport-seam change `TransportNeutralityBoundaryTests`
polices), and `MeshChannelHello` v1 is unchanged — no new field, no persisted surface.

**The target-mesh rule** (§1) is the largest piece of Option 1, and it is three arms:
(a) *dialer*: a mesh-less device browsing an open mesh records a session-scoped join target from
the advertisement's `meshID` and its authority's `meshID` answers that while set — one open mesh per
session, cleared with it (a narrowing, stated); (b) *responder*: either the exchange is restructured
so the responder builds its hello **after** receiving the dialer's and may adopt its `meshID` when it
has none (touching `introduce()`, the exchange initializer's `let localHello`, and the transcript
order on both sides — a wire-compatible change, since the transcript already covers whichever id
both sign), **or** a dial-policy arm makes the mesh-less side always the dialer when joining an
established open mesh (one row in `MeshDialPolicyTests`' matrix; `shouldInitiateInvite` today is by
session id, `:11206-11239`) — the second is smaller and is the drafted default; (c) *newborn*: a
one-member mesh whose descriptor has not yet converged with its pair's accepts the peer's `meshID`
under the conditions `yieldsNewbornMesh` uses (`:12193-12212`), so the double mint cannot deadlock
the re-dial. Safe in all three arms because meshID is inside the signed transcript on both sides;
the joiner is only saying which mesh it is asking into.

**Trust consequence — the delta the decision turns on.** Exactly MC's shipping posture: a device
with the doors open holds a tunnel to any nearby Fernlet that dials it, until the doors close
(`holdCommittedLinks` lowers `isAdmittingNewPeers` and drops every uncommitted slot, `:2135-2163`;
`stopSearching`; leaving the join screen) or the 25 s / 60 s pre-commit timeout evicts it. **A
provisional peer is sent this device's identity introduction — display name, signing key, KA key,
NI token, capabilities — before any commit**, because `handleChannelReady` starts the coordinator and
friend mode sends the intro immediately (`ProximityCoordinator.swift:644-647`); `maySeatVerifiedPeer`
runs *after* that and returns `true` on a first meeting (`:1206`; its own doc says what a stranger
would otherwise be sent, `:1186-1190`). MC does the same today for every peer it admits, so the
cutover is net-neutral; on the QUIC radio it is new, and it is what the TXT record's "deliberately no
display name" (`:11154-11163`) was protecting until now. The frames a provisional peer can reach are
the ones an uncommitted MC slot reaches today (§1's last row) — including the group-key family,
which is ungated at dispatch; it holds no group key, so the frames are inert, but the gate is owed
(below). Strictly better than MC in two ways — the stranger's signing key is proven-held (the hello is
Ed25519-signed over a transcript that includes the TLS-exporter hash) and the bytes are TLS. Strictly
worse than today's QUIC in one — it is no longer members-only before any app frame, which is plan
§7.2's bullet, verbatim: *"Reject before any app frame: unknown identity, **non-roster member**,
hard-departed/removed member, ended/foreign meshID, introduction failure, or replayed nonces"*
(`Plan-ProximityKit-Network-Migration-2026-08-27.md:462`). **Option 1 amends that bullet** — a
provisional non-roster peer is admitted to a *tunnel*, never to a *roster* — and the plan edit is an
owed patch, not a gloss. What it does not give a bystander: the descriptor and who is in the mesh
(commit-gated), a seat on a closed mesh, or membership without the dwell or a tap
(`autoGrantsFoundingAdmission` binds the request to a committed slot holding the requester's own
verified key, `:12533-12544`, `:12456`, `:12469-12474`).

**Two bounds to name.** `maxTotalSlots = 5` / `maxSlotsDuringOverflowEvaluation = 6` (`:517-518`)
and `maxPendingInboundTunnels = 8` (`NetworkMeshSession.swift:334`): a hello's signing key is
self-chosen, so a bystander can hold every seat for 25 s per minted identity while the doors are
open — MC's exposure today, bounded the same way. And `maxReproposalsPerEndpoint = 6`, **never
reset** (`Transport/MeshLinkTable.swift:329-355`, `:406`): its loop is connect → the owner refuses the
seat → disconnect, which is also what a provisional peer evicted by the seat gate *or the timeout*
does — so a genuine friend who fails to commit six times is stranded for the session. The
implementation must charge that budget for an owner refusal only, never for a timeout eviction.

**UI cost.** None. The join screen *is* the tap; `isProximityJoin`/`isAdmittingNewPeers` already
model it. `ConnectView`'s in-session QR sheets keep working unchanged inside a provisional tunnel on
a non-UWB device (they exist only in the `.awaitingManualCommit` branch, `ConnectView.swift:1292`; a
UWB device sits in `.awaitingProximityCommit` and commits by distance, `:1281-1291`).

**Tests it owes.** (i) `NetworkMeshTransportTests` (`MeshChannelIntroductionTests`): doors closed →
`.unknownIdentity`; doors open → the exchange proceeds and `review` still verifies the signature;
`.barred` beats provisional; nothing is recorded before `review`. (ii) `MeshIntroductionAuthorityTests`:
the flag is exactly the invitation gate's predicate — false under a hold, false at the slot cap,
false for a proximity join that may not link; the target-mesh rule's three arms. (iii) A
`MeshPairwiseFoundingTests`-shaped cell: two managers over `FakeMeshTransportSession` with **no**
seeded roster found a mesh through the provisional path, and a third stranger to the resulting
*closed* mesh is refused at the seat. (iv) `MeshDialPolicyTests`: the mesh-less-dials arm. (v) The
`MeshP9McRetirement…` values, per the survey's tests appendix. (vi) **Tier 2:** the Lane C pair run
with **no** `FERNLET_MESH_MATRIX_MEMBERS` (the runbook's "app-path founding over QUIC stays
unobserved", `Docs/Mesh-Network-Feasibility-Runbook.md:1294-1295`, becomes a dated row;
`armFounderLedgerForHarness` and `requestAdmissionForHarness` then become deletable — a later cleanup).
(vii) **Tier 3:** Lane D's founder/joiner shape on hardware, unseeded — the owner's device round.

**Which appendix patches it changes.** `MeshNetworkManager.swift` **Edit 5** (`maySeatVerifiedPeer`
/ `mayLinkToDiscoveredPeers` docs — the check is *the* stage for a provisional peer, not belt) and
**Edit 6** (the `MeshIntroductionAuthority` scope paragraph — the survey said "there is no honest
replacement … if the applier is writing that sentence, D-4.3 is the wrong decision"; there is one
now: *"a stranger is admitted provisionally while the join doors are open — the posture the retired
MC radio shipped, with the key proven — and becomes a member only at the same three doors"*). Edits
1–4, 7 unchanged. **Plus** a patch the survey does not have: plan **§7.2**'s reject bullet, amended
as above. `MeshTransportSelection.swift`, `Info.plist`, `TransportNeutralityBoundaryTests`, the other
docs: unchanged. The tests appendix gains (i)–(iv). `Appendix A`'s rule-7 cell: unchanged.

**Size, honestly.** One authority member and one `receive` arm (small); the target-mesh rule — an
authority property with session state, a dial-policy arm, a newborn arm (medium); the plan §7.2
amendment; five test suites; no `MeshVerifiedPeer` change, no transport-seam change. The
responder-side exchange restructure is *avoided* by arm (b)'s dial-policy default; if the owner wants
symmetric adoption instead, add it and its wire-golden.

### Option 1b — The bounded pre-admission channel (plan §8.7 finding 3's own words)

Plan §8.7 finding 3 ends: *"A real answer is a bounded pre-admission channel (or MC until P9) — a
design decision, not a port detail"* (`:965-973`). Option 1 is the opposite of bounded: a provisional
peer gets a full `ProximityCoordinator` and everything an uncommitted slot can reach. **1b is Option 1
with the tunnel confined** until commit: (1) the group-key family and the vouch list gated on
`slot?.fingerprint != nil` like their siblings — a pure hardening, no UX cost, applies to MC today
too; and (2) the identity introduction sent **without the display name** until the commit, the name
following on `.connected`. (2) is the real decision: it closes the disclosure in Option 1's trust
paragraph — a bystander with the doors open learns a key and a fingerprint, not a name — at the cost
that the join screen shows a fingerprint, not a name, until the 15 cm dwell or the tap, which is a
change to what "find people nearby" *shows* and so a product call, not an engineering one. Ranging
is unaffected (the NI token still crosses). Everything else in Option 1 — mechanism, target-mesh
rule, bounds, tests, patches — is 1b's too, plus a coordinator state for the deferred name and a
`ProximityCoordinatorTests` row. **Drafted:** take (1) in the cutover series; leave (2) to the owner
beside Option 2.

### Option 2 — Out-of-band pre-admission: each side scans the other's QR before any dial

**Mechanism.** The app already has the primitive: `ProximityVerifyQR` — `fernlet://verify?d=…`,
self-signed, carrying **both** public keys, a nonce and a 5-minute freshness window
(`Wire/ProximityVerification.swift:12-37`, `:115-140`), slot-independent and already reused twice off
the mesh (`Trust/CoachVerificationCeremony.swift:8-14`, `App/Fernlet/DuressRecoveryCoordinator.swift:225-233`).
A new pre-session ceremony: each phone shows its code and scans the other's; a scan files a
**pre-admission** — the scanned signing key is answered `.member` by the authority's roster for
introduction purposes, bounded (one entry per scan, expires with the QR's freshness, consumed by the
first successful introduction, cleared with the session), in memory only. Both sides scan because
`receive` is symmetric — each side checks the *other's* key against *its own* roster (`:486`). A
one-way scan is not impossible on the v1 wire: the hello's 16-byte `nonce` (`MeshChannelIntroduction.swift:33`,
`:79-81`) is the same width as the QR's (`ProximityVerification.swift:34-37`) and is checked only
for inequality and freshness (`:485`), so a scanner *could* carry the QR nonce in it and the displayer
honour its live one — at the cost of the field's replay role, a **policy** change rather than a wire
one, and one this document does not recommend. The target-mesh rule (§1) is owed here too (the QR
carries `meshID` — a QR v2 — or the same three arms). The challenge/response half of the existing
ceremony cannot run (no channel yet); the signed introduction transcript is the proof-of-holding.

**Trust consequence.** The strongest of the three: **no stranger ever gets a tunnel**; QUIC stays
members-only before any app frame; §7.2's bullet stands unamended; the key on the roster is the key
the camera saw; nothing is disclosed to anyone the user did not scan.

**UI cost.** A new pre-session screen ("Add a friend nearby: scan each other's codes") that does not
exist — today's QR sheets live *inside* a connected session and only in the `.awaitingManualCommit`
branch (`ConnectView.swift:1292`). Two scans per pairing, on both phones, before anything else; the
15 cm dwell stops being the first-meeting consent (it still commits later). For a stranger joining
an established mesh, one member must scan the newcomer and the newcomer that member — a two-person
ceremony in a group. It also lifts `beginQRVerification`'s slot binding into a second, slot-free mesh
ceremony (the Coach one is the template).

**Tests it owes.** The pre-admission table (bounded count, single use, expiry, cleared on session
end, never persisted — a `PersistedSurfaceWipeBoundaryTests`-style zero-list); authority cells; a QR
v2 codec and wire-golden if `meshID` is added; the ceremony's state machine on both sides; a Lane C
run driven by two harness-seeded scans; Lane D on hardware. **Changes** `MeshNetworkManager.swift`
Edit 6 (honestly: "admission is a scan, before the dial"), adds a UI file, and leaves §7.2 as is.

### Option 3 — Keep MC as the first-meeting radio  *(ruled out)*

Cut the mesh's data path over to QUIC and keep `MeshMultipeerSession` for admission only. This is
D-4.1 hold wearing a cutover's name: both MC files, `_fernlet-friend._{tcp,udp}`, the permit list,
the wipe row and 34 test files all stay, none of the survey's appendices applies, and the app runs
two radios for one feature. Nothing to recommend.

### Ruled out on sight — admit strangers with no gate at all

"Trust on first use, always." Not what MC ships either: its doors close on a hold and a closed mesh
refuses at the seat. Not an option.

## 3. Comparison

| | Option 1 — provisional while doors open | Option 1b — bounded channel | Option 2 — two-scan pre-admission | Option 3 — keep MC for admission |
|---|---|---|---|---|
| Transport trust vs MC today | **Same posture, key proven, TLS** | Better: no name before commit; group-key/vouch frames gated | **Strictly stronger** (members-only kept) | Same as today (MC) |
| What a bystander learns with the doors open | Display name, signing key, KA key, NI token, capabilities (as on MC) | Signing key, fingerprint, KA key, NI token | Nothing | As on MC |
| Plan §7.2's "non-roster member" bullet | **Amended** (tunnel, not roster) | Amended | Unamended | Unamended |
| Membership decision | Unchanged (dwell / QR commit / prompt / auto-grant) | Unchanged | Unchanged, reached only after two scans | Unchanged |
| New UI | **None** | None, but the join screen shows a fingerprint until commit | One new pre-session screen, two scans per pairing | None |
| Wire change | **None** (v1 hello; transcript unchanged) | None | Possibly QR v2 (`meshID`) | None |
| Persisted surface | **None** | None | None (pre-admissions in memory) | None |
| Appendix patches changed | Edits 5, 6 of `MeshNetworkManager.swift`; plan §7.2; tests appendix | same + a coordinator state | Edit 6; tests; a new UI file | none apply |
| All owe | the target-mesh rule's three arms (§1); the `browsed peers=` log level; the re-propose budget charged for refusals only | same | same (arms via QR v2 or TXT) | — |
| Tier-2 row | Lane C **unseeded** pair founds a mesh | same | Lane C with two seeded scans | — |
| Removes MC | Yes (next round, after the flip is gated) | Yes | Yes | **No** |
| Size | authority member + `receive` arm (small); target-mesh rule (medium); §7.2 edit; ~5 suites | + a deferred-name coordinator state | + a ceremony, a screen, a table, a codec | — |

## 4. Recommendation

**Option 1, with 1b's gating half.** It is the honest statement of what the app already ships: MC
admits anyone nearby while the doors are open — and tells them the local name — and decides
membership later at three doors that are tested, audited and reviewed. Option 1 keeps those doors,
makes the tunnel *better* than MC's (key proven, TLS), adds no screen and no wire field, and is the
smallest change that makes the survey's Edit 6 paragraph true instead of a confession. Its real
costs are stated above and are not hidden in a table cell: the target-mesh rule is medium-sized
work, §7.2 is amended, and a bystander learns the display name exactly as on MC. Option 1b's name
deferral would close that last item and is a join-screen product change; take its gating half now
and decide the rest beside Option 2. Option 2 is the right *next* design — "no stranger ever gets a
tunnel" is a real property and the primitives exist — but it costs a new ceremony and two scans per
pairing, and building it first would hold the cutover behind a UI round while the mesh keeps shipping
on the radio the whole plan exists to retire.

**Two conditions the survey's D-4.1 named, one discharged here and one not.** D-4.1 was "hold until
stranger admission exists on QUIC **and §15 has dates**" (`Mesh-P9-Item4-Design-2026-09-20.md:45`).
This document discharges the first. **§15.1–§15.4 are still NOT RUN** (plan `:3519-3522`, and the
plan states the dependency at `:3622`); Lane D ran on 2026-09-21 (§28.6) and §15.5's first attempt
ran the same day (§28.7), but the radio matrix, the partition walks and the soak that decides the
degraded ladder have no dates. Taking D-4.3 now means the device round runs on the *cutover* build
— which is also the only build on which its rows mean anything for the radio that will ship. The
owner takes that knowingly or holds.

**D-4.2 remains on the table.** The survey's split (the NOW half already landed as 9.4-NOW; the LATER
half held) is unchanged by this document. And **D-4.3 is redefined here**: the survey's D-4.3 was
"cut over anyway, accepting broken first-meeting founding — not recommended"; this document's D-4.3
is "cut over *with* Option 1", a different proposition under the same label, and is recommended.

**D-4.4 rides with it, as the legacy sweep** (the survey's own recommendation): keep the
`wipeIdentityForDeleteAll` leg as plain `FileManager` over `Application Support/FernletPeerID.archive`,
rewrite the `Docs/PrivacyWipeCoverage.md` row rather than retiring it, and keep
`PeerIDArchiveWipeTests`' four cells rewritten against the new helper. The only install in the world
is the owner's phone and it *has* run pre-P9 builds, so the archive — the device name, in practice
a first name — is on it today.

**What the cutover series then is** (only after the owner's answer): the admission path with its
tests (i)–(v) and the target-mesh rule → 1b's gating half → the six anchored patches from the survey,
`shippingDefault` `.multipeer` → `.quic` with `MeshP9McRetirementAcceptanceTests`' values flipped in
the same commit, the `browsed peers=` level, the `Info.plist` rows, the wipe row, plan §7.2 and the
other plan rows, the CI name pins raised in the commit that adds names → gate → the Lane C unseeded
run → **MC deletion in the following round**, never in the flip's commit.

## 5. The decision

**D-4.3 (redefined): cut the friend mesh over to QUIC with Option 1 — a stranger is admitted
*provisionally* while the join doors are open (MC's own posture, key proven, the local display name
disclosed before commit exactly as on MC), membership decided at the existing three doors, plan §7.2's
"non-roster member" bullet amended, §15 still undated — taking 1b's frame-gating half and D-4.4 as the
legacy `FileManager` sweep; or D-4.1 hold until §15 has dates and/or Option 2's two-scan ceremony is
built first; or D-4.2, the split as it stands.**

Nothing else in this document is a decision: 1b's name deferral, P9-3-A, the `_fernlet-coach`
strings (§18 decision 4, default hold) and the degraded ladder are untouched by any option.
