import ObjectiveC
import UIKit
import XCTest

/// Replays genuine multi-finger touch sequences in a UI test.
///
/// XCUITest's public API has no free-form multi-touch: beyond one-finger drags it offers only
/// `pinch`, `rotate` and `twoFingerTap`, none of which can hold one finger on the canvas while a
/// second one taps a swatch, or drag two fingers in parallel. XCUITest builds all of its own
/// gestures from two classes in XCUIAutomation.framework — `XCPointerEventPath` (one finger's
/// down / move / up timeline) and `XCSynthesizedEventRecord` (the paths replayed together) — and
/// this drives those same classes, looked up by name at run time.
///
/// They are not public API. When a future Xcode renames them, ``isAvailable`` turns false and
/// ``perform(_:)`` throws `XCTSkip` naming what is missing, so a test built on this is reported
/// SKIPPED — never silently passed, and never a crash.
///
/// Memory: the paths and the record are created with `+alloc` / `-init…` called through their
/// C function pointers with raw pointers, so ARC never sees the `init` family's consumed
/// receiver; each object is handed to Swift once, retained, by `takeRetainedValue()`.
@MainActor
enum MultiTouchSynthesizer {

    /// One finger's timeline, in screen points and seconds from the start of the gesture.
    struct Finger {
        /// Where the finger lands.
        let down: CGPoint
        /// When it lands.
        let downAt: TimeInterval
        /// Each later position with its time, in order. Empty for a finger that holds still.
        let moves: [(point: CGPoint, at: TimeInterval)]
        /// When it lifts, at its last position.
        let liftAt: TimeInterval

        /// A finger that lands at `point` at `at` and lifts `duration` later without moving.
        static func tap(at point: CGPoint, at start: TimeInterval, duration: TimeInterval = 0.1) -> Finger {
            Finger(down: point, downAt: start, moves: [], liftAt: start + duration)
        }

        /// A finger that lands at `from` at `start` and slides to `to` over `duration` in `steps`
        /// evenly spaced samples, then lifts.
        static func drag(from: CGPoint, to: CGPoint, start: TimeInterval,
                         duration: TimeInterval, steps: Int = 20) -> Finger {
            let count = max(1, min(steps, 240))
            let moves = (1...count).map { step -> (point: CGPoint, at: TimeInterval) in
                let progress = CGFloat(step) / CGFloat(count)
                let point = CGPoint(x: from.x + (to.x - from.x) * progress,
                                    y: from.y + (to.y - from.y) * progress)
                return (point, start + duration * Double(progress))
            }
            return Finger(down: from, downAt: start, moves: moves, liftAt: start + duration + 0.05)
        }
    }

