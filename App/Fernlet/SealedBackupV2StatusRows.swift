import CloudKitSync
import FernletUI
import SwiftUI

/// One explicit Sealed backup choice a status row offers (design 2026-09-30, §4.6). The parent screen
/// confirms it, then records it as an in-memory intent the next Private visit carries out.
enum SealedBackupV2RowChoice: Equatable {
    /// "Restore it here" for exactly this set (another iPhone's).
    case restoreHere(SealedBackupHeadStamp)
    /// "Restore anyway" for exactly this set (refused as older).
    case restoreAnyway(SealedBackupHeadStamp)
    /// "Replace it with this iPhone's …" for exactly this set.
    case replace(SealedBackupHeadStamp)
    /// "Start a new backup" over a set this iPhone cannot open.
    case startNew
    /// "Remove them" for exactly these unopenable ids.
    case remove([UUID])
}

/// One payload's Sealed backup rows inside Privacy & Data's backup banner (journal and intimacy
/// Sealed backup v2 design 2026-09-30, §10.1): one sentence per ``SealedBackupV2RowState``, with the
/// choices that state offers — the intimate logs' (unit B2) and the journal's (unit B3), each through
/// its own ``SealedBackupV2RowCopy``.
///
/// The parent shows the intimate-log rows only while intimacy tracking is visible and no duress
/// session runs, and the journal rows only outside a duress session (``FernletStore/intimacyBackupRowState``
/// and ``FernletStore/journalBackupRowState`` answer `.none` otherwise, BV17, BV18), so nothing here
/// ever names a hidden surface. Each sentence is a whole catalog entry (never a spliced noun: it could
/// not agree in gender or case in fr, de or es), each row is one accessibility element, and every
/// button is at least 44 pt with a hint; the destructive choices are confirmed by the parent with a
/// destructive role. Nothing here decrypts, fetches or persists anything.
struct SealedBackupV2StatusRows: View {
    /// The payload's sentences, button titles, hints and frozen identifiers.
    let copy: SealedBackupV2RowCopy
    /// The row to show.
    let state: SealedBackupV2RowState
    /// Whether a choice is being recorded (the buttons wait).
    let isBusy: Bool
    /// Asks the parent to confirm and record `choice`.
    let onChoice: (SealedBackupV2RowChoice) -> Void

    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .heldByAnotherDevice(let stamp):
            VStack(alignment: .leading, spacing: 10) {
                line(stamp.writer == SealedBackupHeadStamp.v1Writer ? copy.heldByEarlierFernlet : copy.heldByAnotherDevice,
                     identifier: copy.identifier("heldByAnotherDevice"))
                choiceButton(copy.restoreHere, identifier: copy.identifier("restoreHere")) { onChoice(.restoreHere(stamp)) }
                choiceButton(copy.replace, identifier: copy.identifier("replace")) { onChoice(.replace(stamp)) }
            }
        case .olderThanSeen(let stamp):
            VStack(alignment: .leading, spacing: 10) {
                line(copy.olderThanSeen, identifier: copy.identifier("waitingForRestore"))
                choiceButton(copy.restoreAnyway, identifier: copy.identifier("restoreAnyway")) { onChoice(.restoreAnyway(stamp)) }
                choiceButton(copy.replace, identifier: copy.identifier("replace")) { onChoice(.replace(stamp)) }
            }
        default:
            stateLines
        }
    }

    /// The rows with at most a "Start a new backup" choice.
    @ViewBuilder
    private var stateLines: some View {
        switch state {
        case .finishing:
            line(Text("Open Private to finish.", comment: "Privacy & Data: a Sealed backup choice waits for the next visit to the Private tab."),
                 identifier: copy.identifier("finishing"))
        case .waitingForRestore:
            line(copy.waitingForRestore, identifier: copy.identifier("waitingForRestore"))
        case .waitingForKey(let restoring):
            VStack(alignment: .leading, spacing: 10) {
                line(restoring ? copy.waitingForKeyRestoring : copy.waitingForKeyExporting,
                     identifier: copy.identifier("waitingForBackupKey"))
                startNewButton
            }
        case .sealedWithOtherKey:
            VStack(alignment: .leading, spacing: 10) {
                line(copy.sealedWithOtherKey, identifier: copy.identifier("headSealedWithOtherKey"))
                startNewButton
            }
        case .damaged:
            VStack(alignment: .leading, spacing: 10) {
                line(copy.damaged, identifier: copy.identifier("headDamaged"))
                startNewButton
            }
        default:
            noticeLines
        }
    }

    /// The rows that only report (and "Remove them").
    @ViewBuilder
    private var noticeLines: some View {
        switch state {
        case .needsNewerFernlet:
            line(copy.needsNewerFernlet, identifier: copy.identifier("needsNewerFernlet"))
        case .paused(let ids):
            VStack(alignment: .leading, spacing: 10) {
                line(copy.paused, identifier: copy.identifier("paused"))
                choiceButton(copy.remove, identifier: copy.identifier("removeUnopenable")) { onChoice(.remove(ids)) }
            }
        case .tooLarge:
            line(copy.tooLarge, identifier: copy.identifier("tooLarge"))
        case .failed:
            line(copy.failed, identifier: copy.identifier("failed"))
        case .catchUp:
            // The pre-v2 deferral line's identifier, kept for the catch-up line (§10.3).
            line(copy.catchUp, identifier: copy.catchUpIdentifier)
        default:
            EmptyView()
        }
    }

    /// "Start a new backup" over a set this iPhone cannot open.
    private var startNewButton: some View {
        choiceButton(copy.startNew, identifier: copy.identifier("startNew")) { onChoice(.startNew) }
    }

    /// One status sentence: one accessibility element, wrapping at every text size.
    private func line(_ text: Text, identifier: String) -> some View {
        text.modifier(SealedBackupRowLineStyle(identifier: identifier))
    }

    /// One choice button: at least 44 pt, with its hint, waiting while a choice is recorded.
    private func choiceButton(_ button: SealedBackupV2RowCopy.Choice, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            button.title
                .frame(maxWidth: .infinity)
                .fernletWrappingText()
        }
        .buttonStyle(.plain)
        .font(.fernlet(.label))
        .foregroundStyle(Color.onMoss)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
        .background(Color.mossFill.opacity(isBusy ? 0.55 : 1), in: RoundedRectangle(cornerRadius: 12))
        .disabled(isBusy)
        .accessibilityHint(button.hint)
        .accessibilityIdentifier(identifier)
    }
}

