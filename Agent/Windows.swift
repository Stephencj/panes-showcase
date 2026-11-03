import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Looks up the real windows on this Mac and moves, resizes and raises them
/// through the Accessibility API.
enum Windows {
    /// Ordinary app windows: titled, normal layer, a usable size, not ours.
    static func list() async throws -> [WindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let me = Bundle.main.bundleIdentifier
        return content.windows.compactMap { w in
            guard let app = w.owningApplication, w.windowLayer == 0,
                  let title = w.title, !title.isEmpty,
                  w.frame.width >= 120, w.frame.height >= 80,
                  app.bundleIdentifier != me else { return nil }
            return WindowInfo(id: w.windowID, app: app.applicationName, bundleID: app.bundleIdentifier,
                              title: title, width: w.frame.width, height: w.frame.height)
        }
        .sorted { ($0.app.lowercased(), $0.title) < ($1.app.lowercased(), $1.title) }
    }

    static func scWindow(_ id: UInt32) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        return content.windows.first { $0.windowID == id }
    }

    /// The window's frame in global display points (top-left origin), the
    /// space mouse events use. Nil once the window is gone.
    static func frame(_ id: UInt32) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let dict = info.first?[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dict) else { return nil }
        return rect
    }

    static func pid(_ id: UInt32) -> pid_t? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let pid = info.first?[kCGWindowOwnerPID as String] as? Int else { return nil }
        return pid_t(pid)
    }

    /// The Accessibility handle for a window, matched by its window number.
    static func axWindow(_ id: UInt32, pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { w in
            var wid: CGWindowID = 0
            return _AXUIElementGetWindow(w, &wid) == .success && wid == id
        }
    }

    /// Brings the window's app to the front and the window to the top, so
    /// clicks and keys land in it. Skipped when it already has focus.
    static func focus(_ id: UInt32) {
        guard let pid = pid(id) else { return }
        let app = AXUIElementCreateApplication(pid)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
           let focused = attribute(app, kAXFocusedWindowAttribute) {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(focused as! AXUIElement, &wid) == .success, wid == id { return }
        }
        NSRunningApplication(processIdentifier: pid)?.activate()
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let w = axWindow(id, pid: pid) {
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
    }

    /// Moves and resizes a window (global top-left points). Returns what the
    /// app actually allowed, since apps enforce their own minimum sizes.
    @discardableResult
    static func setFrame(_ id: UInt32, _ rect: CGRect) -> CGRect? {
        guard let pid = pid(id), let w = axWindow(id, pid: pid) else { return nil }
        var origin = rect.origin, size = rect.size
        if let pos = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos)
        }
        if let sz = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sz)
        }
        return frame(id)
    }

    /// The usable part of the screen the window is on (no menu bar or Dock),
    /// in global top-left points.
    static func visibleArea(for window: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return window }
        let screens = NSScreen.screens.map { s -> (CGRect, CGRect) in
            (flip(s.frame, primary: primary.frame.height), flip(s.visibleFrame, primary: primary.frame.height))
        }
        let center = CGPoint(x: window.midX, y: window.midY)
        return (screens.first { $0.0.contains(center) } ?? screens[0]).1
    }

    /// AppKit's bottom-left screen rects to the top-left space windows use.
    static func flip(_ r: CGRect, primary height: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    private static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }
}

/// Private but long-standing: the window number behind an Accessibility window.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
