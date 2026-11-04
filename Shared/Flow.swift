import Foundation

/// The rules behind moving between tabs, machines and devices (docs/UI.md),
/// kept apart from the UI so they can be tested on the Mac.
enum Flow {
    /// Things opened lately, newest first, without repeats.
    static let recentLimit = 8

    static func addRecent(_ ref: TabRef, to list: [TabRef]) -> [TabRef] {
        var out = list.filter { recentKey($0) != recentKey(ref) }
        out.insert(ref, at: 0)
        return Array(out.prefix(recentLimit))
    }

    /// A recent entry is "that app on that machine": a window by its title,
    /// a terminal is any new terminal, a Linux app by its id.
    static func recentKey(_ r: TabRef) -> String {
        switch r.kind {
        case "window": "\(r.machine)|window|\(r.app)|\(r.title ?? "")"
        case "terminal": "\(r.machine)|terminal"
        default: "\(r.machine)|app|\(r.appID ?? r.app)"
        }
    }

    /// Two refs are the same tab when they'd attach to the same thing.
    static func sameTab(_ a: TabRef, _ b: TabRef) -> Bool {
        guard a.machine == b.machine, a.kind == b.kind else { return false }
        switch a.kind {
        case "window": return a.windowID != nil && a.windowID == b.windowID
        default: return a.session != nil && a.session == b.session
        }
    }

    /// Device lists from every machine, merged: one entry per id, the most
    /// recently seen copy, newest first, never this device.
    static func merge(_ lists: [[DeviceInfo]], except me: String) -> [DeviceInfo] {
        var best: [String: DeviceInfo] = [:]
        for d in lists.joined() where d.id != me {
            if let have = best[d.id], (have.seen ?? 0) >= (d.seen ?? 0) { continue }
            best[d.id] = d
        }
        return best.values.sorted { ($0.seen ?? 0) > ($1.seen ?? 0) }
    }

    /// Search: every word must appear in one of the fields (any order, any case).
    static func matches(_ query: String, _ fields: [String?]) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let hay = fields.compactMap { $0?.lowercased() }.joined(separator: " ")
        return words.allSatisfy { hay.contains($0) }
    }

    /// `#5B9BFF` → (0.36, 0.61, 1.0); nil for anything else.
    static func rgb(_ hex: String?) -> (Double, Double, Double)? {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}

/// A tab sent from another device can come through every machine it was sent
/// to; this lets the first one in and drops the rest for a while.
struct ArrivalFilter {
    var window: TimeInterval = 600
    private var seen: [String: Date] = [:]

    mutating func admit(_ s: SentTab, now: Date = Date()) -> Bool {
        seen = seen.filter { now.timeIntervalSince($0.value) < window }
        let key = s.from + "|" + Flow.recentKey(s.tab) + "|" + (s.tab.session ?? s.tab.windowID.map(String.init) ?? "")
        guard seen[key] == nil else { return false }
        seen[key] = now
        return true
    }
}