/// One payload's words for ``SealedBackupV2StatusRows`` (design 2026-09-30, §10.1–§10.3): every
/// sentence a whole catalog entry, written for its kind (never a spliced noun), and the frozen
/// accessibility identifiers (`<prefix>.<state>` — tokens, never localized).
struct SealedBackupV2RowCopy {
    /// A choice button's title and its VoiceOver hint.
    struct Choice {
        /// The visible title.
        let title: Text
        /// The accessibility hint.
        let hint: Text
    }

    /// The identifier prefix (`privacy.sealedBackup.intimacy`, `privacy.sealedBackup.journal`).
    let identifierPrefix: String
    /// The catch-up line's identifier — the pre-v2 deferral line's, kept (§10.3).
    let catchUpIdentifier: String
    /// The set in iCloud is another iPhone's.
    let heldByAnotherDevice: Text
    /// The set in iCloud was written by an earlier Fernlet that named no iPhone (review U5-backup-v2-C-U5-4).
    let heldByEarlierFernlet: Text
    /// The restore refused a set older than one this iPhone has seen.
    let olderThanSeen: Text
    /// This install has not pulled its backup yet.
    let waitingForRestore: Text
    /// A restore waits for its key from iCloud Keychain.
    let waitingForKeyRestoring: Text
    /// An export waits for its key from iCloud Keychain.
    let waitingForKeyExporting: Text
    /// The set is sealed with a key this iPhone lacks.
    let sealedWithOtherKey: Text
    /// The set will not authenticate.
    let damaged: Text
    /// The set, or an entry here, needs a newer Fernlet.
    let needsNewerFernlet: Text
    /// Entries this iPhone cannot open pause the backup.
    let paused: Text
    /// Over the record or byte bound.
    let tooLarge: Text
    /// The last export failed.
    let failed: Text
    /// Changes the next Private visit backs up.
    let catchUp: Text
    /// "Restore it here".
    let restoreHere: Choice
    /// "Restore anyway".
    let restoreAnyway: Choice
    /// "Replace it with this iPhone's …".
    let replace: Choice
    /// "Start a new backup".
    let startNew: Choice
    /// "Remove them".
    let remove: Choice

    /// The identifier `<prefix>.<state>` (a frozen token).
    func identifier(_ state: String) -> String { "\(identifierPrefix).\(state)" }
}

