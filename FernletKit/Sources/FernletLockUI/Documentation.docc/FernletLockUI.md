# ``FernletLockUI``

The SwiftUI surface of the Fernlet app lock: passcode setup, the unlock screen, a custom PIN keypad, and the view modifier that gates sensitive screens behind the lock.

## Overview

`FernletLockUI` is the presentation layer for Fernlet's app lock — the keychain-backed
passcode/biometric lock that protects the sealed journal, cycle, and intimacy content. The
lock *service* lives in the separate `FernletLock` module (`FernletLockService`, Scrypt key
derivation, content-key wrapping, attempt counting, cooldown escalation); this module owns
everything the user actually sees and touches, so the lock feature is module-complete inside
FernletKit while the service target stays presentation-free. In the package DAG it sits at
"layer 6.5", depending on `FernletLock` (the service and its credential/error types),
`FernletUI` (the design system: `Color.parchment`/`moss`/`bark` tokens, `.fernlet` fonts,
card and label primitives), plus `FernletFoundation` and `FernletDomainModel`. That split is
deliberate: the design system remains a UI-only dependency, and `FernletLock` never imports
SwiftUI presentation code.

The module has three cooperating pieces. ``FernletLockSetupView`` is the five-step
first-time configuration wizard (lock-kind picker, entry, confirmation, optional biometric
toggle, and a mandatory no-recovery disclosure) that ends in
`FernletLockService.configure(credential:grantingScope:)`. ``FernletLockView`` is the unlock screen: it
renders the credential prompt for the configured kind, offers Face ID / Touch ID only while
the service's single policy `isBiometricUnlockAvailable` allows it — **PIN-before-biometrics:
until one passcode success (unlock or initial configure) has happened in the current app
process, a cold-launched locked app shows no biometric button and never auto-prompts**, with
the service's own fail-closed `biometricNotAvailable` guard as the backstop beneath these UI
conditions — auto-triggers the prompt at most once per lock session via the service's
`consumeAutoBiometricPromptOpportunity()` handshake, and mirrors the service's failure ladder — remaining-attempt warnings, an
escalating-cooldown countdown card, and a reset-required card whose only exit is a
destructive reset. ``FernletNumericPad`` is the shared 3×4 PIN keypad both flows (and the
app's passcode-change settings) use instead of the system keyboard. Tying them together,
`FernletLockGateModifier` — applied through the public
`fernletLockGate(scope:active:shouldLockOnDisappear:)` extension on `View` — overlays
``FernletLockView`` over gated content while the service is locked *for that gate's scope*,
offers ``FernletLockSetupView`` when no lock is configured yet, and re-locks with
`lock(reason: .viewDisappeared)` when the gated screen genuinely departs.

**Every entry point in this module names a `FernletLockScope`, and none of them defaults it.**
``FernletLockView(scope:onUnlocked:onResetRequested:)``, ``FernletLockSetupView(grantingScope:)``
and `fernletLockGate(scope:…)` each take the surface they speak for, so a newly gated screen
cannot silently inherit another screen's unlock by forgetting to identify itself. The gate's
`isLocked` therefore asks `isUnlocked(for: scope)` — never "is anything unlocked" — and its
`onAppear` calls `revokeUnlockOutside(scope)` so an *arriving* surface revokes a foreign
unlock rather than inheriting it. That appear-side revoke is the load-bearing half: the
departure-side `onDisappear` re-lock is legitimately suppressed by covering sheets, the
camera's full-screen cover and scene transitions, so a gate must not depend on the surface it
replaced having locked itself. Two gates sharing one scope (the progress-photo strip and its
pushed detail) share one unlock session; different scopes never do, which costs a fresh
authentication per hop between the Private tab, the photo strip and Settings → App lock.

The gate encodes the module's central invariant: **one unlock session never outlives the
screen it unlocked — and it covers exactly one screen while it lives.** Re-locking scrubs the
in-memory content key, so every re-entry re-prompts. The service backs that up beneath the UI:
the sealed-content key is released only to `.privateHub` (`contentKey(for:)`), and it is only
kept resident at all for that scope — a progress-photo or App-lock-settings unlock recovers the
key as the act of verifying the passcode and then drops it, so the gate's scope check is
belt-and-braces rather than the only barrier. Two lifecycle subtleties keep that invariant from misfiring. First, SwiftUI does
not fire `onDisappear` on a view covered by a `.sheet`, so child sheets can be presented
over gated content without re-locking. Second, iOS bounces the scene through
`.inactive`/`.active` while Face ID presents its system dialog, which can fire spurious
`onDisappear`/`onAppear` on page-style TabViews; the gate suppresses the disappear re-lock
during scene transitions (and for 1.5 s after returning to `.active`), deferring rather than
dropping any re-lock requested inside that window. Without this, a successful Face ID unlock
would re-lock, recreate the unlock view, and re-prompt Face ID in a loop. The
`shouldLockOnDisappear` veto additionally lets one unlock session span a push to — and pop
back from — a child screen whose still-visible parent is also gated (the progress-photo
detail returning to its timeline strip).

**The duress model, and why none of it is visible here (security-hardening Phase 7).** A Fernlet
lock may carry one optional *duress code* — a second secret, of the same kind as the real one, that
opens the app while doing something else entirely. There is exactly ONE duress code with ONE chosen
`DuressMode`: `.decoy` opens a KEYLESS session in which every sealed surface renders empty and
nothing is deleted; `.silentWipe` crypto-erases every local key first, sub-second, then re-mints a
throwaway lock under the same code so the empty app survives a re-lock; `.recoveryLock` destroys this
phone's unlock keys while KEEPING the sealed corpus and a blob only the user's own enrolled second
device can open. All three converge on the same empty view, deliberately.

That convergence is why this module has no duress-specific screens, no duress branch, and no
"duress" string anywhere: **an unlock under duress must be indistinguishable from a benign one on
screen, in the keychain, and in the audit log.** `FernletLockService.unlock(passcode:for:)` compares
the duress verifier before the real one and before the `requiresReset`/cooldown guards, then returns
the same `UnlockResult(method: .passcode)` and emits the same `lock.released` line — so
``FernletLockView`` dismisses exactly as it always does, having asked nothing extra and rendered
nothing different. The only observable difference is the *absence* of a key: `contentKey(for:)`
stays nil, which the gated screens already handle as "there is nothing sealed here". Two things this
module DOES carry: it reads the service's `isBiometricUnlockAvailable`, which ANDs
`!isDuressSessionActive`, so the Face ID button disappears for the whole duress session (the bypass
item still holds the REAL content key in the non-destructive decoy — that suppression is the door it
closes); and the flag deliberately survives `lock(reason:)`, so re-locking during a decoy does not
hand the biometric side-door back.

The decoy's second invariant belongs to the app rather than to this module, and is stated here
because a future gate could break it: **the decoy must persist nothing and delete nothing.** It rides
the existing sensitive-visibility machinery through an in-memory flag mirrored into
`FernletStore.duressSessionActive`; a gate that wrote the forced-hidden state into a *preference*
would turn a reversible decoy into silent data hiding and could reach the sealed-backup toggles that
delete the iCloud copy. Configuration lives in the app target's `DuressPINSetupView` under Settings →
App lock — a `.appLockSettings` surface the user must already have unlocked with the real passcode,
which is what makes `configureDuress(pin:mode:)` real-PIN-gated by construction rather than by a
re-prompt — and it emits no audit event at all, since an event NAME reaching the unified log would
itself disclose that a duress code exists.

Relative to the S3 privacy wall, `FernletLockUI` lives on the protected side but is not
itself sealed: it holds no persistence and no cryptography of its own. All key material,
keychain state, and attempt/cooldown bookkeeping stay inside `FernletLockService`, which
this module reaches only through SwiftUI's `@Environment`; passcode text exists here only
transiently in `@State` and is cleared after every submission. The wall's hard rule — that
`AIProviders` and `CloudKitSync` never gain an edge to the sealed `Private*` stores — is
unaffected by this module, and neither walled target depends on it. The whole module is
main-actor isolated (`defaultIsolation(MainActor.self)` in `Package.swift`), matching its
role as a pure SwiftUI surface; asynchronous unlock and configuration calls hop through
`Task { @MainActor in ... }` and back onto the service.

The unlock screen's "attempts remaining" counter reads the lockout threshold from
`FernletLockService.attemptsPerCooldownBatch` — the same constant the service enforces
internally — so a service-side policy change updates the counter automatically.

## Topics

### Gating content behind the lock

- ``SwiftUICore/View/fernletLockGate(scope:active:shouldLockOnDisappear:)``

### Setting up the lock

- ``FernletLockSetupView``

### Unlocking

- ``FernletLockView``

### Shared input components

- ``FernletNumericPad``

### Biometric display helpers

- ``biometricName(_:)``
- ``biometricSystemImage(_:)``
