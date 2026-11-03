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
enum FrameType: UInt8 {
    case control = 1
    case videoFormat = 2
    case videoFrame = 3
    case terminal = 4
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
///                apps, launch(app, name)
/// agent → phone: hello(machine, features), windows(windows), opened(windowID,
///                title, app, width, height), resized(width, height), closed,
///                terminalOpened(name), exited, apps(apps), launched(app, url), error
struct Control: Codable, Equatable {
    var op: String
    var version: Int? = nil
    var machine: String? = nil
    var windows: [WindowInfo]? = nil
    var windowID: UInt32? = nil
    var viewport: Size? = nil
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
