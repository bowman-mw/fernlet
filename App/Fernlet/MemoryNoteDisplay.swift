import Foundation
import FernletDomainModel

/// App-target display fork over ``MemoryNote`` for the Settings "Core memory" page (owner decision
/// 2026-09-23: a journal entry leaves only its emotion in Core Memory unless an on-device summary
/// replaces it).
///
/// An emotion-only memory stores a TOKEN — the ``FeelingTag`` raw value in `category` — and no text,
/// so the sentence a person reads is built here, at render time, in the reader's language. Storing
/// the sentence instead would freeze it in whatever language wrote it and sync that copy to every
/// device (the localization wall: tokens never localize, and display text is never persisted).
///
/// Switching on the CASE rather than interpolating the mood word into one template is deliberate:
/// each sentence is whole for a translator, so gender and article agreement stay the translator's
/// call, and a new `FeelingTag` case is a compiler error here rather than a silently English row.
extension MemoryNote {
    /// What the Core memory page shows for this memory: its own text when it has some (an on-device
    /// summary, or words the user typed), otherwise the localized sentence for its feeling. A text-less
    /// memory whose category is no feeling this build knows still reads as a sentence, never as an
    /// empty row.
    var displayText: String {
        guard text.isEmpty else { return text }
        guard let feeling = emotionOnlyFeeling else {
            return String(localized: "memory.emotionOnly.unknown", defaultValue: "You wrote in your journal.",
                          comment: "Core memory row for a journal entry whose feeling this version does not recognize. Only the feeling is kept, never the words.")
        }
        return feeling.memorySentence
    }
}

extension FeelingTag {
    /// The one-line Core memory a journal entry with this feeling reads as when only its emotion was
    /// kept — the entry's own words never reach Core Memory.
    var memorySentence: String {
        switch self {
        case .bright:
            String(localized: "memory.emotionOnly.bright", defaultValue: "You wrote on a bright day.",
                   comment: "Core memory row: a journal entry tagged Bright. Only the feeling is kept, never the words.")
        case .good:
            String(localized: "memory.emotionOnly.good", defaultValue: "You wrote on a good day.",
                   comment: "Core memory row: a journal entry tagged Good. Only the feeling is kept, never the words.")
        case .neutral:
            String(localized: "memory.emotionOnly.neutral", defaultValue: "You wrote on a neutral day.",
                   comment: "Core memory row: a journal entry tagged Neutral. Only the feeling is kept, never the words.")
        case .quiet:
            String(localized: "memory.emotionOnly.quiet", defaultValue: "You wrote on a quiet day.",
                   comment: "Core memory row: a journal entry tagged Quiet. Only the feeling is kept, never the words.")
        case .tired:
            String(localized: "memory.emotionOnly.tired", defaultValue: "You wrote on a tired day.",
                   comment: "Core memory row: a journal entry tagged Tired. Only the feeling is kept, never the words.")
        case .hard:
            String(localized: "memory.emotionOnly.hard", defaultValue: "You wrote on a hard day.",
                   comment: "Core memory row: a journal entry tagged Hard. Only the feeling is kept, never the words.")
        }
    }
}
