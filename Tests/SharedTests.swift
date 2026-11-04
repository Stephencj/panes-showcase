import AVFoundation
import CoreMedia
import XCTest

final class WireTests: XCTestCase {
    func testControlRoundTripsThroughSplitReads() throws {
        let msg = Control(op: "open", windowID: 42, viewport: Size(width: 393, height: 760))
        let bytes = Wire.encode(msg)
        var reader = FrameReader()
        var frames: [Frame] = []
        for b in bytes { frames += try reader.push(Data([b])) }   // worst case: one byte at a time
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].type, .control)
        XCTAssertEqual(try JSONDecoder().decode(Control.self, from: frames[0].payload), msg)
    }

    func testSeveralFramesInOneRead() throws {
        var bytes = Wire.encode(Control(op: "hello"))
        bytes += Wire.videoFormat([Data([1, 2, 3]), Data([4, 5])])
        bytes += Wire.videoFrame(keyframe: true, ptsMicros: 123_456_789, avcc: Data([9, 9, 9, 9]))
        var reader = FrameReader()
        let frames = try reader.push(bytes)
        XCTAssertEqual(frames.map(\.type), [.control, .videoFormat, .videoFrame])
        XCTAssertEqual(Wire.parseVideoFormat(frames[1].payload), [Data([1, 2, 3]), Data([4, 5])])
        let f = try XCTUnwrap(Wire.parseVideoFrame(frames[2].payload))
        XCTAssertTrue(f.keyframe)
        XCTAssertEqual(f.ptsMicros, 123_456_789)
        XCTAssertEqual(f.avcc, Data([9, 9, 9, 9]))
    }

    func testPartialFrameWaitsForTheRest() throws {
        let bytes = Wire.videoFrame(keyframe: false, ptsMicros: 1, avcc: Data(repeating: 7, count: 100))
        var reader = FrameReader()
        XCTAssertTrue(try reader.push(bytes.prefix(50)).isEmpty)
        XCTAssertEqual(try reader.push(bytes.suffix(from: 50)).count, 1)
    }

    func testGarbageIsRejected() {
        var reader = FrameReader()
        XCTAssertThrowsError(try reader.push(Data([0xEE, 0, 0, 0, 1, 0])))
        var reader2 = FrameReader()
        XCTAssertThrowsError(try reader2.push(Data([1, 0x7F, 0xFF, 0xFF, 0xFF])))
    }

    func testTruncatedFormatIsNil() {
        XCTAssertNil(Wire.parseVideoFormat(Data([2, 0, 3, 1, 2, 3, 0, 9])))
        XCTAssertNil(Wire.parseVideoFrame(Data([1, 2, 3])))
    }
}

final class GeometryTests: XCTestCase {
    let screen = CGRect(x: 0, y: 25, width: 1920, height: 1030)

    func testFitIsZoomTimesThePhone() {
        let big = CGRect(x: 3000, y: 0, width: 1600, height: 1200)
        let s = Geometry.fit(viewport: CGSize(width: 393, height: 700), zoom: 1.4, in: big)
        XCTAssertEqual(s, CGSize(width: 550, height: 980))
    }

    func testFitShrinksToTheScreenKeepingShape() {
        let s = Geometry.fit(viewport: CGSize(width: 393, height: 760), zoom: 1.4, in: screen)
        XCTAssertEqual(s.height, 1030)
        XCTAssertEqual(s.width / s.height, 393 / 760, accuracy: 0.01)
        let wide = Geometry.fit(viewport: CGSize(width: 852, height: 393), zoom: 3, in: screen)
        XCTAssertLessThanOrEqual(wide.width, 1920)
        XCTAssertLessThanOrEqual(wide.height, 1030)
        XCTAssertEqual(wide.width / wide.height, 852 / 393, accuracy: 0.01)
    }

    func testNarrowShapesKeepAUsableWidth() {
        let s = Geometry.fit(viewport: CGSize(width: 200, height: 300), zoom: 1, in: screen)
        XCTAssertEqual(s, CGSize(width: 480, height: 720))
    }

