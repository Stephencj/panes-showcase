import Foundation

/// Who may connect: this Mac itself, or a device on the tailnet that belongs to
/// the same Tailscale user as this Mac. Tailscale has already proved who the
/// device is, so there is no password to manage. Anything else, including
/// machines on the home Wi-Fi, is turned away.
final class Peers {
    private let tailscale: String
    private var cache: [String: (allowed: Bool, at: Date)] = [:]
    private var owner: String?
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

    private func ownerLogin() -> String? {
        lock.lock(); let known = owner; lock.unlock()
        if let known { return known }
        guard let json = run([tailscale, "status", "--json"]),
              let me = json["Self"] as? [String: Any],
              let uid = me["UserID"] as? NSNumber,
              let users = json["User"] as? [String: Any],
              let user = users[uid.stringValue] as? [String: Any],
              let login = user["LoginName"] as? String else { return nil }
        lock.lock(); owner = login; lock.unlock()
        return login
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
