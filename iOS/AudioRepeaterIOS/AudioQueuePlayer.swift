import AVFoundation
import AudioToolbox
import Darwin
import MediaPlayer
import SwiftUI
import UIKit

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
            return "Idle"
        case let .preparing(message):
            return message
        case let .playing(_, displayName, currentRepeat, totalRepeats):
            return "\(displayName) · \(currentRepeat)/\(totalRepeats)"
        }
    }
}

private struct PlaybackProgressEvent {
    let startFrame: AVAudioFramePosition
    let item: QueueItem
    let repeatIndex: Int
}

@MainActor
final class AudioQueuePlayer: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var recordingStatus = "Not recording"
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var outputDescription = "Output follows the selected audio session"

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var remoteIOPlayer: RemoteIOPlayer?
    private var microphoneRecorder: AVAudioRecorder?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var systemVolumeView: MPVolumeView?
    private var playbackTask: Task<Void, Never>?
    private var runID = 0

    override init() {
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in self?.stop() }
        }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                self?.updateOutputDescription()
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.stop() }
            }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    private let stereoPlaybackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!

    func play(
        items: [QueueItem],
        sameFileDelaySeconds: Double,
        differentFileDelaySeconds: Double,
        playbackPath: PlaybackPath = .avAudioEngine,
        avAudioEnginePan: Float = 0,
        avAudioEngineGain: Float = 1,
        avAudioEngineDirectPCM: Bool = false,
        avAudioEngineIsolateSignals: Bool = false,
        avAudioEngineEQFrequency: Float = 3_330,
        avAudioEngineEQGain: Float = 0,
        avAudioEngineEQBandwidth: Float = 0.5,
        avAudioEngineAutomaticFormat: Bool = false,
        avAudioEngineCompletionCallback: String = "playedBack",
        avAudioEngineStopPlayerEachSignal: Bool = false,
        avAudioEngineCompletionDelayFrames: Int = 0,
        avAudioEngineStereoMode: String = "mono",
        preferredIOBufferDuration: Double = 0,
        forceMaximumOutputVolume: Bool = false,
        avAudioSessionMode: String = "default",
        systemAudioCaptureURL: URL? = nil,
        eventLogURL: URL? = nil,
        processing: PlaybackSettings? = nil,
        microphoneRecordingURL: URL? = nil
    ) {
        guard !state.isRunning else { return }
        cancelCurrentPlayback(deactivateAudioSession: false)
        guard !items.isEmpty else { return }
        errorMessage = nil
        state = .preparing(message: "Preparing playback")

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
                avAudioEnginePan: avAudioEnginePan,
                avAudioEngineGain: avAudioEngineGain,
                avAudioEngineDirectPCM: avAudioEngineDirectPCM,
                avAudioEngineIsolateSignals:
                    avAudioEngineIsolateSignals,
                avAudioEngineEQFrequency: avAudioEngineEQFrequency,
                avAudioEngineEQGain: avAudioEngineEQGain,
                avAudioEngineEQBandwidth: avAudioEngineEQBandwidth,
                avAudioEngineAutomaticFormat:
                    avAudioEngineAutomaticFormat,
                avAudioEngineCompletionCallback:
                    avAudioEngineCompletionCallback,
                avAudioEngineStopPlayerEachSignal:
                    avAudioEngineStopPlayerEachSignal,
                avAudioEngineCompletionDelayFrames:
                    avAudioEngineCompletionDelayFrames,
                avAudioEngineStereoMode:
                    avAudioEngineStereoMode,
                preferredIOBufferDuration:
                    preferredIOBufferDuration,
                forceMaximumOutputVolume:
                    forceMaximumOutputVolume,
                avAudioSessionMode: avAudioSessionMode,
                systemAudioCaptureURL: systemAudioCaptureURL,
                eventLogURL: eventLogURL,
                processing: processing,
                microphoneRecordingURL: microphoneRecordingURL
            )
        }
    }

    func stop() {
        guard state.isRunning else { return }
        state = .preparing(message: "Stopping playback")
        playbackTask?.cancel()
        stopMicrophoneRecording()
        // Stop callbacks release pending scheduled-buffer continuations.
        stopEngine(deactivateAudioSession: false)
    }

    private func cancelCurrentPlayback(deactivateAudioSession: Bool) {
        runID += 1
        playbackTask?.cancel()
        playbackTask = nil
        stopEngine(deactivateAudioSession: deactivateAudioSession)
        state = .idle
    }

    private func runPlayback(
        runID activeRunID: Int,
        items: [QueueItem],
        sameFileDelaySeconds: Double,
        differentFileDelaySeconds: Double,
        playbackPath: PlaybackPath,
        avAudioEnginePan: Float,
        avAudioEngineGain: Float,
        avAudioEngineDirectPCM: Bool,
        avAudioEngineIsolateSignals: Bool,
        avAudioEngineEQFrequency: Float,
        avAudioEngineEQGain: Float,
        avAudioEngineEQBandwidth: Float,
        avAudioEngineAutomaticFormat: Bool,
        avAudioEngineCompletionCallback: String,
        avAudioEngineStopPlayerEachSignal: Bool,
        avAudioEngineCompletionDelayFrames: Int,
        avAudioEngineStereoMode: String,
        preferredIOBufferDuration: Double,
        forceMaximumOutputVolume: Bool,
        avAudioSessionMode: String,
        systemAudioCaptureURL: URL?,
        eventLogURL: URL?,
        processing: PlaybackSettings?,
        microphoneRecordingURL: URL?
    ) async {
        var captureRecorder: AnyObject?

        do {
            try processing?.validate()
            if microphoneRecordingURL != nil {
                let granted = await withCheckedContinuation { continuation in
                    AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
                }
                try Task.checkCancellation()
                guard granted else { throw PlaybackSettingsError.microphoneDenied }
            }
            prepareEventLog(at: eventLogURL)
            if let processing {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let json = String(decoding: try encoder.encode(processing), as: UTF8.self)
                recordEvent("AudioRepeaterIOS processing=\(json) activeEffect=\(processing.activeEffect.rawValue) effectiveMode=\(processing.effectiveSessionMode.rawValue)", to: eventLogURL)
            }
            recordEvent(
                "AudioRepeaterIOS playQueue start items=\(items.count) sameDelay=\(sameFileDelaySeconds) diffDelay=\(differentFileDelaySeconds) path=\(playbackPath.rawValue) pan=\(avAudioEnginePan) gain=\(avAudioEngineGain) directPCM=\(avAudioEngineDirectPCM) isolateSignals=\(avAudioEngineIsolateSignals) eqFrequency=\(avAudioEngineEQFrequency) eqGain=\(avAudioEngineEQGain) eqBandwidth=\(avAudioEngineEQBandwidth) automaticFormat=\(avAudioEngineAutomaticFormat) completionCallback=\(avAudioEngineCompletionCallback) stopEachSignal=\(avAudioEngineStopPlayerEachSignal) completionDelayFrames=\(avAudioEngineCompletionDelayFrames) stereoMode=\(avAudioEngineStereoMode) ioBuffer=\(preferredIOBufferDuration) forceMaxVolume=\(forceMaximumOutputVolume) mode=\(avAudioSessionMode) captureSystemAudio=\(systemAudioCaptureURL != nil) displayIdleTimerDisabled=\(UIApplication.shared.isIdleTimerDisabled)",
                to: eventLogURL
            )

            // On iOS, activate the playback session before constructing the
            // ScreenCaptureKit stream. Otherwise an audio-only in-app stream
            // can start successfully but never vend audio sample buffers.
            try await configureAudioSession(
                modeName: avAudioSessionMode,
                preferredIOBufferDuration:
                    preferredIOBufferDuration,
                forceMaximumOutputVolume:
                    forceMaximumOutputVolume,
                eventLogURL: eventLogURL,
                processing: processing,
                recording: microphoneRecordingURL != nil
            )

            try Task.checkCancellation()
            if let microphoneRecordingURL { try startMicrophoneRecording(at: microphoneRecordingURL) }

            if let systemAudioCaptureURL {
                guard #available(iOS 27.0, *) else {
                    throw AudioQueueError.screenCaptureUnavailable
                }
                let recorder = ScreenCaptureAudioRecorder()
                captureRecorder = recorder
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
            try Task.checkCancellation()
            updateOutputDescription()
            if let processing {
                if processing.output == .speaker && !session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) {
                    throw PlaybackSettingsError.outputUnavailable("Speaker (\(route))")
                }
                if processing.output == .receiver && !session.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) {
                    throw PlaybackSettingsError.outputUnavailable("Receiver (\(route))")
                }
            } else if !session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) {
                // Legacy measurement requests retain their speaker-only contract.
                throw AudioQueueError.unexpectedOutputRoute(route)
            }

            let totalScheduledFrames: AVAudioFramePosition
            switch playbackPath {
            case .avAudioEngine:
                totalScheduledFrames = try await runAVAudioEngine(
                    items: items,
                    sameFileDelaySeconds: sameFileDelaySeconds,
                    differentFileDelaySeconds: differentFileDelaySeconds,
                    pan: avAudioEnginePan,
                    gain: avAudioEngineGain,
                    directPCM: avAudioEngineDirectPCM,
                    isolateSignals: avAudioEngineIsolateSignals,
                    eqFrequency: avAudioEngineEQFrequency,
                    eqGain: avAudioEngineEQGain,
                    eqBandwidth: avAudioEngineEQBandwidth,
                    automaticFormat: avAudioEngineAutomaticFormat,
                    completionCallback:
                        avAudioEngineCompletionCallback,
                    stopPlayerEachSignal:
                        avAudioEngineStopPlayerEachSignal,
                    completionDelayFrames:
                        avAudioEngineCompletionDelayFrames,
                    stereoMode:
                        avAudioEngineStereoMode,
                    eventLogURL: eventLogURL,
                    processing: processing
                )
            case .remoteIO:
                totalScheduledFrames = try await runRemoteIO(
                    items: items,
                    sameFileDelaySeconds: sameFileDelaySeconds,
                    differentFileDelaySeconds: differentFileDelaySeconds,
                    eventLogURL: eventLogURL
                )
            }

            recordEvent(
                "AudioRepeaterIOS playQueue finish stopped=false framesScheduled=\(totalScheduledFrames)",
                to: eventLogURL
            )
        } catch is CancellationError {
            recordEvent("AudioRepeaterIOS playQueue finish stopped=true", to: eventLogURL)
        } catch {
            if activeRunID == runID {
                errorMessage = error.localizedDescription
            }
            recordEvent("AudioRepeaterIOS playQueue error \(error.localizedDescription)", to: eventLogURL)
        }

        if #available(iOS 27.0, *), let recorder = captureRecorder as? ScreenCaptureAudioRecorder {
            do { try await recorder.stop() }
            catch { if activeRunID == runID { errorMessage = error.localizedDescription } }
        }

        if activeRunID == runID {
            stopMicrophoneRecording()
            stopEngine()
            playbackTask = nil
            state = .idle
        }
    }

    private func configureAudioSession(
        modeName: String,
        preferredIOBufferDuration: Double,
        forceMaximumOutputVolume: Bool,
        eventLogURL: URL?,
        processing: PlaybackSettings?,
        recording: Bool
    ) async throws {
        // IOAudio2 can restart the speaker service while arming the ring.
        // AVAudioSession reports paramErr (-50) during that short handoff.
        // Keep the request in the same app process until the service is ready
        // instead of surfacing an error and requiring a relaunch.
        let maximumAttempts = 32
        var lastError: Error?

        for attempt in 1...maximumAttempts {
            try Task.checkCancellation()
            let session = AVAudioSession.sharedInstance()
            var stage = "setCategory"
            do {
                var mode: AVAudioSession.Mode
                var category: AVAudioSession.Category
                var categoryOptions: AVAudioSession.CategoryOptions
                switch modeName {
                case "measurement":
                    mode = .measurement
                    category = .playback
                    categoryOptions = []
                case "moviePlayback",
                     "moviePlayback44100",
                     "moviePlayback96000":
                    mode = .moviePlayback
                    category = .playback
                    categoryOptions = []
                case "spokenAudio":
                    mode = .spokenAudio
                    category = .playback
                    categoryOptions = []
                case "voicePrompt":
                    mode = .voicePrompt
                    category = .playback
                    categoryOptions = []
                case "voiceChat":
                    mode = .voiceChat
                    category = .playAndRecord
                    categoryOptions = [.defaultToSpeaker]
                case "videoChat":
                    mode = .videoChat
                    category = .playAndRecord
                    categoryOptions = [.defaultToSpeaker]
                case "gameChat":
                    mode = .gameChat
                    category = .playAndRecord
                    categoryOptions = [.defaultToSpeaker]
                case "videoRecording":
                    mode = .videoRecording
                    category = .playAndRecord
                    categoryOptions = [.defaultToSpeaker]
                case "playAndRecordDefault":
                    mode = .default
                    category = .playAndRecord
                    categoryOptions = [.defaultToSpeaker]
                case "ambientDefault":
                    mode = .default
                    category = .ambient
                    categoryOptions = []
                case "soloAmbientDefault":
                    mode = .default
                    category = .soloAmbient
                    categoryOptions = []
                default:
                    mode = .default
                    category = .playback
                    categoryOptions = []
                }
                if let processing {
                    switch processing.effectiveSessionMode {
                    case .default: mode = .default
                    case .measurement: mode = .measurement
                    case .moviePlayback: mode = .moviePlayback
                    case .spokenAudio: mode = .spokenAudio
                    case .voiceChat: mode = .voiceChat
                    case .videoChat: mode = .videoChat
                    }
                    category = processing.usesInputCategory || recording ? .playAndRecord : .playback
                    categoryOptions = category == .playAndRecord && processing.output == .system
                        ? [.allowBluetooth, .allowBluetoothA2DP] : []
                    if recording && processing.output == .system && !processing.sessionMode.requiresInput {
                        // Keep ordinary recording playback on the speaker unless an external route is connected.
                        categoryOptions.insert(.defaultToSpeaker)
                    }
                    if processing.output == .speaker { categoryOptions.insert(.defaultToSpeaker) }
                } else if recording {
                    category = .playAndRecord
                    mode = .measurement
                    categoryOptions = [.defaultToSpeaker]
                }
                try session.setCategory(
                    category,
                    mode: mode,
                    options: categoryOptions
                )
                stage = "setPreferredSampleRate"
                let preferredSampleRate: Double
                switch modeName {
                case "moviePlayback44100":
                    preferredSampleRate = 44_100
                case "moviePlayback96000":
                    preferredSampleRate = 96_000
                default:
                    preferredSampleRate = playbackFormat.sampleRate
                }
                try session.setPreferredSampleRate(preferredSampleRate)
                if preferredIOBufferDuration > 0 {
                    stage = "setPreferredIOBufferDuration"
                    try session.setPreferredIOBufferDuration(
                        preferredIOBufferDuration
                    )
                }
                stage = "setActive"
                try session.setActive(true)
                if category == .playAndRecord {
                    try session.overrideOutputAudioPort(processing?.output == .speaker ? .speaker : .none)
                    if recording, processing?.output != .system,
                       let input = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                        try session.setPreferredInput(input)
                    }
                }
                if forceMaximumOutputVolume,
                   session.outputVolume < 0.999 {
                    stage = "setMaximumOutputVolume"
                    let volumeView: MPVolumeView
                    if let existing = systemVolumeView {
                        volumeView = existing
                    } else {
                        volumeView = MPVolumeView(
                            frame: CGRect(
                                x: -100,
                                y: -100,
                                width: 1,
                                height: 1
                            )
                        )
                        volumeView.alpha = 0.01
                        let window = UIApplication.shared.connectedScenes
                            .compactMap { $0 as? UIWindowScene }
                            .flatMap(\.windows)
                            .first { $0.isKeyWindow }
                        window?.rootViewController?.view.addSubview(
                            volumeView
                        )
                        systemVolumeView = volumeView
                    }
                    guard let slider = volumeView.subviews.first(
                        where: { $0 is UISlider }
                    ) as? UISlider else {
                        throw AudioQueueError.audioSessionUnavailable
                    }
                    slider.setValue(1.0, animated: false)
                    slider.sendActions(for: .valueChanged)
                    try await Task.sleep(nanoseconds: 250_000_000)
                    recordEvent(
                        "AudioRepeaterIOS maximum output volume requested result=\(session.outputVolume)",
                        to: eventLogURL
                    )
                }
                recordEvent(
                    "AudioRepeaterIOS audio session ready attempt=\(attempt) mode=\(session.mode.rawValue) sampleRate=\(session.sampleRate)",
                    to: eventLogURL
                )
                return
            } catch {
                lastError = error
                guard attempt < maximumAttempts else { break }
                recordEvent(
                    "AudioRepeaterIOS audio session retry attempt=\(attempt)/\(maximumAttempts) stage=\(stage) error=\(error.localizedDescription)",
                    to: eventLogURL
                )
                try? session.setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
                let retryDelayNanoseconds = UInt64(
                    min(500, 150 + attempt * 25)
                ) * 1_000_000
                try await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }

        throw lastError ?? AudioQueueError.audioSessionUnavailable
    }

    private func stopEngine(deactivateAudioSession: Bool = true) {
        playerNode?.stop()
        engine?.stop()
        remoteIOPlayer?.stop()
        engine = nil
        playerNode = nil
        remoteIOPlayer = nil
        if deactivateAudioSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    private func updateOutputDescription() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute.outputs.map(\.portName).joined(separator: ", ")
        outputDescription = "\(route) · \(Int(session.sampleRate)) Hz · \(session.mode.rawValue)"
    }

    private func startMicrophoneRecording(at url: URL) throws {
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        recorder.delegate = self
        guard recorder.prepareToRecord(), recorder.record() else { throw PlaybackSettingsError.microphoneUnavailable }
        microphoneRecorder = recorder
        recordingStatus = "Recording microphone · 48 kHz mono PCM16 WAV"
    }

    private func stopMicrophoneRecording() {
        guard let recorder = microphoneRecorder else { return }
        recorder.stop()
        microphoneRecorder = nil
        if let file = try? AVAudioFile(forReading: recorder.url), file.length > 0 {
            lastRecordingURL = recorder.url
            recordingStatus = "Saved \(recorder.url.lastPathComponent)"
        } else {
            recordingStatus = "No microphone samples were saved"
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.microphoneRecorder === recorder else { return }
            self.errorMessage = error?.localizedDescription ?? "Microphone recording failed."
            self.stop()
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        Task { @MainActor [weak self] in
            guard let self, self.microphoneRecorder === recorder else { return }
            self.errorMessage = "Microphone recording ended before playback finished."
            self.stop()
        }
    }

    private func runAVAudioEngine(
        items: [QueueItem],
        sameFileDelaySeconds: Double,
        differentFileDelaySeconds: Double,
        pan: Float,
        gain: Float,
        directPCM: Bool,
        isolateSignals: Bool,
        eqFrequency: Float,
        eqGain: Float,
        eqBandwidth: Float,
        automaticFormat: Bool,
        completionCallback: String,
        stopPlayerEachSignal: Bool,
        completionDelayFrames: Int,
        stereoMode: String,
        eventLogURL: URL?,
        processing: PlaybackSettings?
    ) async throws -> AVAudioFramePosition {
        let (engine, playerNode) = try await startAVAudioEngine(
            eqFrequency: eqFrequency,
            eqGain: eqGain,
            eqBandwidth: eqBandwidth,
            automaticFormat: automaticFormat,
            stereoMode: stereoMode,
            eventLogURL: eventLogURL,
            processing: processing
        )
        self.engine = engine
        self.playerNode = playerNode
        playerNode.pan = pan
        playerNode.volume = gain
        recordEvent(
            "AudioRepeaterIOS AVAudioEngine pan=\(playerNode.pan) gain=\(playerNode.volume)",
            to: eventLogURL
        )

        var totalScheduledFrames: AVAudioFramePosition = 0
        var progressEvents: [PlaybackProgressEvent] = []
        var preparedItems: [(item: QueueItem, buffer: AVAudioPCMBuffer)] = []
        for (itemIndex, item) in items.enumerated() {
            try Task.checkCancellation()
            let audioBuffer = try loadBuffer(
                from: item.localURL,
                allowDirectPCM: directPCM,
                eventLogURL: eventLogURL
            )
            preparedItems.append((item, audioBuffer))
            recordEvent(
                "AudioRepeaterIOS PCM ready file=\(item.displayName) sampleRate=\(audioBuffer.format.sampleRate) frames=\(audioBuffer.frameLength)",
                to: eventLogURL
            )
            let signalFrames = AVAudioFramePosition(audioBuffer.frameLength)
            let sameDelayFrames = AVAudioFramePosition(
                max(0, Int(sameFileDelaySeconds * playbackFormat.sampleRate))
            )
            var itemFrames: AVAudioFramePosition = 0
            for repeatIndex in 0..<item.repeatCount {
                progressEvents.append(
                    PlaybackProgressEvent(
                        startFrame: totalScheduledFrames,
                        item: item,
                        repeatIndex: repeatIndex
                    )
                )
                itemFrames += signalFrames
                totalScheduledFrames += signalFrames
                if repeatIndex < item.repeatCount - 1 {
                    itemFrames += sameDelayFrames
                    totalScheduledFrames += sameDelayFrames
                }
            }
            if itemIndex < items.count - 1, differentFileDelaySeconds > 0 {
                totalScheduledFrames += AVAudioFramePosition(
                    max(0, Int(differentFileDelaySeconds * playbackFormat.sampleRate))
                )
            }
            recordEvent("AudioRepeaterIOS stream scheduled file=\(item.displayName) frames=\(itemFrames)", to: eventLogURL)
        }

        guard totalScheduledFrames > 0 else {
            throw AudioQueueError.bufferAllocationFailed
        }
        let signalBufferCount = preparedItems.reduce(0) {
            $0 + $1.item.repeatCount
        }
        let sameDelayBufferCount = preparedItems.reduce(0) {
            $0 + max(0, $1.item.repeatCount - 1)
        }
        let differentDelayBufferCount = max(0, preparedItems.count - 1)
        let scheduledBufferCount =
            signalBufferCount
            + sameDelayBufferCount
            + differentDelayBufferCount
        recordEvent(
            "AudioRepeaterIOS discrete queue ready frames=\(totalScheduledFrames) buffersScheduled=\(scheduledBufferCount)",
            to: eventLogURL
        )
        if isolateSignals {
            try await playIsolatedSignalsAndWait(
                preparedItems,
                engine: engine,
                playerNode: playerNode,
                sameFileDelaySeconds: sameFileDelaySeconds,
                differentFileDelaySeconds: differentFileDelaySeconds,
                completionCallback: completionCallback,
                eventLogURL: eventLogURL
            )
        } else if stopPlayerEachSignal {
            try await playStoppedSignalsAndWait(
                preparedItems,
                engine: engine,
                playerNode: playerNode,
                sameFileDelaySeconds: sameFileDelaySeconds,
                differentFileDelaySeconds: differentFileDelaySeconds,
                completionCallback: completionCallback,
                completionDelayFrames: completionDelayFrames,
                eventLogURL: eventLogURL
            )
        } else {
            async let progressTracking: Void = trackPlaybackProgress(
                progressEvents,
                totalFrames: totalScheduledFrames,
                eventLogURL: eventLogURL
            )
            try await playDiscreteQueueAndWait(
                preparedItems,
                playerNode: playerNode,
                sameFileDelaySeconds: sameFileDelaySeconds,
                differentFileDelaySeconds: differentFileDelaySeconds,
                completionCallback: completionCallback,
                eventLogURL: eventLogURL
            )
            try await progressTracking
        }
        return totalScheduledFrames
    }

    private func playIsolatedSignalsAndWait(
        _ preparedItems: [(item: QueueItem, buffer: AVAudioPCMBuffer)],
        engine: AVAudioEngine,
        playerNode: AVAudioPlayerNode,
        sameFileDelaySeconds: Double,
        differentFileDelaySeconds: Double,
        completionCallback: String,
        eventLogURL: URL?
    ) async throws {
        var audioSessionActive = true
        for (itemIndex, prepared) in preparedItems.enumerated() {
            for repeatIndex in 0..<prepared.item.repeatCount {
                try Task.checkCancellation()
                if !audioSessionActive {
                    try AVAudioSession.sharedInstance().setActive(true)
                    try engine.start()
                    audioSessionActive = true
                    recordEvent(
                        "AudioRepeaterIOS isolated audio session reactivated",
                        to: eventLogURL
                    )
                }
                updateStateAndLog(
                    item: prepared.item,
                    repeatIndex: repeatIndex,
                    eventLogURL: eventLogURL
                )
                await withCheckedContinuation {
                    (continuation: CheckedContinuation<Void, Never>) in
                    playerNode.scheduleBuffer(
                        prepared.buffer,
                        completionCallbackType:
                            completionCallbackType(
                                named: completionCallback
                            )
                    ) { _ in
                        continuation.resume()
                    }
                    playerNode.play()
                }
                playerNode.stop()
                let isFinalSignal =
                    itemIndex == preparedItems.count - 1
                    && repeatIndex == prepared.item.repeatCount - 1
                if !isFinalSignal {
                    engine.pause()
                    try AVAudioSession.sharedInstance().setActive(false)
                    audioSessionActive = false
                    recordEvent(
                        "AudioRepeaterIOS isolated audio session deactivated",
                        to: eventLogURL
                    )
                }
                if repeatIndex < prepared.item.repeatCount - 1 {
                    try await sleepForSeconds(sameFileDelaySeconds)
                }
            }
            if itemIndex < preparedItems.count - 1 {
                try await sleepForSeconds(differentFileDelaySeconds)
            }
        }
        recordEvent(
            "AudioRepeaterIOS isolated signals played back",
            to: eventLogURL
        )
    }

    private func playStoppedSignalsAndWait(
        _ preparedItems: [(item: QueueItem, buffer: AVAudioPCMBuffer)],
        engine: AVAudioEngine,
        playerNode: AVAudioPlayerNode,
        sameFileDelaySeconds: Double,
        differentFileDelaySeconds: Double,
        completionCallback: String,
        completionDelayFrames: Int,
        eventLogURL: URL?
    ) async throws {
        let controlDelaySeconds =
            Double(completionDelayFrames) / playbackFormat.sampleRate
        for (itemIndex, prepared) in preparedItems.enumerated() {
            for repeatIndex in 0..<prepared.item.repeatCount {
                try Task.checkCancellation()
                if !engine.isRunning {
                    try engine.start()
                }
                updateStateAndLog(
                    item: prepared.item,
                    repeatIndex: repeatIndex,
                    eventLogURL: eventLogURL
                )
                await withCheckedContinuation {
                    (continuation: CheckedContinuation<Void, Never>) in
                    if completionDelayFrames > 0 {
                        playerNode.scheduleBuffer(
                            prepared.buffer,
                            completionHandler: nil
                        )
                        playerNode.scheduleBuffer(
                            makeSilenceBuffer(
                                frameCount: AVAudioFrameCount(
                                    completionDelayFrames
                                ),
                                format: prepared.buffer.format
                            ),
                            completionCallbackType:
                                completionCallbackType(
                                    named: completionCallback
                                )
                        ) { _ in
                            continuation.resume()
                        }
                    } else {
                        playerNode.scheduleBuffer(
                            prepared.buffer,
                            completionCallbackType:
                                completionCallbackType(
                                    named: completionCallback
                                )
                        ) { _ in
                            continuation.resume()
                        }
                    }
                    playerNode.play()
                }
                playerNode.stop()
                engine.stop()
                if repeatIndex < prepared.item.repeatCount - 1 {
                    try await sleepForSeconds(
                        max(
                            0,
                            sameFileDelaySeconds - controlDelaySeconds
                        )
                    )
                }
            }
            if itemIndex < preparedItems.count - 1 {
                try await sleepForSeconds(
                    max(
                        0,
                        differentFileDelaySeconds - controlDelaySeconds
                    )
                )
            }
        }
        recordEvent(
            "AudioRepeaterIOS stopped signals completion callback=\(completionCallback) delayFrames=\(completionDelayFrames)",
            to: eventLogURL
        )
    }

    private func playDiscreteQueueAndWait(
        _ preparedItems: [(item: QueueItem, buffer: AVAudioPCMBuffer)],
        playerNode: AVAudioPlayerNode,
        sameFileDelaySeconds: Double,
        differentFileDelaySeconds: Double,
        completionCallback: String,
        eventLogURL: URL?
    ) async throws {
        try Task.checkCancellation()
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            for (itemIndex, prepared) in preparedItems.enumerated() {
                for repeatIndex in 0..<prepared.item.repeatCount {
                    let isFinalSignal =
                        itemIndex == preparedItems.count - 1
                        && repeatIndex == prepared.item.repeatCount - 1
                    if isFinalSignal {
                        playerNode.scheduleBuffer(
                            prepared.buffer,
                            completionCallbackType:
                                completionCallbackType(
                                    named: completionCallback
                                )
                        ) { _ in
                            continuation.resume()
                        }
                    } else {
                        playerNode.scheduleBuffer(
                            prepared.buffer,
                            completionHandler: nil
                        )
                    }
                    if repeatIndex < prepared.item.repeatCount - 1 {
                        playerNode.scheduleBuffer(
                            makeSilenceBuffer(
                                duration: sameFileDelaySeconds,
                                format: prepared.buffer.format
                            ),
                            completionHandler: nil
                        )
                    }
                }
                if itemIndex < preparedItems.count - 1 {
                    playerNode.scheduleBuffer(
                        makeSilenceBuffer(
                            duration: differentFileDelaySeconds,
                            format: prepared.buffer.format
                        ),
                        completionHandler: nil
                    )
                }
            }
            playerNode.play()
        }
        try Task.checkCancellation()
        recordEvent(
            "AudioRepeaterIOS discrete queue completion callback=\(completionCallback)",
            to: eventLogURL
        )
    }

    private func completionCallbackType(
        named name: String
    ) -> AVAudioPlayerNodeCompletionCallbackType {
        switch name {
        case "consumed":
            return .dataConsumed
        case "rendered":
            return .dataRendered
        default:
            return .dataPlayedBack
        }
    }

    private func startAVAudioEngine(
        eqFrequency: Float,
        eqGain: Float,
        eqBandwidth: Float,
        automaticFormat: Bool,
        stereoMode: String,
        eventLogURL: URL?,
        processing: PlaybackSettings?
    ) async throws -> (AVAudioEngine, AVAudioPlayerNode) {
        let maximumAttempts = 4
        var lastError: Error?

        for attempt in 1...maximumAttempts {
            try Task.checkCancellation()
            let engine = AVAudioEngine()
            let playerNode = AVAudioPlayerNode()
            engine.attach(playerNode)
            if let processing {
                try PlaybackEffects.connect(player: playerNode, engine: engine, format: playbackFormat, settings: processing)
            } else if eqGain == 0 {
                engine.connect(
                    playerNode,
                    to: engine.mainMixerNode,
                    format: automaticFormat ? nil : playbackFormat
                )
            } else {
                let equalizer = AVAudioUnitEQ(numberOfBands: 1)
                let band = equalizer.bands[0]
                band.filterType = .parametric
                band.frequency = eqFrequency
                band.bandwidth = eqBandwidth
                band.gain = eqGain
                band.bypass = false
                engine.attach(equalizer)
                engine.connect(
                    playerNode,
                    to: equalizer,
                    format: automaticFormat ? nil : playbackFormat
                )
                engine.connect(
                    equalizer,
                    to: engine.mainMixerNode,
                    format: playbackFormat
                )
            }
            engine.prepare()

            do {
                try engine.start()
                recordEvent(
                    "AudioRepeaterIOS AVAudioEngine EQ frequency=\(eqFrequency) gain=\(eqGain) bandwidth=\(eqBandwidth)",
                    to: eventLogURL
                )
                recordEvent(
                    "AudioRepeaterIOS AVAudioEngine automatic format=\(automaticFormat)",
                    to: eventLogURL
                )
                recordEvent(
                    "AudioRepeaterIOS AVAudioEngine graph channels=\(playbackFormat.channelCount) requestedStereoMode=\(stereoMode)",
                    to: eventLogURL
                )
                recordEvent(
                    "AudioRepeaterIOS engine ready attempt=\(attempt)",
                    to: eventLogURL
                )
                return (engine, playerNode)
            } catch {
                lastError = error
                playerNode.stop()
                engine.stop()
                guard attempt < maximumAttempts else { break }
                recordEvent(
                    "AudioRepeaterIOS engine retry attempt=\(attempt)/\(maximumAttempts) error=\(error.localizedDescription)",
                    to: eventLogURL
                )
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }

        throw lastError ?? AudioQueueError.audioEngineUnavailable
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
            let audioBuffer = try loadBuffer(
                from: item.localURL,
                allowDirectPCM: false,
                eventLogURL: eventLogURL
            )
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

    private func sleepForSeconds(_ seconds: Double) async throws {
        try await Task.sleep(
            nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)
        )
    }

    private func loadBuffer(
        from url: URL,
        allowDirectPCM: Bool,
        eventLogURL: URL?
    ) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw AudioQueueError.bufferAllocationFailed
        }

        try file.read(into: sourceBuffer)
        if allowDirectPCM,
           sourceFormat.commonFormat == playbackFormat.commonFormat,
           sourceFormat.sampleRate == playbackFormat.sampleRate,
           sourceFormat.channelCount == playbackFormat.channelCount,
           sourceFormat.isInterleaved == playbackFormat.isInterleaved {
            recordEvent(
                "AudioRepeaterIOS PCM loader path=direct format=\(sourceFormat)",
                to: eventLogURL
            )
            return sourceBuffer
        }
        recordEvent(
            "AudioRepeaterIOS PCM loader path=converter source=\(sourceFormat) output=\(playbackFormat)",
            to: eventLogURL
        )
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

    private func makeSilenceBuffer(
        duration: Double,
        format: AVAudioFormat? = nil
    ) -> AVAudioPCMBuffer {
        let selectedFormat = format ?? playbackFormat
        let frameCount = max(
            1,
            AVAudioFrameCount(duration * selectedFormat.sampleRate)
        )
        return makeSilenceBuffer(
            frameCount: frameCount,
            format: selectedFormat
        )
    }

    private func makeSilenceBuffer(
        frameCount: AVAudioFrameCount,
        format: AVAudioFormat? = nil
    ) -> AVAudioPCMBuffer {
        let selectedFormat = format ?? playbackFormat
        let buffer = AVAudioPCMBuffer(
            pcmFormat: selectedFormat,
            frameCapacity: frameCount
        )!
        buffer.frameLength = frameCount

        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(selectedFormat.channelCount) {
                memset(channels[channel], 0, Int(frameCount) * MemoryLayout<Float>.size)
            }
        }

        return buffer
    }

    private func makePlaybackBuffer(
        from monoBuffer: AVAudioPCMBuffer,
        stereoMode: String
    ) -> AVAudioPCMBuffer {
        guard stereoMode != "mono" else {
            return monoBuffer
        }
        let frameCount = monoBuffer.frameLength
        let stereoBuffer = AVAudioPCMBuffer(
            pcmFormat: stereoPlaybackFormat,
            frameCapacity: frameCount
        )!
        stereoBuffer.frameLength = frameCount
        guard let source = monoBuffer.floatChannelData?[0],
              let channels = stereoBuffer.floatChannelData else {
            return monoBuffer
        }
        let rightGain: Float
        switch stereoMode {
        case "antiPhase":
            rightGain = -1
        case "left":
            rightGain = 0
        default:
            rightGain = 1
        }
        for frame in 0..<Int(frameCount) {
            channels[0][frame] = source[frame]
            channels[1][frame] =
                stereoMode == "right"
                ? source[frame]
                : rightGain * source[frame]
            if stereoMode == "right" {
                channels[0][frame] = 0
            }
        }
        return stereoBuffer
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
    case audioSessionUnavailable
    case audioEngineUnavailable
    case screenCaptureUnavailable
    case unexpectedOutputRoute(String)

    var errorDescription: String? {
        switch self {
        case .bufferAllocationFailed:
            return "Could not create an audio buffer."
        case .conversionFailed:
            return "Could not convert the audio format."
        case .audioSessionUnavailable:
            return "Could not prepare the audio session."
        case .audioEngineUnavailable:
            return "Could not start the audio engine."
        case .screenCaptureUnavailable:
            return "ScreenCaptureKit audio capture is unavailable on this iOS version."
        case let .unexpectedOutputRoute(route):
            return "The selected output is not the built-in speaker: \(route)"
        }
    }
}
