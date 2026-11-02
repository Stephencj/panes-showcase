import AppKit
import Network

/// The Panes agent: a menu-bar-less background app that streams this Mac's
/// windows to the Panes app on the phone. Run by launchd at login.
@main
enum Agent {
    static let peers = Peers()
    static var sessions: [ObjectIdentifier: Session] = [:]
    static let lock = NSLock()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Ask once; macOS remembers the answer for this signed app.
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                              reason: "Streaming windows to Panes")
        do { try listen() } catch {
            print("can't listen on \(Wire.port): \(error)")
            exit(1)
        }
        if let problem = permissionProblem() { print(problem) }
        app.run()
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
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Wire.port)!)
        listener.newConnectionHandler = { conn in
            DispatchQueue.global().async {
                guard case let .hostPort(host, _) = conn.endpoint, peers.allowed("\(host)") else {
                    conn.cancel()
                    return
                }
                let session = Session(conn) { s in
                    lock.lock(); sessions[ObjectIdentifier(s)] = nil; lock.unlock()
                }
                lock.lock(); sessions[ObjectIdentifier(session)] = session; lock.unlock()
                session.start()
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("listener failed: \(error)")
                exit(1)   // launchd starts us again
            }
        }
        listener.start(queue: .main)
        print("Panes agent listening on \(Wire.port)")
    }
}
