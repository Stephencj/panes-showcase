/// Turns the phone's key events into DOM key events for Xpra's web client,
/// which reads `key`, `code` and `keyCode` the way a desktop browser sends them.
enum WebKeys {
    struct DOMKey: Equatable {
        var key: String
        var code: String
        var keyCode: Int
        var ctrl = false, alt = false, shift = false, meta = false
    }

    private static let named: [String: (String, String, Int)] = [
        "return": ("Enter", "Enter", 13), "tab": ("Tab", "Tab", 9), "delete": ("Backspace", "Backspace", 8),
        "escape": ("Escape", "Escape", 27), "forwardDelete": ("Delete", "Delete", 46), "space": (" ", "Space", 32),
        "left": ("ArrowLeft", "ArrowLeft", 37), "up": ("ArrowUp", "ArrowUp", 38),
        "right": ("ArrowRight", "ArrowRight", 39), "down": ("ArrowDown", "ArrowDown", 40),
        "home": ("Home", "Home", 36), "end": ("End", "End", 35),
        "pageUp": ("PageUp", "PageUp", 33), "pageDown": ("PageDown", "PageDown", 34),
    ]

    /// Linux apps use Ctrl for the shortcuts a Mac uses ⌘ for, so ⌘C on the
    /// phone keyboard becomes Ctrl+C.
    static func keys(for e: InputEvent) -> [DOMKey] {
        let mods = Set(e.mods ?? [])
        func styled(_ k: DOMKey) -> DOMKey {
            var k = k
            k.ctrl = mods.contains("ctrl") || mods.contains("cmd")
            k.alt = mods.contains("opt")
            k.shift = k.shift || mods.contains("shift")
            return k
        }
        switch e.kind {
        case "text":
            return (e.text ?? "").map { styled(character($0)) }
        case "key":
            guard let name = e.key else { return [] }
            if let (key, code, kc) = named[name] { return [styled(DOMKey(key: key, code: code, keyCode: kc))] }
            if name.count == 1 { return [styled(character(Character(name)))] }
            return []
        default:
            return []
        }
    }

    static func character(_ c: Character) -> DOMKey {
        if c == "\n" || c == "\r" { return DOMKey(key: "Enter", code: "Enter", keyCode: 13) }
        if c == "\t" { return DOMKey(key: "Tab", code: "Tab", keyCode: 9) }
        let s = String(c)
        if let a = c.asciiValue, c.isLetter {
            let upper = Int(Character(s.uppercased()).asciiValue ?? a)
            return DOMKey(key: s, code: "Key" + s.uppercased(), keyCode: upper, shift: c.isUppercase)
        }
        if c.isNumber, c.isASCII { return DOMKey(key: s, code: "Digit" + s, keyCode: Int(c.asciiValue!)) }
        if let (code, keyCode, shift) = punctuation[c] {
            return DOMKey(key: s, code: code, keyCode: keyCode, shift: shift)
        }
        // Anything else (accents, emoji): Xpra maps by the character itself.
        return DOMKey(key: s, code: "", keyCode: 0)
    }

    /// Where each symbol sits on a US keyboard: Xpra needs the physical key,
    /// and Shift for the upper symbol on it.
    private static let punctuation: [Character: (String, Int, Bool)] = [
        "=": ("Equal", 187, false), "+": ("Equal", 187, true), "-": ("Minus", 189, false), "_": ("Minus", 189, true),
        ".": ("Period", 190, false), ">": ("Period", 190, true), ",": ("Comma", 188, false), "<": ("Comma", 188, true),
        "/": ("Slash", 191, false), "?": ("Slash", 191, true), ";": ("Semicolon", 186, false), ":": ("Semicolon", 186, true),
        "'": ("Quote", 222, false), "\"": ("Quote", 222, true), "[": ("BracketLeft", 219, false), "{": ("BracketLeft", 219, true),
        "]": ("BracketRight", 221, false), "}": ("BracketRight", 221, true), "\\": ("Backslash", 220, false),
        "|": ("Backslash", 220, true), "`": ("Backquote", 192, false), "~": ("Backquote", 192, true),
        " ": ("Space", 32, false),
        "!": ("Digit1", 49, true), "@": ("Digit2", 50, true), "#": ("Digit3", 51, true), "$": ("Digit4", 52, true),
        "%": ("Digit5", 53, true), "^": ("Digit6", 54, true), "&": ("Digit7", 55, true), "*": ("Digit8", 56, true),
        "(": ("Digit9", 57, true), ")": ("Digit0", 48, true),
    ]

    /// One call to the page's panesKey() helper per key.
    static func script(_ keys: [DOMKey]) -> String {
        keys.map { k in
            let key = k.key.unicodeScalars.map { s -> String in
                switch s {
                case "\\": return "\\\\"
                case "\"": return "\\\""
                default: return s.value < 0x20 ? String(format: "\\u%04x", s.value) : String(s)
                }
            }.joined()
            return "panesKey(\"\(key)\",\"\(k.code)\",\(k.keyCode),\(k.ctrl),\(k.alt),\(k.shift),\(k.meta));"
        }.joined()
    }

    /// Added to every Xpra page: the panesKey() helper, and app windows kept
    /// maximized to the tab (dialogs and menus are left alone).
    static let pageScript = """
    window.panesKey = function(key, code, keyCode, ctrl, alt, shift, meta) {
      // Like a real keyboard: modifiers go down first and up last, as keys of
      // their own (Xpra tracks them that way).
      const mods = [];
      if (ctrl) mods.push(["Control", "ControlLeft", 17]);
      if (alt) mods.push(["Alt", "AltLeft", 18]);
      if (shift) mods.push(["Shift", "ShiftLeft", 16]);
      const send = function(type, k, c, kc) {
        const e = new KeyboardEvent(type, {key: k, code: c, ctrlKey: ctrl, altKey: alt, shiftKey: shift,
                                           metaKey: meta, bubbles: true, cancelable: true});
        Object.defineProperty(e, "keyCode", {get: () => kc});
        Object.defineProperty(e, "which", {get: () => kc});
        document.dispatchEvent(e);
      };
      for (const m of mods) send("keydown", m[0], m[1], m[2]);
      send("keydown", key, code, keyCode);
      send("keyup", key, code, keyCode);
      for (const m of mods.reverse()) send("keyup", m[0], m[1], m[2]);
    };
    setInterval(function() {
      try {
        if (typeof client === "undefined" || !client || !client.id_to_window) return;
        for (const wid in client.id_to_window) {
          const w = client.id_to_window[wid];
          const m = w.metadata || {};
          if (w.override_redirect || m["transient-for"] || m["modal"]) continue;
          const type = (m["window-type"] || ["NORMAL"])[0];
          if (type !== "NORMAL" && type !== "_NET_WM_WINDOW_TYPE_NORMAL") continue;
          if (!w.maximized) w.set_maximized(true);
        }
      } catch (e) {}
    }, 400);
    """
}
