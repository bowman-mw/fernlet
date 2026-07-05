//
//  JournalPromptLibrary.swift
//  Fernlet
//
//  A static, curated library of warm journaling prompts with a deterministic daily rotation.
//  Deliberately NOT AI: journal text is walled from every model (S3), and the prompt of the day
//  must be the same on every launch and every device — so it is a pure function of the dateKey.
//  Prompts are inspiration only: surfaced as a dismissible chip in the journal sheet, never
//  required, never blocking.
//

import Foundation

enum JournalPromptLibrary {
    /// ~40 gentle prompts across gratitude, naming emotions, body check-ins, tiny wins, small
    /// pleasures, and self-kindness. Warm and non-clinical by design — no "symptoms", no scores,
    /// no shoulds.
    static let prompts: [String] = [
        // Gratitude
        "What's one small thing today that you'd quietly like to keep?",
        "Who made your day a little lighter — even in a tiny way?",
        "Name something ordinary that worked today. The kettle counts.",
        "What's something your past self set up that today-you got to enjoy?",
        "What made you smile today, even for a second?",
        "What's one comfort you usually overlook?",
        // Naming emotions
        "If today had a weather report, what would it say?",
        "What feeling visited you most today? No need to explain it.",
        "Was there a moment today when your mood shifted? What was nearby?",
        "What's one word for how you feel right now — and one for how you'd like to feel tomorrow?",
        "Is anything sitting a little heavy tonight? You can just name it and stop there.",
        "What did you feel today that you didn't say out loud?",
        // Body check-in
        "Where in your body do you feel today the most?",
        "What did your body do for you today that deserves a thank-you?",
        "How tired are you, honestly? What kind of tired is it?",
        "What would feel kind to your body right now?",
        "When did you feel most at ease in your body today?",
        "What's one thing your body has been quietly asking for?",
        // Tiny wins
        "What's something small you handled today that no one saw?",
        "What did you do today that was slightly hard — and you did it anyway?",
        "Name one thing you finished today, however small.",
        "What went a little better today than it did last time?",
        "What's a tiny choice you made today that you're glad about?",
        "What did you show up for today, even without feeling like it?",
        // Small pleasures
        "What tasted, sounded, or smelled good today?",
        "What's the coziest moment you had today?",
        "Did anything today feel like a small gift you didn't ask for?",
        "What's something you saw today that you'd point out to a friend?",
        "What little routine felt good today?",
        "If you could bottle one minute from today, which one?",
        // Self-kindness
        "What would you say to a friend who had your day?",
        "What are you allowed to stop carrying tonight?",
        "What's one gentle thing you could forgive yourself for today?",
        "If today was a lot, what's one soft thing you can give yourself this evening?",
        "What do you need more of tomorrow — rest, quiet, company, or something else?",
        "What's something you did today that was enough, exactly as it was?",
        "What's one expectation you could set down for a while?",
        "How did you take care of yourself today, even accidentally?",
        "What would 'being on your own side' look like tonight?",
        "What's something kind you hope tomorrow brings you?"
    ]

    /// The prompt of the day: a deterministic rotation seeded by the dateKey (`yyyy-MM-dd`), so
    /// every launch — and every device — shows the same prompt on the same day, with no stored
    /// state. Uses a stable FNV-1a hash (Swift's `Hasher` is seed-randomized per process, which
    /// would break determinism).
    static func prompt(for dateKey: String) -> String {
        assert(!prompts.isEmpty, "prompt library must not be empty")
        let index = Int(stableSeed(dateKey) % UInt64(prompts.count))
        return prompts[index]
    }

    /// FNV-1a over the UTF-8 bytes — tiny, stable across launches/devices/OS versions.
    static func stableSeed(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
