// MIT License
// Copyright (c) 2021-2026 LinearMouse

import GestureKit
import KeyKit
@testable import LinearMouse
import XCTest

private final class RecordingModifierKeySimulator: KeySimulating {
    struct ModifiedPress: Equatable {
        let keyCode: CGKeyCode
        let modifierFlags: CGEventFlags
        let restoringModifierFlags: CGEventFlags
    }

    private(set) var unmodifiedPresses: [[Key]] = []
    private(set) var modifiedPresses: [ModifiedPress] = []

    func down(keys _: [Key], tap _: CGEventTapLocation?) throws {}
    func up(keys _: [Key], tap _: CGEventTapLocation?) throws {}

    func press(keys: [Key], tap _: CGEventTapLocation?) throws {
        unmodifiedPresses.append(keys)
    }

    func press(keys _: [Key], modifierFlags _: CGEventFlags, tap _: CGEventTapLocation?) throws {
        XCTFail("Zoom should send a resolved physical shortcut")
    }

    func press(
        keys _: [Key],
        modifierFlags _: CGEventFlags,
        restoringModifierFlags _: CGEventFlags,
        tap _: CGEventTapLocation?
    ) throws {
        XCTFail("Zoom should send a resolved physical shortcut")
    }

    func press(
        keyCode: CGKeyCode,
        modifierFlags: CGEventFlags,
        restoringModifierFlags: CGEventFlags,
        tap _: CGEventTapLocation?
    ) throws {
        modifiedPresses.append(.init(
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            restoringModifierFlags: restoringModifierFlags
        ))
    }

    func reset() {}

    func modifiedCGEventFlags(of _: CGEvent) -> CGEventFlags? {
        nil
    }
}

final class ModifierActionsTransformerTests: XCTestCase {
    /// A layout where zoom-out is not on the US minus key, and zoom-in needs Shift.
    private static func zoomShortcut(zoomIn: Bool) -> KeyEquivalentResolver.Shortcut? {
        .init(keyCode: zoomIn ? 24 : 44, modifierFlags: zoomIn ? [.maskCommand, .maskShift] : .maskCommand)
    }

