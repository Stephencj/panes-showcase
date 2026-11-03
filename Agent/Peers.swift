import Foundation

/// Who may connect: this Mac itself, or a device on the tailnet that belongs to
/// the same Tailscale user as this Mac. Tailscale has already proved who the
/// device is, so there is no password to manage. Anything else, including
/// machines on the home Wi-Fi, is turned away.
final class Peers {
    private let tailscale: String
    private var cache: [String: (allowed: Bool, at: Date)] = [:]
    private let lock = NSLock()

    init() {
        let candidates = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                          "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        tailscale = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "tailscale"
    }

    /// Strips an IPv4-mapped IPv6 prefix and an interface suffix.
    static func clean(_ ip: String) -> String {
        var s = ip
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        if s.hasPrefix("::ffff:") { s = String(s.dropFirst(7)) }
        return s
    }

    static func isLoopback(_ ip: String) -> Bool {
        let s = clean(ip)
        return s == "::1" || s.hasPrefix("127.")
    }

    /// Tailscale hands out 100.64.0.0/10 and fd7a:115c:a1e0::/48.
    static func isTailnet(_ ip: String) -> Bool {
        let s = clean(ip)
        if s.lowercased().hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = s.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    func allowed(_ ip: String) -> Bool {
        if Self.isLoopback(ip) { return true }
        guard Self.isTailnet(ip) else { return false }
        let key = Self.clean(ip)
        lock.lock()
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < 600 { lock.unlock(); return hit.allowed }
        lock.unlock()
        let me = ownerLogin()
        let them = login(of: key)
        let ok = me != nil && me == them
        lock.lock(); cache[key] = (ok, Date()); lock.unlock()
        if !ok { print("refused \(key): owner \(them ?? "unknown") is not \(me ?? "unknown")") }
        return ok
    }

    /// This machine's owner (Tailscale login), tailnet DNS suffix and own DNS name.
    struct Identity { var owner: String?; var suffix: String?; var dnsName: String? }
    private var identityCache: Identity?

    func identity() -> Identity {
        lock.lock(); let known = identityCache; lock.unlock()
        if let known, known.owner != nil { return known }
        var id = Identity()
        if let json = run([tailscale, "status", "--json"]) {
            let me = json["Self"] as? [String: Any]
            if let uid = me?["UserID"] as? NSNumber,
               let users = json["User"] as? [String: Any],
               let user = users[uid.stringValue] as? [String: Any] {
                id.owner = user["LoginName"] as? String
            }
            id.suffix = json["MagicDNSSuffix"] as? String
            id.dnsName = (me?["DNSName"] as? String).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        }
        lock.lock(); identityCache = id; lock.unlock()
        return id
    }

    func ownerLogin() -> String? { identity().owner }

    /// Where this machine's Panes Web is reached (Tailscale HTTPS on 7443).
    func webAddress() -> String? { identity().dnsName.map { "https://\($0):\(WebHTTP.publicPort)" } }

    // MARK: Panes Web access (docs/WEB.md)

    /// Tailscale's proxy names the user; with no proxy, only a browser on this Mac.
    func webRequestAllowed(login: String?, host: String?) -> Bool {
        if let login { return login == ownerLogin() }
        return Self.isLocalHost(host)
    }

    /// Only Panes Web pages (on the tailnet's HTTPS names, or local) may open
    /// WebSockets, so other sites open in the same browser can't drive this Mac.
    func webOriginAllowed(_ origin: String?) -> Bool {
        guard let origin, let url = URL(string: origin), let host = url.host else { return false }
        if url.scheme == "http", url.port == Int(WebHTTP.localPort), host == "127.0.0.1" || host == "localhost" {
            return true
        }
        guard url.scheme == "https", url.port == Int(WebHTTP.publicPort), let suffix = identity().suffix else { return false }
        return host.hasSuffix("." + suffix)
    }

    static func isLocalHost(_ host: String?) -> Bool {
        host == "127.0.0.1:\(WebHTTP.localPort)" || host == "localhost:\(WebHTTP.localPort)"
    }

    private func login(of ip: String) -> String? {
        guard let json = run([tailscale, "whois", "--json", ip]),
              let profile = json["UserProfile"] as? [String: Any] else { return nil }
        return profile["LoginName"] as? String
    }

    private func run(_ argv: [String]) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
