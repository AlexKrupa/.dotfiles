#!/usr/bin/swift
import Cocoa
import ApplicationServices
import Foundation
import CoreGraphics

// Check accessibility permission (triggered by --check-ax flag)
if CommandLine.arguments.contains("--check-ax") {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    if AXIsProcessTrustedWithOptions(opts) {
        exit(0)
    } else {
        fputs("share-focus: accessibility permission required - approve in System Settings, then restart\n", stderr)
        exit(2)
    }
}

struct WindowBounds {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

// Get focused window bounds (filtering for AXStandardWindow)
func getFocusedWindowBounds() -> WindowBounds? {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = frontmostApp.processIdentifier

    let appElement = AXUIElementCreateApplication(pid)

    // Get the actually focused window, not just the first in the list
    var focusedRef: CFTypeRef?
    let focusedResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef)
    guard focusedResult == .success, let focusedWindow = focusedRef else { return nil }

    // Skip non-standard windows (dialogs, banners, etc.)
    var subroleRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXSubroleAttribute as CFString, &subroleRef) == .success,
       let subrole = subroleRef as? String, subrole != "AXStandardWindow" {
        return nil
    }

    var positionRef: CFTypeRef?
    var sizeRef: CFTypeRef?

    let posResult = AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXPositionAttribute as CFString, &positionRef)
    let sizeResult = AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXSizeAttribute as CFString, &sizeRef)

    guard posResult == .success && sizeResult == .success,
          let positionValue = positionRef, let sizeValue = sizeRef else { return nil }

    var position = CGPoint()
    var size = CGSize()

    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }

    return WindowBounds(
        x: Double(position.x),
        y: Double(position.y),
        width: Double(size.width),
        height: Double(size.height)
    )
}

// Sync the BetterDisplay crop to the focused window
func runSync() {
    let cacheDir = "\(NSHomeDirectory())/.config/share-focus/.cache"
    let enabledFile = "\(cacheDir)/sharing-enabled"
    guard FileManager.default.fileExists(atPath: enabledFile) else { return }

    guard let fileData = try? String(contentsOfFile: enabledFile, encoding: .utf8) else { return }
    let trimmedData = fileData.trimmingCharacters(in: .whitespacesAndNewlines)

    let parts = trimmedData.split(separator: "|")
    guard parts.count == 2 else { return }

    let displayName = String(parts[0])
    let dimensions = String(parts[1]).split(separator: " ").compactMap { Double($0) }
    guard dimensions.count == 2 else { return }

    // Use NSScreen for display dimensions - guaranteed same coordinate space as AX APIs,
    // regardless of what resolution string BetterDisplay reports
    guard let screen = NSScreen.screens.first else { return }
    let displayWidth = Double(screen.frame.width)
    let displayHeight = Double(screen.frame.height)

    // Wait for focus change to complete
    Thread.sleep(forTimeInterval: delayMs / 1000.0)

    guard let wb = getFocusedWindowBounds() else { return }

    // Window entirely off the source display - on another monitor
    if wb.x + wb.width <= 0 || wb.y + wb.height <= 0
        || wb.x >= displayWidth || wb.y >= displayHeight {
        return
    }

    // Clamp to display bounds, then convert to relative coordinates (0.0 to 1.0)
    let clampedX = max(0, wb.x)
    let clampedY = max(0, wb.y)
    let visibleW = wb.width - (clampedX - wb.x)
    let visibleH = wb.height - (clampedY - wb.y)
    let clampedW = min(displayWidth - clampedX, visibleW)
    let clampedH = min(displayHeight - clampedY, visibleH)

    let relX = String(format: "%.3f", clampedX / displayWidth)
    let relY = String(format: "%.3f", clampedY / displayHeight)
    let relW = String(format: "%.3f", clampedW / displayWidth)
    let relH = String(format: "%.3f", clampedH / displayHeight)

    // Post directly to BetterDisplay via distributed notification instead of spawning
    // the CLI process. Same protocol the CLI uses internally, but ~65ms faster per call
    // (CLI ~67ms, HTTP API ~10ms, notification ~0ms in benchmarks).
    struct BDRequest: Codable {
        var uuid: String?
        var commands: [String]
        var parameters: [String: String]
    }
    let request = BDRequest(
        uuid: UUID().uuidString,
        commands: ["set"],
        parameters: [
            "name": displayName,
            "stream": "on",
            "partial": "on",
            "partialOriginX": relX,
            "partialOriginY": relY,
            "partialWidth": relW,
            "partialHeight": relH
        ]
    )
    let json = String(data: try! JSONEncoder().encode(request), encoding: .utf8)!
    DistributedNotificationCenter.default().postNotificationName(
        .init("com.betterdisplay.BetterDisplay.request"),
        object: json,
        userInfo: nil,
        deliverImmediately: true
    )
}

// Parse --delay flag (milliseconds, default 0)
var delayMs: Double = 0
if let idx = CommandLine.arguments.firstIndex(of: "--delay"),
   idx + 1 < CommandLine.arguments.count,
   let val = Double(CommandLine.arguments[idx + 1]) {
    delayMs = val
}

// --- Watch mode: global state for CGEventTap callback (must not capture context) ---

var isDragging = false
var pendingSync: DispatchWorkItem?
var eventTap: CFMachPort?

func triggerSync() {
    pendingSync?.cancel()
    let work = DispatchWorkItem { runSync() }
    pendingSync = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
}

func watcherCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    case .leftMouseDragged:
        isDragging = true
    case .leftMouseUp:
        if isDragging {
            isDragging = false
            triggerSync()
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

if CommandLine.arguments.contains("--watch") {
    let cacheDir = "\(NSHomeDirectory())/.config/share-focus/.cache"

    // Write PID file for service to manage
    try? "\(getpid())".write(
        toFile: "\(cacheDir)/watcher.pid",
        atomically: true,
        encoding: .utf8
    )

    let mask = (1 << CGEventType.leftMouseDragged.rawValue)
             | (1 << CGEventType.leftMouseUp.rawValue)

    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: CGEventMask(mask),
        callback: watcherCallback,
        userInfo: nil
    ) else {
        fputs("share-focus: failed to create event tap - check Accessibility permissions\n", stderr)
        exit(1)
    }

    eventTap = tap

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    CFRunLoopRun()
    exit(0)
}

// --- Default: one-shot sync ---
runSync()
