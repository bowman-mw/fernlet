// PendingNarrativeBufferFormatCensus.swift
// Fernlet
//
// Phase 0 of Docs/Plan-Crypto-Standardization-2026-08-27.md for the PendingNarrativeBuffer surface:
// answer "is there still a pre-91c3956 legacy buffer blob on this device?" WITHOUT decrypting it,
// without touching the keychain, and without writing a single byte.

import Foundation

/// A read-only, key-free reading of which on-disk format one ``PendingNarrativeBuffer`` file is in.
///
/// ## Why this type exists
///
/// `PendingNarrativeBuffer.loadEntries()` still carries a `// cryptographic-domain: legacy-read`
/// branch: a file written before `91c3956` is a bare `ChaChaPoly` box sealed with **no** associated
/// data, while every file written since is the four cleartext bytes `FNB2` followed by a box bound
/// to `FernletCryptoPurpose.AEAD.pendingNarrativeBufferV2`. That branch cannot simply be deleted —
/// the bytes it opens are the user's cycle notes, written while the app lock was engaged, on a phone
/// they still own. Deleting the reader would not standardize those bytes; it would make them
/// unopenable. So the plan's shape is *migrate, prove, then delete*, and this census is the "prove"
/// half's precondition: nothing can be deleted until the number of legacy blobs is known and has
/// been observed to reach zero on a real device that upgraded from a pre-`91c3956` build.
///
/// ## What the number is, and why it is a 0-or-1
///
/// The buffer keeps **one** file per ``PendingNarrativeStorageScope`` —
/// `<scope.directory>/pending-narratives.bin`, named in exactly one place
/// (``PendingNarrativeBuffer/fileURL(in:)``, which this census reuses rather than re-spelling) —
/// and it seals the *entire* entry array as a single box on every save. There is no per-entry
/// framing on disk, so "how many legacy blobs" is a property of the whole file: it is one, or it is
/// none. Counting the ≤50 individual entries would require the buffer key and a decrypt, which this
/// census refuses to do; and it would answer the wrong question anyway, because the migration unit
/// is the file — one re-seal converts every entry in it at once.
///
/// ## The classification rule is the reader's own rule
///
/// Classification is defined as *what `loadEntries()` will decide*, not as an independent opinion:
/// both test the first four bytes against the same ``PendingNarrativeBuffer`` constant, before any
/// key is fetched. That equivalence is the point — a census that classified by some cleverer rule
/// could report "no legacy bytes" about a file the shipping reader would still send down the legacy
/// branch. Two consequences follow, and both are honest limits rather than bugs:
///
/// - **Corrupt or truncated bytes land in ``Format/legacyUnprefixed``.** A three-byte scribble is not a valid
///   box under either format, but it carries no `FNB2` marker, so the reader would take it down the
///   legacy branch and fail to open it — and so this census calls it legacy. ``Format/legacyUnprefixed`` is
///   therefore an *upper bound* on true legacy blobs, which is the safe direction to be wrong in: it
///   can delay the Phase-3 deletion, never license it early.
/// - **A legacy box whose first four nonce bytes happen to spell `FNB2` is called v2.** ChaChaPoly
///   nonces are random, so this is a 2⁻³² accident, and it is deliberately not engineered around:
///   the shipping reader would misread that same file identically (strip four bytes, attempt a v2
///   open, throw), so the census keeps telling the truth about the reader's behavior. Engineering a
///   disambiguation here would only make the census disagree with the code it is measuring.
///
/// ## Absent is not unreadable
///
/// These are two different answers to the Phase-0 question and the whole census is worthless if
/// they are conflated:
///
/// - ``Format/absent`` — there is no file. This is the **common, legitimate zero**: a user who never
///   logged a narrative while the app lock was engaged never causes one to be written. It is real
///   evidence of "no legacy bytes here".
/// - ``Format/unreadable(reason:)`` — a file exists and its first bytes could not be read. This is
///   **indeterminate**, and it must never be scored as a zero. The buffer applies
///   `URLFileProtection.complete` best-effort after each write, so a census taken while the *device*
///   is locked can legitimately fail to open a file that is perfectly fine. (Fernlet's own app lock
///   is irrelevant here by design — the buffer exists precisely to be writable while the app lock is
///   engaged, and its key is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — but the device
///   lock is not.) Scoring that as zero would manufacture exactly the false "census = 0" proof that
///   Phase 3 deletes the legacy reader on.
///
/// ``isProvenLegacyFree`` encodes that distinction; ``indeterminateCount`` keeps it visible, and
/// ``legacyCount`` is `Int?` rather than `Int` so an unclassifiable file cannot be summed into a
/// total as if it were a zero.
///
/// One residual caveat rides on that split, and it is the reason a Phase-3 zero must be taken on an
/// **unlocked** device rather than opportunistically in the background: absent-vs-unreadable is
/// decided by `fileExists(atPath:)`, which answers from file *metadata* — readable today even when
/// data protection is denying the contents. If that ever stopped being true, a protected file would
/// be reported ``Format/absent``, which is precisely the false zero this type exists to prevent.
///
/// ## Read-only, key-free, bounded
///
/// - **No writes.** Unlike `saveEntries(_:)`, this never calls `createDirectory` — a census of a
///   scope whose directory does not exist leaves the disk exactly as it found it, and reports
///   ``Format/absent``. Nothing here creates, renames, truncates or deletes.
/// - **No keychain.** The buffer mints its 256-bit key on first *use*, so merely asking for the key
///   would be a write. Classification never asks: it reads four cleartext bytes. That is also what
///   makes the census usable at times the key is not available.
/// - **Bounded.** One `open`, one `read(upToCount: 4)`, one `close`. There is no loop at all, so
///   there is no scan whose length depends on the data (the house's Power-of-10 rule 2, satisfied by
///   construction rather than by a named cap).
///
/// A reading is a snapshot: a concurrent `purge()` between the failed open and the existence check
/// can turn a file that existed into ``Format/absent``. Nothing here mutates, so the worst outcome
/// is a stale answer, and the buffer's single-instance/main-actor discipline makes even that
/// unlikely.
public struct PendingNarrativeBufferFormatCensus: Sendable, Equatable {

