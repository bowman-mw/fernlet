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

/// A static, curated library of warm journaling prompts with a deterministic daily rotation.
///
/// Deliberately NOT AI: journal text is walled from every model (S3), and the prompt of the day
/// must be identical on every launch and every device, so ``prompt(for:)`` is a pure function of
/// the dateKey seeded by a stable FNV-1a hash. ``JournalSheet``'s dismissible inspiration chip is
/// the only consumer — prompts are inspiration only, never required, never blocking.
enum JournalPromptLibrary {
    /// ~40 gentle prompts across gratitude, naming emotions, body check-ins, tiny wins, small
    /// pleasures, and self-kindness. Warm and non-clinical by design — no "symptoms", no scores,
    /// no shoulds.
    ///
    /// Display copy, resolved in the device's language (Spanish round, 2026-10-20). No prompt is a
    /// token: the rotation picks by INDEX (``prompt(for:)``), nothing stores or compares a prompt's
    /// text, and "Start from this" copies the drawn words into the user's own entry, where they
    /// are the user's text from then on. The keys are numbered per theme, so reordering this
    /// array moves which prompt a day draws but never which words a key holds.
    static let prompts: [String] = [
        // Gratitude
        String(localized: "journal.dailyPrompt.gratitude.1",
               defaultValue: "What's one small thing today that you'd quietly like to keep?",
               comment: "Journal sheet: the daily inspiration prompt (gratitude), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.gratitude.2",
               defaultValue: "Who made your day a little lighter — even in a tiny way?",
               comment: "Journal sheet: the daily inspiration prompt (gratitude), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.gratitude.3",
               defaultValue: "Name something ordinary that worked today. The kettle counts.",
               comment: "Journal sheet: the daily inspiration prompt (gratitude), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.gratitude.4",
               defaultValue: "What's something your past self set up that today-you got to enjoy?",
               comment: "Journal sheet: the daily inspiration prompt (gratitude), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.gratitude.5",
               defaultValue: "What made you smile today, even for a second?",
               comment: "Journal sheet: the daily inspiration prompt (gratitude), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.gratitude.6",
               defaultValue: "What's one comfort you usually overlook?",
               comment: "Journal sheet: the daily inspiration prompt (gratitude), a gentle question the user may start an entry from"),
        // Naming emotions
        String(localized: "journal.dailyPrompt.emotions.1",
               defaultValue: "If today had a weather report, what would it say?",
               comment: "Journal sheet: the daily inspiration prompt (naming a feeling), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.emotions.2",
               defaultValue: "What feeling visited you most today? No need to explain it.",
               comment: "Journal sheet: the daily inspiration prompt (naming a feeling), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.emotions.3",
               defaultValue: "Was there a moment today when your mood shifted? What was nearby?",
               comment: "Journal sheet: the daily inspiration prompt (naming a feeling), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.emotions.4",
               defaultValue: "What's one word for how you feel right now — and one for how you'd like to feel tomorrow?",
               comment: "Journal sheet: the daily inspiration prompt (naming a feeling), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.emotions.5",
               defaultValue: "Is anything sitting a little heavy tonight? You can just name it and stop there.",
               comment: "Journal sheet: the daily inspiration prompt (naming a feeling), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.emotions.6",
               defaultValue: "What did you feel today that you didn't say out loud?",
               comment: "Journal sheet: the daily inspiration prompt (naming a feeling), a gentle question the user may start an entry from"),
        // Body check-in
        String(localized: "journal.dailyPrompt.body.1",
               defaultValue: "Where in your body do you feel today the most?",
               comment: "Journal sheet: the daily inspiration prompt (a body check-in), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.body.2",
               defaultValue: "What did your body do for you today that deserves a thank-you?",
               comment: "Journal sheet: the daily inspiration prompt (a body check-in), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.body.3",
               defaultValue: "How tired are you, honestly? What kind of tired is it?",
               comment: "Journal sheet: the daily inspiration prompt (a body check-in), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.body.4",
               defaultValue: "What would feel kind to your body right now?",
               comment: "Journal sheet: the daily inspiration prompt (a body check-in), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.body.5",
               defaultValue: "When did you feel most at ease in your body today?",
               comment: "Journal sheet: the daily inspiration prompt (a body check-in), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.body.6",
               defaultValue: "What's one thing your body has been quietly asking for?",
               comment: "Journal sheet: the daily inspiration prompt (a body check-in), a gentle question the user may start an entry from"),
        // Tiny wins
        String(localized: "journal.dailyPrompt.wins.1",
               defaultValue: "What's something small you handled today that no one saw?",
               comment: "Journal sheet: the daily inspiration prompt (tiny wins), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.wins.2",
               defaultValue: "What did you do today that was slightly hard — and you did it anyway?",
               comment: "Journal sheet: the daily inspiration prompt (tiny wins), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.wins.3",
               defaultValue: "Name one thing you finished today, however small.",
               comment: "Journal sheet: the daily inspiration prompt (tiny wins), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.wins.4",
               defaultValue: "What went a little better today than it did last time?",
               comment: "Journal sheet: the daily inspiration prompt (tiny wins), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.wins.5",
               defaultValue: "What's a tiny choice you made today that you're glad about?",
               comment: "Journal sheet: the daily inspiration prompt (tiny wins), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.wins.6",
               defaultValue: "What did you show up for today, even without feeling like it?",
               comment: "Journal sheet: the daily inspiration prompt (tiny wins), a gentle question the user may start an entry from"),
        // Small pleasures
        String(localized: "journal.dailyPrompt.pleasures.1",
               defaultValue: "What tasted, sounded, or smelled good today?",
               comment: "Journal sheet: the daily inspiration prompt (small pleasures), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.pleasures.2",
               defaultValue: "What's the coziest moment you had today?",
               comment: "Journal sheet: the daily inspiration prompt (small pleasures), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.pleasures.3",
               defaultValue: "Did anything today feel like a small gift you didn't ask for?",
               comment: "Journal sheet: the daily inspiration prompt (small pleasures), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.pleasures.4",
               defaultValue: "What's something you saw today that you'd point out to a friend?",
               comment: "Journal sheet: the daily inspiration prompt (small pleasures), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.pleasures.5",
               defaultValue: "What little routine felt good today?",
               comment: "Journal sheet: the daily inspiration prompt (small pleasures), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.pleasures.6",
               defaultValue: "If you could bottle one minute from today, which one?",
               comment: "Journal sheet: the daily inspiration prompt (small pleasures), a gentle question the user may start an entry from"),
        // Self-kindness
        String(localized: "journal.dailyPrompt.kindness.1",
               defaultValue: "What would you say to a friend who had your day?",
               comment: "Journal sheet: the daily inspiration prompt (self-kindness), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.kindness.2",
               defaultValue: "What are you allowed to stop carrying tonight?",
               comment: "Journal sheet: the daily inspiration prompt (self-kindness), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.kindness.3",
               defaultValue: "What's one gentle thing you could forgive yourself for today?",
               comment: "Journal sheet: the daily inspiration prompt (self-kindness), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.kindness.4",
               defaultValue: "If today was a lot, what's one soft thing you can give yourself this evening?",
               comment: "Journal sheet: the daily inspiration prompt (self-kindness), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.kindness.5",
               defaultValue: "What do you need more of tomorrow — rest, quiet, company, or something else?",
               comment: "Journal sheet: the daily inspiration prompt (self-kindness), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.kindness.6",
               defaultValue: "What's something you did today that was enough, exactly as it was?",
               comment: "Journal sheet: the daily inspiration prompt (self-kindness), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.kindness.7",
               defaultValue: "What's one expectation you could set down for a while?",
               comment: "Journal sheet: the daily inspiration prompt (self-kindness), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.kindness.8",
               defaultValue: "How did you take care of yourself today, even accidentally?",
               comment: "Journal sheet: the daily inspiration prompt (self-kindness), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.kindness.9",
               defaultValue: "What would 'being on your own side' look like tonight?",
               comment: "Journal sheet: the daily inspiration prompt (self-kindness), a gentle question the user may start an entry from"),
        String(localized: "journal.dailyPrompt.kindness.10",
               defaultValue: "What's something kind you hope tomorrow brings you?",
               comment: "Journal sheet: the daily inspiration prompt (self-kindness), a gentle question the user may start an entry from")
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
