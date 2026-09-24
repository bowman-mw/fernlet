import Foundation
import SwiftUI
import Testing
import UIKit
import FernletDomainModel
import FernletUI
@testable import Fernlet

/// Every companion emotion, drawn at the Home companion's size (132 pt): a smoke test that each face
/// and motif renders, and — when `FERNLET_EMOTION_GALLERY_DIR` is set (pass it to `xcodebuild` as
/// `TEST_RUNNER_FERNLET_EMOTION_GALLERY_DIR`) — the PNG gallery for the owner's visual review.
///
/// Each frame is drawn at a fixed instant (`CompanionView.renderClock`) chosen so every looping
/// motif is mid-loop and visible, which also makes the PNGs byte-stable run to run.
@MainActor
struct CompanionEmotionGalleryTests {

    /// One gallery frame: a name, the band, the emotion (nil = the plain state face), the pose.
    struct Frame {
        let name: String
        let state: CompanionState
        let emotion: CompanionEmotion?
        var settled = false
        var gentleDay = false
    }

    /// The five plain state faces, every emotion on the band the engine pairs it with, and the
    /// settled pose on an ordinary and on a gentle day.
    static let frames: [Frame] = [
        Frame(name: "state-thriving", state: .thriving, emotion: nil),
        Frame(name: "state-okay", state: .okay, emotion: nil),
        Frame(name: "state-tired", state: .tired, emotion: nil),
        Frame(name: "state-resting", state: .resting, emotion: nil),
        Frame(name: "state-sick", state: .sick, emotion: nil),
        Frame(name: "happy", state: .thriving, emotion: .happy),
        Frame(name: "sad", state: .okay, emotion: .sad, gentleDay: true),
        Frame(name: "tired", state: .tired, emotion: .tired),
        Frame(name: "sleepy", state: .okay, emotion: .sleepy),
        Frame(name: "hungry", state: .okay, emotion: .hungry),
        Frame(name: "thirsty", state: .okay, emotion: .thirsty),
        Frame(name: "loved", state: .okay, emotion: .loved),
        Frame(name: "comforted", state: .okay, emotion: .comforted, gentleDay: true),
        Frame(name: "playful", state: .okay, emotion: .playful),
        Frame(name: "calm", state: .okay, emotion: .calm),
        Frame(name: "frazzled", state: .okay, emotion: .frazzled),
        Frame(name: "settled", state: .okay, emotion: nil, settled: true),
        Frame(name: "settled-gentle", state: .okay, emotion: .sad, settled: true, gentleDay: true)
    ]

    /// One second past the reference date: every motif loop is visibly mid-cycle there.
    static let renderInstant = Date(timeIntervalSinceReferenceDate: 1.0)

    /// The companion exactly as Home draws it, on the parchment it sits on.
    static func card(_ frame: Frame) -> some View {
        VStack(spacing: 6) {
            CompanionView(state: frame.state, size: 132, emotion: frame.emotion, gentleDay: frame.gentleDay,
                          settled: frame.settled, renderClock: renderInstant)
                .frame(width: 220, height: 200)
            Text(verbatim: frame.name)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.bark)
        }
        .padding(.vertical, 8)
        .background(Color.parchment)
    }

    @Test func everyEmotionRendersAtTheHomeSize() throws {
        let directory = ProcessInfo.processInfo.environment["FERNLET_EMOTION_GALLERY_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for frame in Self.frames {
            let renderer = ImageRenderer(content: Self.card(frame))
            renderer.scale = 2
            let image = try #require(renderer.uiImage, "\(frame.name) did not render")
            #expect(image.size.width >= 200 && image.size.height >= 200, "\(frame.name) rendered at \(image.size)")
            guard let directory, let png = image.pngData() else { continue }
            try png.write(to: directory.appendingPathComponent("home-\(frame.name).png"))
        }
        guard let directory else { return }
        let sheet = ImageRenderer(content: Self.contactSheet())
        sheet.scale = 2
        let png = try #require(sheet.uiImage?.pngData(), "the contact sheet did not render")
        try png.write(to: directory.appendingPathComponent("home-contact-sheet.png"))
    }

    /// All frames on one sheet, six to a row.
    static func contactSheet() -> some View {
        let rows = stride(from: 0, to: frames.count, by: 6).map { Array(frames[$0..<min($0 + 6, frames.count)]) }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(rows[row].indices, id: \.self) { index in card(rows[row][index]) }
                }
            }
        }
        .background(Color.parchment)
    }
}
