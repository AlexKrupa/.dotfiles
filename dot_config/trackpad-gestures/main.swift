import AppKit

let browserBundleIdentifiers: Set<String> = [
    "org.mozilla.firefox",
    "com.google.Chrome",
    "com.microsoft.edgemac",
]
let fingerCount = 3
// Fraction of the trackpad height
let swipeDistance: CGFloat = 0.1
// NSEventType.gesture has no CGEventType case
let gestureEventTypeRawValue: UInt32 = 29
let keyCodeT: CGKeyCode = 17
let keyCodeW: CGKeyCode = 13

var touchCount = 0
var swipeStart: CGPoint?
var swipeDone = false
var middleButtonDown = false
var eventTap: CFMachPort?

func averagePosition(_ touches: Set<NSTouch>) -> CGPoint {
    let sum = touches.reduce(CGPoint.zero) { sum, touch in
        CGPoint(x: sum.x + touch.normalizedPosition.x, y: sum.y + touch.normalizedPosition.y)
    }
    let count = CGFloat(touches.count)
    return CGPoint(x: sum.x / count, y: sum.y / count)
}

func isBrowserFrontmost() -> Bool {
    guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
        return false
    }
    return browserBundleIdentifiers.contains(bundleIdentifier)
}

func sendCommandShortcut(_ keyCode: CGKeyCode) {
    for keyDown in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown)
        event?.flags = .maskCommand
        event?.post(tap: .cghidEventTap)
    }
}

func trackSwipe(_ position: CGPoint) {
    guard let start = swipeStart else {
        swipeStart = position
        return
    }
    guard !swipeDone else { return }
    let deltaX = position.x - start.x
    let deltaY = position.y - start.y
    guard abs(deltaY) >= swipeDistance, abs(deltaY) > abs(deltaX) else { return }
    swipeDone = true
    guard isBrowserFrontmost() else { return }
    // Normalized trackpad coordinates grow upward
    sendCommandShortcut(deltaY > 0 ? keyCodeT : keyCodeW)
}

func handleGesture(_ event: CGEvent) {
    guard let nsEvent = NSEvent(cgEvent: event) else { return }
    let allTouches = nsEvent.allTouches()
    // Touch events alternate with gesture events that have no touches
    guard !allTouches.isEmpty else { return }
    let touches = allTouches.filter { !$0.phase.isDisjoint(with: .touching) }
    touchCount = touches.count
    if touches.count == fingerCount {
        trackSwipe(averagePosition(touches))
    } else {
        swipeStart = nil
        swipeDone = false
    }
}

func convertToMiddleButton(_ event: CGEvent, type: CGEventType) {
    event.type = type
    event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.center.rawValue))
}

func handleMouse(_ type: CGEventType, _ event: CGEvent) {
    switch type {
    case .leftMouseDown:
        middleButtonDown = touchCount == fingerCount
        if middleButtonDown { convertToMiddleButton(event, type: .otherMouseDown) }
    case .leftMouseDragged:
        if middleButtonDown { convertToMiddleButton(event, type: .otherMouseDragged) }
    case .leftMouseUp:
        if middleButtonDown { convertToMiddleButton(event, type: .otherMouseUp) }
        middleButtonDown = false
    default:
        break
    }
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
        handleMouse(type, event)
    default:
        if type.rawValue == gestureEventTypeRawValue { handleGesture(event) }
    }
    return Unmanaged.passUnretained(event)
}

let promptOption = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
guard AXIsProcessTrustedWithOptions([promptOption: true] as CFDictionary) else {
    fputs(
        "trackpad-gestures: no Accessibility permission for \(CommandLine.arguments[0]). "
            + "Add it in System Settings > Privacy & Security > Accessibility.\n",
        stderr
    )
    exit(1)
}

let eventMask: UInt64 = (1 << UInt64(gestureEventTypeRawValue))
    | (1 << UInt64(CGEventType.leftMouseDown.rawValue))
    | (1 << UInt64(CGEventType.leftMouseDragged.rawValue))
    | (1 << UInt64(CGEventType.leftMouseUp.rawValue))
guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: eventMask,
    callback: callback,
    userInfo: nil
) else {
    fputs("trackpad-gestures: cannot create the event tap\n", stderr)
    exit(1)
}
eventTap = tap
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CFRunLoopRun()
