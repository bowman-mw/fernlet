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

/// The intimate-log Sealed backup's rows inside Privacy & Data's backup banner (journal and intimacy
/// Sealed backup v2 design 2026-09-30, §10.1, unit B2): one sentence per ``SealedBackupV2RowState``,
/// with the choices that state offers.
///
/// The parent shows these rows only while intimacy tracking is visible and no duress session runs
/// (``FernletStore/intimacyBackupRowState`` answers `.none` otherwise, BV17), so nothing here ever
/// names intimacy while it is hidden. Each sentence is a whole catalog entry (never a spliced noun),
/// each row is one accessibility element, and every button is at least 44 pt with a hint; the
/// destructive choices are confirmed by the parent with a destructive role. Nothing here decrypts,
/// fetches or persists anything.
struct IntimacyBackupStatusRows: View {
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
                heldLine(stamp)
                restoreHereButton(stamp)
                replaceButton(stamp)
            }
        case .olderThanSeen(let stamp):
            VStack(alignment: .leading, spacing: 10) {
                line(Text("The intimate log backup in iCloud is older than one this iPhone has already seen, so it wasn't added.",
                          comment: "Privacy & Data: the intimate-log Sealed backup restore refused a set older than one this iPhone has seen."),
                     identifier: "privacy.sealedBackup.intimacy.waitingForRestore")
                choiceButton(Text("Restore anyway", comment: "Privacy & Data: restore an older intimate-log Sealed backup anyway."),
                             hint: Text("Adds the older backup's logs to this iPhone.", comment: "Accessibility hint for Restore anyway on the intimate-log Sealed backup."),
                             identifier: "privacy.sealedBackup.intimacy.restoreAnyway") { onChoice(.restoreAnyway(stamp)) }
                replaceButton(stamp)
            }
        default:
            stateLines
        }
    }

    /// The rows with at most a "Start a new backup" or "Remove them" choice.
    @ViewBuilder
    private var stateLines: some View {
        switch state {
        case .finishing:
            line(Text("Open Private to finish.", comment: "Privacy & Data: a Sealed backup choice waits for the next visit to the Private tab."),
                 identifier: "privacy.sealedBackup.intimacy.finishing")
        case .waitingForRestore:
            line(Text("Your intimate log backup will be added to this iPhone the next time you open Private. New logs are backed up after that.",
                      comment: "Privacy & Data: this iPhone has not added its intimate-log Sealed backup yet."),
                 identifier: "privacy.sealedBackup.intimacy.waitingForRestore")
        case .waitingForKey(let restoring):
            VStack(alignment: .leading, spacing: 10) {
                Group {
                    if restoring {
                        Text("Your intimate log backup is waiting for its key from iCloud Keychain. Make sure iCloud Keychain is on. New logs aren't backed up until it arrives.",
                             comment: "Privacy & Data: the intimate-log Sealed backup restore waits for its key from iCloud Keychain.")
                    } else {
                        Text("Your intimate log backup is waiting for its key from iCloud Keychain. Make sure iCloud Keychain is on.",
                             comment: "Privacy & Data: the intimate-log Sealed backup export waits for its key from iCloud Keychain.")
                    }
                }
                .modifier(RowLineStyle(identifier: "privacy.sealedBackup.intimacy.waitingForBackupKey"))
                startNewButton
            }
        case .sealedWithOtherKey:
            VStack(alignment: .leading, spacing: 10) {
                line(Text("Your intimate log backup was saved with a key this iPhone doesn't have yet. It usually arrives through iCloud Keychain.",
                          comment: "Privacy & Data: the intimate-log Sealed backup is sealed with a key this iPhone lacks."),
                     identifier: "privacy.sealedBackup.intimacy.headSealedWithOtherKey")
                startNewButton
            }
        case .damaged:
            VStack(alignment: .leading, spacing: 10) {
                line(Text("The intimate log backup in iCloud is damaged and can't be opened.",
                          comment: "Privacy & Data: the intimate-log Sealed backup will not authenticate."),
                     identifier: "privacy.sealedBackup.intimacy.headDamaged")
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
            line(Text("Some intimate logs or the intimate log backup need a newer version of Fernlet. Update Fernlet to keep backing up your intimate logs.",
                      comment: "Privacy & Data: the intimate-log Sealed backup or a log needs a newer Fernlet."),
                 identifier: "privacy.sealedBackup.intimacy.needsNewerFernlet")
        case .paused(let ids):
            VStack(alignment: .leading, spacing: 10) {
                line(Text("Some intimate logs can't be opened on this iPhone, so your intimate log backup is paused.",
                          comment: "Privacy & Data: logs this iPhone cannot open pause the intimate-log Sealed backup."),
                     identifier: "privacy.sealedBackup.intimacy.paused")
                choiceButton(Text("Remove them", comment: "Privacy & Data: remove the intimate logs this iPhone cannot open."),
                             hint: Text("Checks the logs again, then deletes those that still can't be opened.", comment: "Accessibility hint for Remove them on the intimate-log Sealed backup."),
                             identifier: "privacy.sealedBackup.intimacy.removeUnopenable") { onChoice(.remove(ids)) }
            }
        case .tooLarge:
            line(Text("Your intimate logs are too large for Sealed backup.", comment: "Privacy & Data: the intimate-log Sealed backup is over its size bound."),
                 identifier: "privacy.sealedBackup.intimacy.tooLarge")
        case .failed:
            line(Text("Your intimate log backup didn't finish. It will try again when you next open Private.",
                      comment: "Privacy & Data: the last intimate-log Sealed backup export failed."),
                 identifier: "privacy.sealedBackup.intimacy.failed")
        case .catchUp:
            // The pre-v2 deferral line's identifier, kept for the catch-up line (§10.3).
            line(Text("Your newest intimate logs will be added to Sealed backup the next time you open Private.",
                      comment: "Privacy & Data: intimate-log changes the next Private visit backs up."),
                 identifier: "privacy.sealedBackup.intimacyDeferred")
        default:
            EmptyView()
        }
    }

    /// The "saved from another iPhone" line. A set an earlier version of Fernlet wrote names no
    /// iPhone, so its line says so instead of guessing (review U5-backup-v2-C-U5-4).
    private func heldLine(_ stamp: SealedBackupHeadStamp) -> some View {
        Group {
            if stamp.writer == SealedBackupHeadStamp.v1Writer {
                Text("Your intimate log backup in iCloud was saved by an earlier version of Fernlet, which didn't record which iPhone saved it. Backing up this iPhone would replace it.",
                     comment: "Privacy & Data: the intimate-log Sealed backup was written by an earlier Fernlet that named no iPhone.")
            } else {
                Text("Your intimate log backup was saved from another iPhone. Backing up this iPhone would replace it.",
                     comment: "Privacy & Data: the intimate-log Sealed backup belongs to another iPhone.")
            }
        }
        .modifier(RowLineStyle(identifier: "privacy.sealedBackup.intimacy.heldByAnotherDevice"))
    }

    /// "Restore it here" for exactly `stamp`.
    private func restoreHereButton(_ stamp: SealedBackupHeadStamp) -> some View {
        choiceButton(Text("Restore it here", comment: "Privacy & Data: add another iPhone's intimate-log Sealed backup to this iPhone."),
                     hint: Text("Adds the backup's logs to this iPhone the next time you open Private.", comment: "Accessibility hint for Restore it here on the intimate-log Sealed backup."),
                     identifier: "privacy.sealedBackup.intimacy.restoreHere") { onChoice(.restoreHere(stamp)) }
    }

    /// "Replace it with this iPhone's intimate logs" for exactly `stamp`.
    private func replaceButton(_ stamp: SealedBackupHeadStamp) -> some View {
        choiceButton(Text("Replace it with this iPhone's intimate logs", comment: "Privacy & Data: back up this iPhone over the intimate-log Sealed backup in iCloud."),
                     hint: Text("Backs up this iPhone over the backup in iCloud.", comment: "Accessibility hint for Replace on the intimate-log Sealed backup."),
                     identifier: "privacy.sealedBackup.intimacy.replace") { onChoice(.replace(stamp)) }
    }

    /// "Start a new backup" over a set this iPhone cannot open.
    private var startNewButton: some View {
        choiceButton(Text("Start a new backup", comment: "Privacy & Data: start a new intimate-log Sealed backup over one this iPhone cannot open."),
                     hint: Text("Replaces a backup this iPhone can't open.", comment: "Accessibility hint for Start a new backup on the intimate-log Sealed backup."),
                     identifier: "privacy.sealedBackup.intimacy.startNew") { onChoice(.startNew) }
    }

    /// One status sentence: one accessibility element, wrapping at every text size.
    private func line(_ text: Text, identifier: String) -> some View {
        text.modifier(RowLineStyle(identifier: identifier))
    }

    /// One choice button: at least 44 pt, with its hint, waiting while a choice is recorded.
    private func choiceButton(_ title: Text, hint: Text, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            title
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
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }
}

/// The banner's status-sentence style: small body text in slate, wrapping, one accessibility element.
private struct RowLineStyle: ViewModifier {
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
