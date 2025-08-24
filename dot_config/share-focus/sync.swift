#!/usr/bin/swift
import Cocoa
import ApplicationServices
import Foundation

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

// Get frontmost application window bounds (filtering for AXStandardWindow)
func getFrontmostWindowBounds() -> (Double, Double, Double, Double)? {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = frontmostApp.processIdentifier

    // Get accessibility element for the frontmost process
    let appElement = AXUIElementCreateApplication(pid)

    // Get windows from the application
    var windowsRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

    guard result == .success, let windows = windowsRef as? [AXUIElement] else {
        return nil
    }

    // Find the first AXStandardWindow
    // Other window types (dialogs, banners) should be ignored
    for window in windows {
        var subroleRef: CFTypeRef?
        let subroleResult = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef)

        if subroleResult == .success, let subrole = subroleRef as? String, subrole == "AXStandardWindow" {
            // Get position and size
            var positionRef: CFTypeRef?
            var sizeRef: CFTypeRef?

            let posResult = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef)
            let sizeResult = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)

            if posResult == .success && sizeResult == .success,
               let positionValue = positionRef, let sizeValue = sizeRef {

                var position = CGPoint()
                var size = CGSize()

                if AXValueGetValue(positionValue as! AXValue, .cgPoint, &position) &&
                   AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) {
                    return (Double(position.x), Double(position.y), Double(size.width), Double(size.height))
                }
            }
        }
    }

    return nil
}

// Wait for focus change to complete (when called from skhd after Aerospace command)
Thread.sleep(forTimeInterval: 0.025)  // 25ms delay

// Main execution
guard let (x, y, width, height) = getFrontmostWindowBounds() else {
    exit(0)
}

// Calculate relative coordinates (0.0 to 1.0)
let relX = x / displayWidth
let relY = y / displayHeight
let relWidth = width / displayWidth
let relHeight = height / displayHeight

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
    "-partialOriginX=\(relXStr)",
    "-partialOriginY=\(relYStr)",
    "-partialWidth=\(relWidthStr)",
    "-partialHeight=\(relHeightStr)"
]

task.launch()
task.waitUntilExit()
