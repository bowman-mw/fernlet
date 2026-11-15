//
//  TierTwoTravel.swift
//  LocalPersistence
//
//  The travel days Tier-2 reads (G7 follow-on, owner decisions 2026-11-15), as plain values.
//

import Foundation

/// One travel day as Tier-2 reads it: the English city names of that day's flight, when the passport
/// knows them. Both nil for a travel day known by its day key only (a ticket's day, the day after an
/// overnight flight, or a flight since deleted from the passport).
///
/// City names only, by design: never an airport code, a time or a place (World-Airports-Spec §13, the
/// owner lifted the "nothing travel-related reaches the AI" rule for the city alone on 2026-11-15).
public nonisolated struct TierTwoTravelDay: Equatable, Sendable {
    /// The city the day's flight left from, in English.
    public var fromCity: String?
    /// The city the day's flight landed in, in English.
    public var toCity: String?

    /// A travel day; both cities default to unknown.
    public init(fromCity: String? = nil, toCity: String? = nil) {
        self.fromCity = fromCity
        self.toCity = toCity
    }
}

/// The travel input to `TierTwoMemoryEngine`: the travel days by `yyyy-MM-dd` day key, and whether
/// the city lines may be written.
///
/// Built by the app from the map's vault (the remembered travel days) and the passport's flights, and
/// handed over as plain values, so `LocalPersistence` never reaches the map's store. Empty (``none``)
/// in a decoy and with "Airports and flights" off.
///
/// **The guard rail on cities** (orchestrator's call, 2026-11-15, flagged for the owner): a city
/// reaches Tier-2 memory text only while ``namesCities`` is true, and the app sets it only while the
/// AI that reads memory runs on this iPhone. Tier-2 text reaches a prompt only through
/// `MemoryAgent` into the `light` tier, which `FernletModelRouter` pins to the on-device model (it
/// fails closed on any destination that leaves the device). With ``namesCities`` false the travel
/// record is still written, without its city line.
public nonisolated struct TierTwoTravel: Equatable, Sendable {
    /// The travel days, by day key.
    public var days: [String: TierTwoTravelDay]
    /// Whether the record may name a city (the guard rail above).
    public var namesCities: Bool

    /// The most travel days one input carries (a bound; the app keeps far fewer).
    public static let maxDays = 64

    /// No travel at all: a decoy, "Airports and flights" off, or nothing known.
    public static let none = TierTwoTravel(days: [:], namesCities: false)

    /// Travel input; `days` beyond ``maxDays`` keep the newest keys.
    public init(days: [String: TierTwoTravelDay], namesCities: Bool) {
        if days.count > Self.maxDays {
            let kept = Set(days.keys.sorted().suffix(Self.maxDays))
            self.days = days.filter { kept.contains($0.key) }
        } else {
            self.days = days
        }
        self.namesCities = namesCities
    }
}

/// A lock-protected holder of the newest ``TierTwoTravel``, so a refresh that runs wherever its
/// repository runs can read the snapshot the app published last without reaching the map's vault.
///
/// The app publishes into it when the Move page remembers travel days and when the map loads at
/// launch or on return to the foreground; the Tier-2 refresher reads it after each save. A reference
/// type on purpose (one holder shared by the publisher and the refresher), `Sendable` because every
/// access goes through ``lock``.
public final class TierTwoTravelHolder: @unchecked Sendable {
    /// Guards ``stored``.
    private let lock = NSLock()
    /// The newest published snapshot.
    private var stored = TierTwoTravel.none

    /// An empty holder (``TierTwoTravel/none``).
    public init() {}

    /// The newest published snapshot.
    public var snapshot: TierTwoTravel {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// Replaces the snapshot.
    public func publish(_ travel: TierTwoTravel) {
        lock.lock()
        defer { lock.unlock() }
        stored = travel
    }
}
