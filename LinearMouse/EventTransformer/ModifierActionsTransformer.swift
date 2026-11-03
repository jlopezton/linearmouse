// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Carbon
import Foundation
import GestureKit
import KeyKit
import os.log

class ModifierActionsTransformer {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "ModifierActionsTransformer"
    )

    private static let defaultKeySimulator = KeySimulator(
        eventSourceUserData: CGEvent.linearMouseSyntheticEventUserData
    )

    static let zoomShortcutResolver = KeyEquivalentResolver(keyEquivalents: ["+", "-"])

    typealias Modifiers = Scheme.Scrolling.Bidirectional<Scheme.Scrolling.Modifiers>
    typealias Action = Scheme.Scrolling.Modifiers.Action

    private let modifiers: Modifiers
    private let keySimulator: KeySimulating
    private let scrollGesture: ScrollGestureOwnership
    private let scrollThrottle: ScrollActionThrottle
    private let monotonicClock: () -> UInt64
    private let zoomShortcut: (Bool) -> KeyEquivalentResolver.Shortcut?

    private let postPinch: (CGSGesturePhase, Double) -> Void
    private var pinchZoomEndTimer: EventThreadTimer?
    private var pinchZoomHorizontal = false
    private var pinchZoomBegan = false
    private var pinchZoomReversed = false

    init(
        modifiers: Modifiers,
        keySimulator: KeySimulating? = nil,
        scrollThrottle: ScrollActionThrottle = .init(),
        scrollGesture: ScrollGestureOwnership = .init(),
        monotonicClock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        postPinch: @escaping (CGSGesturePhase, Double) -> Void = { phase, magnification in
            GestureEvent(zoomSource: nil, phase: phase, magnification: magnification)?.post(tap: .cgSessionEventTap)
        },
        zoomShortcut: @escaping (Bool) -> KeyEquivalentResolver.Shortcut? = defaultZoomShortcut
    ) {
        self.postPinch = postPinch
        self.modifiers = modifiers
        self.keySimulator = keySimulator ?? Self.defaultKeySimulator
        self.scrollThrottle = scrollThrottle
        self.scrollGesture = scrollGesture
        self.monotonicClock = monotonicClock
        self.zoomShortcut = zoomShortcut
    }

    static func defaultZoomShortcut(zoomIn: Bool) -> KeyEquivalentResolver.Shortcut? {
        if #available(macOS 12, *) {
            return zoomShortcutResolver.shortcut(for: zoomIn ? "+" : "-")
        }
        // Preserve the legacy behavior on systems without AppKit's automatic shortcut localization.
        return .init(
            keyCode: CGKeyCode(zoomIn ? kVK_ANSI_KeypadPlus : kVK_ANSI_KeypadMinus),
            modifierFlags: .maskCommand
        )
    }
}

extension ModifierActionsTransformer: EventTransformer {
    var handlesPointerMotion: Bool {
        false
    }

    func transform(_ event: CGEvent, in _: EventTransformerContext) -> CGEvent? {
        if pinchZoomBegan {
            if event.type == .scrollWheel {
                let view = ScrollWheelEventView(event)
                let horizontal = view.deltaYSignum == 0
                if horizontal == pinchZoomHorizontal {
                    return handlePinchZoom(event, reverse: pinchZoomReversed)
                }
                endPinchZoom()
            } else {
                return handlePinchZoom(event, reverse: pinchZoomReversed)
            }
        }

        guard event.type == .scrollWheel else {
            return event
        }

        let scrollWheelEventView = ScrollWheelEventView(event)
        guard let modifiers = scrollWheelEventView.deltaYSignum != 0
            ? modifiers.vertical
            : modifiers.horizontal else {
            return event
        }

        let actionFlags: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        if event.flags.isDisjoint(with: actionFlags),
           let action = modifiers.unmodified, action != .auto {
            return handleModifierKeyAction(for: event, action: action)
        }

        let actions: [(CGEventFlags.Element, Action?)] = [
            (.maskCommand, modifiers.command),
            (.maskShift, modifiers.shift),
            (.maskAlternate, modifiers.option),
            (.maskControl, modifiers.control)
        ]
        var event = event
        for case let (flag, action) in actions where event.flags.contains(flag) {
            if let action, action != .auto {
                guard let handledEvent = handleModifierKeyAction(for: event, action: action) else {
                    return nil
                }
                event = handledEvent
                event.flags.remove(flag)
            }
        }
        return event
    }

