import AudioToolbox
import AVFoundation
import Foundation

private final class RemoteIORenderContext {
    let samples: [Float]
    var cursor = 0

    init(samples: [Float]) {
        self.samples = samples
    }

    func render(_ frameCount: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        let requested = Int(frameCount)
        let remaining = max(0, samples.count - cursor)
        let copyCount = min(requested, remaining)

        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            if copyCount > 0 {
                samples.withUnsafeBufferPointer { source in
                    data.update(from: source.baseAddress!.advanced(by: cursor), count: copyCount)
                }
            }
            if copyCount < requested {
                data.advanced(by: copyCount).initialize(repeating: 0, count: requested - copyCount)
            }
        }
        cursor += copyCount
        return noErr
    }
}

private let remoteIORenderCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
    let context = Unmanaged<RemoteIORenderContext>.fromOpaque(refCon).takeUnretainedValue()
    return context.render(frameCount, ioData: ioData)
}

final class RemoteIOPlayer {
    private var audioUnit: AudioUnit?
    private let context: RemoteIORenderContext

    init(samples: [Float], sampleRate: Double) throws {
        context = RemoteIORenderContext(samples: samples)

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_RemoteIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw RemoteIOError.componentUnavailable
        }

        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit))
        guard let unit else { throw RemoteIOError.componentUnavailable }
        audioUnit = unit

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try withUnsafePointer(to: &format) { pointer in
            try check(AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                0,
                pointer,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ))
        }

        var callback = AURenderCallbackStruct(
            inputProc: remoteIORenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
        )
        try withUnsafePointer(to: &callback) { pointer in
            try check(AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                pointer,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ))
        }
        try check(AudioUnitInitialize(unit))
    }

    deinit {
        stop()
        if let audioUnit {
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }
    }

    func start() throws {
        guard let audioUnit else { throw RemoteIOError.componentUnavailable }
        try check(AudioOutputUnitStart(audioUnit))
    }

    func stop() {
        if let audioUnit {
            AudioOutputUnitStop(audioUnit)
        }
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw RemoteIOError.osStatus(status) }
    }
}

enum RemoteIOError: LocalizedError {
    case componentUnavailable
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .componentUnavailable:
            return "AURemoteIO component is unavailable."
        case let .osStatus(status):
            return "AURemoteIO failed with OSStatus \(status)."
        }
    }
}
