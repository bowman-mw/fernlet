# Mesh Migration Loop Ledger — P5

**Phase:** P5 (encrypted store-and-forward routing) · **Prompt:** [Next-Round-Prompt-Mesh-P5-2026-09-03.md](Next-Round-Prompt-Mesh-P5-2026-09-03.md)
**Started:** 2026-09-03 · **Iteration:** 2 · **Tree at seed:** main = `b31b7c0` (pushed; launcher commit on top of `6bc98ee`)

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`. Tier per §2.
| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 1 | MeshRoutedManifest + MeshRecipientKeyWrap (§11) | 1 | — | done | `bf31f46` | trio additive, no golden moved; verifier splits departed (ok) vs removed (refused); acceptedTypeTokens is item 11's seam |
| 1a | Pre-existing test-host crash: `unowned let store` in mesh rigs (MeshNetworkManager.swift:182, PresenceManager.swift:141) traps nondeterministically after mesh.merge.askedLateReconnect | 1 | — | todo | | seen in P4-era logs before item 1 existed; rig must own the store for the manager's lifetime; small, file-disjoint |
| 2 | MeshChunk on P2's existing stream lane | 1 | 1 | in-flight | | reuse MeshTransferStreamTable, no new transport |
| 3 | MeshCustodyReceipt, four-state sidecar + fifth wrinkle | 1 | 2 | todo | | seal refused ≠ deferred |
| 4 | MeshRecipientReceipt, per-type ack stages | 1 | 3 | todo | | hearts final only at foreground decrypt + commit |
| 5 | Routed content digest, own frozen token | 1 | 1 | todo | | do NOT collide with membership's inventory-digest.v1 |
| 6 | The drain on the one merge path | 1 | 1, 5 | todo | | reconnect ≡ merge ≡ relay drain |
| 7 | Merge-window redesign (2d comes due) | 1 | 6 | todo | | close only when every asked peer matched |
| 8 | Custody-transfer-on-departure | 1 | 3, 6 | todo | | the load-bearing case; increment 1's only relay hop |
| 9 | Backpressure at 256 MiB / 1024 items | 1 | 3 | todo | | bounded, visible refusal, never silent growth |
| 10 | Locked-device handling | 1 | 3 | todo | | ciphertext-only custody; keychain protection unweakened |
| 11 | Type-token registry | 1 | 1 | todo | | unknown types rejected, not forwarded |
| 12 | MeshFrameReplayWindow wired | 1 | 2 | todo | | against manifest/chunk ids, never epoch |
| 13 | Retire the three keyEpoch gates with the path | 1 | 1–7 | todo | | never loosen in place; re-check line numbers first |
| 14 | P5 acceptance battery | 1 | 1–13 | todo | | extend MeshScheduleGenerator, not a new rig |

## Blocked on owner
- §18.2 partition UX copy — default: subtitle count only, no new string (unchanged from P4).
- Legacy unsigned two-party removal's retirement — default: leave frozen (unchanged from P4).
- CI gate lines for MeshP3/P4 AcceptanceTests — still not wired into s3-wall.yml.

## Decisions taken (defaults from §3 unless the owner overrides)
| Decision | Choice | Taken on |
|---|---|---|
| Relay-retention, increment 1 | origin-only until departure (item 1 mints, no relay hop) | 2026-09-03 |
| Merge window closing rule | (default: every asked peer matched) | — |
| MeshDeliveryTarget persistence | (default: inside routed store, own wipe row) | — |
| Routed digest wire token | (default: fernlet.mesh.routed-inventory-digest.v1) | — |
| Four-state sidecar model | (default: mirrors MeshSessionContext's LoadToken + fifth wrinkle) | — |
| Departure delivery ack | (default: still no ack; drain carries custody instead) | — |
| D1 recipient keys | mint takes caller-supplied verified `[fingerprint: X25519 pub]`; refuses by name if a destination lacks one | 2026-09-03 |
| D2 contentHash/size | opaque SHA-256 over the CIPHERTEXT + complete sealed-blob size; item 1 computes neither | 2026-09-03 |
| D3 item seal | not item 1; `AEAD.meshRoutedItemV1` stays Reserved; content key from `makeContentKey()` | 2026-09-03 |
| D4/D5 wrap | fresh ephemeral + nonce per wrap; AAD = purpose ‖ meshID ‖ itemID ‖ origin ‖ recipient (transplant-proof) | 2026-09-03 |
| D6 expiry | receiver requires exact floored equality with own hardDeadline + 1200 s | 2026-09-03 |
| D7 wraps ≡ destinations | wire-enforced; "roster − self" is mint policy, never a v2 trigger | 2026-09-03 |
| D8 size bound | 1…256 MiB on `MeshRoutedManifestFormat`; item 9 reuses the constant | 2026-09-03 |
| D9 verify vs unwrap | separate calls: verify = public material; unwrap = private KA key via closure (item 10) | 2026-09-03 |
| D10 frame body | `MeshRoutedManifestPayload { manifest }`, departure-payload idiom | 2026-09-03 |
| D11 store key | manifest is NOT MeshMergeableContent; routed-store union key = signed pair (originFingerprint, itemID) | 2026-09-03 |
| D12 destinations | trusted on origin signature, bounded, distinct, origin-free; NOT checked against ledger.admissions | 2026-09-03 |
| D13 unknown tokens | verifier takes `acceptedTypeTokens` from day one; refused between shape check and origin lookup | 2026-09-03 |
| D14 departed vs removed | departed origin still verifies; quorum-removed origin refused (`originRemoved`) | 2026-09-03 |

## Session notes
- 2026-09-03: Opus 4.8/5 were briefly down (item 1's workflow ran on the session model, Fable 5.1); owner confirmed Opus is back — later items use `model: "opus"` per the launcher. Ultracode on: each item runs as a small Workflow (understand → implement → adversarial verify → fix).

## Surprises worth not re-deriving
- **Full-suite host crash is pre-existing and nondeterministic** (item 1a): `Attempted to read an unowned reference … already destroyed` on the main thread after `mesh.merge.askedLateReconnect`; the 60 "failing" tests are the ones interrupted, no assertion failed. Re-run the interrupted suites targeted (54 suites → 680 green) and read the implementer's clean full run before believing the red.
- zsh does not word-split `$SUITES` — `${=SUITES}` or an array; `TEST EXECUTE SUCCEEDED` over "Executed 0 tests" is a green banner over nothing.
- Swift Testing's `passed on 'Clone` counter reads 0 in this Xcode; the proof is `Test run with N tests in M suites passed` + per-suite ✔ lines.
- `#expect(xs.allSatisfy(\.p))` fails to build (macro drops rethrows → "call can throw"); bind the Bool first.
- `MeshRoutedManifestMintError.tooManyDestinations` is unreachable (roster cap 8 → ≤ 7 destinations); documented, not tested.
- `MeshQuorumFixtures` mints placeholder-signed proposals the record verifier refuses; use real `SignedRemovalRecord.signed(...)` on a 3-rig for a removed origin.
- Seeded property test paid for itself first iteration in P4 (found 2c, late-reconnect strand, 2d). Write item 14's extension beside the first increment; every event = one call into an existing seam.
- One `ProximityCoordinator` per link in an N-manager rig.
- `ensureProvisioned()` + roster size as hard precondition; distinct `identity:` per manager.
- Sample rotation-queue/drain state right after a synchronous pump, never after an `await`.
- Heals must be ordered (re-gossip / drain answer fires once per peer per session).
- A healed partition must re-form as a full mesh with a second commit round.
- `MeshNetworkManager` holds its host store `unowned` — inline test store traps; use `MeshDepartureRig.node`.
- `.merge` > `.membership` > `.timer` in the 2 s coalescing window; `seedMembershipLedgerForTesting` seeds without spending one.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` on the test target — fixtures `@MainActor`.
- Widening an existing signed frame moves its golden — new additive frame + full trio; re-implement an existing golden byte-for-byte first, then derive the new one.
- `test runner hung before establishing connection` hits the first invocation after every build; retry is the acceptance (~13 min each).
- Close-out apply steps read inputs from scratch files, not a long inline prompt (529s).
- Closed; do not re-audit: `MeshTunnelConvergence`, id-vs-endpoint family (`96337a3`, `2f273a9`), crypto-purpose / `PayloadType` / record-kind spellings, plan §10.7–§10.10.
- Concurrent sessions share this tree + sim fleet; `Localizable.xcstrings` + `xcschememanagement.plist` held by another session — never stage them.

## Next item
2 (in-flight, iteration 2) — then 1a as a bundled small commit when convenient