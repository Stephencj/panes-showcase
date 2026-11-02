import AVFoundation
import SwiftUI

struct Machine: Identifiable, Hashable, Codable {
    var id: String { name }
    var name: String
    /// Tried in order: the Tailscale name, its Tailscale address, then the
    /// home-network address.
    var hosts: [String]

    static let defaults: [Machine] = {
        // Tests point the app at an agent on this Mac with PANES_HOSTS=127.0.0.1.
        if let hosts = ProcessInfo.processInfo.environment["PANES_HOSTS"] {
            return [Machine(name: "Mac mini", hosts: hosts.split(separator: ",").map(String.init))]
        }
        return [Machine(name: "Mac mini", hosts: ["my-mac-mini", "100.64.0.10", "192.168.1.10"])]
    }()
}

/// One tab: a window on a machine, streamed over its own connection.
@MainActor
final class PaneTab: ObservableObject, Identifiable {
    enum Status: Equatable { case connecting, live, closed, failed(String) }

    let id = UUID()
    let machine: Machine
    let window: WindowInfo
    let fitToPhone: Bool
    @Published var status: Status = .connecting
    @Published var title: String
    @Published var notice: String?
    /// The Mac window's size in points, which sets the video's shape.
    @Published var windowSize: CGSize

    let renderer = AVSampleBufferDisplayLayer()
    var viewport: CGSize = CGSize(width: 393, height: 700)
    private var link: AgentLink?
    private var format: CMVideoFormatDescription?
    private var active = true
    private var waitingForKeyframe = true

    init(machine: Machine, window: WindowInfo, fitToPhone: Bool) {
        self.machine = machine
        self.window = window
        self.fitToPhone = fitToPhone
        title = window.title
        windowSize = CGSize(width: window.width, height: window.height)
        renderer.videoGravity = .resizeAspect
        renderer.backgroundColor = UIColor.black.cgColor
    }

    func connect() {
        link?.close()
        status = .connecting
        waitingForKeyframe = true
        let link = AgentLink(hosts: machine.hosts) { [weak self] in self?.handle($0) }
        self.link = link
        link.connect()
    }

    func close() {
        link?.close()
        link = nil
        status = .closed
    }

    /// Background tabs stop their video (the connection stays) so only the
    /// tab on screen uses bandwidth.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        link?.send(Control(op: on ? "resume" : "pause"))
    }

    func refresh() { link?.send(Control(op: "keyframe")) }

    func send(_ event: InputEvent) { link?.send(Control(op: "input", event: event)) }

    private func handle(_ e: AgentLink.Event) {
        switch e {
        case .ready:
            link?.send(Control(op: "hello", version: Wire.version))
            let vp = fitToPhone ? Size(width: viewport.width, height: viewport.height) : nil
            link?.send(Control(op: "open", windowID: window.id, viewport: vp))
            if !active { link?.send(Control(op: "pause")) }
        case .control(let msg):
            switch msg.op {
            case "opened":
                status = .live
                if let t = msg.title, !t.isEmpty { title = t }
                if let w = msg.width, let h = msg.height { windowSize = CGSize(width: w, height: h) }
            case "resized":
                if let w = msg.width, let h = msg.height { windowSize = CGSize(width: w, height: h) }
            case "closed":
                status = .failed("The window was closed on the Mac.")
            case "error":
                notice = msg.error
            default:
                break
            }
        case .format(let sets):
            format = VideoSamples.format(sets)
            renderer.sampleBufferRenderer.flush()
            waitingForKeyframe = true
        case .frame(let keyframe, let pts, let avcc):
            guard let format else { return }
            if waitingForKeyframe && !keyframe { return }
            waitingForKeyframe = false
            if renderer.sampleBufferRenderer.status == .failed {
                renderer.sampleBufferRenderer.flush()
                waitingForKeyframe = true
                refresh()
                return
            }
            if let sample = VideoSamples.sample(avcc, format: format, ptsMicros: pts) {
                renderer.sampleBufferRenderer.enqueue(sample)
            }
        case .failed(let why):
            if status != .closed { status = .failed(why) }
        }
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var tabs: [PaneTab] = []
    @Published var selected: UUID?

    var current: PaneTab? { tabs.first { $0.id == selected } }

    func open(_ window: WindowInfo, on machine: Machine, fit: Bool, viewport: CGSize) {
        let tab = PaneTab(machine: machine, window: window, fitToPhone: fit)
        tab.viewport = viewport
        tabs.append(tab)
        select(tab.id)
        tab.connect()
    }

    func select(_ id: UUID) {
        selected = id
        for t in tabs { t.setActive(t.id == id) }
    }

    func close(_ tab: PaneTab) {
        tab.close()
        tabs.removeAll { $0.id == tab.id }
        if selected == tab.id { selected = tabs.last?.id }
        if let s = selected { select(s) }
    }

    /// iOS drops sockets while the app is in the background; coming back
    /// reconnects every tab to the same window.
    func reconnectAll() {
        for t in tabs where t.status != .live && t.status != .closed { t.connect() }
    }
}

/// A one-off connection that asks a machine for its window list.
@MainActor
final class WindowList: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published var loading = false
    @Published var problem: String?
    private var link: AgentLink?

    func load(_ machine: Machine) {
        link?.close()
        loading = true
        problem = nil
        let link = AgentLink(hosts: machine.hosts) { [weak self] e in
            guard let self else { return }
            switch e {
            case .ready:
                self.link?.send(Control(op: "hello", version: Wire.version))
                self.link?.send(Control(op: "list"))
            case .control(let msg):
                if msg.op == "windows" {
                    self.windows = msg.windows ?? []
                    self.loading = false
                    self.link?.close()
                } else if msg.op == "error" {
                    self.problem = msg.error
                }
            case .failed(let why):
                if self.loading { self.problem = why; self.loading = false }
            default:
                break
            }
        }
        self.link = link
        link.connect()
    }
}
