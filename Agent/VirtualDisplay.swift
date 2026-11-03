import AppKit

/// An invisible Retina display that fitted windows move onto while they're
/// streamed. A window there renders at 2x, so text on the phone is as sharp as
/// on a Retina Mac, whatever monitor this Mac really has. It exists only while
/// a fitted tab is open, so the Mac's own screens aren't changed the rest of the time.
final class VirtualDisplay {
    static let shared = VirtualDisplay()

    /// Points; rendered at twice this in pixels.
    static let size = CGSize(width: 1600, height: 1200)

    private var display: CGVirtualDisplay?
    private var users = 0
    private var releaseWork: DispatchWorkItem?
    private let lock = NSLock()

    /// The display's area in global top-left points, creating it if needed.
    /// Nil if macOS refused (then windows stay where they are).
    func acquire() -> CGRect? {
        lock.lock()
        users += 1
        releaseWork?.cancel()
        releaseWork = nil
        if display == nil { display = Self.make() }
        let id = display?.displayID
        lock.unlock()
        guard let id else { return nil }
        // The window server takes a moment to bring a new display online.
        for _ in 0..<40 {
            let b = CGDisplayBounds(id)
            if b.width > 0 { return b }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    /// Lets go; the display is removed a little after the last user, so
    /// switching windows doesn't make it flicker in and out.
    func release() {
        lock.lock(); defer { lock.unlock() }
        users = max(0, users - 1)
        guard users == 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if self.users == 0 { self.display = nil }
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    var displayID: CGDirectDisplayID? {
        lock.lock(); defer { lock.unlock() }
        return display?.displayID
    }

    private static func make() -> CGVirtualDisplay? {
        let d = CGVirtualDisplayDescriptor()
        d.queue = DispatchQueue(label: "panes.virtual-display")
        d.name = "Panes"
        d.maxPixelsWide = UInt32(size.width * 2)
        d.maxPixelsHigh = UInt32(size.height * 2)
        // ~ a 15" panel, so macOS picks a sensible default scale.
        d.sizeInMillimeters = CGSize(width: 330, height: 248)
        d.vendorID = 0x5041   // "PA"
        d.productID = 0x4E45  // "NE"
        d.serialNum = 1
        d.terminationHandler = { _, _ in }
        guard let display = CGVirtualDisplay(descriptor: d) else { return nil }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [CGVirtualDisplayMode(width: UInt32(size.width), height: UInt32(size.height), refreshRate: 60)]
        guard display.apply(settings), display.displayID != 0 else {
            print("virtual display: macOS refused")
            return nil
        }
        print("virtual display \(display.displayID) online")
        return display
    }
}
