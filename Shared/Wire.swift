import Foundation

/// The wire format between the phone and a machine's agent. One TCP connection
/// per tab. Every message is a frame:
///
///     [type: u8][length: u32 big-endian][payload]
///
/// - control: a JSON `Control` message, either direction.
/// - videoFormat: H.264 parameter sets, sent before the first frame and again
///   whenever the stream size changes. `[count: u8]` then `[len: u16][bytes]` each.
/// - videoFrame: `[flags: u8][pts: u64 microseconds][AVCC data]`, where flags
///   bit 0 marks a keyframe and AVCC data is 4-byte-length-prefixed NAL units.
/// - terminal: raw terminal bytes, either direction (keys in, screen output out).
/// - audioFormat: `[sampleRate: f64][channels: u32][framesPerPacket: u32][magic cookie]`
///   for the AAC stream that follows.
/// - audioFrame: `[pts: u64 microseconds][one AAC packet]`.
/// - snapshot: a JPEG of the window, sent in answer to a `snapshot` request.
enum FrameType: UInt8 {
    case control = 1
    case videoFormat = 2
    case videoFrame = 3
    case terminal = 4
    case audioFormat = 5
    case audioFrame = 6
    /// A JPEG of a window tab's window, for the tab grid's preview.
    case snapshot = 7
}

/// The AAC stream an agent sends for a window's app.
struct AudioFormat: Equatable {
    var sampleRate: Double
    var channels: UInt32
    var framesPerPacket: UInt32
    var cookie: Data
}

struct Frame: Equatable {
    var type: FrameType
    var payload: Data
}

enum Wire {
    static let port: UInt16 = 7890
    static let version = 1
    /// Anything bigger is a corrupt stream, not a frame.
    static let maxPayload = 32 * 1024 * 1024

    static func encode(_ type: FrameType, _ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 5)
        out.append(type.rawValue)
        out.append(contentsOf: UInt32(payload.count).bigEndianBytes)
        out.append(payload)
        return out
    }

    static func encode(_ control: Control) -> Data {
        encode(.control, (try? JSONEncoder().encode(control)) ?? Data())
    }

    static func videoFormat(_ parameterSets: [Data]) -> Data {
        var p = Data([UInt8(parameterSets.count)])
        for set in parameterSets {
            p.append(contentsOf: UInt16(set.count).bigEndianBytes)
            p.append(set)
        }
        return encode(.videoFormat, p)
    }

    static func parseVideoFormat(_ p: Data) -> [Data]? {
        let b = [UInt8](p)
        guard let count = b.first else { return nil }
        var sets: [Data] = [], i = 1
        for _ in 0..<count {
            guard i + 2 <= b.count else { return nil }
            let n = Int(b[i]) << 8 | Int(b[i + 1])
            i += 2
            guard i + n <= b.count else { return nil }
            sets.append(Data(b[i..<i + n]))
            i += n
        }
        return sets
    }

    static func videoFrame(keyframe: Bool, ptsMicros: UInt64, avcc: Data) -> Data {
        var p = Data([keyframe ? 1 : 0])
        p.append(contentsOf: ptsMicros.bigEndianBytes)
        p.append(avcc)
        return encode(.videoFrame, p)
    }

    static func audioFormat(_ f: AudioFormat) -> Data {
        var p = Data(f.sampleRate.bitPattern.bigEndianBytes)
        p.append(contentsOf: f.channels.bigEndianBytes)
        p.append(contentsOf: f.framesPerPacket.bigEndianBytes)
        p.append(f.cookie)
        return encode(.audioFormat, p)
    }

    static func parseAudioFormat(_ p: Data) -> AudioFormat? {
        guard p.count >= 16 else { return nil }
        let b = [UInt8](p)
        func u64(_ at: Int) -> UInt64 { b[at..<at + 8].reduce(0) { $0 << 8 | UInt64($1) } }
        func u32(_ at: Int) -> UInt32 { b[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        return AudioFormat(sampleRate: Double(bitPattern: u64(0)), channels: u32(8), framesPerPacket: u32(12),
                           cookie: Data(b[16...]))
    }

    static func audioFrame(ptsMicros: UInt64, packet: Data) -> Data {
        var p = Data(ptsMicros.bigEndianBytes)
        p.append(packet)
        return encode(.audioFrame, p)
    }

    static func parseAudioFrame(_ p: Data) -> (ptsMicros: UInt64, packet: Data)? {
        guard p.count > 8 else { return nil }
        let pts = [UInt8](p.prefix(8)).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (pts, p.subdata(in: p.startIndex + 8..<p.endIndex))
    }

    static func parseVideoFrame(_ p: Data) -> (keyframe: Bool, ptsMicros: UInt64, avcc: Data)? {
        guard p.count >= 9 else { return nil }
        let b = [UInt8](p.prefix(9))
        var pts: UInt64 = 0
        for byte in b[1..<9] { pts = pts << 8 | UInt64(byte) }
        return (b[0] & 1 == 1, pts, p.subdata(in: p.startIndex + 9..<p.endIndex))
    }
}

/// Collects bytes off a socket and hands back whole frames.
struct FrameReader {
    private var buffer = Data()

    enum Failure: Error { case unknownType(UInt8), tooLarge(Int) }

    mutating func push(_ bytes: Data) throws -> [Frame] {
        buffer.append(bytes)
        var frames: [Frame] = []
        while buffer.count >= 5 {
            let b = buffer.startIndex
            let typeByte = buffer[b]
            guard let type = FrameType(rawValue: typeByte) else { throw Failure.unknownType(typeByte) }
            let len = Int(buffer[b + 1]) << 24 | Int(buffer[b + 2]) << 16 | Int(buffer[b + 3]) << 8 | Int(buffer[b + 4])
            guard len <= Wire.maxPayload else { throw Failure.tooLarge(len) }
            guard buffer.count >= 5 + len else { break }
            frames.append(Frame(type: type, payload: buffer.subdata(in: b + 5..<b + 5 + len)))
            buffer = buffer.subdata(in: b + 5 + len..<buffer.endIndex)
        }
        return frames
    }
}

/// Every JSON message. `op` says which fields matter:
///
/// phone → agent: hello, list, open(windowID, viewport, zoom), input(event),
///                keyframe, pause, resume, terminal(name, cols, rows), resize(cols, rows),
///                apps, launch(app, name), snapshot(width),
///                device(device), devices, send(to, tab, name), forget(device)
/// agent → phone: hello(machine, features), windows(windows), opened(windowID,
///                title, app, width, height), resized(width, height), closed,
///                terminalOpened(name), exited, apps(apps), launched(app, url),
///                inbox(sent), devices(devices), error
struct Control: Codable, Equatable {
    var op: String
    var version: Int? = nil
    var machine: String? = nil
    var windows: [WindowInfo]? = nil
    var windowID: UInt32? = nil
    var viewport: Size? = nil
    /// Window tabs: also stream the app's sound.
    var audio: Bool? = nil
    /// Window points per phone point when fitting (bigger = more fits, smaller text).
    var zoom: Double? = nil
    var title: String? = nil
    var app: String? = nil
    var width: Double? = nil
    var height: Double? = nil
    var event: InputEvent? = nil
    var error: String? = nil
    /// What a machine's agent can do: "windows", "terminal", "apps".
    var features: [String]? = nil
    /// Terminal tabs: the tmux session to attach (created if missing), and the size in cells.
    var name: String? = nil
    var cols: Int? = nil
    var rows: Int? = nil
    /// Linux app tabs: the apps a box offers, and where a launched one is served.
    var apps: [AppInfo]? = nil
    var url: String? = nil
    /// The machine's Panes Web address (https://<name>.<tailnet>.ts.net:7443),
    /// which a relative `url` resolves against.
    var web: String? = nil
    /// Tabs on other devices (docs/UI.md): this device and its open tabs, every
    /// device the agent has heard from, a tab to send and who it's for, and
    /// tabs sent to this device.
    var device: DeviceInfo? = nil
    var devices: [DeviceInfo]? = nil
    var to: String? = nil
    var tab: TabRef? = nil
    var sent: [SentTab]? = nil
}

/// Enough to open the same tab somewhere else: the same window, the same tmux
/// session, or the same Linux app session.
struct TabRef: Codable, Equatable, Hashable {
    /// The machine's name, as in machines.json.
    var machine: String
    /// window, terminal or app
    var kind: String
    /// What the tab is called: the app's name ("Xcode", "Terminal").
    var app: String
    var title: String? = nil
    var windowID: UInt32? = nil
    /// Terminal and app tabs: the session to attach to.
    var session: String? = nil
    /// App tabs: the app's id on the Linux box.
    var appID: String? = nil
}

/// A phone or a browser running Panes, and the tabs it has open.
struct DeviceInfo: Codable, Equatable {
    /// Made up by the device once and kept.
    var id: String
    var name: String
    /// phone or browser
    var kind: String
    var tabs: [TabRef]
    /// When the agent last heard from it (seconds since 1970); the agent fills it in.
    var seen: Double? = nil

    init(id: String, name: String, kind: String, tabs: [TabRef], seen: Double? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.tabs = tabs
        self.seen = seen
    }

    /// `devices` and `forget` only need the id (docs/UI.md), so the rest may be missing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "browser"
        tabs = try c.decodeIfPresent([TabRef].self, forKey: .tabs) ?? []
        seen = try c.decodeIfPresent(Double.self, forKey: .seen)
    }
}

