import AVFoundation
import Foundation
import CryptoKit

@main
struct PlaybackTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(message: message) }
        checks += 1
    }
    struct Failure: Error { let message: String }
    static func rejects(_ operation: () throws -> Void, _ message: String) throws {
        do { try operation() } catch { checks += 1; return }
        throw Failure(message: message)
    }

    static func main() throws {
        var settings = PlaybackSettings()
        try settings.validate()
        let partial = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{\"effect\":\"equalizer\",\"dynamics\":{\"attackMS\":10}}".utf8))
        try check(partial.effect == .equalizer && partial.dynamics.attackMS == 10 && partial.dynamics.releaseMS == 80,
            "Partial processing JSON must retain omitted defaults")
        settings.effect = .equalizer
        settings.path = .remoteIO
        try check(settings.activeEffect == .off && settings.effect == .equalizer, "RemoteIO must bypass stored effects")
        settings.path = .avAudioEngine
        try check(settings.activeEffect == .equalizer, "Switching back must restore the selected effect")
        settings.equalizerGains = [1]
        try rejects({ try settings.validate() }, "Malformed EQ band count accepted")
        settings.equalizerGains = [.nan, 0, 0, 0, 0]
        try rejects({ try settings.validate() }, "Non-finite EQ gain accepted")
        settings = PlaybackSettings()
        settings.dynamics.attackMS = 0
        try rejects({ try settings.validate() }, "Zero attack accepted")
        settings = PlaybackSettings()
        settings.recordMicrophone = true
        settings.sessionMode = .moviePlayback
        try check(settings.effectiveSessionMode == .measurement && settings.usesInputCategory,
            "Recording must use an input-compatible session")
        settings.sessionMode = .voiceChat
        try check(settings.effectiveSessionMode == .voiceChat, "Explicit chat processing must remain visible")
        settings.recordMicrophone = false
        settings.output = .receiver
        settings.sessionMode = .moviePlayback
        try check(settings.effectiveSessionMode == .default && settings.usesInputCategory,
            "Receiver playback must select a compatible input category")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = LibraryStore(root: temporary)
        try store.prepareDirectory(store.importsDirectory)
        let wav = store.importsDirectory.appendingPathComponent("test.wav")
        try Data([1, 2, 3]).write(to: wav)
        let item = AudioItem(sourceURL: wav, localURL: wav, displayName: "Test", repeatText: "3", isEnabled: false)
        settings = PlaybackSettings()
        settings.effect = .equalizer
        settings.equalizerGains[2] = 8
        try store.save(items: [item], defaultRepeats: "3", repeatDelay: "0.25", fileDelay: "1", settings: settings)
        let restored = try store.load()!
        try check(restored.items[0].id == item.id && !restored.items[0].isEnabled && restored.items[0].repeatText == "3",
            "Queue identity, enable state, or repeats were lost")
        try check(restored.snapshot.settings == settings && restored.snapshot.repeatDelay == "0.25", "Processing or delay was lost")
        let migratedRoot = temporary.appendingPathComponent("new-container")
        try FileManager.default.createDirectory(at: migratedRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: temporary.appendingPathComponent("Library"), to: migratedRoot.appendingPathComponent("Library"))
        let migrated = try LibraryStore(root: migratedRoot).load()!
        try check(migrated.items[0].localURL.path.hasPrefix(migratedRoot.path + "/"), "Queue must survive a container path change")
        try FileManager.default.removeItem(at: wav)
        try check(try store.load()!.items.isEmpty, "Missing audio must not produce playable queue rows")

        let documents = temporary.appendingPathComponent("Documents")
        let audio = documents.appendingPathComponent("RemoteAudio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let uploadID = UUID().uuidString.lowercased()
        let uploadName = "a2m_upload_\(uploadID)_m1.wav"
        let uploadURL = audio.appendingPathComponent(uploadName)
        do {
            let file = try AVAudioFile(forWriting: uploadURL, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16)!
            buffer.frameLength = 16
            for i in 0..<16 { buffer.floatChannelData![0][i] = 0.1 }
            try file.write(from: buffer)
        }
        let uploadHash = SHA256.hash(data: try Data(contentsOf: uploadURL)).map { String(format: "%02x", $0) }.joined()
        let uploadFile: [String: Any] = ["fileName": uploadName, "displayName": "c0207_G64_m1.wav", "sha256": uploadHash, "frames": 16]
        let processingObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
        let validUpload: [String: Any] = ["id": uploadID, "files": [uploadFile], "repeatCount": 2,
            "sameFileDelaySeconds": 0.5, "differentFileDelaySeconds": 0, "processing": processingObject]
        let savedBeforeUpload = try Data(contentsOf: store.directory.appendingPathComponent("library.json"))
        let staged = try store.uploadedPlaylist(JSONSerialization.data(withJSONObject: validUpload))
        let stagedObject = try JSONSerialization.jsonObject(with: staged.snapshot) as! [String: Any]
        let stagedLibrary = try JSONDecoder().decode(LibraryStore.Snapshot.self,
            from: JSONSerialization.data(withJSONObject: stagedObject["library"]!))
        try check(stagedLibrary.items.count == 1 && stagedLibrary.items[0].repeatText == "2" && stagedLibrary.items[0].isEnabled,
            "Uploaded queue order, enable state or repeat count changed")
        try check(stagedLibrary.repeatDelay == "0.5" && stagedLibrary.settings == settings && staged.receipt["autoplay"] as? Bool == false,
            "Uploaded processing, delay or no-autoplay contract changed")
        for kind in ["hash", "frames", "path", "duplicates", "delay", "empty", "settings"] {
            var invalid = validUpload
            var file = uploadFile
            switch kind {
            case "hash": file["sha256"] = String(repeating: "0", count: 64); invalid["files"] = [file]
            case "frames": file["frames"] = 17; invalid["files"] = [file]
            case "path": file["fileName"] = "../outside.wav"; invalid["files"] = [file]
            case "duplicates": invalid["files"] = [file, file]
            case "delay": invalid["sameFileDelaySeconds"] = -1
            case "empty": invalid["files"] = []
            default: invalid["processing"] = ["equalizerGains": [1]]
            }
            try rejects({ _ = try store.uploadedPlaylist(JSONSerialization.data(withJSONObject: invalid)) }, "Invalid playlist upload accepted: \(kind)")
        }
        try check(try Data(contentsOf: store.directory.appendingPathComponent("library.json")) == savedBeforeUpload,
            "Upload validation must preserve the previous saved queue")
        try Data([1]).write(to: audio.appendingPathComponent("tone.wav"))
        let manifest = documents.appendingPathComponent("remote-playback.json")
        var request: [String: Any] = ["files": [["fileName": "tone.wav", "repeatCount": 2]],
            "sameFileDelaySeconds": 0, "differentFileDelaySeconds": 0]
        try JSONSerialization.data(withJSONObject: request).write(to: manifest)
        let legacy = try RemotePlaybackRequestLoader.consumeIfPresent(in: documents)!
        try check(legacy.processing == nil && legacy.playbackPath == .avAudioEngine && legacy.microphoneRecordingURL == nil,
            "Legacy remote requests must keep their original processing contract")
        try check(legacy.requestID == nil && legacy.experimentOwner == nil,
            "Legacy playback must not acquire an experiment owner")
        request["requestID"] = "integration-request"
        request["experimentOwner"] = "integration-owner"
        request["processing"] = ["effect": "equalizer", "equalizerGains": [0, 0, 5, 0, 0], "recordMicrophone": true]
        try JSONSerialization.data(withJSONObject: request).write(to: manifest)
        let processed = try RemotePlaybackRequestLoader.consumeIfPresent(in: documents)!
        try check(processed.processing?.activeEffect == .equalizer && processed.microphoneRecordingURL?.pathExtension == "wav",
            "Remote processing and recording must reach the resolved request")
        try check(processed.requestID == "integration-request" && processed.experimentOwner == "integration-owner",
            "Experimental playback must retain the request and lease owner identities")
        request["captureSystemAudio"] = true
        request["systemAudioCaptureFileName"] = "../invalid.caf"
        let log = documents.appendingPathComponent("remote-playback-status.log")
        try Data("retain diagnostic".utf8).write(to: log)
        try JSONSerialization.data(withJSONObject: request).write(to: manifest)
        try rejects({ _ = try RemotePlaybackRequestLoader.consumeIfPresent(in: documents) }, "Unsafe capture path accepted")
        try check(FileManager.default.fileExists(atPath: manifest.path) && (try String(contentsOf: log)) == "retain diagnostic",
            "Invalid requests must preserve the manifest and previous diagnostic log")

        let baseline = try render(PlaybackSettings())
        var eq = PlaybackSettings()
        eq.effect = .equalizer
        eq.equalizerGains[2] = 12
        let equalized = try render(eq)
        try check(equalized > baseline * 2, "EQ must change rendered 910 Hz audio")
        var dynamics = PlaybackSettings()
        dynamics.effect = .dynamics
        dynamics.dynamics.thresholdDB = 0
        dynamics.dynamics.masterGainDB = -12
        dynamics.dynamics.peakLimiter = false
        let compressed = try render(dynamics)
        try check(compressed < baseline * 0.6 && compressed > 0, "Dynamics master gain must change rendered audio")
        dynamics.dynamics.peakLimiter = true
        let limited = try render(dynamics)
        try check(limited.isFinite && limited > 0, "Peak Limiter must render finite nonzero audio")
        print("PASS: \(checks) settings, persistence, legacy requests, and offline audio checks")
        print("Rendered RMS: off=\(baseline), EQ=\(equalized), dynamics=\(compressed), limiter=\(limited)")
    }

    static func render(_ settings: PlaybackSettings) throws -> Double {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        engine.attach(player)
        try PlaybackEffects.connect(player: player, engine: engine, format: format, settings: settings)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        source.frameLength = source.frameCapacity
        for index in 0..<Int(source.frameLength) {
            source.floatChannelData![0][index] = 0.2 * sin(Float(index) * 2 * .pi * 910 / 48_000)
        }
        player.scheduleBuffer(source)
        try engine.start()
        player.play()
        defer { player.stop(); engine.stop() }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        var samples: [Float] = []
        for _ in 0..<47 {
            let status = try engine.renderOffline(1024, to: output)
            guard status == .success else { throw Failure(message: "Offline render failed: \(status)") }
            samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        }
        let tail = samples.suffix(12_000)
        return sqrt(tail.reduce(0) { $0 + Double($1 * $1) } / Double(tail.count))
    }
}
