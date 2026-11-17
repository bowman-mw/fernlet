# Mesh dialer privacy: hiding the long-term key and rotating the `sid`

Status: **approved by the owner 2026-11-15 ("Go A+B") and built in ProximityKit 0.2.0** (roadmap G5, item 2;
`No-Tracking-Wall.md` §6 "A hangout search still shows a dialer this phone's long-term signing key").
Lands in ProximityKit 0.2.0 with the rest of G5.

## The two exposures today

1. **The dialer's long-term key.** While the friend mesh searches, the side that dials opens a QUIC
   tunnel to any advertisement of the mesh service type and sends `MeshChannelHello` first
   (`Transport/MeshChannelIntroduction.swift`). The hello carries `signingPublicKey`, the phone's
   long-term Ed25519 key, before the dialer knows who is behind the advertisement. TLS hides it from a
   passive listener, but not from whoever answers: a phone that advertises the mesh service type during a
   search learns the key, and a key is a stable identifier across days.
2. **The mesh `sid` lives for the whole launch.** `MeshNetworkManager.sessionID` is minted once
   (`UUID().uuidString`, `MeshNetworkManager.swift:264`) and published in the mesh TXT record and in every
   hello. Anyone who browses the service type can link every sighting of this phone for as long as the app
   runs, across radio restarts. The Bonjour instance name and TLS identity already re-mint on each start.

## Proposal

### A. A friend proof before the hello (exposure 1)

A new first exchange on the control stream, before either side sends its hello. It uses the pair secrets
the host already derives for presence, under a mesh-only purpose, bound to the tunnel's TLS exporter
(the 32-byte channel binding the introduction already signs).

1. **Dialer → responder: `MeshDialProof`.** A fixed-size list of `MeshDialProof.slotCount` (24) truncated
   tags, `HMAC-SHA256(pairSecret_i, "pk.mesh.dial.v1" ‖ channelBinding)[0..<12]`, one for each phone the
   dialer would accept on this tunnel (kept mesh members, plus the tap matches the host named in
   `admissibleStrangers`), padded with random tags to the full 24 so the frame never says how many friends
   the phone has. A dialer with more than 24 candidates sends the 24 most recently seen.
2. **Responder.** Computes the same tag for each of its own candidates (24 × 24 HMACs at most, bounded
   loops) and looks for a match. **No match: it closes the tunnel without a byte.** A match: it answers
   `MeshDialAccept`, `HMAC-SHA256(pairSecret, "pk.mesh.accept.v1" ‖ channelBinding)[0..<16]`, proving it
   holds the same pair secret.
3. **Dialer.** Checks the accept against the pair secret its own tag came from. Only then does either side
   send the hello, unchanged, and the signed introduction runs exactly as today and still decides who the
   peer is. The proof only decides whether a key is sent at all.

What it gives: a stranger who advertises the service type sees 24 random-looking 12-byte values that are
bound to that one TLS connection, so they cannot be replayed or linked to another dial, and it learns no
key. Relaying a real friend's advertisement does not help, because the channel binding differs on each
leg. Both sides hold their keys back from a stranger: the responder speaks only after a match, and the
dialer speaks only after the accept.

What it needs: the pair secret needs each candidate's X25519 key-agreement key. Mesh members carry one
(`MeshMember`), and so does a tap match, since the rendezvous exchanges both long-term keys. The derivation
goes through ProximityKit's existing door, `IdentityService.pairSecret(with:purpose:)`, under a new purpose
that the namespace declares beside presence's, so mesh tags never collide with presence tags or message keys.

What it costs:

- **A wire break.** `MeshChannelIntroductionFormat.protocolVersion` goes from 1 to 2. A 0.1.x phone and a
  0.2.0 phone stop meeting on the mesh. That is acceptable before TestFlight; both test phones update together.
- **Open doors with no named keys stop working.** That is the legacy QR join path, where
  `admissibleStrangers` is nil. Fernlet no longer opens its doors that way (World Friends P1), so the proof
  refuses it, and ProximityKit drops that path rather than send a key in the clear. A host that still needs
  it gets a refusal reason, `noDialProof`, in the diagnostics.
- One extra round trip per dial (two small frames), plus at most 576 HMACs on the responder.

### B. A rotating mesh `sid` (exposure 2)

The `sid` moves from a per-launch constant to part of the radio's posture. It re-mints with the instance
name and TLS identity at every `start()` and resume, and also every presence epoch (900 s, the one clock
`IdentityService.presenceEpochSeconds` already defines), as the tap rendezvous does.

- A rotation re-registers the advertisement under the new posture. Live tunnels keep the `sid` their
  introduction verified (`MeshLinkTable` records the verified value per tunnel), so nothing that is
  connected drops. The duplicate-tunnel tie-break ranks the `sid` each side published when its tunnel
  opened, which the link table already holds.
- The hello's `sessionID` is read from the current posture at the moment the hello is built, through the
  one getter (`localSessionID`), so the hello and the TXT record cannot disagree.
- `sweepSkips` and `claimResolves` need no new rule. They already treat a `sid` as an unverified claim
  that only resolves where nothing verified contradicts it, so a peer's `sid` changing between sightings
  looks like what it is: a new advertisement whose tunnel will prove who it is.

### Out of scope

- The recipe radio (SEC-L29) is handled separately in the same tag: no name in TXT, kept friends named by
  pair tags, and an off-by-default "show my name to everyone" setting.
- Presence already advertises only rotating pairwise tags and needs nothing.

## Tests that pin it

- Tier 1 (pure): the proof's tag derivation is mutual, per pair, and per channel binding; the frame is
  exactly 24 × 12 bytes whatever the candidate count; no match means no accept; a wrong accept means no
  hello is built; `protocolVersion` 1 is refused as `unsupportedProtocolVersion`.
- Tier 2 (session): a stranger's advertisement receives a proof frame and never a hello (the existing
  `MeshTransportDebugHooks` capture); a kept member's dial completes; a `sid` rotation leaves a live
  tunnel up and the next TXT record carries the new `sid`.
- Fernlet: `NoTrackingBoundaryTests` and the No-Tracking-Wall §6 text lose the "shows a dialer this
  phone's long-term signing key" limit and say what replaced it.

## Two-phone checks it owes (D3)

- Two kept friends meet on the Album's Friends nearby page, and a tapped pair hands off into a hangout.
- A third phone with no shared friend never finishes a tunnel. Its diagnostics show `noDialProof`, and the
  other two never show it as a key.
- A 30-minute hangout survives two `sid` rotations without a reconnect.
