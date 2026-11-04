import Foundation

/// The phones and browsers that use this agent, the tabs each has open, and
/// tabs sent from one to another (docs/UI.md). Every client reports to every
/// machine it knows, so any one machine being off loses nothing.
final class DeviceBook {
    static let maxDevices = 20
    static let maxTabs = 60
    static let maxInbox = 20
    /// Devices not heard from in this long drop off the list.
    static let deviceTTL: Double = 30 * 24 * 3600
    /// Sent tabs nobody picked up in this long are dropped.
    static let sentTTL: Double = 7 * 24 * 3600

    private struct State: Codable {
        var devices: [DeviceInfo] = []
        var inbox: [String: [SentTab]] = [:]
    }

    private var state = State()
    private let file: URL?
    private let lock = NSLock()
    private let now: () -> Double

    init(file: URL?, now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.file = file
        self.now = now
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        }
    }

    /// The agent's copy, kept next to its other files.
    static let shared: DeviceBook = {
        // PANES_STATE_DIR keeps a test build's devices apart from the real ones.
        let dir = ProcessInfo.processInfo.environment["PANES_STATE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Panes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DeviceBook(file: dir.appendingPathComponent("devices.json"))
    }()

    /// A device checking in: remember its tabs, and hand it (and forget) what
    /// was sent to it.
    func report(_ device: DeviceInfo) -> [SentTab] {
        lock.lock(); defer { lock.unlock() }
        guard let id = Self.clean(device.id) else { return [] }
        var d = device
        d.id = id
        d.name = String(device.name.prefix(60))
        d.kind = device.kind == "phone" ? "phone" : "browser"
        d.tabs = Array(device.tabs.prefix(Self.maxTabs))
        d.seen = now()
        state.devices.removeAll { $0.id == id }
        state.devices.append(d)
        prune()
        let waiting = state.inbox.removeValue(forKey: id) ?? []
        save()
        return waiting
    }

    /// Every device but the asker, most recently seen first.
    func list(except id: String? = nil) -> [DeviceInfo] {
        lock.lock(); defer { lock.unlock() }
        prune()
        return state.devices.filter { $0.id != id }.sorted { ($0.seen ?? 0) > ($1.seen ?? 0) }
    }

    /// Leaves `tab` for device `to` to pick up next time it checks in.
    /// False if no such device has been seen.
    @discardableResult
    func send(_ tab: TabRef, to: String, from: String, id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let to = Self.clean(to), state.devices.contains(where: { $0.id == to }) else { return false }
        var box = state.inbox[to] ?? []
        guard !box.contains(where: { $0.id == id }) else { return true }
        box.append(SentTab(id: String(id.prefix(64)), from: String(from.prefix(60)), tab: tab, at: now()))
        state.inbox[to] = Array(box.suffix(Self.maxInbox))
        save()
        return true
    }

    /// Takes a device off the list (it signed out, or someone tidied up).
    func forget(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        state.devices.removeAll { $0.id == id }
        state.inbox[id] = nil
        save()
    }

    private func prune() {
        let t = now()
        state.devices.removeAll { t - ($0.seen ?? 0) > Self.deviceTTL }
        if state.devices.count > Self.maxDevices {
            state.devices.sort { ($0.seen ?? 0) > ($1.seen ?? 0) }
            state.devices = Array(state.devices.prefix(Self.maxDevices))
        }
        let known = Set(state.devices.map(\.id))
        state.inbox = state.inbox.filter { known.contains($0.key) }
            .mapValues { $0.filter { t - $0.at <= Self.sentTTL } }
            .filter { !$0.value.isEmpty }
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: file, options: [.atomic])
        chmod(file.path, 0o600)
    }

    /// Device ids are made up by the client; keep them to a safe shape.
    static func clean(_ raw: String) -> String? {
        let ok = raw.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
        return ok && !raw.isEmpty && raw.count <= 64 ? raw : nil
    }
}
