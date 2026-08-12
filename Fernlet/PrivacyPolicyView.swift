//
//  PrivacyPolicyView.swift
//  Fernlet
//
//  In-app Privacy Policy screen (App Store submission blocker A1). Renders the policy text — the
//  same substance as Docs/Privacy-Policy.md — in the app's voice and type system. The identical
//  text must also be hosted at a public URL (Site/privacy/index.html) and entered in App Store
//  Connect; keep all three in sync.
//
//  Copy finalized 2026-07-19; revised 2026-08-09 (perpetual no-retroactive-use commitments in
//  "Changes"); revised 2026-08-11 (the opt-in encrypted backup for your own meal / recipe /
//  progress photos, which qualifies the previously unconditional "photos are never uploaded to
//  CloudKit"); revised 2026-08-12 (2026-08-10/11 security-hardening round: hard SE-binding of the
//  sealed store — unrecoverable off-device without the opt-in encrypted backup; default
//  device-backup exclusion of local data files; duress PIN with decoy / silent-wipe /
//  recovery-lock responses; journal text removed from the plaintext-sync claim; no-backdoor
//  statement; intimacy age gate corrected to 16+ to match the shipped gate). Any material change
//  to the policy must update the effective date below AND in Docs/Privacy-Policy.md AND
//  Site/privacy/index.html, and be surfaced in the app per the policy's own terms.
//

import SwiftUI
import FernletUI

/// The in-app Privacy Policy screen: the full policy text rendered in Fernlet's type system.
///
/// Pushed from ``SettingsSheet`` via `SettingsRoute.privacyPolicy`. The copy is a static string
/// parsed into `PolicyBlock`s by `PolicyMarkdown` at render time — no web view, no network — and
/// must stay in lockstep with `Docs/Privacy-Policy.md` and the publicly hosted copy
/// (`Site/privacy/index.html`) entered in App Store Connect. Any material change updates the
/// effective date in all three places (`FernletTests/PrivacyPolicyParityTests` pins the sync).
struct PrivacyPolicyView: View {
    // MARK: - Publication facts (keep in lockstep with Docs/Privacy-Policy.md)
    private static let developerName = "Michael Bowman Olay"
    private static let supportEmail: String? = "fernletapp@gmail.com"
    private static let effectiveDate = "August 12, 2026"

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
    Almost everything: the health and activity you log (meals and nutrition, workouts, hydration, hygiene, sleep, and your daily wellbeing score); journal entries and the gentle reflections drawn from them; short memories Fernlet keeps so it can respond thoughtfully over time; your companion's appearance, wardrobe, coins, and milestones; cycle tracking, if you use it; photos you add to your private album; and your settings. Sensitive categories — period/cycle data, sensitive memories, journal text, Worry Box notes, and any intimate-activity notes — are held in an encrypted, sealed store on your device, walled off so that on-device AI and networking code cannot read the raw data.
    The key that opens the sealed store is locked to *this device's* security hardware (the Secure Enclave). That means sealed data cannot be recovered on any other device — or on this one after it has been erased, reset, or replaced — from any device backup, even with your correct app passcode. The only way sealed data can follow you to a new phone is the opt-in encrypted backup below. If the sealed store can no longer be opened on this device, the app tells you so plainly instead of failing silently.
    Separately, for new installs Fernlet's local data files (the sealed store and your local history database) are excluded from your device backup by default; if you were already using Fernlet before this default existed, the app asks you once, plainly, which you prefer. You can change this any time with "Include local data in iOS backup" in Privacy & Data. That toggle does not cover photo files (see Photos).

    ## Apple Health (HealthKit)
    With your permission, Fernlet reads heart rate, active energy, sleep analysis, step count, and workouts to reflect your day. Fernlet writes only the workouts you log, so they count toward your Apple activity rings. Fernlet never writes period, mood, journal, hydration, or hygiene data to Apple Health. Health data is used only on your device and is never sold or used for advertising. Deleting Fernlet does not delete samples it wrote to Apple Health — remove those in the Health app if you wish.

