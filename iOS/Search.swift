import SwiftUI

/// What every machine offers, asked for each time search opens.
@MainActor
final class Catalog: ObservableObject {
    let lists: [String: WindowList] = Dictionary(uniqueKeysWithValues: Machine.defaults.map { ($0.name, WindowList()) })

    func refresh() {
        for m in Machine.defaults { lists[m.name]?.load(m) }
    }
}

/// One search across every machine (docs/UI.md): Recent, then a section per
/// machine; a machine that's off says so without holding up the rest.
struct SearchView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var catalog: Catalog
    @Binding var query: String
    let done: () -> Void
    let opened: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                    TextField("Xcode, Terminal, linux-box…", text: $query)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(openFirst)
                        .accessibilityLabel("Search apps on every machine")
                        .accessibilityIdentifier("search")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.secondary) }
                            .accessibilityLabel("Clear")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Palette.field, in: RoundedRectangle(cornerRadius: 12))
                Button("Cancel", action: done).foregroundStyle(Palette.link)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if query.isEmpty && !recentRows.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            SectionTitle(text: "Recent").padding(.bottom, 4)
                            ForEach(recentRows) { row in ResultRow(row: row) { pick(row) } }
                        }
                    }
                    ForEach(Machine.defaults) { m in
                        if let list = catalog.lists[m.name] {
                            MachineResults(machine: m, list: list, query: query, pick: pick)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .foregroundStyle(Palette.text)
        .background(Palette.ground.ignoresSafeArea())
        .onAppear { focused = true }
    }

    private var recentRows: [SearchRow] {
        store.recents.compactMap { ref in
            guard let m = Machine.named(ref.machine) else { return nil }
            return SearchRow.recent(ref, machine: m, open: store.existing(ref) != nil)
        }
    }

    private func pick(_ row: SearchRow) {
        switch row.target {
        case .window(let w):
            store.open(w, on: row.machine, fit: Store.fitWindows)
        case .terminal:
            store.openTerminal(on: row.machine)
        case .app(let a):
            store.openApp(a, on: row.machine)
        case .macApp(let a):
            store.openMacApp(a, on: row.machine)
        case .recent(let ref):
            openRecent(ref, on: row.machine)
        }
        opened()
    }

    /// A recent window is looked up again (its id changes when the app restarts).
    private func openRecent(_ ref: TabRef, on m: Machine) {
        if let have = store.existing(ref) { return store.select(have.id) }
        switch ref.kind {
        case "window":
            let windows = catalog.lists[m.name]?.windows ?? []
            if let w = windows.first(where: { $0.id == ref.windowID })
                ?? windows.first(where: { $0.app == ref.app && $0.title == ref.title })
                ?? windows.first(where: { $0.app == ref.app }) {
                store.open(w, on: m, fit: Store.fitWindows)
            } else if let id = ref.appID {
                // Its window is gone: start the app again.
                store.openMacApp(AppInfo(id: id, name: ref.app), on: m)
            } else {
                store.flash("\(ref.app) has no window open on \(m.name) right now.")
            }
        case "terminal":
            store.openTerminal(on: m)
        default:
            if let id = ref.appID { store.openApp(AppInfo(id: id, name: ref.app), on: m) }
        }
    }

    /// Return opens the first match.
    private func openFirst() {
        for m in Machine.defaults {
            if let list = catalog.lists[m.name], let row = SearchRow.rows(for: m, list: list, store: store, query: query).first {
                return pick(row)
            }
        }
    }
}

struct SearchRow: Identifiable {
    enum Target { case window(WindowInfo), terminal, app(AppInfo), macApp(AppInfo), recent(TabRef) }
    let id: String
    let machine: Machine
    let app: String
    let detail: String?
    let open: Bool
    let target: Target

    static func recent(_ ref: TabRef, machine: Machine, open: Bool) -> SearchRow {
        let detail = ref.kind == "terminal" ? "New terminal" : ref.title
        return SearchRow(id: "recent|" + Flow.recentKey(ref), machine: machine, app: ref.app,
                         detail: detail == ref.app ? nil : detail, open: open, target: .recent(ref))
    }

    /// Everything a machine offers that matches `query`.
    /// With nothing typed, a machine shows this many of its apps until "All N apps" is tapped.
    static let appsShown = 8

    @MainActor
    static func rows(for m: Machine, list: WindowList, store: Store, query: String, allApps: Bool = true) -> [SearchRow] {
        var out: [SearchRow] = []
        for w in list.windows where Flow.matches(query, [w.app, w.title, m.name]) {
            let open = store.existing(TabRef(machine: m.name, kind: "window", app: w.app, windowID: w.id)) != nil
            out.append(SearchRow(id: "w\(w.id)", machine: m, app: w.app, detail: w.title, open: open, target: .window(w)))
        }
        if list.features.contains("terminal"), Flow.matches(query, ["Terminal", "New terminal", "shell tmux", m.name]) {
            out.append(SearchRow(id: "terminal", machine: m, app: "Terminal", detail: "New terminal", open: false, target: .terminal))
        }
        // A Mac lists every installed app (running or not); a Linux box its desktop apps.
        let mac = list.features.contains("windows")
        let apps = list.apps.filter { Flow.matches(query, [$0.name, $0.id, m.name]) }
        for a in allApps ? apps : Array(apps.prefix(appsShown)) {
            out.append(SearchRow(id: "a" + a.id, machine: m, app: a.name, detail: mac ? "app" : nil, open: false,
                                 target: mac ? .macApp(a) : .app(a)))
        }
        return out
    }
}

struct MachineResults: View {
    @EnvironmentObject var store: Store
    let machine: Machine
    @ObservedObject var list: WindowList
    let query: String
    let pick: (SearchRow) -> Void
    @State private var expanded = false

    var body: some View {
        let rows = SearchRow.rows(for: machine, list: list, store: store, query: query, allApps: !collapsed)
        if !(query.isEmpty == false && rows.isEmpty && !list.loading && list.problem == nil) {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: machine.name, color: machine.tint).padding(.bottom, 4)
                if list.loading && rows.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Asking \(machine.name)…").foregroundStyle(Palette.secondary)
                    }
                    .frame(minHeight: 52)
                } else if list.problem != nil && rows.isEmpty {
                    Text("Can't reach \(machine.name)").foregroundStyle(Palette.secondary).frame(minHeight: 44)
                }
                ForEach(rows) { row in ResultRow(row: row) { pick(row) } }
                if collapsed && list.apps.count > SearchRow.appsShown {
                    Button { expanded = true } label: {
                        Text("All \(list.apps.count) apps on \(machine.name)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Palette.link)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("all-apps-\(machine.name)")
                }
            }
        }
    }

    private var collapsed: Bool { query.isEmpty && !expanded }
}

struct ResultRow: View {
    let row: SearchRow
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AppTile(name: row.app, color: row.machine.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.app).font(.body.weight(.medium)).lineLimit(1)
                    Text([row.machine.name, row.detail].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(row.open ? "Switch to" : "Open").font(.subheadline).foregroundStyle(Palette.secondary)
            }
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .foregroundStyle(Palette.text)
        .accessibilityIdentifier("result-\(row.machine.name)-\(row.id)")
    }
}
