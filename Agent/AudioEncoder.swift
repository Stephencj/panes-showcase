import AVFoundation

/// PCM in, AAC packets out (48 kHz stereo, 128 kb/s): small enough for
/// cellular, and every iPhone decodes it in hardware.
final class AudioEncoder {
    let format: AudioFormat
    private let converter: AVAudioConverter
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private var pending: [AVAudioPCMBuffer] = []
    private var framesOut: Int64 = 0
    private var startMicros: UInt64?
    private let onPacket: (UInt64, Data) -> Void

    init?(input: AVAudioFormat, onPacket: @escaping (UInt64, Data) -> Void) {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC,
                                               mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                               mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0,
                                               mReserved: 0)
        guard let output = AVAudioFormat(streamDescription: &asbd),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.bitRate = 128_000
        self.input = input
        self.output = output
        self.converter = converter
        self.onPacket = onPacket
        format = AudioFormat(sampleRate: 48_000, channels: 2, framesPerPacket: 1024,
                             cookie: converter.magicCookie ?? Data())
    }

    /// `ptsMicros` is when the first buffer was heard; later packets are timed
    /// from the sample count, so they stay evenly spaced.
    func encode(_ buffer: AVAudioPCMBuffer, ptsMicros: UInt64) {
        if startMicros == nil { startMicros = ptsMicros }
        pending.append(buffer)
        let out = AVAudioCompressedBuffer(format: output, packetCapacity: 16,
                                          maximumPacketSize: max(converter.maximumOutputPacketSize, 1536))
        while true {
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { [weak self] _, inputStatus in
                guard let self, !self.pending.isEmpty else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return self.pending.removeFirst()
            }
            emit(out)
            if status != .haveData || out.packetCount == 0 { break }
        }
    }

    private func emit(_ out: AVAudioCompressedBuffer) {
        guard out.packetCount > 0, let descriptions = out.packetDescriptions, let start = startMicros else { return }
        let bytes = out.data.assumingMemoryBound(to: UInt8.self)
        for i in 0..<Int(out.packetCount) {
            let d = descriptions[i]
            let packet = Data(bytes: bytes + Int(d.mStartOffset), count: Int(d.mDataByteSize))
            let pts = start + UInt64(framesOut * 1_000_000 / 48_000)
            framesOut += 1024
            onPacket(pts, packet)
        }
        out.packetCount = 0
    }
}
