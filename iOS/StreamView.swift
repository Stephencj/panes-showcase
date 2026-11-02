import AVFoundation
import SwiftUI
import UIKit

/// Shows a tab's video and turns touches into mouse input:
/// tap = click (tap again quickly for double-click), long-press = right-click,
/// one-finger drag = click-and-drag, two-finger drag = scroll.
/// It's also the keyboard target, with an Esc/PaneTab/modifier/arrow row on top.
final class StreamView: UIView, UIKeyInput {
    var tab: PaneTab? {
        didSet {
            oldValue?.renderer.removeFromSuperlayer()
            if let tab { layer.addSublayer(tab.renderer) }
            setNeedsLayout()
        }
    }
    var onViewport: ((CGSize) -> Void)?

    private var lastTap: (at: Date, point: CGPoint, clicks: Int)?
    private var lastScroll: CGPoint = .zero
    private var sticky: Set<String> = []
    private var modButtons: [String: UIButton] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPressed))
        long.minimumPressDuration = 0.45
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged))
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        [tap, long, drag, scroll].forEach(addGestureRecognizer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tab?.renderer.frame = bounds
        CATransaction.commit()
        onViewport?(bounds.size)
    }

    /// Where the video actually sits (it's letterboxed to the window's shape).
    private var videoRect: CGRect {
        Geometry.aspectFit(tab?.windowSize ?? bounds.size, in: bounds)
    }

    private func send(_ e: InputEvent) { tab?.send(e) }

    // MARK: touches

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        guard let n = Geometry.normalized(p, in: videoRect) else { return }
        var clicks = 1
        if let last = lastTap, Date().timeIntervalSince(last.at) < 0.4,
           hypot(last.point.x - p.x, last.point.y - p.y) < 24 {
            clicks = last.clicks + 1
        }
        lastTap = (Date(), p, clicks)
        send(InputEvent(kind: "click", x: n.x, y: n.y, clicks: clicks, mods: takeSticky()))
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let n = Geometry.normalized(g.location(in: self), in: videoRect) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        send(InputEvent(kind: "rightClick", x: n.x, y: n.y))
    }

    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        let n = Geometry.clampedNormalized(p, in: videoRect)
        switch g.state {
        case .began:
            // The pan only fires after some movement; press where the finger first landed.
            let t = g.translation(in: self)
            let start = Geometry.clampedNormalized(CGPoint(x: p.x - t.x, y: p.y - t.y), in: videoRect)
            send(InputEvent(kind: "down", x: start.x, y: start.y, mods: Array(sticky)))
            send(InputEvent(kind: "drag", x: n.x, y: n.y))
        case .changed:
            send(InputEvent(kind: "drag", x: n.x, y: n.y))
        case .ended, .cancelled, .failed:
            send(InputEvent(kind: "up", x: n.x, y: n.y))
            _ = takeSticky()
        default:
            break
        }
    }

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        let rect = videoRect
        guard rect.width > 0 else { return }
        let t = g.translation(in: self)
        switch g.state {
        case .began:
            lastScroll = t
        case .changed:
            let d = CGPoint(x: t.x - lastScroll.x, y: t.y - lastScroll.y)
            lastScroll = t
            let at = Geometry.clampedNormalized(g.location(in: self), in: rect)
            send(InputEvent(kind: "scroll", x: at.x, y: at.y, dx: d.x / rect.width, dy: d.y / rect.height))
        default:
            break
        }
    }

    // MARK: keyboard

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    func insertText(_ text: String) {
        if !sticky.isEmpty, text.count == 1, let name = Keys.name(for: text.first!) {
            send(InputEvent(kind: "key", key: name, mods: takeSticky()))
        } else if text == "\n" {
            send(InputEvent(kind: "key", key: "return"))
        } else {
            send(InputEvent(kind: "text", text: text))
        }
    }

    func deleteBackward() { send(InputEvent(kind: "key", key: "delete", mods: takeSticky())) }

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
                send(InputEvent(kind: "key", key: special, mods: mods))
            } else if hasShortcutMod, let ch = key.charactersIgnoringModifiers.first, let name = Keys.name(for: ch) {
                send(InputEvent(kind: "key", key: name, mods: mods))
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    private func takeSticky() -> [String] {
        let mods = Array(sticky)
        sticky.removeAll()
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
                    if self.sticky.remove(name) == nil { self.sticky.insert(name) }
                    b.isSelected = self.sticky.contains(name)
                    b.backgroundColor = b.isSelected ? .tintColor.withAlphaComponent(0.5) : .secondarySystemFill
                } else {
                    self.send(InputEvent(kind: "key", key: name, mods: self.takeSticky()))
                }
            }, for: .touchUpInside)
            if ["ctrl", "opt", "cmd"].contains(name) { modButtons[name] = b }
            stack.addArrangedSubview(b)
        }
        return bar
    }()
}

struct StreamSurface: UIViewRepresentable {
    @ObservedObject var tab: PaneTab
    @Binding var keyboard: Bool

    func makeUIView(context: Context) -> StreamView {
        let v = StreamView()
        v.tab = tab
        v.onViewport = { [weak tab] size in tab?.viewport = size }
        return v
    }

    func updateUIView(_ v: StreamView, context: Context) {
        if v.tab !== tab { v.tab = tab }
        v.setNeedsLayout()
        DispatchQueue.main.async {
            if keyboard && !v.isFirstResponder { v.becomeFirstResponder() }
            if !keyboard && v.isFirstResponder { v.resignFirstResponder() }
        }
    }
}
