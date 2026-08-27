// SealedColumnFormatCensus.swift
// PrivateStoreCore
//
// Phase 0 of Docs/Plan-Crypto-Standardization-2026-08-27.md for the ColumnCrypto
// surface: a keyless, read-only, memory-bounded count of the sealed corpora by
// at-rest format. Nothing here decrypts, and nothing here writes.

import CoreData
import FernletCrypto
import Foundation

/// One censused ciphertext column: the sealed entity it lives on and its attribute name.
///
/// A value type rather than a bare `"Entity.attribute"` string so the census's per-column keys
/// cannot be assembled or parsed by string surgery at a call site.
public struct SealedColumnIdentifier: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// The sealed Core Data entity (`JournalNarrative`, `MenstrualNarrative`, …).
    public let entityName: String
    /// The binary attribute holding the sealed blob (`textCiphertext`, `noteCiphertext`, …).
    public let attributeName: String

    public init(entityName: String, attributeName: String) {
        self.entityName = entityName
        self.attributeName = attributeName
    }

    /// Diagnostic spelling only (`JournalNarrative.textCiphertext`) — never user-facing copy.
    public var description: String { "\(entityName).\(attributeName)" }

    /// Deterministic ordering so census output and mismatch reports are stable across runs.
    public static func < (lhs: SealedColumnIdentifier, rhs: SealedColumnIdentifier) -> Bool {
        (lhs.entityName, lhs.attributeName) < (rhs.entityName, rhs.attributeName)
    }
}

/// One sealed entity and the ciphertext columns the census reads on it.
///
/// This table is written out by hand rather than discovered from the model at run time, because a
/// census that silently discovers its own scope can silently *lose* scope: a renamed attribute
/// would drop out of the count with no failure. The drift risk that creates is closed from the
/// other side, by ``SealedColumnFormatCensus/verifyTable(matches:)``, which fails when the table
/// and the live model disagree in either direction.
public struct SealedEntityColumns: Sendable, Equatable {
    /// The sealed entity's Core Data name.
    public let entityName: String
    /// Its ciphertext attributes, in a fixed order.
    public let ciphertextAttributeNames: [String]

    public init(entityName: String, ciphertextAttributeNames: [String]) {
        self.entityName = entityName
        self.ciphertextAttributeNames = ciphertextAttributeNames
    }

    /// This entity's columns as identifiers.
    public var columns: [SealedColumnIdentifier] {
        ciphertextAttributeNames.map { SealedColumnIdentifier(entityName: entityName, attributeName: $0) }
    }
}

/// How many stored blobs fell into each ``ColumnCryptoStoredFormat`` bucket, plus the two
/// non-format outcomes a census must report rather than absorb.
///
/// - Important: The bucket counts do **not** all mean the same kind of thing, and the difference
///   is the entire point of the census (see ``ColumnCryptoStoredFormat``):
///   - ``unprefixed`` is an **exact** count of definitely-legacy blobs. It is the number Phase 3's
///     "census = 0" gate watches.
///   - ``v3Marked`` and ``v2Marked`` are **upper bounds** on their generations: a legacy blob's
///     first nonce byte collides with a marker with probability 1/256 each, and a byte-only
///     classifier cannot tell a collided legacy blob from a genuinely marked one. Only a keyed
///     migration pass can resolve that ~0.78% sliver.
///
///   So `unprefixed == 0` is **necessary but not sufficient** to prove the legacy population is
///   empty. ``legacyUpperBound`` states the other side of that honestly.
public struct SealedColumnFormatTally: Sendable, Equatable {
    /// Blobs whose first byte is the v3 marker. Upper bound on the v3 population.
    public var v3Marked: Int
    /// Blobs whose first byte is the v2 marker. Upper bound on the v2 population.
    public var v2Marked: Int
    /// Blobs with no recognized marker byte. **Exact** count of definitely-legacy blobs.
    public var unprefixed: Int
    /// Columns holding `nil` or zero bytes — never sealed, so not a format at all.
    public var emptyOrNil: Int
    /// Columns that could not be read as bytes: a row whose fault could not be fulfilled (deleted,
    /// detached, or made inaccessible mid-scan — see
    /// ``SealedColumnFormatCensus/classify(value:readFrom:)``), or an attribute whose value is not
    /// `Data`. Counted, never silently dropped — an unreadable row is exactly the row a "prove it
    /// reached zero" gate must not miss.
    public var indeterminate: Int

