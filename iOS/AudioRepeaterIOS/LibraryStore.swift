import Foundation

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