    private func handleModifierKeyAction(for event: CGEvent, action: Action) -> CGEvent? {
        let scrollWheelEventView = ScrollWheelEventView(event)

        switch action {
        case .auto, .ignore:
            break
        case .preventDefault:
            return nil
        case .alterOrientation:
            scrollWheelEventView.swapXY()
        case let .changeSpeed(scale: scale):
            scrollWheelEventView.scale(factor: scale.asTruncatedDouble)
        case .zoom, .zoomReversed:
            let scrollWheelEventView = ScrollWheelEventView(event)
            var deltaSignum = scrollWheelEventView.deltaYSignum != 0 ? scrollWheelEventView
                .deltaYSignum : scrollWheelEventView.deltaXSignum
            if action == .zoomReversed {
                deltaSignum *= -1
            }
            if deltaSignum == 0 {
                return event
            }
            guard scrollWheelEventView.momentumPhase == .none else {
                return nil
            }
            let axis: ScrollInput.Axis = scrollWheelEventView.deltaYSignum != 0 ? .vertical : .horizontal
            scrollGesture.claim()
            let restoringModifierFlags = ModifierState.normalize(event.flags)
            if let shortcut = zoomShortcut(deltaSignum > 0) {
                guard scrollThrottle.allowsAction(on: axis, at: monotonicClock()) else {
                    return nil
                }
                try? keySimulator.press(
                    keyCode: shortcut.keyCode,
                    modifierFlags: shortcut.modifierFlags,
                    restoringModifierFlags: restoringModifierFlags,
                    tap: .cgSessionEventTap
                )
            }
            return nil
        case .pinchZoom:
            pinchZoomReversed = false
            return handlePinchZoom(event, reverse: false)
        case .pinchZoomReversed:
            pinchZoomReversed = true
            return handlePinchZoom(event, reverse: true)
        }

        return event
    }

    private func handlePinchZoom(_ event: CGEvent, reverse: Bool) -> CGEvent? {
        guard event.type == .scrollWheel || event.type == .flagsChanged else {
            return event
        }

        if event.type == .flagsChanged {
            endPinchZoom()
            return event
        }

        let scrollWheelEventView = ScrollWheelEventView(event)
        guard scrollWheelEventView.momentumPhase == .none else {
            return nil
        }
        let horizontal = scrollWheelEventView.deltaYSignum == 0
        let delta = horizontal ? scrollWheelEventView.deltaXPt : scrollWheelEventView.deltaYPt
        guard delta != 0 else {
            return nil
        }
        scrollGesture.claim()

        if !pinchZoomBegan {
            pinchZoomHorizontal = horizontal
            postPinch(.began, 0)
            pinchZoomBegan = true
            os_log("pinch zoom began", log: Self.log, type: .info)
        }

        let direction = reverse ? -1.0 : 1.0
        let magnification = delta * 0.005 * direction
        postPinch(.changed, magnification)
        // Mouse wheels have no reliable gesture-ended phase or modifier release.
        // Finish on the event thread after the wheel has been idle for 150 ms.
        pinchZoomEndTimer?.invalidate()
        pinchZoomEndTimer = EventThread.shared.scheduleTimer(interval: 0.15, repeats: false) { [weak self] in
            self?.endPinchZoom()
        }
        os_log("pinch zoom changed: magnification=%f", log: Self.log, type: .info, magnification)

        return nil
    }
}

extension ModifierActionsTransformer: Deactivatable {
    private func endPinchZoom() {
        pinchZoomEndTimer?.invalidate()
        pinchZoomEndTimer = nil
        if pinchZoomBegan {
            pinchZoomBegan = false
            pinchZoomReversed = false
            postPinch(.ended, 0)
        }
    }

    func deactivate() {
        endPinchZoom()
    }
}
