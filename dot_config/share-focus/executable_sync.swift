#!/usr/bin/swift
import Cocoa
import ApplicationServices
import Foundation

struct WindowBounds {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

// Check if sharing is enabled and get display dimensions
let cacheDir = "\(NSHomeDirectory())/.config/share-focus/.cache"
let enabledFile = "\(cacheDir)/sharing-enabled"
guard FileManager.default.fileExists(atPath: enabledFile) else {
    exit(0)  // Early return if sharing disabled
}

// Read display info from enabled file (format: "DisplayName|width height")
guard let fileData = try? String(contentsOfFile: enabledFile, encoding: .utf8) else {
    exit(0)  // Exit if can't read file
}
let trimmedData = fileData.trimmingCharacters(in: .whitespacesAndNewlines)

let parts = trimmedData.split(separator: "|")
guard parts.count == 2 else {
    exit(0)  // Exit if can't parse display info
}

let displayName = String(parts[0])
let resolutionPart = String(parts[1])
let dimensions = resolutionPart.split(separator: " ").compactMap { Double($0) }
guard dimensions.count == 2 else {
    exit(0)  // Exit if can't parse resolution
}

let displayWidth: Double = dimensions[0]
let displayHeight: Double = dimensions[1]

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

// Wait for focus change to complete
Thread.sleep(forTimeInterval: 0.025) // seconds

// Main execution
guard let windowBounds = getFocusedWindowBounds() else {
    exit(0)
}

// Clamp to display bounds, then convert to relative coordinates (0.0 to 1.0)
let clampedX = max(0, windowBounds.x)
let clampedY = max(0, windowBounds.y)
let clampedW = min(displayWidth - clampedX, windowBounds.width)
let clampedH = min(displayHeight - clampedY, windowBounds.height)

let relX = clampedX / displayWidth
let relY = clampedY / displayHeight
let relWidth = clampedW / displayWidth
let relHeight = clampedH / displayHeight

// Format to 3 decimal places
let relXStr = String(format: "%.3f", relX)
let relYStr = String(format: "%.3f", relY)
let relWidthStr = String(format: "%.3f", relWidth)
let relHeightStr = String(format: "%.3f", relHeight)

// Execute BetterDisplay command using dynamic display name
let task = Process()
task.launchPath = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
task.arguments = [
    "set",
    "-name=\(displayName)",
    "-stream",
    "-partial=on",
    "-partialOriginX=\(relXStr)",
    "-partialOriginY=\(relYStr)",
    "-partialWidth=\(relWidthStr)",
    "-partialHeight=\(relHeightStr)"
]

task.launch()
