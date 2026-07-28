import Foundation

struct AudioItem: Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL
    let localURL: URL
    let displayName: String
    var repeatText: String
    let deleteLocalFileOnRemove: Bool

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        localURL: URL,
        displayName: String,
        repeatText: String,
        deleteLocalFileOnRemove: Bool = true
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.localURL = localURL
        self.displayName = displayName
        self.repeatText = repeatText
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
