import Foundation
import Network

/// One connection to a machine's agent. Tries each of the machine's addresses
/// in turn and keeps the first that answers.
final class AgentLink {
    enum Event {
        case ready(host: String)
        case control(Control)
        case format([Data])
        case frame(keyframe: Bool, ptsMicros: UInt64, avcc: Data)
        case terminal(Data)
        case failed(String)
    }

    private let hosts: [String]
    private let queue = DispatchQueue(label: "panes.link")
    private var conn: NWConnection?
    private var reader = FrameReader()
    private var closed = false
    private let onEvent: (Event) -> Void

    /// Events arrive on the main queue.
    init(hosts: [String], onEvent: @escaping (Event) -> Void) {
        self.hosts = hosts
        self.onEvent = onEvent
    }

    func connect() { queue.async { self.attempt(0) } }

    func send(_ msg: Control) {
        let data = Wire.encode(msg)
        queue.async { self.conn?.send(content: data, completion: .idempotent) }
    }

    func sendRaw(_ type: FrameType, _ payload: Data) {
        let data = Wire.encode(type, payload)
        queue.async { self.conn?.send(content: data, completion: .idempotent) }
    }

    func close() {
        queue.async {
            self.closed = true
            self.conn?.cancel()
            self.conn = nil
        }
    }

    private func attempt(_ i: Int) {
        guard !closed else { return }
        guard i < hosts.count else { return emit(.failed("Couldn't reach the machine. Is Tailscale on?")) }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 4
        let c = NWConnection(host: NWEndpoint.Host(hosts[i]), port: NWEndpoint.Port(rawValue: Wire.port)!,
                             using: NWParameters(tls: nil, tcp: tcp))
        var settled = false
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                settled = true
                self.conn = c
                self.reader = FrameReader()
                self.emit(.ready(host: self.hosts[i]))
                self.receive(c)
            case .waiting, .failed:
                if !settled {
                    settled = true
                    c.cancel()
                    self.attempt(i + 1)
                } else if case .failed(let e) = state {
                    self.lost("Connection lost (\(e.localizedDescription))")
                }
            case .cancelled:
                if self.conn === c { self.lost("Disconnected") }
            default:
                break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) {
            if !settled { settled = true; c.cancel(); self.attempt(i + 1) }
        }
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self, self.conn === c else { return }
            if let data, !data.isEmpty {
                do {
                    for f in try self.reader.push(data) { self.dispatch(f) }
                } catch {
                    c.cancel()
                    return
                }
            }
            if done || error != nil { c.cancel() } else { self.receive(c) }
        }
    }

    private func dispatch(_ f: Frame) {
        switch f.type {
        case .control:
            if let msg = try? JSONDecoder().decode(Control.self, from: f.payload) { emit(.control(msg)) }
        case .videoFormat:
            if let sets = Wire.parseVideoFormat(f.payload) { emit(.format(sets)) }
        case .videoFrame:
            if let v = Wire.parseVideoFrame(f.payload) { emit(.frame(keyframe: v.keyframe, ptsMicros: v.ptsMicros, avcc: v.avcc)) }
        case .terminal:
            emit(.terminal(f.payload))
        }
    }

    private func lost(_ why: String) {
        conn = nil
        guard !closed else { return }
        emit(.failed(why))
    }

    private func emit(_ e: Event) { DispatchQueue.main.async { self.onEvent(e) } }
}
