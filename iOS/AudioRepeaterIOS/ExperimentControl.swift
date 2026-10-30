import AVFoundation
import CryptoKit
import Darwin
import Foundation
import UIKit

/// App-container commands used by a paired computer. No network listener.
@MainActor
final class ExperimentControl: ObservableObject {
    @Published private(set) var isLeased = false
    private struct Lease: Codable {
        var owner: String
        var deadline: Double
        var snapshot: Data
        var volume: Float
    }
    private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var lease: Lease?
    private var recovered = false
    private var lastWrite: TimeInterval = 0
    private var controlReply: [String: Any] = [:]
    private var processedControlID = UserDefaults.standard.string(forKey: "a2mOptimizeLastControlID")
    private var lastResult: [String: Any] = [:]
    private var requestID: String?
    private var requestStart: TimeInterval = 0
    private var requestFiles: [[String: Any]] = []
    private var microphoneBefore: URL?
    private var expectedMicrophone = false
    private var restoration: [String: Any] = [:]
    private var playlistUpload: [String: Any] = [:]
    private var volumeReadbackValid = false
    private lazy var executableHash = (try? Self.digest(Data(contentsOf: Bundle.main.executableURL!))) ?? ""

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func url(_ name: String) -> URL { documents.appendingPathComponent(name) }
    private func persistLease() throws {
        if let lease { try JSONEncoder().encode(lease).write(to: url("a2m-optimize-lease.json"), options: .atomic) }
        else { try? FileManager.default.removeItem(at: url("a2m-optimize-lease.json")) }
    }
    private func json(_ value: Any, to name: String) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url(name), options: .atomic)
    }
    private func stateName(_ player: AudioQueuePlayer) -> String {
        switch player.state {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .playing: return "playing"
        }
    }
    private func permission() -> String {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        default: return "undetermined"
        }
    }
    private func writeStatus(_ player: AudioQueuePlayer) throws {
        var machine = utsname(); uname(&machine)
        let capacity = MemoryLayout.size(ofValue: machine.machine)
        let product = withUnsafePointer(to: &machine.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        let session = AVAudioSession.sharedInstance()
        try json([
            "schema": "a2m_ios_control_v1", "protocol_version": 1,
            "updated_at": Date().timeIntervalSince1970, "uptime": ProcessInfo.processInfo.systemUptime,
            "platform": "ios", "product_type": product, "os_version": UIDevice.current.systemVersion,
            "bundle_id": Bundle.main.bundleIdentifier ?? "",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "",
            "executable_sha256": executableHash, "microphone_permission": permission(),
            "owner": lease?.owner as Any? ?? NSNull(), "state": stateName(player),
            "output_volume": session.outputVolume, "sample_rate": session.sampleRate,
            "volume_readback_valid": volumeReadbackValid || player.state.isRunning,
            "mode": session.mode.rawValue,
            "outputs": session.currentRoute.outputs.map { ["type": $0.portType.rawValue, "name": $0.portName] },
            "request_id": requestID as Any? ?? NSNull(), "input_files": requestFiles,
            "last_control": controlReply, "last_result": lastResult, "restoration": restoration,
            "playlist_upload_version": 1, "last_playlist_upload": playlistUpload,
            "recording_status": player.recordingStatus,
        ], to: "a2m-optimize-status.json")
    }

    func poll(player: AudioQueuePlayer, snapshot: () throws -> Data, restore: (Data) throws -> Void,
              otherPlaybackRunning: Bool = false) async {
        if !recovered {
            recovered = true
            try? FileManager.default.createDirectory(at: url("RemoteAudio"), withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: url("a2m-optimize-lease.json")),
               let old = try? JSONDecoder().decode(Lease.self, from: data) {
                lease = old; isLeased = true
                do { try await release(player: player, snapshot: snapshot, restore: restore) }
                catch { controlReply = ["error": "Recovery failed: \(error.localizedDescription)"] }
            }
        }
        if let current = lease, Date().timeIntervalSince1970 > current.deadline {
            do { try await release(player: player, snapshot: snapshot, restore: restore) }
            catch { controlReply = ["error": error.localizedDescription] }
        }
        let commandURL = url("a2m-optimize-control.json")
        // A host may still be copying this small file. Leave partial JSON for the next poll.
        if let data = try? Data(contentsOf: commandURL),
           let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = command["id"] as? String, id != processedControlID {
            // CoreDevice checks the destination after copying. Keep the file
            // present and consume each command ID once instead of deleting it.
            processedControlID = id
            UserDefaults.standard.set(id, forKey: "a2mOptimizeLastControlID")
            do {
                try await handle(command, player: player, snapshot: snapshot, restore: restore,
                                 otherPlaybackRunning: otherPlaybackRunning)
                controlReply = ["id": id, "ok": true]
            } catch { controlReply = ["id": id, "ok": false, "error": error.localizedDescription] }
        }
        if let id = requestID, !player.state.isRunning {
            var result: [String: Any] = ["request_id": id,
                "state": player.errorMessage == nil ? "completed" : "failed",
                "error": player.errorMessage as Any? ?? NSNull(),
                "started_uptime": requestStart, "finished_uptime": ProcessInfo.processInfo.systemUptime,
                "input_files": requestFiles]
            if expectedMicrophone {
                if let file = player.lastRecordingURL, file != microphoneBefore,
                   let info = try? AVAudioFile(forReading: file), info.length > 0,
                   let bytes = try? Data(contentsOf: file) {
                    result["microphone"] = ["path": "Recordings/" + file.lastPathComponent,
                        "sha256": Self.digest(bytes), "frames": info.length,
                        "sample_rate": info.processingFormat.sampleRate,
                        "channels": info.processingFormat.channelCount,
                        "profile": "ios-mic-measurement-48k-pcm16"]
                } else {
                    result["state"] = "failed"; result["error"] = "No new microphone recording was saved."
                }
            }
            lastResult = result; requestID = nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastWrite >= 0.25 {
            lastWrite = now
            if lease != nil, let requestID {
                let value: [String: Any] = ["request_id": requestID, "uptime": now,
                    "phase": stateName(player), "volume": AVAudioSession.sharedInstance().outputVolume,
                    "outputs": AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }]
                if let line = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                    let file = url("a2m-optimize-volume.jsonl")
                    if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                    if let handle = try? FileHandle(forWritingTo: file) {
                        defer { try? handle.close() }; handle.seekToEndOfFile(); handle.write(line); handle.write(Data([10]))
                    }
                }
            }
            try? writeStatus(player)
        }
    }

    private func handle(_ command: [String: Any], player: AudioQueuePlayer,
                        snapshot: () throws -> Data, restore: (Data) throws -> Void,
                        otherPlaybackRunning: Bool) async throws {
        guard let action = command["action"] as? String else { throw ControlError.invalid }
        if action == "status" { return }
        if action == "install_playlist" {
            guard lease == nil, !player.state.isRunning, !otherPlaybackRunning,
                  !FileManager.default.fileExists(atPath: url("remote-playback.json").path) else { throw ControlError.busy }
            guard let name = command["manifest"] as? String,
                  name.range(of: "^a2m-optimize-upload-[a-f0-9-]{36}\\.json$", options: .regularExpression) != nil,
                  let hash = command["sha256"] as? String else { throw ControlError.invalid }
            let data = try Data(contentsOf: url(name))
            guard Self.digest(data) == hash else { throw ControlError.hash }
            let upload = try LibraryStore().uploadedPlaylist(data)
            let previous = try snapshot()
            do {
                try restore(upload.snapshot)
                let applied = try snapshot()
                guard applied == upload.snapshot else { throw ControlError.restore }
                playlistUpload = upload.receipt
                playlistUpload["snapshot_sha256"] = Self.digest(applied)
            } catch {
                try restore(previous)
                throw error
            }
            return
        }
        if action == "prepare" {
            guard lease == nil, !player.state.isRunning, !otherPlaybackRunning else { throw ControlError.busy }
            let data = try JSONSerialization.data(withJSONObject: command["processing"] ?? [:])
            let settings = try JSONDecoder().decode(PlaybackSettings.self, from: data)
            try settings.validate()
            try await player.prepareExperimentSession(settings: settings)
            volumeReadbackValid = true
            return
        }
        if action == "request_microphone_permission" {
            _ = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
            return
        }
        guard let owner = command["owner"] as? String,
              owner.range(of: "^[A-Za-z0-9_-]{1,96}$", options: .regularExpression) != nil else { throw ControlError.invalid }
        if action == "acquire" {
            guard lease == nil, !player.state.isRunning, !otherPlaybackRunning else { throw ControlError.busy }
            guard permission() == "granted" else { throw PlaybackSettingsError.microphoneDenied }
            let data = try JSONSerialization.data(withJSONObject: command["processing"] ?? [:])
            let settings = try JSONDecoder().decode(PlaybackSettings.self, from: data)
            try settings.validate()
            lease = Lease(owner: owner, deadline: Date().timeIntervalSince1970 + 60,
                          snapshot: try snapshot(), volume: AVAudioSession.sharedInstance().outputVolume)
            isLeased = true; try persistLease()
            try? FileManager.default.removeItem(at: url("a2m-optimize-volume.jsonl"))
            do { try await player.prepareForExperiment(settings: settings, volume: 1); volumeReadbackValid = true }
            catch {
                try? await release(player: player, snapshot: snapshot, restore: restore)
                throw error
            }
            return
        }
        guard lease?.owner == owner else { throw ControlError.owner }
        switch action {
        case "play":
            guard !player.state.isRunning, let file = command["manifest"] as? String,
                  file.range(of: "^a2m-optimize-[A-Za-z0-9_-]+\\.json$", options: .regularExpression) != nil,
                  let hash = command["sha256"] as? String else { throw ControlError.invalid }
            let data = try Data(contentsOf: url(file))
            guard Self.digest(data) == hash else { throw ControlError.hash }
            let request = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard request?["experimentOwner"] as? String == owner else { throw ControlError.owner }
            guard !FileManager.default.fileExists(atPath: url("remote-playback.json").path) else { throw ControlError.busy }
            try data.write(to: url("remote-playback.json"), options: .atomic)
            lease?.deadline = Date().timeIntervalSince1970 + 60; try persistLease()
        case "release": try await release(player: player, snapshot: snapshot, restore: restore)
        case "stop": player.stop()
        default: throw ControlError.invalid
        }
    }

    func notePlayback(_ request: ResolvedRemotePlaybackRequest, player: AudioQueuePlayer) throws {
        guard let owner = lease?.owner else { return }
        guard request.experimentOwner == owner, let id = request.requestID else { throw ControlError.owner }
        requestFiles = try request.queueItems.map { item in
            let data = try Data(contentsOf: item.localURL); let file = try AVAudioFile(forReading: item.localURL)
            return ["name": item.localURL.lastPathComponent, "sha256": Self.digest(data),
                "frames": file.length, "sample_rate": file.processingFormat.sampleRate,
                "channels": file.processingFormat.channelCount]
        }
        requestID = id; requestStart = ProcessInfo.processInfo.systemUptime
        microphoneBefore = player.lastRecordingURL; expectedMicrophone = request.microphoneRecordingURL != nil
        let duration = requestFiles.reduce(0.0) { $0 + (($1["frames"] as? Int64).map(Double.init) ?? 0) / 48_000 }
        lease?.deadline = Date().timeIntervalSince1970 + min(900, max(60, duration + 30))
        try persistLease()
        lastResult = [:]
    }

    func release(player: AudioQueuePlayer, snapshot: () throws -> Data, restore: (Data) throws -> Void) async throws {
        guard let original = lease else { return }
        if player.state.isRunning { player.stop() }
        for _ in 0..<100 where player.state.isRunning { try await Task.sleep(nanoseconds: 100_000_000) }
        guard !player.state.isRunning else { throw ControlError.busy }
        try restore(original.snapshot)
        try await player.setExperimentVolume(original.volume)
        let restored = try snapshot()
        restoration = ["owner": original.owner, "playlist_restored": original.snapshot == restored,
            "snapshot_before": Self.digest(original.snapshot), "snapshot_after": Self.digest(restored),
            "volume_before": original.volume, "volume_after": AVAudioSession.sharedInstance().outputVolume]
        guard original.snapshot == restored,
              abs(AVAudioSession.sharedInstance().outputVolume - original.volume) < 0.005 else { throw ControlError.restore }
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        volumeReadbackValid = false
        lease = nil; isLeased = false; requestID = nil; try persistLease()
        try writeStatus(player)
    }
}

private enum ControlError: LocalizedError {
    case invalid, busy, owner, hash, restore
    var errorDescription: String? {
        switch self {
        case .invalid: return "Invalid experimental control command."
        case .busy: return "The app is busy. Stop the current playback first."
        case .owner: return "The experiment owner does not match."
        case .hash: return "The staged manifest checksum does not match."
        case .restore: return "The original queue or volume could not be restored."
        }
    }
}
