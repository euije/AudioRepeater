import AVFoundation
import Darwin
import SwiftUI

enum PlaybackState: Equatable {
    case idle
    case playing(displayName: String, currentRepeat: Int, totalRepeats: Int)

    var isRunning: Bool {
        self != .idle
    }

    var statusText: String {
        switch self {
        case .idle:
            return "대기"
        case let .playing(displayName, currentRepeat, totalRepeats):
            return "\(displayName) · \(currentRepeat)/\(totalRepeats)회"
        }
    }
}

@MainActor
final class AudioQueuePlayer: ObservableObject {
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var errorMessage: String?

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var playbackTask: Task<Void, Never>?
    private var runID = 0

    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    func play(
        items: [QueueItem],
        sameFileDelaySeconds: Double,
        differentFileDelaySeconds: Double,
        eventLogURL: URL? = nil
    ) {
        stop()
        guard !items.isEmpty else { return }

        runID += 1
        let activeRunID = runID

        playbackTask = Task { [weak self] in
            guard let self else { return }
            await self.runPlayback(
                runID: activeRunID,
                items: items,
                sameFileDelaySeconds: sameFileDelaySeconds,
                differentFileDelaySeconds: differentFileDelaySeconds,
                eventLogURL: eventLogURL
            )
        }
    }

    func stop() {
        runID += 1
        playbackTask?.cancel()
        playbackTask = nil
        stopEngine()
        state = .idle
    }

    private func runPlayback(
        runID activeRunID: Int,
        items: [QueueItem],
        sameFileDelaySeconds: Double,
        differentFileDelaySeconds: Double,
        eventLogURL: URL?
    ) async {
        var stopped = false

        do {
            prepareEventLog(at: eventLogURL)
            recordEvent(
                "AudioRepeaterIOS playQueue start items=\(items.count) sameDelay=\(sameFileDelaySeconds) diffDelay=\(differentFileDelaySeconds)",
                to: eventLogURL
            )

            try configureAudioSession()
            let engine = AVAudioEngine()
            let playerNode = AVAudioPlayerNode()
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
            engine.prepare()
            try engine.start()

            self.engine = engine
            self.playerNode = playerNode

            var totalScheduledFrames: AVAudioFramePosition = 0

            for (itemIndex, item) in items.enumerated() {
                try Task.checkCancellation()
                let audioBuffer = try loadBuffer(from: item.localURL)
                recordEvent(
                    "AudioRepeaterIOS PCM ready file=\(item.displayName) sampleRate=\(audioBuffer.format.sampleRate) frames=\(audioBuffer.frameLength)",
                    to: eventLogURL
                )

                var itemFrames: AVAudioFramePosition = 0
                for repeatIndex in 0..<item.repeatCount {
                    try Task.checkCancellation()
                    let currentRepeat = repeatIndex + 1
                    state = .playing(
                        displayName: item.displayName,
                        currentRepeat: currentRepeat,
                        totalRepeats: item.repeatCount
                    )
                    recordEvent(
                        "AudioRepeaterIOS repeat queue file=\(item.displayName) repeat=\(currentRepeat)/\(item.repeatCount)",
                        to: eventLogURL
                    )

                    playerNode.scheduleBuffer(audioBuffer, completionHandler: nil)
                    itemFrames += AVAudioFramePosition(audioBuffer.frameLength)
                    totalScheduledFrames += AVAudioFramePosition(audioBuffer.frameLength)

                    if repeatIndex < item.repeatCount - 1, sameFileDelaySeconds > 0 {
                        let silence = makeSilenceBuffer(duration: sameFileDelaySeconds)
                        playerNode.scheduleBuffer(silence, completionHandler: nil)
                        itemFrames += AVAudioFramePosition(silence.frameLength)
                        totalScheduledFrames += AVAudioFramePosition(silence.frameLength)
                    }
                }

                recordEvent(
                    "AudioRepeaterIOS stream scheduled file=\(item.displayName) frames=\(itemFrames)",
                    to: eventLogURL
                )

                if itemIndex < items.count - 1, differentFileDelaySeconds > 0 {
                    let silence = makeSilenceBuffer(duration: differentFileDelaySeconds)
                    playerNode.scheduleBuffer(silence, completionHandler: nil)
                    totalScheduledFrames += AVAudioFramePosition(silence.frameLength)
                }
            }

            playerNode.play()
            let totalSeconds = Double(totalScheduledFrames) / playbackFormat.sampleRate
            try await Task.sleep(nanoseconds: UInt64((totalSeconds + 0.25) * 1_000_000_000))
            recordEvent(
                "AudioRepeaterIOS playQueue finish stopped=false framesScheduled=\(totalScheduledFrames)",
                to: eventLogURL
            )
        } catch is CancellationError {
            stopped = true
            recordEvent("AudioRepeaterIOS playQueue finish stopped=true", to: eventLogURL)
        } catch {
            stopped = true
            errorMessage = error.localizedDescription
            recordEvent("AudioRepeaterIOS playQueue error \(error.localizedDescription)", to: eventLogURL)
        }

        if activeRunID == runID || !stopped {
            stopEngine()
            playbackTask = nil
            state = .idle
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }

    private func stopEngine() {
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func loadBuffer(from url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw AudioQueueError.bufferAllocationFailed
        }

        try file.read(into: sourceBuffer)
        return try convert(sourceBuffer, to: playbackFormat)
    }

    private func convert(_ sourceBuffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let sourceFormat = sourceBuffer.format
        let sampleRateRatio = outputFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * sampleRateRatio) + 32

        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw AudioQueueError.bufferAllocationFailed
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if didProvideInput {
                inputStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }

        if status == .error {
            throw conversionError ?? AudioQueueError.conversionFailed
        }

        return outputBuffer
    }

    private func makeSilenceBuffer(duration: Double) -> AVAudioPCMBuffer {
        let frameCount = max(1, AVAudioFrameCount(duration * playbackFormat.sampleRate))
        let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(playbackFormat.channelCount) {
                memset(channels[channel], 0, Int(frameCount) * MemoryLayout<Float>.size)
            }
        }

        return buffer
    }

    private func prepareEventLog(at url: URL?) {
        guard let url else { return }
        try? Data().write(to: url, options: .atomic)
    }

    private func recordEvent(_ message: String, to url: URL?) {
        print(message)
        guard let url, let data = (message + "\n").data(using: .utf8) else { return }

        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    }
}

enum AudioQueueError: LocalizedError {
    case bufferAllocationFailed
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .bufferAllocationFailed:
            return "오디오 버퍼를 만들 수 없습니다."
        case .conversionFailed:
            return "오디오 형식을 변환할 수 없습니다."
        }
    }
}
