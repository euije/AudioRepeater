import Foundation
import AVFoundation
import CryptoKit

struct LibraryStore {
    struct Snapshot: Codable {
        var items: [SavedItem]
        var defaultRepeats: String
        var repeatDelay: String
        var fileDelay: String
        var settings: PlaybackSettings
    }

    struct SavedItem: Codable {
        var id: UUID
        var playbackKey: String
        var sourceURL: URL
        var relativePath: String
        var displayName: String
        var repeatText: String
        var isEnabled: Bool
        var deleteLocalFileOnRemove: Bool
    }

    let root: URL
    init(root: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        self.root = root.standardizedFileURL
    }

    var directory: URL { root.appendingPathComponent("Library/Application Support/AudioRepeater", isDirectory: true) }
    var importsDirectory: URL { directory.appendingPathComponent("ImportedAudio", isDirectory: true) }
    var recordingsDirectory: URL { root.appendingPathComponent("Documents/Recordings", isDirectory: true) }

    /// Validate the complete upload before changing either the saved or visible queue.
    func uploadedPlaylist(_ data: Data) throws -> (snapshot: Data, receipt: [String: Any]) {
        struct Upload: Decodable {
            struct File: Decodable {
                let fileName: String
                let displayName: String
                let sha256: String
                let frames: Int64
            }
            let id: String
            let files: [File]
            let repeatCount: Int
            let sameFileDelaySeconds: Double
            let differentFileDelaySeconds: Double
            let processing: PlaybackSettings
        }
        let request = try JSONDecoder().decode(Upload.self, from: data)
        guard UUID(uuidString: request.id) != nil, (1...8).contains(request.files.count),
              Set(request.files.map(\.fileName)).count == request.files.count,
              (1...10_000).contains(request.repeatCount),
              [request.sameFileDelaySeconds, request.differentFileDelaySeconds].allSatisfy({
                  $0.isFinite && (0...3600).contains($0)
              }) else { throw CocoaError(.fileReadCorruptFile) }
        try request.processing.validate()
        var saved: [SavedItem] = []
        var verified: [[String: Any]] = []
        for file in request.files {
            let pattern = "^a2m_upload_" + NSRegularExpression.escapedPattern(for: request.id) + "_m[1-8]\\.wav$"
            guard file.fileName.range(of: pattern, options: .regularExpression) != nil,
                  !file.displayName.isEmpty, file.displayName.count <= 240 else { throw CocoaError(.fileReadCorruptFile) }
            let relative = "Documents/RemoteAudio/" + file.fileName
            let url = root.appendingPathComponent(relative)
            let bytes = try Data(contentsOf: url)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let audio = try AVAudioFile(forReading: url)
            guard digest == file.sha256, file.frames > 0, audio.length == file.frames,
                  audio.fileFormat.sampleRate == 48_000, audio.fileFormat.channelCount == 1,
                  audio.fileFormat.commonFormat == .pcmFormatInt16 else { throw CocoaError(.fileReadCorruptFile) }
            saved.append(SavedItem(id: UUID(), playbackKey: UUID().uuidString, sourceURL: url,
                relativePath: relative, displayName: file.displayName, repeatText: String(request.repeatCount),
                isEnabled: true, deleteLocalFileOnRemove: false))
            verified.append(["fileName": file.fileName, "displayName": file.displayName,
                "sha256": digest, "frames": audio.length])
        }
        let library = Snapshot(items: saved, defaultRepeats: String(request.repeatCount),
            repeatDelay: String(request.sameFileDelaySeconds), fileDelay: String(request.differentFileDelaySeconds),
            settings: request.processing)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(library))
        let snapshot = try JSONSerialization.data(withJSONObject: ["library": object, "bridge_enabled": false], options: [.sortedKeys])
        let processing = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request.processing))
        return (snapshot, ["id": request.id, "autoplay": false, "files": verified,
            "repeatCount": request.repeatCount, "sameFileDelaySeconds": request.sameFileDelaySeconds,
            "differentFileDelaySeconds": request.differentFileDelaySeconds, "processing": processing])
    }

    func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var excluded = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }

    func recordingURL(extension suffix: String) throws -> URL {
        try prepareDirectory(recordingsDirectory)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return recordingsDirectory.appendingPathComponent("recording-\(stamp)-\(UUID().uuidString.prefix(8)).\(suffix)")
    }

    func save(items: [AudioItem], defaultRepeats: String, repeatDelay: String,
              fileDelay: String, settings: PlaybackSettings) throws {
        try settings.validate()
        let prefix = root.path + "/"
        let saved = items.compactMap { item -> SavedItem? in
            let path = item.localURL.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { return nil }
            return SavedItem(id: item.id, playbackKey: item.playbackKey, sourceURL: item.sourceURL,
                relativePath: String(path.dropFirst(prefix.count)), displayName: item.displayName,
                repeatText: item.repeatText, isEnabled: item.isEnabled,
                deleteLocalFileOnRemove: item.deleteLocalFileOnRemove)
        }
        let snapshot = Snapshot(items: saved, defaultRepeats: defaultRepeats,
            repeatDelay: repeatDelay, fileDelay: fileDelay, settings: settings)
        try prepareDirectory(directory)
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("library.json"), options: .atomic)
    }

    func load() throws -> (snapshot: Snapshot, items: [AudioItem])? {
        let url = directory.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        try snapshot.settings.validate()
        let items = snapshot.items.compactMap { saved -> AudioItem? in
            let url = root.appendingPathComponent(saved.relativePath).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/"),
                  FileManager.default.fileExists(atPath: url.path), url.pathExtension.lowercased() == "wav" else { return nil }
            return AudioItem(id: saved.id, playbackKey: saved.playbackKey, sourceURL: saved.sourceURL,
                localURL: url, displayName: saved.displayName, repeatText: saved.repeatText,
                isEnabled: saved.isEnabled, deleteLocalFileOnRemove: saved.deleteLocalFileOnRemove)
        }
        return (snapshot, items)
    }

    func recordings() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: recordingsDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: recordingsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            .filter { ["wav", "caf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
