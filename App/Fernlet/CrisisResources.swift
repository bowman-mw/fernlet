//
//  CrisisResources.swift
//  Fernlet
//
//  The gentle-support row's phone numbers, keyed on the device's REGION rather
//  than its language. A German speaker in the US must still see 988; an
//  American in Spain must see 024. Language decides what words the row is in
//  (Phase 1); region decides which number actually connects to a human.
//
//  Every entry here was verified against the operator's own publication before
//  it shipped — see the source note on each case. Numbers are safety copy:
//  changing one is not a routine edit, and a wrong number in this table is
//  worse than no number at all.
//

import Foundation

/// One tappable action on a crisis resource — a call or a text, with the URL already resolved.
///
/// The URL is non-optional by construction: ``CrisisResources`` builds actions through a failable
/// path and drops any whose URL will not parse, so a typo can never render a button that opens
/// nothing. `CrisisResourceTests` asserts the expected action count per region, which turns such a
/// dropped action into a test failure rather than a dead button in front of someone in crisis.
struct CrisisResourceAction: Identifiable {
    /// Stable identifier, also used as the accessibility-identifier suffix (`"call"`, `"text"`).
    let id: String
    /// The button's visible title, e.g. `"Call 988"`. Phase 1 localizes this; the number inside it
    /// is not translated.
    let title: String
    /// SF Symbol drawn ahead of the title.
    let systemImage: String
    /// Where the button goes — a `tel:` or `sms:` URL.
    let url: URL
}

/// A crisis line to show one person, chosen by their device's region.
///
/// `actions` is empty for the fallback resource: where Fernlet does not have a verified number,
/// the row shows supportive copy and no button at all, because a dialable-looking number that
/// does not connect in that country is the worst possible outcome on this screen.
struct CrisisResource {
    /// The service's own name, e.g. `"988 Suicide & Crisis Lifeline"`. Not translated — a person
    /// asking for help by name should use the name the operator answers to.
    let name: String
    /// One sentence of supportive copy naming the line. Phase 1 localizes this.
    let blurb: String
    /// Call/text buttons, in display order. Empty means "show no button" (see above).
    let actions: [CrisisResourceAction]
}

/// The region-keyed table behind the First Aid screen's gentle-support row.
///
/// Regions with a verified national line get that line; every other region gets
/// ``fallback``, which names no number. The table is deliberately small and hand-verified rather
/// than generated: each number below was checked against the operator's or health ministry's own
/// page (sources in the case comments), and all listed lines are free and staffed 24/7 — which is
/// what lets one piece of shared copy promise "there around the clock" for every listed region.
///
/// **Maintenance:** verify against the operator's page before changing a number, update the
/// source comment in the same edit, and keep `CrisisResourceTests` in step. This table is also
/// what the localized privacy-policy footer should read from when the policy is translated.
enum CrisisResources {

    /// The resource to show for `region`, falling back to ``fallback`` when it is unlisted or nil.
    ///
    /// Called with `Locale.current.region` at render time — not cached — so a person who travels
    /// or changes their region setting sees the line that works where they are now.
    static func resource(for region: Locale.Region?) -> CrisisResource {
        guard let region else { return fallback }
        return table[region.identifier] ?? fallback
    }

    /// Shown wherever Fernlet has no verified national line.
    ///
    /// Names no number on purpose: local emergency services are the one thing reachable
    /// everywhere, and inventing a plausible-looking number for an unlisted country would be a
    /// dead call at the worst possible moment.
    static let fallback = CrisisResource(
        name: "Local emergency services",
        blurb: "Some moments are bigger than any app. You deserve real support — your local "
            + "emergency services, or a crisis line where you are, can help right now.",
        actions: []
    )

