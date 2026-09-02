# Mesh Migration Loop Ledger — P3

**Phase:** P3 (durable session context, roster, membership) · **Prompt:** [Next-Round-Prompt-Mesh-P3-2026-09-01.md](Next-Round-Prompt-Mesh-P3-2026-09-01.md)
**Started:** 2026-09-01 · **Iteration:** 7 · **Tree at seed:** main = `801e34f` (pushed); launcher at `adfa3c0`

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`. Tier per §2.
| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 0 | Multi-node sim bring-up (3 nodes) | 2 | — | todo | | de-risks every tier-2 item; deferred behind tier-1 work per §1.3 |
| 1 | Records + derived roster, pure | 1 | — | done | `cd8ea71` | 4 record kinds, ledger of 4 sets, roster derived per read; caps = keep-earliest-k (merge-stable); barred keys joined from admission |
| 2 | Sealed MeshSessionStore (5-state, per-instance root, §17.3) | 1 | 1 | done | `8166071` | 1 iter. Store+paperwork landed; manager save-cadence wiring folded into item 6 |
| 3 | Membership event wire tokens | 1 | 1 | done | `700605c` | transcript NOT moved; goodbye = presence-only downgrade; verifier gates insertion |
| 3b | `member-removal.v1` wire frame (PayloadType + payload + golden + decode/dispatch; purpose `meshMemberRemovalV1` already registered) | 1 | 3 | todo | | exposed by item 5: removal is minted+filed locally but has no frame; needed before 7/9 |
| 4 | Epoch model §8.4 + tighten the gate | 1 | 3 | done | `374b1cc` | epochID derived not drawn; goldens untouched; gate strict; replay window built-not-wired (P5) |
| 5 | Membership-driven rotation | 1 | 3, 4 | done | `ddcc717` | 2 s debounce; cause on unsigned payload (new golden only); leave regression closed |
| 6 | State machine §8.2 on the fake | 1 | 2 | done | `3daf364` | 10 states/18 events, ceiling at both bounds, restore 5→7, save cadence on the one writer |
| 7 | IntroductionAuthority → derived roster | 1 | 1, 2, 3b, 5 | todo | | makes matrix row 3 shipping |
| 8 | P3 acceptance battery | 1 | 2,4,5,6,7 | todo | | |
| 9 | Multi-node membership at tier 2 | 2 | 0, 7 | todo | | Lane C, 3–6 sims |

## Blocked on owner
- Transcript-`sid` / `epochRef` move (§3 decision, §18 decision 7) — confirm before the wire changes.

## Decisions taken (defaults from §3 unless the owner overrides)
| Decision | Choice | Taken on |
|---|---|---|
| Bind `sid`+`epochRef` in transcript v2 | DEFERRED past P3 — epochRef became real inside the existing field with no golden move; `sid` binding still owner-gated (touch list in `374b1cc` report / MeshChannelIntroductionTranscript, canonicalBytes, bind(channelBindingHash:), purpose doc, framing case, distinctness table) | 2026-09-01 |
| Epoch gate strict after §8.4 | yes, at MeshChannelIntroductionExchange.receive | 2026-09-01 |
| Publish `fp` in TXT | no (transcript did not move) | 2026-09-01 |

## Surprises worth not re-deriving
- Item 6: `.terminationVerified`/`.removed` state events are NOT yet applied from the dispatch path (ledger insertion happens; deciding a received record names THIS device needs item 7's derived shipping roster). `.developed`, `.backgrounded`/`.foregrounded` unwired (P7 seam). `enforceSessionCeiling`/`evaluateIdleLapse` are on-demand, no timer — item 8/P7 decide who polls. Removal receive path (3b) should call `commitVerifiedRecord(rollingBackTo:type:)`. Acceptance handles for item 8: `MeshSessionCeiling`, `MeshSessionRestore.outcome`, `applySessionEvent`, `MeshSessionStoreFixtures`.
- Item 5: `meshKeyRotation` is UNSIGNED inside the signed envelope (no canonical serializer, no prior golden). `MeshSessionContext.hardDeadline` is stamped `createdAt + 6h` but only RECORDED — item 6 enforces it. `removedMemberFingerprints` is the interim removal authority until item 7. `ProximityHost.meshSessionStorage` is the scope seam. Test seams: `seedEpochKeyringForTesting`, `rotateNowForTesting(cause:)`, `onMembershipEventSentForTesting`, `identityForTesting`.
- Item 4: `MeshNetworkManager.epochRef` derives per read from `currentGroupKey.epoch` + the GOSSIPED descriptor roster (not `activeSlots`); item 5 must replace it with a held `MeshEpochKeyring` and move the coordinator source together with it or members stop agreeing on `epochID`. Rotation API: `MeshEpochRef.successor(coordinatorFingerprint:meshID:)` → `MeshEpochAcceptance.rotationVerdict` → `MeshEpochKeyring.rotate(to:key:at:)`. No `cause` token exists yet (item 5 mints `timer`/`membership`/`merge` on the `meshKeyRotation` payload). `MeshEpochFixtures` in MeshEpochModelTests is reusable by item 8.
- Item 3: INTERIM REGRESSION to close in item 5 — `leaveSessionAfterNotifyingPeers()` now sends nothing (goodbye emit removed; signed departure not yet emitted). Joiners never adopt a ledger yet, so every received event on a joiner is refused `signerNotAdmitted` (fail-closed) until item 7 derives the shipping roster from records. `emitMembershipEvent(_:)` on `MeshNetworkManager` is the only emitter seam. Both radios funnel through `proximityCoordinator(_:didReceive:)`, so dispatch needs no `NetworkMeshSession` change. Admission stays on `meshAdmissionTokenV2`.
- Item 2: `LoadToken` is an associated value of `loaded`/`absent` only (fileprivate init) — refused/deferred/corrupt structurally cannot `save`. Refusal seams: seal → `SealedColumnStrictSealError.bindingUnavailable`; open → `SealedColumnOpenError.installBindingMissing`; `DeviceBindingID.ReadError` = deferred; tests drive via `DeviceBindingID.$testOverride`. Key row is NOT a `KeychainPrivateMediaKeyProvider.Role` (those survive delete-all; this one must not). `MeshSessionContext.epochHeads` is `[String]` until item 4 bumps schema to 2. §17.3's PrivacyInfo/privacy-copy paragraph is still owed at phase close.
- Item 1: `SignedAdmissionRecord` wraps `MeshAdmissionToken` whole — `expiresAt` is admission-time freshness only, never a validity test on a durable record. Termination is derived (not applied at merge) to keep commutativity. Records are NOT signature-checked in the pure layer; item 3 must verify before insertion (junk low-timestamp records could crowd a real removal out of a 16-slot set). Minted `member-admission.v1`/`member-removal.v1` tokens beyond §8.3's two — respell in item 3 if wanted. Legacy `sessionGoodbye` has no record shape yet (item 3 decides).
- Instrument the wire before believing an inference; a negative read off an *accessor* is not a negative observed on the wire.
- The Lane C harness exists (`FERNLET_MESH_MATRIX`/`_FLOWS`/`_CONSOLE_LOG` + chaos) — reuse it. It commits **both** proximity gates.
- One contiguous write per QUIC frame is load-bearing.
- A hard-killed QUIC peer sends no `CONNECTION_CLOSE`; survivor refuses re-dials until its idle timer — bounded, not a leak.
- `/loop` never compacts between iterations → fresh session per phase; the ledger is the only durable state.
- The id-vs-endpoint family and `MeshTunnelConvergence` are **closed** (`2f273a9`, `96337a3`). Do not re-audit.
- Concurrent sessions share this tree and sim fleet; `Localizable.xcstrings` + `xcschememanagement.plist` are held by another session — never stage them.

## Next item
3b (`member-removal.v1` wire frame), then 7. Item 0 stays deferred behind tier-1 work.
