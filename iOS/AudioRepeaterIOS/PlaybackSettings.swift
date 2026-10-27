import Foundation

enum PlaybackPath: String, Codable, CaseIterable {
    case avAudioEngine
    case remoteIO

    var label: String { self == .avAudioEngine ? "AVAudioEngine" : "RemoteIO" }
}

enum PlaybackEffect: String, Codable, CaseIterable {
    case off, equalizer, dynamics

    var label: String {
        switch self {
        case .off: return "Off"
        case .equalizer: return "Equalizer"
        case .dynamics: return "Dynamics Processing"
        }
    }
}

enum PlaybackOutput: String, Codable, CaseIterable {
    case system, speaker, receiver

    var label: String { rawValue.capitalized }
}

enum PlaybackSessionMode: String, Codable, CaseIterable {
    case `default`, measurement, moviePlayback, spokenAudio, voiceChat, videoChat

    var label: String {
        switch self {
        case .default: return "Default"
        case .measurement: return "Measurement"
        case .moviePlayback: return "Movie playback"
        case .spokenAudio: return "Spoken audio"
        case .voiceChat: return "Voice chat"
        case .videoChat: return "Video chat"
        }
    }

    var requiresInput: Bool { self == .voiceChat || self == .videoChat }
}

struct DynamicsSettings: Codable, Equatable {
    var thresholdDB: Float = -12
    var headroomDB: Float = 6
    var attackMS: Float = 3
    var releaseMS: Float = 80
    var masterGainDB: Float = 0
    var peakLimiter = true

    init() {}
    private enum CodingKeys: String, CodingKey {
        case thresholdDB, headroomDB, attackMS, releaseMS, masterGainDB, peakLimiter
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        thresholdDB = try values.decodeIfPresent(Float.self, forKey: .thresholdDB) ?? thresholdDB
        headroomDB = try values.decodeIfPresent(Float.self, forKey: .headroomDB) ?? headroomDB
        attackMS = try values.decodeIfPresent(Float.self, forKey: .attackMS) ?? attackMS
        releaseMS = try values.decodeIfPresent(Float.self, forKey: .releaseMS) ?? releaseMS
        masterGainDB = try values.decodeIfPresent(Float.self, forKey: .masterGainDB) ?? masterGainDB
        peakLimiter = try values.decodeIfPresent(Bool.self, forKey: .peakLimiter) ?? peakLimiter
    }

    func validate() throws {
        guard thresholdDB.isFinite, (-40...0).contains(thresholdDB),
              headroomDB.isFinite, (0.1...40).contains(headroomDB),
              attackMS.isFinite, (0.1...200).contains(attackMS),
              releaseMS.isFinite, (10...3000).contains(releaseMS),
              masterGainDB.isFinite, (-40...24).contains(masterGainDB) else {
            throw PlaybackSettingsError.invalidDynamics
        }
    }
}

struct PlaybackSettings: Codable, Equatable {
    static let equalizerFrequencies: [Float] = [60, 230, 910, 3600, 14000]
    var path: PlaybackPath = .avAudioEngine
    var effect: PlaybackEffect = .off
    var equalizerGains: [Float] = [0, 0, 0, 0, 0]
    var dynamics = DynamicsSettings()
    var output: PlaybackOutput = .system
    var sessionMode: PlaybackSessionMode = .default
    var recordMicrophone = false
    var captureSystemAudio = false

    init() {}
    private enum CodingKeys: String, CodingKey {
        case path, effect, equalizerGains, dynamics, output, sessionMode, recordMicrophone, captureSystemAudio
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decodeIfPresent(PlaybackPath.self, forKey: .path) ?? path
        effect = try values.decodeIfPresent(PlaybackEffect.self, forKey: .effect) ?? effect
        equalizerGains = try values.decodeIfPresent([Float].self, forKey: .equalizerGains) ?? equalizerGains
        dynamics = try values.decodeIfPresent(DynamicsSettings.self, forKey: .dynamics) ?? dynamics
        output = try values.decodeIfPresent(PlaybackOutput.self, forKey: .output) ?? output
        sessionMode = try values.decodeIfPresent(PlaybackSessionMode.self, forKey: .sessionMode) ?? sessionMode
        recordMicrophone = try values.decodeIfPresent(Bool.self, forKey: .recordMicrophone) ?? recordMicrophone
        captureSystemAudio = try values.decodeIfPresent(Bool.self, forKey: .captureSystemAudio) ?? captureSystemAudio
    }

    var activeEffect: PlaybackEffect { path == .avAudioEngine ? effect : .off }
    var effectiveSessionMode: PlaybackSessionMode {
        // Playback-only modes are incompatible with the input category.
        if recordMicrophone && !sessionMode.requiresInput { return .measurement }
        if output == .receiver && !sessionMode.requiresInput { return .default }
        if output == .speaker && [.moviePlayback, .spokenAudio].contains(sessionMode) { return .default }
        return sessionMode
    }
    var usesInputCategory: Bool {
        recordMicrophone || output != .system || sessionMode.requiresInput
    }

    func validate() throws {
        guard equalizerGains.count == Self.equalizerFrequencies.count,
              equalizerGains.allSatisfy({ $0.isFinite && (-15...15).contains($0) }) else {
            throw PlaybackSettingsError.invalidEqualizer
        }
        try dynamics.validate()
    }
}

enum PlaybackSettingsError: LocalizedError {
    case invalidEqualizer, invalidDynamics, microphoneDenied, microphoneUnavailable
    case outputUnavailable(String), audioUnit(OSStatusCode: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidEqualizer: return "EQ requires five band gains between -15 and 15 dB."
        case .invalidDynamics: return "The dynamics settings are outside the supported ranges."
        case .microphoneDenied: return "Allow microphone access in Settings to record during playback."
        case .microphoneUnavailable: return "Could not start microphone recording."
        case let .outputUnavailable(output): return "The requested output is unavailable: \(output)."
        case let .audioUnit(status): return "Could not configure the audio effect (OSStatus \(status))."
        }
    }
}
