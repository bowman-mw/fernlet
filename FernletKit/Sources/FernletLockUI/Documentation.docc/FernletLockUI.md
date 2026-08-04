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
`FernletLockService.configure(credential:)`. ``FernletLockView`` is the unlock screen: it
renders the credential prompt for the configured kind, auto-triggers Face ID / Touch ID at
most once per lock session via the service's `consumeAutoBiometricPromptOpportunity()`
handshake, and mirrors the service's failure ladder — remaining-attempt warnings, an
escalating-cooldown countdown card, and a reset-required card whose only exit is a
destructive reset. ``FernletNumericPad`` is the shared 3×4 PIN keypad both flows (and the
app's passcode-change settings) use instead of the system keyboard. Tying them together,
``FernletLockGateModifier`` — applied through the public `fernletLockGate(active:shouldLockOnDisappear:)`
extension on `View` — overlays ``FernletLockView`` over gated content while the service is
locked, offers ``FernletLockSetupView`` when no lock is configured yet, and re-locks with
`lock(reason: .viewDisappeared)` when the gated screen genuinely departs.

The gate encodes the module's central invariant: **one unlock session never outlives the
screen it unlocked.** Re-locking scrubs the in-memory content key, so every re-entry
re-prompts. Two lifecycle subtleties keep that invariant from misfiring. First, SwiftUI does
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

One UI-side coupling is worth knowing before editing: the unlock screen's
"attempts remaining" counter hardcodes the same 4-attempt lockout threshold that
`FernletLockService` enforces internally. If the service's threshold ever changes, the
counter here must change with it.

## Topics

### Gating content behind the lock

- ``FernletLockGateModifier``

### Setting up the lock

- ``FernletLockSetupView``

### Unlocking

- ``FernletLockView``

### Shared input components

- ``FernletNumericPad``

### Biometric display helpers

- ``biometricName(_:)``
- ``biometricSystemImage(_:)``
