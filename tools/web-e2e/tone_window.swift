// A small window that plays a quiet 440 Hz tone from its own process, so the
// agent's per-app sound capture has something to hear. Used by run.mjs.
//
//   swiftc -O tone_window.swift -o shots/tone_window && shots/tone_window <title> <seconds>
import AppKit
import AVFoundation

let args = CommandLine.arguments
let title = args.count > 1 ? args[1] : "panes-web-probe-tone"
let seconds = args.count > 2 ? Double(args[2]) ?? 60 : 60

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 420, height: 260),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = title
let label = NSTextField(labelWithString: "\(title): 440 Hz")
label.font = .systemFont(ofSize: 20)
label.frame = NSRect(x: 20, y: 110, width: 380, height: 30)
window.contentView?.addSubview(label)
window.makeKeyAndOrderFront(nil)

let engine = AVAudioEngine()
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

DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
app.run()
