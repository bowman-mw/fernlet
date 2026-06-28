# Handoff prompt — WI-6 + WI-9 (fresh session)

> Paste the block below into a fresh session to finish the two deferred S3-wall hardening items.
> It is re-runnable: once WI-6 is committed, re-pasting it in another session sees WI-6 done (via the
> plan's §1a status table) and skips to WI-9. See `Docs/Security-Hardening-Plan-2026-06-27.md` §1a.

---

Continue the Fernlet "S3 privacy wall" security-hardening work. Two architectural follow-ups
remain: WI-6 and WI-9. They were deliberately deferred from the previous pass because each is a
larger, risk-bearing change that must be done carefully — NOT casually.

BRANCH: Work directly on the existing branch `claude/adoring-hoover-3c0a22` (it already holds
WI-1..WI-5, WI-7a, WI-8, WI-10, and the safe WI-Q items). Do NOT create a new branch or worktree —
stay on this branch and commit here. NOTE: this branch is checked out in a git worktree at
`.claude/worktrees/adoring-hoover-3c0a22/` — run all commands and edits from there, not the main
checkout (the main checkout is on `main` and cannot check this branch out concurrently).

START BY READING: `Docs/Security-Hardening-Plan-2026-06-27.md`. It is self-contained — §0 has the S3
wall context + build/test commands, §1a is the implementation status table (confirm WI-6 and WI-9 are
still the only "Deferred" items), and the WI-6 and WI-9 sections have the exact file:line references,
recommended fixes, and compatibility constraints. Also read `CLAUDE.md` (S3 wall enforcement + the
pre-merge ritual) and the memory `s3-wall-security-review-2026-06-27`.

DO WI-6 FIRST, THEN THE CONTEXT CHECKPOINT, THEN (maybe) WI-9 — see ordering note below.

────────────────────────────────────────────────────────────────────────
WI-6 — Replace the cross-platform canonical signing encoder  [P2/MED, roadmap]
────────────────────────────────────────────────────────────────────────
Problem: `FernletKit/Sources/ProximityKit/Wire/FernletIdentityEnvelope.swift` →
`makeCanonicalSignatureEncoder()` (around line 62) returns a Foundation `JSONEncoder` configured with
`.sortedKeys`, `.withoutEscapingSlashes`, and `.iso8601` dates. `.sortedKeys` is stable WITHIN one
Foundation version, but Apple sorts by UTF-16 code units and does not guarantee byte-identical
number/string/date encoding across Foundation implementations — so a peer on a different Foundation
version, or the planned Android (Kotlin) port, could produce different canonical bytes and reject a
legitimately-signed envelope/admission token (`signatureInvalid`). It is used by BOTH
`FernletIdentityEnvelope` (around line 74) AND `MeshAdmissionToken` (`MeshPayloads.swift`, around line
299). This is NOT a carve-up regression (preserved as-is); it is a known load-bearing fix that must
precede any cross-stack signatures (see memory `cross-platform-direction-2026-06`).

Recommended fix (do deliberately):
- Replace the Foundation JSONEncoder with a deterministic canonical serializer you fully control on
  both stacks: explicit field ordering, fixed numeric formatting (no locale/precision drift), explicit
  string escaping, and an explicit date format. The output must be byte-reproducible from a plain
  field list so a Kotlin implementation can match it exactly.
- COMPATIBILITY IS LOAD-BEARING: changing the encoder changes the signed bytes, so existing
  Apple-to-Apple signatures would break. Gate the change behind the envelope `schemaVersion` (envelopes
  already carry `schemaVersion`): during a transition, VERIFY against BOTH the old (legacy JSONEncoder)
  and new canonical encoders, and only SIGN with the new one for the bumped schemaVersion. Confirm
  `MeshAdmissionToken` carries/honors the same version gate. There are no live cross-platform peers
  today, so this is not urgent — but get the dual-verify transition right so no in-field Apple peer is
  cut off.
- Add regression tests: (a) the new canonical serializer is deterministic and byte-stable for a fixed
  input (golden-bytes test); (b) sign-with-new / verify-with-new round-trips; (c) the dual-verify
  transition accepts BOTH a legacy-signed and a new-signed envelope/token; (d) a tampered byte fails
  verification. Put them alongside the existing mesh/identity signing tests (look for the suites that
  already exercise `FernletIdentityEnvelope` / `MeshAdmissionToken` signing — e.g. `MeshEncryptionTests`
  and any identity-envelope test).

────────────────────────────────────────────────────────────────────────
WI-9 — ProximityKit MainActor isolation forces off-main decode under `.v5`  [P2/LOW]
────────────────────────────────────────────────────────────────────────
Problem: `FernletKit/Package.swift` (around line 299) sets `.defaultIsolation(MainActor.self)` for the
`ProximityKit` target, which makes the moved mesh `Codable` conformances and the `sign`/`verify` free
functions `MainActor`-isolated; this only compiles because of the `.swiftLanguageMode(.v5)` escape
hatch on that target. Off-main decode of incoming `MCSession` data (untrusted bytes) compiles with a
warning today; a Swift 6 / strict-concurrency migration would fail. This is a concurrency-correctness
cleanup, NOT a live hole — scope it deliberately.

Recommended fix (incremental):
- Mark the wire `Codable` conformances and the `sign` / `verify` / `makeCanonicalSignatureEncoder`
  free functions `nonisolated`, working toward dropping the `.v5` language-mode escape hatch for the
  `ProximityKit` target. Do it incrementally; do NOT force-drop `.v5` if it surfaces a cascade of
  unrelated strict-concurrency errors — land the `nonisolated` annotations first and leave a clear note
  on what still blocks `.v5` removal.
- These types/functions handle untrusted bytes off the main actor; verify there is no shared-mutable-
  state data race introduced (the signing/verify path should be pure over its inputs).

ORDERING NOTE (WI-6 → WI-9 overlap): both touch `makeCanonicalSignatureEncoder`. WI-6 REPLACES that
function; WI-9 wants it (and the new serializer + the wire Codable conformances) `nonisolated`. So do
WI-6 first; when you reach WI-9, mark the NEW canonical serializer `nonisolated` as part of the same
cleanup.

────────────────────────────────────────────────────────────────────────
PER WORK ITEM
────────────────────────────────────────────────────────────────────────
Implement the recommended fix, add the regression tests named above, and commit on this branch with a
message referencing the WI id. End commit messages with:
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>

VERIFY after each item (iOS 26 / Xcode 26.5; simulator name `iPhone 17`; from the worktree dir):
  - FERNLET_DESTINATION='platform=iOS Simulator,name=iPhone 17' Scripts/spm-wall-check.sh   # expect exit 0
  - Scripts/spm-wall-selftest.sh   # proves the wall still rejects a forbidden import (exit 65 then clean pass)
  - xcodebuild test-without-building -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FernletTests/<Suite>
  (batch test runs; the lock suite is slow. Check the "TEST EXECUTE SUCCEEDED" banner + exit code, not naïve grep.)
After finishing, update the §1a status table in Docs/Security-Hardening-Plan-2026-06-27.md and the
memory `s3-wall-security-review-2026-06-27` to mark WI-6 / WI-9 done.

────────────────────────────────────────────────────────────────────────
CONTEXT CHECKPOINT (REQUIRED) — between WI-6 and WI-9
────────────────────────────────────────────────────────────────────────
As soon as WI-6 is implemented, verified, AND committed, STOP and check how much context this session
has consumed. Claude Code tracks the running token usage for the session — gauge it from your
context-window budget (and the user can confirm with the `/context` command). Then:

  • If MORE THAN 200,000 tokens have been used by the time WI-6 is committed:
      DO NOT start WI-9. Stop and tell the user, verbatim:
      "WI-6 is committed. This session has used more than 200k tokens — please start a NEW session to
       do WI-9 (re-use this same prompt; it will see WI-6 already done and skip to WI-9)."
      Then end your turn. Do not begin WI-9.

  • If 200,000 tokens or fewer have been used:
      Report the approximate usage, then proceed to WI-9 in this same session.

(If you cannot determine the exact token count, err on the side of stopping: if WI-6 took substantial
back-and-forth or the context indicator looks more than ~60–70% full, treat it as over budget and ask
the user to start a fresh session for WI-9.)
