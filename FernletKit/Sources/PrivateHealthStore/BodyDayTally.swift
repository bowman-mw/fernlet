import Foundation

// BodyDayTally.swift — one day's bathroom-visit count and free-meal tags (World bodybuilding spec,
// §5–§7, round 7 piece B1). The value sealed whole into one `BodyTally` row by
// `BodyTallyRepository`; never in the synced day blob, never in CloudKit as plaintext.

/// One day's sealed tallies: how many bathroom visits were counted and which meals were tagged as
/// a free meal (the owner's word, never "cheat").
///
/// The whole value is the sealed payload of one `BodyTally` row, so it carries its own ``dayKey`` —
/// the row has no plaintext day column. Every initializer and the decoder SANITIZE rather than
/// trust: the visit count is clamped to `0...maxBathroomVisits`, the free-meal ids are
/// de-duplicated (first occurrence kept) and capped at ``maxFreeMeals``, so a value that exists is
/// always in bounds. A day key that is not a `yyyy-MM-dd` calendar day does not decode at all.
///
/// Gentle by design: a tally, never a streak or a grade — there is no "missed" state, and an empty
/// day is simply no row (``isEmpty``).
///
/// The `CodingKeys` raw values are FROZEN storage tokens: renaming one orphans every sealed tally.
/// `Sendable`: a plain value crossing `performAndWait`'s `@Sendable` closure.
public nonisolated struct BodyDayTally: Codable, Equatable, Sendable {
    /// The payload format written beside each row (plaintext `schemaVersion` column). A row written
    /// under a higher number is a newer build's and is never treated as dead.
    public static let schemaVersion = 1
    /// The most bathroom visits one day holds ("a count per day, nothing else", spec §5).
    public static let maxBathroomVisits = 30
    /// The most meals one day can tag as a free meal.
    public static let maxFreeMeals = 20

    /// The `yyyy-MM-dd` day this tally belongs to.
    public let dayKey: String
    /// Bathroom visits counted on the day, in `0...maxBathroomVisits`.
    public private(set) var bathroomVisits: Int
    /// The meals tagged as a free meal on the day: unique, at most ``maxFreeMeals``, in tag order.
    public private(set) var freeMealIDs: [UUID]
    /// When the tally last changed.
    public var updatedAt: Date

    /// Creates a sanitized tally (see the type's documentation).
    ///
    /// - Parameters:
    ///   - dayKey: The `yyyy-MM-dd` day; check it with ``isValidDayKey(_:)`` first — the repository
    ///     refuses to store a tally whose key is not a calendar day.
    ///   - bathroomVisits: Clamped to `0...maxBathroomVisits`.
    ///   - freeMealIDs: De-duplicated and capped at ``maxFreeMeals``.
    ///   - updatedAt: The change stamp.
    public init(dayKey: String, bathroomVisits: Int = 0, freeMealIDs: [UUID] = [], updatedAt: Date = Date()) {
        self.dayKey = dayKey
        self.bathroomVisits = Self.clampedVisits(bathroomVisits)
        self.freeMealIDs = Self.sanitizedMealIDs(freeMealIDs)
        self.updatedAt = updatedAt
    }

    /// Whether the tally holds nothing — no visits and no tagged meal. An empty day is stored as no
    /// row at all.
    public var isEmpty: Bool { bathroomVisits == 0 && freeMealIDs.isEmpty }

    /// Whether `mealID` is tagged as a free meal on this day.
    public func isFreeMeal(_ mealID: UUID) -> Bool { freeMealIDs.contains(mealID) }

    /// Whether the content (visits and tags) equals `other`'s, ignoring the stamp — what decides that
    /// a write changed nothing.
    public func hasSameContent(as other: BodyDayTally) -> Bool {
        dayKey == other.dayKey && bathroomVisits == other.bathroomVisits && freeMealIDs == other.freeMealIDs
    }

    /// A copy with one more bathroom visit, or `nil` when the day already holds
    /// ``maxBathroomVisits`` (the tap is refused, never wrapped or dropped silently).
    public func addingBathroomVisit() -> BodyDayTally? {
        guard bathroomVisits < Self.maxBathroomVisits else { return nil }
        var copy = self
        copy.bathroomVisits += 1
        return copy
    }

    /// A copy whose visit count is `count`, clamped to `0...maxBathroomVisits`.
    public func settingBathroomVisits(_ count: Int) -> BodyDayTally {
        var copy = self
        copy.bathroomVisits = Self.clampedVisits(count)
        return copy
    }

    /// A copy with `mealID` tagged (or untagged), or `nil` when tagging would pass
    /// ``maxFreeMeals``. Tagging a tagged meal or untagging an untagged one returns an equal copy.
    public func settingFreeMeal(_ isFree: Bool, mealID: UUID) -> BodyDayTally? {
        var copy = self
        if isFree {
            guard !freeMealIDs.contains(mealID) else { return copy }
            guard freeMealIDs.count < Self.maxFreeMeals else { return nil }
            copy.freeMealIDs.append(mealID)
        } else {
            copy.freeMealIDs.removeAll { $0 == mealID }
        }
        return copy
    }

    /// This tally merged with another copy of the same day — the Sealed iCloud backup's restore rule
    /// (round 7 piece B2): the bathroom visits are the HIGHER of the two counts (two iPhones counting
    /// the same visits must not add them up), the free-meal tags are the union (this copy's first, in
    /// order, then the other's new ones, capped at ``maxFreeMeals``), and the stamp is the later one.
    /// Commutative in content, idempotent (`a.merged(with: a)` has `a`'s content), and it never removes
    /// anything this copy holds below the caps. A tally of another day is returned unchanged.
    public func merged(with other: BodyDayTally) -> BodyDayTally {
        guard other.dayKey == dayKey else { return self }
        return BodyDayTally(
            dayKey: dayKey,
            bathroomVisits: max(bathroomVisits, other.bathroomVisits),
            freeMealIDs: freeMealIDs + other.freeMealIDs,
            updatedAt: max(updatedAt, other.updatedAt)
        )
    }

    /// Whether `key` is a `yyyy-MM-dd` calendar day key: ten characters, digits around two dashes,
    /// month `01...12`, day `01...31`. Pure; no calendar lookup.
    public static func isValidDayKey(_ key: String) -> Bool {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard key.count == 10, parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
              let month = Int(parts[1]), let day = Int(parts[2]) else { return false }
        return (1...12).contains(month) && (1...31).contains(day)
    }

    // MARK: - Codable (frozen keys)

    /// The frozen at-rest field names — storage tokens, never renamed or localized.
    private enum CodingKeys: String, CodingKey {
        case dayKey
        case bathroomVisits
        case freeMealIDs
        case updatedAt
    }

    /// Decodes and sanitizes; a day key that is not a calendar day is a decoding error.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let dayKey = try container.decode(String.self, forKey: .dayKey)
        guard Self.isValidDayKey(dayKey) else {
            throw DecodingError.dataCorruptedError(forKey: .dayKey, in: container, debugDescription: "not a yyyy-MM-dd day key")
        }
        self.init(
            dayKey: dayKey,
            bathroomVisits: try container.decodeIfPresent(Int.self, forKey: .bathroomVisits) ?? 0,
            freeMealIDs: try container.decodeIfPresent([UUID].self, forKey: .freeMealIDs) ?? [],
            updatedAt: try container.decode(Date.self, forKey: .updatedAt)
        )
    }

    /// Encodes under the frozen keys.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dayKey, forKey: .dayKey)
        try container.encode(bathroomVisits, forKey: .bathroomVisits)
        try container.encode(freeMealIDs, forKey: .freeMealIDs)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    // MARK: - Sanitizing

    /// `count` clamped to `0...maxBathroomVisits`.
    private static func clampedVisits(_ count: Int) -> Int {
        min(max(count, 0), maxBathroomVisits)
    }

    /// `ids` de-duplicated (first occurrence kept) and capped at ``maxFreeMeals``.
    private static func sanitizedMealIDs(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        var result: [UUID] = []
        for id in ids where seen.insert(id).inserted {  // R2: bounded by `ids`, and stops at the cap.
            result.append(id)
            if result.count == maxFreeMeals { break }
        }
        return result
    }
}

private extension Character {
    /// Whether the character is one of the ten ASCII digits.
    nonisolated var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