    public init(v3Marked: Int = 0, v2Marked: Int = 0, unprefixed: Int = 0, emptyOrNil: Int = 0, indeterminate: Int = 0) {
        self.v3Marked = v3Marked
        self.v2Marked = v2Marked
        self.unprefixed = unprefixed
        self.emptyOrNil = emptyOrNil
        self.indeterminate = indeterminate
    }

    /// Every column value classified, whatever the outcome.
    public var total: Int { v3Marked + v2Marked + unprefixed + emptyOrNil + indeterminate }

    /// The exact count of blobs that carry no version byte — the lower bound on legacy, and the
    /// only figure in this type that is a precise answer rather than a bound.
    public var definitelyLegacy: Int { unprefixed }

    /// The honest upper bound on the legacy population: every unprefixed blob, plus every marked
    /// blob, since any marked blob *could* be a legacy blob whose nonce collided with the marker.
    ///
    /// Deliberately loose. The expected collided share is ~0.39% of each marked bucket, but an
    /// expectation is not a bound, and Phase 3 deletes a reader on the strength of this number.
    /// Report both ``definitelyLegacy`` and this, never a single "legacy count".
    public var legacyUpperBound: Int { unprefixed + v2Marked + v3Marked }

    /// Records one classified column value.
    public mutating func count(_ format: ColumnCryptoStoredFormat) {
        switch format {
        case .v3Marked:
            v3Marked += 1
        case .v2Marked:
            v2Marked += 1
        case .unprefixed:
            unprefixed += 1
        case .empty:
            emptyOrNil += 1
        }
    }

    /// Records one column value that could not be read at all.
    public mutating func countIndeterminate() {
        indeterminate += 1
    }

    /// Bucket-wise sum, used to fold per-entity tallies into the whole-store total.
    public static func + (lhs: SealedColumnFormatTally, rhs: SealedColumnFormatTally) -> SealedColumnFormatTally {
        SealedColumnFormatTally(
            v3Marked: lhs.v3Marked + rhs.v3Marked,
            v2Marked: lhs.v2Marked + rhs.v2Marked,
            unprefixed: lhs.unprefixed + rhs.unprefixed,
            emptyOrNil: lhs.emptyOrNil + rhs.emptyOrNil,
            indeterminate: lhs.indeterminate + rhs.indeterminate
        )
    }
}

/// What one column value's read produced: a format, or the admission that the value cannot be
/// trusted to mean anything.
///
/// Two cases rather than an optional `ColumnCryptoStoredFormat`, because the difference between
/// them is the census's whole reason to exist. `nil` reads as "no format here", which is one short
/// step from "nothing to migrate here"; ``indeterminate`` cannot be read that way. See
/// ``SealedColumnFormatCensus/classify(value:readFrom:)`` for the trap it is guarding.
public enum SealedColumnReadOutcome: Sendable, Equatable {
    /// The value was read from a row that was still there afterwards, and these are its marker
    /// semantics (including ``ColumnCryptoStoredFormat/empty`` for a genuinely unsealed column).
    case classified(ColumnCryptoStoredFormat)
    /// The value is worthless as evidence: its row was deleted, detached, or otherwise unable to
    /// fulfil its fault, or the attribute held something that is not `Data`. Counted in
    /// ``SealedColumnFormatTally/indeterminate``, never as a format.
    case indeterminate
}

