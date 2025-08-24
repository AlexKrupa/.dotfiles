#!/usr/bin/swift
import Cocoa
import ApplicationServices
import Foundation

// Display dimensions (hardcode for performance)
let displayWidth: Double = 2056
let displayHeight: Double = 1329

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

// Execute BetterDisplay command
let task = Process()
task.launchPath = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
task.arguments = [
    "set",
    "-name=Built-in Display",
    "-stream",
    "-partialOriginX=\(relXStr)",
    "-partialOriginY=\(relYStr)",
    "-partialWidth=\(relWidthStr)",
    "-partialHeight=\(relHeightStr)"
]

task.launch()
task.waitUntilExit()