# The Power of 10, for Fernlet's Swift

Fernlet's shipping code is held to Gerard Holzmann's **Power of 10** rules (NASA/JPL, 2006) —
adapted from safety-critical C to Swift/SwiftUI. This document is the standard: what each rule
means here, what is enforced by machine, what is enforced by review, and how exemptions work.

The rules exist because this app holds sealed health data. Code that traps, loops without a bound,
grows without a cap, or swallows errors silently is code whose failure the user cannot see and we
cannot reason about. Every rule below is a way of making failure **explicit, bounded, and local**.

Two enforcement layers, mirroring the S3 and no-tracking walls:

- **Mechanical** — `Scripts/power-of-10-scan.py` (the canonical checker; zero-violation baseline,
  exits 1) and `Tests/FernletTests/PowerOfTenBoundaryTests.swift` (the same checks as a grep-wall
  test, so a regression fails the normal test run). Both read the single allowlist
  `Scripts/power-of-10-allowlist.json`. CI runs the scanner on every push
  (`.github/workflows/power-of-10.yml`); the pre-push hook runs it locally.
- **Review** — the rules a tokenizer cannot decide (indirect recursion, loop bounds, input-driven
  growth, parameter validation, side-effect-free assertions). Every code review checks the review
  column of the table below; the audit that established this baseline is
  `Docs/CODE_REVIEW_Power-of-10-2026-08-16.md`.

Scope: the four shipping roots — `FernletKit/Sources`, `App/Fernlet`, `App/FernletWidgets`,
`App/FernletShareExtension`. Test code is exempt from R4/R5/R7 (tests trap on purpose) but not
from R10 (zero warnings everywhere).

