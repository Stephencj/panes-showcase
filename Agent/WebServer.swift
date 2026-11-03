import Foundation
import Network

/// Panes Web (docs/WEB.md): serves the browser client and carries Sessions
/// over WebSocket. Listens on this Mac only; Tailscale publishes it on the
/// tailnet over HTTPS (`tailscale serve --https=7443 http://127.0.0.1:7891`),
/// which browsers need for WebCodecs, and tells us who's connecting.
enum WebServer {
    static func listen() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: WebHTTP.localPort)!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { conn in
            let queue = DispatchQueue(label: "panes.web")
            conn.start(queue: queue)
            readRequest(conn, buffer: Data(), queue: queue)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { print("web listener failed: \(error)") }
        }
        listener.start(queue: .main)
        print("Panes Web on 127.0.0.1:\(WebHTTP.localPort)")
    }

    /// Reads up to the end of the request headers (capped, so nothing can make us buffer forever).
    private static func readRequest(_ conn: NWConnection, buffer: Data, queue: DispatchQueue) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let rest = buffer.subdata(in: end.upperBound..<buffer.endIndex)
                route(WebHTTP.Request(head), leftover: rest, conn: conn, queue: queue)
            } else if done || error != nil || buffer.count > 16 * 1024 {
                conn.cancel()
            } else {
                readRequest(conn, buffer: buffer, queue: queue)
            }
        }
    }

    private static func route(_ req: WebHTTP.Request, leftover: Data, conn: NWConnection, queue: DispatchQueue) {
        let peers = Agent.peers
        guard peers.webRequestAllowed(login: req.headers["tailscale-user-login"], host: req.headers["host"]) else {
            return respond(conn, 403, "Forbidden")
        }
        let path = req.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        if path == "/ws" {
            guard req.isWebSocketUpgrade, peers.webOriginAllowed(req.headers["origin"]) else {
                return respond(conn, 403, "Forbidden")
            }
            let accept = WebSocket.acceptKey(req.headers["sec-websocket-key"]!)
            let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
            conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in
                Agent.startSession(WebSocketTransport(conn, leftover: leftover), queue: queue)
            })
            return
        }
        guard req.method == "GET" || req.method == "HEAD" else { return respond(conn, 405, "Method Not Allowed") }
        // machines.json is shared with the phone app, so it's bundled once at the top level.
        let shared = path == "/machines.json" ? Bundle.main.url(forResource: "machines", withExtension: "json") : nil
        guard let file = WebHTTP.staticFile(path) ?? shared else { return respond(conn, 404, "Not Found") }
        var body = (try? Data(contentsOf: file)) ?? Data()
        // A browser on this Mac itself (no Tailscale identity) reaches this Mac
        // at localhost, which also works with Tailscale HTTPS not set up.
        if path == "/machines.json", req.headers["tailscale-user-login"] == nil,
           let me = peers.webAddress(), let text = String(data: body, encoding: .utf8) {
            body = Data(text.replacingOccurrences(of: "\"\(me)\"", with: "\"http://127.0.0.1:\(WebHTTP.localPort)\"").utf8)
        }
        respond(conn, 200, req.method == "HEAD" ? Data() : body, type: WebHTTP.contentType(file.pathExtension),
                length: body.count)
    }

    private static func respond(_ conn: NWConnection, _ code: Int, _ text: String) {
        respond(conn, code, Data(text.utf8), type: "text/plain; charset=utf-8", length: text.utf8.count)
    }

    private static func respond(_ conn: NWConnection, _ code: Int, _ body: Data, type: String, length: Int) {
        let reason = [200: "OK", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"][code] ?? "Error"
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\n"
            + "Cache-Control: no-cache\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }
}
