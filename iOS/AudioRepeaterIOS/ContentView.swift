import Foundation
import SwiftUI

struct ContentView: View {
    @StateObject private var player = AudioQueuePlayer()
    @State private var items: [AudioItem] = []
    @State private var defaultRepeatText = "1"
    @State private var sameFileDelayText = "0"
    @State private var differentFileDelayText = "0"
    @State private var isImporterPresented = false
    @State private var isImporting = false
    @State private var alertMessage: String?
    @State private var didCheckRemotePlaybackRequest = false

    private var defaultRepeat: Int? {
        positiveInt(defaultRepeatText)
    }

    private var sameFileDelay: Double? {
        delaySeconds(sameFileDelayText)
    }

    private var differentFileDelay: Double? {
        delaySeconds(differentFileDelayText)
    }

    private var canPlay: Bool {
        !player.state.isRunning &&
            !isImporting &&
            !items.isEmpty &&
            sameFileDelay != nil &&
            differentFileDelay != nil &&
            items.allSatisfy { $0.repeatCount != nil }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                controls
                playbackControls
                listContent
            }
            .padding()
            .navigationTitle("AudioRepeater")
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [ImportManager.wavType],
                allowsMultipleSelection: true,
                onCompletion: handleImportResult
            )
            .alert("알림", isPresented: alertBinding) {
                Button("확인", role: .cancel) {
                    alertMessage = nil
                }
            } message: {
                Text(alertMessage ?? "")
            }
            .onReceive(player.$errorMessage.compactMap { $0 }) { message in
                alertMessage = message
            }
            .task {
                consumeRemotePlaybackRequestIfPresent()
            }
            .onDisappear {
                player.stop()
                items.forEach { ImportManager.deleteLocalFileIfOwned($0) }
            }
        }
    }

    @MainActor
    private func consumeRemotePlaybackRequestIfPresent() {
        guard !didCheckRemotePlaybackRequest else { return }
        didCheckRemotePlaybackRequest = true

        do {
            guard let request = try RemotePlaybackRequestLoader.consumeIfPresent() else {
                return
            }

            items = request.queueItems.map { item in
                AudioItem(
                    sourceURL: item.sourceURL,
                    localURL: item.localURL,
                    displayName: item.displayName,
                    repeatText: String(item.repeatCount),
                    deleteLocalFileOnRemove: false
                )
            }
            if let firstRepeat = request.queueItems.first?.repeatCount,
               request.queueItems.allSatisfy({ $0.repeatCount == firstRepeat }) {
                defaultRepeatText = String(firstRepeat)
            }
            sameFileDelayText = delayText(request.sameFileDelaySeconds)
            differentFileDelayText = delayText(request.differentFileDelaySeconds)

            print(
                "AudioRepeaterIOS remote request loaded items=\(request.queueItems.count) " +
                    "sameDelay=\(request.sameFileDelaySeconds) " +
                    "diffDelay=\(request.differentFileDelaySeconds)"
            )
            player.play(
                items: request.queueItems,
                sameFileDelaySeconds: request.sameFileDelaySeconds,
                differentFileDelaySeconds: request.differentFileDelaySeconds,
                eventLogURL: request.eventLogURL
            )
        } catch {
            alertMessage = error.localizedDescription
            print("AudioRepeaterIOS remote request error \(error.localizedDescription)")
        }
    }

    private func delayText(_ value: Double) -> String {
        var text = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text.isEmpty ? "0" : text
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                labeledTextField(
                    title: "기본 반복",
                    text: $defaultRepeatText,
                    keyboardType: .numberPad,
                    sanitize: sanitizeRepeatInput
                )

                Button {
                    isImporterPresented = true
                } label: {
                    Label(isImporting ? "추가 중" : "여러개 추가", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(player.state.isRunning || isImporting || defaultRepeat == nil)
            }

            Button {
                for index in items.indices {
                    items[index].repeatText = defaultRepeatText
                }
            } label: {
                Label("전체 반복 적용", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(player.state.isRunning || defaultRepeat == nil || items.isEmpty)

            HStack(spacing: 12) {
                labeledTextField(
                    title: "같은 파일 딜레이(초)",
                    text: $sameFileDelayText,
                    keyboardType: .decimalPad,
                    sanitize: sanitizeDelayInput
                )

                labeledTextField(
                    title: "파일 간 딜레이(초)",
                    text: $differentFileDelayText,
                    keyboardType: .decimalPad,
                    sanitize: sanitizeDelayInput
                )
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button {
                let queueItems = items.compactMap { item -> QueueItem? in
                    guard let repeatCount = item.repeatCount else { return nil }
                    return QueueItem(
                        sourceURL: item.sourceURL,
                        localURL: item.localURL,
                        displayName: item.displayName,
                        repeatCount: repeatCount
                    )
                }

                player.play(
                    items: queueItems,
                    sameFileDelaySeconds: sameFileDelay ?? 0,
                    differentFileDelaySeconds: differentFileDelay ?? 0
                )
            } label: {
                Label("재생", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canPlay)

            Button {
                player.stop()
            } label: {
                Label("정지", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!player.state.isRunning)
        }
        .overlay(alignment: .bottom) {
            Text(player.state.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .offset(y: 26)
        }
        .padding(.bottom, 24)
    }

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("목록 (\(items.count))")
                .font(.headline)

            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("wav 파일 없음")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach($items) { $item in
                        AudioItemRow(
                            item: $item,
                            isPlaying: player.state.isRunning,
                            isCurrent: isCurrent(item)
                        ) {
                            if let index = items.firstIndex(where: { $0.id == item.id }) {
                                let removed = items.remove(at: index)
                                ImportManager.deleteLocalFileIfOwned(removed)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func labeledTextField(
        title: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType,
        sanitize: @escaping (String) -> String
    ) -> some View {
        TextField(title, text: text)
            .keyboardType(keyboardType)
            .textFieldStyle(.roundedBorder)
            .disabled(player.state.isRunning)
            .onChange(of: text.wrappedValue) { newValue in
                let sanitized = sanitize(newValue)
                if sanitized != newValue {
                    text.wrappedValue = sanitized
                }
            }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard !urls.isEmpty else { return }
            isImporting = true
            defer { isImporting = false }

            do {
                let knownSources = Set(items.map { $0.sourceURL.absoluteString })
                let importResult = try ImportManager.importAudioItems(
                    from: urls,
                    knownSources: knownSources,
                    repeatText: defaultRepeatText
                )
                items.append(contentsOf: importResult.items)

                if importResult.items.isEmpty {
                    alertMessage = "추가된 wav 파일이 없습니다."
                } else if importResult.skippedCount > 0 {
                    alertMessage = "\(importResult.items.count)개 추가, \(importResult.skippedCount)개 건너뜀"
                } else {
                    alertMessage = "\(importResult.items.count)개 추가됨"
                }
            } catch {
                alertMessage = error.localizedDescription
            }

        case let .failure(error):
            alertMessage = error.localizedDescription
        }
    }

    private func isCurrent(_ item: AudioItem) -> Bool {
        if case let .playing(displayName, _, _) = player.state {
            return displayName == item.displayName
        }
        return false
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )
    }
}

private struct AudioItemRow: View {
    @Binding var item: AudioItem
    let isPlaying: Bool
    let isCurrent: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .foregroundStyle(isCurrent ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(item.localURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            TextField("횟수", text: $item.repeatText)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 76)
                .disabled(isPlaying)
                .onChange(of: item.repeatText) { newValue in
                    let sanitized = sanitizeRepeatInput(newValue)
                    if sanitized != newValue {
                        item.repeatText = sanitized
                    }
                }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .disabled(isPlaying)
        }
        .padding(.vertical, 6)
        .listRowBackground(isCurrent ? Color.blue.opacity(0.08) : Color.clear)
    }
}

private func sanitizeRepeatInput(_ value: String) -> String {
    let digits = String(value.filter(\.isNumber).prefix(4))
    let trimmed = digits.drop { $0 == "0" }
    if trimmed.isEmpty {
        return digits.isEmpty ? "" : "0"
    }
    return String(trimmed)
}

private func sanitizeDelayInput(_ value: String) -> String {
    var result = ""
    var hasDecimalPoint = false
    var wholeDigits = 0
    var fractionDigits = 0

    for character in value.replacingOccurrences(of: ",", with: ".") {
        if character.isNumber {
            if hasDecimalPoint {
                guard fractionDigits < 3 else { continue }
                fractionDigits += 1
            } else {
                guard wholeDigits < 4 else { continue }
                wholeDigits += 1
            }
            result.append(character)
        } else if character == ".", !hasDecimalPoint {
            if result.isEmpty {
                result.append("0")
            }
            result.append(".")
            hasDecimalPoint = true
        }
    }

    guard !result.isEmpty else { return "" }
    let parts = result.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    let whole = parts.first.map { String($0).drop { $0 == "0" } }.map(String.init) ?? "0"
    let normalizedWhole = whole.isEmpty ? "0" : whole
    if parts.count == 1 {
        return normalizedWhole
    }
    return "\(normalizedWhole).\(parts[1])"
}

private func positiveInt(_ value: String) -> Int? {
    guard let intValue = Int(value), intValue > 0 else { return nil }
    return intValue
}

private func delaySeconds(_ value: String) -> Double? {
    guard let doubleValue = Double(value.replacingOccurrences(of: ",", with: ".")),
          doubleValue.isFinite,
          doubleValue >= 0 else {
        return nil
    }
    return doubleValue
}
