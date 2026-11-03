import AVFoundation
import CoreMedia

/// Rebuilds playable samples from the wire's AAC packets.
enum AudioSamples {
    static func streamDescription(_ f: AudioFormat) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: f.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
                                    mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: f.framesPerPacket,
                                    mBytesPerFrame: 0, mChannelsPerFrame: f.channels, mBitsPerChannel: 0,
                                    mReserved: 0)
    }

    static func format(_ f: AudioFormat) -> CMAudioFormatDescription? {
        var asbd = streamDescription(f)
        var desc: CMAudioFormatDescription?
        let status = f.cookie.withUnsafeBytes { cookie in
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: f.cookie.count,
                                           magicCookie: f.cookie.isEmpty ? nil : cookie.baseAddress,
                                           extensions: nil, formatDescriptionOut: &desc)
        }
        return status == noErr ? desc : nil
    }

    static func sample(_ packet: Data, format: CMAudioFormatDescription, framesPerPacket: UInt32,
                       sampleRate: Double, ptsMicros: UInt64) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: packet.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: packet.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = packet.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: packet.count)
        }
        guard copied == noErr else { return nil }
        var description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                       mDataByteSize: UInt32(packet.count))
        let pts = CMTime(value: CMTimeValue(Double(ptsMicros) * sampleRate / 1_000_000), timescale: CMTimeScale(sampleRate))
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: CMItemCount(framesPerPacket),
            presentationTimeStamp: pts, packetDescriptions: &description, sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }
}
