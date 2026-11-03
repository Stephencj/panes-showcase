import AVFoundation

/// Plays a tab's AAC stream. Starts a little behind the first packet so
/// network jitter doesn't cause gaps; a new format (reconnect, resume) restarts it.
final class AudioPlayer {
    private let renderer = AVSampleBufferAudioRenderer()
    private let clock = AVSampleBufferRenderSynchronizer()
    private var wire: AudioFormat?
    private var format: CMAudioFormatDescription?
    private var started = false
    /// How far behind live sound plays: enough for cellular jitter, not enough to notice.
    private let lead = 0.15

    init() { clock.addRenderer(renderer) }

    func setFormat(_ f: AudioFormat) {
        wire = f
        format = AudioSamples.format(f)
        restart()
    }

    func play(ptsMicros: UInt64, packet: Data) {
        guard let wire, let format,
              let sample = AudioSamples.sample(packet, format: format, framesPerPacket: wire.framesPerPacket,
                                               sampleRate: wire.sampleRate, ptsMicros: ptsMicros) else { return }
        if renderer.status == .failed { restart() }
        if !started {
            started = true
            clock.setRate(1, time: CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample),
                                                  CMTime(seconds: lead, preferredTimescale: 48_000)))
        }
        if renderer.isReadyForMoreMediaData { renderer.enqueue(sample) }
    }

    func stop() { restart() }

    private func restart() {
        clock.setRate(0, time: .zero)
        renderer.flush()
        started = false
    }

    /// Mixed with other audio, and plays with the ringer switch on silent
    /// (it's an app's sound you chose to stream).
    static func configureSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}
