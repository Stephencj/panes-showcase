// A small window of the test's own: it plays a quiet 440 Hz tone from its own
// process (so the agent's per-app sound capture has something to hear) and has
// a text field whose text it prints on every change ("TEXT <json>"), so the
// test can check typing and paste arrive without scripting any other app.
// Used by run.mjs and agent_smoke.mjs.
//
//   swiftc -O tone_window.swift -o shots/tone_window && shots/tone_window <title> <seconds> [silent]
import AppKit
import AVFoundation

let args = CommandLine.arguments
let title = args.count > 1 ? args[1] : "panes-web-probe-tone"
let seconds = args.count > 2 ? Double(args[2]) ?? 60 : 60
let silent = args.count > 3 && args[3] == "silent"

setvbuf(stdout, nil, _IOLBF, 0)

let app = NSApplication.shared
app.setActivationPolicy(.regular)

final class Echo: NSObject, NSTextFieldDelegate {
    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField,
              let json = try? JSONEncoder().encode([field.stringValue]),
              let text = String(data: json, encoding: .utf8) else { return }
        print("TEXT \(text)")
    }
}

let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 480, height: 300),
                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = title
let content = window.contentView!
let label = NSTextField(labelWithString: silent ? title : "\(title): 440 Hz")
label.font = .systemFont(ofSize: 20)
label.frame = NSRect(x: 20, y: 200, width: 440, height: 30)
label.autoresizingMask = [.width, .minYMargin]
content.addSubview(label)
// Fills most of the window, so a click in the middle of the stream lands in it.
let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 440, height: 160))
field.font = .systemFont(ofSize: 18)
field.stringValue = "web probe"
field.autoresizingMask = [.width, .height]
let echo = Echo()
field.delegate = echo
content.addSubview(field)
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(field)

let engine = AVAudioEngine()
if !silent {
    let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    var phase = 0.0
    let tone = AVAudioSourceNode { _, _, frameCount, buffers -> OSStatus in
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        for frame in 0..<Int(frameCount) {
            let v = Float(sin(phase) * 0.02) // quiet
            phase += 2 * .pi * 440 / rate
            for b in list { b.mData!.assumingMemoryBound(to: Float.self)[frame] = v }
        }
        return noErr
    }
    engine.attach(tone)
    engine.connect(tone, to: engine.mainMixerNode,
                   format: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
    try engine.start()
}

DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
app.run()
