import CoreGraphics

enum Geometry {
    /// How many Mac points a phone point shows when fitting. 1.4 keeps Mac
    /// text readable on the phone while fitting a useful amount of an app.
    static let defaultZoom: CGFloat = 1.4

    /// A window with the phone's shape, `zoom` times the phone's size, shrunk
    /// if needed to fit the screen area. `minWidth` keeps it from collapsing
    /// into an unusable sliver; apps clamp to their own minimum size on top.
    static func fit(viewport: CGSize, zoom: CGFloat = defaultZoom, in screen: CGRect,
                    minWidth: CGFloat = 480) -> CGSize {
        guard viewport.width > 0, viewport.height > 0, screen.width > 0, screen.height > 0 else {
            return screen.size
        }
        let aspect = viewport.width / viewport.height
        var size = CGSize(width: viewport.width * zoom, height: viewport.height * zoom)
        if size.width < minWidth { size = CGSize(width: minWidth, height: minWidth / aspect) }
        if size.width > screen.width { size = CGSize(width: screen.width, height: screen.width / aspect) }
        if size.height > screen.height { size = CGSize(width: screen.height * aspect, height: screen.height) }
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }

    /// Where an aspect-fit video of `content` size sits inside `bounds`.
    static func aspectFit(_ content: CGSize, in bounds: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0 else { return bounds }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// A touch in the view as 0...1 across the video, or nil outside it.
    static func normalized(_ point: CGPoint, in videoRect: CGRect) -> CGPoint? {
        guard videoRect.width > 0, videoRect.height > 0, videoRect.contains(point) else { return nil }
        return CGPoint(x: (point.x - videoRect.minX) / videoRect.width,
                       y: (point.y - videoRect.minY) / videoRect.height)
    }

    /// The same, clamped to the edge: a drag that leaves the video keeps going.
    static func clampedNormalized(_ point: CGPoint, in videoRect: CGRect) -> CGPoint {
        guard videoRect.width > 0, videoRect.height > 0 else { return .zero }
        return CGPoint(x: min(max((point.x - videoRect.minX) / videoRect.width, 0), 1),
                       y: min(max((point.y - videoRect.minY) / videoRect.height, 0), 1))
    }

    /// A 0...1 window position as a point on the Mac's global display space.
    static func screenPoint(x: Double, y: Double, window: CGRect) -> CGPoint {
        CGPoint(x: window.minX + CGFloat(min(max(x, 0), 1)) * window.width,
                y: window.minY + CGFloat(min(max(y, 0), 1)) * window.height)
    }
}