    func testModifierActions() throws {
        var event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: 1,
            wheel2: 2,
            wheel3: 0
        ))
        let modifiers = Scheme.Scrolling.Modifiers(
            command: .auto,
            shift: .alterOrientation,
            option: .changeSpeed(scale: 2),
            control: .changeSpeed(scale: 3)
        )
        let transformer = ModifierActionsTransformer(modifiers: .init(vertical: modifiers, horizontal: modifiers))
        event.flags = .maskCommand
        event.flags.insert(.maskShift)
        event.flags.insert(.maskAlternate)
        event.flags.insert(.maskControl)
        event = try XCTUnwrap(transformer.transform(event, in: EventTransformerContext(device: nil)))
        var view = ScrollWheelEventView(event)
        XCTAssertEqual(view.deltaX, 6)
        XCTAssertEqual(view.deltaY, 12)

        event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: 1,
            wheel2: 2,
            wheel3: 0
        ))
        event.flags = .maskCommand
        event.flags.insert(.maskShift)
        event.flags.insert(.maskAlternate)
        event = try XCTUnwrap(transformer.transform(event, in: EventTransformerContext(device: nil)))
        view = ScrollWheelEventView(event)
        XCTAssertEqual(view.deltaX, 2)
        XCTAssertEqual(view.deltaY, 4)
    }

    func testZoomAttachesCommandWithoutPressingCommandKey() throws {
        let keySimulator = RecordingModifierKeySimulator()
        var now: UInt64 = 0
        let modifiers = Scheme.Scrolling.Modifiers(command: .zoom)
        let transformer = ModifierActionsTransformer(
            modifiers: .init(vertical: modifiers, horizontal: modifiers),
            keySimulator: keySimulator,
            monotonicClock: { now },
            zoomShortcut: Self.zoomShortcut
        )
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        ))
        event.flags = .maskCommand

        XCTAssertNil(transformer.transform(event, in: EventTransformerContext(device: nil)))
        now = 300_000_000
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -1)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -10)
        XCTAssertNil(transformer.transform(event, in: EventTransformerContext(device: nil)))

        XCTAssertTrue(keySimulator.unmodifiedPresses.isEmpty)
        XCTAssertEqual(
            keySimulator.modifiedPresses,
            [
                .init(
                    keyCode: 24,
                    modifierFlags: [.maskCommand, .maskShift],
                    restoringModifierFlags: .maskCommand
                ),
                .init(
                    keyCode: 44,
                    modifierFlags: .maskCommand,
                    restoringModifierFlags: .maskCommand
                )
            ]
        )
    }

    func testZoomAndMappedCommandsShareDeviceCooldown() throws {
        let simulator = RecordingModifierKeySimulator()
        let throttle = ScrollActionThrottle()
        let recognizer = ScrollActionRecognizer(throttle: throttle)
        let input = ScrollInput(axis: .vertical, delta: 1, units: .detents)
        XCTAssertEqual(recognizer.consume(input, mapping: 0, repeats: false, at: 0), 1)
        var now: UInt64 = 60_000_000
        let modifiers = Scheme.Scrolling.Modifiers(control: .zoom)
        let transformer = ModifierActionsTransformer(
            modifiers: .init(vertical: modifiers, horizontal: modifiers),
            keySimulator: simulator,
            scrollThrottle: throttle,
            monotonicClock: { now },
            zoomShortcut: Self.zoomShortcut
        )
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0
        ))
        event.flags = .maskControl
        XCTAssertNil(transformer.transform(event, in: .init(device: nil)))
        XCTAssertTrue(simulator.modifiedPresses.isEmpty)
        now = 300_000_000
        XCTAssertNil(transformer.transform(event, in: .init(device: nil)))
        XCTAssertEqual(simulator.modifiedPresses.count, 1)
        XCTAssertEqual(recognizer.consume(input, mapping: 0, repeats: false, at: now), 0)
    }

    func testZoomMomentumStaysConsumedAfterModifierReleaseAndOnAnotherRoute() throws {
        let simulator = RecordingModifierKeySimulator()
        let ownership = ScrollGestureOwnership()
        let modifiers = Scheme.Scrolling.Modifiers(control: .zoom)
        let transformer = ModifierActionsTransformer(
            modifiers: .init(vertical: modifiers, horizontal: modifiers),
            keySimulator: simulator,
            scrollGesture: ownership,
            zoomShortcut: Self.zoomShortcut
        )
        let pipeline: [EventTransformer] = [ScrollGestureTransformer(ownership: ownership), transformer]
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 8, wheel2: 0, wheel3: 0
        ))
        event.flags = .maskControl
        XCTAssertNil(pipeline.transform(event, in: .init(device: nil)))
        XCTAssertEqual(simulator.modifiedPresses.count, 1)
        event.flags = []
        let view = ScrollWheelEventView(event)
        view.momentumPhase = .begin
        XCTAssertNil(pipeline.transform(event, in: .init(device: nil)))
        let next = ScrollGestureTransformer(ownership: ownership)
        XCTAssertNil(next.transform(event, in: .init(device: nil)))
        view.momentumPhase = .end
        XCTAssertNil(next.transform(event, in: .init(device: nil)))
        view.momentumPhase = .none
        view.scrollPhase = .began
        XCTAssertNotNil(pipeline.transform(event, in: .init(device: nil)))
        XCTAssertEqual(simulator.modifiedPresses.count, 1)
    }

    func testDirectScrollingAfterReleasingZoomModifierRestoresNativeMomentum() throws {
        let simulator = RecordingModifierKeySimulator()
        let ownership = ScrollGestureOwnership()
        let modifiers = Scheme.Scrolling.Modifiers(control: .zoom)
        let transformer = ModifierActionsTransformer(
            modifiers: .init(vertical: modifiers, horizontal: modifiers),
            keySimulator: simulator,
            scrollGesture: ownership,
            zoomShortcut: Self.zoomShortcut
        )
        let pipeline: [EventTransformer] = [ScrollGestureTransformer(ownership: ownership), transformer]
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 8, wheel2: 0, wheel3: 0
        ))
        let view = ScrollWheelEventView(event)
        view.momentumPhase = .none
        view.scrollPhase = .changed
        event.flags = .maskControl
        XCTAssertNil(pipeline.transform(event, in: .init(device: nil)))
        XCTAssertTrue(ownership.isOwned)
        event.flags = []
        XCTAssertNotNil(pipeline.transform(event, in: .init(device: nil)))
        XCTAssertFalse(ownership.isOwned)
        view.scrollPhase = nil
        view.momentumPhase = .begin
        XCTAssertNotNil(pipeline.transform(event, in: .init(device: nil)))
        XCTAssertEqual(simulator.modifiedPresses.count, 1)
    }

    func testZoomThrottleSurvivesRouteChangesAndIgnoresMomentum() throws {
        let simulator = RecordingModifierKeySimulator()
        let throttle = ScrollActionThrottle()
        var now: UInt64 = 0
        let modifiers = Scheme.Scrolling.Modifiers(control: .zoom)
        func route() -> ModifierActionsTransformer {
            ModifierActionsTransformer(
                modifiers: .init(vertical: modifiers, horizontal: modifiers),
                keySimulator: simulator,
                scrollThrottle: throttle,
                monotonicClock: { now },
                zoomShortcut: Self.zoomShortcut
            )
        }
        let first = route()
        let next = route()
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        ))
        event.flags = .maskControl
        XCTAssertNil(first.transform(event, in: .init(device: nil)))
        first.deactivate()
        now = 120_000_000
        XCTAssertNil(next.transform(event, in: .init(device: nil)))
        XCTAssertEqual(simulator.modifiedPresses.count, 1)
        now = 300_000_000
        XCTAssertNil(next.transform(event, in: .init(device: nil)))
        XCTAssertEqual(simulator.modifiedPresses.count, 2)
        now = 600_000_000
        ScrollWheelEventView(event).momentumPhase = .begin
        XCTAssertNil(next.transform(event, in: .init(device: nil)))
        XCTAssertEqual(simulator.modifiedPresses.count, 2)
    }

    func testZoomRestoresNonCommandTriggerModifier() throws {
        let keySimulator = RecordingModifierKeySimulator()
        let modifiers = Scheme.Scrolling.Modifiers(option: .zoom)
        let transformer = ModifierActionsTransformer(
            modifiers: .init(vertical: modifiers, horizontal: modifiers),
            keySimulator: keySimulator,
            zoomShortcut: Self.zoomShortcut
        )
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        ))
        let leftOptionFlag = CGEventFlags(rawValue: UInt64(NX_DEVICELALTKEYMASK))
        event.flags = [.maskAlternate, leftOptionFlag]

        XCTAssertNil(transformer.transform(event, in: EventTransformerContext(device: nil)))
        XCTAssertEqual(
            keySimulator.modifiedPresses,
            [
                .init(
                    keyCode: 24,
                    modifierFlags: [.maskCommand, .maskShift],
                    restoringModifierFlags: [.maskAlternate, leftOptionFlag]
                )
            ]
        )
    }

    func testHorizontalReversedZoomUsesTheOppositeResolvedShortcut() throws {
        let simulator = RecordingModifierKeySimulator()
        let transformer = ModifierActionsTransformer(
            modifiers: .init(vertical: nil, horizontal: .init(control: .zoomReversed)),
            keySimulator: simulator,
            zoomShortcut: Self.zoomShortcut
        )
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: 0,
            wheel2: 1,
            wheel3: 0
        ))
        event.flags = .maskControl

        XCTAssertNil(transformer.transform(event, in: .init(device: nil)))
        XCTAssertEqual(simulator.modifiedPresses, [
            .init(keyCode: 44, modifierFlags: .maskCommand, restoringModifierFlags: .maskControl)
        ])
    }

    func testZoomDoesNotSendAnOldOrGuessedShortcutWhileLayoutIsUnresolved() throws {
        let simulator = RecordingModifierKeySimulator()
        let transformer = ModifierActionsTransformer(
            modifiers: .init(vertical: .init(command: .zoom), horizontal: nil),
            keySimulator: simulator
        ) { _ in nil }
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        ))
        event.flags = .maskCommand

        XCTAssertNil(transformer.transform(event, in: .init(device: nil)))
        XCTAssertTrue(simulator.modifiedPresses.isEmpty)
        XCTAssertTrue(simulator.unmodifiedPresses.isEmpty)
    }
}