    /// Region identifier (ISO 3166-1 alpha-2) → resource. See the type's maintenance note.
    private static let table: [String: CrisisResource] = [
        // US/CA: 988 Suicide & Crisis Lifeline — call or text, free, 24/7.
        // Canada adopted the same three-digit code in November 2023. Sources: 988lifeline.org, 988.ca
        "US": lifeline988,
        "CA": lifeline988,

        // GB/IE: Samaritans on the EU-harmonised 116 123 — free, 24/7. Source: samaritans.org
        "GB": samaritans,
        "IE": samaritans,

        // ES: Línea 024 de atención a la conducta suicida — free, confidential, 24/7, 365 days.
        // Run by the Ministerio de Sanidad since 2022-05-10. Source: sanidad.gob.es/linea024
        "ES": CrisisResource(
            name: "Línea 024 de atención a la conducta suicida",
            blurb: supportiveBlurb(naming: "the 024 line"),
            actions: actions(call: "024")
        ),

        // FR: 3114, numéro national de prévention du suicide — free, 24/7, nationwide,
        // staffed by nurses and psychologists. Source: 3114.fr, info.gouv.fr
        "FR": CrisisResource(
            name: "3114 — numéro national de prévention du suicide",
            blurb: supportiveBlurb(naming: "the 3114 line"),
            actions: actions(call: "3114")
        ),

        // DE: TelefonSeelsorge — free, anonymous, around the clock, on both historic 0800 numbers
        // and the EU-harmonised 116 123. Source: telefonseelsorge.de
        "DE": CrisisResource(
            name: "TelefonSeelsorge",
            blurb: supportiveBlurb(naming: "the TelefonSeelsorge line"),
            actions: actions(call: "08001110111", display: "Call 0800 111 0 111")
        ),

        // AU: Lifeline — 13 11 14, 24/7. Source: lifeline.org.au/131114
        "AU": CrisisResource(
            name: "Lifeline",
            blurb: supportiveBlurb(naming: "the Lifeline number"),
            actions: actions(call: "131114", display: "Call 13 11 14")
        ),

        // NZ: 1737, Need to talk? — free, call or text, 24/7. Source: 1737.org.nz
        "NZ": CrisisResource(
            name: "1737, Need to talk?",
            blurb: supportiveBlurb(naming: "the 1737 line"),
            actions: actions(call: "1737", text: "1737")
        ),
    ]

    // MARK: - Shared entries

    /// US and Canada share one entry: same code, same call-or-text shape.
    private static let lifeline988 = CrisisResource(
        name: "988 Suicide & Crisis Lifeline",
        blurb: supportiveBlurb(naming: "the 988 line"),
        actions: actions(call: "988", text: "988")
    )

    /// Great Britain and Ireland share the Samaritans entry on the same harmonised number.
    private static let samaritans = CrisisResource(
        name: "Samaritans",
        blurb: supportiveBlurb(naming: "the Samaritans line"),
        actions: actions(call: "116123", display: "Call 116 123")
    )

    // MARK: - Builders

    /// The shared supportive sentence, with the line's name dropped in.
    ///
    /// Safe to promise "free" and "around the clock" for every listed region because that was a
    /// condition of listing: any future entry that is not free and 24/7 needs its own copy rather
    /// than this sentence.
    private static func supportiveBlurb(naming line: String) -> String {
        "Some moments are bigger than any app. You deserve real support — \(line) is free, kind, "
            + "and there around the clock."
    }

    /// Builds the call (and optional text) actions, dropping any whose URL will not parse.
    ///
    /// `display` overrides the button title for numbers written with spaces — the dialled string
    /// stays unspaced so the `tel:` URL is unambiguous, while the button reads the way the
    /// operator prints it.
    private static func actions(
        call number: String,
        text textNumber: String? = nil,
        display: String? = nil
    ) -> [CrisisResourceAction] {
        var built: [CrisisResourceAction] = []
        if let url = URL(string: "tel:\(number)") {
            built.append(CrisisResourceAction(
                id: "call",
                title: display ?? "Call \(number)",
                systemImage: "phone",
                url: url
            ))
        }
        if let textNumber, let url = URL(string: "sms:\(textNumber)") {
            built.append(CrisisResourceAction(
                id: "text",
                title: "Text \(textNumber)",
                systemImage: "message",
                url: url
            ))
        }
        return built
    }
}
