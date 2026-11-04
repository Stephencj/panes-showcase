import SwiftUI

@main
struct PanesApp: App {
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var phase

    init() {
        AudioPlayer.configureSession()
        // UI tests: no animations, so XCUITest isn't left waiting for the app to settle.
        if ProcessInfo.processInfo.environment["PANES_UITEST"] != nil { UIView.setAnimationsEnabled(false) }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .onAppear {
                    store.setForeground(true)
                    autoOpen()
                }
        }
        .onChange(of: phase) { _, now in
            if now == .active { store.reconnectAll() }
            store.setForeground(now == .active)
        }
    }

    /// For tests, on the first machine at launch:
    /// - PANES_OPEN="<title>|<title>…" opens those windows, in order;
    /// - PANES_TERMINAL=<command> opens a terminal and types the command;
    /// - PANES_APP=<name> launches that Linux app (PANES_TYPE=<text> then types into it);
    /// - PANES_DEVICE_NAME names this device; PANES_SHOW=grid|search|send|settings
    ///   opens that screen once the tabs are up (PANES_QUERY fills the search).
    private func autoOpen() {
        let env = ProcessInfo.processInfo.environment
        guard store.tabs.isEmpty, let machine = Machine.defaults.first else { return }
        if let name = env["PANES_DEVICE_NAME"] { store.deviceName = name }
        Task { @MainActor in
            if let command = env["PANES_TERMINAL"] {
                store.openTerminal(on: machine)
                let tab = store.current
                try? await Task.sleep(for: .seconds(2))
                tab?.sendTerminal(Data((command + "\r").utf8))
            }
            if env["PANES_APP"] != nil || env["PANES_OPEN"] != nil {
                let list = WindowList()
                list.load(machine)
                for _ in 0..<50 where list.loading { try? await Task.sleep(for: .milliseconds(200)) }
                for needle in (env["PANES_OPEN"] ?? "").split(separator: "|").map(String.init) {
                    if let w = list.windows.first(where: { $0.title.localizedCaseInsensitiveContains(needle) }) {
                        store.open(w, on: machine, fit: Store.fitWindows)
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                if let appName = env["PANES_APP"],
                   let a = list.apps.first(where: { $0.name.localizedCaseInsensitiveContains(appName) }) {
                    store.openApp(a, on: machine)
                    if let text = env["PANES_TYPE"] {
                        let tab = store.current
                        try? await Task.sleep(for: .seconds(10))
                        tab?.sendToPage(InputEvent(kind: "text", text: text))
                    }
                }
            }
            if let show = env["PANES_SHOW"] {
                try? await Task.sleep(for: .seconds(3))
                NotificationCenter.default.post(name: .panesShow, object: show)
            }
        }
    }
}

extension Notification.Name {
    /// Test hook: which screen to show (see PanesApp.autoOpen).
    static let panesShow = Notification.Name("panesShow")
}

/// The colours from docs/UI.md.
enum Palette {
    static let ground = Color(red: 0.043, green: 0.047, blue: 0.055)
    static let surface = Color(red: 0.086, green: 0.094, blue: 0.11)
    static let field = Color(red: 0.11, green: 0.118, blue: 0.137)
    static let raised = Color(red: 0.149, green: 0.161, blue: 0.188)
    static let text = Color(red: 0.949, green: 0.953, blue: 0.961)
    static let secondary = Color(red: 0.639, green: 0.659, blue: 0.702)
    static let link = Color(red: 0.541, green: 0.722, blue: 1.0)
    static let bar = Color(red: 0.11, green: 0.118, blue: 0.137).opacity(0.92)
}

struct ContentView: View {
    enum Screen { case tab, grid, search }

    @EnvironmentObject var store: Store
    @StateObject private var catalog = Catalog()
    @State private var screen: Screen = .tab
    /// Where search goes back to.
    @State private var searchFrom: Screen = .tab
    @State private var keyboard = false
    @State private var slideForward = true
    @State private var sending: PaneTab?
    @State private var settings = false
    @State private var query = ""

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(spacing: 0) {
                tabArea
                BottomBar(keyboard: $keyboard, step: step, showGrid: { show(.grid) }, showSearch: { show(.search) })
            }
            if screen == .grid {
                TabGridView(close: { show(.tab) }, search: { show(.search) },
                            send: { sending = $0 }, settings: { settings = true }, pick: { id in
                                store.select(id)
                                show(.tab)
                            })
                .transition(.opacity.combined(with: .scale(scale: 1.04)))
                .zIndex(1)
            }
            if screen == .search {
                SearchView(catalog: catalog, query: $query, done: {
                    query = ""
                    show(searchFrom == .search ? .tab : searchFrom)
                }, opened: {
                    query = ""
                    show(.tab)
                })
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(2)
            }
            NoticeBanner().zIndex(3)
        }
        .sheet(item: $sending) { tab in SendSheet(tab: tab) { sending = nil } }
        .sheet(isPresented: $settings) { SettingsSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .panesShow)) { note in
            switch note.object as? String {
            case "grid": show(.grid)
            case "search":
                query = ProcessInfo.processInfo.environment["PANES_QUERY"] ?? ""
                show(.search)
            case "send": sending = store.current
            case "settings": settings = true
            default: break
            }
        }
    }

    private var tabArea: some View {
        GeometryReader { g in
            ZStack {
                if let tab = store.current {
                    TabScreen(tab: tab, keyboard: $keyboard)
                        .id(tab.id)
                        .transition(.asymmetric(insertion: .move(edge: slideForward ? .trailing : .leading),
                                                removal: .move(edge: slideForward ? .leading : .trailing)))
                } else {
                    EmptyTabs { show(.search) }
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
            .onAppear { store.viewport = g.size }
            .onChange(of: g.size) { _, s in store.viewport = s }
        }
    }

    private static let animate = ProcessInfo.processInfo.environment["PANES_UITEST"] == nil

    private func step(_ by: Int) {
        guard let i = store.currentIndex, store.tabs.indices.contains(i + by) else { return }
        slideForward = by > 0
        withAnimation(Self.animate ? .spring(response: 0.32, dampingFraction: 0.9) : nil) { store.move(by: by) }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func show(_ s: Screen) {
        if s == .search { searchFrom = screen; catalog.refresh() }
        if s == .grid { store.refreshPreviews() }
        if s != .tab { keyboard = false }
        withAnimation(Self.animate ? .easeOut(duration: 0.22) : nil) { screen = s }
    }
}

/// Keyboard button, the pill (swipe it to change tab, tap or swipe up for all
/// tabs), search button; one dot per tab above.
struct BottomBar: View {
    @EnvironmentObject var store: Store
    @Binding var keyboard: Bool
    let step: (Int) -> Void
    let showGrid: () -> Void
    let showSearch: () -> Void
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        VStack(spacing: 8) {
            if store.tabs.count > 1 && !keyboard {
                HStack(spacing: 5) {
                    ForEach(store.tabs) { t in
                        Capsule()
                            .fill(t.machine.tint)
                            .frame(width: t.id == store.selected ? 18 : 6, height: 6)
                            .opacity(t.id == store.selected ? 1 : 0.45)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: store.selected)
                .accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                RoundButton(system: keyboard ? "keyboard.chevron.compact.down" : "keyboard",
                            label: keyboard ? "Hide keyboard" : "Show keyboard") { keyboard.toggle() }
                    .disabled(store.current == nil)
                    .opacity(store.current == nil ? 0.4 : 1)
                pill
                RoundButton(system: "magnifyingglass", label: "Open an app", action: showSearch)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Palette.ground)
    }

    private var pill: some View {
        let tab = store.current
        let i = store.currentIndex ?? 0
        return HStack(spacing: 0) {
            Button { step(-1) } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 40, height: 52)
            }
            .opacity(i > 0 ? 1 : 0.3)
            .accessibilityLabel("Previous tab")
            Button(action: showGrid) {
                HStack(spacing: 7) {
                    if let tab {
                        Circle().fill(tab.machine.tint).frame(width: 9, height: 9)
                        Text(tab.appName).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(tab.machine.name).font(.subheadline).foregroundStyle(Palette.secondary).lineLimit(1)
                    } else {
                        Text("No tabs").font(.subheadline).foregroundStyle(Palette.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Rectangle())
                .offset(x: drag * 0.4)
            }
            .accessibilityLabel(tab.map { "\($0.appName) on \($0.machine.name), tab \(i + 1) of \(store.tabs.count). Show all tabs" }
                                ?? "Show all tabs")
            .accessibilityIdentifier("pill")
            Button { step(1) } label: {
                Image(systemName: "chevron.right").font(.body.weight(.semibold)).frame(width: 40, height: 52)
            }
            .opacity(i < store.tabs.count - 1 ? 1 : 0.3)
            .accessibilityLabel("Next tab")
        }
        .foregroundStyle(Palette.text)
        .background(Palette.bar, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08)))
        .contentShape(Capsule())
        // A drag wins over the buttons inside; a tap still reaches them.
        .highPriorityGesture(
            DragGesture(minimumDistance: 14)
                .updating($drag) { v, state, _ in
                    if abs(v.translation.width) > abs(v.translation.height) { state = v.translation.width }
                }
                .onEnded { v in
                    let t = v.translation
                    if abs(t.width) > abs(t.height), abs(t.width) > 36 {
                        step(t.width < 0 ? 1 : -1)
                    } else if t.height < -28 {
                        showGrid()
                    }
                }
        )
    }
}

struct RoundButton: View {
    let system: String
    let label: String
    let action: () -> Void

    init(system: String, label: String, action: @escaping () -> Void) {
        self.system = system
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 48, height: 48)
                .foregroundStyle(Palette.text)
                .background(Palette.bar, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.08)))
        }
        .accessibilityLabel(label)
    }
}

