import Foundation
import UniformTypeIdentifiers

enum ImportManager {
    static let wavType = UTType(filenameExtension: "wav") ?? .audio

    static func importAudioItems(
        from urls: [URL],
        knownSources: Set<String>,
        repeatText: String
    ) throws -> (items: [AudioItem], skippedCount: Int) {
        var importedItems: [AudioItem] = []
        var skippedCount = 0
        var knownSources = knownSources

        for sourceURL in urls {
            let sourceKey = sourceURL.absoluteString
            guard knownSources.insert(sourceKey).inserted else {
                skippedCount += 1
                continue
            }

            guard sourceURL.pathExtension.lowercased() == "wav" else {
                skippedCount += 1
                continue
            }

            let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let localURL = try copyToAudioCache(sourceURL)
                importedItems.append(
                    AudioItem(
                        sourceURL: sourceURL,
                        localURL: localURL,
                        displayName: sourceURL.lastPathComponent,
                        repeatText: repeatText,
                        deleteLocalFileOnRemove: true
                    )
                )
            } catch {
                skippedCount += 1
            }
        }

        return (importedItems, skippedCount)
    }

    static func deleteLocalFileIfOwned(_ item: AudioItem) {
        guard item.deleteLocalFileOnRemove else { return }
        try? FileManager.default.removeItem(at: item.localURL)
    }

    private static func copyToAudioCache(_ sourceURL: URL) throws -> URL {
        let directory = try audioCacheDirectory()
        let fileName = "\(UUID().uuidString).wav"
        let destinationURL = directory.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private static func audioCacheDirectory() throws -> URL {
        let store = LibraryStore()
        let directory = store.importsDirectory
        try store.prepareDirectory(directory)
        return directory
    }
}