extension ModifierActionsTransformerTests {
    private func wheel(x: Double, y: Double = 0, flags: CGEventFlags = []) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(y),
            wheel2: Int32(x),
            wheel3: 0
        ))
        event.flags = flags
        let view = ScrollWheelEventView(event)
        view.deltaXPt = x
        view.deltaYPt = y
        return event
    }

    func testUnmodifiedHorizontalPinchPreservesVerticalScrollAndEnds() throws {
        var phases: [CGSGesturePhase] = []
        var amounts: [Double] = []
        let ownership = ScrollGestureOwnership()
        let transformer = ModifierActionsTransformer(
            modifiers: .init(horizontal: .init(unmodified: .pinchZoom)),
            scrollGesture: ownership
        )            { phases.append($0); amounts.append($1) }
        let context = EventTransformerContext(device: nil)
        XCTAssertNil(try transformer.transform(wheel(x: 20), in: context))
        XCTAssertNil(try transformer.transform(wheel(x: -10), in: context))
        XCTAssertEqual(phases, [.began, .changed, .changed])
        XCTAssertEqual(amounts, [0, 0.1, -0.05])
        XCTAssertTrue(ownership.isOwned)
        let vertical = try wheel(x: 0, y: 20)
        XCTAssertIdentical(transformer.transform(vertical, in: context), vertical)
        XCTAssertEqual(phases.last, .ended)
        transformer.deactivate()
        XCTAssertEqual(phases.filter { $0 == .ended }.count, 1)
    }

    func testUnmodifiedPinchDoesNotOverrideHeldModifiers() throws {
        var phases: [CGSGesturePhase] = []
        let transformer = ModifierActionsTransformer(
            modifiers: .init(horizontal: .init(unmodified: .pinchZoom))
        )            { phase, _ in phases.append(phase) }
        let event = try wheel(x: 20, flags: .maskCommand)
        XCTAssertIdentical(transformer.transform(event, in: EventTransformerContext(device: nil)), event)
        XCTAssertTrue(phases.isEmpty)
    }

    func testHorizontalModifierPinchUsesHorizontalDeltaAndReverses() throws {
        var amounts: [Double] = []
        let transformer = ModifierActionsTransformer(
            modifiers: .init(horizontal: .init(command: .pinchZoomReversed))
        )            { _, amount in amounts.append(amount) }
        XCTAssertNil(try transformer.transform(
            wheel(x: 20, flags: .maskCommand), in: EventTransformerContext(device: nil)
        ))
        XCTAssertEqual(amounts, [0, -0.1])
        transformer.deactivate()
        XCTAssertEqual(amounts.last, 0)
    }

    func testPinchIgnoresMomentumAndEmptySamples() throws {
        var phases: [CGSGesturePhase] = []
        let transformer = ModifierActionsTransformer(
            modifiers: .init(horizontal: .init(unmodified: .pinchZoom))
        )            { phase, _ in phases.append(phase) }
        let context = EventTransformerContext(device: nil)
        let event = try wheel(x: 20)
        ScrollWheelEventView(event).momentumPhase = .begin
        XCTAssertNil(transformer.transform(event, in: context))
        XCTAssertNil(try transformer.transform(wheel(x: 0), in: context))
        XCTAssertTrue(phases.isEmpty)
    }

    func testUnmodifiedActionConfigurationRoundTripAndMerge() throws {
        let decoder = JSONDecoder()
        let value = try decoder.decode(Scheme.Scrolling.Modifiers.self, from: Data(
            #"{"unmodified":{"type":"pinchZoom"},"command":{"type":"zoom"}}"#.utf8
        ))
        var merged = Scheme.Scrolling.Modifiers(shift: .alterOrientation)
        value.merge(into: &merged)
        XCTAssertEqual(merged.unmodified, .pinchZoom)
        XCTAssertEqual(merged.command, .zoom)
        XCTAssertEqual(merged.shift, .alterOrientation)
        XCTAssertEqual(try decoder.decode(
            Scheme.Scrolling.Modifiers.self, from: JSONEncoder().encode(merged)
        ), merged)
    }

    func testUnmodifiedPinchEndsAfterIdleOnEventThread() throws {
        let ended = expectation(description: "Pinch ends without a modifier release")
        EventThread.shared.start()
        defer { EventThread.shared.stop() }
        let transformer = ModifierActionsTransformer(
            modifiers: .init(horizontal: .init(unmodified: .pinchZoom))
        )            { phase, _ in
                if phase == .ended {
                    ended.fulfill()
                }
            }
        let event = try wheel(x: 20)
        _ = EventThread.shared.performAndWait {
            XCTAssertNil(transformer.transform(event, in: EventTransformerContext(device: nil)))
        }
        wait(for: [ended], timeout: 2)
        _ = EventThread.shared.performAndWait { transformer.deactivate() }
    }
}