    // MARK: - The five buckets

    /// What one buffer file is, decided purely by existence, emptiness, and its first four bytes.
    ///
    /// Deliberately five cases rather than a `Bool` plus an error: `absent`, `empty` and
    /// `v2Marked` are three genuinely different ways to be legacy-free, and collapsing them would
    /// hide which one a device is actually in — `absent` says the user never buffered a note,
    /// `empty` says a zero-byte file is lying around (the reader treats it as no entries), and
    /// `v2Marked` says the migration target has been reached for real bytes.
    ///
    /// Case names deliberately echo the other Phase-0 surfaces' censuses (`v2Marked`,
    /// `legacyUnprefixed`, an indeterminate bucket) so the six per-surface numbers can be read side
    /// by side without a translation table.
    public enum Format: Sendable, Equatable {
        /// No file at `<scope.directory>/pending-narratives.bin`. The legitimate, common zero.
        case absent

        /// The file exists but holds zero bytes. `loadEntries()` short-circuits on this exact
        /// condition and returns no entries, so it is legacy-free — but it is not the same fact as
        /// `absent`, and a device reporting it is worth a second look, since the buffer's atomic
        /// write never produces an empty file.
        case empty

        /// The file begins with the cleartext `FNB2` marker: the current whole-file format, sealed
        /// under the `pendingNarrativeBufferV2` associated data. This is the migration target.
        case v2Marked

        /// The file is non-empty and does NOT begin with the marker: the pre-`91c3956` shape, a bare
        /// `ChaChaPoly` combined box with no associated data. See the type's note on corrupt bytes —
        /// this bucket is an upper bound, since anything unmarked lands here exactly as it would in
        /// the reader.
        case legacyUnprefixed

        /// A file exists but its first bytes could not be read — most plausibly data protection
        /// while the device is locked. **Indeterminate, never a zero.**
        ///
        /// `reason` is a diagnostic rendering of the underlying error for a DEBUG surface only. It
        /// is not user-facing copy, must not be parsed, and makes ``Format`` equality
        /// message-sensitive: compare with ``isUnreadable`` when the fact, not the phrasing, is what
        /// matters.
        case unreadable(reason: String)

        /// `true` for ``unreadable(reason:)`` regardless of the diagnostic message it carries.
        public var isUnreadable: Bool {
            if case .unreadable = self { return true }
            return false
        }
    }

    // MARK: - The reading

    /// Which format the file was in when the census was taken.
    public let format: Format

    /// The exact file the reading is about, resolved through ``PendingNarrativeBuffer/fileURL(in:)``
    /// so a census can never report on a different file than the buffer would read.
    public let fileURL: URL

    /// Creates a reading directly. Public so a DEBUG diagnostic surface can hold an expected value
    /// (and so tests can write one) without a file on disk; the real readings come from
    /// ``take(of:)``.
    public init(format: Format, fileURL: URL) {
        self.format = format
        self.fileURL = fileURL
    }

    // MARK: - The marker

    /// The four cleartext bytes (`FNB2`) that mark the current whole-file format, re-exported from
    /// ``PendingNarrativeBuffer`` rather than re-spelled here.
    ///
    /// Sharing the constant is load-bearing: a census with its own copy of the marker would keep
    /// reporting "v2" after someone changed the writer's prefix, which is the exact failure mode
    /// Phase 0 exists to prevent. The bytes are not secret — they sit in the clear at offset 0 of
    /// every file the shipping writer produces — so exposing them publicly costs nothing and lets a
    /// diagnostic surface (and the test suite) pin the on-disk shape.
    public static let versionTwoMarker: Data = PendingNarrativeBuffer.sealedFormatV2