extension SealedBackupV2RowCopy {
    /// The intimate-log backup's words (unit B2).
    static var intimacy: SealedBackupV2RowCopy {
        SealedBackupV2RowCopy(
            identifierPrefix: "privacy.sealedBackup.intimacy",
            catchUpIdentifier: "privacy.sealedBackup.intimacyDeferred",
            heldByAnotherDevice: Text("Your intimate log backup was saved from another iPhone. Backing up this iPhone would replace it.",
                                      comment: "Privacy & Data: the intimate-log Sealed backup belongs to another iPhone."),
            heldByEarlierFernlet: Text("Your intimate log backup in iCloud was saved by an earlier version of Fernlet, which didn't record which iPhone saved it. Backing up this iPhone would replace it.",
                                       comment: "Privacy & Data: the intimate-log Sealed backup was written by an earlier Fernlet that named no iPhone."),
            olderThanSeen: Text("The intimate log backup in iCloud is older than one this iPhone has already seen, so it wasn't added.",
                                comment: "Privacy & Data: the intimate-log Sealed backup restore refused a set older than one this iPhone has seen."),
            waitingForRestore: Text("Your intimate log backup will be added to this iPhone the next time you open Private. New logs are backed up after that.",
                                    comment: "Privacy & Data: this iPhone has not added its intimate-log Sealed backup yet."),
            waitingForKeyRestoring: Text("Your intimate log backup is waiting for its key from iCloud Keychain. Make sure iCloud Keychain is on. New logs aren't backed up until it arrives.",
                                         comment: "Privacy & Data: the intimate-log Sealed backup restore waits for its key from iCloud Keychain."),
            waitingForKeyExporting: Text("Your intimate log backup is waiting for its key from iCloud Keychain. Make sure iCloud Keychain is on.",
                                         comment: "Privacy & Data: the intimate-log Sealed backup export waits for its key from iCloud Keychain."),
            sealedWithOtherKey: Text("Your intimate log backup was saved with a key this iPhone doesn't have yet. It usually arrives through iCloud Keychain.",
                                     comment: "Privacy & Data: the intimate-log Sealed backup is sealed with a key this iPhone lacks."),
            damaged: Text("The intimate log backup in iCloud is damaged and can't be opened.",
                          comment: "Privacy & Data: the intimate-log Sealed backup will not authenticate."),
            needsNewerFernlet: Text("Some intimate logs or the intimate log backup need a newer version of Fernlet. Update Fernlet to keep backing up your intimate logs.",
                                    comment: "Privacy & Data: the intimate-log Sealed backup or a log needs a newer Fernlet."),
            paused: Text("Some intimate logs can't be opened on this iPhone, so your intimate log backup is paused.",
                         comment: "Privacy & Data: logs this iPhone cannot open pause the intimate-log Sealed backup."),
            tooLarge: Text("Your intimate logs are too large for Sealed backup.", comment: "Privacy & Data: the intimate-log Sealed backup is over its size bound."),
            failed: Text("Your intimate log backup didn't finish. It will try again when you next open Private.",
                         comment: "Privacy & Data: the last intimate-log Sealed backup export failed."),
            catchUp: Text("Your newest intimate logs will be added to Sealed backup the next time you open Private.",
                          comment: "Privacy & Data: intimate-log changes the next Private visit backs up."),
            restoreHere: Choice(title: Text("Restore it here", comment: "Privacy & Data: add another iPhone's Sealed backup (journal or intimate logs) to this iPhone."),
                                hint: Text("Adds the backup's logs to this iPhone the next time you open Private.", comment: "Accessibility hint for Restore it here on the intimate-log Sealed backup.")),
            restoreAnyway: Choice(title: Text("Restore anyway", comment: "Privacy & Data: restore an older Sealed backup (journal or intimate logs) anyway."),
                                  hint: Text("Adds the older backup's logs to this iPhone.", comment: "Accessibility hint for Restore anyway on the intimate-log Sealed backup.")),
            replace: Choice(title: Text("Replace it with this iPhone's intimate logs", comment: "Privacy & Data: back up this iPhone over the intimate-log Sealed backup in iCloud."),
                            hint: Text("Backs up this iPhone over the backup in iCloud.", comment: "Accessibility hint for Replace on a Sealed backup (journal or intimate logs).")),
            startNew: Choice(title: Text("Start a new backup", comment: "Privacy & Data: start a new Sealed backup (journal or intimate logs) over one this iPhone cannot open."),
                             hint: Text("Replaces a backup this iPhone can't open.", comment: "Accessibility hint for Start a new backup on a Sealed backup (journal or intimate logs).")),
            remove: Choice(title: Text("Remove them", comment: "Privacy & Data: remove the Sealed backup entries (journal or intimate logs) this iPhone cannot open."),
                           hint: Text("Checks the logs again, then deletes those that still can't be opened.", comment: "Accessibility hint for Remove them on the intimate-log Sealed backup."))
        )
    }

