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
import FernletScoring

struct StressExplainerSheet: View {
    /// Nil during cold start (fewer than ~7 days of body signals).
    var assessment: StressAssessment?
    /// Set by ContentView to chain into the First Aid sheet (dismiss-then-represent).
    var onFirstAid: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Body signals")
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
                    Spacer()
                    Button("Done") { dismiss() }
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.moss)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(currentReadingTitle)
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
                    Text(currentReadingBody)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                    if let annotationLine {
                        Text(annotationLine)
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                    if let confidenceLine {
                        Text(confidenceLine)
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))

                firstAidLink

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("How Fernlet estimates this")
                    Text("Fernlet quietly compares your recent heart rate variability and resting heart rate with your own usual range from the last several weeks — never anyone else's numbers. Days you moved a lot, marked yourself sick, or showed signs of coming down with something are taken into account so a hard workout doesn't read as a hard week.")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                    Text("Everything is estimated and stored on this device only.")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("A gentle note")
                    Text("This is a wellbeing reflection, not a medical measurement, diagnosis, or advice. If you're worried about how you feel, please talk to a health professional you trust.")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
            }
            .padding(20)
        }
        .background(Color.parchment)
    }

    /// A soft door to the First Aid tools — worded as an offer, shown whenever the host wired it.
    @ViewBuilder
    private var firstAidLink: some View {
        if let onFirstAid {
            Button {
                onFirstAid()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "heart.circle")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.moss)
                        .frame(width: 34, height: 34)
                        .background(Color.moss.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Something for right now?")
                            .font(.fernlet(.label))
                            .foregroundStyle(Color.bark)
                        Text("First aid has slow breathing, grounding, and a worry box — only if it sounds nice.")
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.slate.opacity(0.6))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("stressExplainer.firstAid")
        }
    }

    private var currentReadingTitle: String {
        guard let assessment else { return "Still getting to know you" }
        switch assessment.state {
        case .calm: return "Settled"
        case .okay: return "About your usual"
        case .tense: return "A little tense"
        case .needsCare: return "Extra tense lately"
        }
    }

    private var currentReadingBody: String {
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

    private var annotationLine: String? {
        switch assessment?.annotation {
        case .workedOut:
            return "You've moved a lot recently, so this may just be that good kind of tired."
        case .possiblyUnwell:
            return "A few signals hint your body might be fighting something off — resting counts double."
        case nil:
            return nil
        }
    }

    private var confidenceLine: String? {
        switch assessment?.confidence {
        case .building: return "Fernlet's sense of your usual is still quite new."
        case .settling: return "Fernlet's sense of your usual is still settling in."
        case .established, nil: return nil
        }
    }
}
