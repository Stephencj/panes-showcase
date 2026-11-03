import AVFoundation
import SwiftTerm
import SwiftUI
import WebKit

struct Machine: Identifiable, Hashable, Codable {
    var id: String { name }
    var name: String
    /// Tried in order: the Tailscale name, its Tailscale address, then the
    /// home-network address.
    var hosts: [String]

    static let defaults: [Machine] = {
        // Tests point the app at agents on this Mac with PANES_HOSTS=127.0.0.1.
        if let hosts = ProcessInfo.processInfo.environment["PANES_HOSTS"] {
            return [Machine(name: "Mac mini", hosts: hosts.split(separator: ",").map(String.init))]
        }
        return [
            Machine(name: "Mac mini", hosts: ["my-mac-mini", "100.64.0.10", "192.168.1.10"]),
            Machine(name: "linux-box", hosts: ["linux-box", "100.64.0.20"]),
        ]
    }()
}

/// One tab: a window or a terminal on a machine, over its own connection.
@MainActor
final class PaneTab: ObservableObject, Identifiable {
    enum Status: Equatable { case connecting, live, closed, failed(String) }
    enum Kind: Equatable {
        case window(WindowInfo)
        /// The tmux session it attaches to, so a reconnect finds the same programs.
        case terminal(session: String)
        /// A Linux app in its own Xpra session (named like a tmux session, same idea).
        case app(AppInfo, session: String)
    }

    let id = UUID()
    let machine: Machine
    let kind: Kind
    let fitToPhone: Bool
    @Published var status: Status = .connecting
    @Published var title: String
    @Published var notice: String?
    /// The Mac window's size in points, which sets the video's shape.
    @Published var windowSize: CGSize

