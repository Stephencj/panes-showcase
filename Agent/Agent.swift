import AppKit
import Network

/// The Panes agent: a menu-bar-less background app that streams this Mac's
/// windows to the Panes app on the phone. Run by launchd at login.
@main
enum Agent {
    static let peers = Peers()
    /// PANES_PORT moves it, so a test build can run beside the installed agent.
    static let port: UInt16 = ProcessInfo.processInfo.environment["PANES_PORT"].flatMap(UInt16.init) ?? Wire.port
    static var sessions: [ObjectIdentifier: Session] = [:]
    static let lock = NSLock()

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)   // launchd log: write each line as it happens
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Ask once; macOS remembers the answer for this signed app.
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                              reason: "Streaming windows to Panes")
        do { try listen() } catch {
            print("can't listen on \(Agent.port): \(error)")
            exit(1)
        }
        do {
            try WebServer.listen()
        } catch {
            print("Panes Web unavailable: \(error)")   // the phone app still works
        }
        if let problem = permissionProblem() { print(problem) }
        app.run()
    }

    /// Keeps a Session alive until it ends, whichever way it arrived.
    static func startSession(_ transport: Transport, queue: DispatchQueue) {
        let session = Session(transport, queue: queue) { s in
            lock.lock(); sessions[ObjectIdentifier(s)] = nil; lock.unlock()
        }
        lock.lock(); sessions[ObjectIdentifier(session)] = session; lock.unlock()
        session.start()
    }

    static func permissionProblem() -> String? {
        var missing: [String] = []
        if !CGPreflightScreenCaptureAccess() { missing.append("Screen Recording") }
        if !AXIsProcessTrusted() { missing.append("Accessibility") }
        guard !missing.isEmpty else { return nil }
        return "On the Mac, allow Panes Agent in System Settings → Privacy & Security → "
            + missing.joined(separator: " and ") + "."
    }

    private static func listen() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Agent.port)!)
        listener.newConnectionHandler = { conn in
            DispatchQueue.global().async {
                guard case let .hostPort(host, _) = conn.endpoint, peers.allowed("\(host)") else {
                    conn.cancel()
                    return
                }
                startSession(TCPTransport(conn), queue: DispatchQueue(label: "panes.session"))
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("listener failed: \(error)")
                exit(1)   // launchd starts us again
            }
        }
        listener.start(queue: .main)
        print("Panes agent listening on \(Agent.port)")
    }
}
