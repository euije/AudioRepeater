import Foundation

struct ResolvedRemotePlaybackRequest {
    let queueItems: [QueueItem]
    let sameFileDelaySeconds: Double
    let differentFileDelaySeconds: Double
    let playbackPath: PlaybackPath
    let avAudioEnginePan: Float
    let avAudioEngineGain: Float
    let avAudioEngineDirectPCM: Bool
    let avAudioEngineIsolateSignals: Bool
    let avAudioEngineEQFrequency: Float
    let avAudioEngineEQGain: Float
    let avAudioEngineEQBandwidth: Float
    let avAudioEngineAutomaticFormat: Bool
    let avAudioEngineCompletionCallback: String
    let avAudioEngineStopPlayerEachSignal: Bool
    let avAudioEngineCompletionDelayFrames: Int
    let avAudioEngineStereoMode: String
    let preferredIOBufferDuration: Double
    let forceMaximumOutputVolume: Bool
    let avAudioSessionMode: String
    let captureSystemAudio: Bool
    let systemAudioCaptureURL: URL?
    let eventLogURL: URL
}

enum RemotePlaybackRequestLoader {
    private struct Request: Decodable {
        struct File: Decodable {
            let fileName: String
            let displayName: String?
            let repeatCount: Int
        }

        let files: [File]
        let sameFileDelaySeconds: Double
        let differentFileDelaySeconds: Double
        let playbackPath: PlaybackPath?
        let avAudioEnginePan: Float?
        let avAudioEngineGain: Float?
        let avAudioEngineDirectPCM: Bool?
        let avAudioEngineIsolateSignals: Bool?
        let avAudioEngineEQFrequency: Float?
        let avAudioEngineEQGain: Float?
        let avAudioEngineEQBandwidth: Float?
        let avAudioEngineAutomaticFormat: Bool?
        let avAudioEngineCompletionCallback: String?
        let avAudioEngineStopPlayerEachSignal: Bool?
        let avAudioEngineCompletionDelayFrames: Int?
        let avAudioEngineStereoMode: String?
        let preferredIOBufferDuration: Double?
        let forceMaximumOutputVolume: Bool?
        let avAudioSessionMode: String?
        let captureSystemAudio: Bool?
        let systemAudioCaptureFileName: String?
    }

    private static let manifestName = "remote-playback.json"
    private static let audioDirectoryName = "RemoteAudio"

