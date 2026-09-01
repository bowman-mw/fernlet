# Mesh Migration Loop Ledger — P2

The loop's durable memory. `/loop` resumes the same context and never compacts, so this file — not
the orchestrator's head — is where state lives. **Keep it short:** it is read on every wake, so every
line costs orchestrator budget forever. Prune the surprises list when an entry stops earning its
place.

**Phase:** P2 (NetworkMeshSession) · **Prompt:** [Next-Round-Prompt-Mesh-P2-2026-08-31.md](Next-Round-Prompt-Mesh-P2-2026-08-31.md)
**Started:** 2026-08-31 · **Iteration:** 11 · **Tree at seed:** main = `16b9cb2` (pushed); loop head `7be47c8`

## Items

States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`.
Tier per prompt §2 — 1 = no radio, 2 = device↔Simulator, 3 = two physical devices.

| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 0 | Sim↔sim experiment (prompt §2). Timeboxed to ONE iteration, DEBUG toggle only. | 2 | — | done | `926a791` | **CONNECTED** — Bonjour + QUIC/TLS + signed introduction both ways; multi-node on one Mac is a real lane (re-tier P3–P6 at close-out). Datagrams didn't negotiate — see surprises |
| 1 | Capture Lane A diagnostic report; promote runbook rows *Observed working* → *Pass* | 2 | 1 device | todo | | Owner reports it connects; no report captured. Must also settle the datagram row (see surprises) |
| 2 | String-catalog repair (9 stale keys, pre-existing) | 1 | quiet tree | todo | | SKIP if `Localizable.xcstrings` still held by another session |
| 3 | §6.5 root fix: stable `id` per session + close §6.4 asymmetries 1–3 | 1 | — | done | `b8d7a5a` | `SessionPeerIdentity` minted once per peer, session-scoped, cleared in `stop()`; 9 tier-1 tests; goldens un-re-pinned |
| 3b | Close the two remaining id-only `handleChannelReady` guards (RecipeShare + Presence) | 1 | 3 | done | `2a03800` | Endpoint helper + 3-case admission enum per manager, item-3 idiom; 4 tests; suite green (3320) |
| 3c | Outbound `sendHeart` gate: endpoint recognition via `hasHeartConnection(with:)` | 1 | 3b | done | `8c258b5` | Negative-checked against the old line; 45 tests in 4 suites green |
| 3d | Close the id-vs-endpoint family for good (timeout path + exhaustive audit) | 1 | 3c | done | `2f273a9` | 14 sites fixed; full audit table with per-site verdicts is in the commit message. FAMILY CLOSED — do not re-audit |
| 4 | Dial-policy tie-breaker: exhaustive tier-1 tests BEFORE any QUIC code | 1 | 3 | done | `ce91f5d` | Policy sound, 18 tests both-sides-exhaustive. Late TXT only ever WITHDRAWS dial permission (double-dial possible pre-TXT, deadlock impossible) |
| 5 | `NetworkMeshSession` skeleton (listener/browser/connection/session actor) | 1 | 3, 4 | done | `5835b52` | Full duty list in one slice; 47 tier-1 tests, no `.discovered`, TXT carries `sid`/no `fp`, cellular prohibited, TLS identity ephemeral. Residuals live in items 7/8/10 + P9 |
| 6 | No-tracking wall extension — SECOND marker family, not `httpClientMarkers` | 1 | 5 | done | `5835b52` | `localLinkMarkers` + `permittedLocalLinkFiles` (2 files), disjoint-by-test from the HTTP family, planted-marker proven |
| 7 | Signed channel introduction productionized | 1 | 5 | done | `48b0c5c` | 12 named rejections, each a teardown; inbound now ranked by verified `sid`; `MeshIntroductionAuthority` is the item-8 seam (nil ⇒ refuse all) |
| 8 | Transport selection in `MeshNetworkManager`; QUIC NOT default | 1 | 5, 7 | done | `099727d` | `MeshTransportSession` seam; Release can only answer MC; `FERNLET_MESH_TRANSPORT=quic` (DEBUG, one launch); manager IS the introduction authority; manager invite path finally tier-1-tested |
| 9 | Rejection matrix at tier 2 | 2 | 8 | done | `7357110` | 6/6 rows + baseline observed sim↔sim over real QUIC; Lane C in runbook. Shipping removals refuse as `unknownIdentity` (barred stays empty by design) |
| 10 | Mesh flows at tier 2 (admission, QR, photos, chat, hearts, shop, moderation, age gates) | 2 | 8 | todo | | Needs per-transfer photo streams in `NetworkPeerChannel` (item-5 residual). **Empty roster ⇒ QUIC refuses every peer** — first-meeting stranger admission is a P3 membership question (plan §8); flows need membership established first (MC or fixture) then transport switched |
| 11 | Tier-3, and only this: AWDL path + Local Network permission prompt | 3 | 10 | todo | | Justify any addition to this row |
| 12 | Convert the heartbeat flake test to a polled wait | 1 | — | done | `3ca3ddb` | Reused suite's `waitUntil` (2 s deadline, 200-poll floor); 3 isolated passes + suite |
| 13 | **Verified pair converges to ONE tunnel.** Observed on-radio (item 9, both baseline runs): nil-`sid` window ⇒ both dial; inbound keys off `connection.id`, never colliding with the browsed key ⇒ suppression never fires. After introduction both sides KNOW the verified `sid` — collapse there by deterministic rule (dial preference), close the loser. Tier-1 repro on fakes + Lane C re-run as proof | 1 | 9 | done | `96337a3` | Fix real by construction, 14 tier-1 tests (repro red pre-fix). **Item 9's two-tunnel reading was churn misread as duplication** — Lane C can't form the duplicate (TXT arrives with browse); the collapse is a Lane B (hardware) row |
| 14 | Widen `TestHookBoundaryTests` to the mesh/probe env families | 1 | — | done | `7ff49fc` | Per-family floors; planted Release-reachable read tripped TH1 by name; all 14 existing reads were clean |
| 15 | **Diagnose the tunnel churn**: 3 activations per side in ~100 s with NO dial failure, refusal, give-up, or transport error logged on either side; predates item 13; reproduces with convergence disabled. First add the missing diagnostic — a live tunnel that ends logs NOTHING (`endTunnel` with a control stream emits no line) — then re-run Lane C and name the cause. Note the unverified correlation: churn cadence ≈ the 30 s heartbeat interval — check whether heartbeats actually flow on the real radio before believing anything else | 2 | 13 | todo | | Precedes item 10 — flows over churning tunnels would be flaky |

## Blocked on owner

- **Item 1** needs one physical iOS 26.5+ device on the same non-isolated Wi-Fi as the Mac. Not
  blocking: items 2–8 are all tier 1 and can proceed while this waits.
- **Non-blocking, wants owner eyes:** item 5 took the FIRST crypto escape hatch since the
  standardization round (`x509-self-signature` — an X.509 self-signature has no Fernlet domain to
  name; census 3→4 files / 6→7 hatches, `Crypto-Domain-Separation.md` updated same commit).
  Review as a policy act.
- **Non-blocking, wants owner eyes (item 7):** the `sid` that drives duplicate-tunnel suppression
  rides an UNSIGNED hello field — §7.2's transcript doesn't include it, and binding it means a
  transcript v2 (moves signed bytes). Impact bounded: a verified roster member can only misdirect
  its own link; admit-both stays safe. Documented on `MeshChannelHello.sessionID`.

## Decisions taken (defaults from prompt §3 unless the owner overrides)

| Decision | Choice | Taken on |
|---|---|---|
| Ephemeral per-mesh TLS identity | Yes (default) | — |
| `prohibitedInterfaceTypes = [.cellular]` | Yes, always (default) | — |
| Publish `fp` in QUIC TXT | No, not in P2 (default) | — |
| Take the §6.5 root fix | Yes, item 3 (default) | — |

## Surprises worth not re-deriving

- **QUIC datagrams show usable frame size 0 on sim↔sim — but NO lane has ever recorded a non-zero
  size** (Lane A's Datagram row was never captured). Equally consistent with a probe QUIC-parameter
  defect that would fail against a device too. Do not record it as a Simulator limitation; one
  device↔Sim run (item 1) settles it. Both ends advertised `maxDatagramFrameSize=1024`, both saw
  `datagram-flow=false`.
- **An absent Bonjour TXT record reads as `device`** — a Sim saw a peer before its TXT arrived,
  logged it `[device]`, and dialed (a dial the pre-existing policy also allowed). The old sim→sim
  refusal was never airtight; no Simulator-origin check may rest on TXT presence alone. Item 4's
  tie-breaker tests should cover the missing/late-TXT case.
- Sim↔sim probe env toggles (all default-off, DEBUG-only): `FERNLET_PROBE_ALLOW_SIM_DIAL`,
  `FERNLET_PROBE_AUTOSTART`, `FERNLET_PROBE_CONSOLE_LOG`. `allowsOutboundConnection` gained a
  7th parameter defaulted `false`.
- `BGTaskScheduler` error 1 on Simulators — the sim lane can never speak to P8's background rows.
- Item 3 **inverted a documented design intent**: the old `stop()` deliberately preserved the
  endpoint map ("an owner would stop recognizing a device"). All three owners now drop every
  peer-keyed record in the same teardown, so preserving identity across `stop()` protects nothing.
- `MeshMultipeerSessionIdentityTests` first test can take ~90–110 s in a loaded full-suite run —
  min-poll-floor absorbing MainActor starvation, bounded, terminates. Not a hang; don't drop the
  poll floor.
- **Standing down a fail-loud path needs a dependents audit** (3d lesson): fixing the heart
  connect-timeout's false retry exposed `pendingHeartSends` quietly depending on that failure —
  the send would have hung at `.connecting` forever. Closing a retry ≠ done; ask what its firing
  was cleaning up.
- Recipe picker rows can't reach an endpoint directly — device recognition from a row is
  three-arm: row id ∨ proven fingerprint ∨ endpoint of the handle the row was minted from.
- `ProximityCoordinatorTests.heartbeatAcceleratesDuringTransferAndUsesCooldownAfterTransfer`
  flaked once under full-suite load (fixed 20 ms sleep vs 80 ms send); passes alone. Now item 12
  (owner folded it into this loop; the new-session chip was dismissed).
- **Runner-hang flake protocol updated (iteration 6):** `simctl shutdown all` did NOT cure it —
  three consecutive ~371 s hangs. What works: `xcrun simctl boot "iPhone 17"` + ~20 s settle
  *before* `xcodebuild`. A concurrent session shares this Mac's simulator fleet.
- `MeshNetworkManager` owns `private let meshSession = MeshMultipeerSession()` outright — no seam
  to inject `FakePeerTransport`, so manager-level invite behavior is untestable at tier 1 until
  item 8 (transport selection) introduces the seam.
- Purpose-wall escape-hatch markers must sit within 3 lines of the call — the scan window is
  `[line−3, line+6]`, so a marker above a long comment falls outside it.
- **Concurrent-session test contention protocol:** another session runs suites on this Mac. Use a
  FRESH log path per xcodebuild run, and `pgrep xcodebuild` before believing a failure — one
  crossed log showed ~20 phantom `FernletLock*`/`SecureEnclaveWrap*` failures that vanished
  uncontended. Boot the destination sim + ~20 s settle remains the hang cure.
- Epoch gate at introduction is deliberately soft (item 7): equal **or one side empty** — a joining
  peer holds no group key yet, so strict equality would make admission impossible. Two different
  non-empty epochs ⇒ `.divergentEpoch`. P3 §8.4's merge relaxes further; flagged in source.
- Flake protocol, refined again (iteration 9): if the sim is already Booted, `simctl boot` is a
  no-op — budget a plain retry, not a boot. Boot+settle only cures the not-yet-booted case.
- Dial budget observed live (item 9): a refusing peer is re-offered exactly 3 times, then silence.
- Lane C exists: `FERNLET_MESH_MATRIX` harness + `FERNLET_MESH_CONSOLE_LOG` + chaos hooks make the
  production mesh drivable on two sims — items 10/15 reuse this, don't rebuild it.
- **Tier-2 evidence lesson (items 9→13):** "accepted twice" read as two live tunnels, but a live
  tunnel that ends logs nothing, so churn masqueraded as duplication. Before believing a
  wire-level inference, instrument the counter (`tunnels=`) and run the control. The Lane C
  duplicate can never form (TXT arrives with the browse result — only one side dials); the
  double-dial window is physical-radio behaviour, so its collapse is proven at tier 1 + Lane B.
- `MeshMultipeerSession.onDisconnectPeerRequestedForTesting` was deleted (item 8 seam replaced it);
  `Docs/Memory-Leak-Review-2026-08-17.md` lines 82/84 name it as a dated historical record — fine.

## Known-red gates that are NOT this phase's fault

- `sync-string-catalogs.sh --check` — nine stale keys, present in the file as committed at `f4fa541`.
  Item 2 fixes it if the tree is quiet. Do not bisect it.

## Next item

**15** — the tunnel-churn diagnosis (instrument the silent live-disconnect path, re-run Lane C,
name the cause; heartbeat-flow check first). Then **10**. Item 1 waits on a device; item 2 stays
skip-gated while `Localizable.xcstrings` is held by another session.
