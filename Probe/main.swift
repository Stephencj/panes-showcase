import AppKit
import CoreImage
import Network
import VideoToolbox

// End-to-end check of a running agent, from the phone's side of the wire:
//
//   panes-probe --title <part of a window title> [--host 127.0.0.1] [--fit 393x760]
//               [--type <text>] [--png out.png]
//
// Connects, lists windows, opens the matching one, decodes the first keyframe,
// optionally types text into it, and prints a JSON summary. Exit 0 on success.

var args = CommandLine.arguments.dropFirst()
var opts: [String: String] = [:]
while let key = args.popFirst() { if key.hasPrefix("--") { opts[String(key.dropFirst(2))] = args.popFirst() ?? "" } }
let terminalMode = opts["terminal"] != nil
let appNeedle = opts["app"]
guard let titleNeedle = opts["title"] ?? (terminalMode || appNeedle != nil ? "" : nil) else {
    print("usage: panes-probe --title TEXT [--host H] [--port P] [--fit WxH] [--type TEXT] [--png PATH]")
    print("       panes-probe --terminal NAME [--host H] [--port P]   (runs a command in a terminal tab)")
    print("       panes-probe --app TEXT [--host H]   (launches a Linux app; checks its web client answers)")
    exit(2)
}
var terminalOutput = ""
var audioPackets = 0
// The shell has to compute this, so seeing it proves a real shell ran the line.
let marker = "PANES_" + "42"

let host = opts["host"] ?? "127.0.0.1"
var summary: [String: Any] = ["host": host]
let started = Date()
var reader = FrameReader()
var format: CMVideoFormatDescription?
var decoder: VTDecompressionSession?
var framesSeen = 0
var keyframesSeen = 0
var typed = false
var done = false

func finish(_ ok: Bool, _ note: String? = nil) {
    guard !done else { return }
    done = true
    summary["ok"] = ok
    if let note { summary["note"] = note }
    summary["frames"] = framesSeen
    summary["keyframes"] = keyframesSeen
    if opts["audio"] != nil { summary["audioPackets"] = audioPackets }
    let json = try! JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    print(String(data: json, encoding: .utf8)!)
    exit(ok ? 0 : 1)
}

let port = opts["port"].flatMap(UInt16.init) ?? Wire.port
let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
func send(_ c: Control) { conn.send(content: Wire.encode(c), completion: .idempotent) }

func decode(_ sample: CMSampleBuffer) {
    guard let format else { return }
    if decoder == nil {
        var s: VTDecompressionSession?
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                     imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &s)
        decoder = s
    }
    guard let decoder else { return finish(false, "no decoder") }
    VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
        guard status == noErr, let image else { return }
        DispatchQueue.main.async { decoded(image) }
    }
}

func decoded(_ image: CVImageBuffer) {
    guard summary["firstFrameMs"] == nil else { return }
    summary["firstFrameMs"] = Int(Date().timeIntervalSince(started) * 1000)
    summary["frameSize"] = "\(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image))"
    let ci = CIImage(cvImageBuffer: image)
    let ctx = CIContext()
    // Average brightness: a blank or black capture means Screen Recording is off.
    let avg = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)])!
    var px = [UInt8](repeating: 0, count: 4)
    ctx.render(avg.outputImage!, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
               format: .RGBA8, colorSpace: nil)
    summary["averageRGB"] = [px[0], px[1], px[2]]
    if let path = opts["png"], let cg = ctx.createCGImage(ci, from: ci.extent) {
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        summary["png"] = path
    }
    if let text = opts["type"] {
        send(Control(op: "input", event: InputEvent(kind: "click", x: 0.5, y: 0.5)))
        send(Control(op: "input", event: InputEvent(kind: "text", text: text)))
        typed = true
        summary["typed"] = text
        // Typing changes the window, so a fresh frame must follow.
        let before = framesSeen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            summary["framesAfterTyping"] = framesSeen - before
            finish(framesSeen > before, framesSeen > before ? nil : "no new frames after typing")
        }
    } else if let secs = opts["audio"].flatMap(Double.init) {
        // Listen for a while; whatever the app plays should arrive as packets.
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { finish(audioPackets > 0, audioPackets > 0 ? nil : "no audio") }
    } else {
        finish(true)
    }
}

