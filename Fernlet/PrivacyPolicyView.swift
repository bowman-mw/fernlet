//
//  PrivacyPolicyView.swift
//  Fernlet
//
//  In-app Privacy Policy screen (App Store submission blocker A1). Renders the policy text — the
//  same substance as Docs/Privacy-Policy.md — in the app's voice and type system. The identical
//  text must also be hosted at a public URL and entered in App Store Connect; keep the two in sync.
//
//  Copy finalized 2026-07-19. Any material change to the policy must update the effective date
//  below AND in Docs/Privacy-Policy.md, and be surfaced in the app per the policy's own terms.
//

import SwiftUI
import FernletUI

/// The in-app Privacy Policy screen: the full policy text rendered in Fernlet's type system.
///
/// Pushed from ``SettingsSheet`` via `SettingsRoute.privacyPolicy`. The copy is a static string
/// parsed into `PolicyBlock`s by `PolicyMarkdown` at render time — no web view, no network — and
/// must stay in lockstep with `Docs/Privacy-Policy.md` and the publicly hosted copy entered in
/// App Store Connect. Any material change updates the effective date in both places.
struct PrivacyPolicyView: View {
    // MARK: - Publication facts (keep in lockstep with Docs/Privacy-Policy.md)
    private static let developerName = "Michael Bowman Olay"
    private static let supportEmail: String? = "fernletapp@gmail.com"
    private static let effectiveDate = "July 19, 2026"

    private static var contactClause: String {
        if let supportEmail { return "contact \(supportEmail)" }
        return "contact the developer, \(developerName)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(Self.blocks.enumerated()), id: \.offset) { _, block in
                    block.view
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.parchment)
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Content (display copy)

    private static var blocks: [PolicyBlock] { PolicyMarkdown.parse(policyText) }

    private static let policyText = """
    # Fernlet Privacy Policy

    Last updated: \(effectiveDate)

    ## The short version
    Fernlet is a private, gentle self-care companion. It is built privacy-first, on-device by design. We do not run servers that collect your health data, we do not sell or share your data, we use no advertising or third-party tracking, and we never do face recognition. Most of what you log never leaves your phone. The parts that can be backed up go to *your own* iCloud account, not to us, and the most sensitive parts are encrypted on your device first so that not even Apple can read them.

    ## Who controls your data
    Fernlet has no backend that we operate. Your data lives in three places, all under your control: on your device (the default home for nearly everything), your personal iCloud account (only if you turn on sync or encrypted backup — this is Apple's infrastructure tied to your Apple ID, not ours), and directly between phones in person (for the optional friend features, which work only when two people are physically near each other). \(developerName) does not receive, store, or have access to your health information, journal entries, photos, memories, cycle data, friend list, or location.

    ## What Fernlet stores on your device
    Almost everything: the health and activity you log (meals and nutrition, workouts, hydration, hygiene, sleep, and your daily wellbeing score); journal entries and the gentle reflections drawn from them; short memories Fernlet keeps so it can respond thoughtfully over time; your companion's appearance, wardrobe, coins, and milestones; cycle tracking, if you use it; photos you add to your private album; and your settings. Sensitive categories — period/cycle data, sensitive memories, journal text, and any intimate-activity notes — are held in an encrypted, sealed store on your device, walled off so that on-device AI and networking code cannot read the raw data.

    ## Apple Health (HealthKit)
    With your permission, Fernlet reads heart rate, active energy, sleep analysis, step count, and workouts to reflect your day. Fernlet writes only the workouts you log, so they count toward your Apple activity rings. Fernlet never writes period, mood, journal, hydration, or hygiene data to Apple Health. Health data is used only on your device and is never sold or used for advertising. Deleting Fernlet does not delete samples it wrote to Apple Health — remove those in the Health app if you wish.

    ## iCloud sync and encrypted backup (optional, you choose)
    During setup you choose whether to keep your data only on this device or sync it to iCloud. If you enable iCloud sync, your core app data is synced to your own iCloud private database using Apple's CloudKit, associated with your Apple ID under Apple's standard privacy model — we cannot see it, and you can turn it off or delete the cloud copy any time. You may separately opt in to an encrypted backup of sensitive memories and/or period data; before that data leaves your device it is encrypted (AES-256-GCM) so Apple stores only unreadable ciphertext. Because the key lives in your iCloud Keychain, if you permanently lose access to it on all your devices, that encrypted data cannot be recovered — you are told this when you enable it. Period-data backup is a deliberate, clearly-warned opt-in.

    ## Photos
    Photos in your Fernlet album are stored encrypted in the app's private storage and are never uploaded to CloudKit or sent to any AI or server. They are included in your standard iCloud device backup through the app container. You may explicitly export an individual photo to your system Photos library with a "Save to Photos" action — a one-time export you initiate, not automatic sync. Fernlet does no face recognition.

    ## Friend features (in-person only)
    To support optional in-person friend features, Fernlet generates a cryptographic identity for your device. Your public key is the only persistent identifier shared with friends; your private keys never leave your device. Friend features work only when two people are physically near each other, over a short-range encrypted connection — there is no friend server and no remote friend activity. When you add a friend in person, your devices exchange display names, public keys, avatar appearances, and a *fuzzy* wellbeing vibe (e.g. "thriving," "okay," "struggling"). Friends never see your numeric score, goals, cycle information, or any raw health data. Optional approximate location may be used only for gentle weather prompts and, if you choose, to tag an in-person activity; location is never tracked over time.

    ## Artificial intelligence
    Fernlet's AI features run on your device using Apple's on-device models. Your journal text, memories, health data, photos, period data, and friend data are not sent to any external AI service. Some optional convenience features may look up non-personal reference data from public sources (for example, the nutrition facts for a packaged product), sending only the minimal query needed and never your identity or sensitive information. Fernlet does not generate mental-health diagnoses and filters clinical language out of anything it stores.

    ## What we do not do
    - We do not sell, rent, or trade your personal data.
    - We do not use third-party advertising or cross-app tracking.
    - We do not embed analytics SDKs that profile you.
    - We do not perform face recognition.
    - We do not operate a server that collects your health or journal data.
    - We do not require an account or a login.

    ## User content and safety
    If you create custom companion clothing and share it with friends in person, that content is governed by our in-app rules against objectionable content. You can report and block content and the people who share it; reporting hides the content on your device and blocks that person, and Fernlet keeps an on-device record used to limit abusive sharing. Because sharing is peer-to-peer, moderation actions take effect on-device.

    ## Your controls
    In Settings you can choose local-only storage or iCloud sync; turn encrypted backup on or off per category; export your data as a file you can save or share (the export excludes the encrypted sealed categories to protect them); delete your iCloud copy; delete your data; and manage or wipe the memories Fernlet keeps. Because we hold no copy of your data on our own servers, you exercise these rights directly in the app.

    ## Children
    Fernlet is not directed to young children. Intimate-tracking features are gated to users who indicate they are 18 or older and are hidden and off by default.

    ## Changes and contact
    If we make material changes we will update the date above and surface the change in the app. For questions about this policy or your privacy, \(contactClause).

    ---
    Fernlet is a wellness and self-care companion, not a medical device. It does not provide medical advice, diagnosis, or treatment. If you are in crisis, contact your local emergency services or, in the US, call or text 988 (the Suicide & Crisis Lifeline).
    """
}

