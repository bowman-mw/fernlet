//
//  StressExplainerSheet.swift
//  Fernlet
//
//  The gentle "how we estimate this" sheet behind the Home body-signals line. Wellness
//  framing only — plain language, the user's own baseline, and an explicit not-medical
//  disclaimer (App Store 1.4.1). Batch B will add a First Aid link from here; for now the
//  sheet is informational only.
//

import SwiftUI
import FernletScoring

struct StressExplainerSheet: View {
    /// Nil during cold start (fewer than ~7 days of body signals).
    var assessment: StressAssessment?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Body signals")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.bark)
                    Spacer()
                    Button("Done") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.moss)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(currentReadingTitle)
                        .font(.headline)
                        .foregroundStyle(Color.bark)
                    Text(currentReadingBody)
                        .font(.subheadline)
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                    if let annotationLine {
                        Text(annotationLine)
                            .font(.subheadline)
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                    if let confidenceLine {
                        Text(confidenceLine)
                            .font(.caption.italic())
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("How Fernlet estimates this")
                    Text("Fernlet quietly compares your recent heart rate variability and resting heart rate with your own usual range from the last several weeks — never anyone else's numbers. Days you moved a lot, marked yourself sick, or showed signs of coming down with something are taken into account so a hard workout doesn't read as a hard week.")
                        .font(.subheadline)
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                    Text("Everything is estimated and stored on this device only.")
                        .font(.caption.italic())
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("A gentle note")
                    Text("This is a wellbeing reflection, not a medical measurement, diagnosis, or advice. If you're worried about how you feel, please talk to a health professional you trust.")
                        .font(.subheadline)
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
            }
            .padding(20)
        }
        .background(Color.parchment)
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