/// The whole reading: one tally per censused column, plus the bounds the scan actually ran under.
///
/// - Important: ``truncated`` is load-bearing. A census that stopped at its row cap has counted a
///   *subset*, so a zero in ``definitelyLegacy`` proves nothing about the rows it never reached.
///   Anything reporting this result must surface truncation alongside the numbers; never present a
///   truncated census as a clean one.
public struct SealedColumnFormatCensusResult: Sendable, Equatable {
    /// Per-column tallies, keyed by ``SealedColumnIdentifier``. Every censused column is present,
    /// including columns whose entity held no rows (an all-zero tally, which is a real answer —
    /// distinct from a column that was never scanned, which cannot happen: a table/model
    /// disagreement throws before the scan starts).
    public let columns: [SealedColumnIdentifier: SealedColumnFormatTally]
    /// Rows visited across all entities. Not the number of classified values — a row contributes
    /// one classification per ciphertext column on its entity (three for `MenstrualNarrative`).
    public let rowsScanned: Int
    /// Rows the store holds across all censused entities, whether or not they were scanned. Equal
    /// to ``rowsScanned`` exactly when the census was not truncated.
    public let rowsAvailable: Int
    /// `true` when the row cap stopped the scan before every row was classified.
    public let truncated: Bool
    /// The row cap the scan ran under, echoed so a truncated reading carries its own explanation.
    public let rowCap: Int

    public init(
        columns: [SealedColumnIdentifier: SealedColumnFormatTally],
        rowsScanned: Int,
        rowsAvailable: Int,
        truncated: Bool,
        rowCap: Int
    ) {
        self.columns = columns
        self.rowsScanned = rowsScanned
        self.rowsAvailable = rowsAvailable
        self.truncated = truncated
        self.rowCap = rowCap
    }

    /// Every column's tally folded together.
    public var total: SealedColumnFormatTally {
        columns.values.reduce(SealedColumnFormatTally(), +)
    }

    /// One column's tally; an all-zero tally for a column that is not censused.
    public func tally(for column: SealedColumnIdentifier) -> SealedColumnFormatTally {
        columns[column] ?? SealedColumnFormatTally()
    }

    /// One entity's columns folded together.
    public func tally(forEntity entityName: String) -> SealedColumnFormatTally {
        columns
            .filter { $0.key.entityName == entityName }
            .values
            .reduce(SealedColumnFormatTally(), +)
    }

    /// Store-wide exact count of definitely-legacy blobs — the Phase 3 gate number.
    public var definitelyLegacy: Int { total.definitelyLegacy }

    /// Store-wide upper bound on the legacy population (see ``SealedColumnFormatTally/legacyUpperBound``).
    public var legacyUpperBound: Int { total.legacyUpperBound }
}

/// Counts the sealed corpora by at-rest format, **without a content key and without decrypting
/// anything**.
///
/// ## Why this exists
///
/// `ColumnCrypto` reads three at-rest generations (v3, v2, and unprefixed legacy) and has no
/// migration pass: rows rebind only when something happens to re-seal them. Phase 3 of
/// Docs/Plan-Crypto-Standardization-2026-08-27.md wants to delete the legacy reader, and deleting a
/// reader while a single legacy row survives is permanent data loss. The plan's gate is therefore a
/// number — and its stated risk control is that producing the number must never itself decrypt
/// ("count by MARKER BYTES only"). A keyed census would only run while the private area is
/// unlocked, and would be a second, unreviewed reader of the sealed corpora.
///
/// ## What the number proves, and what it does not
///
/// ``SealedColumnFormatTally/definitelyLegacy`` (the unprefixed bucket) is exact. The two marked
/// buckets are upper bounds, because a legacy blob's random first nonce byte equals a marker
/// 1-in-256 times per marker and no byte-only classifier can tell that apart from a real marker —
/// the shipping reader disambiguates by attempted decrypt, which this deliberately does not do. A
/// reading of `definitelyLegacy == 0` is therefore **necessary but not sufficient** proof that the
/// legacy population is empty; only a keyed migration pass can resolve the ~0.78% collided sliver.
/// Two further caveats belong next to any reported number:
/// - **It can go up.** `ColumnCrypto.sealPlaintext` still fails open, writing an unbound legacy
///   blob whenever no `DeviceBindingID` is available, so shipping builds can still create legacy
///   rows. Phase 3 closes that; until then a zero reading is a moment, not a latch.
/// - **A truncated census counted a subset.** See ``SealedColumnFormatCensusResult/truncated``.
/// - **A row the scan could not actually READ is not an empty row.** Faulting a row in can fail
///   silently (see ``classify(value:readFrom:)``), so every value's readability is judged after the
///   read and failures land in ``SealedColumnFormatTally/indeterminate``; a store that vanished
///   mid-scan is refused outright by the second ``Failure/storeUnavailable`` guard in
///   ``run(controller:pageSize:rowCap:)``.
///
/// ## Memory posture (the jetsam hazard 269003c was chasing)
///
/// All seven sealed columns use `allowsExternalBinaryDataStorage`, so any value over ~100 KB lives
/// as a loose file in `.FernletPrivate_SUPPORT` and *faults the whole blob into memory* the moment
/// the attribute is touched. Fetching every row and reading every column would therefore pull the
/// entire sealed corpus into RAM to look at one byte per value. Instead the scan: fetches with a
/// small `fetchBatchSize`, walks one page at a time inside an `autoreleasepool`, reads only
/// `data.first` via the classifier, and immediately turns each row back into a fault with
/// `refresh(_:mergeChanges: false)` so the blob is released before the next row is touched. Peak
/// residency is a page of rows, not a corpus. ``defaultRowCap`` bounds the total work, and hitting
/// it sets ``SealedColumnFormatCensusResult/truncated`` rather than silently reporting a partial.
///
/// ## Read-only posture
///
/// The scan runs on a fresh `newBackgroundContext()` — never `viewContext`, whose registered
/// objects the app's live repositories depend on — never saves, and throws
/// ``Failure/censusDirtiedTheContext`` if the context somehow ends up with changes. `refresh` and
/// `count` are reads. Nothing here is a write, and nothing here creates a persisted key or
/// preference (the census has no latch by design: it is a reading, not a migration).
///
/// A caseless enum used purely as a namespace. Nonisolated by this module's default isolation,
/// like the repositories that share the sealed stack.
public enum SealedColumnFormatCensus {
    /// The naming convention the drift guard keys off: every sealed binary column ends in this.
    public static let ciphertextAttributeSuffix = "Ciphertext"

