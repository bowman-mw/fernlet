//
//  StressExplainerSheet.swift
//  Fernlet
//
//  The gentle "how we estimate this" sheet behind the Home body-signals line. Wellness
//  framing only — plain language, the user's own baseline, and an explicit not-medical
//  disclaimer (App Store 1.4.1). Also offers the First Aid tools — an invitation, never
//  an instruction.
//

import SwiftUI
import FernletDomainModel
import FernletScoring
import FernletUI

/// The gentle "how we estimate this" sheet behind the Home body-signals line.
///
/// Renders the current `StressAssessment` from ``StressService`` (nil during the ~7-day cold
/// start) as plain-language wellness copy — the user's own baseline, the worked-out /
/// possibly-unwell annotation, and a confidence line — plus an explicit not-medical disclaimer
/// (App Store 1.4.1). The optional `onFirstAid` hook, wired by ContentView, chains into the
/// ``FirstAidView`` sheet as an offer, never an instruction. Purely presentational: it computes
/// nothing and stores nothing. A read-only sheet under the 2026-08-21 template: Done sits
/// top-right in the pinned header and is the whole exit — no bottom bar.
struct StressExplainerSheet: View {
    /// Nil during cold start (fewer than ~7 days of body signals).
    var assessment: StressAssessment?
    /// Set by ContentView to chain into the First Aid sheet (dismiss-then-represent).
    var onFirstAid: (() -> Void)? = nil
    /// World (`b2-stress`): pushed under the Today panel's plate ("‹ Today  Body signals  ✕") instead
    /// of presented as a sheet with Done.
    var isPushed = false
    @Environment(\.dismiss) private var dismiss
    /// The user's term of address (the app root sets it from the body profile), for the lines that
    /// describe the user: the tense reading titles and "marked yourself sick".
    @Environment(\.fernletTermOfAddress) private var termOfAddress

    var body: some View {
        if isPushed {
            ScrollView { readingContent }
                .fernletPageBackground()
                .fernletPushedPage(LocalizedStringResource("Body signals"))
        } else {
            VStack(spacing: 0) {
                SheetHeader(title: "Body signals", onDone: { dismiss() })
                ScrollView {
                    readingContent
                }
            }
            .background(Color.parchment)
        }
    }

    /// The scrolling half: the current-reading card, the First Aid offer, and the two prose
    /// sections (how it's estimated, and the not-medical note), each a framed card in the World look.
    private var readingContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            readingCard
            firstAidLink
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("How Fernlet estimates this")
                FernletCard {
                    VStack(alignment: .leading, spacing: 8) {
                        AddressedText("Fernlet quietly compares your recent heart rate variability and resting heart rate with your own usual range from the last several weeks — never anyone else's numbers. Days you moved a lot, marked yourself sick, or showed signs of coming down with something are taken into account so a hard workout doesn't read as a hard week.")
                            .font(FernletFramedFont.field)
                            .foregroundStyle(WorldPalette.dim)
                            .fernletWrappingText()
                        Text("Everything is estimated and stored on this device only.")
                            .font(FernletFramedFont.body)
                            .foregroundStyle(WorldPalette.dim)
                            .fernletWrappingText()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("A gentle note")
                FernletCard {
                    Text("This is a wellbeing reflection, not a medical measurement, diagnosis, or advice. If you're worried about how you feel, please talk to a health professional you trust.")
                        .font(FernletFramedFont.field)
                        .foregroundStyle(WorldPalette.dim)
                        .fernletWrappingText()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The current reading (`b2-stress`): a sage card in the kit's ink frame, the reading as a
    /// Fraunces title over today's lines.
    private var readingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            currentReadingTitle
                .font(FernletFramedFont.sheetTitle)
                .foregroundStyle(WorldPalette.bark)
                .accessibilityAddTraits(.isHeader)
            Text(currentReadingBody)
                .font(FernletFramedFont.field)
                .foregroundStyle(WorldPalette.dim)
                .fernletWrappingText()
            if let annotationLine {
                Text(annotationLine)
                    .font(FernletFramedFont.field)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
            }
            if let confidenceLine {
                Text(confidenceLine)
                    .font(FernletFramedFont.body)
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fernletFramed(WorldTheme.framedLook, fill: WorldPalette.sage, cornerRadius: FernletFramedLook.cardRadius)
    }

    /// A soft door to the First Aid tools — worded as an offer, shown whenever the host wired it.
    @ViewBuilder
    private var firstAidLink: some View {
        if let onFirstAid {
            Button {
                onFirstAid()
            } label: {
                HStack(spacing: 14) {
                    // World (b2-stress): the pixel aid heart (its tile bare inside the card), the pixel chevron.
                    FernletIconTile(size: 48) {
                        WorldSpriteView(sprite: WorldSprites.aid, scale: 3)
                    }
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Something for right now?")
                            .font(FernletFramedFont.rowTitleBold)
                            .foregroundStyle(WorldPalette.bark)
                        Text("First aid has slow breathing, grounding, and a worry box — only if it sounds nice.")
                            .font(FernletFramedFont.note)
                            .foregroundStyle(WorldPalette.dim)
                            .fernletWrappingText()
                    }
                    Spacer(minLength: 0)
                    FernletIcon(.chevron, scale: 2)
                        .accessibilityHidden(true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The frame rule (ref-frames-rule): pieces inside this card draw flat.
                .environment(\.fernletInFramedSection, true)
                .fernletFramed(WorldTheme.framedLook, fill: WorldPalette.paper, cornerRadius: FernletFramedLook.cardRadius)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("stressExplainer.firstAid")
        }
    }

    // The four reading lines below are `LocalizedStringKey` or `Text`, not `String`: each returns a
    // literal, and as `String` every one reached `Text`'s verbatim initializer and was never harvested.

    /// The reading's title. A `Text` because the two tense titles describe the user (*tensa*) and are
    /// agreed with them through `AddressedCopy`; the other three are plain literals.
    private var currentReadingTitle: Text {
        guard let assessment else { return Text("Still getting to know you") }
        switch assessment.state {
        case .calm: return Text("Settled")
        case .okay: return Text("About your usual")
        case .tense: return Text(AddressedCopy.attributed("A little tense", addressing: termOfAddress))
        case .needsCare: return Text(AddressedCopy.attributed("Extra tense lately", addressing: termOfAddress))
        }
    }

    private var currentReadingBody: LocalizedStringKey {
        guard let assessment else {
            return "Fernlet needs about a week of body signals before it can tell what \"usual\" looks like for you. Nothing to do — it will quietly settle in."
        }
        switch assessment.state {
        case .calm:
            return "Your body seems more settled than your usual right now. Nice."
        case .okay:
            return "Your body seems right around its usual. Nothing to read into."
        case .tense:
            return "Your body seems a bit more tense than your usual. That can come from lots of ordinary things — be extra kind to yourself today."
        case .needsCare:
            return "Your body has seemed extra tense for a couple of days now. Going gently — rest, water, something small and kind — is more than enough."
        }
    }

    private var annotationLine: LocalizedStringKey? {
        switch assessment?.annotation {
        case .workedOut:
            return "You've moved a lot recently, so this may just be that good kind of tired."
        case .possiblyUnwell:
            return "A few signals hint your body might be fighting something off — resting counts double."
        case nil:
            return nil
        }
    }

    private var confidenceLine: LocalizedStringKey? {
        switch assessment?.confidence {
        case .building: return "Fernlet's sense of your usual is still quite new."
        case .settling: return "Fernlet's sense of your usual is still settling in."
        case .established, nil: return nil
        }
    }
}
