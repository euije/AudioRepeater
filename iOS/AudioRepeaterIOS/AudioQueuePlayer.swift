import AVFoundation
import AudioToolbox
import Darwin
import SwiftUI
import UIKit

enum PlaybackPath: String, Codable, CaseIterable {
    case avAudioEngine
    case remoteIO
}

enum PlaybackState: Equatable {
    case idle
    case preparing(message: String)
    case playing(
        itemKey: String,
        displayName: String,
        currentRepeat: Int,
        totalRepeats: Int
    )

    var isRunning: Bool {
        self != .idle
    }

    var statusText: String {
        switch self {
        case .idle:
            return "대기"
        case let .preparing(message):
            return message
        case let .playing(_, displayName, currentRepeat, totalRepeats):
            return "\(displayName) · \(currentRepeat)/\(totalRepeats)회"
        }
    }
}

private struct PlaybackProgressEvent {
    let startFrame: AVAudioFramePosition
    let item: QueueItem
    let repeatIndex: Int
}

@MainActor
final class AudioQueuePlayer: ObservableObject {
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var errorMessage: String?

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var remoteIOPlayer: RemoteIOPlayer?
    private var screenCaptureRecorder: AnyObject?
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
        playbackPath: PlaybackPath = .avAudioEngine,
        systemAudioCaptureURL: URL? = nil,
        eventLogURL: URL? = nil
    ) {
        stop()
        guard !items.isEmpty else { return }
        errorMessage = nil

        runID += 1
        let activeRunID = runID

        playbackTask = Task { [weak self] in
            guard let self else { return }
            await self.runPlayback(
                runID: activeRunID,
                items: items,
                sameFileDelaySeconds: sameFileDelaySeconds,
                differentFileDelaySeconds: differentFileDelaySeconds,
                playbackPath: playbackPath,
                systemAudioCaptureURL: systemAudioCaptureURL,
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
        playbackPath: PlaybackPath,
        systemAudioCaptureURL: URL?,
        eventLogURL: URL?
    ) async {
        var stopped = false

        do {
            prepareEventLog(at: eventLogURL)
            recordEvent(
                "AudioRepeaterIOS playQueue start items=\(items.count) sameDelay=\(sameFileDelaySeconds) diffDelay=\(differentFileDelaySeconds) path=\(playbackPath.rawValue) captureSystemAudio=\(systemAudioCaptureURL != nil) displayIdleTimerDisabled=\(UIApplication.shared.isIdleTimerDisabled)",
                to: eventLogURL
            )

            // On iOS, activate the playback session before constructing the
            // ScreenCaptureKit stream. Otherwise an audio-only in-app stream
            // can start successfully but never vend audio sample buffers.
            try configureAudioSession()

            if let systemAudioCaptureURL {
                guard #available(iOS 27.0, *) else {
                    throw AudioQueueError.screenCaptureUnavailable
                }
                let recorder = ScreenCaptureAudioRecorder()
                screenCaptureRecorder = recorder
                try await recorder.start(outputURL: systemAudioCaptureURL) { [weak self] message in
                    self?.recordEvent(message, to: eventLogURL)
                }
            }

            let route = AVAudioSession.sharedInstance().currentRoute.outputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
            let session = AVAudioSession.sharedInstance()
            recordEvent(
                "AudioRepeaterIOS route outputs=\(route) outputVolume=\(session.outputVolume) sampleRate=\(session.sampleRate) ioBufferDuration=\(session.ioBufferDuration)",
                to: eventLogURL
            )
            guard session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) else {
                throw AudioQueueError.unexpectedOutputRoute(route)
            }

            let totalScheduledFrames: AVAudioFramePosition
            switch playbackPath {
            case .avAudioEngine:
                totalScheduledFrames = try await runAVAudioEngine(
                    items: items,
                    sameFileDelaySeconds: sameFileDelaySeconds,
                    differentFileDelaySeconds: differentFileDelaySeconds,
                    eventLogURL: eventLogURL
                )
            case .remoteIO:
                totalScheduledFrames = try await runRemoteIO(
                    items: items,
                    sameFileDelaySeconds: sameFileDelaySeconds,
                    differentFileDelaySeconds: differentFileDelaySeconds,
                    eventLogURL: eventLogURL
                )
            }

            if #available(iOS 27.0, *), let recorder = screenCaptureRecorder as? ScreenCaptureAudioRecorder {
                try await recorder.stop()
                screenCaptureRecorder = nil
            }
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
        remoteIOPlayer?.stop()
        engine = nil
        playerNode = nil
        remoteIOPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func runAVAudioEngine(
        items: [QueueItem],
        sameFileDelaySeconds: Double,
        differentFileDelaySeconds: Double,
        eventLogURL: URL?
    ) async throws -> AVAudioFramePosition {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.playerNode = playerNode

        var totalScheduledFrames: AVAudioFramePosition = 0
        var progressEvents: [PlaybackProgressEvent] = []
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
                progressEvents.append(
                    PlaybackProgressEvent(
                        startFrame: totalScheduledFrames,
                        item: item,
                        repeatIndex: repeatIndex
                    )
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
            recordEvent("AudioRepeaterIOS stream scheduled file=\(item.displayName) frames=\(itemFrames)", to: eventLogURL)
            if itemIndex < items.count - 1, differentFileDelaySeconds > 0 {
                let silence = makeSilenceBuffer(duration: differentFileDelaySeconds)
                playerNode.scheduleBuffer(silence, completionHandler: nil)
                totalScheduledFrames += AVAudioFramePosition(silence.frameLength)
            }
        }
        playerNode.play()
        try await trackPlaybackProgress(
            progressEvents,
            totalFrames: totalScheduledFrames,
            eventLogURL: eventLogURL
        )
        return totalScheduledFrames
    }

    private func runRemoteIO(
        items: [QueueItem],
        sameFileDelaySeconds: Double,
        differentFileDelaySeconds: Double,
        eventLogURL: URL?
    ) async throws -> AVAudioFramePosition {
        var samples: [Float] = []
        var totalScheduledFrames: AVAudioFramePosition = 0
        var progressEvents: [PlaybackProgressEvent] = []
        for (itemIndex, item) in items.enumerated() {
            try Task.checkCancellation()
            let audioBuffer = try loadBuffer(from: item.localURL)
            guard let channel = audioBuffer.floatChannelData?[0] else {
                throw AudioQueueError.bufferAllocationFailed
            }
            let frameCount = Int(audioBuffer.frameLength)
            let payload = Array(UnsafeBufferPointer(start: channel, count: frameCount))
            recordEvent(
                "AudioRepeaterIOS PCM ready file=\(item.displayName) sampleRate=\(audioBuffer.format.sampleRate) frames=\(audioBuffer.frameLength)",
                to: eventLogURL
            )
            var itemFrames: AVAudioFramePosition = 0
            for repeatIndex in 0..<item.repeatCount {
                try Task.checkCancellation()
                progressEvents.append(
                    PlaybackProgressEvent(
                        startFrame: totalScheduledFrames,
                        item: item,
                        repeatIndex: repeatIndex
                    )
                )
                samples.append(contentsOf: payload)
                itemFrames += AVAudioFramePosition(frameCount)
                totalScheduledFrames += AVAudioFramePosition(frameCount)
                if repeatIndex < item.repeatCount - 1, sameFileDelaySeconds > 0 {
                    let silenceFrames = Int(sameFileDelaySeconds * playbackFormat.sampleRate)
                    samples.append(contentsOf: repeatElement(0, count: silenceFrames))
                    itemFrames += AVAudioFramePosition(silenceFrames)
                    totalScheduledFrames += AVAudioFramePosition(silenceFrames)
                }
            }
            recordEvent("AudioRepeaterIOS stream scheduled file=\(item.displayName) frames=\(itemFrames)", to: eventLogURL)
            if itemIndex < items.count - 1, differentFileDelaySeconds > 0 {
                let silenceFrames = Int(differentFileDelaySeconds * playbackFormat.sampleRate)
                samples.append(contentsOf: repeatElement(0, count: silenceFrames))
                totalScheduledFrames += AVAudioFramePosition(silenceFrames)
            }
        }
        let player = try RemoteIOPlayer(samples: samples, sampleRate: playbackFormat.sampleRate)
        remoteIOPlayer = player
        recordEvent("AudioRepeaterIOS RemoteIO initialized format=float32_mono_noninterleaved", to: eventLogURL)
        try player.start()
        try await trackPlaybackProgress(
            progressEvents,
            totalFrames: totalScheduledFrames,
            eventLogURL: eventLogURL
        )
        player.stop()
        return totalScheduledFrames
    }

    private func updateStateAndLog(item: QueueItem, repeatIndex: Int, eventLogURL: URL?) {
        let currentRepeat = repeatIndex + 1
        state = .playing(
            itemKey: item.itemKey,
            displayName: item.displayName,
            currentRepeat: currentRepeat,
            totalRepeats: item.repeatCount
        )
        recordEvent(
            "AudioRepeaterIOS repeat queue file=\(item.displayName) repeat=\(currentRepeat)/\(item.repeatCount)",
            to: eventLogURL
        )
    }

    private func trackPlaybackProgress(
        _ events: [PlaybackProgressEvent],
        totalFrames: AVAudioFramePosition,
        eventLogURL: URL?
    ) async throws {
        var elapsedFrames: AVAudioFramePosition = 0
        for event in events {
            let waitFrames = max(0, event.startFrame - elapsedFrames)
            if waitFrames > 0 {
                try await sleepForFrames(waitFrames)
            }
            updateStateAndLog(
                item: event.item,
                repeatIndex: event.repeatIndex,
                eventLogURL: eventLogURL
            )
            elapsedFrames = event.startFrame
        }

        let remainingFrames = max(0, totalFrames - elapsedFrames)
        if remainingFrames > 0 {
            try await sleepForFrames(
                remainingFrames,
                completionPadding: 0.25
            )
        }
    }

    private func sleepForFrames(
        _ frames: AVAudioFramePosition,
        completionPadding: Double = 0
    ) async throws {
        let seconds =
            Double(frames) / playbackFormat.sampleRate + completionPadding
        try await Task.sleep(
            nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)
        )
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
    case screenCaptureUnavailable
    case unexpectedOutputRoute(String)

    var errorDescription: String? {
        switch self {
        case .bufferAllocationFailed:
            return "오디오 버퍼를 만들 수 없습니다."
        case .conversionFailed:
            return "오디오 형식을 변환할 수 없습니다."
        case .screenCaptureUnavailable:
            return "이 iOS 버전에서는 ScreenCaptureKit 오디오 캡처를 사용할 수 없습니다."
        case let .unexpectedOutputRoute(route):
            return "내장 스피커가 아닌 출력 경로가 선택되었습니다: \(route)"
        }
    }
}
