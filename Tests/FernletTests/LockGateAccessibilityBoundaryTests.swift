// LockGateAccessibilityBoundaryTests.swift
// FernletTests
//
// The grep half of the lock gate's accessibility cover, and the pad's scroll safety.
//
// Why a grep-wall and not a runtime test. Both invariants are STRUCTURAL — a modifier that must be
// present on a particular view — and both fail SILENTLY when it is dropped: the screen looks
// identical, and only an assistive technology can tell. A runtime assertion would need SwiftUI to
// have materialised its accessibility node tree, which it does not do unless an assistive
// technology is actually attached to the process; a test that quietly finds an empty tree passes
// vacuously, which is the exact failure mode this file exists to prevent. The runtime evidence for
// these invariants was taken separately, with the simulator's accessibility server enabled.
//
// Companions: `CaptureOcclusionGatingTests` pins the truth table of
// `FernletLockGateOcclusion.overlayIsUp(active:state:scope:)`, which the gate modifier CALLS (rather
// than hand-copying) precisely so that suite covers the accessibility cover's condition too.

import Foundation
import Testing

/// Pins the accessibility invariants of the app lock's gate and of the shared PIN pad's hosts.
@Suite struct LockGateAccessibilityBoundaryTests {

    /// One file's audited pad shape: how many ``FernletNumericPad``s it renders, how many
    /// `fernletLockPadPage()` scroll hosts wrap them, and how many pads are Dynamic-Type capped
    /// instead of scrolled.
    ///
    /// The counts are pinned EXACTLY, and the numbers are deliberately not required to match each
    /// other — one scroll host legitimately covers several pads (``FernletLockSetupView`` wraps
    /// `stepContent`, which is the entry step and the confirm step). What the exact pin buys is the
    /// thing a "contains at least one wrapper" check cannot: adding a pad to a file that already has
    /// a wrapper somewhere fails this test, so the author has to come here, update the pin, and
    /// answer the wrapper question for the screen they just added.
    private struct PadHostShape {
        /// Repo-relative path.
        let path: String
        /// Occurrences of `FernletNumericPad(value:`.
        let pads: Int
        /// Occurrences of `.fernletLockPadPage()` — call sites only; the helper's own declaration
        /// carries no leading dot.
        let scrollHosts: Int
        /// Occurrences of the Dynamic-Type cap, for pads that structurally cannot scroll.
        let cappedPads: Int
    }

    /// Every file that renders a ``FernletNumericPad``, with its audited shape.
    ///
    /// The pad's key tiles are a Dynamic-Type MINIMUM around a `relativeTo: .title2` digit, so the
    /// 3×4 grid grows past 300pt at the accessibility text sizes; the app declares landscape on
    /// iPhone and locks orientation nowhere. Every screen behind these counts is unskippable —
    /// unlocking, creating a passcode, changing one, re-verifying one, setting a duress code — so a
    /// bottom key row that falls off the screen is a dead end, not an inconvenience.
    ///
    /// `DuressPINSetupView` is the one host that CANNOT scroll: its pad is a `safeAreaInset`, and an
    /// inset that grows takes its height off the page above it rather than scrolling, so it caps the
    /// pad's Dynamic Type instead. That exception is pinned here rather than left implicit.
    private static let padHostShapes: [PadHostShape] = [
        PadHostShape(path: "FernletKit/Sources/FernletLockUI/FernletLockView.swift",
                     pads: 3, scrollHosts: 2, cappedPads: 0),   // unlock; setup entry + confirm
        PadHostShape(path: "App/Fernlet/SettingsSheet.swift",
                     pads: 4, scrollHosts: 2, cappedPads: 0),   // biometric verify; change ×3
        PadHostShape(path: "App/Fernlet/DuressPINSetupView.swift",
                     pads: 1, scrollHosts: 0, cappedPads: 1)    // safeAreaInset — capped, not scrolled
    ]

