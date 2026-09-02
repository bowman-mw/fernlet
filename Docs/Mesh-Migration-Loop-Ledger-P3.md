# Mesh Migration Loop Ledger — P3

**Phase:** P3 (durable session context, roster, membership) · **Prompt:** [Next-Round-Prompt-Mesh-P3-2026-09-01.md](Next-Round-Prompt-Mesh-P3-2026-09-01.md)
**Started:** 2026-09-01 · **Iteration:** 4 · **Tree at seed:** main = `801e34f` (pushed); launcher at `adfa3c0`

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`. Tier per §2.
| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 0 | Multi-node sim bring-up (3 nodes) | 2 | — | todo | | de-risks every tier-2 item; deferred behind tier-1 work per §1.3 |
| 1 | Records + derived roster, pure | 1 | — | done | `cd8ea71` | 4 record kinds, ledger of 4 sets, roster derived per read; caps = keep-earliest-k (merge-stable); barred keys joined from admission |
| 2 | Sealed MeshSessionStore (5-state, per-instance root, §17.3) | 1 | 1 | done | `8166071` | 1 iter. Store+paperwork landed; manager save-cadence wiring folded into item 6 |
| 3 | Membership event wire tokens | 1 | 1 | done | `700605c` | transcript NOT moved; goodbye = presence-only downgrade; verifier gates insertion |
| 4 | Epoch model §8.4 + tighten the gate | 1 | 3 | todo | | |
| 5 | Membership-driven rotation | 1 | 3, 4 | todo | | closes voted-out-keeps-key gap |
| 6 | State machine §8.2 on the fake | 1 | 2 | todo | | |
| 7 | IntroductionAuthority → derived roster | 1 | 1, 2, 5 | todo | | makes matrix row 3 shipping |
| 8 | P3 acceptance battery | 1 | 2,4,5,6,7 | todo | | |
| 9 | Multi-node membership at tier 2 | 2 | 0, 7 | todo | | Lane C, 3–6 sims |

## Blocked on owner
- Transcript-`sid` / `epochRef` move (§3 decision, §18 decision 7) — confirm before the wire changes.

## Decisions taken (defaults from §3 unless the owner overrides)
| Decision | Choice | Taken on |
|---|---|---|
| Bind `sid`+`epochRef` in transcript v2 | (default: yes, once) | — |
| Epoch gate strict after §8.4 | (default: yes) | — |
| Publish `fp` in TXT | (default: no unless bundled) | — |

## Surprises worth not re-deriving
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
4 (epoch model + strict gate). Build MeshEpochRef/keyring/acceptance WITHOUT binding `sid` into the transcript — the `sid` move stays owner-gated; serialize the real epochRef into the existing string field only if goldens stay honest. Item 0 stays deferred behind tier-1 work.
