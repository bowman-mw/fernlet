# Mesh Migration Loop Ledger — P2

The loop's durable memory. `/loop` resumes the same context and never compacts, so this file — not
the orchestrator's head — is where state lives. **Keep it short:** it is read on every wake, so every
line costs orchestrator budget forever. Prune the surprises list when an entry stops earning its
place.

**Phase:** P2 (NetworkMeshSession) · **Prompt:** [Next-Round-Prompt-Mesh-P2-2026-08-31.md](Next-Round-Prompt-Mesh-P2-2026-08-31.md)
**Started:** 2026-08-31 · **Iteration:** 2 · **Tree at seed:** main = `16b9cb2` (pushed); loop head `1540d5b`

## Items

States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`.
Tier per prompt §2 — 1 = no radio, 2 = device↔Simulator, 3 = two physical devices.

| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 0 | Sim↔sim experiment (prompt §2). Timeboxed to ONE iteration, DEBUG toggle only. | 2 | — | done | `926a791` | **CONNECTED** — Bonjour + QUIC/TLS + signed introduction both ways; multi-node on one Mac is a real lane (re-tier P3–P6 at close-out). Datagrams didn't negotiate — see surprises |
| 1 | Capture Lane A diagnostic report; promote runbook rows *Observed working* → *Pass* | 2 | 1 device | todo | | Owner reports it connects; no report captured. Must also settle the datagram row (see surprises) |
| 2 | String-catalog repair (9 stale keys, pre-existing) | 1 | quiet tree | todo | | SKIP if `Localizable.xcstrings` still held by another session |
| 3 | §6.5 root fix: stable `id` per session + close §6.4 asymmetries 1–3 | 1 | — | done | `b8d7a5a` | `SessionPeerIdentity` minted once per peer, session-scoped, cleared in `stop()`; 9 tier-1 tests; goldens un-re-pinned |
| 3b | Close the two remaining id-only `handleChannelReady` guards: `ProximityRecipeShareManager.swift:444`, `PresenceManager.swift:706` — same family as item 3, asymmetric vs their own `shouldAdmitChannel` | 1 | 3 | todo | | Rare post-fix (needs cap-64 eviction or stop/start) but real |
| 4 | Dial-policy tie-breaker: exhaustive tier-1 tests BEFORE any QUIC code | 1 | 3 | todo | | The comparison that deadlocked the mesh |
| 5 | `NetworkMeshSession` skeleton (listener/browser/connection/session actor) | 1 | 3, 4 | todo | | May take 2–3 iterations |
| 6 | No-tracking wall extension — SECOND marker family, not `httpClientMarkers` | 1 | 5 | todo | | Same commit as first QUIC file |
| 7 | Signed channel introduction productionized | 1 | 5 | todo | | Serializer + registry framing together |
| 8 | Transport selection in `MeshNetworkManager`; QUIC NOT default | 1 | 5, 7 | todo | | |
| 9 | Rejection matrix at tier 2 | 2 | 8 | todo | | Drive by making the Simulator misbehave |
| 10 | Mesh flows at tier 2 (admission, QR, photos, chat, hearts, shop, moderation, age gates) | 2 | 8 | todo | | |
| 11 | Tier-3, and only this: AWDL path + Local Network permission prompt | 3 | 10 | todo | | Justify any addition to this row |

## Blocked on owner

- **Item 1** needs one physical iOS 26.5+ device on the same non-isolated Wi-Fi as the Mac. Not
  blocking: items 2–8 are all tier 1 and can proceed while this waits.

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

## Known-red gates that are NOT this phase's fault

- `sync-string-catalogs.sh --check` — nine stale keys, present in the file as committed at `f4fa541`.
  Item 2 fixes it if the tree is quiet. Do not bisect it.

## Next item

**3b** (small — finish the §6.4 finding-1 family), then **4** (tie-breaker tier-1 tests, incl. the
missing/late-TXT case from the item-0 surprise). Item 1 waits on a device; item 2 stays skip-gated
while `Localizable.xcstrings` is held by another session.
