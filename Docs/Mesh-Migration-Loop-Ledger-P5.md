# Mesh Migration Loop Ledger — P5

**Phase:** P5 (encrypted store-and-forward routing) · **Prompt:** [Next-Round-Prompt-Mesh-P5-2026-09-03.md](Next-Round-Prompt-Mesh-P5-2026-09-03.md)
**Started:** 2026-09-03 · **Iteration:** 6 · **Tree at seed:** main = `b31b7c0` (pushed; launcher commit on top of `6bc98ee`)

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`. Tier per §2.
| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 1 | MeshRoutedManifest + MeshRecipientKeyWrap (§11) | 1 | — | done | `bf31f46` | trio additive, no golden moved; verifier splits departed (ok) vs removed (refused); acceptedTypeTokens is item 11's seam |
| 1a | Pre-existing test-host crash: `unowned let store` in mesh rigs (MeshNetworkManager.swift:182, PresenceManager.swift:141) traps nondeterministically after mesh.merge.askedLateReconnect | 1 | — | todo | | seen in P4-era logs before item 1 existed; rig must own the store for the manager's lifetime; small, file-disjoint |
| 2 | MeshChunk on P2's existing stream lane | 1 | 1 | done | `5019e04` | origin-signed chunks + assembly-time contentHash check; chunkID derived, origin-free; Transport/ docs-only |
| 3 | MeshCustodyReceipt, four-state sidecar + fifth wrinkle | 1 | 2 | done | `64e8c44` | MeshRoutedStore five-state floor; witness-gated receipt (durable-before-acknowledged as a type rule); wipe row + delete-all wired; keychain service com.fernlet.mesh-routed |
| 4 | MeshRecipientReceipt, per-type ack stages | 1 | 3 | done | `fdabe2e` | stage resolved from the type token via ONE table (item 11's value); witness-gated; heart = judgements + ledger proof + itemID==giftID; routed index schema → 2 |
| 5 | Routed content digest, own frozen token | 1 | 1 | done | `df1a48d` | MeshRoutedInventory (no 'Digest' stem), advertiser-signed, exact chunk bitmap + signer index lists; Delta.between → ask/offer/receipts; matched = quiescence |
| 6 | The drain on the one merge path | 1 | 1, 5 | in-flight | | reconnect ≡ merge ≡ relay drain. From item 5: `peerRoutedInventories` (never `peerInventoryDigests`) holding the peer's inventory + its quiescence bit; its OWN once-per-peer-per-session set (not `reGossipedToFingerprints`); a per-peer per-session refused set for capacity refusals subtracted from the entitlement set; the routed answer inside `receiveInventoryDigest`'s single Task; a non-`.loaded` store sends NO digest, never an empty one |
| 7 | Merge-window redesign (2d comes due) | 1 | 6 | todo | | close only when every asked peer matched; consumes `converged(local:peerReportsQuiescent:)` + the four deadlock regressions in MeshRoutedInventoryDeltaTests; must decide: transfer-length window holding, digests sent only as a link opens, the capacity-refusal contract |
| 8 | Custody-transfer-on-departure | 1 | 3, 6 | todo | | the load-bearing case; entitlement source 2 + the custody self-rule: the digest is the index, the signed receipt is the authority; `MeshCustodyHandoffSummary.handedOffItemCount` is the one field P5 fills; increment 1's only relay hop; item 3's door is `recordingCustodyTransfer(item:for:receipt:now:)` (parked item answers manifestMismatch); `advancingAll` must choose skip-delivered vs refuse-batch (item 4 documented it by a passing test, not fixed) |
| 9 | Backpressure at 256 MiB / 1024 items | 1 | 3 | todo | | bounded, visible refusal, never silent growth; must COUNT parked manifest-less chunks (C10) and DROP a parked set whose manifest is refused; read `itemsReclaimableAsCustodian`, NEVER `isAcknowledgedLocally` (D-4.19); MUST add the missing `capacityExceeded("chunkCount")` guard in `MeshRoutedItemRecord.init(from:)` (MeshRoutedIndex.swift ~410 — decodes a bare UInt32; item 5 residual) |
| 10 | Locked-device handling | 1 | 3 | todo | | ciphertext-only custody; keychain protection unweakened; D-4.4/4.5 already split photos/text (ciphertext-only IS final) from hearts (custodied(by: self) until a foreground pass); FOREGROUNDNESS is the one unenforced leg on the heart path (D-4.16) — wire `MeshSessionState.activeForeground` here |
| 11 | Type-token registry | 1 | 1 | todo | | unknown types rejected, not forwarded; feeds item 1's `acceptedTypeTokens`; with item 9, drop parked chunk sets on `unknownTypeToken` |
| 12 | MeshFrameReplayWindow wired | 1 | 2 | todo | | against manifest/chunk ids, never epoch. CAVEAT: window bound is 64 frames × 8 senders = 512 ids but one maximal item is 1024 chunks → a legitimate 65th chunk hits `senderWindowFull`; resize/key per item, do not paper over (chunkID is origin-free, C3/C4); item 4 added a second derived id per (origin, item, member) for receipts |
| 13 | Retire the three keyEpoch gates with the path | 1 | 1–7 | todo | | never loosen in place; re-check line numbers first |
| 14 | P5 acceptance battery | 1 | 1–13 | todo | | extend MeshScheduleGenerator, not a new rig |

## Blocked on owner
- (close-out flag) `MeshSessionContext.routingInventoryDigest` is provably dead as of item 5 (left nil) — delete at close-out or hand to P6.
- (close-out flag) `CryptoFormatCensusTests` now has TWO sealed at-rest mesh surfaces outside its census (mesh-session from P3, mesh-routed from P5 item 3) — P3's precedent followed; owner decides whether the census grows.
- (close-out flag) the duress pre-draw sweep names neither `com.fernlet.mesh-session` nor `com.fernlet.mesh-routed`; both die in the delete-all funnel — decide whether duress should pre-draw them too.
- §18.2 partition UX copy — default: subtitle count only, no new string (unchanged from P4).
- Legacy unsigned two-party removal's retirement — default: leave frozen (unchanged from P4).
- CI gate lines for MeshP3/P4 AcceptanceTests — still not wired into s3-wall.yml.

## Decisions taken (defaults from §3 unless the owner overrides)
| Decision | Choice | Taken on |
|---|---|---|
| Relay-retention, increment 1 | origin-only until departure (item 1 mints, no relay hop) | 2026-09-03 |
| Merge window closing rule | (default: every asked peer matched) | — |
| MeshDeliveryTarget persistence | inside MeshRoutedStore: restored from the SIGNED manifest + a sparse progress map (no stored destination list); type stays non-Codable; wipe row + delete-all in the same commit | 2026-09-03 |
| Routed digest wire token | `fernlet.mesh.routed-inventory-digest.v1` = `Signature.meshRoutedInventoryDigestV1` + `PayloadType.meshRoutedInventoryDigest`; no Hash sibling; Swift types `MeshRoutedInventory*` (no 'Digest' stem) | 2026-09-04 |
| Four-state sidecar model | MeshRoutedStore mirrors MeshSessionStore's LoadToken exactly (rawValue sets asserted equal) + §19.5 seal-refused; own schema, own keychain service; MeshSessionContext schema stays 2 | 2026-09-03 |
| Departure delivery ack | (default: still no ack; drain carries custody instead) | — |
| D1 recipient keys | mint takes caller-supplied verified `[fingerprint: X25519 pub]`; refuses by name if a destination lacks one | 2026-09-03 |
| D2 contentHash/size | opaque SHA-256 over the CIPHERTEXT + complete sealed-blob size; item 1 computes neither | 2026-09-03 |
| D3 item seal | not item 1 and not item 2 — the seal is item 6 / P6's; `AEAD.meshRoutedItemV1` stays Reserved; content key from `makeContentKey()` | 2026-09-03 |
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
| C1/C2 chunk integrity | BOTH: per-chunk origin Ed25519 signature over the transcript AND assembly-time contentHash check; relays forward the origin-signed chunk unchanged, never re-derive the inner signature | 2026-09-03 |
| C3/C4 chunkID | derived, not a wire field: UUID(SHA-256(purpose ‖ itemID ‖ index)[0..<16]); origin-free — the replay window separates by sender | 2026-09-03 |
| C5/C6 digests | domain-tagged: `Hash.meshRoutedContentV1` "fernlet.mesh.routed-content.hash.v1", `Hash.meshRoutedChunkV1` "fernlet.mesh.routed-chunk.hash.v1", + chunk-id purpose; manifest.contentHash meaning frozen = SHA-256(lp(purpose) ‖ blob) | 2026-09-03 |
| C7 chunk frame | `Signature.meshRoutedChunkV1` "fernlet.mesh.routed-chunk.v1" (.lengthPrefixed) + `PayloadType.meshRoutedChunk` | 2026-09-03 |
| C8/C9 wire fields | meshID, itemID, origin, contentHash, chunkIndex/Count (UInt32), chunkHash, expiresAt, payload, signature; `size` stays the manifest's | 2026-09-03 |
| C10 manifest-less chunk | admissible: verified from the chunk alone and PARKED, never silently dropped (items 9/11 own the parked set's fate) | 2026-09-03 |
| C11/C12 blob contract | no item sealer in item 2 (seal = item 6 / P6); blob is self-contained (nonce + tag inside); contentHash + size measure the COMPLETE blob | 2026-09-03 |
| C13 assembler | in-memory bounded `[UInt32: MeshChunk]`; item 3 re-backs bytes with the sealed sidecar; duplicate-vs-conflict decided on transcript + payload, not hedged signature bytes | 2026-09-03 |
| C14 chunker | primitive = one chunk; bounded loop over it; guard chain (incl. full-blob hash) once per item | 2026-09-03 |
| C15 pacing placeholders | `maxChunksInFlightPerPeer = maxConcurrentOutbound − 1` (3) and 256 KiB are tier-2 placeholders; measure with a concurrent photo transfer on the same tunnel | 2026-09-03 |
| C16 Transport/ | no behavioural change; one docs-only amendment in MeshTransferStreamTable | 2026-09-03 |
| D-3.1/3.2 store shape | five-state value with P3's load/save/quarantine/wipe floor; custody verbs a thin layer on top; sweeps are explicit calls, load() read-only | 2026-09-03 |
| D-3.3/3.14 C13 by extraction | `MeshChunkAdmissionRule` per-chunk + binding verdicts shared by MeshChunkAssembly and the store | 2026-09-03 |
| D-3.5 mint refusals | only the reachable ones (notTheCustodian, witnessForAnotherItem, contentHashMismatch, …); isWellFormed does not pre-check origin ≠ custodian | 2026-09-03 |
| D-3.6 bad chunk file | missing/unauthenticated chunk file → item INCOMPLETE (descriptor dropped, index repaired), not a corrupt store | 2026-09-03 |
| D-3.7 witness | `MeshCustodyDurabilityWitness` init fileprivate to MeshRoutedCustodyCommit.swift; LoadToken init fileprivate to MeshRoutedStore.swift — two gates, two files | 2026-09-03 |
| D-3.8 refused | RETRYABLE (as P3); `MeshRoutedUnavailability` is an outcome value, deliberately not `Error` | 2026-09-03 |
| D-3.9 delivered | no `delivered` rung written in item 3 — only the frozen spelling; item 4/6 write it | 2026-09-03 |
| D-3.10/3.11 transfer + idempotence | transfer names destinations, custodian from the receipt; idempotent = re-streams + re-gates, never skips | 2026-09-03 |
| D-3.12/3.13 caps | over-cap at rest = corrupt, never clamped; writer doors refuse by name; file cap counts the directory; an orphan-making writer removes it | 2026-09-03 |
| D-4.1/4.2 receipt | recipient-signed, about the origin's item, forwarded verbatim; the ack STAGE is not on the wire — receipt = "final"; stage resolved from the manifest's type token via the table | 2026-09-03 |
| D-4.3 decrypt-pending | = `custodied(by: self)` on the existing frozen ladder; no fourth rung | 2026-09-03 |
| D-4.4/4.5 locked device | photos/text: durable ciphertext-only storage IS final; hearts: NOT final until a foreground pass (custodied(by: self) across restarts) | 2026-09-03 |
| D-4.6 control | the ACK RECORD must be durable (index write), not the content | 2026-09-03 |
| D-4.7 one table | store door takes the TABLE: `committingDelivery(item:recipient:stages:evidence:now:)`; shipping code names exactly one `MeshRoutedAckStageTable` (grep-wall) | 2026-09-03 |
| D-4.8/4.9/4.10 heart evidence | three fail-closed legs: judged exactly once in this `MeshHeartCommitOutcome` (judgements reused), `ProximityHeartLedger.commitProof(for:)` → `MeshHeartLedgerProof` (additive, read-only, fileprivate init), itemID == giftID frozen for `fernlet.mesh.routed-type.heart.v1` | 2026-09-03 |
| D-4.11 routed index schema | `MeshRoutedIndexSchema.current` = 2; schema 1 corrupt (quarantine + orphan sweep); at-rest token unchanged | 2026-09-03 |
| D-4.12/4.13 own receipt + re-commit | recipient stores its OWN receipt in `recipientReceipts` beside peers' (item 6 re-sends); re-commit re-runs the whole verification | 2026-09-03 |
| D-4.14/4.15 refusals | mint errors reachable only; new store refusals `capacityRecipientReceipts`, `unknownTypeToken` | 2026-09-03 |
| D-4.16 foregroundness | unenforceable from a pure value in ProximityKit — item 10 / P6 wire `MeshSessionState.activeForeground` | 2026-09-03 |
| D-4.17/4.18 delivered rung | split as item 3: `committingDelivery` writes record-level `deliveredAt` + witness; heart stage keeps the held-ciphertext precondition (`isComplete && isCustodied`) — a deliberate deviation from §11's letter | 2026-09-03 |
| D-4.19 awaiting local ack | `itemsAwaitingLocalAck(at:for:)` = live items where this device is a destination and its OWN receipt is absent | 2026-09-03 |
| Type tokens | `MeshRoutedTypeToken` photo / tempMessage / heart = `fernlet.mesh.routed-type.<x>.v1`, frozen and pinned by test | 2026-09-03 |
| D-5.2/5.3 entry summary | two signer INDEX lists (custody / recipient receipt signers), no rollup hash; `==` over the canonical value is set equality | 2026-09-04 |
| D-5.4 member table | `members: [String]` ≤ 16, sorted, distinct, MINIMAL + `UInt8` indices (minimality is load-bearing for canonical bytes) | 2026-09-04 |
| D-5.5/5.6 what is advertised | live-only at an injected `now`; parked / delivered / unrestorable all advertised; custodySigners = stored custodians ∪ self iff custodied and origin ≠ self | 2026-09-04 |
| D-5.7 over-cap | refused by name (`.overCapacity` / `.malformed`), never clamped or re-sorted | 2026-09-04 |
| D-5.8 signed | advertiser-signed, `sentAt` bound in, five-check verifier, key from the admission ledger | 2026-09-04 |
| D-5.9/5.15 matched (item 7) | QUIESCENCE, never equality; `isQuiescent` is strictly local; `converged(local:peerReportsQuiescent:)` needs BOTH sides — the peer's bit rides item 6's routed answer | 2026-09-04 |
| D-5.10 comparison inputs | `Delta.between(local:remote:offerableToPeer:)`; only the OFFER lists take the entitlement set (two origin-signed sources) | 2026-09-04 |
| D-5.11/5.12 no persistence, no replay window | no file/keychain/UserDefaults/wipe row; digest not admitted to `MeshFrameReplayWindow` — its replay defence is the signed `sentAt` | 2026-09-04 |
| D-5.13/5.14 builder + bitmap | `init?` nil only past `maxReferencedMembers`; mint throws `tooManyReferencedMembers`; exact held-chunk bitmap ceil(chunkCount/8), frozen bit order, trailing zeros mandatory | 2026-09-04 |
| D-5.16/5.17 delta safety | foreign-mesh pair → nil, never an empty delta (empty reads as matched = fail-open); signer sets compared as resolved fingerprints, never indices | 2026-09-04 |
| D-5.18/5.19 review round | mint derives "this device" from `identity` alone (no `selfFingerprint` param); `ask`/`offer` are DISTINCT keys in canonical order | 2026-09-04 |

## Session notes
- 2026-09-04 00:41: item 5's workflow hit the session usage limit mid-verify (implementer green, full suite 4232; 34 refuter votes + fix + gauntlet failed at spawn). Resumed from run wf_65b84324-d14 after the 12:40am reset — cached stages replay, only verify/fix/gauntlet re-run. If a workflow's agents fail with 'session limit', schedule a wake for after the reset instead of retrying.
- 2026-09-03: Opus 4.8/5 were briefly down (item 1's workflow ran on the session model, Fable 5.1); owner confirmed Opus is back — later items use `model: "opus"` per the launcher. Ultracode on: each item runs as a small Workflow (understand → implement → adversarial verify → fix).

## Surprises worth not re-deriving
- `#expect(_, "comment")` needs a LITERAL comment (`String` → `Comment?` build error); no interpolated/computed comments.
- ColumnCrypto seals with a fresh nonce on every write — never assert sealed-byte equality across two writes; compare the decoded value.
- An EMPTY routed store's pre-first-unlock refusal arrives at `.seal`, not `.open` (a green field answers absent without consulting custody); a corrupt-quarantine test must establish the seal key before planting garbage (custody is classified before content).
- `Result<_, MeshRoutedUnavailability>` will not compile and must not — the unavailability is an outcome value, not an `Error`.
- **CryptoKit Ed25519 signatures are HEDGED (nondeterministic).** Never compare signed records by full `==`; compare canonical bytes + payload and verify both signatures. Two mints differ only in the 64 signature bytes; goldens exclude the signature.
- `CryptographicWallScan` matches bare primitive names in COMMENTS too (`rawCryptographicCallsNameAPurpose`); don't name a sealing primitive in prose.
- A non-existent suite in `-only-testing` matches zero tests and still prints `TEST EXECUTE SUCCEEDED` — always check `Test run with N tests` is non-zero (item 1's verifier suite is `MeshRoutedManifestSigningTests`; there is no `…VerifyTests`).
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
6 (in-flight, iteration 6) — then 1a as a bundled small commit when convenient