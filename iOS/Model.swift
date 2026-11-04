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
    /// Its Panes Web address, which Linux app tabs load through.
    var web: String?
    /// Its colour everywhere in the UI (docs/UI.md).
    var color: String?

    var tint: SwiftUI.Color {
        let c = Flow.rgb(color) ?? (0.64, 0.66, 0.70)
        return SwiftUI.Color(red: c.0, green: c.1, blue: c.2)
    }

    static func named(_ name: String) -> Machine? { defaults.first { $0.name == name } }

    /// From Shared/machines.json, the same list Panes Web uses.
    static let defaults: [Machine] = {
        // Tests point the app at agents on this Mac with PANES_HOSTS=127.0.0.1,
        // or at a whole list with PANES_MACHINES=<path to a machines.json>.
        if let path = ProcessInfo.processInfo.environment["PANES_MACHINES"],
           let data = FileManager.default.contents(atPath: path),
           let list = try? JSONDecoder().decode([Machine].self, from: data) {
            return list
        }
        if let hosts = ProcessInfo.processInfo.environment["PANES_HOSTS"] {
            return [Machine(name: "Mac mini", hosts: hosts.split(separator: ",").map(String.init),
                            web: ProcessInfo.processInfo.environment["PANES_WEB"], color: "#5B9BFF")]
        }
        guard let url = Bundle.main.url(forResource: "machines", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Machine].self, from: data), !list.isEmpty else { return [] }
        return list
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
    /// What the tab grid shows for it.
    @Published var preview: UIImage?

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
        config.userContentController.addUserScript(
            WKUserScript(source: WebKeys.pageScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let v = WKWebView(frame: .zero, configuration: config)
        v.isOpaque = false
        v.backgroundColor = .black
        v.scrollView.isScrollEnabled = false
        return v
    }()
    private var appURL: URL?
    private var webAddress: String?

    var viewport: CGSize = CGSize(width: 393, height: 700)
    private let audio = AudioPlayer()
    private var link: AgentLink?
    private var format: CMVideoFormatDescription?
    private var active = true
    private var waitingForKeyframe = true

    /// How another device (or a later visit) opens the same thing.
    var ref: TabRef {
        switch kind {
        case .window(let w):
            TabRef(machine: machine.name, kind: "window", app: w.app, title: title, windowID: w.id)
        case .terminal(let session):
            TabRef(machine: machine.name, kind: "terminal", app: "Terminal", title: title, session: session)
        case .app(let a, let session):
            TabRef(machine: machine.name, kind: "app", app: a.name, title: title, session: session, appID: a.id)
        }
    }

    /// Refreshes `preview`: window tabs ask the agent for a picture of the
    /// window; terminals and apps draw their own view.
    func requestPreview() {
        switch kind {
        case .window:
            link?.send(Control(op: "snapshot", width: 480))
        case .terminal:
            let v = terminalView
            guard v.bounds.width > 0 else { return }
            preview = UIGraphicsImageRenderer(bounds: v.bounds).image { _ in v.drawHierarchy(in: v.bounds, afterScreenUpdates: false) }
        case .app:
            guard webView.bounds.width > 0 else { return }
            webView.takeSnapshot(with: nil) { [weak self] image, _ in
                if let image { self?.preview = image }
            }
        }
    }

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
        audio.stop()
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
        if case .window = kind {
            link?.send(Control(op: on ? "resume" : "pause"))
            if !on { audio.stop() }
        }
    }

    func refresh() { link?.send(Control(op: "keyframe")) }

    func send(_ event: InputEvent) { link?.send(Control(op: "input", event: event)) }

    func sendTerminal(_ bytes: Data) { link?.sendRaw(.terminal, bytes) }

    /// App tabs: typed keys go into Xpra's page as DOM key events.
    func sendToPage(_ e: InputEvent) {
        let js = WebKeys.script(WebKeys.keys(for: e))
        guard !js.isEmpty else { return }
        webView.evaluateJavaScript("(function(){ try { \(js) return 'ok'; } catch (e) { return String(e); } })()") { result, error in
            if let error { print("panes: key script failed: \(error)") }
            else if let r = result as? String, r != "ok" { print("panes: key script: \(r)") }
        }
    }

    func resizeTerminal(cols: Int, rows: Int) { link?.send(Control(op: "resize", cols: cols, rows: rows)) }

    private func handle(_ e: AgentLink.Event) {
        switch e {
        case .ready:
            link?.send(Control(op: "hello", version: Wire.version))
            switch kind {
            case .window(let w):
                let vp = fitToPhone ? Size(width: viewport.width, height: viewport.height) : nil
                link?.send(Control(op: "open", windowID: w.id, viewport: vp,
                                   audio: Store.setting("streamAudio")))
                if !active { link?.send(Control(op: "pause")) }
            case .terminal(let session):
                let t = terminalView.getTerminal()
                link?.send(Control(op: "terminal", name: session, cols: t.cols, rows: t.rows))
            case .app(let a, let session):
                link?.send(Control(op: "launch", app: a.id, name: session))
            }
        case .control(let msg):
            switch msg.op {
            case "hello":
                webAddress = msg.web
            case "opened":
                status = .live
                if let t = msg.title, !t.isEmpty { title = t }
                if let w = msg.width, let h = msg.height { windowSize = CGSize(width: w, height: h) }
            case "terminalOpened":
                status = .live
            case "launched":
                status = .live
                // Same session as before (a reconnect) keeps the page as it is.
                // Newer agents send a path on the machine's Panes Web address; the
                // phone's own keyboard is used, so Xpra's on-screen one stays hidden.
                let base = (webAddress ?? machine.web).flatMap(URL.init(string:))
                if let u = msg.url.flatMap({ URL(string: $0 + "&keyboard=false", relativeTo: base)?.absoluteURL }),
                   u != appURL {
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
        case .audioFormat(let f):
            audio.setFormat(f)
        case .audio(let pts, let packet):
            if active { audio.play(ptsMicros: pts, packet: packet) }
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
        case .snapshot(let jpeg):
            if let image = UIImage(data: jpeg) { preview = image }
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
    /// Phones and browsers elsewhere, and their tabs (docs/UI.md).
    @Published var otherDevices: [DeviceInfo] = []
    @Published var notice: Notice?
    @Published var recents: [TabRef] = Store.loadRecents()
    @Published var deviceName: String = UserDefaults.standard.string(forKey: "deviceName") ?? "iPhone" {
        didSet {
            UserDefaults.standard.set(deviceName, forKey: "deviceName")
            scheduleSync()
        }
    }
    /// The size tabs get on screen, which fitted windows are shaped to.
    var viewport = CGSize(width: 393, height: 700)

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var text: String
        /// Tapping it switches to this tab.
        var tab: UUID?
    }

    /// Made up once and kept: how other devices address this one.
    let deviceID: String = {
        if let id = UserDefaults.standard.string(forKey: "deviceID") { return id }
        let id = "phone-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "deviceID")
        return id
    }()

    private var arrivals = ArrivalFilter()
    private var syncTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var deviceLists: [String: [DeviceInfo]] = [:]

    var current: PaneTab? { tabs.first { $0.id == selected } }
    var currentIndex: Int? { tabs.firstIndex { $0.id == selected } }

    func open(_ window: WindowInfo, on machine: Machine, fit: Bool, viewport: CGSize? = nil) {
        if let have = existing(TabRef(machine: machine.name, kind: "window", app: window.app, windowID: window.id)) {
            return select(have.id)
        }
        add(PaneTab(machine: machine, kind: .window(window), fitToPhone: fit), viewport: viewport ?? self.viewport)
    }

    func openTerminal(on machine: Machine, session: String? = nil) {
        add(PaneTab(machine: machine, kind: .terminal(session: session ?? Self.newSessionName())), viewport: .zero)
    }

    func openApp(_ app: AppInfo, on machine: Machine, session: String? = nil) {
        add(PaneTab(machine: machine, kind: .app(app, session: session ?? Self.newSessionName())), viewport: .zero)
    }

    /// Opens a tab another device has (or sent): the same window, tmux
    /// session or app session. Switches to it if it's already open here.
    @discardableResult
    func open(_ ref: TabRef, select: Bool = true) -> PaneTab? {
        if let have = existing(ref) {
            if select { self.select(have.id) }
            return have
        }
        guard let machine = Machine.named(ref.machine) else {
            flash("\(ref.machine) isn't one of this phone's machines.")
            return nil
        }
        let kind: PaneTab.Kind
        switch ref.kind {
        case "window":
            guard let id = ref.windowID else { return nil }
            kind = .window(WindowInfo(id: id, app: ref.app, bundleID: "", title: ref.title ?? ref.app, width: 0, height: 0))
        case "terminal":
            kind = .terminal(session: ref.session ?? Self.newSessionName())
        default:
            guard let appID = ref.appID else { return nil }
            kind = .app(AppInfo(id: appID, name: ref.app), session: ref.session ?? Self.newSessionName())
        }
        let tab = PaneTab(machine: machine, kind: kind, fitToPhone: Self.fitWindows)
        add(tab, viewport: viewport, select: select)
        return tab
    }

    static var fitWindows: Bool { setting("fitWindows") }

    /// A switch in Settings, on unless turned off (`bool(forKey:)` also reads
    /// "NO" passed on the command line by tests).
    static func setting(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }

    func existing(_ ref: TabRef) -> PaneTab? { tabs.first { Flow.sameTab($0.ref, ref) } }

    private static func newSessionName() -> String { "panes-" + UUID().uuidString.prefix(6).lowercased() }

    private func add(_ tab: PaneTab, viewport: CGSize, select: Bool = true) {
        tab.viewport = viewport
        tabs.append(tab)
        if select || selected == nil { self.select(tab.id) } else { tab.setActive(false) }
        tab.connect()
        remember(tab.ref)
        scheduleSync()
    }

    func select(_ id: UUID) {
        // The tab being left keeps a fresh picture for the tab grid.
        if let leaving = current, leaving.id != id { leaving.requestPreview() }
        selected = id
        for t in tabs { t.setActive(t.id == id) }
    }

    /// The next or previous tab (swiping the pill).
    func move(by step: Int) {
        guard let i = currentIndex else { return }
        let j = i + step
        guard tabs.indices.contains(j) else { return }
        select(tabs[j].id)
    }

    func close(_ tab: PaneTab) {
        // A terminal or app another device still has open keeps running for it.
        let shared = otherDevices.contains { $0.tabs.contains { Flow.sameTab($0, tab.ref) } }
        if !shared { tab.end() }
        // Give the "end" a moment to go out before the socket closes.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            tab.close()
        }
        let i = tabs.firstIndex { $0.id == tab.id } ?? 0
        tabs.removeAll { $0.id == tab.id }
        if selected == tab.id { selected = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id }
        if let s = selected { select(s) }
        scheduleSync()
    }

    func refreshPreviews() { for t in tabs { t.requestPreview() } }

    /// iOS drops sockets while the app is in the background; coming back
    /// reconnects every tab to the same window or tmux session.
    func reconnectAll() {
        for t in tabs where t.status != .live && t.status != .closed { t.connect() }
        scheduleSync()
    }

    // MARK: recents

    private func remember(_ ref: TabRef) {
        recents = Flow.addRecent(ref, to: recents)
        if let data = try? JSONEncoder().encode(recents) { UserDefaults.standard.set(data, forKey: "recents") }
    }

    private static func loadRecents() -> [TabRef] {
        guard let data = UserDefaults.standard.data(forKey: "recents") else { return [] }
        return (try? JSONDecoder().decode([TabRef].self, from: data)) ?? []
    }

    // MARK: notices

    /// UI tests hold notices longer (PANES_NOTICE_SECONDS) so they can read them.
    static let noticeSeconds = ProcessInfo.processInfo.environment["PANES_NOTICE_SECONDS"].flatMap(Double.init) ?? 5

    func flash(_ text: String, tab: UUID? = nil) {
        NSLog("panes notice: %@", text)
        let n = Notice(text: text, tab: tab)
        notice = n
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.noticeSeconds))
            if self.notice?.id == n.id { self.notice = nil }
        }
    }

    // MARK: other devices

    var me: DeviceInfo { DeviceInfo(id: deviceID, name: deviceName, kind: "phone", tabs: tabs.map(\.ref)) }

    /// Check in with every machine soon (changes come in bursts).
    func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self.syncNow()
        }
    }

    /// While the app is in use, check in every 15 s so other devices' tabs stay current.
    func setForeground(_ on: Bool) {
        heartbeat?.cancel()
        heartbeat = nil
        guard on else { return }
        heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                self.syncNow()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func syncNow() {
        let me = self.me
        for machine in Machine.defaults {
            AgentCall.run(machine) { call, hello in
                guard hello.features?.contains("devices") == true else { return call.finish() }
                call.send(Control(op: "device", device: me))
            } onReply: { [weak self] call, msg in
                switch msg.op {
                case "inbox":
                    self?.received(msg.sent ?? [])
                    call.send(Control(op: "devices", device: DeviceInfo(id: me.id, name: me.name, kind: "phone", tabs: [])))
                case "devices":
                    self?.heard(msg.devices ?? [], from: machine)
                    call.finish()
                default:
                    break
                }
            }
        }
    }

    private func heard(_ list: [DeviceInfo], from machine: Machine) {
        deviceLists[machine.name] = list
        let merged = Flow.merge(Array(deviceLists.values), except: deviceID)
        if merged != otherDevices { otherDevices = merged }
    }

    private func received(_ sent: [SentTab]) {
        for s in sent where arrivals.admit(s) {
            if let tab = open(s.tab, select: false) {
                flash("\(s.tab.app) arrived from \(s.from)", tab: tab.id)
            }
        }
    }

    /// Leaves the tab with `device` through every machine (whichever it
    /// checks in with first delivers it).
    func send(_ tab: PaneTab, to device: DeviceInfo) {
        let msg = Control(op: "send", name: deviceName, to: device.id, tab: tab.ref)
        var delivered = false
        var pending = Machine.defaults.count
        for machine in Machine.defaults {
            AgentCall.run(machine) { call, hello in
                guard hello.features?.contains("devices") == true else { return call.finish() }
                call.send(msg)
                // `send` has no answer unless it failed; a quick devices call confirms it went through.
                call.send(Control(op: "devices", device: DeviceInfo(id: self.deviceID, name: "", kind: "phone", tabs: [])))
            } onReply: { call, reply in
                if reply.op == "devices" { delivered = true; call.finish() }
                if reply.op == "error" { call.finish() }
            } onDone: { [weak self] in
                pending -= 1
                guard pending == 0, let self else { return }
                self.flash(delivered ? "Sent. \(tab.appName) is waiting in Panes on \(device.name)."
                                     : "Couldn't reach any machine to send it.")
            }
        }
    }
}

/// A short conversation with one machine's agent: hello, a few messages, done.
@MainActor
final class AgentCall {
    private var link: AgentLink?
    private var done = false
    private let onDone: () -> Void

    private init(onDone: @escaping () -> Void) { self.onDone = onDone }

    static func run(_ machine: Machine,
                    afterHello: @escaping (AgentCall, Control) -> Void,
                    onReply: @escaping (AgentCall, Control) -> Void,
                    onDone: @escaping () -> Void = {}) {
        let call = AgentCall(onDone: onDone)
        let link = AgentLink(hosts: machine.hosts) { e in
            switch e {
            case .ready:
                call.send(Control(op: "hello", version: Wire.version))
            case .control(let msg):
                if msg.op == "hello" { afterHello(call, msg) } else { onReply(call, msg) }
            case .failed:
                call.finish()
            default:
                break
            }
        }
        call.link = link
        link.connect()
        // Never hang around: a machine that's slow to answer is skipped this time.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            call.finish()
        }
    }

    func send(_ msg: Control) { link?.send(msg) }

    func finish() {
        guard !done else { return }
        done = true
        link?.close()
        link = nil
        onDone()
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
