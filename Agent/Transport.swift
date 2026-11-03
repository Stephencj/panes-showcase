import Foundation
import Network

/// How a Session's bytes come and go. TCP for the phone app, WebSocket for
/// browsers; both carry the same Wire frames.
protocol Transport: AnyObject {
    func start(queue: DispatchQueue, onBytes: @escaping (Data) -> Void, onClose: @escaping () -> Void)
    func send(_ bytes: Data, done: @escaping () -> Void)
    func close()
}

final class TCPTransport: Transport {
    private let conn: NWConnection
    init(_ conn: NWConnection) { self.conn = conn }

    func start(queue: DispatchQueue, onBytes: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        conn.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: onClose()
            default: break
            }
        }
        conn.start(queue: queue)
        receive(onBytes, onClose)
    }

    private func receive(_ onBytes: @escaping (Data) -> Void, _ onClose: @escaping () -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            if let data, !data.isEmpty { onBytes(data) }
            if done || error != nil { onClose() } else { self?.receive(onBytes, onClose) }
        }
    }

    func send(_ bytes: Data, done: @escaping () -> Void) {
        conn.send(content: bytes, completion: .contentProcessed { _ in done() })
    }

    func close() { conn.cancel() }
}

/// A connection that has already been upgraded to WebSocket by WebServer.
/// Each binary message is one Wire frame in, and each send is one out.
final class WebSocketTransport: Transport {
    private let conn: NWConnection
    private var reader = WebSocket.Reader()
    private var leftover: Data
    private var closed = false

    init(_ conn: NWConnection, leftover: Data) {
        self.conn = conn
        self.leftover = leftover
    }

    /// The connection is already running on `queue` (WebServer started it there).
    func start(queue: DispatchQueue, onBytes: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        conn.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: onClose()
            default: break
            }
        }
        let first = leftover
        leftover = Data()
        if !first.isEmpty, !handle(first, onBytes, onClose) { return }
        receive(onBytes, onClose)
    }

    private func receive(_ onBytes: @escaping (Data) -> Void, _ onClose: @escaping () -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty, !self.handle(data, onBytes, onClose) { return }
            if done || error != nil { onClose() } else { self.receive(onBytes, onClose) }
        }
    }

    /// False once the connection is finished.
    private func handle(_ data: Data, _ onBytes: (Data) -> Void, _ onClose: () -> Void) -> Bool {
        do {
            for (opcode, payload) in try reader.push(data) {
                switch opcode {
                case .binary: onBytes(payload)
                case .ping: conn.send(content: WebSocket.frame(.pong, payload), completion: .idempotent)
                case .close:
                    close()
                    onClose()
                    return false
                default: break   // text and pongs aren't used
                }
            }
            return true
        } catch {
            print("bad websocket: \(error)")
            close()
            onClose()
            return false
        }
    }

    func send(_ bytes: Data, done: @escaping () -> Void) {
        conn.send(content: WebSocket.frame(.binary, bytes), completion: .contentProcessed { _ in done() })
    }

    func close() {
        guard !closed else { return }
        closed = true
        conn.send(content: WebSocket.frame(.close, Data([0x03, 0xE8])), completion: .contentProcessed { [conn] _ in
            conn.cancel()
        })
    }
}
