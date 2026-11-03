import AVFoundation
import ScreenCaptureKit

/// The sound of one app (the streamed window's), and nothing else on the Mac.
/// A separate stream from the window's video, because a window filter can't
/// pick out an app's audio.
final class AudioCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private var encoder: AudioEncoder?
    private let queue: DispatchQueue
    private let onFormat: (AudioFormat) -> Void
    private let onPacket: (UInt64, Data) -> Void
    var paused = false

    init(queue: DispatchQueue, onFormat: @escaping (AudioFormat) -> Void,
         onPacket: @escaping (UInt64, Data) -> Void) {
        self.queue = queue
        self.onFormat = onFormat
        self.onPacket = onPacket
    }

    func start(app: SCRunningApplication) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { return }
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        // Video can't be turned off; keep it tiny and rare.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        encoder = nil
    }

    /// The next packets start a fresh stream (a phone that just reconnected or resumed).
    func resendFormat() {
        if let encoder { onFormat(encoder.format) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, !paused, sample.isValid,
              let desc = CMSampleBufferGetFormatDescription(sample) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        if encoder == nil {
            encoder = AudioEncoder(input: format, onPacket: onPacket)
            if let encoder { onFormat(encoder.format) }
        }
        guard let pcm = Self.pcm(sample, format: format) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        encoder?.encode(pcm, ptsMicros: pts.isValid ? UInt64(max(0, pts.seconds * 1_000_000)) : 0)
    }

    /// Copies the captured audio out (ScreenCaptureKit reuses its buffers).
    private static func pcm(_ sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