func handle(_ frame: Frame) {
    switch frame.type {
    case .control:
        guard let msg = try? JSONDecoder().decode(Control.self, from: frame.payload) else { return }
        switch msg.op {
        case "hello":
            summary["machine"] = msg.machine
            summary["features"] = msg.features
            if terminalMode {
                send(Control(op: "terminal", name: opts["terminal"], cols: 100, rows: 30))
            } else if appNeedle != nil {
                send(Control(op: "apps"))
            } else {
                send(Control(op: "list"))
            }
        case "apps":
            let apps = msg.apps ?? []
            summary["appCount"] = apps.count
            guard let a = apps.first(where: { $0.name.localizedCaseInsensitiveContains(appNeedle ?? "") || $0.id.localizedCaseInsensitiveContains(appNeedle ?? "") }) else {
                return finish(false, "no app like \(appNeedle ?? "")")
            }
            summary["app"] = "\(a.name) (\(a.id))"
            send(Control(op: "launch", app: a.id, name: opts["session"] ?? "panes-probe-app"))
        case "launched":
            summary["launchedMs"] = Int(Date().timeIntervalSince(started) * 1000)
            guard let u = msg.url.flatMap(URL.init(string:)) else { return finish(false, "no url") }
            summary["url"] = u.absoluteString.replacingOccurrences(of: #"password=[^&]+"#, with: "password=…", options: .regularExpression)
            URLSession.shared.dataTask(with: u) { data, resp, err in
                DispatchQueue.main.async {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    let page = String(decoding: data ?? Data(), as: UTF8.self)
                    summary["httpStatus"] = code
                    summary["looksLikeXpra"] = page.localizedCaseInsensitiveContains("xpra")
                    finish(code == 200 && page.localizedCaseInsensitiveContains("xpra"), err.map { "\($0)" })
                }
            }.resume()
        case "terminalOpened":
            summary["session"] = msg.name
            conn.send(content: Wire.encode(.terminal, Data("echo PANES_$((6*7))\r".utf8)), completion: .idempotent)
        case "exited":
            summary["exited"] = true
            finish(terminalOutput.contains(marker), terminalOutput.contains(marker) ? nil : "shell exited early")
        case "windows":
            let windows = msg.windows ?? []
            summary["windowCount"] = windows.count
            guard let w = windows.first(where: { $0.title.localizedCaseInsensitiveContains(titleNeedle) }) else {
                return finish(false, "no window titled like \(titleNeedle)")
            }
            summary["window"] = "\(w.app) — \(w.title)"
            var viewport: Size?
            if let fit = opts["fit"] {
                let p = fit.split(separator: "x").compactMap { Double($0) }
                if p.count == 2 { viewport = Size(width: p[0], height: p[1]) }
            }
            send(Control(op: "open", windowID: w.id, viewport: viewport, audio: opts["audio"] != nil))
        case "opened":
            summary["opened"] = "\(Int(msg.width ?? 0))x\(Int(msg.height ?? 0)) pt"
        case "error":
            summary["error"] = msg.error
            if msg.error?.contains("System Settings") != true { finish(false, msg.error) }
        default:
            break
        }
    case .audioFormat:
        if let f = Wire.parseAudioFormat(frame.payload) { summary["audioFormat"] = "\(Int(f.sampleRate)) Hz x\(f.channels)" }
    case .audioFrame:
        audioPackets += 1
    case .terminal:
        terminalOutput += String(decoding: frame.payload, as: UTF8.self)
        if terminalOutput.contains(marker), summary["firstOutputMs"] == nil {
            summary["firstOutputMs"] = Int(Date().timeIntervalSince(started) * 1000)
            summary["sawMarker"] = true
            // Leave nothing behind: exit ends the tmux session too.
            conn.send(content: Wire.encode(.terminal, Data("exit\r".utf8)), completion: .idempotent)
        }
    case .videoFormat:
        if let sets = Wire.parseVideoFormat(frame.payload), let f = VideoSamples.format(sets) {
            format = f
            decoder = nil
            let d = CMVideoFormatDescriptionGetDimensions(f)
            summary["streamSizes"] = (summary["streamSizes"] as? [String] ?? []) + ["\(d.width)x\(d.height)"]
        }
    case .videoFrame:
        guard let f = Wire.parseVideoFrame(frame.payload), let format else { return }
        framesSeen += 1
        if f.keyframe { keyframesSeen += 1 }
        if let s = VideoSamples.sample(f.avcc, format: format, ptsMicros: f.ptsMicros, displayImmediately: false) { decode(s) }
    }
}

func receive() {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
        if let data { (try? reader.push(data))?.forEach(handle) }
        if complete || error != nil { return finish(false, "connection closed: \(error.map { "\($0)" } ?? "by agent")") }
        receive()
    }
}

conn.stateUpdateHandler = { state in
    switch state {
    case .ready: send(Control(op: "hello", version: Wire.version)); receive()
    case .failed(let e): finish(false, "connect failed: \(e)")
    default: break
    }
}
conn.start(queue: .main)
DispatchQueue.main.asyncAfter(deadline: .now() + 15 + (opts["audio"].flatMap(Double.init) ?? 0)) { finish(false, "timed out") }
dispatchMain()