    /// The censused surface: the four sealed entities of `PrivatePersistenceController` and their
    /// seven ciphertext columns. Written by hand and cross-checked against the live model by
    /// ``verifyTable(matches:)`` — an eighth column or a fifth entity fails loudly instead of going
    /// silently un-censused.
    public static let censusedEntities: [SealedEntityColumns] = [
        SealedEntityColumns(
            entityName: "MenstrualNarrative",
            ciphertextAttributeNames: ["noteCiphertext", "symptomFlagsCiphertext", "customSymptomScalesCiphertext"]
        ),
        SealedEntityColumns(
            entityName: "JournalNarrative",
            ciphertextAttributeNames: ["textCiphertext", "emotionsCiphertext"]
        ),
        SealedEntityColumns(
            entityName: "IntimacyLog",
            ciphertextAttributeNames: ["noteCiphertext"]
        ),
        SealedEntityColumns(
            entityName: "WorryNarrative",
            ciphertextAttributeNames: ["textCiphertext"]
        )
    ]

    /// Every censused column, in table order.
    public static var censusedColumns: [SealedColumnIdentifier] {
        censusedEntities.flatMap(\.columns)
    }

    /// Rows faulted in per batch. Small on purpose: an externalized blob is faulted whole, so the
    /// page size is the knob that bounds peak residency.
    public static let defaultPageSize = 50

    /// Hard ceiling on rows visited per census, an order of magnitude above the observed corpus
    /// (low thousands). Exceeding it truncates and says so; it never silently stops counting.
    public static let defaultRowCap = 20_000

    /// Why a census could not be produced. Every case is a refusal to report a number that would
    /// be wrong — per the plan, "if any count cannot be produced, stop".
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// ``censusedEntities`` and the live managed-object model disagree. `missing` lists
        /// censused columns the model does not have (or has with a non-binary type the classifier
        /// cannot read); `unlisted` lists model attributes ending in `Ciphertext` that the table
        /// does not census. Either direction is a correctness hole: the first would count a column
        /// that no longer exists, the second would leave a live sealed column out of the number
        /// that gates deleting a legacy reader.
        case tableDoesNotMatchModel(missing: [SealedColumnIdentifier], unlisted: [SealedColumnIdentifier])
        /// A non-positive page size or row cap; the scan would have no bound to run under.
        case invalidBounds(pageSize: Int, rowCap: Int)
        /// The coordinator has no store attached — either before the scan (a `rebuildStore()` whose
        /// re-add has not healed yet) or, checked again on the way out, because the store was torn
        /// off DURING it. There is nothing to count, which is not the same as counting zero.
        case storeUnavailable
        /// The read-only wall: the scan finished with a dirty context, so something mutated the
        /// sealed store. Reported instead of the numbers, because a census that writes is not a
        /// census.
        case censusDirtiedTheContext