struct EmptyTabs: View {
    let open: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Nothing open").font(.title3.weight(.semibold))
            Text("Open an app on any of your machines.").font(.subheadline).foregroundStyle(Palette.secondary)
            Button(action: open) {
                Label("Open an app", systemImage: "magnifyingglass").padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .padding(32)
    }
}

/// "Sent…" and "<app> arrived from…" notices; tap one about a tab to switch to it.
struct NoticeBanner: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack {
            if let n = store.notice {
                Button {
                    if let id = n.tab, store.tabs.contains(where: { $0.id == id }) { store.select(id) }
                    store.notice = nil
                } label: {
                    Text(n.text)
                        .font(.subheadline)
                        .foregroundStyle(Palette.text)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                }
                .padding(.horizontal, 16)
                .accessibilityIdentifier("notice")
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(.top, 6)
        .animation(.easeOut(duration: 0.2), value: store.notice)
    }
}

struct TabScreen: View {
    @ObservedObject var tab: PaneTab
    @Binding var keyboard: Bool

    var body: some View {
        ZStack(alignment: .top) {
            if case .terminal = tab.kind {
                TerminalSurface(tab: tab, keyboard: $keyboard)
            } else if case .app = tab.kind {
                AppSurface(tab: tab, keyboard: $keyboard)
            } else {
                StreamSurface(tab: tab, keyboard: $keyboard)
                    .ignoresSafeArea(.keyboard)
            }
            switch tab.status {
            case .connecting where tab.preview == nil:
                ProgressView("Connecting to \(tab.machine.name)…").padding().background(.thinMaterial, in: .rect(cornerRadius: 12))
                    .frame(maxHeight: .infinity)
            case .failed(let why):
                VStack(spacing: 10) {
                    Text(why).multilineTextAlignment(.center)
                    Button("Reconnect") { tab.connect() }.buttonStyle(.borderedProminent)
                }
                .padding().background(.thinMaterial, in: .rect(cornerRadius: 12))
                .frame(maxHeight: .infinity)
            default:
                EmptyView()
            }
            if let notice = tab.notice {
                Text(notice).font(.footnote).padding(10)
                    .background(.orange.opacity(0.9), in: .rect(cornerRadius: 10))
                    .padding(8)
                    .onTapGesture { tab.notice = nil }
            }
        }
        .background(Color.black)
    }
}
