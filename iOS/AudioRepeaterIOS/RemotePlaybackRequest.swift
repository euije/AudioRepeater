import Foundation

struct ResolvedRemotePlaybackRequest {
    let queueItems: [QueueItem]
    let sameFileDelaySeconds: Double
    let differentFileDelaySeconds: Double
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
        return ResolvedRemotePlaybackRequest(
            queueItems: queueItems,
            sameFileDelaySeconds: request.sameFileDelaySeconds,
            differentFileDelaySeconds: request.differentFileDelaySeconds,
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
    case invalidRepeatCount(String)
    case invalidFileName(String)
    case missingFile(String)

    var errorDescription: String? {
        switch self {
        case .emptyFileList:
            return "원격 재생 파일 목록이 비어 있습니다."
        case .invalidDelay:
            return "원격 재생 딜레이 값이 올바르지 않습니다."
        case let .invalidRepeatCount(fileName):
            return "반복 횟수가 올바르지 않습니다: \(fileName)"
        case let .invalidFileName(fileName):
            return "안전하지 않은 WAV 파일명입니다: \(fileName)"
        case let .missingFile(fileName):
            return "전송된 WAV 파일을 찾을 수 없습니다: \(fileName)"
        }
    }
}