    /// The journal backup's words (unit B3).
    static var journal: SealedBackupV2RowCopy {
        SealedBackupV2RowCopy(
            identifierPrefix: "privacy.sealedBackup.journal",
            catchUpIdentifier: "privacy.sealedBackup.journalDeferred",
            heldByAnotherDevice: Text("Your journal backup was saved from another iPhone. Backing up this iPhone would replace it.",
                                      comment: "Privacy & Data: the journal Sealed backup belongs to another iPhone."),
            heldByEarlierFernlet: Text("Your journal backup in iCloud was saved by an earlier version of Fernlet, which didn't record which iPhone saved it. Backing up this iPhone would replace it.",
                                       comment: "Privacy & Data: the journal Sealed backup was written by an earlier Fernlet that named no iPhone."),
            olderThanSeen: Text("The journal backup in iCloud is older than one this iPhone has already seen, so it wasn't added.",
                                comment: "Privacy & Data: the journal Sealed backup restore refused a set older than one this iPhone has seen."),
            waitingForRestore: Text("Your journal backup will be added to this iPhone the next time you open Private. New entries are backed up after that.",
                                    comment: "Privacy & Data: this iPhone has not added its journal Sealed backup yet."),
            waitingForKeyRestoring: Text("Your journal backup is waiting for its key from iCloud Keychain. Make sure iCloud Keychain is on. New entries aren't backed up until it arrives.",
                                         comment: "Privacy & Data: the journal Sealed backup restore waits for its key from iCloud Keychain."),
            waitingForKeyExporting: Text("Your journal backup is waiting for its key from iCloud Keychain. Make sure iCloud Keychain is on.",
                                         comment: "Privacy & Data: the journal Sealed backup export waits for its key from iCloud Keychain."),
            sealedWithOtherKey: Text("Your journal backup was saved with a key this iPhone doesn't have yet. It usually arrives through iCloud Keychain.",
                                     comment: "Privacy & Data: the journal Sealed backup is sealed with a key this iPhone lacks."),
            damaged: Text("The journal backup in iCloud is damaged and can't be opened.",
                          comment: "Privacy & Data: the journal Sealed backup will not authenticate."),
            needsNewerFernlet: Text("Some journal entries or the journal backup need a newer version of Fernlet. Update Fernlet to keep backing up your journal.",
                                    comment: "Privacy & Data: the journal Sealed backup or an entry needs a newer Fernlet."),
            paused: Text("Some journal entries can't be opened on this iPhone, so your journal backup is paused.",
                         comment: "Privacy & Data: entries this iPhone cannot open pause the journal Sealed backup."),
            tooLarge: Text("Your journal is too large for Sealed backup.", comment: "Privacy & Data: the journal Sealed backup is over its size bound."),
            failed: Text("Your journal backup didn't finish. It will try again when you next open Private.",
                         comment: "Privacy & Data: the last journal Sealed backup export failed."),
            catchUp: Text("Your newest journal entries will be added to Sealed backup the next time you open Private.",
                          comment: "Privacy & Data: journal changes the next Private visit backs up."),
            restoreHere: Choice(title: Text("Restore it here", comment: "Privacy & Data: add another iPhone's Sealed backup (journal or intimate logs) to this iPhone."),
                                hint: Text("Adds the backup's entries to this iPhone the next time you open Private.", comment: "Accessibility hint for Restore it here on the journal Sealed backup.")),
            restoreAnyway: Choice(title: Text("Restore anyway", comment: "Privacy & Data: restore an older Sealed backup (journal or intimate logs) anyway."),
                                  hint: Text("Adds the older backup's entries to this iPhone.", comment: "Accessibility hint for Restore anyway on the journal Sealed backup.")),
            replace: Choice(title: Text("Replace it with this iPhone's journal", comment: "Privacy & Data: back up this iPhone over the journal Sealed backup in iCloud."),
                            hint: Text("Backs up this iPhone over the backup in iCloud.", comment: "Accessibility hint for Replace on a Sealed backup (journal or intimate logs).")),
            startNew: Choice(title: Text("Start a new backup", comment: "Privacy & Data: start a new Sealed backup (journal or intimate logs) over one this iPhone cannot open."),
                             hint: Text("Replaces a backup this iPhone can't open.", comment: "Accessibility hint for Start a new backup on a Sealed backup (journal or intimate logs).")),
            remove: Choice(title: Text("Remove them", comment: "Privacy & Data: remove the Sealed backup entries (journal or intimate logs) this iPhone cannot open."),
                           hint: Text("Checks the entries again, then deletes those that still can't be opened.", comment: "Accessibility hint for Remove them on the journal Sealed backup."))
        )
    }
}

/// The banner's status-sentence style: small body text in slate, wrapping, one accessibility element.
private struct SealedBackupRowLineStyle: ViewModifier {
    /// The row's accessibility identifier (a frozen token).
    let identifier: String

    func body(content: Content) -> some View {
        content
            .font(.fernlet(.bodySmall))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
    }
}
