import SwiftUI

@main
struct PanesApp: App {
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .onAppear(perform: autoOpen)
        }
        .onChange(of: phase) { _, now in
            if now == .active { store.reconnectAll() }
        }
    }

    /// For tests: PANES_OPEN="<title text>" opens that window on the first machine
    /// at launch; PANES_TERMINAL=<command> opens a terminal there and types the command;
    /// PANES_APP=<name> launches that Linux app.
    private func autoOpen() {
        let env = ProcessInfo.processInfo.environment
        let machine = Machine.defaults[0]
        if let command = env["PANES_TERMINAL"], store.tabs.isEmpty {
            store.openTerminal(on: machine)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                store.current?.sendTerminal(Data((command + "\r").utf8))
            }
            return
        }
        if let appName = env["PANES_APP"], store.tabs.isEmpty {
            // PANES_APP="<app name>": launch that Linux app from the first machine.
            let list = WindowList()
            list.load(machine)
            Task { @MainActor in
                for _ in 0..<50 where list.loading { try? await Task.sleep(for: .milliseconds(200)) }
                if let a = list.apps.first(where: { $0.name.localizedCaseInsensitiveContains(appName) }) {
                    store.openApp(a, on: machine)
                    // PANES_TYPE="<text>": type it into the app once it's up (tests the key path).
                    if let text = env["PANES_TYPE"] {
                        try? await Task.sleep(for: .seconds(10))
                        store.current?.sendToPage(InputEvent(kind: "text", text: text))
                    }
                }
            }
            return
        }
        guard let needle = env["PANES_OPEN"], store.tabs.isEmpty else { return }
        let list = WindowList()
        list.load(machine)
        Task { @MainActor in
            for _ in 0..<50 where list.loading { try? await Task.sleep(for: .milliseconds(200)) }
            if let w = list.windows.first(where: { $0.title.localizedCaseInsensitiveContains(needle) }) {
                store.open(w, on: machine, fit: true, viewport: CGSize(width: 393, height: 700))
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var picking = false
    @State private var keyboard = false
    @State private var viewport = CGSize(width: 393, height: 700)

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            ZStack {
                if let tab = store.current {
                    TabScreen(tab: tab, keyboard: $keyboard)
                        .id(tab.id)
                } else {
                    empty
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GeometryReader { g in
                Color.clear.onAppear { viewport = g.size }.onChange(of: g.size) { _, s in viewport = s }
            })
        }
        .background(Color.black)
        .sheet(isPresented: $picking) {
            PickerView(viewport: viewport, open: { window, machine, fit in
                picking = false
                store.open(window, on: machine, fit: fit, viewport: viewport)
            }, openTerminal: { machine in
                picking = false
                store.openTerminal(on: machine)
            }, openApp: { app, machine in
                picking = false
                store.openApp(app, on: machine)
            })
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.tabs) { tab in
                        TabChip(tab: tab, selected: tab.id == store.selected,
                                select: { store.select(tab.id) }, close: { store.close(tab) })
                    }
                }
                .padding(.horizontal, 10)
            }
            if store.current != nil {
                Button { keyboard.toggle() } label: {
                    Image(systemName: keyboard ? "keyboard.chevron.compact.down" : "keyboard")
                }
                .accessibilityLabel(keyboard ? "Hide keyboard" : "Show keyboard")
            }
            Button { picking = true } label: { Image(systemName: "plus").font(.title3.weight(.semibold)) }
                .accessibilityLabel("Open a window")
                .padding(.trailing, 12)
        }
        .frame(height: 44)
        .background(.bar)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "macwindow.on.rectangle").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No windows open").font(.headline)
            Button("Open a window") { picking = true }.buttonStyle(.borderedProminent)
        }
    }
}

struct TabChip: View {
    @ObservedObject var tab: PaneTab
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.appName).font(.caption.weight(.semibold)).lineLimit(1)
                Text(tab.machine.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Button(action: close) { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close \(tab.appName)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(selected ? Color.white.opacity(0.16) : Color.white.opacity(0.06), in: Capsule())
        .onTapGesture(perform: select)
    }

    private var dot: Color {
        switch tab.status {
        case .live: .green
        case .connecting: .yellow
        case .failed: .red
        case .closed: .gray
        }
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
            case .connecting:
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
    }
}

struct PickerView: View {
    let viewport: CGSize
    let open: (WindowInfo, Machine, Bool) -> Void
    let openTerminal: (Machine) -> Void
    let openApp: (AppInfo, Machine) -> Void
    @State private var machine = Machine.defaults[0]
    @State private var fit = true
    @StateObject private var list = WindowList()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Machine", selection: $machine) {
                        ForEach(Machine.defaults) { Text($0.name).tag($0) }
                    }
                    if list.features.contains("windows") {
                        Toggle("Fit window to phone", isOn: $fit)
                    }
                } footer: {
                    if list.features.contains("windows") {
                        Text("Fitting resizes the window on the Mac to the phone's shape while the tab is open, and puts it back when you close the tab.")
                    }
                }
                if list.features.contains("terminal") {
                    Section {
                        Button { openTerminal(machine) } label: {
                            Label("New terminal", systemImage: "terminal")
                        }
                    } footer: {
                        Text("Runs in tmux on \(machine.name), so it keeps going when you leave the app.")
                    }
                }
                if list.loading {
                    HStack { ProgressView(); Text("Asking \(machine.name) for its windows…").foregroundStyle(.secondary) }
                }
                if let problem = list.problem {
                    Text(problem).foregroundStyle(.orange)
                }
                if !list.apps.isEmpty {
                    Section {
                        ForEach(list.apps) { app in
                            Button(app.name) { openApp(app, machine) }
                        }
                    } header: {
                        Text("Apps")
                    } footer: {
                        Text("Each app runs in its own session on \(machine.name) and keeps running when you leave.")
                    }
                }
                ForEach(groups, id: \.0) { app, windows in
                    Section(app) {
                        ForEach(windows) { w in
                            Button { open(w, machine, fit) } label: {
                                VStack(alignment: .leading) {
                                    Text(w.title).lineLimit(2)
                                    Text("\(Int(w.width)) × \(Int(w.height))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Open a window")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { list.load(machine) }
            .onAppear { list.load(machine) }
            .onChange(of: machine) { _, m in list.load(m) }
        }
    }

    private var groups: [(String, [WindowInfo])] {
        Dictionary(grouping: list.windows, by: \.app).sorted { $0.key.lowercased() < $1.key.lowercased() }
    }
}
