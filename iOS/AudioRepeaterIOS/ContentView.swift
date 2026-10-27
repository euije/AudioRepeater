import Foundation
import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var player = AudioQueuePlayer()
    @StateObject private var ioAudio2Bridge = IOAudio2BridgeController()
    @AppStorage(AudioRepeaterPreferences.ioAudio2RingOverwriteEnabled)
    private var ioAudio2RingOverwriteEnabled = false
    @State private var items: [AudioItem] = []
    @State private var defaultRepeatText = "1"
    @State private var sameFileDelayText = "0"
    @State private var differentFileDelayText = "0"
    @State private var isImporterPresented = false
    @State private var isImporting = false
    @State private var alertMessage: String?
    @State private var settings = PlaybackSettings()
    @State private var presentedSheet: PlaybackSheet?
    @State private var didLoadLibrary = false

    private var defaultRepeat: Int? {
        positiveInt(defaultRepeatText)
    }

    private var sameFileDelay: Double? {
        delaySeconds(sameFileDelayText)
    }

    private var differentFileDelay: Double? {
        delaySeconds(differentFileDelayText)
    }

    private var isPlaybackRunning: Bool {
        player.state.isRunning || ioAudio2Bridge.state.isRunning
    }

    private var activePlaybackState: PlaybackState {
        ioAudio2Bridge.state.isRunning ? ioAudio2Bridge.state : player.state
    }

    private var enabledItems: [AudioItem] {
        items.filter(\.isEnabled)
    }

    private var canPlay: Bool {
        !isPlaybackRunning &&
            !isImporting &&
            !enabledItems.isEmpty &&
            sameFileDelay != nil &&
            differentFileDelay != nil &&
            enabledItems.allSatisfy { $0.repeatCount != nil }
    }

    var body: some View {
        NavigationStack {
            List {
                playbackSettings
                Section("Queue controls") { controls }
                listContent
            }
            .listStyle(.insetGrouped)
            .navigationTitle("AudioRepeater")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                playbackControls.padding(.horizontal).padding(.vertical, 8).background(.regularMaterial)
            }
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { EditButton().disabled(isPlaybackRunning) } }
            .sheet(item: $presentedSheet) { sheet in
                if sheet == .recordings {
                    RecordingLibraryView { url in
                        guard !items.contains(where: { $0.localURL == url }) else { return }
                        items.append(AudioItem(sourceURL: url, localURL: url, displayName: url.lastPathComponent,
                            repeatText: defaultRepeatText, deleteLocalFileOnRemove: false))
                    }
                } else {
                    PlaybackEffectEditor(settings: $settings, sheet: sheet)
                }
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [ImportManager.wavType],
                allowsMultipleSelection: true,
                onCompletion: handleImportResult
            )
            .alert("Notice", isPresented: alertBinding) {
                Button("OK", role: .cancel) {
                    alertMessage = nil
                }
            } message: {
                Text(alertMessage ?? "")
            }
            .onReceive(player.$errorMessage.compactMap { $0 }) { message in
                alertMessage = message
            }
            .onReceive(ioAudio2Bridge.$errorMessage.compactMap { $0 }) { message in
                alertMessage = message
            }
            .task {
                restoreLibrary()
                seedSimulatorQueueIfRequested()
                ioAudio2Bridge.resumeMonitoringIfNeeded()
                await monitorRemotePlaybackRequests()
            }
            .onChange(of: items) { _ in persistLibrary() }
            .onChange(of: settings) { _ in persistLibrary() }
            .onChange(of: [defaultRepeatText, sameFileDelayText, differentFileDelayText]) { _ in persistLibrary() }
            .onDisappear {
                player.stop()
                persistLibrary()
            }
        }
    }

    private var playbackSettings: some View {
        Group {
            Section("Playback") {
                Picker("Playback path", selection: $settings.path) {
                    ForEach(PlaybackPath.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("playbackPath")
                .disabled(isPlaybackRunning || ioAudio2RingOverwriteEnabled)
                DisclosureGroup("Experimental bridge") {
                    Toggle("IOAudio2 ring overwrite", isOn: $ioAudio2RingOverwriteEnabled)
                        .disabled(isPlaybackRunning)
                    Text("Requires the separately configured Mac IOAudio2 bridge.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Playback effects") {
                HStack {
                    Picker("Effect", selection: $settings.effect) {
                        ForEach(PlaybackEffect.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("effectPicker")
                    Button("Settings") {
                        presentedSheet = settings.effect == .equalizer ? .equalizer : .dynamics
                    }
                    .disabled(settings.effect == .off)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("effectSettings")
                }
                .disabled(isPlaybackRunning || ioAudio2RingOverwriteEnabled || settings.path != .avAudioEngine)
                if settings.path != .avAudioEngine {
                    Text("Effects require AVAudioEngine.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Playback output") {
                Picker("Output", selection: $settings.output) {
                    ForEach(PlaybackOutput.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Session mode", selection: $settings.sessionMode) {
                    ForEach(PlaybackSessionMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .disabled(settings.recordMicrophone || settings.output == .receiver)
                Text("Active mode: \(settings.effectiveSessionMode.label)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(player.outputDescription).font(.caption).foregroundStyle(.secondary)
            }
            .disabled(isPlaybackRunning || ioAudio2RingOverwriteEnabled)
            Section("Recording") {
                Toggle("Record microphone with playback", isOn: $settings.recordMicrophone)
                    .accessibilityIdentifier("recordMicrophone")
                #if canImport(ScreenCaptureKit) && !targetEnvironment(simulator)
                if #available(iOS 27.0, *) {
                    Toggle("Capture app audio", isOn: $settings.captureSystemAudio)
                }
                #endif
                if settings.recordMicrophone {
                    Text("48 kHz mono PCM16 WAV. Measurement mode minimizes input processing. Voice chat modes request the system's chat session policy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(player.recordingStatus).font(.caption).foregroundStyle(.secondary)
                Button { presentedSheet = .recordings } label: {
                    Label("Recordings", systemImage: "waveform.badge.mic")
                }
                .accessibilityIdentifier("openRecordings")
            }
            .disabled(isPlaybackRunning || ioAudio2RingOverwriteEnabled)
        }
    }

    private func restoreLibrary() {
        guard !didLoadLibrary else { return }
        do {
            if let saved = try LibraryStore().load() {
                items = saved.items
                defaultRepeatText = saved.snapshot.defaultRepeats
                sameFileDelayText = saved.snapshot.repeatDelay
                differentFileDelayText = saved.snapshot.fileDelay
                settings = saved.snapshot.settings
            } else {
                loadPinnedLibraryIfPresent()
            }
        } catch {
            alertMessage = "Could not restore the saved queue: \(error.localizedDescription)"
        }
        didLoadLibrary = true
    }

    private func seedSimulatorQueueIfRequested() {
        #if DEBUG && targetEnvironment(simulator)
        guard ProcessInfo.processInfo.arguments.contains("--ui-test"), items.isEmpty else { return }
        do {
            let store = LibraryStore()
            try store.prepareDirectory(store.importsDirectory)
            let url = store.importsDirectory.appendingPathComponent("test-tone.wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)!
            buffer.frameLength = buffer.frameCapacity
            for index in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![0][index] = 0.02 * sin(Float(index) * 2 * .pi * 910 / 48_000)
            }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            items = [AudioItem(sourceURL: url, localURL: url, displayName: "Test tone.wav", repeatText: "20")]
            persistLibrary()
        } catch { alertMessage = error.localizedDescription }
        #endif
    }

    private func persistLibrary() {
        guard didLoadLibrary else { return }
        do {
            try LibraryStore().save(items: items, defaultRepeats: defaultRepeatText,
                repeatDelay: sameFileDelayText, fileDelay: differentFileDelayText, settings: settings)
        } catch { alertMessage = "Could not save the queue: \(error.localizedDescription)" }
    }

    private func startManualPlayback() {
        let queue = items.compactMap { item -> QueueItem? in
            guard item.isEnabled, let repeats = item.repeatCount else { return nil }
            return QueueItem(itemKey: item.playbackKey, sourceURL: item.sourceURL, localURL: item.localURL,
                displayName: item.displayName, repeatCount: repeats)
        }
        if ioAudio2RingOverwriteEnabled {
            ioAudio2Bridge.play(items: queue, sameFileDelaySeconds: sameFileDelay ?? 0,
                differentFileDelaySeconds: differentFileDelay ?? 0)
            return
        }
        do {
            try settings.validate()
            let store = LibraryStore()
            let microphoneURL = settings.recordMicrophone ? try store.recordingURL(extension: "wav") : nil
            let captureURL: URL?
            if settings.captureSystemAudio {
                guard #available(iOS 27.0, *) else { throw AudioQueueError.screenCaptureUnavailable }
                captureURL = try store.recordingURL(extension: "caf")
            } else { captureURL = nil }
            player.play(items: queue, sameFileDelaySeconds: sameFileDelay ?? 0,
                differentFileDelaySeconds: differentFileDelay ?? 0, playbackPath: settings.path,
                systemAudioCaptureURL: captureURL, processing: settings, microphoneRecordingURL: microphoneURL)
        } catch { alertMessage = error.localizedDescription }
    }

    @MainActor
    private func loadPinnedLibraryIfPresent() {
        guard items.isEmpty else { return }

        do {
            let fileManager = FileManager.default
            let documentsURL = try fileManager.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let audioDirectoryURL = documentsURL.appendingPathComponent(
                "RemoteAudio",
                isDirectory: true
            )
            let pinnedURLs = try fileManager.contentsOfDirectory(
                at: audioDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter {
                $0.pathExtension.lowercased() == "wav" &&
                    $0.lastPathComponent.hasPrefix("pinned_")
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare(
                    $1.lastPathComponent
                ) == .orderedAscending
            }

            guard !pinnedURLs.isEmpty else { return }
            items = pinnedURLs.map { url in
                let stem = url.deletingPathExtension().lastPathComponent
                let displayName = String(stem.dropFirst("pinned_".count))
                    .replacingOccurrences(of: "_", with: " ")
                return AudioItem(
                    sourceURL: url,
                    localURL: url,
                    displayName: displayName,
                    repeatText: defaultRepeatText,
                    deleteLocalFileOnRemove: false
                )
            }
            print("AudioRepeaterIOS pinned library loaded items=\(items.count)")
            let receipt: [String: Any] = [
                "schema": "audiorepeater_pinned_library_v1",
                "loadedAt": ISO8601DateFormatter().string(from: Date()),
                "itemCount": items.count,
                "displayNames": items.map(\.displayName),
                "fileNames": pinnedURLs.map(\.lastPathComponent),
            ]
            let receiptData = try JSONSerialization.data(
                withJSONObject: receipt,
                options: [.prettyPrinted, .sortedKeys]
            )
            try receiptData.write(
                to: documentsURL.appendingPathComponent(
                    "pinned-library-status.json",
                    isDirectory: false
                ),
                options: .atomic
            )
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            alertMessage = error.localizedDescription
            print(
                "AudioRepeaterIOS pinned library error " +
                    error.localizedDescription
            )
        }
    }

    @MainActor
    private func monitorRemotePlaybackRequests() async {
        while !Task.isCancelled {
            // The IOAudio2 bridge still needs AudioRepeater's silent
            // AVAudioEngine keepalive while ring overwrite is active.
            if !player.state.isRunning {
                consumeRemotePlaybackRequestIfPresent()
            }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
        }
    }

    @MainActor
    private func consumeRemotePlaybackRequestIfPresent() {
        do {
            guard let request = try RemotePlaybackRequestLoader.consumeIfPresent() else {
                return
            }

            let isRingKeepalive = request.queueItems.count == 1 &&
                request.queueItems[0].displayName ==
                    "c0004 AudioRepeater ring keepalive"
            if !isRingKeepalive {
                if let processing = request.processing { settings = processing }
                settings.path = request.playbackPath
                items = request.queueItems.map { item in
                    AudioItem(
                        playbackKey: item.itemKey,
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
                differentFileDelayText =
                    delayText(request.differentFileDelaySeconds)
            }

            print(
                "AudioRepeaterIOS remote request loaded items=\(request.queueItems.count) " +
                    "sameDelay=\(request.sameFileDelaySeconds) " +
                    "diffDelay=\(request.differentFileDelaySeconds) " +
                    "path=\(request.playbackPath.rawValue) " +
                    "pan=\(request.avAudioEnginePan) " +
                    "gain=\(request.avAudioEngineGain) " +
                    "directPCM=\(request.avAudioEngineDirectPCM) " +
                    "isolateSignals=\(request.avAudioEngineIsolateSignals) " +
                    "eqFrequency=\(request.avAudioEngineEQFrequency) " +
                    "eqGain=\(request.avAudioEngineEQGain) " +
                    "eqBandwidth=\(request.avAudioEngineEQBandwidth) " +
                    "automaticFormat=\(request.avAudioEngineAutomaticFormat) " +
                    "completionCallback=\(request.avAudioEngineCompletionCallback) " +
                    "stopEachSignal=\(request.avAudioEngineStopPlayerEachSignal) " +
                    "completionDelayFrames=\(request.avAudioEngineCompletionDelayFrames) " +
                    "stereoMode=\(request.avAudioEngineStereoMode) " +
                    "ioBuffer=\(request.preferredIOBufferDuration) " +
                    "forceMaxVolume=\(request.forceMaximumOutputVolume) " +
                    "mode=\(request.avAudioSessionMode) " +
                    "captureSystemAudio=\(request.captureSystemAudio)"
            )
            player.play(
                items: request.queueItems,
                sameFileDelaySeconds: request.sameFileDelaySeconds,
                differentFileDelaySeconds: request.differentFileDelaySeconds,
                playbackPath: request.playbackPath,
                avAudioEnginePan: request.avAudioEnginePan,
                avAudioEngineGain: request.avAudioEngineGain,
                avAudioEngineDirectPCM: request.avAudioEngineDirectPCM,
                avAudioEngineIsolateSignals:
                    request.avAudioEngineIsolateSignals,
                avAudioEngineEQFrequency:
                    request.avAudioEngineEQFrequency,
                avAudioEngineEQGain: request.avAudioEngineEQGain,
                avAudioEngineEQBandwidth:
                    request.avAudioEngineEQBandwidth,
                avAudioEngineAutomaticFormat:
                    request.avAudioEngineAutomaticFormat,
                avAudioEngineCompletionCallback:
                    request.avAudioEngineCompletionCallback,
                avAudioEngineStopPlayerEachSignal:
                    request.avAudioEngineStopPlayerEachSignal,
                avAudioEngineCompletionDelayFrames:
                    request.avAudioEngineCompletionDelayFrames,
                avAudioEngineStereoMode:
                    request.avAudioEngineStereoMode,
                preferredIOBufferDuration:
                    request.preferredIOBufferDuration,
                forceMaximumOutputVolume:
                    request.forceMaximumOutputVolume,
                avAudioSessionMode: request.avAudioSessionMode,
                systemAudioCaptureURL: request.systemAudioCaptureURL,
                eventLogURL: request.eventLogURL,
                processing: request.processing,
                microphoneRecordingURL: request.microphoneRecordingURL
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
                labeledTextField(title: "Default repeats", text: $defaultRepeatText,
                    keyboardType: .numberPad, sanitize: sanitizeRepeatInput)
                Button { isImporterPresented = true } label: {
                    Label(isImporting ? "Adding" : "Add files", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPlaybackRunning || isImporting || defaultRepeat == nil)
                .accessibilityIdentifier("addFiles")
            }
            HStack {
                Button("Apply repeats to all") {
                    for index in items.indices { items[index].repeatText = defaultRepeatText }
                }
                .disabled(isPlaybackRunning || defaultRepeat == nil || items.isEmpty)
                Spacer()
                Text("Repeats").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repeat delay (s)").font(.caption)
                    labeledTextField(title: "Repeat delay (s)", text: $sameFileDelayText,
                        keyboardType: .decimalPad, sanitize: sanitizeDelayInput)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("File delay (s)").font(.caption)
                    labeledTextField(title: "File delay (s)", text: $differentFileDelayText,
                        keyboardType: .decimalPad, sanitize: sanitizeDelayInput)
                }
            }
        }
    }

    private var playbackControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: startManualPlayback) {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(ioAudio2RingOverwriteEnabled ? .orange : .blue)
                .disabled(!canPlay)
                .accessibilityIdentifier("playQueue")
                Button {
                    if ioAudio2Bridge.state.isRunning { ioAudio2Bridge.stop() }
                    if player.state.isRunning { player.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!isPlaybackRunning)
                .accessibilityIdentifier("stopQueue")
            }
            playbackStatusCard
        }
    }

    private var listContent: some View {
        Section {
            if items.isEmpty {
                Label("No WAV files. Add files to build a queue.", systemImage: "music.note")
                    .foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                HStack {
                    Button(enabledItems.count == items.count ? "Deselect all" : "Select all") {
                        let enabled = enabledItems.count != items.count
                        for index in items.indices { items[index].isEnabled = enabled }
                    }
                    .disabled(isPlaybackRunning)
                    Spacer()
                    Text("\(enabledItems.count)/\(items.count) enabled").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                ForEach($items) { $item in
                    AudioItemRow(item: $item, isPlaying: isPlaybackRunning,
                        playbackProgress: playbackProgress(for: item)) {
                        if let index = items.firstIndex(where: { $0.id == item.id }) {
                            let removed = items.remove(at: index)
                            ImportManager.deleteLocalFileIfOwned(removed)
                        }
                    }
                }
                .onMove { source, destination in
                    guard !isPlaybackRunning else { return }
                    items.move(fromOffsets: source, toOffset: destination)
                }
                .moveDisabled(isPlaybackRunning)
            }
        } header: { Text("Queue") }
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
            .disabled(isPlaybackRunning)
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
                    alertMessage = "No WAV files were added."
                } else if importResult.skippedCount > 0 {
                    alertMessage = "Added \(importResult.items.count); skipped \(importResult.skippedCount)"
                } else {
                    alertMessage = "Added \(importResult.items.count) files"
                }
            } catch {
                alertMessage = error.localizedDescription
            }

        case let .failure(error):
            alertMessage = error.localizedDescription
        }
    }

    private var playbackStatusCard: some View {
        HStack(spacing: 10) {
            Image(
                systemName: isPlaybackRunning
                    ? "waveform.circle.fill"
                    : "waveform.circle"
            )
            .font(.title3)
            .foregroundStyle(
                ioAudio2RingOverwriteEnabled ? .orange : .blue
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    ioAudio2RingOverwriteEnabled
                        ? "IOAudio2 ring overwrite"
                        : settings.path.label
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Text(activePlaybackState.statusText)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    isPlaybackRunning
                        ? Color.accentColor.opacity(0.14)
                        : Color.secondary.opacity(0.08)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isPlaybackRunning
                        ? Color.accentColor.opacity(0.7)
                        : Color.secondary.opacity(0.2),
                    lineWidth: isPlaybackRunning ? 1.5 : 1
                )
        )
    }

    private func playbackProgress(
        for item: AudioItem
    ) -> (current: Int, total: Int)? {
        if case let .playing(
            itemKey,
            _,
            currentRepeat,
            totalRepeats
        ) = activePlaybackState,
           itemKey == item.playbackKey {
            return (currentRepeat, totalRepeats)
        }
        return nil
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
    let playbackProgress: (current: Int, total: Int)?
    let onDelete: () -> Void

    private var isCurrent: Bool {
        playbackProgress != nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                item.isEnabled.toggle()
            } label: {
                Image(
                    systemName:
                        item.isEnabled
                            ? "checkmark.square.fill"
                            : "square"
                )
                .font(.title3)
                .foregroundStyle(
                    item.isEnabled ? Color.accentColor : Color.secondary
                )
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(isPlaying)
            .accessibilityLabel(
                item.isEnabled ? "Disable item" : "Enable item"
            )

            Image(systemName: isCurrent ? "waveform" : "music.note")
                .font(isCurrent ? .title3 : .body)
                .foregroundStyle(isCurrent ? .orange : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(
                        isCurrent
                            ? .subheadline.weight(.bold)
                            : .subheadline
                    )
                    .lineLimit(2)
                Text(item.localURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let playbackProgress {
                    HStack(spacing: 8) {
                        Text(
                            "\(playbackProgress.current) / " +
                                "\(playbackProgress.total) repeats"
                        )
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                        ProgressView(
                            value: Double(playbackProgress.current),
                            total: Double(playbackProgress.total)
                        )
                        .tint(.orange)
                    }
                }
            }

            Spacer()

            TextField("Repeats", text: $item.repeatText)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 76)
                .disabled(isPlaying || !item.isEnabled)
                .onChange(of: item.repeatText) { newValue in
                    let sanitized = sanitizeRepeatInput(newValue)
                    if sanitized != newValue {
                        item.repeatText = sanitized
                    }
                }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(isPlaying)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .opacity(item.isEnabled ? 1 : 0.5)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isCurrent ? Color.orange.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isCurrent ? Color.orange : Color.clear,
                    lineWidth: 2
                )
        )
        .animation(.easeInOut(duration: 0.18), value: isCurrent)
        .listRowBackground(Color.clear)
    }
}

private struct IOAudio2BridgeRequest: Encodable {
    struct Item: Encodable {
        let itemKey: String
        let fileName: String
        let displayName: String
        let repeatCount: Int
    }

    let schema: String
    let requestID: String
    let createdAt: String
    let items: [Item]
    let sameFileDelaySeconds: Double
    let differentFileDelaySeconds: Double
}

private struct IOAudio2BridgeStatus: Decodable {
    let schema: String
    let requestID: String
    let state: String
    let itemKey: String?
    let displayName: String?
    let currentRepeat: Int?
    let totalRepeats: Int?
    let message: String?
    let startedAtUnixSeconds: Double?
    let repeatIntervalSeconds: Double?
}

private struct IOAudio2BridgeCancel: Encodable {
    let schema: String
    let requestID: String
    let createdAt: String
}

@MainActor
private final class IOAudio2BridgeController: ObservableObject {
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var errorMessage: String?

    private let activeRequestDefaultsKey =
        "ioAudio2RingOverwriteActiveRequestID"
    private let requestFileName = "ioaudio2-playback-request.json"
    private let statusFileName = "ioaudio2-playback-status.json"
    private let cancelFileName = "ioaudio2-playback-cancel.json"
    private var monitorTask: Task<Void, Never>?
    private var activeRequestID: String?

    func play(
        items: [QueueItem],
        sameFileDelaySeconds: Double,
        differentFileDelaySeconds: Double
    ) {
        guard !state.isRunning, !items.isEmpty else { return }
        errorMessage = nil

        do {
            let requestID = UUID().uuidString
            let requestItems = try stageRequestItems(items)
            let request = IOAudio2BridgeRequest(
                schema: "audiorepeater_ioaudio2_request_v1",
                requestID: requestID,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                items: requestItems,
                sameFileDelaySeconds: sameFileDelaySeconds,
                differentFileDelaySeconds: differentFileDelaySeconds
            )
            let fileManager = FileManager.default
            let urls = try bridgeURLs()
            try? fileManager.removeItem(at: urls.status)
            try? fileManager.removeItem(at: urls.cancel)
            let data = try JSONEncoder().encode(request)
            try data.write(to: urls.request, options: .atomic)

            activeRequestID = requestID
            UserDefaults.standard.set(
                requestID,
                forKey: activeRequestDefaultsKey
            )
            state = .preparing(message: "Connecting to the IOAudio2 bridge")
            startMonitoring(requestID: requestID)
        } catch {
            fail(error.localizedDescription)
        }
    }

    func stop() {
        guard let requestID = activeRequestID else {
            state = .idle
            return
        }

        do {
            let cancel = IOAudio2BridgeCancel(
                schema: "audiorepeater_ioaudio2_cancel_v1",
                requestID: requestID,
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            try JSONEncoder().encode(cancel).write(
                to: bridgeURLs().cancel,
                options: .atomic
            )
            state = .preparing(message: "Stopping IOAudio2 playback")
        } catch {
            fail(error.localizedDescription)
        }
    }

    func resumeMonitoringIfNeeded() {
        guard activeRequestID == nil,
              let requestID = UserDefaults.standard.string(
                  forKey: activeRequestDefaultsKey
              ),
              !requestID.isEmpty else {
            return
        }
        activeRequestID = requestID
        state = .preparing(message: "Restoring IOAudio2 playback status")
        startMonitoring(requestID: requestID)
    }

    private func startMonitoring(requestID: String) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            await self?.monitor(requestID: requestID)
        }
    }

    private func monitor(requestID: String) async {
        var emptyPollCount = 0
        while !Task.isCancelled, activeRequestID == requestID {
            do {
                let statusURL = try bridgeURLs().status
                guard FileManager.default.fileExists(
                    atPath: statusURL.path
                ) else {
                    emptyPollCount += 1
                    if emptyPollCount >= 150 {
                        fail(
                            "The Mac IOAudio2 bridge is not responding. " +
                                "Check the connection between the Mac and iPhone."
                        )
                        return
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }

                let status = try JSONDecoder().decode(
                    IOAudio2BridgeStatus.self,
                    from: Data(contentsOf: statusURL)
                )
                guard status.requestID == requestID else {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                emptyPollCount = 0
                if apply(status) {
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                emptyPollCount += 1
                if emptyPollCount >= 150 {
                    fail(error.localizedDescription)
                    return
                }
            }

            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
        }
    }

    private func apply(_ status: IOAudio2BridgeStatus) -> Bool {
        switch status.state {
        case "accepted":
            state = .preparing(
                message: status.message ?? "Preparing the IOAudio2 ring"
            )
            return false
        case "playing":
            guard let itemKey = status.itemKey,
                  let displayName = status.displayName,
                  let currentRepeat = status.currentRepeat,
                  let totalRepeats = status.totalRepeats else {
                return false
            }
            var displayedRepeat = currentRepeat
            if let startedAt = status.startedAtUnixSeconds,
               let interval = status.repeatIntervalSeconds,
               interval > 0 {
                let elapsed = max(
                    0,
                    Date().timeIntervalSince1970 - startedAt
                )
                let timelineRepeat = Int(elapsed / interval) + 1
                displayedRepeat = min(
                    totalRepeats,
                    max(currentRepeat, timelineRepeat)
                )
            }
            state = .playing(
                itemKey: itemKey,
                displayName: displayName,
                currentRepeat: displayedRepeat,
                totalRepeats: totalRepeats
            )
            return false
        case "complete":
            finish()
            return true
        case "cancelled":
            finish()
            return true
        case "error":
            fail(status.message ?? "IOAudio2 playback failed.")
            return true
        default:
            return false
        }
    }

    private func stageRequestItems(
        _ items: [QueueItem]
    ) throws -> [IOAudio2BridgeRequest.Item] {
        let urls = try bridgeURLs()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: urls.audioDirectory,
            withIntermediateDirectories: true
        )

        return try items.map { item in
            let sourceURL = item.localURL
            guard sourceURL.pathExtension.lowercased() == "wav",
                  fileManager.fileExists(atPath: sourceURL.path) else {
                throw IOAudio2BridgeError.missingWAV(
                    sourceURL.lastPathComponent
                )
            }

            let fileName: String
            if sourceURL.deletingLastPathComponent().standardizedFileURL ==
                urls.audioDirectory.standardizedFileURL {
                fileName = sourceURL.lastPathComponent
            } else {
                let safeStem = sourceURL
                    .deletingPathExtension()
                    .lastPathComponent
                    .unicodeScalars
                    .map { scalar -> Character in
                        CharacterSet.alphanumerics.contains(scalar)
                            ? Character(String(scalar))
                            : "_"
                    }
                fileName =
                    "ioaudio2_\(UUID().uuidString)_\(String(safeStem)).wav"
                let destination = urls.audioDirectory.appendingPathComponent(
                    fileName,
                    isDirectory: false
                )
                try fileManager.copyItem(at: sourceURL, to: destination)
            }

            return IOAudio2BridgeRequest.Item(
                itemKey: item.itemKey,
                fileName: fileName,
                displayName: item.displayName,
                repeatCount: item.repeatCount
            )
        }
    }

    private func bridgeURLs() throws -> (
        request: URL,
        status: URL,
        cancel: URL,
        audioDirectory: URL
    ) {
        let documentsURL = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return (
            documentsURL.appendingPathComponent(
                requestFileName,
                isDirectory: false
            ),
            documentsURL.appendingPathComponent(
                statusFileName,
                isDirectory: false
            ),
            documentsURL.appendingPathComponent(
                cancelFileName,
                isDirectory: false
            ),
            documentsURL.appendingPathComponent(
                "RemoteAudio",
                isDirectory: true
            )
        )
    }

    private func finish() {
        monitorTask?.cancel()
        monitorTask = nil
        activeRequestID = nil
        UserDefaults.standard.removeObject(
            forKey: activeRequestDefaultsKey
        )
        state = .idle
    }

    private func fail(_ message: String) {
        errorMessage = message
        finish()
    }
}

private enum IOAudio2BridgeError: LocalizedError {
    case missingWAV(String)

    var errorDescription: String? {
        switch self {
        case let .missingWAV(fileName):
            return "WAV file not found for IOAudio2 playback: \(fileName)"
        }
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