    let renderer = AVSampleBufferDisplayLayer()
    /// Terminal tabs keep their view (and its scrollback) across tab switches.
    private(set) lazy var terminalView: TerminalView = {
        let v = TerminalView(frame: CGRect(x: 0, y: 0, width: 393, height: 600))
        v.terminalDelegate = terminalBridge
        v.backgroundColor = .black
        return v
    }()
    private lazy var terminalBridge = TerminalBridge(tab: self)
    /// App tabs show Xpra's web client; the view stays with the tab.
    private(set) lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let v = WKWebView(frame: .zero, configuration: config)
        v.isOpaque = false
        v.backgroundColor = .black
        v.scrollView.isScrollEnabled = false
        return v
    }()
    private var appURL: URL?

    var viewport: CGSize = CGSize(width: 393, height: 700)
    private var link: AgentLink?
    private var format: CMVideoFormatDescription?
    private var active = true
    private var waitingForKeyframe = true

    var appName: String {
        switch kind {
        case .window(let w): w.app
        case .terminal: "Terminal"
        case .app(let a, _): a.name
        }
    }

    init(machine: Machine, kind: Kind, fitToPhone: Bool = true) {
        self.machine = machine
        self.kind = kind
        self.fitToPhone = fitToPhone
        switch kind {
        case .window(let w):
            title = w.title
            windowSize = CGSize(width: w.width, height: w.height)
        case .terminal:
            title = "Terminal"
            windowSize = .zero
        case .app(let a, _):
            title = a.name
            windowSize = .zero
        }
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

    /// Closing a terminal or app tab ends its session on the machine (a
    /// dropped connection doesn't, so programs survive the app being suspended).
    func end() {
        switch kind {
        case .terminal(let session), .app(_, let session):
            link?.send(Control(op: "end", name: session))
        case .window:
            break
        }
    }

    /// Background tabs stop their video (the connection stays) so only the
    /// tab on screen uses bandwidth.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if case .window = kind { link?.send(Control(op: on ? "resume" : "pause")) }
    }

    func refresh() { link?.send(Control(op: "keyframe")) }

    func send(_ event: InputEvent) { link?.send(Control(op: "input", event: event)) }

    func sendTerminal(_ bytes: Data) { link?.sendRaw(.terminal, bytes) }

    func resizeTerminal(cols: Int, rows: Int) { link?.send(Control(op: "resize", cols: cols, rows: rows)) }

    private func handle(_ e: AgentLink.Event) {
        switch e {
        case .ready:
            link?.send(Control(op: "hello", version: Wire.version))
            switch kind {
            case .window(let w):
                let vp = fitToPhone ? Size(width: viewport.width, height: viewport.height) : nil
                link?.send(Control(op: "open", windowID: w.id, viewport: vp))
                if !active { link?.send(Control(op: "pause")) }
            case .terminal(let session):
                let t = terminalView.getTerminal()
                link?.send(Control(op: "terminal", name: session, cols: t.cols, rows: t.rows))
            case .app(let a, let session):
                link?.send(Control(op: "launch", app: a.id, name: session))
            }
        case .control(let msg):
            switch msg.op {
            case "opened":
                status = .live
                if let t = msg.title, !t.isEmpty { title = t }
                if let w = msg.width, let h = msg.height { windowSize = CGSize(width: w, height: h) }
            case "terminalOpened":
                status = .live
            case "launched":
                status = .live
                // Same session as before (a reconnect) keeps the page as it is.
                if let u = msg.url.flatMap(URL.init(string:)), u != appURL {
                    appURL = u
                    webView.load(URLRequest(url: u))
                }
            case "exited":
                status = .failed("The shell exited.")
            case "resized":
                if let w = msg.width, let h = msg.height { windowSize = CGSize(width: w, height: h) }
            case "closed":
                status = .failed("The window was closed on the Mac.")
            case "error":
                notice = msg.error
            default:
                break
            }
        case .terminal(let bytes):
            terminalView.feed(byteArray: [UInt8](bytes)[...])
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

/// SwiftTerm's delegate: keys typed go to the agent; size changes resize the pty.
final class TerminalBridge: NSObject, TerminalViewDelegate {
    weak var tab: PaneTab?
    init(tab: PaneTab) { self.tab = tab }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        MainActor.assumeIsolated { tab?.sendTerminal(bytes) }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { tab?.resizeTerminal(cols: newCols, rows: newRows) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        guard !title.isEmpty else { return }
        MainActor.assumeIsolated { tab?.title = title }
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor
final class Store: ObservableObject {
    @Published var tabs: [PaneTab] = []
    @Published var selected: UUID?

    var current: PaneTab? { tabs.first { $0.id == selected } }

    func open(_ window: WindowInfo, on machine: Machine, fit: Bool, viewport: CGSize) {
        add(PaneTab(machine: machine, kind: .window(window), fitToPhone: fit), viewport: viewport)
    }

    func openTerminal(on machine: Machine) {
        add(PaneTab(machine: machine, kind: .terminal(session: Self.newSessionName())), viewport: .zero)
    }

    func openApp(_ app: AppInfo, on machine: Machine) {
        add(PaneTab(machine: machine, kind: .app(app, session: Self.newSessionName())), viewport: .zero)
    }

    private static func newSessionName() -> String { "panes-" + UUID().uuidString.prefix(6).lowercased() }

    private func add(_ tab: PaneTab, viewport: CGSize) {
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
        tab.end()
        // Give the "end" a moment to go out before the socket closes.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            tab.close()
        }
        tabs.removeAll { $0.id == tab.id }
        if selected == tab.id { selected = tabs.last?.id }
        if let s = selected { select(s) }
    }

    /// iOS drops sockets while the app is in the background; coming back
    /// reconnects every tab to the same window or tmux session.
    func reconnectAll() {
        for t in tabs where t.status != .live && t.status != .closed { t.connect() }
    }
}

/// A one-off connection that asks a machine what it offers.
@MainActor
final class WindowList: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published var apps: [AppInfo] = []
    @Published var features: [String] = []
    @Published var loading = false
    @Published var problem: String?
    private var link: AgentLink?

    func load(_ machine: Machine) {
        link?.close()
        loading = true
        problem = nil
        windows = []
        apps = []
        features = []
        let link = AgentLink(hosts: machine.hosts) { [weak self] e in
            guard let self else { return }
            switch e {
            case .ready:
                self.link?.send(Control(op: "hello", version: Wire.version))
            case .control(let msg):
                switch msg.op {
                case "hello":
                    // Older agents didn't say; they only did windows.
                    self.features = msg.features ?? ["windows"]
                    if self.features.contains("windows") {
                        self.link?.send(Control(op: "list"))
                    } else if self.features.contains("apps") {
                        self.link?.send(Control(op: "apps"))
                    } else {
                        self.loading = false
                        self.link?.close()
                    }
                case "windows":
                    self.windows = msg.windows ?? []
                    self.loading = false
                    self.link?.close()
                case "apps":
                    self.apps = msg.apps ?? []
                    self.loading = false
                    self.link?.close()
                case "error":
                    self.problem = msg.error
                default:
                    break
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
