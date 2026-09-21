// WidgetSnapshotContentEqualityTests.swift
// FernletTests
//
// Network migration P10 item 4 (plan §17.2): the CONTENT/METADATA split the background refresh's
// "reload timelines only on change" rests on, and the mirror behaviour it buys.
//
// **The trap this suite exists for.** `WidgetSnapshot` is `Equatable` by synthesis, and the
// synthesis includes `computedAt`, which `FernletStore.currentWidgetSnapshot()` stamps `Date()` at
// every construction. So `==` is FALSE between two snapshots of an unchanged day taken a
// millisecond apart, and a refresh handler that decided "did anything change?" with `==` would
// reload the widget's timelines on every single run, forever, having written a test suite that
// passed. That is not a hypothetical: it is what the app does today on the foreground path (by
// design there — every caller is a persisted save), and it is exactly what §17.2 forbids a
// fifteen-minute opportunistic task from doing.
//
// **What is pinned, and why each cell exists.**
// 1. The two notions are DIFFERENT: two snapshots differing only in `computedAt` are `contentEquals`
//    and are not `==`. One cell, both directions, and it is the whole thesis.
// 2. Every content field, flipped one at a time, breaks `contentEquals` — so a field silently
//    dropped from the comparison reds.
// 3. The flip table COVERS the content list, and the content list plus the metadata list is exactly
//    the struct's stored-property set, counted through `Mirror`. A field added to `WidgetSnapshot`
//    without a classification therefore reds here rather than being silently excluded from the diff
//    — the failure mode a hand-written comparison always has and never announces.
// 4. The mirror reloads only on a content change, counted against the `reloadTimelines` closure
//    `WidgetSnapshotMirror` already injects. No new seam was needed for this: `WidgetBridgeTests`
//    has been counting reloads through it since batch G.
//
// **Why `Mirror` rather than a `CodingKeys` count.** `WidgetSnapshot` has no hand-written
// `CodingKeys`, so there is nothing to count but the runtime's view of the stored properties, and a
// computed property (`companionState`) does not appear in it — which is correct, since a computed
// property cannot be a field the diff forgot.
//
// Not a `MeshP<n>…AcceptanceTests`: gated on the `s3-grep` CI step beside the other two
// companion-refresh suites.

import Foundation
import Testing
@testable import Fernlet

/// The content-vs-metadata classification of ``WidgetSnapshot``, and the publish decision it drives.
@MainActor
struct WidgetSnapshotContentEqualityTests {

    // MARK: - The classification

    /// The fields that decide what the widget DRAWS. A difference in any one is a reload.
    ///
    /// MEASURED against the struct by ``theClassificationCoversEveryStoredField()``; the reason each
    /// is content is in `WidgetSnapshot.contentEquals(_:)`'s own table, which is where a reviewer
    /// should be reading it.
    static let contentFields = [
        "companionStateRaw", "score", "bottleCount", "hydrationTarget", "macroSummary", "dateKey"
    ]

    /// The fields stamped at construction that no widget family renders. A difference in one of
    /// these is NOT a reload.
    ///
    /// One entry. `computedAt` is written in three places across the bridge and read by no view; if
    /// a family ever displays "updated at", this row moves to ``contentFields`` and the refresh
    /// starts reloading on every run, which is a decision somebody makes on purpose.
    static let metadataFields = ["computedAt"]

    /// The widget-side files that must not RENDER the metadata field.
    ///
    /// The classification above is an assertion about the widget's views, and nothing else here
    /// checks it: every cell below would stay green if a family started drawing `computedAt`, and
    /// the refresh would then be silently skipping reloads the person can see. So the claim is made
    /// mechanically, over the extension's own sources, as code rather than as prose.
    static let widgetSourceRoot = "App/FernletWidgets"

    /// A snapshot with nothing zero or empty, so a flip that failed to change anything cannot pass
    /// by accident.
    ///
    /// - Returns: The baseline every cell below starts from.
    static func baseline() -> WidgetSnapshot {
        WidgetSnapshot(
            companionStateRaw: "Okay",
            score: 0.62,
            bottleCount: 3,
            hydrationTarget: 8,
            macroSummary: WidgetSnapshot.MacroSummary(protein: 42, carbs: 118, fat: 31),
            dateKey: "2026-09-20",
            computedAt: Date(timeIntervalSince1970: 1_780_000_123)
        )
    }

    /// One flip: the field it changes, and how.
    struct Flip {

        /// The stored property this row flips — matched against ``contentFields``.
        let field: String

        /// Applies the flip.
        let apply: (inout WidgetSnapshot) -> Void
    }

