# Enhanced Security (Xcode capability)

Adopted 2026-10-17 (owner decision), first stage: **memory tagging in soft mode**.

## What it is, and what it is not

Enhanced Security is Xcode 26's process-hardening capability. It makes a memory-corruption bug much
harder to turn into control of the running app: pointer authentication (`arm64e`), a hardened heap,
read-only dyld/platform state, extra platform restrictions on loaded code and Mach messages, and
**hardware memory tagging** (Apple's Memory Integrity Enforcement), which stops a use-after-free or an
out-of-bounds access at the moment it happens.

It protects the *process*, not the *data*. Nothing here encrypts anything; data at rest is still
the job of the sealed stores, the Secure-Enclave-bound content key and `NSFileProtectionComplete`
(see `FernletLock`'s landing page). Its reason to exist in Fernlet is the untrusted input the app
parses: recipe shares and friend photos from the proximity mesh, pages fetched by the share
extension, payloads arriving in the Messages extension. Those are exactly the inputs a memory bug
would be reached through.

Fernlet is a cheap adopter: it is Swift with no C/C++ sources, no binary frameworks and only two
source packages (CryptoSwift, proximitykit), and the no-tracking wall means there is no third-party
crash reporter (the class of SDK that `platform-restrictions` is known to break).

## What is enabled

- **Build setting** `ENABLE_ENHANCED_SECURITY = YES` at the **project** level (Debug and Release),
  so every target inherits it, the hosted test bundles included. On the device SDK it adds an `arm64e`
  slice (`ARCHS = arm64 arm64e`) and turns on `ENABLE_POINTER_AUTHENTICATION` and
  `ENABLE_SECURITY_COMPILER_WARNINGS` (verified with `xcodebuild -showBuildSettings`, Xcode 26.5).
  Simulator builds stay `arm64`; the simulator cannot exercise pointer authentication.
- **Workspace setting** `iOSPackagesShouldBuildARM64e = YES` in `xcshareddata/WorkspaceSettings.xcsettings`
  of both workspaces the project is opened through (`App/Fernlet.xcodeproj/project.xcworkspace` and
  the root `Fernlet.xcworkspace`). A project-level build setting never reaches Swift package targets:
  without this, every FernletKit module, CryptoSwift and ProximityKit built `arm64` only and the device
  build failed at the first `arm64e` import ("Unable to resolve module dependency: 'FernletExchange'",
  2026-10-17). This is Apple's documented switch (BrowserEngineKit, *Creating browser extensions in
  Xcode* → "Build for pointer authentication"); the macOS equivalent is reported not to work, which
  does not matter here.
- **Entitlements**, identical in all four process targets — `App/Fernlet`, `FernletShareExtension`,
  `FernletMessagesExtension`, `FernletWidgets` — and exactly the set Xcode 26.5's own "Enhanced
  Security Extension" template writes:

  | Key | Value |
  | --- | --- |
  | `com.apple.security.hardened-process` | `true` |
  | `com.apple.security.hardened-process.enhanced-security-version-string` | `"1"` |
  | `com.apple.security.hardened-process.platform-restrictions-string` | `"2"` |
  | `com.apple.security.hardened-process.hardened-heap` | `true` |
  | `com.apple.security.hardened-process.dyld-ro` | `true` |
  | `com.apple.security.hardened-process.checked-allocations` | `true` (memory tagging) |
  | `com.apple.security.hardened-process.checked-allocations.soft-mode` | `true` (stage 1 only) |

`Tests/FernletTests/EnhancedSecurityConfigurationTests` holds this shape: every app/extension target
has an entitlements file carrying the keys, the two `-string` keys are Strings, the retired integer
keys are absent, all targets share one tagging mode, the setting lives at the project level with
no target overriding it or `ARCHS`, and both workspaces build packages for `arm64e`. CI builds only
for the simulator, so the suite is what catches a device-only break before an archive does.

## Rollout

1. **Soft mode (now).** A tag mismatch writes a *simulated* crash report ("SIMULATED (this is NOT a
   crash)", `EXC_GUARD` / `GUARD_EXC_MTE_SYNC_FAULT`) instead of terminating. Tagging only runs on
   hardware that has it: iPhone/iPad with **A19 or later**, Mac/Vision Pro with **M5 or later**. On
   older devices the tagging entitlement has no effect; the other protections still apply.
2. **Simulator on an M5 Mac — tagging is live, in HARD mode.** Xcode signs simulator builds with
   only `hardened-process` and `checked-allocations` (no `soft-mode`), and the iOS 26.5 Simulator on
   an M5 host enforces it: a deliberate use-after-free on a Swift object in a scratch test was killed
   with `EXC_BAD_ACCESS (EXC_ARM_MTE_TAGCHECK_FAIL)`, termination namespace `MTE_FAIL` (2026-10-17).
   A use-after-free on a plain `UInt64` buffer was NOT caught — pure-data allocations are untagged
   without `…checked-allocations.enable-pure-data`, on device too. So every local simulator test run
   on an M5 Mac is a hard-mode tagging run: the full `FernletTests` line (6,658 tests) ran under it
   with no tag fault on 2026-10-17 (its one failure was an unrelated string-catalog check). A latent
   bug shows up as the test host crashing; simulator crash reports do not land in
   `~/Library/Logs/DiagnosticReports` — get them from the result bundle with
   `xcrun xcresulttool export diagnostics`. Do not count on CI for this: tagging needs an M5-or-later
   host, and the hosted runners are not assumed to be one. Pointer authentication is device-only
   everywhere.
3. **Device testing.** On an A19 iPhone, Scheme → Run → Diagnostics → **Hardware Memory Tagging**,
   then exercise the mesh flows (recipe share, friend photos, disposable camera), the share
   extension, the Messages extension, widgets, and the Private tab. Address Sanitizer cannot be on at
   the same time. Simulated reports are under Window → Devices and Simulators → Open Recent Logs.
4. **TestFlight in soft mode** for a period, reading the same reports.
5. **Turn soft mode off for release:** remove the `…checked-allocations.soft-mode` key from all four
   entitlements files in one commit (Signing & Capabilities → Memory Safety → uncheck "Enable Soft
   Mode for Memory Tagging" does the same per target). The configuration suite requires all four to
   agree.

## Known issues

- **App Store validation false rejection.** The validator has twice rejected the
  `-string` keys demanding Boolean `true` (October 2025, April 2026); Apple DTS confirmed on the
  Developer Forums that the String values are correct. **Never change them to `true`** — that stops
  the app launching. Reply to App Review citing the DTS answer instead.
- **Inconsistent `arm64e`.** Everything linked into one process must carry the slice; that is why the
  setting is project-level and the packages follow the workspace setting. A binary framework added
  later would need an `arm64e` slice of its own.
- **Apple silicon Macs need macOS 26.5 (validation warning, 2026-10-17).** App Store Connect offers an
  iPhone app on Apple silicon Macs by default, and Fernlet is iPhone-only (`TARGETED_DEVICE_FAMILY = 1`)
  with an implied macOS minimum of 26.0. A bundle carrying the `arm64e` slice launches on a Mac only from
  macOS 26.5, so validation warns "Macs with Apple silicon support issue".
  - **Resolution (owner, 2026-10-17):** Mac availability is turned OFF in App Store Connect (Pricing and
    Availability → iPhone and iPad Apps on Apple Silicon Macs). On a Mac, Fernlet's core features are
    absent anyway: no Apple Health data, no UWB ranging, no in-person mesh. No build setting changed.
  - **If Mac availability is ever turned back on:** set the minimum macOS version to 26.5 on that App
    Store Connect page, or add `INFOPLIST_KEY_LSMinimumSystemVersion = 26.5` to the Fernlet target, which
    iOS ignores, with a cell in `EnhancedSecurityConfigurationTests` to hold it. Otherwise a Mac on
    26.0–26.4 would offer the app and then fail to launch it.
- **The app's `arm64e` slice had no class_ro_t pointer signing (found 2026-10-17, fixed 2026-10-25).**
  Every iOS archive printed 29 linker warnings: "'<Module>.o' was built with class_ro_t pointer signing
  enabled, but previous .o file was not", once per FernletKit module, plus the reverse for `CryptoSwift.o`.
  - **Cause.** For `arm64e`, swiftc signs the Objective-C `class_ro_t` pointer in each class's metadata
    only when the deployment target is iOS 16 or later. That is bit `0x10` of `__objc_imageinfo`, and it
    can also be forced with `-Xfrontend -sign-class-ro`. Xcode builds a remote package at the floor its
    own `Package.swift` declares, not at the app's floor. Upstream CryptoSwift 1.10.0, the newest
    release, declares `.iOS(.v11)` (Xcode lifts it to 12.0), so its objects were unsigned. Every
    FernletKit module and ProximityKit declare `.iOS(.v26)`, so theirs are signed. When the signed and
    unsigned objects meet, `ld` keeps the image consistent by clearing the flag for the whole image. A
    two-object link reproduces both the warning and the cleared bit.
  - **Effect, measured on a local Xcode 26.5 archive before the fix.** `Fernlet.app/Fernlet`'s `arm64e`
    slice had imageinfo flags `0x06030740`: the bit clear. The three extensions, which do not link
    CryptoSwift, had `0x06030750`: the bit set. So the main app ran without this one hardening. Pointer
    authentication of code pointers, the hardened heap, memory tagging and the rest were unaffected.
  - **Why the fix is a fork, not a setting.** No client-side setting reaches Xcode's own Build or
    Archive. Xcode 26.5 reads no workspace or project key for a package's floor: the only package key in
    `WorkspaceSettings.xcsettings` is `iOSPackagesShouldBuildARM64e`. `IPHONEOS_DEPLOYMENT_TARGET=26.0`
    on the `xcodebuild` command line, or in an xcconfig named by the `XCODE_XCCONFIG_FILE` environment
    variable, does raise every target, CryptoSwift included: zero warnings, `0x06030750`. Only
    `xcodebuild` reads either, though, and Apple documents Xcode Cloud's custom environment variables for
    its `ci_scripts` only. Writing Fernlet's own scrypt would have meant owning the cryptography.
  - **The fix.** Fernlet builds CryptoSwift from its fork, `https://github.com/bowman-mw/CryptoSwift`,
    at tag `1.10.0-fernlet.2` (commit `81cbac5a`). That tag is upstream 1.10.0 (`f2a627b8`) with one line
    of `Package.swift` changed, `.iOS(.v11)` to `.iOS("26.0")`, under a comment marking the file as
    altered, as CryptoSwift's license asks. No source file differs (`git diff 1.10.0 1.10.0-fernlet.2`
    in the fork shows just those lines), and `NOTICE` carries the license and its acknowledgment. The
    same sources built at upstream's floor and at 26.0 gave the same scrypt bytes (measured on macOS,
    2026-10-25). `FernletLockCryptoTests` pins scrypt two ways: to RFC 7914's published vector at the
    lock's own r=8 and p=1, and to a known answer at the production parameters, cross-checked against an
    independent RFC 7914 implementation.
    `CIGateSelectorBoundaryTests.theFourPinSpellingsNameOneTagOfTheCryptoSwiftFork` holds both
    manifests and both `Package.resolved` files to that tag's commit. On a Release build for a generic
    iOS device, the link prints zero of these warnings, and the app's `arm64e` slice reads `0x06030750`
    like the extensions.
  - **Moving to a new CryptoSwift release.** Cut a tag on the fork: upstream's release with the same
    floor line and marking comment, and nothing else. Then, in one commit, move the manifest's `exact:`
    and the project's `exactVersion`, re-resolve both `Package.resolved` files, and add the tag's row to
    `releasedCryptoSwiftRevisions`. Both scrypt known-answer tests must pass unchanged.
- **Debugging.** Pointer-authentication faults only reproduce on device; tagging faults also
  reproduce in the Simulator on an M5 Mac (rollout step 2), in hard mode. Apple warns the
  checks "can impact the performance and stability" of code not built for them; that is what the soft
  stage is for.
- **iOS 27.** `enhanced-security-version-string = "2"` enables guard objects; Apple says to profile
  first. Raising the version is a deliberate change, not a default.

## References

- Apple, *Enabling enhanced security for your app* —
  https://developer.apple.com/documentation/xcode/enabling-enhanced-security-for-your-app
- Apple, *Security entitlements* — https://developer.apple.com/documentation/bundleresources/security-entitlements
- Apple, *Creating browser extensions in Xcode*, "Build for pointer authentication" (the package
  workspace setting) —
  https://developer.apple.com/documentation/browserenginekit/creating-browser-extensions-in-xcode
- Apple Security Research, *Memory Integrity Enforcement* (2025-09-09) —
  https://security.apple.com/blog/memory-integrity-enforcement/
- Xcode 26.4 release notes (168185600: the `-string` keys replace the integer forms).