// MARK: - Minimal markdown block model + parser

/// One renderable block of the policy document: a title, section header, paragraph, bullet, or rule.
///
/// Produced by ``PolicyMarkdown/parse(_:)`` and rendered by ``PrivacyPolicyView``; each case carries
/// its own `view` so the screen body is just a ForEach over the parsed blocks.
private enum PolicyBlock {
    case title(String)
    case header(String)
    case paragraph(String)
    case bullet(String)
    case rule

    @ViewBuilder var view: some View {
        switch self {
        case .title(let s):
            Text(s)
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
                .padding(.bottom, 2)
        case .header(let s):
            Text(s)
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.bark)
                .padding(.top, 8)
        case .paragraph(let s):
            Text(PolicyMarkdown.inline(s))
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").font(.fernlet(.body)).foregroundStyle(Color.moss)
                Text(PolicyMarkdown.inline(s))
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Divider().background(Color.slate.opacity(0.4)).padding(.vertical, 4)
        }
    }
}

/// Minimal line-oriented markdown parser for the policy text — headers, bullets, rules, paragraphs,
/// and inline bold/italic.
///
/// Deliberately tiny: it supports exactly the constructs the policy uses, so the display copy can
/// stay a readable markdown string shared verbatim with `Docs/Privacy-Policy.md` instead of
/// hand-built views.
private enum PolicyMarkdown {
    /// Splits the markdown into `PolicyBlock`s, one per non-empty line.
    static func parse(_ text: String) -> [PolicyBlock] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw -> PolicyBlock? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line == "---" { return .rule }
            if line.hasPrefix("## ") { return .header(String(line.dropFirst(3))) }
            if line.hasPrefix("# ") { return .title(String(line.dropFirst(2))) }
            if line.hasPrefix("- ") { return .bullet(String(line.dropFirst(2))) }
            return .paragraph(line)
        }
    }

    /// Renders inline `*italic*` / `**bold**` while keeping plain text intact.
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }
}

#Preview {
    NavigationStack { PrivacyPolicyView() }
}