    func testAspectFitCentersAndMapsTouches() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let video = Geometry.aspectFit(CGSize(width: 1600, height: 900), in: bounds)
        XCTAssertEqual(video.width, 400)
        XCTAssertEqual(video.height, 225)
        XCTAssertEqual(video.midY, 400)
        XCTAssertNil(Geometry.normalized(CGPoint(x: 200, y: 10), in: video))
        let p = try! XCTUnwrap(Geometry.normalized(CGPoint(x: 100, y: video.midY), in: video))
        XCTAssertEqual(p.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(p.y, 0.5, accuracy: 0.001)
        XCTAssertEqual(Geometry.clampedNormalized(CGPoint(x: -50, y: 9999), in: video), CGPoint(x: 0, y: 1))
    }

    func testScreenPointClampsIntoTheWindow() {
        let w = CGRect(x: 100, y: 200, width: 800, height: 600)
        XCTAssertEqual(Geometry.screenPoint(x: 0.5, y: 0.5, window: w), CGPoint(x: 500, y: 500))
        XCTAssertEqual(Geometry.screenPoint(x: 2, y: -1, window: w), CGPoint(x: 900, y: 200))
    }
}

final class KeysTests: XCTestCase {
    func testNamesForTypedCharacters() {
        XCTAssertEqual(Keys.name(for: "\n"), "return")
        XCTAssertEqual(Keys.name(for: "S"), "s")
        XCTAssertEqual(Keys.name(for: " "), "space")
        XCTAssertNil(Keys.name(for: "é"))
        XCTAssertEqual(Keys.codes["c"], 8)
        XCTAssertEqual(Keys.codes["escape"], 53)
    }
}

final class VideoSamplesTests: XCTestCase {
    /// Encode a real frame with the hardware encoder settings the agent uses,
    /// send it through the wire format, and rebuild a decodable sample.
    func testEncodedFrameSurvivesTheWire() throws {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        var bytes = Data()
        let got = expectation(description: "frame")
        let encoder = try XCTUnwrap(Encoder(width: 640, height: 360,
            onFormat: { bytes += Wire.videoFormat($0) },
            onFrame: { key, pts, avcc in bytes += Wire.videoFrame(keyframe: key, ptsMicros: pts, avcc: avcc); got.fulfill() }))
        encoder.encode(try XCTUnwrap(pixels), pts: CMTime(value: 1, timescale: 60), keyframe: true)
        wait(for: [got], timeout: 5)

        var reader = FrameReader()
        let frames = try reader.push(bytes)
        XCTAssertEqual(frames.map(\.type), [.videoFormat, .videoFrame])
        let sets = try XCTUnwrap(Wire.parseVideoFormat(frames[0].payload))
        XCTAssertEqual(sets.count, 2, "SPS + PPS")
        let fmt = try XCTUnwrap(VideoSamples.format(sets))
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(fmt).width, 640)
        let f = try XCTUnwrap(Wire.parseVideoFrame(frames[1].payload))
        XCTAssertTrue(f.keyframe)
        XCTAssertNotNil(VideoSamples.sample(f.avcc, format: fmt, ptsMicros: f.ptsMicros))
    }
}

final class PeersTests: XCTestCase {
    func testOnlyLoopbackAndTailnetAddressesAreCandidates() {
        XCTAssertTrue(Peers.isLoopback("127.0.0.1"))
        XCTAssertTrue(Peers.isLoopback("::1"))
        XCTAssertTrue(Peers.isLoopback("::ffff:127.0.0.1"))
        XCTAssertTrue(Peers.isTailnet("100.64.0.30"))
        XCTAssertTrue(Peers.isTailnet("::ffff:100.64.0.10"))
        XCTAssertTrue(Peers.isTailnet("fd7a:115c:a1e0::1234%utun4"))
        XCTAssertFalse(Peers.isTailnet("100.128.0.1"), "outside 100.64.0.0/10")
        XCTAssertFalse(Peers.isTailnet("100.63.0.1"))
        XCTAssertFalse(Peers.isTailnet("192.168.1.20"), "home Wi-Fi isn't enough")
        XCTAssertFalse(Peers().allowed("192.168.1.20"))
        XCTAssertTrue(Peers().allowed("127.0.0.1"))
    }
}

