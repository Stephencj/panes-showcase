import AVFoundation
import SwiftUI
import UIKit

/// Shows a tab's video and turns touches into mouse input:
/// tap = click (tap again quickly for double-click), long-press = right-click,
/// one-finger drag = click-and-drag, two-finger drag = scroll.
/// It's also the keyboard target, with an Esc/PaneTab/modifier/arrow row on top.
final class StreamView: KeyInputView {
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

    override func emit(_ e: InputEvent) { send(e) }

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
            send(InputEvent(kind: "down", x: start.x, y: start.y, mods: Array(stickyMods)))
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
