# Mesh Migration Loop Ledger — P2

The loop's durable memory. `/loop` resumes the same context and never compacts, so this file — not
the orchestrator's head — is where state lives. **Keep it short:** it is read on every wake, so every
line costs orchestrator budget forever. Prune the surprises list when an entry stops earning its
place.

**Phase:** P2 (NetworkMeshSession) · **Prompt:** [Next-Round-Prompt-Mesh-P2-2026-08-31.md](Next-Round-Prompt-Mesh-P2-2026-08-31.md)
**Started:** not yet · **Iteration:** 0 · **Tree at seed:** main = `16b9cb2` (pushed)

## Items

States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`.
Tier per prompt §2 — 1 = no radio, 2 = device↔Simulator, 3 = two physical devices.

| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 0 | Sim↔sim experiment (prompt §2). Timeboxed to ONE iteration, DEBUG toggle only. | 2 | — | todo | | High payoff: unlocks multi-node on one Mac |
| 1 | Capture Lane A diagnostic report; promote runbook rows *Observed working* → *Pass* | 2 | 1 device | todo | | Owner reports it connects; no report captured |
| 2 | String-catalog repair (9 stale keys, pre-existing) | 1 | quiet tree | todo | | SKIP if `Localizable.xcstrings` still held by another session |
| 3 | §6.5 root fix: stable `id` per session + close §6.4 asymmetries 1–3 | 1 | — | todo | | Behaviour change — own it with tests |
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

- (nothing yet)

## Known-red gates that are NOT this phase's fault

- `sync-string-catalogs.sh --check` — nine stale keys, present in the file as committed at `f4fa541`.
  Item 2 fixes it if the tree is quiet. Do not bisect it.

## Next item

**0** — the sim↔sim experiment. Cheap, timeboxed, and its result re-tiers P3–P6.
