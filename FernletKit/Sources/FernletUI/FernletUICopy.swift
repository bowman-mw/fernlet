//
//  FernletUICopy.swift
//  FernletUI
//
//  The module's own copy vault (accessibility review 2026-08-22, §4.0).
//
//  WHY THIS EXISTS. FernletUI's stated architecture is that it takes `LocalizedStringKey`/`Text`
//  from its callers and owns no copy — and that is still the rule for anything a caller *names*
//  (a field caption, a save word, an empty-state line). But a shared component cannot push
//  everything outward: a DEFAULT value, a prompt every sheet must word identically, and copy that
//  renders from a modifier rather than from a call site all have to live here. Before this file
//  they lived here as bare literals, and a `LocalizedStringKey` literal written inside an SPM
//  module resolves against `Bundle.main` — the APP's bundle — which never consults the module's
//  own catalog. The build is clean, the English is right, and the string is untranslatable
//  forever. `SheetSaveBar`'s `"Save"` default documented that trap in its own doc comment and
//  survived only because the app catalog happened to carry the same key.
//
//  THE RULE, in two halves:
//    * Copy a CALLER names stays a caller parameter (`LocalizedStringKey`/`Text`), harvested into
//      the caller's own catalog. Unchanged — that is what `SectionLabel`, `SheetField`,
//      `EmptyState` and `SheetSaveBar`'s `label:` are.
//    * Copy the MODULE owns lives here, keyed, with `bundle: .module`, resolving against
//      `FernletKit/Sources/FernletUI/Localizable.xcstrings`.
//
//  `LocalizationBoundaryTests.packageDisplayLiteralsPassModuleBundle()` is the mechanical half: a
//  bare literal handed to a SwiftUI display initializer anywhere under `FernletKit/Sources` now
//  fails that test, so the next one cannot ship silently. Modelled on `FernletLockCopy`, which
//  solved the identical problem for `FernletLockUI`.
//

import Foundation

/// The copy `FernletUI` itself owns: shared verbs, the discard prompt, and the capture-cover line.
///
/// Every member resolves through `String(localized:bundle:.module)` against this module's own
/// string catalog, so it translates where a bare literal in the same position would not (see the
/// file header). Members are computed rather than stored so the lookup happens at *use* time,
/// under the user's current locale, rather than once at first access — a stored `static let`
/// would freeze the language a process launched in.
///
/// Resolved `String`s, not `LocalizedStringKey`s, deliberately: a `LocalizedStringKey` carries no
/// bundle, so handing one to SwiftUI would put the lookup back in `Bundle.main` and undo the fix.
/// The resolved string reaches SwiftUI through the `StringProtocol` overloads
/// (`Text(verbatim:)`, `Button(_ title: S,…)`), which render it as-is.
public enum FernletUICopy {

    // MARK: Shared verbs

    /// Dismisses the keyboard (the accessory toolbar) and commits a sheet header's edits.
    public static var done: String {
        String(localized: "ui.action.done", defaultValue: "Done", bundle: .module,
               comment: "Button. Two shared places: the keyboard accessory that dismisses the keyboard, and the trailing commit button of a sheet header.")
    }

    /// Leaves a sheet without committing. The leading button of every sheet header and cancel bar.
    public static var cancel: String {
        String(localized: "ui.action.cancel", defaultValue: "Cancel", bundle: .module,
               comment: "Button. Leaves the current sheet or dialog without saving anything.")
    }

    /// The default commit word of ``SheetSaveBar`` — used by the ~6 sheets that pass no `label:`.
    public static var save: String {
        String(localized: "ui.action.save", defaultValue: "Save", bundle: .module,
               comment: "Default label of the green commit bar at the bottom of an entry sheet, for sheets that do not name their own commit verb.")
    }

    // MARK: Discard prompt

    /// The copy of the shared "you have unsaved edits" alert.
    ///
    /// One key each rather than one set per sheet: the prompt is raised from a single modifier
    /// (`discardConfirmation` / `fernletDraftGuard`) at every entry sheet in the app, and per-sheet
    /// keys would let one flow's discard dialog drift into several wordings in a language nobody
    /// here can proofread.
    public enum Discard {
        /// Alert title, phrased as a question.
        public static var title: String {
            String(localized: "ui.discard.title", defaultValue: "Discard your changes?", bundle: .module,
                   comment: "Title of the alert shown when the user cancels an entry sheet that has unsaved edits.")
        }

        /// The cancel-role button: go back to the sheet.
        public static var keepEditing: String {
            String(localized: "ui.discard.keepEditing", defaultValue: "Keep editing", bundle: .module,
                   comment: "Cancel-role button on the unsaved-changes alert. Returns to the sheet with the draft intact.")
        }

        /// The destructive-role button: throw the draft away.
        public static var discard: String {
            String(localized: "ui.discard.confirm", defaultValue: "Discard", bundle: .module,
                   comment: "Destructive button on the unsaved-changes alert. Closes the sheet and throws the draft away.")
        }

        /// The body line, naming exactly what is lost.
        public static var message: String {
            String(localized: "ui.discard.message",
                   defaultValue: "Anything you've typed here won't be saved.", bundle: .module,
                   comment: "Body of the unsaved-changes alert. Names what is lost without implying anything already saved is at risk.")
        }
    }

    // MARK: Coin pill

    /// VoiceOver label for the coin balance pill, e.g. "12 coins".
    ///
    /// The count is an argument rather than an interpolation into a literal so the plural rule
    /// lives in the catalog, where a translator can vary it: several languages need three or more
    /// forms, and English's own "1 coin" is already wrong today.
    ///
    /// - Parameter balance: The number of coins shown on the pill.
    /// - Returns: The spoken form of the balance.
    public static func coinBalance(_ balance: Int) -> String {
        String(localized: "ui.coins.balance", defaultValue: "\(balance) coins", bundle: .module,
               comment: "VoiceOver label for the coin balance pill. The number is the user's current coin count.")
    }
}
