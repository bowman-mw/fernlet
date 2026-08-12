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
   the S3 enforcement self-test plus exactly five wall suites — `S3BoundaryTests`,
   `NoTrackingBoundaryTests`, `KeyCustodyBoundaryTests`, `ColumnCryptoDeviceBindingTests`, and
   `SealedBackupFormatPinTests` — so a cross-wall import, tracking, key-custody, or at-rest-format
   regression cannot merge green. (Everything else in `FernletTests`, `FernletLockCryptoTests`
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
   `Fernlet/PrivacyPolicyView.swift` — same substance, same effective date).
4. If any network destination or dependency changed: the change is allowlisted in
   `NoTrackingBoundaryTests` **and** documented in
   [`Docs/No-Tracking-Wall.md`](No-Tracking-Wall.md), in the same commit (§5 of that doc).

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

## 5. The two one-time publish steps (owner actions)

Everything above runs today, visible only to the owner. Two steps make it third-party-checkable
([`Verifiability.md`](Verifiability.md) §7):

1. **Flip the repository public** (it currently 404s for outsiders). This turns the walls from
   internal guardrails into public commitments: removing one becomes a visible, attributable
   diff, and the traffic-audit invitation gains an audience.
2. **Deploy [`Site/`](../Site/README.md) to `fernlet.com`** (currently a parking page). This
   hosts the privacy policy at the public URL App Store Connect requires, and should link
   `Docs/Verifiability.md`.

## 6. Related

- [`Docs/Verifiability.md`](Verifiability.md) — what each guarantee is and how anyone verifies it.
- [`Docs/No-Tracking-Wall.md`](No-Tracking-Wall.md) — the egress wall this process gates changes to.
- [`.github/CODEOWNERS`](../.github/CODEOWNERS) — the review gate's path list.
- [`Scripts/release-checksum.sh`](../Scripts/release-checksum.sh) — the tag + checksum tool.
