// BodyWeightSample.swift
// FernletDomainModel
//
// One body-weight reading. The Bodybuilding calendar draws these from Health (`BodyWeightReader`, in
// the app). The workout planner does not read them: the body-weight trend that once sat beside this
// type (G13) was never fed a weigh-in and was removed on 2026-11-10 (w10).

import Foundation

/// One weigh-in the person logged.
public nonisolated struct BodyWeightSample: Equatable, Sendable {
    public var date: Date
    public var kilograms: Double

    public init(date: Date, kilograms: Double) {
        self.date = date
        self.kilograms = kilograms
    }
}
