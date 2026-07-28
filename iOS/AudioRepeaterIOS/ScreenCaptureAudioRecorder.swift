import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

@available(iOS 27.0, *)
final class ScreenCaptureAudioRecorder: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    private let outputQueue = DispatchQueue(label: "com.a2m.audiorepeater.screencapture.audio")
    private var stream: SCStream?
    private var outputURL: URL?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var logHandler: ((String) -> Void)?
    private var sampleBufferCount = 0
    private var screenBufferCount = 0

    @MainActor
    func start(outputURL: URL, log: @escaping (String) -> Void) async throws {
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else {
            throw ScreenCaptureAudioError.unavailable
        }

        self.outputURL = outputURL
        self.logHandler = log
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        picker.add(self)
        picker.isActive = true
        log("AudioRepeaterIOS ScreenCaptureKit picker presented")
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            picker.presentForCurrentApplication()
        }
    }

    @MainActor
    func stop() async throws {
        if let stream {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                stream.stopCapture { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
        stream = nil

        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false

        let writerState = outputQueue.sync { () -> (AVAssetWriter?, AVAssetWriterInput?, Int) in
            (writer, writerInput, sampleBufferCount)
        }
        guard let writer = writerState.0, let input = writerState.1 else {
            logHandler?(
                "AudioRepeaterIOS ScreenCaptureKit capture finished audioBuffers=0 screenBuffers=\(screenBufferCount) digitalAudioFile=false"
            )
            return
        }
        input.markAsFinished()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: writer.error ?? ScreenCaptureAudioError.writerFailed)
                }
            }
        }
        logHandler?(
            "AudioRepeaterIOS ScreenCaptureKit capture finished audioBuffers=\(writerState.2) screenBuffers=\(screenBufferCount) digitalAudioFile=true file=\(outputURL?.lastPathComponent ?? "unknown")"
        )
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        resolveStart(.failure(ScreenCaptureAudioError.cancelled))
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = false

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            // The new iOS in-app capture path currently needs a screen output
            // attached for the stream to drive its audio producer reliably.
            // We discard these frames and retain only the audio audit file.
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
            self.stream = newStream
            newStream.startCapture { [weak self] error in
                guard let self else { return }
                if let error {
                    self.resolveStart(.failure(error))
                } else {
                    self.logHandler?("AudioRepeaterIOS ScreenCaptureKit capture started sampleRate=48000 channels=2 excludesCurrentProcessAudio=false")
                    self.resolveStart(.success(()))
                }
            }
        } catch {
            resolveStart(.failure(error))
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        resolveStart(.failure(error))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        resolveStart(.failure(error))
        logHandler?("AudioRepeaterIOS ScreenCaptureKit stream stopped error=\(error.localizedDescription)")
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        if outputType == .screen {
            screenBufferCount += 1
            if screenBufferCount == 1 {
                logHandler?("AudioRepeaterIOS ScreenCaptureKit first screen buffer received")
            }
            return
        }
        guard outputType == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        if sampleBufferCount == 0 {
            logHandler?("AudioRepeaterIOS ScreenCaptureKit first audio buffer received samples=\(sampleBuffer.numSamples)")
        }
        do {
            try append(sampleBuffer)
        } catch {
            logHandler?("AudioRepeaterIOS ScreenCaptureKit writer error=\(error.localizedDescription)")
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer) throws {
        if writer == nil {
            guard let outputURL,
                  let formatDescription = sampleBuffer.formatDescription else {
                throw ScreenCaptureAudioError.writerFailed
            }
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .caf)
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: formatDescription
            )
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw ScreenCaptureAudioError.writerFailed }
            writer.add(input)
            guard writer.startWriting() else {
                throw writer.error ?? ScreenCaptureAudioError.writerFailed
            }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            self.writer = writer
            writerInput = input
        }

        guard let writer, let writerInput else { throw ScreenCaptureAudioError.writerFailed }
        guard writer.status == .writing else {
            throw writer.error ?? ScreenCaptureAudioError.writerFailed
        }
        if writerInput.isReadyForMoreMediaData {
            guard writerInput.append(sampleBuffer) else {
                throw writer.error ?? ScreenCaptureAudioError.writerFailed
            }
            sampleBufferCount += 1
        }
    }

    private func resolveStart(_ result: Result<Void, Error>) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let continuation = self.startContinuation else { return }
            self.startContinuation = nil
            switch result {
            case .success:
                continuation.resume()
            case let .failure(error):
                continuation.resume(throwing: error)
            }
        }
    }
}

@available(iOS 27.0, *)
enum ScreenCaptureAudioError: LocalizedError {
    case unavailable
    case cancelled
    case noAudioSamples
    case writerFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "ScreenCaptureKit is unavailable on this device."
        case .cancelled:
            return "ScreenCaptureKit picker was cancelled."
        case .noAudioSamples:
            return "ScreenCaptureKit produced no audio samples."
        case .writerFailed:
            return "ScreenCaptureKit audio writer failed."
        }
    }
}