        public var description: String {
            switch self {
            case let .tableDoesNotMatchModel(missing, unlisted):
                return "The sealed-column census table does not match the model — missing: \(missing), unlisted: \(unlisted)."
            case let .invalidBounds(pageSize, rowCap):
                return "The sealed-column census needs a positive page size and row cap (got \(pageSize), \(rowCap))."
            case .storeUnavailable:
                return "The sealed store is not loaded — there is nothing to census."
            case .censusDirtiedTheContext:
                return "The sealed-column census left unsaved changes; it must be read-only."
            }
        }
    }

    // MARK: - Drift guard

    /// Fails when ``censusedEntities`` and `model` disagree in either direction.
    ///
    /// Called up front by ``run(controller:pageSize:rowCap:)``, before a single row is read, so a
    /// drifted table stops the census rather than producing a number that quietly omits a column.
    /// A missing entry also covers a column that exists but is no longer
    /// `.binaryDataAttributeType`: the classifier reads `Data`, and an attribute of some other
    /// type would land every row in ``SealedColumnFormatTally/indeterminate`` for a reason the
    /// caller could only guess at.
    ///
    /// - Parameter model: The live managed-object model to check the table against.
    /// - Throws: ``Failure/tableDoesNotMatchModel(missing:unlisted:)``, with both directions listed.
    public static func verifyTable(matches model: NSManagedObjectModel) throws {
        var missing: [SealedColumnIdentifier] = []
        for column in censusedColumns {  // R2: bounded by the seven-entry static table.
            let attribute = model.entitiesByName[column.entityName]?.attributesByName[column.attributeName]
            if attribute?.attributeType != .binaryDataAttributeType {
                missing.append(column)
            }
        }
        let listed = Set(censusedColumns)
        var unlisted: [SealedColumnIdentifier] = []
        for entity in model.entities {  // R2: bounded by the model's finite entity list.
            guard let entityName = entity.name else { continue }
            for attributeName in entity.attributesByName.keys where attributeName.hasSuffix(ciphertextAttributeSuffix) {
                let column = SealedColumnIdentifier(entityName: entityName, attributeName: attributeName)
                if !listed.contains(column) { unlisted.append(column) }
            }
        }
        guard missing.isEmpty, unlisted.isEmpty else {
            throw Failure.tableDoesNotMatchModel(missing: missing.sorted(), unlisted: unlisted.sorted())
        }
    }

    // MARK: - Census

    /// Counts every sealed ciphertext column by at-rest format.
    ///
    /// - Parameters:
    ///   - controller: The sealed stack to census. Injectable so tests can pass an isolated
    ///     in-memory or scratch-URL controller; production passes the shared one.
    ///   - pageSize: Rows faulted in per batch. Defaults to ``defaultPageSize``.
    ///   - rowCap: Hard ceiling on rows visited. Defaults to ``defaultRowCap``.
    /// - Returns: Per-column tallies plus the bounds the scan ran under.
    /// - Throws: ``Failure`` when the number cannot honestly be produced, or the underlying Core
    ///   Data fetch error.
    ///
    /// - Important: ``Failure/storeUnavailable`` is checked **twice**, before and after the scan,
    ///   and the second check is the load-bearing one. A `rebuildStore()` or a delete-all can tear
    ///   the store off the coordinator while the scan is walking pages; every subsequent fault then
    ///   fails, and with `shouldDeleteInaccessibleFaults` those failures are silent (see
    ///   ``classify(value:readFrom:)``). The per-value discriminator turns them into
    ///   ``SealedColumnFormatTally/indeterminate`` rather than empties, and this second guard
    ///   refuses to report the resulting numbers at all — a census taken across a detach is a
    ///   reading of nothing, not a reading of zero.
    public static func run(
        controller: PrivatePersistenceController,
        pageSize: Int = defaultPageSize,
        rowCap: Int = defaultRowCap
    ) throws -> SealedColumnFormatCensusResult {
        guard pageSize > 0, rowCap > 0 else {
            throw Failure.invalidBounds(pageSize: pageSize, rowCap: rowCap)
        }
        guard controller.isStoreLoaded else { throw Failure.storeUnavailable }
        try verifyTable(matches: controller.container.managedObjectModel)

        // A FRESH background context, never `viewContext`: the app's long-lived repositories hold
        // registered objects on the view context, and refreshing those out from under them to
        // release blobs would be a side effect on live state. This context is thrown away when the
        // scan returns.
        let context = controller.container.newBackgroundContext()
        context.automaticallyMergesChangesFromParent = false
        let result = try context.performAndWait {
            try scan(in: context, pageSize: pageSize, rowCap: rowCap)
        }
        // The second half of the guard above: the store may have gone away UNDER the scan.
        guard controller.isStoreLoaded else { throw Failure.storeUnavailable }
        return result
    }

    /// Walks the table entity by entity, folding per-entity tallies into one result.
    private static func scan(
        in context: NSManagedObjectContext,
        pageSize: Int,
        rowCap: Int
    ) throws -> SealedColumnFormatCensusResult {
        var columns: [SealedColumnIdentifier: SealedColumnFormatTally] = [:]
        for column in censusedColumns { columns[column] = SealedColumnFormatTally() }
        var rowsScanned = 0
        var rowsAvailable = 0
        var truncated = false
        for entity in censusedEntities {  // R2: bounded by the four-entry static table.
            let budget = max(rowCap - rowsScanned, 0)
            let outcome = try scanEntity(entity, in: context, pageSize: pageSize, rowBudget: budget)
            for (column, tally) in outcome.tallies {  // R2: bounded by the entity's column list.
                columns[column] = (columns[column] ?? SealedColumnFormatTally()) + tally
            }
            rowsScanned += outcome.rowsScanned
            rowsAvailable += outcome.rowsAvailable
            truncated = truncated || outcome.rowsScanned < outcome.rowsAvailable
        }
        guard !context.hasChanges else { throw Failure.censusDirtiedTheContext }
        return SealedColumnFormatCensusResult(
            columns: columns,
            rowsScanned: rowsScanned,
            rowsAvailable: rowsAvailable,
            truncated: truncated,
            rowCap: rowCap
        )
    }

    /// What one entity's scan produced.
    private struct EntityScanOutcome {
        var tallies: [SealedColumnIdentifier: SealedColumnFormatTally]
        var rowsScanned: Int
        var rowsAvailable: Int
    }

    /// Scans up to `rowBudget` rows of one entity, a page at a time, releasing each row's faulted
    /// blobs before moving on.
    ///
    /// The row count comes from a keyless `count(for:)` first, so truncation is exact (`scanned <
    /// available`) rather than inferred from having hit the cap — a store holding exactly `rowCap`
    /// rows is complete, not truncated. No sort descriptor: which subset a truncated scan sees is
    /// arbitrary, and saying so via `truncated` is more honest than an ordering that would imply
    /// the census walked the corpus in a meaningful sequence.
    private static func scanEntity(
        _ entity: SealedEntityColumns,
        in context: NSManagedObjectContext,
        pageSize: Int,
        rowBudget: Int
    ) throws -> EntityScanOutcome {
        var tallies: [SealedColumnIdentifier: SealedColumnFormatTally] = [:]
        for column in entity.columns { tallies[column] = SealedColumnFormatTally() }
        let available = try context.count(for: NSFetchRequest<NSManagedObject>(entityName: entity.entityName))
        let limit = min(max(available, 0), rowBudget)
        guard limit > 0 else {
            return EntityScanOutcome(tallies: tallies, rowsScanned: 0, rowsAvailable: max(available, 0))
        }

        let request = NSFetchRequest<NSManagedObject>(entityName: entity.entityName)
        request.fetchLimit = limit
        request.fetchBatchSize = pageSize
        request.returnsObjectsAsFaults = true
        let rows = try context.fetch(request)

        let scannable = min(rows.count, limit)
        let pageCount = (scannable + pageSize - 1) / pageSize
        var rowsScanned = 0
        for page in 0..<pageCount {  // R2: bound computed from the fetch limit before the loop.
            let start = page * pageSize
            let end = min(start + pageSize, scannable)
            guard start < end else { break }
            autoreleasepool {
                for index in start..<end {  // R2: bounded by this page's window.
                    let row = rows[index]
                    classify(row: row, of: entity, into: &tallies)
                    // Straight back to a fault: releases the (possibly externalized, possibly
                    // hundreds-of-KB) blob this row just faulted in. `mergeChanges: false` is safe
                    // precisely because this context never has changes to merge.
                    context.refresh(row, mergeChanges: false)
                }
            }
            rowsScanned = end
        }
        return EntityScanOutcome(tallies: tallies, rowsScanned: rowsScanned, rowsAvailable: max(available, 0))
    }

    /// Classifies one row's ciphertext columns by marker byte, counting anything unreadable as
    /// ``SealedColumnFormatTally/indeterminate`` rather than dropping it.
    ///
    /// Readability is judged by ``classify(value:readFrom:)`` **after** each value is read, not
    /// once before the loop — see that method for why the order is the whole point.
    private static func classify(
        row: NSManagedObject,
        of entity: SealedEntityColumns,
        into tallies: inout [SealedColumnIdentifier: SealedColumnFormatTally]
    ) {
        for attributeName in entity.ciphertextAttributeNames {  // R2: the static per-entity list.
            let column = SealedColumnIdentifier(entityName: entity.entityName, attributeName: attributeName)
            switch classify(value: row.value(forKey: attributeName), readFrom: row) {
            case let .classified(format):
                tallies[column, default: SealedColumnFormatTally()].count(format)
            case .indeterminate:
                tallies[column, default: SealedColumnFormatTally()].countIndeterminate()
            }
        }
    }

    /// Decides what ONE already-read column value is worth, given the state its row was left in by
    /// the read itself.
    ///
    /// ## Why the order matters (the unfulfillable-fault trap)
    ///
    /// The scan fetches rows as faults and touches one attribute per column, so every read can
    /// fault a row in — and a fault can fail. Core Data's `shouldDeleteInaccessibleFaults` (ON by
    /// default) handles that failure by marking the object **deleted** and answering `nil` for every
    /// attribute, silently: no throw, no signal at the call site. A row deleted by another context,
    /// a store torn off the coordinator by a concurrent `rebuildStore()`/delete-all, or a device
    /// that auto-locks mid-scan under `FileProtection.complete` all land there.
    ///
    /// A readability check taken BEFORE the read cannot see any of that — the row is perfectly
    /// healthy until the fault is fulfilled — so a corpus that was never actually read would be
    /// counted as a confident pile of ``ColumnCryptoStoredFormat/empty``, which is exactly the clean
    /// zero the Phase 3 gate must never be handed. Taking `isDeleted` / `managedObjectContext`
    /// afterwards is what turns that silence into ``SealedColumnFormatTally/indeterminate``; the
    /// `shouldDeleteInaccessibleFaults` path sets `isDeleted`, so it is the exact discriminator.
    ///
    /// Public so the discriminator itself is testable: the race is not deterministically
    /// constructible from outside the scan, but a genuinely deleted row is, and this is the seam
    /// where a `nil` value from one becomes a bucket.
    ///
    /// - Parameters:
    ///   - value: What `value(forKey:)` returned for the column, read BEFORE this call.
    ///   - row: The row it was read from, inspected AFTER that read.
    /// - Returns: The bucket, or ``SealedColumnReadOutcome/indeterminate`` when the row could not
    ///   vouch for the value it just handed over.
    public static func classify(value: Any?, readFrom row: NSManagedObject) -> SealedColumnReadOutcome {
        // AFTER the read, deliberately: an unfulfillable fault answers nil and marks itself deleted.
        guard !row.isDeleted, row.managedObjectContext != nil else { return .indeterminate }
        guard let value else { return .classified(.empty) }
        // Something is stored here that is not bytes — a model/type drift the census must report
        // rather than quietly treat as "no legacy row here".
        guard let data = value as? Data else { return .indeterminate }
        return .classified(ColumnCryptoStoredFormat.classify(data))
    }
}