    private static func source(_ relativePath: String) throws -> String {
        let url = RepoRoot.url.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The gate must cover its content in the accessibility tree, not only on screen.
    ///
    /// `zIndex` reorders drawing and nothing else, so without `accessibilityHidden` VoiceOver,
    /// Switch Control and Full Keyboard Access walk off the passcode pad into the Private hub and
    /// can operate it while the lock is painted over the screen.
    @Test func theLockGateHidesItsContentAndDeclaresBothOverlaysModal() throws {
        let gate = try Self.source("FernletKit/Sources/FernletLockUI/FernletLockGate.swift")

        #expect(gate.contains(".accessibilityHidden(overlayIsUp)"),
                "FernletLockGateModifier must hide its gated content while an overlay is up.")
        // Both overlays: the unlock screen and the not-configured setup call to action.
        let modalCount = gate.components(separatedBy: ".accessibilityAddTraits(.isModal)").count - 1
        #expect(modalCount == 2,
                "Both gate overlays must be accessibility-modal; found \(modalCount) of 2.")
        #expect(gate.contains("AccessibilityNotification.ScreenChanged()"),
                "The gate must announce the screen change when it engages — .isModal scopes the cursor but never moves it.")
        // The condition must be the pure function the truth-table suite pins, never a hand copy.
        #expect(gate.contains("FernletLockGateOcclusion.overlayIsUp("),
                "overlayIsUp must delegate to the tested pure helper rather than restate its condition.")
    }

    /// Pins the audited pad shape of every file that renders the shared keypad.
    ///
    /// **The guarded invariant, precisely.** Every screen that renders a ``FernletNumericPad`` puts
    /// it inside a `fernletLockPadPage()` scroll host, EXCEPT `DuressPINSetupView`, whose pad is a
    /// `safeAreaInset` and is Dynamic-Type capped instead. That is a per-SCREEN property, and this
    /// is a per-FILE tripwire — the two are not the same thing, and the gap is deliberate and
    /// bounded rather than hidden:
    ///
    /// - What this CANNOT prove: that each individual pad in a multi-screen file is wrapped. One
    ///   scroll host legitimately covers several pads (``FernletLockSetupView`` wraps `stepContent`
    ///   for both the entry and confirm steps), so counts cannot be required to match, and text
    ///   alone cannot tell which pad a given wrapper encloses.
    /// - What it DOES guarantee: the shape cannot change without someone noticing. Every count is
    ///   pinned exactly, so adding a pad to a file that already has a wrapper — the regression class
    ///   that a "contains at least one wrapper" check waves through — fails here and forces the
    ///   author to update the pin and answer the wrapper question for the new screen. Removing a
    ///   wrapper fails too.
    /// - What closes the gap for real: the per-screen rendered probes at AX5 that established these
    ///   numbers in the first place (all five hosts, every key reachable). Re-run those when this
    ///   pin changes; that is the point of making the pin fail.
    @Test func everyNumericPadHostKeepsItsAuditedScrollShape() throws {
        for shape in Self.padHostShapes {
            let text = try Self.source(shape.path)
            let pads = text.components(separatedBy: "FernletNumericPad(value:").count - 1
            let scrollHosts = text.components(separatedBy: ".fernletLockPadPage()").count - 1
            let capped = text.components(separatedBy: ".dynamicTypeSize(...Self.padTypeSizeCap)").count - 1

            #expect(pads == shape.pads, """
                \(shape.path) renders \(pads) FernletNumericPad(s), the wall expects \(shape.pads). \
                A pad was added or removed: confirm the new screen is inside a fernletLockPadPage() \
                scroll host (or Dynamic-Type capped, if its pad cannot scroll), re-run the AX5 \
                reachability probe for it, then update padHostShapes.
                """)
            #expect(scrollHosts == shape.scrollHosts, """
                \(shape.path) has \(scrollHosts) fernletLockPadPage() host(s), the wall expects \
                \(shape.scrollHosts). A pad screen without one drops its bottom key row off screen \
                at accessibility text sizes and in landscape, on a screen the user cannot skip.
                """)
            #expect(capped == shape.cappedPads, """
                \(shape.path) has \(capped) Dynamic-Type-capped pad(s), the wall expects \
                \(shape.cappedPads). The cap is what keeps a safeAreaInset pad from eating the page \
                it is inset into; it may only be dropped by making that pad scroll instead.
                """)
        }
    }

    /// Discovery guard: if a NEW file starts hosting the pad, it has to be added above. Without
    /// this, a sixth host could ship unscrolled and both tests would still pass.
    @Test func noUnlistedFileHostsTheNumericPad() throws {
        let roots = ["App", "FernletKit/Sources"]
        var hosts: [String] = []
        for root in roots {
            let rootURL = RepoRoot.url.appendingPathComponent(root)
            guard let walker = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
                Issue.record("Could not enumerate \(root) — discovery is broken.")
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      text.contains("FernletNumericPad(value:") else { continue }
                hosts.append(url.path)
            }
        }
        #expect(!hosts.isEmpty, "Found zero pad hosts — discovery is broken, not clean.")

        let known = Self.padHostShapes
            .map { RepoRoot.url.appendingPathComponent($0.path).path }
        let unlisted = hosts.filter { !known.contains($0) }
        #expect(unlisted.isEmpty, """
            New FernletNumericPad host(s) not covered by this wall: \(unlisted). \
            Wrap the screen in fernletLockPadPage() (or cap the pad's Dynamic Type) and list it here.
            """)
    }
}
