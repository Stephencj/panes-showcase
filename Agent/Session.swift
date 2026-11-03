import AppKit
import Network
import ScreenCaptureKit

/// One phone tab: one connection, one window. Captures the window, encodes
/// it, sends it, and plays the phone's input back into it.
final class Session: NSObject, SCStreamOutput, SCStreamDelegate {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private var reader = FrameReader()
    private let input = Input()
    private let onEnd: (Session) -> Void

    private var windowID: UInt32?
    private var stream: SCStream?
    private var config: SCStreamConfiguration?
    private var scale: CGFloat = 1
    private var encoder: Encoder?
    private var lastPixels: CVPixelBuffer?
    private var lastSize: CGSize = .zero
    private var originalFrame: CGRect?
    private var usingVirtual = false
    private var paused = false
    private var wantKeyframe = true
    private var watch: DispatchSourceTimer?
    private var ended = false
    private var terminal: Terminal?

    /// Bytes handed to the socket but not yet sent. Past the limit the phone's
    /// connection can't keep up, so frames are skipped rather than queued
    /// (queued frames are lag that never goes away).
    private var inFlight = 0
    private let inFlightLimit = 1_500_000
    private let sendLock = NSLock()

    init(_ conn: NWConnection, onEnd: @escaping (Session) -> Void) {
        self.conn = conn
        self.onEnd = onEnd
        queue = DispatchQueue(label: "panes.session")
        super.init()
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.queue.async { self?.end() }
            default: break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try self.reader.push(data) {
                        switch frame.type {
                        case .control:
                            if let msg = try? JSONDecoder().decode(Control.self, from: frame.payload) { self.handle(msg) }
                        case .terminal:
                            self.terminal?.write(frame.payload)
                        default:
                            break
                        }
                    }
                } catch {
                    print("bad stream: \(error)")
                    self.end()
                    return
                }
            }
            if done || error != nil { self.end() } else { self.receive() }
        }
    }

    private func handle(_ msg: Control) {
        switch msg.op {
        case "hello":
            send(Control(op: "hello", version: Wire.version, machine: Host.current().localizedName ?? "Mac",
                         features: ["windows", "terminal"]))
            if let problem = Agent.permissionProblem() { send(Control(op: "error", error: problem)) }
        case "list":
            Task {
                do { send(Control(op: "windows", windows: try await Windows.list())) }
                catch { send(Control(op: "error", error: "Can't list windows: \(error.localizedDescription)")) }
            }
        case "open":
            guard let id = msg.windowID else { return }
            Task { await open(id, viewport: msg.viewport, zoom: msg.zoom) }
        case "input":
            if let event = msg.event, let id = windowID { input.handle(event, window: id) }
        case "terminal":
            openTerminal(msg)
        case "resize":
            terminal?.resize(cols: msg.cols ?? 80, rows: msg.rows ?? 24)
        case "keyframe":
            requestKeyframe()
        case "pause":
            paused = true
        case "resume":
            paused = false
            requestKeyframe()
        default:
            break
        }
    }

    // MARK: terminal

    private func openTerminal(_ msg: Control) {
        terminal?.close()
        let name = Wire.sessionName(msg.name)
        terminal = Terminal(name: name, cols: msg.cols ?? 80, rows: msg.rows ?? 24, queue: queue,
                            onOutput: { [weak self] data in self?.sendRaw(Wire.encode(.terminal, data)) },
                            onExit: { [weak self] in
                                self?.terminal = nil
                                self?.send(Control(op: "exited"))
                            })
        if terminal == nil { send(Control(op: "error", error: "Couldn't start a shell.")) }
        else { send(Control(op: "terminalOpened", name: name)) }
    }

    // MARK: capture

    private func open(_ id: UInt32, viewport: Size?, zoom: Double?) async {
        let t0 = Date()
        let found: SCWindow?
        do { found = try await Windows.scWindow(id) } catch {
            print("open \(id): window lookup failed: \(error)")
            found = nil
        }
        guard var window = found, let frame = Windows.frame(id) else {
            print("open \(id): gone (capture list has it: \(found != nil), bounds: \(Windows.frame(id) != nil))")
            send(Control(op: "error", error: "That window is gone."))
            return
        }
        await withCheckedContinuation { c in queue.async { self.stopCapture(); c.resume() } }
        if let viewport {
            // Fitted windows go onto the Retina virtual display when there is
            // one, so they stream at 2x; otherwise they're fitted where they are.
            let virtual = VirtualDisplay.shared.acquire()
            queue.sync { originalFrame = frame; usingVirtual = virtual != nil }
            let area = virtual ?? Windows.visibleArea(for: frame)
            let size = Geometry.fit(viewport: CGSize(width: viewport.width, height: viewport.height),
                                    zoom: CGFloat(zoom ?? Geometry.defaultZoom), in: area)
            let target = CGRect(x: area.midX - size.width / 2, y: area.minY, width: size.width, height: size.height)
            Windows.setFrame(id, target)
            // The window server applies the new frame a moment later; wait for
            // it so the stream starts at the window's real shape and scale.
            // Moving lands before resizing, so wait for the size (apps may clamp
            // it to their minimum, hence the timeout).
            for _ in 0..<30 {
                if let f = Windows.frame(id), abs(f.width - size.width) < 2, abs(f.height - size.height) < 2 { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            if virtual != nil, let moved = try? await Windows.scWindow(id) { window = moved }
        }
        let now = Windows.frame(id) ?? frame
        print("open \(id): window ready after \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Self.even(now.width * scale)
        config.height = Self.even(now.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.scalesToFit = true
        config.queueDepth = 5
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            print("open \(id): capturing after \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        } catch {
            send(Control(op: "error", error: "Can't capture that window: \(error.localizedDescription)"))
            return
        }
        queue.async {
            self.windowID = id
            self.stream = stream
            self.config = config
            self.scale = scale
            self.lastSize = now.size
            self.wantKeyframe = true
            self.send(Control(op: "opened", windowID: id, title: window.title,
                              app: window.owningApplication?.applicationName,
                              width: now.width, height: now.height))
            self.watchWindow()
        }
    }

    /// Follows the window: a new size means a new stream size; gone means the tab closes.
    private func watchWindow() {
        watch?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in
            guard let self, let id = self.windowID else { return }
            guard let frame = Windows.frame(id) else {
                self.send(Control(op: "closed", windowID: id))
                self.stopCapture()
                return
            }
            if frame.size != self.lastSize, let config = self.config, let stream = self.stream {
                self.lastSize = frame.size
                config.width = Self.even(frame.width * self.scale)
                config.height = Self.even(frame.height * self.scale)
                stream.updateConfiguration(config) { _ in }
                self.send(Control(op: "resized", width: frame.width, height: frame.height))
            }
        }
        t.resume()
        watch = t
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        lastPixels = pixels
        encode(pixels, pts: CMSampleBufferGetPresentationTimeStamp(sample))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard stream === self.stream else { return }
            self.send(Control(op: "error", error: "Capture stopped: \(error.localizedDescription)"))
            self.stopCapture()
        }
    }

    private func encode(_ pixels: CVPixelBuffer, pts: CMTime) {
        guard !paused else { return }
        sendLock.lock(); let backlog = inFlight; sendLock.unlock()
        if backlog > inFlightLimit {
            wantKeyframe = true   // the next one that fits restarts the picture cleanly
            return
        }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        if encoder == nil || encoder!.width != Int32(w) || encoder!.height != Int32(h) {
            encoder = Encoder(width: w, height: h,
                              onFormat: { [weak self] sets in self?.sendRaw(Wire.videoFormat(sets)) },
                              onFrame: { [weak self] key, pts, data in
                                  self?.sendRaw(Wire.videoFrame(keyframe: key, ptsMicros: pts, avcc: data))
                              })
            wantKeyframe = true
        }
        encoder?.encode(pixels, pts: pts, keyframe: wantKeyframe)
        wantKeyframe = false
    }

    /// Screen capture only delivers frames when the window changes, so a still
    /// window is re-sent from the last picture.
    private func requestKeyframe() {
        wantKeyframe = true
        encoder?.resendFormat()
        if let lastPixels {
            encode(lastPixels, pts: CMClockGetTime(CMClockGetHostTimeClock()))
        }
    }

    private func stopCapture() {
        watch?.cancel()
        watch = nil
        if let stream { stream.stopCapture { _ in } }
        stream = nil
        encoder = nil
        lastPixels = nil
        if let id = windowID {
            input.releaseAll(window: id)
            if let original = originalFrame { Windows.setFrame(id, original) }
        }
        if usingVirtual { VirtualDisplay.shared.release() }
        usingVirtual = false
        originalFrame = nil
        windowID = nil
    }

    private func end() {
        guard !ended else { return }
        ended = true
        stopCapture()
        terminal?.close()
        terminal = nil
        conn.cancel()
        onEnd(self)
    }

    // MARK: sending

    private func send(_ msg: Control) { sendRaw(Wire.encode(msg)) }

    private func sendRaw(_ data: Data) {
        let n = data.count
        sendLock.lock(); inFlight += n; sendLock.unlock()
        conn.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.sendLock.lock(); self.inFlight -= n; self.sendLock.unlock()
        })
    }

    private static func even(_ v: CGFloat) -> Int { max(2, Int(v.rounded()) & ~1) }
}