final class TerminalWireTests: XCTestCase {
    func testSessionNamesAreSanitized() {
        XCTAssertEqual(Wire.sessionName("panes-1A_b"), "panes-1A_b")
        XCTAssertEqual(Wire.sessionName("x; rm -rf ~"), "xrm-rf")
        XCTAssertEqual(Wire.sessionName("$(reboot)"), "reboot")
        XCTAssertEqual(Wire.sessionName(nil), "panes")
        XCTAssertEqual(Wire.sessionName("é'\""), "panes")
    }

    func testOnlyPanesSessionsCanBeEnded() {
        XCTAssertTrue(Wire.isPanesSession("panes-1a2b3c"))
        XCTAssertFalse(Wire.isPanesSession("work"))
        XCTAssertFalse(Wire.isPanesSession("panes-"))
        XCTAssertFalse(Wire.isPanesSession("mypanes-x"))
    }

    func testTerminalBytesRoundTrip() throws {
        var reader = FrameReader()
        let frames = try reader.push(Wire.encode(.terminal, Data("ls -la\r".utf8)))
        XCTAssertEqual(frames, [Frame(type: .terminal, payload: Data("ls -la\r".utf8))])
    }
}

final class WebKeysTests: XCTestCase {
    func testTypingMapsToDOMKeys() {
        let keys = WebKeys.keys(for: InputEvent(kind: "text", text: "aB1."))
        XCTAssertEqual(keys.map(\.key), ["a", "B", "1", "."])
        XCTAssertEqual(keys.map(\.code), ["KeyA", "KeyB", "Digit1", "Period"])
        XCTAssertEqual(keys.map(\.keyCode), [65, 66, 49, 190])
        let plus = WebKeys.character("+")
        XCTAssertEqual(plus, WebKeys.DOMKey(key: "+", code: "Equal", keyCode: 187, shift: true))
        XCTAssertEqual(WebKeys.character("é").keyCode, 0)
        XCTAssertEqual(keys.map(\.shift), [false, true, false, false])
    }

    func testSpecialKeysAndCommandBecomesControl() {
        XCTAssertEqual(WebKeys.keys(for: InputEvent(kind: "key", key: "delete")).first?.key, "Backspace")
        let copy = WebKeys.keys(for: InputEvent(kind: "key", key: "c", mods: ["cmd"]))
        XCTAssertEqual(copy, [WebKeys.DOMKey(key: "c", code: "KeyC", keyCode: 67, ctrl: true)])
        XCTAssertEqual(WebKeys.keys(for: InputEvent(kind: "text", text: "\n")).first?.key, "Enter")
    }

    func testScriptEscapesQuotes() {
        let js = WebKeys.script(WebKeys.keys(for: InputEvent(kind: "text", text: "\"\\")))
        XCTAssertEqual(js, #"panesKey("\"","Quote",222,false,false,true,false);panesKey("\\","Backslash",220,false,false,false,false);"#)
    }
}

final class AudioTests: XCTestCase {
    func testAudioFormatRoundTrips() throws {
        let f = AudioFormat(sampleRate: 48_000, channels: 2, framesPerPacket: 1024, cookie: Data([1, 2, 3]))
        var reader = FrameReader()
        let frames = try reader.push(Wire.audioFormat(f) + Wire.audioFrame(ptsMicros: 99, packet: Data([7, 7])))
        XCTAssertEqual(Wire.parseAudioFormat(frames[0].payload), f)
        let a = try XCTUnwrap(Wire.parseAudioFrame(frames[1].payload))
        XCTAssertEqual(a.ptsMicros, 99)
        XCTAssertEqual(a.packet, Data([7, 7]))
    }

    /// A second of 440 Hz through the agent's AAC encoder, the wire, and a
    /// decoder must come back as a loud tone (not silence, not garbage).
    func testToneSurvivesEncodeAndDecode() throws {
        let pcm = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        var packets: [(UInt64, Data)] = []
        let encoder = try XCTUnwrap(AudioEncoder(input: pcm) { packets.append(($0, $1)) })
        for chunk in 0..<48 {
            let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 1000))
            buf.frameLength = 1000
            for ch in 0..<2 {
                for i in 0..<1000 {
                    buf.floatChannelData![ch][i] = 0.5 * sin(2 * .pi * 440 * Float(chunk * 1000 + i) / 48_000)
                }
            }
            encoder.encode(buf, ptsMicros: 1_000_000)
        }
        XCTAssertGreaterThan(packets.count, 40)
        XCTAssertEqual(packets[1].0 - packets[0].0, 21_333, "1024 frames at 48 kHz")

