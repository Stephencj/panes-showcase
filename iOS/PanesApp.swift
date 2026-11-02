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

    /// For tests: PANES_OPEN="<title text>" opens that window on the first machine at launch.
    private func autoOpen() {
        guard let needle = ProcessInfo.processInfo.environment["PANES_OPEN"], store.tabs.isEmpty else { return }
        let machine = Machine.defaults[0]
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
            PickerView(viewport: viewport) { window, machine, fit in
                picking = false
                store.open(window, on: machine, fit: fit, viewport: viewport)
            }
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
                Text(tab.window.app).font(.caption.weight(.semibold)).lineLimit(1)
                Text(tab.machine.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Button(action: close) { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close \(tab.window.app)")
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
            StreamSurface(tab: tab, keyboard: $keyboard)
                .ignoresSafeArea(.keyboard)
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
                    Toggle("Fit window to phone", isOn: $fit)
                } footer: {
                    Text("Fitting resizes the window on the Mac to the phone's shape while the tab is open, and puts it back when you close the tab.")
                }
                if list.loading {
                    HStack { ProgressView(); Text("Asking \(machine.name) for its windows…").foregroundStyle(.secondary) }
                }
                if let problem = list.problem {
                    Text(problem).foregroundStyle(.orange)
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
