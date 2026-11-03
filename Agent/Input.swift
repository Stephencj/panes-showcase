import AppKit
import CoreGraphics

/// Turns the phone's touches and keys into real mouse and keyboard events,
/// aimed at one window.
final class Input {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonDown = false

    func handle(_ e: InputEvent, window id: UInt32) {
        guard let frame = Windows.frame(id) else { return }
        let point = Geometry.screenPoint(x: e.x ?? 0.5, y: e.y ?? 0.5, window: frame)
        let flags = Self.flags(e.mods)
        switch e.kind {
        case "move":
            mouse(.mouseMoved, at: point, button: .left)
        case "click":
            Windows.focusAndWait(id)
            let clicks = Int64(max(1, e.clicks ?? 1))
            mouse(.mouseMoved, at: point, button: .left)
            mouse(.leftMouseDown, at: point, button: .left, clicks: clicks, flags: flags)
            mouse(.leftMouseUp, at: point, button: .left, clicks: clicks, flags: flags)
        case "rightClick":
            Windows.focusAndWait(id)
            mouse(.mouseMoved, at: point, button: .right)
            mouse(.rightMouseDown, at: point, button: .right, flags: flags)
            mouse(.rightMouseUp, at: point, button: .right, flags: flags)
        case "down":
            Windows.focusAndWait(id)
            mouse(.mouseMoved, at: point, button: .left)
            mouse(.leftMouseDown, at: point, button: .left, flags: flags)
            buttonDown = true
        case "drag":
            mouse(buttonDown ? .leftMouseDragged : .mouseMoved, at: point, button: .left, flags: flags)
        case "up":
            mouse(.leftMouseUp, at: point, button: .left, flags: flags)
            buttonDown = false
        case "scroll":
            // dx/dy are fractions of the window; scroll by the same distance in points.
            mouse(.mouseMoved, at: point, button: .left)
            let dy = Int32(((e.dy ?? 0) * frame.height).rounded())
            let dx = Int32(((e.dx ?? 0) * frame.width).rounded())
            if dx != 0 || dy != 0,
               let ev = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                wheel1: dy, wheel2: dx, wheel3: 0) {
                ev.post(tap: .cghidEventTap)
            }
        case "text":
            guard Windows.focusAndWait(id) else {
                let holder = Windows.pid(id).flatMap { Windows.focusedWindow(pid: $0) }
                return print("dropped typing: window \(id) didn't get focus (focused: \(holder.map(String.init) ?? "none"))")
            }
            type(e.text ?? "")
        case "key":
            guard Windows.focusAndWait(id) else { return print("dropped key: window didn't get focus") }
            if let name = e.key, let code = Keys.codes[name] { press(code, flags: flags) }
        default:
            break
        }
    }

    /// Lets go of a held button, so a dropped connection can't leave a drag stuck.
    func releaseAll(window id: UInt32) {
        guard buttonDown, let frame = Windows.frame(id) else { return }
        mouse(.leftMouseUp, at: CGPoint(x: frame.midX, y: frame.midY), button: .left)
        buttonDown = false
    }

    static func flags(_ mods: [String]?) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in mods ?? [] {
            switch m {
            case "cmd": f.insert(.maskCommand)
            case "ctrl": f.insert(.maskControl)
            case "opt": f.insert(.maskAlternate)
            case "shift": f.insert(.maskShift)
            default: break
            }
        }
        return f
    }

    private func mouse(_ type: CGEventType, at p: CGPoint, button: CGMouseButton,
                       clicks: Int64 = 1, flags: CGEventFlags = []) {
        guard let ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p,
                               mouseButton: button) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: clicks)
        if !flags.isEmpty { ev.flags = flags }
        ev.post(tap: .cghidEventTap)
    }

    private func press(_ code: UInt16, flags: CGEventFlags) {
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            ev.flags = flags
            ev.post(tap: .cghidEventTap)
        }
    }

    /// Types text as characters rather than key codes, so it comes out right
    /// whatever keyboard layout the Mac uses. Newlines and tabs are real keys.
    private func type(_ text: String) {
        var chunk: [UniChar] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                ev.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                ev.post(tap: .cghidEventTap)
            }
            chunk.removeAll()
        }
        for ch in text {
            if ch == "\n" || ch == "\r" || ch == "\t" {
                flush()
                press(Keys.codes[Keys.name(for: ch)!]!, flags: [])
            } else {
                chunk.append(contentsOf: Array(String(ch).utf16))
                if chunk.count >= 16 { flush() }
            }
        }
        flush()
    }
}