        let wire = try XCTUnwrap(Wire.parseAudioFormat(try FrameReader().pushOne(Wire.audioFormat(encoder.format))))
        let desc = try XCTUnwrap(AudioSamples.format(wire))
        var asbd = AudioSamples.streamDescription(wire)
        let aac = try XCTUnwrap(AVAudioFormat(streamDescription: &asbd))
        let decoder = try XCTUnwrap(AVAudioConverter(from: aac, to: pcm))
        decoder.magicCookie = wire.cookie
        var energy: Float = 0, samples = 0
        for (pts, packet) in packets {
            XCTAssertNotNil(AudioSamples.sample(packet, format: desc, framesPerPacket: 1024, sampleRate: 48_000, ptsMicros: pts))
            let comp = AVAudioCompressedBuffer(format: aac, packetCapacity: 1, maximumPacketSize: packet.count)
            packet.withUnsafeBytes { comp.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
            comp.byteLength = UInt32(packet.count)
            comp.packetCount = 1
            comp.packetDescriptions![0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                       mDataByteSize: UInt32(packet.count))
            let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 1024))
            var fed = false
            _ = decoder.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return comp
            }
            for i in 0..<Int(out.frameLength) { energy += out.floatChannelData![0][i] * out.floatChannelData![0][i] }
            samples += Int(out.frameLength)
        }
        let rms = sqrt(energy / Float(max(samples, 1)))
        XCTAssertGreaterThan(samples, 30_000)
        XCTAssertEqual(rms, 0.35, accuracy: 0.08, "0.5-amplitude sine has RMS ≈ 0.354")
    }
}

extension FrameReader {
    func pushOne(_ data: Data) throws -> Data {
        var r = self
        return try r.push(data)[0].payload
    }
}

