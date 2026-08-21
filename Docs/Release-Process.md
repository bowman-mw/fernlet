# Release Process — governance for a repo whose product is a promise

**Status:** Standing process. This document is the governance half of
[`Docs/Verifiability.md`](Verifiability.md): the walls make a privacy regression *loud*; this
process makes shipping one *attributable and gated*. It covers branch protection, code-owner
review, signed release tags, checksum publication, and the two one-time publish steps.

---

## 1. Branch protection (one-time GitHub setup)

On `main`, enable branch protection with:

1. **Require status checks to pass before merging**, with
   [`s3-wall.yml`](../.github/workflows/s3-wall.yml) as a **required** check. That workflow runs
   the S3 enforcement self-test plus exactly seven wall suites — `S3BoundaryTests`,
   `NoTrackingBoundaryTests`, `PowerOfTenBoundaryTests`, `LocalizationBoundaryTests`,
   `KeyCustodyBoundaryTests`, `ColumnCryptoDeviceBindingTests`, and `SealedBackupFormatPinTests`
   — so a cross-wall import, tracking, Power-of-10, localization-bundle, key-custody, or
   at-rest-format regression cannot merge green. (Everything else in `FernletTests`, `FernletLockCryptoTests`
   included, is gated by the per-release full-suite run in §2, not per-merge.) The workflow needs
   a macOS runner carrying the **iOS 26.5 SDK or newer** (`runs-on: macos-26`), because the app
   uses API introduced in that SDK; it selects the newest Xcode 26+ on the image and fails fast
   when a floor is unmet. `IPHONEOS_DEPLOYMENT_TARGET` must stay at the claimed floor, 26.0,
   because a deployment target above the runner's SDK is a hard build error.
2. **Require review from Code Owners.** [`.github/CODEOWNERS`](../.github/CODEOWNERS) lists
   exactly the wall-load-bearing paths (the boundary tests, wall scripts and hooks, the CI
   workflow, the privacy documents, `FernletKit/Package.swift`, and the `PrivacyInfo.xcprivacy`
   manifests). With this switch on, no change to a wall file merges without the owner's explicit
   approval.
3. **Require signed commits** (optional but recommended once the repo is public) and disallow
   force pushes to `main`.

Local complement: every clone runs `Scripts/install-git-hooks.sh` once, so the committed
`pre-push` hook runs `Scripts/spm-wall-check.sh` before wall-touching pushes.

## 2. Per-release checklist

1. `main` is green: `xcodebuild build-for-testing …` plus the full `FernletTests` suite, and
   `Scripts/spm-wall-check.sh` exits 0.
2. `Scripts/doc-coverage-scan.py` reports zero undocumented type declarations.
3. The privacy policy triple is in sync (`Docs/Privacy-Policy.md`, `Site/privacy/index.html`,
   `App/Fernlet/PrivacyPolicyView.swift` — same substance, same effective date).
4. If any network destination or dependency changed: the change is allowlisted in
   `NoTrackingBoundaryTests` **and** documented in
   [`Docs/No-Tracking-Wall.md`](No-Tracking-Wall.md), in the same commit (§5 of that doc).
5. **A Release archive builds and validates.** CI only ever builds Debug, so whole-module
   optimization, `ENABLE_NS_ASSERTIONS = NO`, distribution code signing, and the entitlements
   the distribution profile actually carries are exercised **nowhere else**. Archive and run
   Organizer → Validate App before every submission.
6. **The CloudKit Production schema is current.** TestFlight and the App Store both run against
   the **Production** container, and Production does not auto-create record types the way
   Development does. Check [`CloudKit-Schema-Deploy.md`](CloudKit-Schema-Deploy.md) for any row
   still marked pending, promote it in the console, and confirm it is *queryable*. A missing
   record type does not crash — it silently breaks restore, and it makes the delete-everything
   teardown (which enumerates by record type) quietly incomplete, which turns the app's central
   privacy promise into a false statement.

## 3. Signed tag + checksums

Run [`Scripts/release-checksum.sh`](../Scripts/release-checksum.sh):

```
Scripts/release-checksum.sh 1.0.0
```

It refuses a dirty tree, creates the annotated **signed** tag `v1.0.0` (and verifies it — an
unsigned release tag is a hard failure, not a fallback), archives the Release build, and writes
`build/release-1.0.0/SHA256SUMS-1.0.0.txt` with a SHA-256 for every file in the archive's
products, plus the commit, toolchain, and date they were built from.

**Why checksums, when the App Store can't be byte-verified:** Apple re-signs and transforms every
submitted binary, so store bytes can never match a local build — that limit is stated in the
checksum file itself and in [`Verifiability.md`](Verifiability.md) §5. The checksums are the
*self-build baseline*: they pin what the owner's toolchain produced from the signed tag, let any
independent builder of the same tag diff their output against it, and give sideloaders a binary
they can fully account for.

## 4. Publish the release

1. Push the tag: `git push origin v1.0.0`.
2. Create a GitHub Release on the tag and attach `SHA256SUMS-<version>.txt`.
3. Release notes must call out any change to: the egress allowlist, the privacy policy, key
   custody, or an at-rest format — these are the changes users are being asked to trust.
4. Submit to App Store Connect from the same archive the checksums describe.

## 5. The two one-time publish steps — DONE 2026-08-19/20

Both steps that made this repo third-party-checkable ([`Verifiability.md`](Verifiability.md) §7)
have landed:

1. ✅ **Repository is public** — <https://github.com/bowman-mw/fernlet>. The walls are now public
   commitments rather than internal guardrails: removing one is a visible, attributable diff.
2. ✅ **[`Site/`](../Site/README.md) is deployed** — `fernlet.com` serves the landing page and
   <https://fernlet.com/privacy/> carries the policy at the effective date in
   [`Privacy-Policy.md`](Privacy-Policy.md). That is the public URL App Store Connect requires;
   entering it in ASC is a remaining owner step, tracked in
   [`RemainingWork-2026-08-20.md`](RemainingWork-2026-08-20.md) §1.

## 6. Related

- [`Docs/Verifiability.md`](Verifiability.md) — what each guarantee is and how anyone verifies it.
- [`Docs/No-Tracking-Wall.md`](No-Tracking-Wall.md) — the egress wall this process gates changes to.
- [`.github/CODEOWNERS`](../.github/CODEOWNERS) — the review gate's path list.
- [`Scripts/release-checksum.sh`](../Scripts/release-checksum.sh) — the tag + checksum tool.