    /// One row per content field, each changing that field and nothing else.
    ///
    /// Declared as a table rather than as six cells so ``theFlipTableCoversEveryContentField()`` can
    /// assert it is WHOLE — six near-identical cells can be five near-identical cells and nobody
    /// notices.
    static let flips: [Flip] = [
        Flip(field: "companionStateRaw", apply: { $0.companionStateRaw = "Tired" }),
        Flip(field: "score", apply: { $0.score = 0.63 }),
        Flip(field: "bottleCount", apply: { $0.bottleCount = 4 }),
        Flip(field: "hydrationTarget", apply: { $0.hydrationTarget = 9 }),
        Flip(field: "macroSummary", apply: {
            $0.macroSummary = WidgetSnapshot.MacroSummary(protein: 43, carbs: 118, fat: 31)
        }),
        Flip(field: "dateKey", apply: { $0.dateKey = "2026-09-21" })
    ]

    // MARK: - The thesis

    /// **The whole point**: `contentEquals` and `==` are different notions, proved in both
    /// directions at once.
    ///
    /// A snapshot that differs only in its construction stamp renders identically and must not
    /// reload the widget — and it is NOT `==`, which is why the refresh could not have used `==`.
    /// If somebody "simplifies" `contentEquals` to `self == other`, the second assertion still
    /// passes and the first one reds.
    @Test func aSnapshotThatDiffersOnlyInItsStampIsContentEqualButNotEqual() {
        let first = Self.baseline()
        var second = first
        second.computedAt = first.computedAt.addingTimeInterval(900)

        #expect(first.contentEquals(second), "a fresh stamp over unchanged data is not a change")
        #expect(second.contentEquals(first), "and the relation is symmetric")
        #expect(first != second, """
            …while `==` says it IS a change. These two answers differing is the reason \
            `contentEquals` exists: a refresh handler that reached for `==` would reload the \
            widget's timelines every fifteen minutes for the rest of the install.
            """)
        #expect(first.contentEquals(first), "and it is reflexive")
    }

    /// Every content field, flipped alone, is a change under both notions.
    @Test func flippingAnyContentFieldBreaksContentEquality() {
        // R2: bounded by the flip table.
        for flip in Self.flips {
            let original = Self.baseline()
            var changed = original
            flip.apply(&changed)

            #expect(changed != original, "\(flip.field): the flip changed nothing — the row is dead")
            #expect(!original.contentEquals(changed),
                    "\(flip.field) is content: a difference in it changes what the widget draws, so it must force a reload")
            #expect(!changed.contentEquals(original), "\(flip.field): and symmetrically so")
        }
    }

    /// The flip table covers every content field, so a field can be classified as content only by
    /// also being flipped.
    @Test func theFlipTableCoversEveryContentField() {
        #expect(Set(Self.flips.map(\.field)) == Set(Self.contentFields), """
            the flip table and the content list disagree. A content field with no flip row is a \
            field `contentEquals` could stop comparing without anything going red.
            """)
        #expect(Self.flips.count == Self.contentFields.count, "and no field is flipped twice")
    }

    /// **The field-count pin.** Content plus metadata is exactly the struct's stored-property set.
    ///
    /// This is the cell that catches the failure a hand-written comparison always has: a field added
    /// to `WidgetSnapshot` later, wired through `Codable` and the widget, and silently absent from
    /// `contentEquals` — so the refresh stops reloading when it changes, and the widget shows a
    /// stale value that nothing explains. Adding a field makes this red until somebody writes down
    /// which side of the line it is on.
    @Test func theClassificationCoversEveryStoredField() {
        let fields = Mirror(reflecting: Self.baseline()).children.compactMap(\.label)

        #expect(Set(fields) == Set(Self.contentFields + Self.metadataFields), """
            `WidgetSnapshot`'s stored properties are \(fields.sorted()), and the classification \
            names \((Self.contentFields + Self.metadataFields).sorted()). Every field must be \
            content (it changes what the widget draws → reload) or metadata (stamped at \
            construction, rendered by nothing → no reload), and the one that is missing has to be \
            put on a side before this passes.
            """)
        #expect(fields.count == 7, "MEASURED at P10 item 4: six content fields and one metadata field")

        let macroFields = Mirror(reflecting: WidgetSnapshot.MacroSummary(protein: 0, carbs: 0, fat: 0))
            .children.compactMap(\.label)
        #expect(Set(macroFields) == Set(["protein", "carbs", "fat"]), """
            the nested macro summary is compared WHOLE by `contentEquals`, so a field added to it is \
            covered automatically — but only while it stays a value type with synthesised equality, \
            which this pins.
            """)
    }

    /// **The metadata claim, made against the widget extension rather than asserted in prose.**
    ///
    /// `computedAt` is metadata only because no widget family draws it. That is a fact about
    /// another target's source, and every other cell in this suite would stay green if it stopped
    /// being true — the refresh would simply start skipping reloads a person can see, which is the
    /// worst kind of regression because it looks like the feature working.
    ///
    /// So the sites are COUNTED. Three today, all in the shared-model file and all writes: the
    /// declaration, the placeholder's stamp, and the optimistic water bump's re-stamp. A fourth
    /// mention — which a `Text(entry.snapshot.computedAt, style: .relative)` would be — reds this
    /// cell, and whoever added it either moves `computedAt` to ``contentFields`` (and accepts a
    /// reload on every refresh) or explains why their new site is still not a render.
    @Test func theMetadataFieldIsStillDrawnByNoWidgetFamily() throws {
        let root = RepoRoot.url(Self.widgetSourceRoot)
        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
            "could not enumerate \(Self.widgetSourceRoot) — this cell is now passing over nothing")

        var sites: [String] = []
        var filesScanned = 0
        // R2: bounded by the extension's file count.
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            filesScanned += 1
            // R2: bounded by that file's line count.
            for (offset, line) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), line.contains("computedAt") else { continue }
                sites.append("\(url.lastPathComponent):\(offset + 1)")
            }
        }

        #expect(filesScanned >= 3, "scanned \(filesScanned) file(s) — the widget target's folder moved")
        #expect(sites.count == 3, """
            `computedAt` appears as code at \(sites.count) site(s) under \(Self.widgetSourceRoot), \
            measured 3 (the declaration, the placeholder's stamp, and the optimistic water bump's \
            re-stamp — all writes, none a render): \(sites.joined(separator: ", ")). If a family now \
            DRAWS it, move it to `contentFields` in this file, because the background refresh is \
            deciding not to reload on a difference the person can see.
            """)
        #expect(sites.allSatisfy { $0.hasPrefix("WidgetSharedModels.swift:") },
                "every site is in the shared-model twin, which renders nothing: \(sites.joined(separator: ", "))")
    }

    // MARK: - The mirror's decision

    /// A temporary app-group stand-in, one per cell.
    ///
    /// - Returns: A directory nothing else writes to.
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WidgetSnapshotContentEqualityTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// **The behaviour §17.2 asks for**, counted at the real seam: content change → reload; fresh
    /// stamp only → written, not reloaded.
    ///
    /// Driven against the real `WidgetSnapshotMirror` and its real file store, through the
    /// `reloadTimelines` closure the type already injects, so this is the app's WidgetKit poke being
    /// counted and not a fake's idea of one.
    @Test func theMirrorReloadsOnlyWhenTheContentChanged() {
        var reloads = 0
        let mirror = WidgetSnapshotMirror(directory: temporaryDirectory(), reloadTimelines: { reloads += 1 })
        let first = Self.baseline()

        #expect(mirror.publishIfContentChanged(first) == .reloaded,
                "nothing was published before, so the widget has nothing — a first publish is always a change")
        #expect(reloads == 1)

        var restamped = first
        restamped.computedAt = first.computedAt.addingTimeInterval(900)
        #expect(mirror.publishIfContentChanged(restamped) == .unchanged,
                "the dull refresh: same day, same numbers, a newer stamp — and no reload")
        #expect(reloads == 1, "THE assertion of this cell; a second reload here is the defect §17.2 names")
        #expect(mirror.currentSnapshot()?.computedAt == restamped.computedAt,
                "…and it was still WRITTEN: the stamp moves, so a reader can tell a current snapshot from an abandoned one")

        var changed = restamped
        changed.bottleCount += 1
        #expect(mirror.publishIfContentChanged(changed) == .reloaded, "a real change reloads")
        #expect(reloads == 2)
        #expect(mirror.currentSnapshot()?.bottleCount == changed.bottleCount)
    }

    /// A day rollover is always a content change, because `dateKey` is content.
    ///
    /// Stated as its own cell because it is the one change a background refresh exists to catch: the
    /// app was backgrounded yesterday, the refresh runs after midnight, and the widget must stop
    /// rendering yesterday's companion. If `dateKey` were ever classified as metadata, every other
    /// cell here would still pass.
    @Test func aDayRolloverAlwaysReloads() {
        var reloads = 0
        let mirror = WidgetSnapshotMirror(directory: temporaryDirectory(), reloadTimelines: { reloads += 1 })
        let yesterday = Self.baseline()
        _ = mirror.publishIfContentChanged(yesterday)

        var today = yesterday
        today.dateKey = "2026-09-21"
        today.computedAt = yesterday.computedAt.addingTimeInterval(86_400)

        #expect(mirror.publishIfContentChanged(today) == .reloaded)
        #expect(reloads == 2, "the rollover is a reload even though every other field is identical")
    }

    /// The unconditional publish path is untouched: `publish(_:)` still reloads every time.
    ///
    /// §17.2 scopes "reload only on change" to the REFRESH handler. Narrowing the foreground path
    /// would change every widget update in the app — a save, a day roll, a queue drain — each of
    /// which is a change by construction anyway. This cell is what makes that scoping a fact rather
    /// than an intention: a future edit that routes `publish(_:)` through the diff reds here.
    @Test func theUnconditionalPublishPathStillReloadsEveryTime() {
        var reloads = 0
        let mirror = WidgetSnapshotMirror(directory: temporaryDirectory(), reloadTimelines: { reloads += 1 })
        let snapshot = Self.baseline()

        mirror.publish(snapshot)
        mirror.publish(snapshot)

        #expect(reloads == 2, "the foreground path is unconditional and stays that way")
    }
}
