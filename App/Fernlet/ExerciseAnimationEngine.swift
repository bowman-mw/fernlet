//
//  ExerciseAnimationEngine.swift
//  Fernlet
//
//  The approved motion engine, run unchanged in a JavaScriptCore context: `movements.js` and
//  `motion-engine.js` from ExerciseAnimations.bundle are evaluated as classic scripts, in that order,
//  and a small local bridge serialises the poses the Swift renderer needs. JavaScriptCore here only
//  computes numbers: no web view, no network API, nothing leaves the process.
//

import Foundation
import JavaScriptCore

/// The approved motion engine in a JavaScriptCore context, sampling poses for the Swift renderer.
///
/// Not thread-safe: it belongs to one `ExerciseAnimationRenderer`, on that renderer's serial queue.
nonisolated final class ExerciseAnimationEngine {
    /// The bundle directory that carries the approved engine files, byte-identical to the package.
    static let bundleName = "ExerciseAnimations"
    /// The engine files, evaluated in this order (later scripts read earlier scripts' globals).
    static let scriptNames = ["movements", "motion-engine"]

    /// The bridge, evaluated after the engine. It reads the engine's global lexical `movements`,
    /// `MOTIONS`, `sampleExercise` and `socket`, and returns JSON strings that keep the engine's
    /// array order (equipment draw order decides depth ties). Its own code only copies fields.
    static let bridgeSource = """
    (function () {
      const byID = new Map(movements.map(function (e) { return [e.id, e]; }));
      function objectOut(o) {
        const b = o.basis;
        return { type: o.type, color: o.color, points: o.points, width: o.width, center: o.center,
                 size: o.size, basis: b ? { right: b.right, forward: b.forward, up: b.up } : null,
                 axis: o.axis, half: o.half, radius: o.radius, length: o.length, direction: o.direction };
      }
      function poseOut(p, sockets) {
        return { center: p.center, view: p.view, hip: p.hip, up: p.up, forward: p.forward, right: p.right,
                 hipRight: p.hipRight, shoulder: p.shoulder, head: p.head, headUp: p.headUp || null,
                 headRight: p.headRight || null, grip: p.grip ? String(p.grip) : null,
                 handStyle: typeof p.handStyle === 'string' ? p.handStyle : null, spine: p.spine, j: p.j,
                 feet: p.feet.map(function (f) { return { ankle: f.ankle, right: f.right, forward: f.forward, up: f.up }; }),
                 objects: p.objects.map(objectOut),
                 sockets: sockets ? [socket(p, -1), socket(p, 1), socket(p, -1, false), socket(p, 1, false)] : null };
      }
      return {
        exercise: function (id) {
          const e = byID.get(id);
          if (!e) return null;
          return JSON.stringify({ id: e.id, hold: !!e.hold,
                                  viewPreset: typeof e.viewPreset === 'string' ? e.viewPreset : null,
                                  viewElevation: e.viewElevation ?? null });
        },
        sample: function (id, t) {
          const e = byID.get(id);
          return e ? JSON.stringify(poseOut(sampleExercise(e, t), true)) : null;
        },
        framing: function (id) {
          const e = byID.get(id);
          if (!e) return null;
          const poses = [];
          for (let i = 0; i <= 48; i++) poses.push(poseOut(MOTIONS[e.motion](e, e.hold ? 0 : i / 48), false));
          return JSON.stringify(poses);
        }
      };
    })()
    """

    /// The context the engine lives in.
    private let context: JSContext
    /// The bridge object `bridgeSource` returned.
    private let bridge: JSValue
    /// Decodes the bridge's JSON (JSONDecoder reads every double exactly; JSONSerialization does not).
    private let decoder = JSONDecoder()

    /// Loads the engine from `bundle`'s ExerciseAnimations.bundle; nil when a file is missing or a script
    /// throws.
    init?(bundle: Bundle) {
        guard let directory = bundle.url(forResource: Self.bundleName, withExtension: "bundle"),
              let engineBundle = Bundle(url: directory) else { return nil }
        guard let context = JSContext() else { return nil }
        for name in Self.scriptNames {
            guard let url = engineBundle.url(forResource: name, withExtension: "js"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            context.evaluateScript(source)
            guard context.exception == nil else { return nil }
        }
        guard let bridge = context.evaluateScript(Self.bridgeSource), context.exception == nil,
              bridge.isObject else { return nil }
        self.context = context
        self.bridge = bridge
    }

    /// The approved catalog fields of `exerciseID`, or nil for an unknown ID.
    func exercise(_ exerciseID: String) -> ExerciseAnimationExerciseInfo? {
        decode(ExerciseAnimationExerciseInfo.self, method: "exercise", arguments: [exerciseID])
    }

    /// `sampleExercise(e, progress)` for `exerciseID`, with its arm and hip sockets.
    func pose(_ exerciseID: String, progress: Double) -> ExerciseAnimationPose? {
        decode(ExerciseAnimationPose.self, method: "sample", arguments: [exerciseID, progress])
    }

    /// The 49 raw loop poses `frameCamera` bounds (`MOTIONS[e.motion](e, e.hold ? 0 : i/48)`).
    func framingPoses(_ exerciseID: String) -> [ExerciseAnimationPose]? {
        decode([ExerciseAnimationPose].self, method: "framing", arguments: [exerciseID])
    }

    /// Calls a bridge method and decodes its JSON string; nil when it returns null or throws.
    private func decode<Value: Decodable>(_ type: Value.Type, method: String, arguments: [Any]) -> Value? {
        let result = bridge.invokeMethod(method, withArguments: arguments)
        guard context.exception == nil else {
            context.exception = nil
            return nil
        }
        guard let result, result.isString, let json = result.toString() else { return nil }
        return try? decoder.decode(type, from: Data(json.utf8))
    }
}