| # | NASA rule (C) | Fernlet rule (Swift) | Enforced by |
|---|---|---|---|
| 1 | Simple control flow: no `goto`, `setjmp`, recursion | **No recursion**, direct or indirect. Use an explicit worklist with a bounded iteration count. | scanner (direct, advisory) + review (indirect) |
| 2 | Every loop has a fixed upper bound | Every `while`/`repeat` is governed by a counter with a named maximum or by an iterator over finite data. **No `while true`.** `for await` only over sequences that end on cancellation. | scanner (`while true`) + review (bounds) |
| 3 | No dynamic allocation after init | **Bounded growth**: every collection fed by external input (peers, network, HealthKit, files, repeated user actions) has an explicit cap enforced where the input enters; caches are bounded; task fan-out is bounded. | review |
| 4 | ≤ 60 lines per function | **≤ 60 code lines** per `func`/`init`/`subscript`/computed property/`body`/closure-initialiser (blank and comment-only lines excluded). SwiftUI bodies decompose into named subviews. | scanner |
| 5 | ≥ 2 assertions per function; side-effect free; failure ⇒ recovery | `guard`+recovery is the assertion. Validate inputs at entry; assert invariants; **no silent traps** (`!`, `try!`, `as!`, IUO, `fatalError`) in shipping code. Density floor is a ratchet. | scanner (traps, density) + review (validation, side effects) |
| 6 | Smallest possible scope | No file-scope `var`; no stored `static var` outside the allowlist; `let` by default; `private` by default; declare at first use. | scanner (globals) + review |
| 7 | Check every return value; validate every parameter | **No swallowed `try?`** — every error feeds a decision or is caught and named. `@discardableResult` never on a success/failure value. `_ =` never discards a Bool/Result/Optional-error. Parameters validated with `guard` at entry. | scanner (`try?`) + review |
| 8 | Preprocessor: includes + simple macros only | `#if` only for `DEBUG`, `canImport`, `os`, `targetEnvironment`, `swift`/`compiler`, `arch`; **never nested**; no custom compilation conditions; Apple macros only. | scanner |
| 9 | ≤ 1 level of pointer dereference; no function pointers | No `Unsafe*`, `withUnsafe*`, `unsafeBitCast`, `Unmanaged`, `unowned(unsafe)`, `nonisolated(unsafe)` outside allowlisted seams; each seam names its safety invariant. Keep optional chains shallow. | scanner + allowlist |
| 10 | All warnings on, zero warnings, daily static analysis | **Warnings are errors** on every target (`SWIFT_TREAT_WARNINGS_AS_ERRORS` + `GCC_TREAT_WARNINGS_AS_ERRORS` in the pbxproj; for the package, `SUPPRESS_WARNINGS=NO` + the same two flags on the strict build command — never `.treatAllWarnings` in `Package.swift`, which collides with Xcode's `-suppress-warnings`); Swift 6 language mode in the package, approachable concurrency in the app; the scanner + the three grep-walls run in CI on every push. | build settings + CI |

---

## R1 — Simple control flow: no recursion

Swift has no `goto` or `longjmp`; the rule that survives is **no recursion**. A recursive function's
stack depth is a function of its input, so its memory use is unbounded (R3) and its termination is
not statically evident (R2). Rewrite as a loop over an explicit worklist:

```swift
// ✗ recursion — depth follows the data
func flatten(_ node: Node) -> [Leaf] { node.children.flatMap(flatten) + node.leaves }

// ✓ worklist with a bound
func flatten(_ root: Node) -> [Leaf] {
    var work = [root], out: [Leaf] = []
    var budget = Node.maxNodes                       // R2/R3: named bound
    while let node = work.popLast(), budget > 0 {
        budget -= 1
        out += node.leaves
        work += node.children
    }
    return out
}
```

Mutual (indirect) recursion — A calls B calls A — is the same violation and is only found by
reading; reviewers walk the call chain of anything that dispatches back into its caller
(delegates, `Task { self.retry() }`, timer callbacks that reschedule themselves are all fine because
the *stack* unwinds between calls; the rule is about the stack, not the call graph).

**Scanner:** `R1-RECURSION` (advisory) flags a function whose body calls its own name. Overload
delegation (`log(x)` → `log(x, level:)`) trips it; the reviewer confirms and the audit records it.
Any real recursion that must stay (a bounded, finite structure with an explicit `depth < max`
guard) is allowlisted with the bound stated in the reason.

## R2 — Every loop has a fixed upper bound

A loop's bound must be visible at the loop: `for` over a finite collection or range; `while` with a
counter compared to a **named** maximum (`attempt < Self.maxAttempts`); `while let` over an iterator
of finite data (`popLast()`, `iterator.next()`, `readLine()`); `repeat` only with the same discipline.

- **`while true` is banned.** A loop that "breaks when done" hides its bound; hoist it into the
  condition. The scanner rejects `while true` and `repeat … while true`.
- **Retry loops** name their attempt cap and their back-off cap.
- **`for await`** over an `AsyncSequence` is an event loop; it is bounded by the task's lifetime and
  is allowed only when the sequence finishes on cancellation and the owning `Task` is cancelled on
  `deinit`/`onDisappear`. A body that does more than forward one event checks `Task.isCancelled`.
- **Timers / `Task.sleep` loops** that reschedule themselves are the same event-loop shape and
  follow the same rules.

**Scanner:** `R2-WHILE-TRUE` (enforced, zero) and `R2-WHILE` (advisory list of every `while` for the
reviewer). The audit records the bound of every `while` in shipping code.

## R3 — Bounded growth (the Swift form of "no dynamic allocation")

Swift allocates on every `append`; the rule cannot be "no allocation". Its *purpose* — memory use
that is bounded and independent of input — survives as **bounded growth**:

- Any collection that grows from **external input** (mesh/peer frames, network responses, HealthKit
  samples, files, clipboard, repeated user actions in a loop) has an **explicit cap** enforced where
  the input enters (`prefix(max)`, drop, or evict), and the cap is a named constant.
- **Caches** are bounded (count or byte budget, oldest-out). No append-only in-memory logs.
- **Task fan-out** is bounded: at most one in-flight task per key (dedupe by identity), never one
  task per incoming event without a limit.
- Buffers for framing/parsing declare a maximum frame size and reject oversize input up front
  (`SealedPayloadFraming` is the model).
- No recursion (R1) + bounded loops (R2) ⇒ stack use is bounded by construction.

**Enforced by review.** The audit lists every input-driven collection in shipping code with its cap
(or the finding that it has none).

## R4 — At most 60 code lines per function

Counted the SwiftLint way: lines inside the braces that are not blank and not comment-only.
Applies to `func`, `init`/`deinit`, `subscript`, computed properties (including SwiftUI `body`),
and closure initialisers (`let table: [X] = { … }()`).

Why 60 for SwiftUI too: a 200-line `body` is a 200-line function with the same review problem —
you cannot hold it in your head, and a `@State` mutation on line 140 is invisible from line 20.
Decompose into **named** subviews (a `private struct` per logical region) or `@ViewBuilder`
computed properties; keep `@State` in the owner and pass bindings down. Long `init`s that decode
many fields split by field group; long `switch` dispatchers split per case family.

**Scanner:** `R4-LENGTH` (enforced, zero). No allowlist entry is expected; if one is ever needed
the reason must say why the body cannot be split (data-table-shaped code belongs in a `static let`,
not a function).

## R5 — Assertions: validate, assert, never trap silently

NASA's rule wants two assertions per function, side-effect free, and an explicit recovery when one
fails. In Swift that decomposes into three obligations:

1. **Validate at entry, recover explicitly.** `guard <condition> else { return / throw / continue }`
   is the assertion form that carries its own recovery. Every function that takes untrusted or
   external data — decoders, peer/network payloads, HealthKit results, file contents, user text —
   validates it before use. Every non-trivial function states its preconditions as `guard`s.
2. **Assert invariants without side effects.** `assert(...)` / `assertionFailure(...)` for
   programmer-error invariants that must hold. The expression inside `assert` never calls anything
   that mutates state or performs I/O (it is compiled out in Release). `precondition` — a trap —
   only where continuing would corrupt sealed data or breach the S3 wall, and each such site is
   documented at the call.
3. **No silent traps.** Force unwrap `!`, `try!`, `as!`, and implicitly-unwrapped `T!` declarations
   are assertions with no message and no recovery: **banned in shipping code**. `fatalError` /
   `preconditionFailure` likewise, except the unreachable `required init?(coder:)` that UIKit
   subclassing forces, which is allowlisted per site.

Compile-time literals (`UUID(uuidString: "…")!`, `URL(string: "https://…")!`) are the one class of
force unwrap that cannot fail after the first test run. Prefer a non-optional construction where the
type offers one; otherwise the site may be allowlisted with `line_contains` naming the literal, and
a unit test must evaluate the expression so the "cannot fail" claim is checked on every run.

**Density.** The scanner computes `(guard + assert + precondition) / logic functions` — `func`,
`init`, `deinit` and `subscript` bodies with ≥ 3 code lines; computed properties (SwiftUI `body`
and view fragments, which have nothing to guard) and closure initialisers are excluded — over the
shipping roots and enforces a floor (`DENSITY_FLOOR` in the scanner). It is a **ratchet**: raise it
when the codebase improves, never lower it. It is a proxy — a `guard`-free 3-line getter is fine —
so the review column carries the real weight: does every boundary function validate its inputs?

**Scanner:** `R5-FORCE`, `R5-TRAP` (enforced, zero + allowlist), `R5-DENSITY` (floor).

## R6 — Smallest possible scope

- **No file-scope `var`.** A mutable global is state every function can corrupt.
- **No stored `static var`** outside the allowlist. A mutable static is a global in a namespace.
  The allowlisted ones are the deliberate process-global registries (test capture handlers, the
  once-per-launch schema deploy latch); each entry names its concurrency story — an actor, a lock,
  or a documented single-thread invariant. `nonisolated(unsafe)` on a static is *also* an R9 hit.
- `let` by default; a `var` that is never mutated is a compiler warning and therefore (R10) an error.
- `private` by default; widen only for a named consumer. Types are `final` unless subclassed.
- Declare at first use, in the narrowest block; no "declare everything at the top".

**Scanner:** `R6-FILE-VAR`, `R6-STATIC-VAR` (enforced, zero + allowlist).

## R7 — Check every return value; validate every parameter

- **No swallowed `try?`.** A bare `try? f()` (or `_ = try? f()`) discards both the result and the
  error: the failure is invisible. Every `try?` must feed a decision (`guard let` / `if let` /
  `?? fallback` where the fallback is meaningful), or become `do { try f() } catch { … }` where
  the `catch` names the recovery — at minimum an audit-log line and the reason the failure is
  benign. Best-effort cleanup (`removeItem` on a temp file) still logs.
- **`@discardableResult`** is a promise that ignoring the result is safe. It is never placed on a
  function whose result is a success/failure signal (`Bool`, `Result`, an optional error, a count
  the caller must act on). Builders and fluent APIs may use it; the doc comment says why.
- **`_ =` discards** only values that carry no failure information (`Task {}` handles,
  `withAnimation` results, `insert`'s tuple when the caller knows the element is new).
- **Parameter validation** is R5(1): every `public`/`package` entry point and every boundary
  function checks its arguments with `guard` before use.

**Scanner:** `R7-SWALLOW` (enforced, zero); `R7-DISCARD` (advisory: every `_ =` and every
`@discardableResult`, for review).

## R8 — Preprocessor discipline

Swift's `#if` is the only preprocessor. Allowed conditions: `DEBUG`, `canImport(...)`, `os(...)`,
`targetEnvironment(...)`, `swift(...)`/`compiler(...)`, `arch(...)`, optionally negated or combined.
No custom compilation conditions (feature flags are runtime values), and **no nesting** — a nested
`#if` produces 2ⁿ build variants that are never all compiled. Macros: Apple's only (`#Preview`,
`#expect`, `@Observable`, …); a macro package is also a new SPM dependency, which the no-tracking
wall forbids without allowlisting.

**Scanner:** `R8-IF-COND`, `R8-IF-NEST` (enforced, zero).

## R9 — Unsafe pointers only at named seams

Swift has references, not pointers; what survives is the *unsafe* surface: `Unsafe*Pointer`,
`withUnsafe*`, `unsafeBitCast`, `Unmanaged`, `unowned(unsafe)`, `unsafelyUnwrapped`, and
`nonisolated(unsafe)` (unsafe in the concurrency dimension). All are banned outside allowlisted
seams. An allowlist entry is per **file** and its reason names the seam (CommonCrypto / Security
framework / Core Data / BLE bridging / a documented single-writer static) and the invariant that
keeps it safe. Prefer `Data`, `ContiguousBytes`, `withContiguousStorageIfAvailable`; prefer real
actor isolation over `nonisolated(unsafe)`.

The dereference-depth half of the rule becomes: keep optional chains shallow (`a?.b?.c?.d` is a
sign the type model is wrong), and closures stored in tables keyed by strings are dispatch you
cannot statically follow — prefer an `enum` switch.

**Scanner:** `R9-UNSAFE` (enforced, zero + allowlist).

## R10 — Warnings are errors; the analyzers run every day

- `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` and `GCC_TREAT_WARNINGS_AS_ERRORS = YES` at the PROJECT
  level of `App/Fernlet.xcodeproj` (the Debug and Release blocks every target inherits — app, both
  extensions, both test targets), never overridden back to `NO` on any target.
- The FernletKit package targets get the same treatment from the BUILD COMMAND, not the manifest:
  Xcode passes `-suppress-warnings` to every local-package target (so an ordinary build hides
  package warnings outright), and `.treatAllWarnings(as: .error)` in `Package.swift` collides with
  that flag ("conflicting options -warnings-as-errors and -suppress-warnings" — verified, it breaks
  the Xcode build). So `Scripts/spm-wall-check.sh` — the one strict build CI runs, via
  `spm-wall-selftest.sh` and the pre-push hook — passes `SUPPRESS_WARNINGS=NO
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES` on the `xcodebuild`
  command, which does reach the synthesized package targets. Locally, the same three overrides on
  any `xcodebuild build-for-testing`, or `swift build … -Xswiftc -warnings-as-errors` inside
  `FernletKit/`, reproduce the strict build.
- The package builds in Swift 6 language mode; the app targets use approachable concurrency with
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (the "most pedantic setting" available while the app
  stays in Swift 5 mode; moving the app to Swift 6 mode is tracked in RemainingWork).
- "At least one static analyzer, daily" = the Power-of-10 scanner + the S3 grep-wall + the
  no-tracking wall + the doc-coverage scan, all in CI on every push, plus the pre-push hook. (There
  is no C/Objective-C in the tree, so the Clang static analyzer has nothing to analyze.)

`PowerOfTenBoundaryTests` also pins the build settings above by reading the pbxproj and
`Scripts/spm-wall-check.sh`, so removing a flag fails the test run.

---

## Exemptions: the allowlist

`Scripts/power-of-10-allowlist.json` is a JSON array; every entry has `rule`, `path`
(repo-relative), `reason`, and optionally `symbol` (function name) or `line_contains` (a substring
of the offending code line). An entry with neither narrows to the whole file — used only for
`R9-UNSAFE` seams. Rules for entries:

- The reason states the **invariant** that makes the exemption safe, not the inconvenience.
- Entries that match nothing fail the scan (`UNUSED ALLOWLIST ENTRY`), so the list cannot rot.
- Adding an entry is a reviewed change, in the same commit as the code it excuses.

## Running the checks

```bash
Scripts/power-of-10-scan.py               # violations by rule; exit 1 on any
Scripts/power-of-10-scan.py --advisory    # + the review lists (every while, _ =, @discardableResult, static var, recursion guesses)
Scripts/power-of-10-scan.py --json        # machine-readable
xcodebuild test-without-building -project App/Fernlet.xcodeproj -scheme Fernlet \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FernletTests/PowerOfTenBoundaryTests
```

## Review checklist (the non-mechanical half)

For every changed function, the reviewer answers:

1. Does it recurse, directly or through a callback chain? (R1)
2. Does every `while`/`repeat`/`for await` have a bound I can point at? (R2)
3. Does any collection grow from input without a cap? Is every cache bounded? (R3)
4. Does it validate its parameters at entry, and are its `assert`s side-effect free? (R5, R7)
5. Is every `try?` feeding a decision? Is every discarded result failure-free? (R7)
6. Is anything declared wider or earlier than it needs to be? (R6)
7. Would the change add a build warning anywhere, including tests? (R10)
