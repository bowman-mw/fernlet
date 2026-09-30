import LinkPresentation
import UIKit

/// What "Share as text" hands the system share sheet: the recipe's readable text
/// (``RecipeShareText``), with the recipe's name as the sheet's title and as Mail's subject.
///
/// **Why an item source rather than `ShareLink`** (measured on the iOS 26.5 simulator, 2026-09-30).
/// `ShareLink` offers the two halves only separately: its plain-`String` form keeps Copy but leaves
/// the sheet's title row blank, and its `SharePreview` form titles the sheet but hands the text over
/// as a file-like item, which drops Copy and offers Save to Files instead. A `UIActivityItemSource`
/// gives both: every activity receives a string, and the title comes from ``activityViewControllerLinkMetadata(_:)``.
///
/// **No network.** The `LPLinkMetadata` here is built locally with a title only — no URL, no
/// `LPMetadataProvider` — so LinkPresentation fetches nothing (Docs/No-Tracking-Wall.md).
///
/// `nonisolated` with immutable `Sendable` state, because UIKit documents no queue for these
/// callbacks. `Identifiable` (by object identity) so `.sheet(item:)` presents a fresh one per tap.
nonisolated final class RecipeShareTextItemSource: NSObject, UIActivityItemSource, Identifiable {
    /// The readable text every activity receives.
    let text: String
    /// The recipe's name: the sheet's title and Mail's subject.
    let title: String

    init(text: String, title: String) {
        self.text = text
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        text
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        text
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        title
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        return metadata
    }
}
