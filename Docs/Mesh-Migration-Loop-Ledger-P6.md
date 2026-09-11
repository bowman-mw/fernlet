# Mesh Migration Loop Ledger — P6

**Phase:** P6 (feature routing — text, hearts, key advertisement) · **Prompt:** [Next-Round-Prompt-Mesh-P6-2026-09-10.md](Next-Round-Prompt-Mesh-P6-2026-09-10.md)
**Started:** 2026-09-10 · **Iteration:** 1 · **Tree at seed:** main = `3a32be0` (P5 close-out + post-close review corrections)

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`. Tier per §2.
| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 1 | Key-advertisement wire family `fernlet.mesh.key-agreement.v1` | 1 | — | todo | | additive family, own door; MeshSessionContext 2→3; second verified source + keyMismatch |
| 2 | Pairwise mesh identity — promote at one commit | 1 | 1 | todo | | audit what currentMesh != nil switches on first |
| 3 | Receiver-side per-type cap + photo row's narrowed cap | 1 | — | todo | | one commit: check + rejection case + non-dropping arm |
| 4 | Temporary text on the routed store | 1 | 1, 2, 3 | todo | | three passes: sender / receiver+W2(b) / retirement wall |
| 5 | Projection retryable-vs-final | 1 | 4 | todo | | final excluded; retryable sub-allowance |
| 6 | Hearts on the routed store | 1 | 1, 5 | todo | | .singleRecipient flip + subset init; ceremony behind mayCommitRoutedHeartLedgerJudgement; consume-on-stage |
| 7 | sentAt monotonicity guard | 1 | — | todo | | own commit; battery asserts never backwards |
| 8 | Departed-origin custodian-forwarding cell (second rig) | 1 | — | todo | | owed by name from P5 item 12/14 |
| 9 | P6 acceptance battery + CI gate lines | 1 | 1–8 | todo | | overlay fields after 8; MeshP6*AcceptanceTests; s3-wall.yml same commit |
| 10 | Tier 2: Lane C .chat re-run + two-session hearts/moderation script | 2 | 4, 6 | todo | | timebox two iterations |
| 11 | Close-out: §12 BUILT, §24 P7 handoff, P7 launcher, memory | 1 | 1–10 | todo | | draft → verify → apply from files |

## Blocked on owner
- Option (b) for handleEncryptedMetadata; D-7.30 once-per-window; §18.2 copy; legacy unsigned removal; transcript sid; hardware lanes (Lane A/B/D, AWDL); census/duress for the two mesh keychain services; final wording of the routed hold/refusal copy. (Main `3a32be0` == origin/main; S3 Wall + Power of 10 workflows both green on it, 2026-09-06.)

## Decisions taken (defaults from §3 unless the owner overrides)
| Decision | Choice | Taken on |
|---|---|---|
| Key advertisement family shape | (default: additive family, own door, not a record kind) | — |
| Key advertisement persistence | (default: MeshSessionContext 2→3, older corrupt) | — |
| Pairwise identity | (default: promote at one commit) | — |
| Heart destinations | (default: .singleRecipient flipped in place + subset init) | — |
| Heart send feedback | (default: consume-on-stage) | — |
| Second expiry rule | (default: not added) | — |
| routingInventoryDigest | (default: retired in item 1's schema bump; §23.4 says owner's — amend §23.4 in that commit) | — |
| Items 1–2 despite §23.4's owner gate | taken under the post-close review's recommendation (P5 ledger: "recorded at the head of P6's list"); reported as policy acts at close-out; launcher verified against HEAD (62 claims, 10 corrected) before commit | 2026-09-10 |

## Surprises worth not re-deriving
- `test-without-building` runs the LAST build — revert, REBUILD, then test.
- A suites list is only as good as its names: regenerate from `@Suite` declarations; count `◇ Suite` starts against `✔ Suite` passes; `Test run with N tests` must be non-zero.
- The FIRST test invocation after a build or an idle gap hangs (~350 s); the retry is the acceptance — warm the runner with a tiny suite.
- A process-global audit signal cannot witness a per-cell claim under concurrent suites; witness per run.
- CryptoKit Ed25519 signatures are hedged — goldens exclude signature bytes; never `==` on signed records. `CryptographicWallScan` matches primitive names in comments.
- `#expect(_, "literal")` only; bind `allSatisfy` Bools first; ColumnCrypto nonces differ per write — compare decoded values.
- A settle's `until:` fires synchronously inside the pump — assert on frame counts.
- After one `unowned` trap expect the next down the chain; fakes hold fabrics `weak`; use the rigs (`MeshDepartureRig.node`, `spawnHostPinned`).
- `activeSlots` is a distance rank, not a reach set; reach = every committed slot ∩ derived roster.
- `@Test(arguments: [])` is green over nothing; `MeshQuorumFixtures` proposals are placeholder-signed; a `ProximityPayloadHandling` conformance cannot take `now:`; `Result<_, MeshRoutedUnavailability>` must not compile; `MeshRoutedStorageScope.production` never as a test literal.
- Long agent work can die of the session usage limit at a fixed local reset hour — resume, don't retry; apply steps read inputs from scratch files.
- Closed; do not re-audit: `MeshTunnelConvergence`, id-vs-endpoint family, crypto-purpose / `PayloadType` / record-kind spellings, plan §10.7–§10.10 and §11.1–§11.4, Proximity-Security-Followups §1.
- Concurrent sessions share this tree + sim fleet; `Localizable.xcstrings` + `xcschememanagement.plist` held by another session, a stray PDF in `Docs/` — never stage them.

## Next item
3 (file-disjoint, no prereq), then 1.