    static func consumeIfPresent() throws -> ResolvedRemotePlaybackRequest? {
        let fileManager = FileManager.default
        let documentsURL = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let manifestURL = documentsURL.appendingPathComponent(manifestName, isDirectory: false)

        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: manifestURL))
        guard !request.files.isEmpty else {
            throw RemotePlaybackRequestError.emptyFileList
        }
        guard isValidDelay(request.sameFileDelaySeconds),
              isValidDelay(request.differentFileDelaySeconds) else {
            throw RemotePlaybackRequestError.invalidDelay
        }
        let avAudioEnginePan = request.avAudioEnginePan ?? 0
        guard avAudioEnginePan.isFinite,
              (-1...1).contains(avAudioEnginePan) else {
            throw RemotePlaybackRequestError.invalidPan
        }
        let avAudioEngineGain = request.avAudioEngineGain ?? 1
        guard avAudioEngineGain.isFinite,
              (0.01...1).contains(avAudioEngineGain) else {
            throw RemotePlaybackRequestError.invalidGain
        }
        let avAudioSessionMode = request.avAudioSessionMode ?? "default"
        guard [
            "default",
            "measurement",
            "moviePlayback",
            "moviePlayback44100",
            "moviePlayback96000",
            "spokenAudio",
            "voicePrompt",
            "voiceChat",
            "videoChat",
            "gameChat",
            "videoRecording",
            "playAndRecordDefault",
            "ambientDefault",
            "soloAmbientDefault",
        ].contains(avAudioSessionMode) else {
            throw RemotePlaybackRequestError.invalidAudioSessionMode
        }
        let avAudioEngineEQFrequency =
            request.avAudioEngineEQFrequency ?? 3_330
        let avAudioEngineEQGain = request.avAudioEngineEQGain ?? 0
        let avAudioEngineEQBandwidth =
            request.avAudioEngineEQBandwidth ?? 0.5
        guard avAudioEngineEQFrequency.isFinite,
              (20...20_000).contains(avAudioEngineEQFrequency),
              avAudioEngineEQGain.isFinite,
              (-96...24).contains(avAudioEngineEQGain),
              avAudioEngineEQBandwidth.isFinite,
              (0.05...5).contains(avAudioEngineEQBandwidth) else {
            throw RemotePlaybackRequestError.invalidEQ
        }
        let avAudioEngineCompletionCallback =
            request.avAudioEngineCompletionCallback ?? "playedBack"
        guard ["playedBack", "rendered", "consumed"].contains(
            avAudioEngineCompletionCallback
        ) else {
            throw RemotePlaybackRequestError.invalidCompletionCallback
        }
        let avAudioEngineCompletionDelayFrames =
            request.avAudioEngineCompletionDelayFrames ?? 0
        guard (0...4_096).contains(
            avAudioEngineCompletionDelayFrames
        ) else {
            throw RemotePlaybackRequestError.invalidCompletionDelay
        }
        let avAudioEngineStereoMode =
            request.avAudioEngineStereoMode ?? "mono"
        guard ["mono", "dualMono", "antiPhase", "left", "right"].contains(
            avAudioEngineStereoMode
        ) else {
            throw RemotePlaybackRequestError.invalidStereoMode
        }
        let preferredIOBufferDuration =
            request.preferredIOBufferDuration ?? 0
        guard preferredIOBufferDuration.isFinite,
              (0...0.1).contains(preferredIOBufferDuration) else {
            throw RemotePlaybackRequestError.invalidIOBufferDuration
        }

        let audioDirectoryURL = documentsURL.appendingPathComponent(audioDirectoryName, isDirectory: true)
        let queueItems = try request.files.map { file -> QueueItem in
            guard file.repeatCount > 0 else {
                throw RemotePlaybackRequestError.invalidRepeatCount(file.fileName)
            }
            guard isSafeFileName(file.fileName),
                  file.fileName.lowercased().hasSuffix(".wav") else {
                throw RemotePlaybackRequestError.invalidFileName(file.fileName)
            }

            let fileURL = audioDirectoryURL.appendingPathComponent(file.fileName, isDirectory: false)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                throw RemotePlaybackRequestError.missingFile(file.fileName)
            }

            return QueueItem(
                sourceURL: fileURL,
                localURL: fileURL,
                displayName: file.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? file.fileName,
                repeatCount: file.repeatCount
            )
        }

        let eventLogURL = documentsURL.appendingPathComponent("remote-playback-status.log", isDirectory: false)
        if fileManager.fileExists(atPath: eventLogURL.path) {
            try fileManager.removeItem(at: eventLogURL)
        }
        try fileManager.removeItem(at: manifestURL)

        let captureSystemAudio = request.captureSystemAudio ?? false
        let captureFileName = request.systemAudioCaptureFileName ?? "screen-capture.caf"
        guard !captureSystemAudio || isSafeFileName(captureFileName) else {
            throw RemotePlaybackRequestError.invalidFileName(captureFileName)
        }
        let systemAudioCaptureURL = captureSystemAudio
            ? documentsURL.appendingPathComponent(captureFileName, isDirectory: false)
            : nil

        return ResolvedRemotePlaybackRequest(
            queueItems: queueItems,
            sameFileDelaySeconds: request.sameFileDelaySeconds,
            differentFileDelaySeconds: request.differentFileDelaySeconds,
            playbackPath: request.playbackPath ?? .avAudioEngine,
            avAudioEnginePan: avAudioEnginePan,
            avAudioEngineGain: avAudioEngineGain,
            avAudioEngineDirectPCM: request.avAudioEngineDirectPCM ?? false,
            avAudioEngineIsolateSignals:
                request.avAudioEngineIsolateSignals ?? false,
            avAudioEngineEQFrequency: avAudioEngineEQFrequency,
            avAudioEngineEQGain: avAudioEngineEQGain,
            avAudioEngineEQBandwidth: avAudioEngineEQBandwidth,
            avAudioEngineAutomaticFormat:
                request.avAudioEngineAutomaticFormat ?? false,
            avAudioEngineCompletionCallback:
                avAudioEngineCompletionCallback,
            avAudioEngineStopPlayerEachSignal:
                request.avAudioEngineStopPlayerEachSignal ?? false,
            avAudioEngineCompletionDelayFrames:
                avAudioEngineCompletionDelayFrames,
            avAudioEngineStereoMode:
                avAudioEngineStereoMode,
            preferredIOBufferDuration: preferredIOBufferDuration,
            forceMaximumOutputVolume:
                request.forceMaximumOutputVolume ?? false,
            avAudioSessionMode: avAudioSessionMode,
            captureSystemAudio: captureSystemAudio,
            systemAudioCaptureURL: systemAudioCaptureURL,
            eventLogURL: eventLogURL
        )
    }

    private static func isValidDelay(_ value: Double) -> Bool {
        value.isFinite && value >= 0
    }

    private static func isSafeFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty &&
            fileName == URL(fileURLWithPath: fileName).lastPathComponent &&
            !fileName.contains("..")
    }
}

enum RemotePlaybackRequestError: LocalizedError {
    case emptyFileList
    case invalidDelay
    case invalidPan
    case invalidGain
    case invalidAudioSessionMode
    case invalidEQ
    case invalidCompletionCallback
    case invalidCompletionDelay
    case invalidStereoMode
    case invalidIOBufferDuration
    case invalidRepeatCount(String)
    case invalidFileName(String)
    case missingFile(String)

    var errorDescription: String? {
        switch self {
        case .emptyFileList:
            return "The remote playback file list is empty."
        case .invalidDelay:
            return "Invalid remote playback delay."
        case .invalidPan:
            return "AVAudioEngine pan must be between -1 and 1."
        case .invalidGain:
            return "AVAudioEngine gain must be in 0.01...1."
        case .invalidAudioSessionMode:
            return "Unsupported AVAudioSession mode."
        case .invalidEQ:
            return "Invalid AVAudioEngine EQ values."
        case .invalidCompletionCallback:
            return "Invalid AVAudioEngine completion callback."
        case .invalidCompletionDelay:
            return "Invalid AVAudioEngine completion delay."
        case .invalidStereoMode:
            return "Invalid AVAudioEngine stereo mode."
        case .invalidIOBufferDuration:
            return "Invalid preferred IO buffer duration."
        case let .invalidRepeatCount(fileName):
            return "Invalid repeat count: \(fileName)"
        case let .invalidFileName(fileName):
            return "Unsafe WAV file name: \(fileName)"
        case let .missingFile(fileName):
            return "Transferred WAV file not found: \(fileName)"
        }
    }
}