    ## iCloud sync and encrypted backup (optional, you choose)
    During setup you choose whether to keep your data only on this device or sync it to iCloud. If you enable iCloud sync, your core app data is synced to your own iCloud private database using Apple's CloudKit, associated with your Apple ID under Apple's standard privacy model — we cannot see it, and you can turn it off or delete the cloud copy any time. Journal *text* is not part of that sync: the days and structure of your journal sync, but the words you wrote are sealed on your device and leave it only as ciphertext, through the opt-in encrypted backup. You may separately opt in to an encrypted backup of sensitive memories, period data, journal entries, intimate logs, and/or your own photos (see Photos below); before that data leaves your device it is encrypted (AES-256-GCM) so Apple stores only unreadable ciphertext. Because the key lives in your iCloud Keychain, if you permanently lose access to it on all your devices, that encrypted data cannot be recovered — you are told this when you enable it. Because the sealed store's key is locked to this device (above), this opt-in backup is the *only* way the sealed categories can be recovered on another or an erased device — without it, sealed data is unrecoverable off this device, full stop. The journal, period-data and intimate-log parts of this backup require Fernlet's app lock: without one, those categories cannot be backed up at all (sensitive memories still can be). Notes you let go of in the Worry Box are deliberately excluded from every backup — they exist only on this device and do not survive a device erase. Period-data backup is a deliberate, clearly-warned opt-in.

    ## Photos
    Photos are stored encrypted in the app's private storage and are never sent to any AI or server, and never analyzed. By default they are also never uploaded to CloudKit: they leave your phone only inside your standard iCloud device backup, through the app container. There is exactly one exception, and it is off unless you turn it on. If you switch on "Sealed backup for your photos" in Privacy & Data, your own meal, recipe and gym-progress photos are backed up to your own iCloud private database — encrypted on your device first (AES-256-GCM), so Apple stores only unreadable ciphertext, and still never sent to us or to any AI. Photos friends have shared with you are never part of that backup. Once that backup has actually stored your photos, Fernlet locks their encryption key to this device so future device backups can no longer open them. The lock protects only backups made *after* you turn it on — a device backup made *before* still carries a working copy of the key. The lock is permanent, and from then on the encrypted backup is how those photos come back on a new phone. You may explicitly export an individual photo to your system Photos library with a "Save to Photos" action — a one-time export you initiate, not automatic sync. Fernlet does no face recognition.

    ## Friend features (in-person only)
    To support optional in-person friend features, Fernlet generates a cryptographic identity for your device. The keys stay in this device's Keychain and never sync to iCloud Keychain — a new phone starts with a fresh identity, and you re-add friends in person. Your public key is the only persistent identifier shared with friends; your private keys never leave your device. Friend features work only when two people are physically near each other, over a short-range encrypted connection — there is no friend server and no remote friend activity. When you add a friend in person, your devices exchange display names, public keys, avatar appearances, and a *fuzzy* wellbeing vibe (e.g. "thriving," "okay," "struggling"). Friends never see your numeric score, goals, cycle information, or any raw health data. Optional approximate location may be used only for gentle weather prompts and, if you choose, to tag an in-person activity; location is never tracked over time.

    ## Artificial intelligence
    Fernlet's AI features run on your device using Apple's on-device models. Your journal text, memories, health data, photos, period data, and friend data are not sent to any external AI service. Some optional convenience features may look up non-personal reference data from public sources (for example, the nutrition facts for a packaged product), sending only the minimal query needed and never your identity or sensitive information. Fernlet does not generate mental-health diagnoses and filters clinical language out of anything it stores.

    ## What we do not do
    - We do not sell, rent, or trade your personal data.
    - We do not use third-party advertising or cross-app tracking.
    - We do not embed analytics SDKs that profile you.
    - We do not perform face recognition.
    - We do not operate a server that collects your health or journal data.
    - We do not require an account or a login.
    - We do not hold a master key or any recovery backdoor. We cannot bypass or remove your app lock for you, and we cannot recover your sealed data — nobody can, not us, not Apple, not any future owner of the app. The only recovery route is the encrypted backup you may opt into.

