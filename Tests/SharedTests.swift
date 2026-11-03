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
