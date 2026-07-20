// LinkMetadataPrototypeView.swift
// D11 prototype: does sender-supplied LPLinkMetadata survive into the SENT iMessage bubble,
// or does Messages re-fetch the page's own metadata?
// Test matrix, run steps, and the results table: Docs/D11-LinkMetadata-Prototype.md
// Temporary debug tool — delete once D11 is decided. Not wired into any screen; present it
// with a temporary (uncommitted) NavigationLink from any DEBUG build.

#if DEBUG
import SwiftUI
import LinkPresentation
import UIKit

// `nonisolated` keeps the UIActivityItemSource conformance legal if the target ever adopts
// default MainActor isolation; if your build setting rejects the keyword, just delete it.
nonisolated struct LinkMetadataTestCase: Identifiable, Sendable {
    let id: String          // matrix row, e.g. "B"
    let name: String
    let question: String
    let url: URL
    let customTitle: String?    // nil = baseline share with no custom metadata
    let attachImage: Bool
}

nonisolated enum LinkMetadataTestMatrix {
    /// ~2 KB of deterministic base64url noise standing in for a sealed inline plan payload.
    static let fragmentPayload: String = {
        var s = ""
        var i = 0
        while s.utf8.count < 2_048 {
            s += "fernlet-d11-prototype-payload-\(i)-"
            i += 1
        }
        return Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }()

    static let all: [LinkMetadataTestCase] = [
        LinkMetadataTestCase(
            id: "A", name: "Baseline fetch",
            question: "No custom metadata — bubble should show the page's own title (“Example Domain”). Confirms the fetch path.",
            url: URL(string: "https://example.com/")!,
            customTitle: nil, attachImage: false),
        LinkMetadataTestCase(
            id: "B", name: "Custom title vs plain page",
            question: "THE core test: does the sent bubble show “7/19–7/26 Workouts” or “Example Domain”?",
            url: URL(string: "https://example.com/")!,
            customTitle: "7/19–7/26 Workouts", attachImage: false),
        LinkMetadataTestCase(
            id: "C", name: "Custom title + image",
            question: "Does custom card artwork survive into the bubble alongside the title?",
            url: URL(string: "https://example.com/")!,
            customTitle: "7/19–7/26 Workouts", attachImage: true),
        LinkMetadataTestCase(
            id: "D", name: "Custom vs rich page",
            question: "Page with full OG tags — does the fetched rich preview beat the custom metadata? (Our real /plan pages will have OG tags.)",
            url: URL(string: "https://www.apple.com/")!,
            customTitle: "7/19–7/26 Workouts", attachImage: true),
        LinkMetadataTestCase(
            id: "E", name: "Fragment payload",
            question: "Realistic ~2 KB #fragment — does the bubble stay clean, and does the FULL fragment survive to the tap (check Safari's address bar on the recipient)?",
            url: URL(string: "https://example.com/plan#v1.\(fragmentPayload)")!,
            customTitle: "7/19–7/26 Workouts", attachImage: false),
        LinkMetadataTestCase(
            id: "F", name: "404 page",
            question: "Fetch finds no usable metadata — does the custom title still render?",
            url: URL(string: "https://example.com/plan/fernlet-d11-does-not-exist")!,
            customTitle: "7/19–7/26 Workouts", attachImage: false),
        LinkMetadataTestCase(
            id: "G", name: "Unfetchable domain",
            question: "“.invalid” never resolves (RFC 2606) — does a styled bubble with the custom title send at all?",
            url: URL(string: "https://fernlet-prototype.invalid/plan#v1.abc123")!,
            customTitle: "7/19–7/26 Workouts", attachImage: false),
    ]
}

nonisolated final class LinkMetadataItemSource: NSObject, UIActivityItemSource {
    let testCase: LinkMetadataTestCase

    init(testCase: LinkMetadataTestCase) {
        self.testCase = testCase
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        testCase.url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        testCase.url
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        guard let title = testCase.customTitle else { return nil }
        let metadata = LPLinkMetadata()
        metadata.originalURL = testCase.url
        metadata.url = testCase.url
        metadata.title = title
        if testCase.attachImage {
            metadata.imageProvider = NSItemProvider(object: Self.cardImage(labeled: title))
        }
        return metadata
    }

    private static func cardImage(labeled title: String) -> UIImage {
        let size = CGSize(width: 600, height: 400)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            (title as NSString).draw(
                at: CGPoint(x: 24, y: 24),
                withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 40),
                    .foregroundColor: UIColor.white,
                ])
        }
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let itemSource: LinkMetadataItemSource

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [itemSource], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct LinkMetadataPrototypeView: View {
    @State private var activeCase: LinkMetadataTestCase?

    var body: some View {
        NavigationStack {
            List(LinkMetadataTestMatrix.all) { testCase in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(testCase.id) — \(testCase.name)")
                        .font(.headline)
                    Text(testCase.question)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Share…") { activeCase = testCase }
                            .buttonStyle(.borderedProminent)
                        Button("Copy URL") { UIPasteboard.general.url = testCase.url }
                            .buttonStyle(.bordered)
                    }
                    .font(.footnote)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("D11: LPLinkMetadata")
            .sheet(item: $activeCase) { testCase in
                ActivityShareSheet(itemSource: LinkMetadataItemSource(testCase: testCase))
                    .presentationDetents([.medium, .large])
            }
        }
    }
}
#endif
