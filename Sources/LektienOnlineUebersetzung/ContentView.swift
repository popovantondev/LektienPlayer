import AVFoundation
import AppKit
import PlayerCore
import PlayerTranslation
import PlayerMedia
import PlayerExport
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var playback = PlaybackController()
    @StateObject private var preparation = PreparationController()
    @StateObject private var translation = TranslationController()
    @StateObject private var speech = SpeechController()
    @StateObject private var streaming = StreamingTranslationController()
    @StateObject private var recognition = RecognitionController()
    @StateObject private var speechExport = SpeechExportController()
    @StateObject private var network = NetworkController()
    @StateObject private var telegram = TelegramController.shared
    @State private var showsNetwork = false
    @State private var showsTelegramUpload = false
    @State private var exportDestination: URL?
    @State private var videoExportSelection: VideoExportSelection?
    @State private var pendingVideoExport: VideoExportRequest?
    @State private var exportVideo: VideoExportRequest?
    @State private var sourceSelection: RecognitionSourceSelection?
    @State private var sourceLoading = false
    @State private var sourceCancellation: MediaCancellation?
    @State private var sourceGeneration = UUID()
    @State private var recognitionStreamIndex: Int?
    @State private var savedHistory = LectureHistory()
    @State private var lastSavedPosition = 0.0
    @StateObject private var usage = UsageController()
    @StateObject private var windowState = PlayerWindowState()
    @ObservedObject private var menus = PlayerMenuController.shared
    @AppStorage(AppLocalization.preferenceKey) private var language: InterfaceLanguage = .german
    @AppStorage("interface.languageConfirmed") private var languageConfirmed = false
    @AppStorage("player.fullscreenFill") private var fullscreenFill = true
    @AppStorage("player.videoUnderHeader") private var videoUnderHeader = false
    private let voice = "kseniya"
    @AppStorage("player.autoHide") private var autoHide = true
    @AppStorage("player.controlsMode") private var controlsMode: PlayerControlsMode = .sliding
    @AppStorage("speech.bufferMinutes") private var bufferMinutes = 6.0
    @AppStorage("speech.pausedMinutes") private var pausedMinutes = 10.0
    @AppStorage("subtitles.ruColor") private var ruColor = "FFFFFF"
    @AppStorage("subtitles.deColor") private var deColor = "FFE45C"
    @AppStorage("subtitles.outlineColor") private var outlineColor = "000000"
    @AppStorage("subtitles.size") private var subtitleSize = 24.0
    @AppStorage("subtitles.stroke") private var subtitleStroke = 2.0
    @AppStorage("subtitles.background") private var subtitleBackground = 0.35
    @State private var controlsHeight: CGFloat = 150
    @State private var showsAttachments = false
    @State private var showsUsage = false
    @Environment(\.openWindow) private var openWindow
    @AppStorage("translation.model") private var translationModel = "Luna"
    @AppStorage("translation.effort") private var reasoningEffort = "Среднее"
    @AppStorage("review.model") private var reviewModel = "Terra"
    @AppStorage("review.effort") private var reviewEffort = "Среднее"
    @State private var lecture: LocalLecture?
    @State private var showsGerman = true
    @State private var showsRussian = true
    @State private var subtitleError: String?
    @State private var libraryPresentation: LibraryPresentation?
    @State private var showsAudioMixer = false
    @State private var showsPronunciation = false
    @State private var libraryDirectory: URL?
    @State private var adjacentSubtitles: LibraryLecture?
    @State private var telegramStream: TelegramStreamSelection?
    @State private var queuedRequest: LibraryPreparationRequest?
    @StateObject private var libraryQueue = LibraryQueueController.shared

    private var reservedHeaderHeight: CGFloat {
        windowState.isFullscreen || videoUnderHeader ? 0 : PlayerChrome.headerHeight
    }

    private var playerView: some View {
        ZStack(alignment: .bottom) {
            PlayerSurface(player: playback.player, videoSize: playback.videoSize,
                          panelHeight: controlsMode == .standard && !windowState.isFullscreen ? controlsHeight : 0,
                          headerHeight: reservedHeaderHeight,
                          mediaURL: lecture?.videoURL, togglePlayback: { playback.togglePlayback() },
                          windowState: windowState, menuActions: menuActions, fullscreenFill: fullscreenFill)
                .background(Color.black)
                .padding(.top, reservedHeaderHeight)
                .padding(.bottom, controlsMode == .standard && !windowState.isFullscreen ? controlsHeight : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PlayerControlsOverlay(mode: controlsMode, autoHide: autoHide, playing: playback.playbackRequested,
                pinned: showsAudioMixer || showsAttachments || showsUsage || libraryPresentation != nil || menus.isTracking || !languageConfirmed,
                fullscreen: windowState.isFullscreen, manualToggle: windowState.controlsToggle,
                panelHeight: $controlsHeight, subtitles: { subtitlesView }, controls: { controls }, header: { headerView })
        }
        .frame(minWidth: 780, minHeight: 360)
        .ignoresSafeArea()
        .background(Color.black)
        .onChange(of: playback.playbackRequested) { _, _ in updateBufferTarget(); persistHistory() }
        .onChange(of: bufferMinutes) { _, _ in updateBufferTarget() }
        .onChange(of: pausedMinutes) { _, _ in updateBufferTarget() }
        .task {
            while !Task.isCancelled {
                await usage.refresh()
                do { try await Task.sleep(for: .seconds(180)) } catch { return }
            }
        }

    }

    private var headerView: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                WindowDragArea()
                Text(lecture?.videoURL.lastPathComponent ?? translationText("app.title"))
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    .allowsHitTesting(false)
            }.frame(minWidth: 70, maxWidth: .infinity)
            headerButtons
            Button { windowState.toggleFullscreen() } label: {
                Image(systemName: windowState.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }.help(translationText("player.fullscreen"))
        }.padding(.leading, windowState.isFullscreen ? 12 : 82).padding(.trailing, 12)
            .buttonStyle(.borderless).controlSize(.small).focusEffectDisabled()
    }

    private var headerButtons: some View {
        HStack(spacing: 8) {
                HeaderOpenButton(title: translationText("player.openShort"), action: chooseVideo).fixedSize()
                Button(translationText("player.libraryShort"), systemImage: "rectangle.stack") {
                    showLibrary()
                }
                Button(translationText("settings.shortTitle")) { openWindow(id: "translation-settings") }
                Menu {
                    if exportDestination != nil || speechExport.isRunning {
                        Button(translationText("export.cancel"), action: cancelExport)
                    } else {
                        Button(translationText("export.save")) { saveSpeech() }
                            .disabled(lecture == nil || playback.snapshot.duration == nil || translation.isRunning || sourceLoading || (lecture?.russianSubtitles == nil && !streaming.isRunning))
                        Button(translationText("export.video"), action: chooseVideoExport)
                            .disabled(lecture == nil || playback.snapshot.duration == nil || translation.isRunning || sourceLoading || (lecture?.russianSubtitles == nil && !streaming.isRunning))
                    }
                    if let result = speechExport.result {
                        Button(translationText("export.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([result]) }
                        if telegram.lanChatID != nil {
                            Button(translationText("telegram.upload.result")) { showsTelegramUpload = true }
                        }
                    }
                    Divider()
                    Button(translationText("network.title")) { showsNetwork = true }
                    Button(translationText("recognition.title")) { prepareVideoSubtitles(automatic: false) }
                        .disabled(lecture == nil || sourceLoading || streaming.isRunning || recognition.isRunning || speech.isRunning)
                    Button(translationText("pronunciation.title")) { showsPronunciation = true }
                        .disabled(lecture == nil || exportDestination != nil || speechExport.isRunning)
                    Button(translationText("review.start"), action: reviewLecture).disabled(speech.isRunning || !canReview)
                    Divider()
                    Button(translationText("preparation.title"), action: prepareForTranslation)
                        .disabled(lecture?.germanSubtitles == nil)
                    Text(translationText("preparation.help"))
                } label: { Text(translationText("player.more")) }
                if streaming.isRunning || recognition.isRunning {
                    Button(translationText("stream.stop"), action: stopPreparation)
                } else if translation.isRunning {
                    Button(translationText("translation.stop"), action: translation.stop)
                } else {
                    Button(translationText("translation.start"), action: translateLecture)
                        .help(translationText("translation.help"))
                        .disabled(lecture == nil || sourceLoading)
                }
                if streaming.isRunning {
                    Button(translationText(playback.russianVoiceEnabled ? "speech.turnOff" : "speech.turnOn")) {
                        playback.russianVoiceEnabled.toggle()
                    }
                } else if speech.isRunning {
                    Button(translationText("speech.stop")) { cancelExport(); speech.stop(); playback.russianVoiceEnabled = false }
                } else {
                    Button(translationText("speech.start"), action: synthesizeSpeech)
                        .disabled(translation.isRunning || lecture?.russianSubtitles?.cues.isEmpty != false)
                }
        }.buttonStyle(.borderless).controlSize(.small).focusEffectDisabled()
    }

    private var menuActions: PlayerActions {
        PlayerActions(perform: { command in
            switch command {
            case .openVideo: chooseVideo()
            case .openLibrary: showLibrary()
            case .playPause: playback.togglePlayback()
            case .translate: translateLecture()
            case .prepare: prepareForTranslation()
            case .settings: openWindow(id: "translation-settings")
            case .subtitleSettings: openWindow(id: "subtitle-settings")
            case .help: openWindow(id: "player-help")
            case .fullscreen: windowState.toggleFullscreen()
            case .controls: windowState.controlsToggle += 1
            }
        }, canPlay: lecture != nil,
        canTranslate: lecture != nil && !streaming.isRunning && !recognition.isRunning && !translation.isRunning && !sourceLoading)
    }

    private var observedPlayback: some View {
        playerView
        .onChange(of: recognition.ready) { _, chunks in
            guard !chunks.isEmpty else { return }
            streaming.supplyRecognized(recognition.sourceChunks)
            lecture?.germanSubtitles = recognition.document
        }
        .onChange(of: recognition.completedURL) { _, url in
            guard let url else { return }
            lecture?.germanSubtitleURL = url
            if let document = recognition.document {
                savedHistory.recognitionSubtitle = url.lastPathComponent
                savedHistory.recognitionSubtitleHash = MediaPublication.hash(Data(MediaPublication.srt(document).utf8))
                persistHistory()
            }
            exportIfReady()
            syncCurrentLibraryStatus()
        }
        .onChange(of: recognition.errorMessage) { _, error in
            if error != nil { cancelExport(); streaming.stop(); speech.stop(); playback.pause() }
        }
        .onChange(of: translation.progress?.completed) { _, _ in
            if !translation.isReview, let document = translation.progress?.document {
                lecture?.russianSubtitles = document
            }
        }
        .onChange(of: translation.result?.subtitleURL) { _, _ in
            if let result = translation.result {
                lecture?.russianSubtitles = result.document
                lecture?.russianSubtitleURL = result.subtitleURL
            }
            syncCurrentLibraryStatus()
        }
        .onChange(of: streaming.ready) { _, chunks in
            guard !chunks.isEmpty else { return }
            speech.supply(chunks)
            if let document = streaming.document { lecture?.russianSubtitles = document }
        }
        .onChange(of: streaming.completedURL) { _, _ in syncCurrentLibraryStatus() }
        .onChange(of: streaming.completedURL) { _, url in
            if let url { lecture?.russianSubtitleURL = url }
            exportIfReady()
        }
        .onChange(of: streaming.errorMessage) { _, error in
            if error != nil { cancelExport(); recognition.stop(); speech.stop(); playback.pause() }
        }
        .onChange(of: speech.errorMessage) { _, error in
            if error != nil { cancelExport(); recognition.stop(); streaming.stop(); playback.pause() }
        }
        .onChange(of: playback.russianVoiceEnabled) { _, enabled in
            speech.setPreparationEnabled(enabled)
        }
        .onChange(of: speech.prepared) { _, chunks in
            playback.acceptSpeech(chunks)
            exportIfReady()
            syncCurrentLibraryStatus()
        }
        .onChange(of: playback.snapshot.position) { _, position in
            speech.updatePosition(position)
            streaming.updatePosition(position)
            recognition.updatePosition(position)
            if abs(position - lastSavedPosition) >= 5 { persistHistory() }
        }
        .onChange(of: showsRussian) { _, enabled in
            if enabled { playback.selectSubtitle(-1) }
        }
        .onChange(of: showsGerman) { _, enabled in
            if enabled { playback.selectSubtitle(-1) }
        }
    }

    private var queueObservedPlayback: some View {
        observedPlayback
        .onAppear {
            network.macBusy = { recognition.isRunning || streaming.isRunning || speech.isRunning || translation.isRunning || sourceLoading || speechExport.isRunning }
            updateQueuePriority()
            libraryQueue.resumeAfterLaunch()
        }
        .onChange(of: playback.playbackRequested) { _, _ in updateQueuePriority() }
        .onChange(of: network.viewerActive) { _, _ in updateQueuePriority() }
        .onChange(of: recognition.isRunning) { _, _ in maintainQueuedWholePreparation(); finishQueuedPreparationIfReady() }
        .onChange(of: streaming.isRunning) { _, _ in maintainQueuedWholePreparation(); finishQueuedPreparationIfReady() }
        .onChange(of: speech.isRunning) { _, _ in maintainQueuedWholePreparation(); finishQueuedPreparationIfReady() }
        .onChange(of: sourceLoading) { _, _ in maintainQueuedWholePreparation(); finishQueuedPreparationIfReady() }
        .onChange(of: speech.prepared.count) { _, _ in updateQueuedProgress(); finishQueuedPreparationIfReady() }
        .onChange(of: recognition.errorMessage) { _, _ in syncCurrentLibraryStatus() }
        .onChange(of: streaming.errorMessage) { _, _ in syncCurrentLibraryStatus() }
        .onChange(of: speech.errorMessage) { _, _ in syncCurrentLibraryStatus() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryPreparationRequested)) { notification in
            guard let request = notification.object as? LibraryPreparationRequest else { return }
            startQueuedPreparation(request)
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryPreparationStopRequested)) { _ in
            guard let request = queuedRequest else { return }
            stopPreparation(); queuedRequest = nil
            libraryQueue.updateStatus(id: request.lecture.id) { $0.state = .stopped }
            request.complete(.failure(CancellationError()))
        }
    }

    var body: some View {
        queueObservedPlayback
        .environment(\.locale, Locale(identifier: language.rawValue))
        .onReceive(NotificationCenter.default.publisher(for: .telegramFileDownloaded)) { notification in
            guard let url = notification.object as? URL else { return }
            if ["mp4", "m4v", "mkv"].contains(url.pathExtension.lowercased()) {
                openVideo(url)
            } else if url.pathExtension.lowercased() == "srt", lecture != nil {
                if let telegramStream, Self.telegramStem(url.lastPathComponent) == Self.telegramStem(telegramStream.item.name) {
                    attachTelegramSubtitle(url)
                } else { refreshNearbySubtitles() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .telegramStreamSelected)) { notification in
            guard let selection = notification.object as? TelegramStreamSelection else { return }
            openTelegramStream(selection)
        }
        .onChange(of: language) {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
            menus.install(); speech.refreshIdleLanguage(); playback.refreshTrackLanguage()
        }
        .sheet(isPresented: Binding(get: { !languageConfirmed }, set: { _ in })) {
            InterfaceLanguageView().interactiveDismissDisabled()
        }
        .sheet(item: $libraryPresentation) { library in
            LectureLibraryView(
                directory: library.directory,
                lectures: library.lectures,
                chooseFolder: chooseLibraryFolder,
                openLecture: openLibraryLecture,
                openTelegram: { item in
                    do { openTelegramStream(try TelegramController.shared.makeStreamSelection(item)) }
                    catch { subtitleError = error.localizedDescription }
                },
                openQueue: { openWindow(id: "preparation-queue") }
            )
        }
        .sheet(item: $sourceSelection) { selection in
            RecognitionSourceView(selection: selection) { stream, translates in
                prepareSelectedSource(selection: selection, stream: stream, translates: translates)
            }
        }
        .sheet(item: $videoExportSelection, onDismiss: {
            if let request = pendingVideoExport {
                pendingVideoExport = nil
                saveSpeech(video: request)
            }
        }) { selection in
            VideoExportView(selection: selection) { pendingVideoExport = $0 }
        }
        .sheet(isPresented: $showsPronunciation) {
            if let video = lecture?.videoURL {
                PronunciationView(video: video, saved: {
                    guard !speech.plan.isEmpty else { return }
                    let wasPlaying = playback.playbackRequested
                    let enabled = playback.russianVoiceEnabled
                    playback.pause(); playback.clearVoice()
                    speech.reloadPronunciation(videoURL: video, voice: voice, position: playback.snapshot.position)
                    playback.beginSpeech(plan: speech.plan)
                    playback.russianVoiceEnabled = enabled
                    if wasPlaying { playback.play() }
                }, pausePlayback: { playback.pause() })
            }
        }
        .sheet(isPresented: $showsNetwork) { NetworkView(controller: network) }
        .sheet(isPresented: $showsTelegramUpload) {
            if let result = speechExport.result { TelegramUploadView(exportDirectory: result) }
        }
        .alert(translationText("subtitle.errorTitle"), isPresented: Binding(
            get: { subtitleError != nil },
            set: { if !$0 { subtitleError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(subtitleError ?? "")
        }
    }

    @ViewBuilder
    private var subtitlesView: some View {
        let time = playback.snapshot.position
        VStack(spacing: 8) {
            if !playback.embeddedSubtitleText.isEmpty {
                StyledSubtitle(text: playback.embeddedSubtitleText, color: ruColor, appearance: subtitleAppearance)
            }
            if showsRussian, let text = lecture?.russianSubtitles?.text(at: time) {
                StyledSubtitle(text: text, color: ruColor, appearance: subtitleAppearance)
            }
            if showsGerman, let text = lecture?.germanSubtitles?.text(at: time) {
                StyledSubtitle(text: text, color: deColor, appearance: subtitleAppearance)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            transportControls
            trackControls
            processingStatus
            HStack { attachmentsSummary; UsageBadge(usage: usage, expanded: $showsUsage) }
        }
    }

    private var transportControls: some View {
            HStack {
                Button { openAdjacentLecture(-1) } label: { Image(systemName: "backward.end.fill") }
                    .help(translationText("library.previous")).disabled(lecture == nil)
                Button { playback.seek(to: playback.snapshot.position - 10) } label: {
                    Image(systemName: "gobackward.10")
                }
                .help(translationText("player.back"))
                .disabled(lecture == nil)
                Button {
                    playback.togglePlayback()
                } label: {
                    Image(systemName: playback.playbackRequested ? "pause.fill" : "play.fill")
                        .font(.title2).frame(width: 32, height: 28)
                }
                .help(translationText(playback.snapshot.isPlaying ? "player.pause" : "player.play"))
                .disabled(lecture == nil)
                Button { playback.seek(to: playback.snapshot.position + 10) } label: {
                    Image(systemName: "goforward.10")
                }
                .help(translationText("player.forward"))
                .disabled(lecture == nil)
                Button { openAdjacentLecture(1) } label: { Image(systemName: "forward.end.fill") }
                    .help(translationText("library.next")).disabled(lecture == nil)

                Text(timeText(playback.snapshot.position))
                    .monospacedDigit()
                BufferedTimeline(position: playback.snapshot.position, duration: playback.snapshot.duration,
                    prepared: speech.prepared, active: speech.plan.first { $0.id == speech.activeChunk },
                    translated: streaming.ready.map { $0.start...$0.end }, translating: streaming.activeRange,
                    recognized: recognition.ready.map { $0.start...$0.end }, recognizing: recognition.activeRange) { position in
                        speech.updatePosition(position)
                        streaming.updatePosition(position)
                        recognition.updatePosition(position)
                        playback.seek(to: position)
                    }
                    .frame(height: 24)
                Text(timeText(playback.snapshot.duration ?? 0))
                    .monospacedDigit()
            }

    }

    private var trackControls: some View {
            HStack {
                Button { showsAudioMixer.toggle() } label: {
                    Label(translationText("player.audio"), systemImage: "waveform")
                }
                .fixedSize()
                .popover(isPresented: $showsAudioMixer, arrowEdge: .top) {
                    AudioMixerView(playback: playback)
                }
                subtitlesMenu
                Text(translationText("player.original"))
                Slider(value: $playback.volume, in: 0...1)
                    .frame(width: 90).help(translationText("player.volume"))
                Text(translationText("speech.shortTitle"))
                Slider(value: $playback.russianVolume, in: 0...1)
                    .frame(width: 90).help(translationText("speech.volume"))
                    .accessibilityLabel(translationText("speech.volume"))
                Text("\(Int((playback.russianVolume * 100).rounded()))%").monospacedDigit()
                Toggle(translationText("audio.duck"), isOn: $playback.duckingEnabled)
                    .toggleStyle(.checkbox).help(translationText("audio.duckHelp"))
                Button(translationText("attachment.chooseAudio"), action: chooseExternalAudio)
                    .disabled(lecture == nil || telegramStream != nil)
                if let adjacentSubtitles {
                    Button(translationText("player.attachNearby"), action: attachNearbySubtitles)
                        .disabled(translation.isRunning || speech.isRunning)
                        .help([adjacentSubtitles.germanSubtitleURL, adjacentSubtitles.russianSubtitleURL]
                            .compactMap { $0?.lastPathComponent }.joined(separator: "\n"))
                }
                Spacer()
            }
            .font(.caption)
    }

    private var translationStatus: String {
        if sourceLoading { return translationText("recognition.inspecting") }
        if let status = recognition.errorMessage { return status }
        if let status = recognition.status, recognition.isRunning {
            return [status, streaming.status].compactMap { $0 }.joined(separator: " · ")
        }
        if let status = streaming.status ?? translation.status ?? preparation.statusText { return status }
        if let source = lecture?.germanSubtitles, let russian = lecture?.russianSubtitles, sameTiming(source, russian) {
            return translationText("translation.existingRU")
        }
        return translationText(lecture?.germanSubtitles == nil ? "translation.needsSRT" : "translation.ready")
    }

    @ViewBuilder private var processingStatus: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if sourceLoading || recognition.activeRange != nil || translation.isRunning || streaming.activeRange != nil { ProgressView().controlSize(.small) }
                    Text(translationStatus)
                        .font(.caption).lineLimit(1)
                        .help(translationStatus)
                    Spacer()
                    if let result = translation.result {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([result.subtitleURL])
                        } label: { Image(systemName: "folder") }
                        .help(result.subtitleURL.lastPathComponent)
                    }
                }
                Label(playback.errorMessage ?? playback.externalVoiceStatus ?? ((speech.plan.isEmpty && lecture?.russianSubtitles != nil ? translationText("speech.canStart") : speech.status) + (playback.hasRussianVoice
                    ? String(format: translationText(playback.waitingForSpeech ? "speech.waiting" : "speech.buffer"), Int(playback.speechBufferSeconds)) : "")),
                      systemImage: playback.errorMessage == nil ? "speaker.badge.exclamationmark" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(height: 44, alignment: .topLeading)
            if exportDestination != nil {
                Text(String(format: translationText("export.preparing"), speech.prepared.count, speech.plan.count))
                    .font(.caption).foregroundStyle(.secondary)
            } else if speechExport.isRunning {
                ProgressView(translationText("export.saving"), value: speechExport.progress).font(.caption)
            } else if let error = speechExport.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let result = speechExport.result {
                Button(translationText("export.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([result]) }
                    .font(.caption)
            }
    }

    private var subtitlesMenu: some View {
        Menu {
            Button(translationText("player.subtitlesOff")) {
                showsGerman = false
                showsRussian = false
                playback.selectSubtitle(-1)
            }
            Divider()
            Toggle(translationText("player.externalRU"), isOn: $showsRussian)
                .disabled(lecture?.russianSubtitles == nil)
            Toggle(translationText("player.externalDE"), isOn: $showsGerman)
                .disabled(lecture?.germanSubtitles == nil)
            Divider()
            Picker(translationText("player.embedded"), selection: Binding(
                get: { playback.selectedSubtitleTrack }, set: { id in
                    playback.selectSubtitle(id)
                    if id >= 0 { showsRussian = false; showsGerman = false }
                })) {
                Text(translationText("player.embeddedOff")).tag(-1)
                ForEach(playback.subtitleTracks) { Text($0.title).tag($0.id) }
            }
            Divider()
            Button(translationText("subtitles.appearance")) { openWindow(id: "subtitle-settings") }
            Button(translationText("attachment.chooseDE")) { chooseSubtitles(for: .german) }.disabled(lecture == nil || translation.isRunning || speech.isRunning)
            Button(translationText("attachment.chooseRU")) { chooseSubtitles(for: .russian) }.disabled(lecture == nil || translation.isRunning || speech.isRunning)
        } label: { Label(translationText("player.subtitles"), systemImage: "captions.bubble") }
        .fixedSize()
    }

    private func attachNearbySubtitles() {
        guard let adjacentSubtitles, var current = lecture else { return }
        do {
            let german = try adjacentSubtitles.germanSubtitleURL.map { try SRTParser.parse(data: Data(contentsOf: $0)) }
            let russian = try adjacentSubtitles.russianSubtitleURL.map { try SRTParser.parse(data: Data(contentsOf: $0)) }
            if let german { current.germanSubtitles = german; current.germanSubtitleURL = adjacentSubtitles.germanSubtitleURL; showsGerman = true }
            if let russian { current.russianSubtitles = russian; current.russianSubtitleURL = adjacentSubtitles.russianSubtitleURL; showsRussian = true }
            lecture = current
            playback.selectSubtitle(-1)
            self.adjacentSubtitles = nil
        } catch { subtitleError = error.localizedDescription }
    }

    private func refreshNearbySubtitles() {
        guard let video = lecture?.videoURL else { return }
        let found = LectureLibrary.adjacentSubtitles(for: video)
        adjacentSubtitles = found.germanSubtitleURL != nil || found.russianSubtitleURL != nil ? found : nil
        if adjacentSubtitles != nil { attachNearbySubtitles() }
    }

    private static func telegramStem(_ name: String) -> String {
        var url = URL(fileURLWithPath: name).deletingPathExtension()
        while ["de", "ru", "en", "reviewed"].contains(url.pathExtension.lowercased()) { url.deletePathExtension() }
        return url.lastPathComponent.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func attachTelegramSubtitle(_ url: URL) {
        guard var current = lecture else { return }
        do {
            let document = try SRTParser.parse(data: Data(contentsOf: url))
            if url.deletingPathExtension().pathExtension.lowercased() == "ru" {
                current.russianSubtitles = document; current.russianSubtitleURL = url; showsRussian = true
            } else {
                current.germanSubtitles = document; current.germanSubtitleURL = url; showsGerman = true
            }
            lecture = current
            playback.selectSubtitle(-1)
        } catch { subtitleError = error.localizedDescription }
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.prompt = translationText("menu.open")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openVideo(url)
    }

    private func openVideo(_ url: URL) {
        persistHistory()
        telegramStream?.stop(); telegramStream = nil
        resetSourcePreparation()
        streaming.reset()
        translation.reset()
        speech.reset()
        preparation.reset()
        lecture = LocalLecture(videoURL: url)
        libraryQueue.registerLocalVideo(url)
        libraryDirectory = url.deletingLastPathComponent()
        showsGerman = false
        showsRussian = false
        playback.load(url: url)
        applyStoredAttachments()
        restoreHistory()
    }

    private func openTelegramStream(_ selection: TelegramStreamSelection) {
        persistHistory()
        telegramStream?.stop()
        resetSourcePreparation()
        streaming.reset()
        translation.reset()
        speech.reset()
        preparation.reset()
        telegramStream = selection
        libraryQueue.registerTelegram([selection.item], chatID: TelegramController.shared.lanChatID)
        lecture = LocalLecture(videoURL: selection.cacheVideoURL)
        libraryDirectory = selection.cacheVideoURL.deletingLastPathComponent()
        showsGerman = false
        showsRussian = false
        playback.load(asset: selection.asset)
        refreshNearbySubtitles()
        restoreHistory()
    }

    private func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.prompt = translationText("menu.open")
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = translationText("menu.library")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let lectures = try LectureLibrary.scan(directory: url)
            libraryDirectory = url
            libraryPresentation = .init(directory: url, lectures: lectures)
        } catch {
            subtitleError = error.localizedDescription
        }
    }

    private func openLibraryLecture(_ item: LibraryLecture) {
        do {
            let german = try item.germanSubtitleURL.map { try SRTParser.parse(data: Data(contentsOf: $0)) }
            let russian = try item.russianSubtitleURL.map { try SRTParser.parse(data: Data(contentsOf: $0)) }
            persistHistory()
            resetSourcePreparation()
            streaming.reset()
            translation.reset()
            speech.reset()
            preparation.reset()
            lecture = LocalLecture(videoURL: item.videoURL, germanSubtitles: german, russianSubtitles: russian)
            lecture?.germanSubtitleURL = item.germanSubtitleURL
            lecture?.russianSubtitleURL = item.russianSubtitleURL
            adjacentSubtitles = nil
            showsGerman = german != nil
            showsRussian = russian != nil
            playback.load(url: item.videoURL)
            applyStoredAttachments()
            restoreHistory()
        } catch {
            subtitleError = String(format: translationText("library.openError"), error.localizedDescription)
        }
    }

    private func chooseSubtitles(for language: SubtitleLanguage) {
        let panel = NSOpenPanel()
        panel.prompt = translationText("menu.open")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = lecture?.videoURL.deletingLastPathComponent()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let video = lecture?.videoURL,
                  let reference = LectureAttachmentLocator.reference(for: url, beside: video) else {
                subtitleError = translationText("attachment.sameFolder")
                return
            }
            let document = try SRTParser.parse(data: Data(contentsOf: url))
            guard var lecture else { return }
            resetSourcePreparation()
            streaming.reset()
            switch language {
            case .german:
                translation.reset()
                preparation.reset()
                lecture.germanSubtitles = document
                lecture.germanSubtitleURL = url
                showsGerman = true
            case .russian:
                translation.reset()
                speech.reset()
                playback.clearVoice()
                lecture.russianSubtitles = document
                lecture.russianSubtitleURL = url
                showsRussian = true
            }
            self.lecture = lecture
            var attachments = libraryQueue.attachments(for: video)
            if language == .german { attachments.germanSubtitles = reference }
            else { attachments.russianSubtitles = reference }
            libraryQueue.saveAttachments(attachments, for: video)
            playback.selectSubtitle(-1)
            persistHistory()
        } catch {
            subtitleError = error.localizedDescription
        }
    }

    private func chooseExternalAudio() {
        guard let video = lecture?.videoURL else { return }
        let panel = NSOpenPanel()
        panel.prompt = translationText("attachment.chooseAudio")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = video.deletingLastPathComponent()
        panel.allowedContentTypes = [UTType(filenameExtension: "m4a") ?? .audio, UTType(filenameExtension: "wav") ?? .audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let reference = LectureAttachmentLocator.reference(for: url, beside: video, audio: true) else {
            subtitleError = translationText("attachment.sameFolder")
            return
        }
        var attachments = libraryQueue.attachments(for: video)
        attachments.russianAudio = reference
        libraryQueue.saveAttachments(attachments, for: video)
        do { try playback.attachVoice(url: url) }
        catch { subtitleError = error.localizedDescription }
    }

    private func applyStoredAttachments() {
        guard var current = lecture, telegramStream == nil else { refreshNearbySubtitles(); return }
        let video = current.videoURL
        libraryQueue.registerLocalVideo(video)
        let attachments = libraryQueue.attachments(for: video)
        let folder = video.deletingLastPathComponent()
        do {
            if let url = attachments.resolved(in: folder, language: .german) {
                current.germanSubtitles = try SRTParser.parse(data: Data(contentsOf: url)); current.germanSubtitleURL = url; showsGerman = true
            }
            if let url = attachments.resolved(in: folder, language: .russian) {
                current.russianSubtitles = try SRTParser.parse(data: Data(contentsOf: url)); current.russianSubtitleURL = url; showsRussian = true
            }
            lecture = current
            if let audio = attachments.resolved(in: folder, audio: true) { try playback.attachVoice(url: audio) }
            else if attachments.russianAudio != nil { playback.setExternalVoiceUnavailable() }
            playback.selectSubtitle(-1)
        } catch { subtitleError = error.localizedDescription }
    }

    private func prepareForTranslation() {
        guard let document = lecture?.germanSubtitles else {
            subtitleError = translationText("translation.attachDE")
            return
        }
        preparation.prepare(document: document)
    }

    private func resetSourcePreparation() {
        cancelExport()
        sourceGeneration = UUID(); sourceCancellation?.cancel(); sourceCancellation = nil
        sourceLoading = false; sourceSelection = nil; recognitionStreamIndex = nil
        recognition.reset()
    }

    private func persistHistory() {
        guard let video = lecture?.videoURL else { return }
        savedHistory.position = playback.snapshot.position
        savedHistory.recognitionStream = recognitionStreamIndex
        do {
            if let telegramStream { try savedHistory.save(video: video, remoteIdentity: telegramStream.rangeStore.identity) }
            else { try savedHistory.save(video: video) }
            lastSavedPosition = savedHistory.position
        } catch { /* Read-only libraries remain playable. Processing reports its own write errors. */ }
    }

    private func restoreHistory() {
        guard var lecture else { return }
        if let telegramStream { savedHistory = LectureHistory.load(video: lecture.videoURL, remoteIdentity: telegramStream.rangeStore.identity) }
        else { savedHistory = LectureHistory.load(video: lecture.videoURL) }
        lastSavedPosition = savedHistory.position
        if let restored = savedHistory.restoredRecognitionSource(video: lecture.videoURL) {
            lecture.germanSubtitleURL = restored.url
            lecture.germanSubtitles = restored.document
            self.lecture = lecture
            showsGerman = true
        }
        if savedHistory.matchesRecognitionSource(subtitle: lecture.germanSubtitleURL,
            content: lecture.germanSubtitles.map(MediaPublication.srt)) {
            recognitionStreamIndex = savedHistory.recognitionStream
        }
        if savedHistory.position > 0 { playback.seek(to: savedHistory.position) }
    }

    private func prepareVideoSubtitles(automatic: Bool) {
        guard let video = lecture?.videoURL, !sourceLoading else { return }
        let token = UUID(); sourceGeneration = token
        let cancellation = MediaCancellation(); sourceCancellation = cancellation
        sourceLoading = true
        Task {
            do {
                let currentTelegram = telegramStream
                let mediaURL = try await currentTelegram?.preparationURL()
                let inspectionURL = mediaURL ?? video
                let inspection = try await Task.detached { try MediaInspection.read(inspectionURL, cancellation: cancellation) }.value
                guard sourceGeneration == token, currentTelegram === telegramStream else { return }
                sourceLoading = false
                let selection = RecognitionSourceSelection(video: video, mediaURL: mediaURL, inspection: inspection)
                if automatic, let source = inspection.textSubtitles.first(where: \.isGerman)
                    ?? inspection.textSubtitles.first(where: \.isRussian)
                    ?? (queuedRequest == nil ? nil : inspection.audio.first(where: \.isGerman) ?? inspection.audio.first) {
                    prepareSelectedSource(selection: selection, stream: source, translates: true)
                } else {
                    sourceSelection = selection
                }
            } catch {
                guard sourceGeneration == token else { return }
                sourceLoading = false
                subtitleError = error.localizedDescription
            }
        }
    }

    private func prepareSelectedSource(selection: RecognitionSourceSelection, stream: MediaStream, translates: Bool) {
        guard lecture?.videoURL == selection.video else { return }
        streaming.reset(); translation.reset(); speech.reset(); recognition.reset()
        recognitionStreamIndex = nil
        playback.clearVoice()
        if stream.isTextSubtitle {
            let token = UUID(); sourceGeneration = token
            let cancellation = MediaCancellation(); sourceCancellation = cancellation
            sourceLoading = true
            Task {
                do {
                    let result = try await Task.detached {
                        let document = try MediaInspection.extractSubtitles(selection.mediaURL ?? selection.video, stream: stream, cancellation: cancellation)
                        guard !document.cues.isEmpty else { throw MediaFailure.invalidOutput }
                        let url = try MediaPublication.subtitles(document, video: selection.video, language: stream.isRussian ? "ru" : "de")
                        return (document, url)
                    }.value
                    guard sourceGeneration == token else { return }
                    sourceLoading = false
                    if stream.isRussian {
                        lecture?.russianSubtitles = result.0; lecture?.russianSubtitleURL = result.1; showsRussian = true
                        if translates { synthesizeSpeech() }
                    } else {
                        lecture?.germanSubtitles = result.0; lecture?.germanSubtitleURL = result.1; showsGerman = true
                        if translates { translateLecture() }
                    }
                    playback.selectSubtitle(-1)
                } catch {
                    guard sourceGeneration == token else { return }
                    sourceLoading = false; subtitleError = error.localizedDescription
                }
            }
        } else {
            guard let duration = selection.inspection.duration ?? playback.snapshot.duration else { return }
            recognitionStreamIndex = stream.index
            savedHistory.recognitionSubtitle = nil; savedHistory.recognitionSubtitleHash = nil
            lecture?.germanSubtitles = nil; lecture?.germanSubtitleURL = nil
            lecture?.russianSubtitles = nil; lecture?.russianSubtitleURL = nil
            showsGerman = true; showsRussian = translates; playback.selectSubtitle(-1)
            updateBufferTarget(starting: translates)
            recognition.start(video: selection.video, streamIndex: stream.index, duration: duration,
                position: playback.snapshot.position, mediaURL: selection.mediaURL,
                mediaIdentity: telegramStream?.rangeStore.identity)
            persistHistory()
            if translates { startRecognizedTranslation() }
        }
    }

    private func startRecognizedTranslation() {
        guard let lecture, let streamIndex = recognitionStreamIndex,
              let duration = recognition.plan.last?.end ?? playback.snapshot.duration else { return }
        if !recognition.isRunning {
            recognition.start(video: lecture.videoURL, streamIndex: streamIndex, duration: duration,
                position: playback.snapshot.position, mediaURL: telegramStream?.currentPreparationURL,
                mediaIdentity: telegramStream?.rangeStore.identity)
        }
        translation.reset(); speech.reset(); playback.clearVoice()
        updateBufferTarget(starting: true)
        streaming.startRecognizing(plan: recognition.speechPlan, videoURL: lecture.videoURL,
            translation: .init(model: modelID(translationModel), effort: effortID(reasoningEffort)),
            review: .init(model: modelID(reviewModel), effort: effortID(reviewEffort)), position: playback.snapshot.position)
        streaming.supplyRecognized(recognition.sourceChunks)
        if streaming.isRunning {
            speech.startStreaming(plan: streaming.plan, videoURL: lecture.videoURL, voice: voice, position: playback.snapshot.position)
            playback.startWithSpeech(plan: streaming.plan)
            showsRussian = true
        }
    }

    private func translateLecture() {
        cancelExport()
        guard let lecture, playback.player.currentItem?.status != .failed else { return }
        if recognitionStreamIndex != nil {
            startRecognizedTranslation()
            return
        }
        if telegramStream != nil && recognitionStreamIndex == nil && lecture.germanSubtitles == nil {
            prepareVideoSubtitles(automatic: true)
            return
        }
        guard let document = lecture.germanSubtitles, !document.cues.isEmpty else {
            if lecture.russianSubtitles?.cues.isEmpty == false { synthesizeSpeech() }
            else { prepareVideoSubtitles(automatic: true) }
            return
        }
        if let russian = lecture.russianSubtitles, sameTiming(document, russian) {
            synthesizeSpeech()
            return
        }
        translation.reset()
        preparation.reset()
        speech.reset()
        playback.clearVoice()
        showsRussian = true
        playback.selectSubtitle(-1)
        updateBufferTarget(starting: true)
        streaming.start(source: document, videoURL: lecture.videoURL,
            translation: .init(model: modelID(translationModel), effort: effortID(reasoningEffort)),
            review: .init(model: modelID(reviewModel), effort: effortID(reviewEffort)), position: playback.snapshot.position)
        if streaming.isRunning {
            speech.startStreaming(plan: streaming.plan, videoURL: lecture.videoURL, voice: voice, position: playback.snapshot.position)
            playback.startWithSpeech(plan: streaming.plan)
        }
    }

    private func stopPreparation() {
        cancelExport()
        recognition.stop()
        streaming.stop()
        speech.stop()
        playback.pause()
    }

    private func sameTiming(_ source: SubtitleDocument, _ russian: SubtitleDocument) -> Bool {
        source.cues.count == russian.cues.count && zip(source.cues, russian.cues).allSatisfy {
            $0.id == $1.id && $0.start == $1.start && $0.end == $1.end
        }
    }

    private func effortID(_ value: String) -> String {
        value == "Лёгкие" ? "low" : value == "Высокие" ? "high" : "medium"
    }

    private func modelID(_ name: String) -> String {
        name == "Luna" ? "gpt-5.6-luna" : name == "Terra" ? "gpt-5.6-terra" : "gpt-6-astra"
    }

    private var canReview: Bool {
        guard !streaming.isRunning, streaming.completedURL == nil, let german = lecture?.germanSubtitles, let russian = lecture?.russianSubtitles,
              !german.cues.isEmpty, german.cues.count == russian.cues.count else { return false }
        if translation.isReview, translation.result?.document == russian { return false }
        return zip(german.cues, russian.cues).allSatisfy {
            $0.identifier == $1.identifier && $0.start == $1.start && $0.end == $1.end
        }
    }

    private func reviewLecture() {
        cancelExport()
        guard canReview, let lecture, let german = lecture.germanSubtitles, let russian = lecture.russianSubtitles else { return }
        preparation.reset()
        speech.reset()
        playback.clearVoice()
        let effort = reviewEffort == "Лёгкие" ? "low" : reviewEffort == "Высокие" ? "high" : "medium"
        translation.start(document: german, videoURL: lecture.videoURL,
                          settings: .init(model: modelID(reviewModel), effort: effort), reviewDraft: russian)
    }

    private func synthesizeSpeech() {
        cancelExport()
        if recognitionStreamIndex != nil {
            startRecognizedTranslation()
            return
        }
        guard let lecture, let russian = lecture.russianSubtitles else { return }
        if !streaming.plan.isEmpty, let source = lecture.germanSubtitles, !sameTiming(source, russian) {
            translateLecture()
            return
        }
        streaming.reset()
        updateBufferTarget(starting: true)
        speech.start(document: russian, videoURL: lecture.videoURL, voice: voice, position: playback.snapshot.position)
        if speech.isRunning { playback.startWithSpeech(plan: speech.plan) }
    }

    private var subtitleAppearance: SubtitleAppearance {
        .init(russian: ruColor, german: deColor, outline: outlineColor, size: subtitleSize,
              stroke: subtitleStroke, background: subtitleBackground)
    }

    private func updateBufferTarget(starting: Bool = false) {
        let minutes = playback.playbackRequested || starting ? bufferMinutes : pausedMinutes
        let ahead = minutes == 0 ? (playback.snapshot.duration ?? 86400) : max(1, minutes) * 60
        speech.bufferAhead = ahead
        streaming.bufferAhead = ahead + 60
        recognition.bufferAhead = ahead + 90
    }

    private func chooseVideoExport() {
        guard let video = lecture?.videoURL, !sourceLoading else { return }
        let token = UUID(); sourceGeneration = token
        let control = MediaCancellation(); sourceCancellation = control
        sourceLoading = true
        Task {
            do {
                let inspection = try await Task.detached { try MediaInspection.read(video, cancellation: control) }.value
                guard sourceGeneration == token, lecture?.videoURL == video else { return }
                sourceLoading = false
                videoExportSelection = .init(source: video, inspection: inspection,
                    hasGerman: lecture?.germanSubtitles != nil || !recognition.plan.isEmpty,
                    germanAudio: recognitionStreamIndex)
            } catch {
                guard sourceGeneration == token else { return }
                sourceLoading = false; subtitleError = error.localizedDescription
            }
        }
    }

    private func saveSpeech(video: VideoExportRequest? = nil) {
        guard let lecture, let duration = playback.snapshot.duration, duration > 0 else { return }
        guard video == nil || video?.source == lecture.videoURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = lecture.videoURL.deletingLastPathComponent()
        panel.prompt = translationText("export.chooseFolder")
        panel.message = translationText(video == nil ? "export.explanation" : "export.videoExplanation")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let wasPlaying = playback.playbackRequested
        if !streaming.plan.isEmpty && streaming.completedURL == nil && !streaming.isRunning {
            translateLecture()
            if !wasPlaying { playback.pause() }
        }
        if speech.plan.isEmpty || (!speech.isRunning && speech.prepared.count != speech.plan.count) {
            if streaming.isRunning {
                speech.startStreaming(plan: streaming.plan, videoURL: lecture.videoURL, voice: voice, position: playback.snapshot.position)
                speech.supply(streaming.ready)
            } else if let russian = lecture.russianSubtitles {
                speech.start(document: russian, videoURL: lecture.videoURL, voice: voice, position: playback.snapshot.position)
            }
        }
        guard !speech.plan.isEmpty else { return }
        speechExport.reset()
        exportVideo = video
        exportDestination = directory.appendingPathComponent(lecture.videoURL.deletingPathExtension().lastPathComponent + " — Kseniya", isDirectory: true)
        recognition.prepareWholeLecture = true
        streaming.prepareWholeLecture = true
        speech.prepareWholeLecture = true
        exportIfReady()
    }

    private func exportIfReady() {
        guard let destination = exportDestination, let duration = playback.snapshot.duration,
              !speech.plan.isEmpty, speech.prepared.count == speech.plan.count,
              streaming.plan.isEmpty || streaming.completedURL != nil,
              recognition.plan.isEmpty || recognition.completedURL != nil else { return }
        exportDestination = nil
        finishWholePreparation()
        speechExport.start(plan: speech.plan, prepared: speech.prepared, duration: duration,
                           german: lecture?.germanSubtitles ?? recognition.document, destination: destination, video: exportVideo)
        exportVideo = nil
    }

    private func finishWholePreparation() {
        recognition.prepareWholeLecture = false
        streaming.prepareWholeLecture = false
        speech.prepareWholeLecture = false
        speech.setPreparationEnabled(playback.russianVoiceEnabled)
    }

    private func cancelExport() {
        exportDestination = nil
        exportVideo = nil
        pendingVideoExport = nil
        speechExport.reset()
        finishWholePreparation()
    }

    private func showLibrary() {
        if libraryDirectory == nil { libraryDirectory = lecture?.videoURL.deletingLastPathComponent() }
        guard let directory = libraryDirectory else { chooseLibraryFolder(); return }
        do {
            let lectures = try LectureLibrary.scan(directory: directory)
            libraryQueue.refresh(directory: directory)
            libraryQueue.registerTelegram(TelegramController.shared.lanMedia, chatID: TelegramController.shared.lanChatID)
            libraryPresentation = .init(directory: directory, lectures: lectures)
        }
        catch { subtitleError = error.localizedDescription }
    }

    private func openAdjacentLecture(_ direction: Int) {
        enum Target { case local(LibraryLecture), telegram(TelegramMedia) }
        var targets: [(String, Target)] = []
        if let directory = libraryDirectory, let lectures = try? LectureLibrary.scan(directory: directory) {
            targets += lectures.map { item in
                let id = LibraryManifestStore.lectureID(for: .local(path: item.videoURL.standardizedFileURL.path))
                return (id, .local(item))
            }
        }
        if let chat = TelegramController.shared.lanChatID {
            targets += TelegramController.shared.lanMedia.filter { ["mp4", "m4v", "mkv", "mov"].contains($0.type.lowercased()) }.map { item in
                let id = LibraryManifestStore.lectureID(for: .telegram(chatID: chat, messageID: item.id,
                    fileID: item.fileID, name: item.name, size: item.size))
                return (id, .telegram(item))
            }
        }
        let currentID: String?
        if let stream = telegramStream, let chat = TelegramController.shared.lanChatID {
            let item = stream.item
            currentID = LibraryManifestStore.lectureID(for: .telegram(chatID: chat, messageID: item.id,
                fileID: item.fileID, name: item.name, size: item.size))
        } else if let video = lecture?.videoURL {
            currentID = LibraryManifestStore.lectureID(for: .local(path: video.standardizedFileURL.path))
        } else { currentID = nil }
        guard let currentID, let index = targets.firstIndex(where: { $0.0 == currentID }) else { return }
        let next = index + (direction < 0 ? -1 : 1)
        guard targets.indices.contains(next) else { return }
        switch targets[next].1 {
        case .local(let item): openLibraryLecture(item)
        case .telegram(let item):
            do { openTelegramStream(try TelegramController.shared.makeStreamSelection(item)) }
            catch { subtitleError = error.localizedDescription }
        }
    }

    private func updateQueuePriority() {
        libraryQueue.setInteractive(playback.playbackRequested || network.viewerActive)
    }

    private func startQueuedPreparation(_ request: LibraryPreparationRequest) {
        guard queuedRequest == nil else {
            request.complete(.failure(NSError(domain: "LektienQueue", code: 1,
                userInfo: [NSLocalizedDescriptionKey: translationText("queue.busy")]))); return
        }
        do {
            switch request.lecture.source {
            case .local(let path):
                let item = LectureLibrary.adjacentSubtitles(for: URL(fileURLWithPath: path))
                openLibraryLecture(item)
            case .telegram(_, let messageID, _, _, _):
                guard let item = TelegramController.shared.lanMedia.first(where: { $0.id == messageID }) else {
                    throw NSError(domain: "LektienQueue", code: 2, userInfo: [NSLocalizedDescriptionKey: translationText("queue.sourceUnavailable")])
                }
                openTelegramStream(try TelegramController.shared.makeStreamSelection(item))
            }
            queuedRequest = request
            libraryQueue.updateStatus(id: request.lecture.id) { $0.state = .preparing; $0.error = nil }
            translateLecture()
            recognition.prepareWholeLecture = true
            streaming.prepareWholeLecture = true
            speech.prepareWholeLecture = true
            playback.pause()
            finishQueuedPreparationIfReady()
        } catch { request.complete(.failure(error)) }
    }

    private func finishQueuedPreparationIfReady() {
        guard let request = queuedRequest else { return }
        if let error = recognition.errorMessage ?? streaming.errorMessage ?? speech.errorMessage {
            libraryQueue.updateStatus(id: request.lecture.id) { $0.state = .failed; $0.error = error }
            queuedRequest = nil; request.complete(.failure(NSError(domain: "LektienQueue", code: 3,
                userInfo: [NSLocalizedDescriptionKey: error]))); return
        }
        let hasPlan = !speech.plan.isEmpty
        guard hasPlan, !recognition.isRunning, !streaming.isRunning, !speech.isRunning,
              speech.prepared.count == speech.plan.count else { return }
        libraryQueue.updateStatus(id: request.lecture.id) {
            $0.hasGermanSubtitles = lecture?.germanSubtitles != nil
            $0.recognized = recognitionStreamIndex != nil
            $0.translated = lecture?.russianSubtitles != nil
            $0.reviewed = streaming.completedURL != nil || request.lecture.status.reviewed
            $0.voiced = true; $0.state = .complete
            $0.progress = .init(completed: speech.prepared.count, total: speech.plan.count)
            $0.languages = ["de", "ru", "ru-audio"]
        }
        queuedRequest = nil; request.complete(.success(()))
    }

    private func updateQueuedProgress() {
        guard let request = queuedRequest else { return }
        libraryQueue.updateStatus(id: request.lecture.id) {
            $0.state = .preparing
            $0.progress = .init(completed: speech.prepared.count, total: speech.plan.count)
            $0.hasGermanSubtitles = lecture?.germanSubtitles != nil
            $0.translated = lecture?.russianSubtitles != nil
        }
    }

    private func syncCurrentLibraryStatus() {
        guard let video = lecture?.videoURL else { return }
        let source: LectureSource
        if let stream = telegramStream, let chat = TelegramController.shared.lanChatID {
            let item = stream.item
            source = .telegram(chatID: chat, messageID: item.id, fileID: item.fileID, name: item.name, size: item.size)
        } else { source = .local(path: video.standardizedFileURL.path) }
        let id = LibraryManifestStore.lectureID(for: source)
        libraryQueue.updateStatus(id: id) { status in
            status.hasGermanSubtitles = lecture?.germanSubtitles != nil || recognition.completedURL != nil
            status.recognized = status.recognized || recognition.completedURL != nil
            status.translated = lecture?.russianSubtitles != nil || streaming.completedURL != nil
            status.reviewed = status.reviewed || streaming.completedURL != nil || translation.isReview && translation.result != nil
            status.voiced = !speech.plan.isEmpty && speech.prepared.count == speech.plan.count
            status.progress = .init(completed: speech.prepared.count, total: speech.plan.count)
            status.languages = [status.hasGermanSubtitles ? "de" : nil, status.translated ? "ru" : nil,
                                status.voiced ? "ru-audio" : nil].compactMap { $0 }
            if let error = recognition.errorMessage ?? streaming.errorMessage ?? speech.errorMessage {
                status.state = .failed; status.error = error
            } else if status.fullyReady { status.state = .complete; status.error = nil }
            else if recognition.isRunning || streaming.isRunning || speech.isRunning { status.state = .preparing }
        }
    }

    private func maintainQueuedWholePreparation() {
        guard queuedRequest != nil else { return }
        recognition.prepareWholeLecture = true
        streaming.prepareWholeLecture = true
        speech.prepareWholeLecture = true
    }

    private var attachmentNames: [String] {
        var names: [String] = []
        if let url = lecture?.germanSubtitleURL { names.append("DE: " + url.lastPathComponent) }
        else if recognition.document?.cues.isEmpty == false { names.append(translationText("recognition.partial")) }
        if let url = lecture?.russianSubtitleURL { names.append("RU: " + url.lastPathComponent) }
        else if lecture?.russianSubtitles != nil { names.append(translationText("attachments.translated")) }
        if let name = playback.externalVoiceName { names.append("Kseniya: " + name) }
        else if playback.externalVoiceStatus != nil { names.append(translationText("attachment.audioMissing")) }
        else if !speech.plan.isEmpty { names.append(String(format: translationText("attachments.voice"), speech.prepared.count)) }
        return names
    }

    private var attachmentsSummary: some View {
        Button { showsAttachments.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "paperclip")
                Text(attachmentNames.isEmpty ? translationText("attachments.empty") : attachmentNames.joined(separator: " · "))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }.font(.caption).foregroundStyle(.secondary).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help(attachmentNames.joined(separator: "\n"))
            .popover(isPresented: $showsAttachments) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(translationText("attachments.title")).font(.headline)
                    Text(lecture?.videoURL.lastPathComponent ?? translationText("attachments.empty")).font(.caption)
                    ForEach(attachmentNames, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    if let url = lecture?.videoURL {
                        Button(translationText("attachments.showFolder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }.padding(18).frame(width: 440, alignment: .leading)
            }
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    let videoSize: CGSize
    let panelHeight: CGFloat
    let headerHeight: CGFloat
    let mediaURL: URL?
    let togglePlayback: () -> Void
    let windowState: PlayerWindowState
    let menuActions: PlayerActions
    let fullscreenFill: Bool

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.windowState = windowState
        view.menuActions = menuActions
        view.fillFullscreen = fullscreenFill
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.videoSize = videoSize
        view.panelHeight = panelHeight
        view.headerHeight = headerHeight
        view.mediaURL = mediaURL
        view.togglePlayback = togglePlayback
        return view
    }

    func updateNSView(_ view: PlayerContainerView, context: Context) {
        view.windowState = windowState
        view.menuActions = menuActions
        view.fillFullscreen = fullscreenFill
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.videoSize = videoSize
        view.panelHeight = panelHeight
        view.headerHeight = headerHeight
        view.mediaURL = mediaURL
        view.togglePlayback = togglePlayback
    }
}

private struct LibraryPresentation: Identifiable {
    let id = UUID()
    let directory: URL
    let lectures: [LibraryLecture]
}

private struct LectureLibraryView: View {
    @State private var selectedIDs: Set<String> = []
    @State private var showsCache = false
    @Environment(\.dismiss) private var dismiss
    let directory: URL?
    let lectures: [LibraryLecture]
    let chooseFolder: () -> Void
    let openLecture: (LibraryLecture) -> Void
    let openTelegram: (TelegramMedia) -> Void
    let openQueue: () -> Void
    @StateObject private var libraryQueue = LibraryQueueController.shared
    @ObservedObject private var telegram = TelegramController.shared

    var body: some View {
        NavigationStack {
            libraryContent
            .navigationTitle(translationText("library.title"))
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(directory?.path ?? translationText("library.noFolder"))
                        .lineLimit(1).font(.caption).foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: libraryQueue.cacheUsage.totalBytes, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(translationText("library.chooseOther"), action: chooseFolder)
                        Button(translationText("queue.open"), action: openQueue)
                        Button(translationText("cache.manage")) { showsCache = true }
                        Button(translationText("queue.addSelected")) {
                            libraryQueue.add(Array(selectedIDs))
                        }.disabled(selectedIDs.isEmpty)
                        Spacer()
                        Button(translationText("library.close")) { dismiss() }.keyboardShortcut(.cancelAction)
                        Button(translationText("library.open"), action: openSelected)
                            .disabled(selectedIDs.isEmpty).keyboardShortcut(.defaultAction)
                    }
                }.padding(12).background(.bar)
            }
        }
        .frame(minWidth: 650, minHeight: 460)
        .onAppear {
            if let id = lectures.first.map({ LibraryManifestStore.lectureID(for: .local(path: $0.videoURL.standardizedFileURL.path)) })
                ?? telegram.lanMedia.first.map(telegramManifestID) { selectedIDs = [id] }
        }
        .sheet(isPresented: $showsCache) {
            if let directory {
                LibraryCacheView(library: directory, controller: libraryQueue)
            }
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if lectures.isEmpty && telegram.lanMedia.isEmpty {
            ContentUnavailableView(
                translationText("library.empty"),
                systemImage: "film",
                description: Text(translationText("library.emptyHelp"))
            )
        } else {
            List(selection: $selectedIDs) {
                Section(translationText("library.local")) {
                  ForEach(lectures) { item in
                    let manifestID = LibraryManifestStore.lectureID(for: .local(path: item.videoURL.standardizedFileURL.path))
                    lectureRow(item).tag(manifestID)
                        .onTapGesture(count: 2) { openLecture(item); dismiss() }
                  }
                }
                if !telegram.lanMedia.filter({ ["mp4", "m4v", "mkv", "mov"].contains($0.type.lowercased()) }).isEmpty {
                    Section("Telegram") {
                        ForEach(telegram.lanMedia.filter { ["mp4", "m4v", "mkv", "mov"].contains($0.type.lowercased()) }) { item in
                            telegramRow(item).tag(telegramManifestID(item))
                                .onTapGesture(count: 2) { openTelegram(item); dismiss() }
                        }
                    }
                }
            }
        }
    }

    private func lectureRow(_ item: LibraryLecture) -> some View {
        let id = LibraryManifestStore.lectureID(for: .local(path: item.videoURL.standardizedFileURL.path))
        let status = libraryQueue.manifest.lectures[id]?.status
        return HStack(spacing: 12) {
                Image(systemName: status?.fullyReady == true ? "checkmark.circle.fill" : status?.state == .failed ? "exclamationmark.triangle.fill" : "film")
                    .foregroundStyle(status?.fullyReady == true ? Color.teal : status?.state == .failed ? Color.red : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).lineLimit(1)
                    Text(statusText(item, status: status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let status, status.progress.total > 0 { ProgressView(value: status.progress.fraction).frame(maxWidth: 220) }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var selectedLecture: LibraryLecture? {
        lectures.first { selectedIDs.contains(LibraryManifestStore.lectureID(for: .local(path: $0.videoURL.standardizedFileURL.path))) }
    }
    private func openSelected() {
        if let selectedLecture { openLecture(selectedLecture) }
        else if let item = telegram.lanMedia.first(where: { selectedIDs.contains(telegramManifestID($0)) }) { openTelegram(item) }
        else { return }
        dismiss()
    }

    private func telegramManifestID(_ item: TelegramMedia) -> String {
        LibraryManifestStore.lectureID(for: .telegram(chatID: telegram.lanChatID ?? 0, messageID: item.id,
            fileID: item.fileID, name: item.name, size: item.size))
    }
    private func telegramRow(_ item: TelegramMedia) -> some View {
        let status = libraryQueue.manifest.lectures[telegramManifestID(item)]?.status
        return HStack(spacing: 12) {
            Image(systemName: status?.fullyReady == true ? "checkmark.circle.fill" : "paperplane")
                .foregroundStyle(status?.fullyReady == true ? Color.teal : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1)
                Text(status.map { statusSummary($0) } ?? ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.contentShape(Rectangle())
    }

    private func subtitleStatus(_ item: LibraryLecture) -> String {
        let german = item.germanSubtitleURL == nil ? translationText("library.missingDE") : "DE"
        let russian = item.russianSubtitleURL == nil ? translationText("library.missingRU") : "RU"
        return "\(german) · \(russian)"
    }
    private func statusText(_ item: LibraryLecture, status: LecturePreparationStatus?) -> String {
        guard let status else { return subtitleStatus(item) }
        var parts = status.languages
        if status.recognized { parts.append(translationText("library.recognized")) }
        if status.reviewed { parts.append(translationText("library.reviewed")) }
        if status.voiced { parts.append(translationText("library.voiced")) }
        if status.fullyReady { parts.append(translationText("library.complete")) }
        if status.state == .stopped { parts.append(translationText("library.stopped")) }
        if let error = status.error { parts.append(error) }
        return parts.isEmpty ? subtitleStatus(item) : parts.joined(separator: " · ")
    }
    private func statusSummary(_ status: LecturePreparationStatus) -> String {
        var parts = status.languages
        if status.recognized { parts.append(translationText("library.recognized")) }
        if status.reviewed { parts.append(translationText("library.reviewed")) }
        if status.voiced { parts.append(translationText("library.voiced")) }
        if status.fullyReady { parts.append(translationText("library.complete")) }
        return parts.isEmpty ? translationText("queue.state.\(status.state.rawValue)") : parts.joined(separator: " · ")
    }
}