    private typealias AllocFunction = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
    private typealias InitPathFunction =
        @convention(c) (UnsafeMutableRawPointer, Selector, CGPoint, Double) -> UnsafeMutableRawPointer?
    private typealias InitRecordFunction =
        @convention(c) (UnsafeMutableRawPointer, Selector, NSString, Int) -> UnsafeMutableRawPointer?
    private typealias MoveFunction = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
    private typealias LiftFunction = @convention(c) (AnyObject, Selector, Double) -> Void
    private typealias AddPathFunction = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    private typealias SynthesizeFunction = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer?) -> ObjCBool

    private static let pathClassName = "XCPointerEventPath"
    private static let recordClassName = "XCSynthesizedEventRecord"
    private static let initPath = NSSelectorFromString("initForTouchAtPoint:offset:")
    private static let move = NSSelectorFromString("moveToPoint:atOffset:")
    private static let lift = NSSelectorFromString("liftUpAtOffset:")
    private static let initRecord = NSSelectorFromString("initWithName:interfaceOrientation:")
    private static let addPath = NSSelectorFromString("addPointerEventPath:")
    private static let synthesize = NSSelectorFromString("synthesizeWithError:")

    /// What is missing from this Xcode's XCUIAutomation, or nil when everything is there.
    static var missingPiece: String? {
        guard let path = NSClassFromString(pathClassName) else { return pathClassName }
        guard let record = NSClassFromString(recordClassName) else { return recordClassName }
        for selector in [initPath, move, lift] where class_getInstanceMethod(path, selector) == nil {
            return "\(pathClassName) \(NSStringFromSelector(selector))"
        }
        for selector in [initRecord, addPath, synthesize] where class_getInstanceMethod(record, selector) == nil {
            return "\(recordClassName) \(NSStringFromSelector(selector))"
        }
        return nil
    }

    /// True when this Xcode still carries the event-synthesis classes.
    static var isAvailable: Bool { missingPiece == nil }

    /// Replays every finger together, in portrait, and waits for the replay to finish.
    static func perform(_ fingers: [Finger], name: String = "multi-touch") throws {
        if let missing = missingPiece {
            throw XCTSkip("XCUIAutomation no longer has \(missing); multi-touch replay is unavailable")
        }
        guard !fingers.isEmpty,
              let pathClass = NSClassFromString(pathClassName),
              let recordClass = NSClassFromString(recordClassName) else { return }
        let record = try make(recordClass, initRecord, as: InitRecordFunction.self) { function, raw in
            function(raw, initRecord, name as NSString, UIInterfaceOrientation.portrait.rawValue)
        }
        let add = unsafeBitCast(try method(of: recordClass, addPath), to: AddPathFunction.self)
        for finger in fingers.prefix(10) {
            add(record, addPath, try path(for: finger, pathClass: pathClass))
        }
        let run = unsafeBitCast(try method(of: recordClass, synthesize), to: SynthesizeFunction.self)
        guard run(record, synthesize, nil).boolValue else {
            throw XCTSkip("the multi-touch replay '\(name)' was refused by the event synthesizer")
        }
    }

    /// Builds one `XCPointerEventPath` from a finger's timeline.
    private static func path(for finger: Finger, pathClass: AnyClass) throws -> AnyObject {
        let path = try make(pathClass, initPath, as: InitPathFunction.self) { function, raw in
            function(raw, initPath, finger.down, finger.downAt)
        }
        let moveTo = unsafeBitCast(try method(of: pathClass, move), to: MoveFunction.self)
        for sample in finger.moves.prefix(240) {
            moveTo(path, move, sample.point, sample.at)
        }
        let liftUp = unsafeBitCast(try method(of: pathClass, lift), to: LiftFunction.self)
        liftUp(path, lift, finger.liftAt)
        return path
    }

    /// `+alloc` then the given `-init…`, returning the initialised object owned by Swift.
    private static func make<Function>(
        _ cls: AnyClass, _ initializer: Selector, as type: Function.Type,
        call: (Function, UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    ) throws -> AnyObject {
        let allocSelector = NSSelectorFromString("alloc")
        guard let metaclass = object_getClass(cls),
              let allocIMP = class_getMethodImplementation(metaclass, allocSelector) else {
            throw XCTSkip("cannot allocate \(NSStringFromClass(cls))")
        }
        let alloc = unsafeBitCast(allocIMP, to: AllocFunction.self)
        guard let raw = alloc(cls, allocSelector) else {
            throw XCTSkip("+alloc returned nil for \(NSStringFromClass(cls))")
        }
        let function = unsafeBitCast(try method(of: cls, initializer), to: Function.self)
        guard let initialised = call(function, raw) else {
            throw XCTSkip("\(NSStringFromSelector(initializer)) returned nil")
        }
        return Unmanaged<AnyObject>.fromOpaque(initialised).takeRetainedValue()
    }

    /// The implementation of an instance method (``missingPiece`` has already vouched for it).
    private static func method(of cls: AnyClass, _ selector: Selector) throws -> IMP {
        guard let implementation = class_getMethodImplementation(cls, selector) else {
            throw XCTSkip("\(NSStringFromClass(cls)) has no \(NSStringFromSelector(selector))")
        }
        return implementation
    }
}