    /// How many bytes the classification actually needs. The whole read.
    private static var markerByteCount: Int { versionTwoMarker.count }

    // MARK: - Taking the census

    /// Classifies the buffer file belonging to `scope`.
    ///
    /// Takes the whole ``PendingNarrativeStorageScope`` — not just its directory — for the same
    /// reason ``PendingNarrativeBuffer`` does: the scope is the buffer's one storage identity, and a
    /// census parameterized on something narrower could drift onto a file the buffer never reads.
    /// The scope's `keychainService` half is deliberately **unused** here, and that is the point: it
    /// is carried past this function untouched, because classification must never fetch (and
    /// therefore never mint) the buffer key.
    public static func take(of scope: PendingNarrativeStorageScope) -> PendingNarrativeBufferFormatCensus {
        take(inDirectory: scope.directory)
    }

    /// Classifies the buffer file in `directory` — the scope-free half, for a diagnostic that has
    /// only a path (e.g. an inspected backup root) rather than a live scope.
    ///
    /// Never creates `directory`. A missing directory is simply a missing file: ``Format/absent``.
    public static func take(inDirectory directory: URL) -> PendingNarrativeBufferFormatCensus {
        let url = PendingNarrativeBuffer.fileURL(in: directory)

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            // The open failed for one of two very different reasons, and the census's whole value
            // depends on telling them apart: nothing is there (a real zero), or something is there
            // that we could not look at (indeterminate — typically data protection with the device
            // locked). `fileExists` answers that from metadata alone, no read required.
            guard FileManager.default.fileExists(atPath: url.path) else {
                return PendingNarrativeBufferFormatCensus(format: .absent, fileURL: url)
            }
            return PendingNarrativeBufferFormatCensus(format: .unreadable(reason: "\(error)"), fileURL: url)
        }
        defer { try? handle.close() }

        let prefix: Data?
        do {
            // A single bounded read of the marker's length. For a regular file this returns fewer
            // bytes only at EOF, so no loop is needed to "fill" the request — and a short file
            // simply cannot equal the marker, which is exactly the reader's own conclusion.
            prefix = try handle.read(upToCount: markerByteCount)
        } catch {
            // A file that opened but would not yield its first bytes is still indeterminate, for
            // the same reason: an unreadable file must never be counted as a clean zero.
            return PendingNarrativeBufferFormatCensus(format: .unreadable(reason: "\(error)"), fileURL: url)
        }

        guard let prefix, !prefix.isEmpty else {
            return PendingNarrativeBufferFormatCensus(format: .empty, fileURL: url)
        }

        // The one classification rule, mirroring `loadEntries()`'s `starts(with:)` test exactly.
        return PendingNarrativeBufferFormatCensus(
            format: prefix == versionTwoMarker ? .v2Marked : .legacyUnprefixed,
            fileURL: url
        )
    }

    // MARK: - Phase-0 numbers

    /// **The Phase-0 number.** Legacy blobs on this surface: 0 or 1 — or `nil` when the file could
    /// not be classified at all.
    ///
    /// `Int?` rather than `Int`, and that is the whole safety property of this API: an unreadable
    /// file returning `0` would read, in a summary line or a sum across surfaces, exactly like a
    /// clean device. It is not one. Phase 3 (deleting the legacy reader) is gated on observing this
    /// at `0` — never on `nil`, and never on a total that quietly absorbed a `nil` as a zero.
    public var legacyCount: Int? {
        switch format {
        case .legacyUnprefixed:        return 1
        case .absent, .empty, .v2Marked: return 0
        case .unreadable:              return nil
        }
    }

    /// Blobs already in the current format: 0 or 1, `nil` when indeterminate, for the same reason.
    public var versionTwoCount: Int? {
        switch format {
        case .v2Marked:                       return 1
        case .absent, .empty, .legacyUnprefixed: return 0
        case .unreadable:                     return nil
        }
    }

    /// Files that exist but could not be classified: 0 or 1. A non-zero value means the census did
    /// not produce an answer for this device and must be retaken (e.g. with the device unlocked) —
    /// it does not mean "clean".
    public var indeterminateCount: Int { format.isUnreadable ? 1 : 0 }

    /// `true` when this reading contributes no answer, only a blind spot.
    public var isIndeterminate: Bool { format.isUnreadable }

    /// `true` only when the census actually determined the format AND found nothing legacy.
    ///
    /// The asymmetry is deliberate: ``Format/absent``, ``Format/empty`` and ``Format/v2Marked`` are
    /// positive evidence, while ``Format/unreadable(reason:)`` is the absence of evidence and scores
    /// `false`. "We could not look" must never read the same as "we looked and it was clean".
    public var isProvenLegacyFree: Bool {
        switch format {
        case .absent, .empty, .v2Marked:
            return true
        case .legacyUnprefixed, .unreadable:
            return false
        }
    }
}
