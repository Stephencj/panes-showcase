import Network
import XCTest

/// Drives the phone UI (docs/UI.md) against side agents started by
/// tools/ios-e2e/run.sh: a Mac agent standing in for "Mac mini" with two
/// test windows open, and the Linux agent standing in for "linux-box".
/// The run script passes where they are as TEST_RUNNER_PANES_* variables.
final class FlowUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private let browserID = "uitest-browser-" + UUID().uuidString.prefix(6).lowercased()
    private let browserName = "Chrome on Linux"

    override func setUp() { continueAfterFailure = false }

    /// On any failure, keep what the screen looked like and what was on it.
    override func record(_ issue: XCTIssue) {
        if let dir = env["PANES_E2E_SHOTS"] {
            let app = XCUIApplication()
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir + "/failure.png"))
            try? app.debugDescription.write(toFile: dir + "/failure-tree.txt", atomically: true, encoding: .utf8)
        }
        super.record(issue)
    }

    override func tearDown() {
        // Leave no made-up devices behind in the agents' books.
        for agent in agents { _ = try? agent.call(Control(op: "forget", device: device(browserID)), until: nil) }
    }

    private var agents: [AgentClient] {
        (env["PANES_E2E_AGENTS"] ?? "").split(separator: ",").map { AgentClient(String($0)) }
    }

    private func device(_ id: String, tabs: [TabRef] = []) -> DeviceInfo {
        DeviceInfo(id: id, name: browserName, kind: "browser", tabs: tabs)
    }

    func testFlowBetweenTabsMachinesAndDevices() throws {
        // A browser elsewhere with a Mac terminal open, known to both machines.
        let shared = TabRef(machine: "Mac mini", kind: "terminal", app: "Terminal", title: "Terminal", session: "panes-e2eshare")
        for agent in agents { _ = try agent.call(Control(op: "device", device: device(browserID, tabs: [shared])), until: "inbox") }

        let app = XCUIApplication()
        app.launchEnvironment = [
            "PANES_MACHINES": try XCTUnwrap(env["PANES_MACHINES"]),
            "PANES_OPEN": "panes-ui-a|panes-ui-b",
            "PANES_DEVICE_NAME": "Test iPhone",
            "PANES_NOTICE_SECONDS": "40",
            "PANES_UITEST": "1",
        ]
        // The test windows play a tone; streaming it keeps the app too busy for
        // XCUITest to read the screen promptly (sound has its own probe test).
        app.launchArguments = ["-streamAudio", "NO", "-recents", ""]
        app.launch()

        // Two window tabs, the second showing.
        let pill = app.buttons["pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 20))
        try wait(pill, value: "Tab 2 of 2", timeout: 20)
        XCTAssertTrue(pill.label.contains("on Mac mini"), pill.label)
        shot(app, "1-tab")

        // Swipes and arrows move between tabs.
        swipe(pill, by: 140)
        try wait(pill, value: "Tab 1 of 2")
        swipe(pill, by: -140)
        try wait(pill, value: "Tab 2 of 2")
        app.buttons["Previous tab"].tap()
        try wait(pill, value: "Tab 1 of 2")
        app.buttons["Next tab"].tap()
        try wait(pill, value: "Tab 2 of 2")
        app.buttons["Previous tab"].tap()
        try wait(pill, value: "Tab 1 of 2")
        // Swiping the pill up shows every tab.
        swipe(pill, by: 0, up: 120)
        XCTAssertTrue(app.staticTexts["2 tabs"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["2 tabs"].waitForNonExistence(timeout: 5))

        // Search every machine: a terminal on linux-box.
        app.buttons["Open an app"].tap()
        let field = app.textFields["search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["MAC MINI"].waitForExistence(timeout: 10))
        // A Mac lists every installed app, so with nothing typed it shows a few and an "All N apps" row.
        XCTAssertTrue(app.buttons["all-apps-Mac mini"].waitForExistence(timeout: 10))
        // (linux-box's section is further down; the search below finds it.)
        field.typeText("term fedora")
        let terminal = app.buttons["result-linux-box-terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["result-Mac mini-terminal"].exists, "the Mac's terminal doesn't match \"fedora\"")
        shot(app, "2-search")
        terminal.tap()
        try wait(pill, value: "Tab 3 of 3")
        XCTAssertTrue(app.buttons["pill"].label.hasPrefix("Terminal on linux-box"), app.buttons["pill"].label)

        // Recent remembers it.
        app.buttons["Open an app"].tap()
        XCTAssertTrue(app.staticTexts["RECENT"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.textFields["search"].waitForNonExistence(timeout: 5))

        // The tab grid: three cards, and the other browser's tab.
        pill.tap()
        XCTAssertTrue(app.staticTexts["3 tabs"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "card").count, 3)
        XCTAssertTrue(app.staticTexts[browserName].waitForExistence(timeout: 25), "other devices didn't show")
        shot(app, "3-grid")
        let openHere = app.buttons["Open Terminal from \(browserName)"]
        XCTAssertTrue(openHere.waitForExistence(timeout: 5))
        openHere.tap()
        XCTAssertTrue(app.staticTexts["4 tabs"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Switch to Terminal from \(browserName)"].waitForExistence(timeout: 5),
                      "an open tab should say Switch, not Open")

        // Send the first window tab to the browser.
        app.buttons.matching(identifier: "send").element(boundBy: 0).tap()
        let target = app.buttons[browserName]
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        shot(app, "4-send")
        target.tap()
        let notice = app.buttons["notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertTrue(notice.label.hasPrefix("Sent."), notice.label)
        // It reached the browser's inbox (on at least one machine).
        var got: [SentTab] = []
        for agent in agents {
            got += try agent.call(Control(op: "device", device: device(browserID, tabs: [shared])), until: "inbox")?.sent ?? []
        }
        XCTAssertTrue(got.contains { $0.from == "Test iPhone" && $0.tab.kind == "window" }, "\(got)")

        // A tab sent from the browser arrives without taking over the screen.
        notice.tap()   // a notice sits over the grid's header until tapped or timed out
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["4 tabs"].waitForNonExistence(timeout: 5))
        let before = app.buttons["pill"].label
        let phoneID = try XCTUnwrap(agents.lazy.compactMap { try? $0.call(Control(op: "devices"), until: "devices") }
            .compactMap { $0.devices?.first { $0.name == "Test iPhone" }?.id }.first)
        let incoming = TabRef(machine: "linux-box", kind: "terminal", app: "Terminal", title: "Terminal", session: "panes-e2earrive")
        for agent in agents {
            _ = try agent.call(Control(op: "send", name: browserName, to: phoneID, tab: incoming), until: nil)
        }
        let arrived = app.buttons["notice"]
        XCTAssertTrue(arrived.waitForExistence(timeout: 30), "nothing arrived")
        XCTAssertTrue(arrived.label.contains("arrived from \(browserName)"), arrived.label)
        XCTAssertEqual(app.buttons["pill"].label, before.replacingOccurrences(of: "of 4", with: "of 5"))
        shot(app, "5-arrived")
        arrived.tap()
        try wait(pill, value: "Tab 5 of 5")

        // Only one copy arrived, even though it was sent through both machines.
        pill.tap()
        XCTAssertTrue(app.staticTexts["5 tabs"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["6 tabs"].waitForExistence(timeout: 20))

        // Closing from the grid.
        app.buttons.matching(identifier: "close").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["4 tabs"].waitForExistence(timeout: 5))

        // Settings.
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.switches["Fit windows to the phone"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Play the app's sound"].exists)
        XCTAssertEqual(app.textFields["Name"].value as? String, "Test iPhone")
        shot(app, "6-settings")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.switches["Fit windows to the phone"].waitForNonExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()   // and the grid

        // Any installed Mac app, running or not: Chess isn't running; picking it starts it.
        app.buttons["Open an app"].tap()
        app.textFields["search"].typeText("chess")
        let chess = app.buttons["result-Mac mini-acom.apple.Chess"]
        XCTAssertTrue(chess.waitForExistence(timeout: 15))
        chess.tap()
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline, !app.buttons["pill"].label.hasPrefix("Chess on Mac mini") { usleep(500_000) }
        XCTAssertTrue(app.buttons["pill"].label.hasPrefix("Chess on Mac mini"), app.buttons["pill"].label)
        // Live once Chess has a window and it streams: the spinner goes, no error shows.
        XCTAssertTrue(app.staticTexts["Opening Chess on Mac mini…"].waitForNonExistence(timeout: 40), "Chess never opened")
        XCTAssertFalse(app.buttons["Reconnect"].exists)
        sleep(2)
        shot(app, "7-mac-app")
    }

    private func wait(_ e: XCUIElement, value: String, timeout: TimeInterval = 5) throws {
        let end = Date().addingTimeInterval(timeout)
        var seen: [String] = []
        while Date() < end {
            // A fresh query each time: an element's attributes can stay as first read.
            let v = XCUIApplication().buttons[e.identifier.isEmpty ? "pill" : e.identifier].label
            if v.lowercased().contains(value.lowercased()) { return }
            if seen.last != v { seen.append(v) }
            usleep(250_000)
        }
        XCTFail("pill went \(seen), wanted \(value)")
        throw XCTSkip("stopping")
    }

    /// A finger drag across the pill (XCUITest's own swipes are too quick to count as a drag).
    private func swipe(_ e: XCUIElement, by dx: CGFloat, up dy: CGFloat = 0) {
        let start = e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: -dy)))
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = env["PANES_E2E_SHOTS"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }
}

/// A tiny synchronous client for an agent: connect, hello, one message, wait
/// for a reply with the given op (or none).
struct AgentClient {
    let host: String
    let port: UInt16

    init(_ hostPort: String) {
        let p = hostPort.split(separator: ":")
        host = String(p[0])
        port = UInt16(p[1]) ?? Wire.port
    }

    func call(_ msg: Control, until op: String?, timeout: TimeInterval = 8) throws -> Control? {
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let q = DispatchQueue(label: "agent-client")
        let done = DispatchSemaphore(value: 0)
        var reader = FrameReader()
        var result: Control?
        var finished = false
        func finish(_ c: Control?) {
            guard !finished else { return }
            finished = true
            result = c
            done.signal()
        }
        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                for f in (try? reader.push(data ?? Data())) ?? [] where f.type == .control {
                    guard let c = try? JSONDecoder().decode(Control.self, from: f.payload) else { continue }
                    if c.op == "hello" {
                        conn.send(content: Wire.encode(msg), completion: .contentProcessed { _ in
                            if op == nil { q.asyncAfter(deadline: .now() + 0.3) { finish(nil) } }
                        })
                    } else if c.op == op {
                        return finish(c)
                    }
                }
                if complete || error != nil { return finish(nil) }
                receive()
            }
        }
        conn.stateUpdateHandler = { s in
            switch s {
            case .ready:
                conn.send(content: Wire.encode(Control(op: "hello", version: Wire.version)), completion: .idempotent)
                receive()
            case .failed: finish(nil)
            default: break
            }
        }
        conn.start(queue: q)
        _ = done.wait(timeout: .now() + timeout)
        conn.cancel()
        if op != nil && result == nil { throw NSError(domain: "AgentClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "no \(op!) from \(host):\(port)"]) }
        return result
    }
}
