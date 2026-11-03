import UIKit

/// The keyboard side of a tab: on-screen keyboard with an Esc/Tab/Ctrl/Opt/⌘/
/// arrow row on top, and hardware keyboards (shortcuts like ⌘S go as key
/// presses, plain typing as text). Subclasses decide where the keys go.
class KeyInputView: UIView, UIKeyInput {
    var stickyMods: Set<String> = []
    private var modButtons: [String: UIButton] = [:]

    /// Where keys go; StreamView sends them to the Mac, app tabs into the page.
    func emit(_ e: InputEvent) {}


    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    func insertText(_ text: String) {
        if !stickyMods.isEmpty, text.count == 1, let name = Keys.name(for: text.first!) {
            emit(InputEvent(kind: "key", key: name, mods: takeSticky()))
        } else if text == "\n" {
            emit(InputEvent(kind: "key", key: "return"))
        } else {
            emit(InputEvent(kind: "text", text: text))
        }
    }

    func deleteBackward() { emit(InputEvent(kind: "key", key: "delete", mods: takeSticky())) }

    /// Hardware keyboards: shortcuts and special keys go as key presses
    /// (so ⌘S saves on the Mac); plain typing falls through to insertText.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { unhandled.insert(press); continue }
            var mods: [String] = []
            if key.modifierFlags.contains(.command) { mods.append("cmd") }
            if key.modifierFlags.contains(.control) { mods.append("ctrl") }
            if key.modifierFlags.contains(.alternate) { mods.append("opt") }
            if key.modifierFlags.contains(.shift) { mods.append("shift") }
            let special: String? = switch key.keyCode {
            case .keyboardLeftArrow: "left"
            case .keyboardRightArrow: "right"
            case .keyboardUpArrow: "up"
            case .keyboardDownArrow: "down"
            case .keyboardEscape: "escape"
            case .keyboardDeleteForward: "forwardDelete"
            case .keyboardHome: "home"
            case .keyboardEnd: "end"
            case .keyboardPageUp: "pageUp"
            case .keyboardPageDown: "pageDown"
            default: nil
            }
            let hasShortcutMod = mods.contains { $0 != "shift" }
            if let special {
                emit(InputEvent(kind: "key", key: special, mods: mods))
            } else if hasShortcutMod, let ch = key.charactersIgnoringModifiers.first, let name = Keys.name(for: ch) {
                emit(InputEvent(kind: "key", key: name, mods: mods))
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    /// Modifiers latched on the key row, cleared once used.
    func takeSticky() -> [String] {
        let mods = Array(stickyMods)
        stickyMods.removeAll()
        modButtons.values.forEach { $0.isSelected = false; $0.backgroundColor = .secondarySystemFill }
        return mods
    }

    override var inputAccessoryView: UIView? { keyRow }

    private lazy var keyRow: UIView = {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -5),
        ])
        let keys: [(String, String)] = [("esc", "escape"), ("tab", "tab"), ("ctrl", "ctrl"), ("opt", "opt"),
                                        ("⌘", "cmd"), ("←", "left"), ("↑", "up"), ("↓", "down"), ("→", "right")]
        for (label, name) in keys {
            let b = UIButton(type: .system)
            b.setTitle(label, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            b.backgroundColor = .secondarySystemFill
            b.layer.cornerRadius = 6
            b.tintColor = .label
            b.addAction(UIAction { [weak self, weak b] _ in
                guard let self, let b else { return }
                if ["ctrl", "opt", "cmd"].contains(name) {
                    if self.stickyMods.remove(name) == nil { self.stickyMods.insert(name) }
                    b.isSelected = self.stickyMods.contains(name)
                    b.backgroundColor = b.isSelected ? .tintColor.withAlphaComponent(0.5) : .secondarySystemFill
                } else {
                    self.emit(InputEvent(kind: "key", key: name, mods: self.takeSticky()))
                }
            }, for: .touchUpInside)
            if ["ctrl", "opt", "cmd"].contains(name) { modButtons[name] = b }
            stack.addArrangedSubview(b)
        }
        return bar
    }()
}
