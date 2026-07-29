import Foundation

struct AudioItem: Identifiable, Equatable {
    let id: UUID
    let playbackKey: String
    let sourceURL: URL
    let localURL: URL
    let displayName: String
    var repeatText: String
    var isEnabled: Bool
    let deleteLocalFileOnRemove: Bool

    init(
        id: UUID = UUID(),
        playbackKey: String? = nil,
        sourceURL: URL,
        localURL: URL,
        displayName: String,
        repeatText: String,
        isEnabled: Bool = true,
        deleteLocalFileOnRemove: Bool = true
    ) {
        self.id = id
        self.playbackKey = playbackKey ?? id.uuidString
        self.sourceURL = sourceURL
        self.localURL = localURL
        self.displayName = displayName
        self.repeatText = repeatText
        self.isEnabled = isEnabled
        self.deleteLocalFileOnRemove = deleteLocalFileOnRemove
    }

    var repeatCount: Int? {
        Int(repeatText).flatMap { $0 > 0 ? $0 : nil }
    }
}

struct QueueItem {
    let itemKey: String
    let sourceURL: URL
    let localURL: URL
    let displayName: String
    let repeatCount: Int

    init(
        itemKey: String? = nil,
        sourceURL: URL,
        localURL: URL,
        displayName: String,
        repeatCount: Int
    ) {
        self.itemKey = itemKey ?? localURL.lastPathComponent
        self.sourceURL = sourceURL
        self.localURL = localURL
        self.displayName = displayName
        self.repeatCount = repeatCount
    }
}