/// A tab one device sent another, waiting until that device next checks in.
struct SentTab: Codable, Equatable {
    var id: String
    /// The sending device's name.
    var from: String
    var tab: TabRef
    var at: Double
}

/// An app a Linux box can start in its own Xpra session (from its .desktop file).
struct AppInfo: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var name: String
}

extension Wire {
    /// tmux session names from the phone are limited to letters, digits, - and _.
    static func sessionName(_ raw: String?) -> String {
        let cleaned = String((raw ?? "").unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
        }.prefix(40))
        return cleaned.isEmpty ? "panes" : cleaned
    }

    /// Sessions the phone creates are named panes-…; only those may be ended
    /// from the phone, so it can never kill a tmux session the user made.
    static func isPanesSession(_ name: String) -> Bool { name.hasPrefix("panes-") && name.count > 6 }
}

struct Size: Codable, Equatable {
    var width: Double
    var height: Double
}

struct WindowInfo: Codable, Equatable, Identifiable, Hashable {
    var id: UInt32
    var app: String
    var bundleID: String
    var title: String
    var width: Double
    var height: Double
}

/// Pointer positions are 0...1 across the window, so the phone never needs
/// to know the window's real size or where it sits on the Mac's screen.
struct InputEvent: Codable, Equatable {
    /// click, rightClick, down, drag, up, move, scroll, text, key
    var kind: String
    var x: Double? = nil
    var y: Double? = nil
    var clicks: Int? = nil
    var dx: Double? = nil
    var dy: Double? = nil
    var text: String? = nil
    /// A name from `Keys.codes` ("return", "a", "left"...).
    var key: String? = nil
    /// Any of cmd, ctrl, opt, shift.
    var mods: [String]? = nil
}

extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.bigEndian) { Array($0) }
    }
}
