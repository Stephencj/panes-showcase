import CoreMedia
import VideoToolbox

/// Hardware H.264 in low-latency mode: no B-frames, so every frame can be
/// shown the moment it arrives.
final class Encoder {
    let width: Int32
    let height: Int32
    private var session: VTCompressionSession?
    private var lastParameterSets: [Data] = []
    private let onFormat: ([Data]) -> Void
    private let onFrame: (Bool, UInt64, Data) -> Void

    init?(width: Int, height: Int, bitrate: Int = 6_000_000,
          onFormat: @escaping ([Data]) -> Void, onFrame: @escaping (Bool, UInt64, Data) -> Void) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.onFormat = onFormat
        self.onFrame = onFrame
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var s: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: self.width, height: self.height,
                                         codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
                                         imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr,
              let s else { return nil }
        session = s
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 4 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    func encode(_ pixels: CVPixelBuffer, pts: CMTime, keyframe: Bool) {
        guard let session else { return }
        let props = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) {
            [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.emit(sample)
        }
    }

    private func emit(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sample) {
            let sets = Self.parameterSets(fmt)
            if !sets.isEmpty, sets != lastParameterSets {
                lastParameterSets = sets
                onFormat(sets)
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let ok = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!) == noErr
        }
        guard ok else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let micros = pts.isValid ? UInt64(max(0, pts.seconds * 1_000_000)) : 0
        onFrame(isKey, micros, data)
    }

    /// Makes the next keyframe resend the parameter sets (a phone that just
    /// reconnected or resumed needs them).
    func resendFormat() { lastParameterSets = [] }

    static func parameterSets(_ fmt: CMFormatDescription) -> [Data] {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr else { return [] }
        return (0..<count).compactMap { i in
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr else { return nil }
            return Data(bytes: ptr, count: size)
        }
    }
}