final class WebSocketTests: XCTestCase {
    func testAcceptKeyMatchesTheRFCExample() {
        XCTAssertEqual(WebSocket.acceptKey("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testMaskedClientFramesOfEverySizeComeBack() throws {
        for size in [0, 5, 125, 126, 300, 65_535, 65_536, 200_000] {
            let payload = Data((0..<size).map { UInt8($0 % 251) })
            var reader = WebSocket.Reader()
            var got: [(WebSocket.Opcode, Data)] = []
            let bytes = WebSocket.frame(.binary, payload, mask: [1, 2, 3, 4])
            for chunk in stride(from: 0, to: bytes.count, by: 997) {
                got += try reader.push(bytes.subdata(in: chunk..<min(chunk + 997, bytes.count)))
            }
            XCTAssertEqual(got.count, 1, "size \(size)")
            XCTAssertEqual(got.first?.1, payload, "size \(size)")
        }
    }

    func testFragmentsAreJoinedAndControlFramesPassThrough() throws {
        var first = WebSocket.frame(.binary, Data([1, 2]), mask: [9, 9, 9, 9])
        first[0] &= 0x7F   // not final
        let ping = WebSocket.frame(.ping, Data([7]), mask: [1, 1, 1, 1])
        let last = WebSocket.frame(.continuation, Data([3]), mask: [5, 6, 7, 8])
        var reader = WebSocket.Reader()
        let got = try reader.push(first + ping + last)
        XCTAssertEqual(got.map(\.0), [.ping, .binary])
        XCTAssertEqual(got[1].1, Data([1, 2, 3]))
    }

    func testUnmaskedAndOversizedClientFramesAreRefused() {
        var r1 = WebSocket.Reader()
        XCTAssertThrowsError(try r1.push(WebSocket.frame(.binary, Data([1]))))
        var r2 = WebSocket.Reader(maxMessage: 10)
        XCTAssertThrowsError(try r2.push(WebSocket.frame(.binary, Data(count: 11), mask: [1, 2, 3, 4])))
    }
}

final class WebServerTests: XCTestCase {
    func testRequestHeadersParse() {
        let r = WebHTTP.Request("GET /ws?x=1 HTTP/1.1\r\nHost: 127.0.0.1:7891\r\nUpgrade: websocket\r\nSec-WebSocket-Key: abc\r\nTailscale-User-Login: me@x")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/ws?x=1")
        XCTAssertEqual(r.headers["tailscale-user-login"], "me@x")
        XCTAssertTrue(r.isWebSocketUpgrade)
    }

    func testStaticFilesStayInsideTheirFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("panes-web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("vendor"), withIntermediateDirectories: true)
        try Data("<html>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("x".utf8).write(to: root.appendingPathComponent("vendor/a.js"))
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(WebHTTP.staticFile("/", root: root)?.lastPathComponent, "index.html")
        XCTAssertEqual(WebHTTP.staticFile("/vendor/a.js", root: root)?.lastPathComponent, "a.js")
        XCTAssertNil(WebHTTP.staticFile("/../../etc/passwd", root: root))
        XCTAssertNil(WebHTTP.staticFile("/%2e%2e/%2e%2e/etc/passwd", root: root))
        XCTAssertNil(WebHTTP.staticFile("/vendor", root: root), "folders aren't files")
        XCTAssertNil(WebHTTP.staticFile("/missing.js", root: root))
        XCTAssertEqual(WebHTTP.contentType("js"), "text/javascript; charset=utf-8")
        // The install manifest needs its own type, or browsers won't offer to install the web app.
        XCTAssertEqual(WebHTTP.contentType("webmanifest"), "application/manifest+json")
        XCTAssertEqual(WebHTTP.contentType("woff2"), "font/woff2")
    }

    func testOnlyLocalHostsPassWithoutTailscaleIdentity() {
        XCTAssertTrue(Peers.isLocalHost("127.0.0.1:7891"))
        XCTAssertTrue(Peers.isLocalHost("localhost:7891"))
        XCTAssertFalse(Peers.isLocalHost("evil.example:7891"))
        XCTAssertFalse(Peers.isLocalHost(nil))
        let p = Peers()
        XCTAssertTrue(p.webRequestAllowed(login: nil, host: "127.0.0.1:7891"))
        XCTAssertFalse(p.webRequestAllowed(login: nil, host: "my-mac-mini.tailnet-example.ts.net:7443"))
        XCTAssertFalse(p.webRequestAllowed(login: "someone-else@example.com", host: "127.0.0.1:7891"))
    }

    func testOnlyPanesWebPagesMayOpenWebSockets() {
        let p = Peers()
        XCTAssertTrue(p.webOriginAllowed("http://127.0.0.1:7891"))
        XCTAssertTrue(p.webOriginAllowed("http://localhost:7891"))
        XCTAssertFalse(p.webOriginAllowed("https://evil.example"))
        XCTAssertFalse(p.webOriginAllowed("http://127.0.0.1:8000"))
        XCTAssertFalse(p.webOriginAllowed(nil))
        if let suffix = p.identity().suffix {   // needs this Mac's Tailscale
            XCTAssertTrue(p.webOriginAllowed("https://linux-box.\(suffix):7443"))
            XCTAssertFalse(p.webOriginAllowed("https://linux-box.\(suffix):443"))
            XCTAssertFalse(p.webOriginAllowed("https://evil.\(suffix).example.com:7443"))
        }
    }
}

final class DeviceBookTests: XCTestCase {
    private func tab(_ app: String) -> TabRef { TabRef(machine: "Mac mini", kind: "window", app: app, windowID: 7) }

    func testReportListAndSendAcrossDevices() {
        var clock = 1000.0
        let book = DeviceBook(file: nil, now: { clock })
        XCTAssertEqual(book.report(DeviceInfo(id: "phone-1", name: "iPhone", kind: "phone", tabs: [tab("Xcode")])), [])
        clock += 5
        _ = book.report(DeviceInfo(id: "web-1", name: "Chrome on Linux", kind: "browser", tabs: []))
        // Newest first, and never the asker itself.
        XCTAssertEqual(book.list().map(\.id), ["web-1", "phone-1"])
        XCTAssertEqual(book.list(except: "web-1").map(\.id), ["phone-1"])
        XCTAssertEqual(book.list(except: "web-1").first?.tabs, [tab("Xcode")])
        XCTAssertEqual(book.list().first?.seen, 1005)

        XCTAssertTrue(book.send(tab("Xcode"), to: "web-1", from: "iPhone", id: "s1"))
        XCTAssertTrue(book.send(tab("Xcode"), to: "web-1", from: "iPhone", id: "s1"))   // a resend isn't doubled
        XCTAssertFalse(book.send(tab("Xcode"), to: "nobody", from: "iPhone", id: "s2"))
        let got = book.report(DeviceInfo(id: "web-1", name: "Chrome on Linux", kind: "browser", tabs: []))
        XCTAssertEqual(got.map(\.from), ["iPhone"])
        XCTAssertEqual(got.first?.tab, tab("Xcode"))
        // Picked up once, then gone.
        XCTAssertEqual(book.report(DeviceInfo(id: "web-1", name: "Chrome on Linux", kind: "browser", tabs: [])), [])
    }

    func testOldDevicesAndSendsAgeOut() {
        var clock = 0.0
        let book = DeviceBook(file: nil, now: { clock })
        _ = book.report(DeviceInfo(id: "a", name: "A", kind: "phone", tabs: []))
        _ = book.report(DeviceInfo(id: "b", name: "B", kind: "browser", tabs: []))
        book.send(tab("Xcode"), to: "b", from: "A", id: "s")
        clock = DeviceBook.sentTTL + 1
        _ = book.report(DeviceInfo(id: "a", name: "A", kind: "phone", tabs: []))
        XCTAssertEqual(book.report(DeviceInfo(id: "b", name: "B", kind: "browser", tabs: [])), [])
        clock += DeviceBook.deviceTTL + 1
        _ = book.report(DeviceInfo(id: "a", name: "A", kind: "phone", tabs: []))
        XCTAssertEqual(book.list().map(\.id), ["a"])
    }

    func testRejectsOddIdsAndCapsSizes() {
        let book = DeviceBook(file: nil)
        XCTAssertEqual(book.report(DeviceInfo(id: "../../etc", name: "x", kind: "phone", tabs: [])), [])
        XCTAssertTrue(book.list().isEmpty)
        let many = (0..<100).map { tab("App \($0)") }
        _ = book.report(DeviceInfo(id: "big", name: String(repeating: "n", count: 500), kind: "weird", tabs: many))
        let d = book.list().first
        XCTAssertEqual(d?.tabs.count, DeviceBook.maxTabs)
        XCTAssertEqual(d?.name.count, 60)
        XCTAssertEqual(d?.kind, "browser")
        for i in 0..<30 { book.send(tab("T"), to: "big", from: "x", id: "s\(i)") }
        XCTAssertEqual(book.report(DeviceInfo(id: "big", name: "n", kind: "phone", tabs: [])).count, DeviceBook.maxInbox)
    }

    func testSurvivesARestart() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("panes-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let one = DeviceBook(file: file)
        _ = one.report(DeviceInfo(id: "p", name: "iPhone", kind: "phone", tabs: [tab("Xcode")]))
        one.send(tab("Logic Pro"), to: "p", from: "Chrome", id: "s")
        let two = DeviceBook(file: file)
        XCTAssertEqual(two.list().first?.tabs, [tab("Xcode")])
        XCTAssertEqual(two.report(DeviceInfo(id: "p", name: "iPhone", kind: "phone", tabs: [])).first?.tab.app, "Logic Pro")
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testDeviceMessagesRoundTrip() throws {
        let msg = Control(op: "send", name: "iPhone", to: "web-1",
                          tab: TabRef(machine: "linux-box", kind: "app", app: "Calculator", session: "panes-abc123", appID: "org.gnome.Calculator"))
        let back = try JSONDecoder().decode(Control.self, from: try JSONEncoder().encode(msg))
        XCTAssertEqual(back, msg)
    }
}
