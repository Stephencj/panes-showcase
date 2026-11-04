import AppKit

/// Every app installed on this Mac, so a tab can start one that isn't running
/// (docs/UI.md, "Opening any app").
enum MacApps {
    static let folders: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/Applications", "/Applications/Utilities", "/System/Applications",
                "/System/Applications/Utilities"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            + [home.appendingPathComponent("Applications", isDirectory: true)]
    }()

    /// Apps with a user interface, by name. `id` is the bundle identifier.
    static func installed(in folders: [URL] = folders) -> [AppInfo] {
        var seen = Set<String>()
        var out: [AppInfo] = []
        let me = Bundle.main.bundleIdentifier
        for folder in folders {
            for url in appBundles(in: folder) {
                guard let b = Bundle(url: url), let id = b.bundleIdentifier, id != me, !seen.contains(id) else { continue }
                let info = b.infoDictionary ?? [:]
                // Menu-bar helpers and background agents have no window to show.
                if (info["LSUIElement"] as? Bool) == true || (info["LSUIElement"] as? String) == "1"
                    || (info["LSBackgroundOnly"] as? Bool) == true { continue }
                seen.insert(id)
                let name = FileManager.default.displayName(atPath: url.path)
                out.append(AppInfo(id: id, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// .app bundles in a folder and one level of subfolders (suites like "Microsoft Office").
    private static func appBundles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for item in items {
            if item.pathExtension == "app" {
                out.append(item)
            } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let inner = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                out += inner.filter { $0.pathExtension == "app" }
            }
        }
        return out
    }

    enum Failure: Error, CustomStringConvertible {
        case notInstalled, noWindow(String)
        var description: String {
            switch self {
            case .notInstalled: "That app isn't installed on this Mac."
            case .noWindow(let name): "\(name) opened but didn't show a window."
            }
        }
    }

    /// Starts the app (or brings it forward, which also asks it to reopen a
    /// window if it has none) and returns the window to stream: the one it
    /// focuses, or its first.
    static func open(_ bundleID: String, timeout: TimeInterval = 25) async throws -> UInt32 {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { throw Failure.notInstalled }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        let name = app.localizedName ?? bundleID
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let windows = (try? await Windows.list())?.filter { $0.bundleID == bundleID } ?? []
            if let focused = Windows.focusedWindow(pid: app.processIdentifier), windows.contains(where: { $0.id == focused }) {
                return focused
            }
            if let first = windows.first { return first.id }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw Failure.noWindow(name)
    }
}
