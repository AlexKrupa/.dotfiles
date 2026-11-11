import AppKit

let browserBundleIdentifiers: Set<String> = [
    "org.mozilla.firefox",
    "com.google.Chrome",
    "com.microsoft.edgemac",
]
let fingerCount = 3
// Fraction of the trackpad height
let swipeDistance: CGFloat = 0.1
// NSEventType.gesture and NSEventType.systemDefined have no CGEventType case
let gestureEventTypeRawValue: UInt32 = 29
let systemDefinedEventTypeRawValue: UInt32 = 14
let keyCodeT: CGKeyCode = 17
let keyCodeW: CGKeyCode = 13
let spotifyBundleIdentifier = "com.spotify.client"
// NX_SUBTYPE_AUX_CONTROL_BUTTONS and NX_KEYTYPE_* from IOKit ev_keymap.h
let mediaKeySubtype: Int16 = 8
let spotifyCommands: [Int: String] = [
    16: "playpause",
    17: "next track",
    18: "previous track",
]

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
    // macOS often reports a 3 finger click as a right click
    case .leftMouseDown, .rightMouseDown:
        middleButtonDown = touchCount == fingerCount
        if middleButtonDown { convertToMiddleButton(event, type: .otherMouseDown) }
    case .leftMouseDragged, .rightMouseDragged:
        if middleButtonDown { convertToMiddleButton(event, type: .otherMouseDragged) }
    case .leftMouseUp, .rightMouseUp:
        if middleButtonDown { convertToMiddleButton(event, type: .otherMouseUp) }
        middleButtonDown = false
    default:
        break
    }
}

func runSpotifyCommand(_ command: String) {
    var error: NSDictionary?
    NSAppleScript(source: "tell application id \"\(spotifyBundleIdentifier)\" to \(command)")?
        .executeAndReturnError(&error)
    if let error { fputs("input-tweaks: Spotify \(command) failed: \(error)\n", stderr) }
}

// Returns true when the event goes to Spotify and must not reach other apps
func handleMediaKey(_ event: CGEvent) -> Bool {
    guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == mediaKeySubtype else {
        return false
    }
    let keyCode = (nsEvent.data1 & 0xFFFF_0000) >> 16
    guard let command = spotifyCommands[keyCode] else { return false }
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: spotifyBundleIdentifier).isEmpty else {
        return false
    }
    let keyDown = (nsEvent.data1 & 0xFF00) >> 8 == 0x0A
    let keyRepeat = nsEvent.data1 & 0x1 == 1
    if keyDown && !keyRepeat {
        // An Apple Event can take longer than the event tap timeout
        DispatchQueue.main.async { runSpotifyCommand(command) }
    }
    return true
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    case .leftMouseDown, .leftMouseDragged, .leftMouseUp,
        .rightMouseDown, .rightMouseDragged, .rightMouseUp:
        handleMouse(type, event)
    case .scrollWheel:
        // macOS scrolls on 3 finger movement when no system gesture uses 3 fingers
        if touchCount == fingerCount { return nil }
    default:
        if type.rawValue == gestureEventTypeRawValue { handleGesture(event) }
        if type.rawValue == systemDefinedEventTypeRawValue && handleMediaKey(event) { return nil }
    }
    return Unmanaged.passUnretained(event)
}

let cgEventTypes: [CGEventType] = [
    .leftMouseDown, .leftMouseDragged, .leftMouseUp,
    .rightMouseDown, .rightMouseDragged, .rightMouseUp,
    .scrollWheel,
]
let eventTypeRawValues = cgEventTypes.map(\.rawValue)
    + [gestureEventTypeRawValue, systemDefinedEventTypeRawValue]
let eventMask = eventTypeRawValues.reduce(UInt64(0)) { mask, rawValue in mask | (1 << UInt64(rawValue)) }

let promptOption = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
guard AXIsProcessTrustedWithOptions([promptOption: true] as CFDictionary) else {
    fputs(
        "input-tweaks: no Accessibility permission for \(CommandLine.arguments[0]). "
            + "Add it in System Settings > Privacy & Security > Accessibility, then run install.sh.\n",
        stderr
    )
    // Exit code 0 stops launchd restarts, which show the prompt again. An event tap created in a
    // process that waited for the permission blocked all trackpad input.
    exit(0)
}

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: eventMask,
    callback: callback,
    userInfo: nil
) else {
    fputs("input-tweaks: cannot create the event tap\n", stderr)
    exit(1)
}
eventTap = tap
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CFRunLoopRun()
