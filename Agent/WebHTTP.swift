import Foundation

/// The parts of Panes Web's HTTP handling that don't touch the network, kept
/// apart so they can be tested on their own.
enum WebHTTP {
    /// PANES_WEB_PORT moves it, so a test build can run beside the installed agent.
    static let localPort: UInt16 = ProcessInfo.processInfo.environment["PANES_WEB_PORT"].flatMap(UInt16.init) ?? 7891
    static let publicPort: UInt16 = 7443

    struct Request {
        var method = "", path = "", headers: [String: String] = [:]

        init(_ head: String) {
            let lines = head.components(separatedBy: "\r\n")
            let first = lines.first?.split(separator: " ") ?? []
            if first.count >= 2 { method = String(first[0]); path = String(first[1]) }
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }

        var isWebSocketUpgrade: Bool {
            headers["upgrade"]?.lowercased() == "websocket" && headers["sec-websocket-key"] != nil
        }
    }

    /// The client's files, bundled in the agent; nothing outside that folder.
    static func staticFile(_ path: String, root: URL? = Bundle.main.resourceURL?.appendingPathComponent("web")) -> URL? {
        guard let root else { return nil }
        let clean = path.removingPercentEncoding ?? path
        let relative = clean == "/" ? "index.html" : String(clean.drop(while: { $0 == "/" }))
        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return file
    }

    static func contentType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "ico": "image/x-icon"
        default: "application/octet-stream"
        }
    }

}