    ## User content and safety
    If you create custom companion clothing and share it with friends in person, that content is governed by our in-app rules against objectionable content. You can report and block content and the people who share it; reporting hides the content on your device and blocks that person, and Fernlet keeps an on-device record used to limit abusive sharing. Because sharing is peer-to-peer, moderation actions take effect on-device.

    ## Your controls
    In Settings you can choose local-only storage or iCloud sync; turn encrypted backup on or off per category, including "Sealed backup for your photos"; lock your photos' encryption key to this device *without* any backup, if you prefer the protection to the recovery (clearly warned; permanent); choose whether Fernlet's local data files are included in your device backup ("Include local data in iOS backup" — excluded by default for new installs); reset the app lock, which permanently destroys every key that can open the sealed categories on this device (a crypto-erase — the sealed data on this phone becomes unreadable for good; a cloud copy in the opt-in encrypted backup, if you enabled it, is separate and survives a lock reset — turn that backup off to delete it); export your data as a file you can save or share (the export excludes the encrypted sealed categories to protect them); delete your iCloud copy; delete your data; and manage or wipe the memories Fernlet keeps. Because we hold no copy of your data on our own servers, you exercise these rights directly in the app.
    You can also set an optional *duress PIN*: a second app passcode with one response you choose. **Decoy** opens a view with sensitive content hidden and destroys nothing. **Silent wipe** immediately destroys every key that can open sealed data on this device — an instant, irreversible crypto-erasure — then deletes the remaining local data, your iCloud copies, and the samples Fernlet wrote to Apple Health, on a best-effort basis; encrypted backup data briefly left off the device is unopenable ciphertext until the purge or its own age-out removes it. **Recovery lock** is not deletion: it destroys this device's unlock keys, so everything sealed stays on the phone as unreadable ciphertext — a lock-out, not an erase — recoverable only in person, through a mutual QR ceremony with a second device *you* previously enrolled as your own recovery device; there is no cloud or remote route, and the recovery device is always your own, never us. Entering a duress PIN looks exactly like a normal unlock — nothing on the screen, in the unlock's timing, or in the app's activity log gives away that one is configured.

    ## Children
    Fernlet is not directed to young children. Intimate-tracking features are gated to users who indicate they are 16 or older and are hidden and off by default.

    ## Changes — and the promises that cannot change
    If we make material changes we will update the date above and surface the change in the app. Some of this policy is **permanent**: the following commitments are perpetual and bind this version of Fernlet, every future version, and any future owner or maintainer of the app.
    - **Data you logged under this policy is never retroactively repurposed.** Anything Fernlet stored while this policy was in force stays governed by the promises that were in force when you logged it. No future update may reach back and use, upload, analyze, sell, or share that data under weaker terms.
    - **The no-collection guarantee does not expire.** Fernlet is built so that the developer receives none of your health, journal, photo, memory, cycle, friend, or location data, and that guarantee binds every future version and owner — no future version may begin collecting from data you already entered.
    - **Weakening ever requires your fresh, affirmative consent.** Any future change that would send existing data somewhere new, or handle it less protectively, takes effect only for users who explicitly and separately agree to it after being clearly told what changes. Continued use, silence, or installing an update is *never* consent to such a change — and declining must either leave the app usable with your data handled under the old terms, or let you export and delete your data first.
    For everything else — clarifications, new features, stronger protections — continued use after an update means you accept the revised policy.

    How these promises are backed technically (build-enforced boundaries, a published network-egress inventory, and a standing invitation to audit the app's traffic) is described in the project's verifiability statement, published alongside the source code as Docs/Verifiability.md.

    ## Contact
    For questions about this policy or your privacy, \(contactClause).

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
