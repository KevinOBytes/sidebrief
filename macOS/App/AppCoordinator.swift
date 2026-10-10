import SwiftUI
import AppKit
import Carbon
import SidebriefCore

@MainActor
public final class AppCoordinator: ObservableObject {
    public static let shared = AppCoordinator()

    @Published public var activeSpace: ContextSpace = ContextSpace.defaultSpaces[0]
    @Published public var availableSpaces: [ContextSpace] = []
    @Published public var currentMeeting: Meeting
    @Published public var transcriptSegments: [TranscriptSegment] = []
    @Published public var currentSuggestion: SuggestionCard?
    @Published public var isPinned: Bool = false

    @Published public var micMeter = AudioLevelMeter()
    @Published public var systemMeter = AudioLevelMeter()
    @Published public var captureState: AudioCaptureState = .idle
    @Published public var recordingDurationSeconds: TimeInterval = 0
    @Published public var activeSpeakerMap: [String: String] = [:]
    @Published public var currentMeetingTokenUsage: TokenUsage = TokenUsage()

    @Published public var pastMeetings: [Meeting] = []
    @Published public var selectedPastMeeting: Meeting?
    @Published public var pastMeetingSummary: MeetingSummary?
    @Published public var pastMeetingSegments: [TranscriptSegment] = []

    @Published public var playbackOffsetMs: Int64 = 0
    @Published public var isPlaying: Bool = false

    public let store = LocalDatabaseStore.shared
    @Published public var memoryFacts: [MemoryFact] = []
    @Published public var emailAccounts: [EmailAccountConfig] = []

    public let captureService = AudioCaptureService()
    public let playbackEngine = AudioPlaybackEngine()
    private var sttService: TranscriptionServiceProtocol?
    private var sttStreamTask: Task<Void, Never>?
    private var assistanceCoordinator: AssistanceCoordinator?

    private struct STTAudioEnvelope: Sendable {
        let trackId: String
        let data: Data
        let sampleCount: Int
        let offsetMs: Int64
    }

    private var micAudioQueueContinuation: AsyncStream<STTAudioEnvelope>.Continuation?
    private var sysAudioQueueContinuation: AsyncStream<STTAudioEnvelope>.Continuation?
    private var micAudioWorkerTask: Task<Void, Never>?
    private var sysAudioWorkerTask: Task<Void, Never>?

    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var carbonHotKeyRef: EventHotKeyRef?
    private var durationTimer: Timer?

    public var recordingDurationFormatted: String {
        let totalSeconds = Int(recordingDurationSeconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    private init() {
        let initialMeeting = Meeting(
            spaceId: "space-work",
            title: "Work Architecture Review",
            state: .scheduled
        )
        self.currentMeeting = initialMeeting
        setupGlobalShortcut()
        setupNotificationObservers()
        loadLocalData()
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(forName: NSNotification.Name("ContextSpacesDidChange"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.reloadSpaces()
            }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("ActiveSpaceDidChange"), object: nil, queue: .main) { [weak self] note in
            let spaceId = note.object as? String
            Task { @MainActor in
                if let spaceId = spaceId, let space = self?.availableSpaces.first(where: { $0.id == spaceId }) {
                    self?.setActiveSpace(space)
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("SidebriefSettingsDidChange"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshConfiguration()
            }
        }
    }

    // MARK: - Global Shortcut (Control-Option-Space)

    private func setupGlobalShortcut() {
        // 1. Local event monitor for when Sidebrief or Floating Panel is active
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 49 && event.modifierFlags.contains([.control, .option]) {
                Task { @MainActor in
                    self?.triggerImmediateHelp()
                }
                return nil
            }
            return event
        }

        // 2. Global event monitor for when other applications are frontmost
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 49 && event.modifierFlags.contains([.control, .option]) {
                Task { @MainActor in
                    self?.triggerImmediateHelp()
                }
            }
        }

        // 3. Carbon system-wide hotkey registration
        registerCarbonHotKey()
    }

    private func registerCarbonHotKey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x5342), id: 1) // 'SB', 1
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { (_, _, userData) -> OSStatus in
            guard let userData = userData else { return noErr }
            let coordinator = Unmanaged<AppCoordinator>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                coordinator.triggerImmediateHelp()
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        _ = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), hotKeyID, GetApplicationEventTarget(), 0, &carbonHotKeyRef)
    }

    // MARK: - Duration Timer

    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.recordingDurationSeconds += 1
                self.assistanceCoordinator?.updateAudioDuration(seconds: self.recordingDurationSeconds)
                self.assistanceCoordinator?.checkPeriodicCadence()
            }
        }
    }

    private func pauseDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingDurationSeconds = 0
    }

    // MARK: - Meeting Lifecycle

    public var currentUserName: String {
        let saved = UserDefaults.standard.string(forKey: "user_name") ?? ""
        if !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return saved.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let full = NSFullUserName()
        return full.isEmpty ? "User" : full
    }

    public func createConfiguredLLMAdapter(apiKeyOverride: String = "") -> OpenRouterAdapter {
        let providerRaw = UserDefaults.standard.string(forKey: "selected_llm_provider") ?? "openrouter"
        let provider = LLMProviderType(rawValue: providerRaw) ?? .openrouter
        let customEndpoint = UserDefaults.standard.string(forKey: "custom_llm_url")

        let resolvedKey: String
        if !apiKeyOverride.isEmpty && provider == .openrouter {
            resolvedKey = apiKeyOverride
        } else {
            switch provider {
            case .openrouter:
                resolvedKey = !apiKeyOverride.isEmpty ? apiKeyOverride : (UserDefaults.standard.string(forKey: "openrouter_api_key") ?? "")
            case .anthropic:
                resolvedKey = UserDefaults.standard.string(forKey: "anthropic_api_key") ?? ""
            case .openai:
                resolvedKey = UserDefaults.standard.string(forKey: "openai_api_key") ?? ""
            case .custom:
                resolvedKey = UserDefaults.standard.string(forKey: "custom_llm_api_key") ?? ""
            }
        }

        let fastModel: String
        let deepModel: String

        switch provider {
        case .openrouter:
            let selected = UserDefaults.standard.string(forKey: "openrouter_model") ?? "anthropic/claude-sonnet-5"
            if selected == "custom" {
                let custom = UserDefaults.standard.string(forKey: "openrouter_custom_model") ?? ""
                fastModel = custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "anthropic/claude-sonnet-5" : custom.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                fastModel = selected
            }
            deepModel = UserDefaults.standard.string(forKey: "openrouter_deep_model") ?? "anthropic/claude-sonnet-5"

        case .anthropic:
            fastModel = UserDefaults.standard.string(forKey: "anthropic_model") ?? "claude-3-7-sonnet-20250219"
            deepModel = UserDefaults.standard.string(forKey: "anthropic_deep_model") ?? "claude-3-7-sonnet-20250219"

        case .openai:
            fastModel = UserDefaults.standard.string(forKey: "openai_model") ?? "gpt-4o"
            deepModel = UserDefaults.standard.string(forKey: "openai_deep_model") ?? "o3-mini"

        case .custom:
            let custom = UserDefaults.standard.string(forKey: "custom_llm_model") ?? "llama3.3"
            fastModel = custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "llama3.3" : custom.trimmingCharacters(in: .whitespacesAndNewlines)
            let deepCustom = UserDefaults.standard.string(forKey: "custom_llm_deep_model") ?? fastModel
            deepModel = deepCustom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fastModel : deepCustom.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return OpenRouterAdapter(
            providerType: provider,
            apiKey: resolvedKey.isEmpty ? "mock" : resolvedKey,
            customEndpoint: customEndpoint,
            fastModelId: fastModel,
            deepModelId: deepModel
        )
    }

    public func createConfiguredSTTService(apiKeyOverride: String = "") -> TranscriptionServiceProtocol {
        if !apiKeyOverride.isEmpty {
            return ElevenLabsStreamingSTTAdapter(apiKey: apiKeyOverride)
        }

        let providerRaw = UserDefaults.standard.string(forKey: "selected_stt_provider") ?? "apple_speech"
        let elKey = UserDefaults.standard.string(forKey: "elevenlabs_api_key") ?? ""
        let openaiKey = UserDefaults.standard.string(forKey: "openai_api_key") ?? ""

        switch providerRaw {
        case "elevenlabs":
            if !elKey.isEmpty {
                return ElevenLabsStreamingSTTAdapter(apiKey: elKey)
            } else {
                let adapter = AppleSpeechTranscriptionAdapter()
                let vocab = store.getVocabulary(spaceId: activeSpace.id).map { $0.phrase }
                let speakers = store.getSpeakerProfiles(spaceId: activeSpace.id).map { $0.name }
                adapter.setCustomVocabulary(vocab + speakers)
                return adapter
            }
        case "whisper":
            if !openaiKey.isEmpty {
                return WhisperTranscriptionAdapter(apiKey: openaiKey)
            } else {
                let adapter = AppleSpeechTranscriptionAdapter()
                let vocab = store.getVocabulary(spaceId: activeSpace.id).map { $0.phrase }
                let speakers = store.getSpeakerProfiles(spaceId: activeSpace.id).map { $0.name }
                adapter.setCustomVocabulary(vocab + speakers)
                return adapter
            }
        case "mock":
            return MockTranscriptionService()
        case "apple_speech":
            fallthrough
        default:
            let adapter = AppleSpeechTranscriptionAdapter()
            let vocab = store.getVocabulary(spaceId: activeSpace.id).map { $0.phrase }
            let speakers = store.getSpeakerProfiles(spaceId: activeSpace.id).map { $0.name }
            adapter.setCustomVocabulary(vocab + speakers)
            return adapter
        }
    }

    public func refreshConfiguration() {
        let newAdapter = createConfiguredLLMAdapter()
        assistanceCoordinator?.updateAdapter(newAdapter)
        let cadence = UserDefaults.standard.double(forKey: "evaluation_cadence_seconds")
        if cadence >= 5.0 {
            assistanceCoordinator?.evaluationCadenceSeconds = cadence
        }
        assistanceCoordinator?.setUserName(currentUserName)
        assistanceCoordinator?.setRoleToneAndGoals(activeSpace.customPrompt)
        let vocab = store.getVocabulary(spaceId: activeSpace.id)
        assistanceCoordinator?.setCustomVocabulary(vocab)
        let speakerProfiles = store.getSpeakerProfiles(spaceId: activeSpace.id)
        assistanceCoordinator?.setSpeakerProfiles(speakerProfiles)
        SpeakerDiarizationService.shared.refreshKnownProfiles(spaceId: activeSpace.id)

        if captureState == .idle {
            self.sttService = createConfiguredSTTService()
        } else if let appleSTT = sttService as? AppleSpeechTranscriptionAdapter {
            let vocabStrings = vocab.map { $0.phrase }
            let speakerStrings = speakerProfiles.map { $0.name }
            appleSTT.setCustomVocabulary(vocabStrings + speakerStrings)
        }
    }

    public func startMeeting(apiKeyElevenLabs: String = "", apiKeyOpenRouter: String = "") async {
        let meeting = Meeting(
            spaceId: activeSpace.id,
            title: "Meeting — \(Date().formatted(date: .abbreviated, time: .shortened))",
            actualStartTime: Date(),
            state: .recording
        )
        self.currentMeeting = meeting
        self.transcriptSegments.removeAll()
        self.currentSuggestion = nil
        self.recordingDurationSeconds = 0
        self.activeSpeakerMap.removeAll()
        self.currentMeetingTokenUsage = TokenUsage()
        startDurationTimer()

        let cadence = UserDefaults.standard.double(forKey: "evaluation_cadence_seconds")

        // Initialize STT Service: prefer configured provider (defaults to native Apple Speech with zero config)
        self.sttService = createConfiguredSTTService(apiKeyOverride: apiKeyElevenLabs)

        let adapter = createConfiguredLLMAdapter(apiKeyOverride: apiKeyOpenRouter)
        let coordinator = AssistanceCoordinator(
            meetingId: meeting.id,
            adapter: adapter,
            roleToneAndGoals: activeSpace.customPrompt,
            userName: currentUserName
        )
        if cadence >= 5.0 {
            coordinator.evaluationCadenceSeconds = cadence
        }
        let vocab = store.getVocabulary(spaceId: activeSpace.id)
        coordinator.setCustomVocabulary(vocab)
        let speakerProfiles = store.getSpeakerProfiles(spaceId: activeSpace.id)
        coordinator.setSpeakerProfiles(speakerProfiles)
        coordinator.delegate = self
        self.assistanceCoordinator = coordinator
        updateAssistantExcerpts()

        if let appleSTT = sttService as? AppleSpeechTranscriptionAdapter {
            let vocabStrings = vocab.map { $0.phrase }
            let speakerStrings = speakerProfiles.map { $0.name }
            appleSTT.setCustomVocabulary(vocabStrings + speakerStrings)
        }

        // Setup Strict FIFO STT Queues to guarantee in-order delivery
        micAudioWorkerTask?.cancel()
        sysAudioWorkerTask?.cancel()
        micAudioQueueContinuation?.finish()
        sysAudioQueueContinuation?.finish()

        let (micStream, micCont) = AsyncStream.makeStream(of: STTAudioEnvelope.self)
        let (sysStream, sysCont) = AsyncStream.makeStream(of: STTAudioEnvelope.self)
        self.micAudioQueueContinuation = micCont
        self.sysAudioQueueContinuation = sysCont

        self.micAudioWorkerTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await env in micStream {
                guard !Task.isCancelled, let self = self else { break }
                try? await self.sttService?.sendAudioChunk(trackId: env.trackId, pcmData: env.data, sampleCount: env.sampleCount, offsetMs: env.offsetMs)
            }
        }

        self.sysAudioWorkerTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await env in sysStream {
                guard !Task.isCancelled, let self = self else { break }
                try? await self.sttService?.sendAudioChunk(trackId: env.trackId, pcmData: env.data, sampleCount: env.sampleCount, offsetMs: env.offsetMs)
            }
        }

        // Setup Callbacks to yield non-blockingly into FIFO streams
        captureService.onMicPCMData = { [weak self, micCont] data, sampleCount, offsetMs in
            guard let self = self, let track = self.captureService.micTrack else { return }
            micCont.yield(STTAudioEnvelope(trackId: track.id, data: data, sampleCount: sampleCount, offsetMs: offsetMs))
        }

        captureService.onSystemPCMData = { [weak self, sysCont] data, sampleCount, offsetMs in
            guard let self = self, let track = self.captureService.systemTrack else { return }
            sysCont.yield(STTAudioEnvelope(trackId: track.id, data: data, sampleCount: sampleCount, offsetMs: offsetMs))
        }

        // Start Capture
        do {
            try await captureService.startCapture(meetingId: meeting.id)
            self.captureState = captureService.currentState

            if let mic = captureService.micTrack {
                try await sttService?.startSession(meetingId: meeting.id, track: mic)
            }
            if let sys = captureService.systemTrack {
                try await sttService?.startSession(meetingId: meeting.id, track: sys)
            }

            // Listen to STT Stream
            sttStreamTask?.cancel()
            if let stream = sttService?.eventStream {
                self.sttStreamTask = Task { @MainActor [weak self] in
                    for await event in stream {
                        guard let self = self, !Task.isCancelled else { break }
                        self.handleSTTEvent(event)
                    }
                }
            }
        } catch {
            self.captureState = .failed
            stopDurationTimer()
        }
    }

    public func pauseMeeting() {
        captureService.pauseCapture()
        pauseDurationTimer()
        self.captureState = captureService.currentState
        var m = currentMeeting
        m.state = .paused
        self.currentMeeting = m
    }

    public func resumeMeeting() {
        captureService.resumeCapture()
        startDurationTimer()
        self.captureState = captureService.currentState
        var m = currentMeeting
        m.state = .recording
        self.currentMeeting = m
    }

    public func stopMeeting() async {
        stopDurationTimer()

        // Flush and finish FIFO streaming queues
        micAudioQueueContinuation?.finish()
        sysAudioQueueContinuation?.finish()
        micAudioWorkerTask?.cancel()
        sysAudioWorkerTask?.cancel()
        micAudioQueueContinuation = nil
        sysAudioQueueContinuation = nil
        micAudioWorkerTask = nil
        sysAudioWorkerTask = nil

        // End STT sessions to flush trailing uncommitted speech
        if let mic = captureService.micTrack {
            try? await sttService?.endSession(trackId: mic.id)
        }
        if let sys = captureService.systemTrack {
            try? await sttService?.endSession(trackId: sys.id)
        }

        // Brief yield to allow trailing committed transcript segment to be emitted
        try? await Task.sleep(nanoseconds: 100_000_000)

        sttStreamTask?.cancel()
        sttStreamTask = nil
        let finalizedChunks = (try? await captureService.stopCapture()) ?? []
        self.captureState = captureService.currentState

        var m = currentMeeting
        m.actualEndTime = Date()
        m.state = .completed
        m.totalPromptTokens = currentMeetingTokenUsage.promptTokens
        m.totalCompletionTokens = currentMeetingTokenUsage.completionTokens
        m.estimatedCostUSD = currentMeetingTokenUsage.estimatedCostUSD
        self.currentMeeting = m

        // Persist meeting, audio chunks, and transcript segments
        store.saveMeeting(m)
        store.saveAudioChunks(finalizedChunks)
        store.saveTranscriptSegments(transcriptSegments)

        // Trigger cloud synchronization in background
        Task {
            await SyncEngine.shared.syncAll(spaceId: m.spaceId)
        }

        // Generate final summary
        var summaryToPersist: MeetingSummary?
        let adapter = createConfiguredLLMAdapter()
        if let sum = try? await adapter.generateSummary(meetingId: m.id, allSegments: transcriptSegments) {
            self.pastMeetingSummary = sum
            summaryToPersist = sum
        }
        if summaryToPersist == nil && !transcriptSegments.isEmpty {
            let overview = "Meeting completed with \(transcriptSegments.count) transcript segments recorded."
            let sum = MeetingSummary(
                meetingId: m.id,
                overview: overview,
                keyPoints: transcriptSegments.prefix(4).map { "\($0.speakerLabel): \($0.text)" }
            )
            self.pastMeetingSummary = sum
            summaryToPersist = sum
        }
        if let sum = summaryToPersist {
            store.saveSummary(sum)
        }

        self.pastMeetings = store.getMeetings()
        selectPastMeeting(m)
    }

    public func selectPastMeeting(_ meeting: Meeting) {
        self.selectedPastMeeting = meeting
        self.pastMeetingSegments = store.getTranscriptSegments(meetingId: meeting.id)
        self.pastMeetingSummary = store.getSummary(meetingId: meeting.id)
        self.playbackOffsetMs = 0
        self.isPlaying = false
    }

    public func deletePastMeeting(id: String) {
        store.deleteMeeting(id: id, spaceId: activeSpace.id)
        self.pastMeetings = store.getMeetings()
        if selectedPastMeeting?.id == id {
            if let first = pastMeetings.first {
                selectPastMeeting(first)
            } else {
                selectedPastMeeting = nil
                pastMeetingSegments = []
                pastMeetingSummary = nil
            }
        }
    }

    // MARK: - Speaker Renaming

    public func renameSpeaker(meetingId: String? = nil, oldLabel: String, newLabel: String) {
        let trimmedNew = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNew.isEmpty, trimmedNew != oldLabel else { return }

        // 1. Update session map rule for current/future incoming segments
        activeSpeakerMap[oldLabel] = trimmedNew

        // 2. Update active memory segments
        for i in 0..<transcriptSegments.count {
            if transcriptSegments[i].speakerLabel == oldLabel {
                transcriptSegments[i].speakerLabel = trimmedNew
            }
        }

        // 3. Persist in database if target meeting exists
        let targetId = meetingId ?? currentMeeting.id
        store.renameSpeakerInTranscript(meetingId: targetId, oldLabel: oldLabel, newLabel: trimmedNew)

        // 4. Update past meeting view if currently inspected
        if selectedPastMeeting?.id == targetId {
            pastMeetingSegments = store.getTranscriptSegments(meetingId: targetId)
        }
    }

    // MARK: - STT Event Handling

    private func handleSTTEvent(_ event: TranscriptionEvent) {
        switch event {
        case .provisional(let segment):
            var seg = segment
            if let renamed = activeSpeakerMap[seg.speakerLabel] {
                seg.speakerLabel = renamed
            }
            if let idx = transcriptSegments.firstIndex(where: { $0.id == seg.id }) {
                transcriptSegments[idx] = seg
            } else if let lastIdx = transcriptSegments.indices.last,
                      transcriptSegments[lastIdx].isProvisional,
                      transcriptSegments[lastIdx].trackId == seg.trackId {
                transcriptSegments[lastIdx] = seg
            } else {
                transcriptSegments.append(seg)
            }
            assistanceCoordinator?.handleProvisionalSegment(seg)

        case .committed(let segment):
            var seg = segment
            if let renamed = activeSpeakerMap[seg.speakerLabel] {
                seg.speakerLabel = renamed
            }
            if let idx = transcriptSegments.firstIndex(where: { $0.id == seg.id }) {
                transcriptSegments[idx] = seg
            } else if let lastIdx = transcriptSegments.indices.last,
                      transcriptSegments[lastIdx].isProvisional,
                      transcriptSegments[lastIdx].trackId == seg.trackId {
                transcriptSegments[lastIdx] = seg
            } else {
                transcriptSegments.append(seg)
            }
            store.saveTranscriptSegments([seg])
            assistanceCoordinator?.handleCommittedSegment(seg)

        case .started, .closed:
            break

        case .error(let trackId, let message):
            NSLog("[Sidebrief STT Error] Track %@: %@", trackId, message)
        }
    }

    // MARK: - Suggestions & HUD

    public func triggerImmediateHelp() {
        assistanceCoordinator?.requestImmediateHelp()
    }

    public func togglePinSuggestion(cardId: String, isPinned: Bool) {
        if isPinned {
            assistanceCoordinator?.pinSuggestion(cardId: cardId)
        } else {
            assistanceCoordinator?.unpinSuggestion(cardId: cardId)
        }
    }

    public func showFloatingPanel() {
        let assistantView = FloatingAssistantView(
            currentSuggestion: Binding(
                get: { self.currentSuggestion },
                set: { self.currentSuggestion = $0 }
            ),
            isPinned: Binding(
                get: { self.isPinned },
                set: { self.isPinned = $0 }
            ),
            contextSpaceName: Binding(
                get: { self.activeSpace.name },
                set: { _ in }
            ),
            isCaptureDegraded: self.captureState == .degraded,
            tokenUsage: self.currentMeetingTokenUsage,
            onPinToggled: { [weak self] pinned in
                guard let self = self else { return }
                if let id = self.currentSuggestion?.id {
                    if pinned {
                        self.assistanceCoordinator?.pinSuggestion(cardId: id)
                    } else {
                        self.assistanceCoordinator?.unpinSuggestion(cardId: id)
                    }
                }
            },
            onDismiss: {
                FloatingPanelController.shared.hidePanel()
            },
            onRequestImmediateHelp: { [weak self] in
                self?.triggerImmediateHelp()
            },
            onAskChat: { [weak self] prompt in
                self?.handleInMeetingChat(prompt: prompt)
            }
        )

        FloatingPanelController.shared.showPanel(with: AnyView(assistantView))
    }

    public func toggleFloatingPanel() {
        showFloatingPanel()
    }

    public func handleInMeetingChat(prompt: String) {
        let userMsg = ChatMessage(meetingId: currentMeeting.id, sender: .user, text: prompt)
        Task {
            let adapter = self.createConfiguredLLMAdapter()
            if let answer = try? await adapter.chat(meetingId: currentMeeting.id, messages: [userMsg], transcriptContext: transcriptSegments) {
                let card = SuggestionCard(
                    meetingId: currentMeeting.id,
                    contextRevision: transcriptSegments.count,
                    triggerReason: .chat,
                    detectedTopicOrQuestion: prompt,
                    primaryResponse: SuggestionAlternative(label: "Answer", text: answer),
                    evidenceCategory: .basedOnDiscussion
                )
                await MainActor.run {
                    self.currentSuggestion = card
                    self.isPinned = true
                    self.assistanceCoordinator?.pinSuggestion(cardId: card.id)
                }
            }
        }
    }

    // MARK: - Memory & Multi-Email Data Management

    public func loadLocalData() {
        bootstrapEnvironmentKeys()

        // Load or seed context spaces (restricted to the 3 allowed spaces)
        var loadedSpaces = store.getContextSpaces()
        if loadedSpaces.isEmpty {
            for space in ContextSpace.defaultSpaces {
                store.saveContextSpace(space)
            }
            loadedSpaces = store.getContextSpaces()
        }
        self.availableSpaces = loadedSpaces

        let savedSpaceId = UserDefaults.standard.string(forKey: "selected_space_id") ?? activeSpace.id
        if let current = loadedSpaces.first(where: { $0.id == savedSpaceId }) {
            self.activeSpace = current
        } else if let first = loadedSpaces.first {
            self.activeSpace = first
        }

        self.memoryFacts = store.getMemoryFacts(for: activeSpace.id)
        self.emailAccounts = store.getEmailAccounts(for: activeSpace.id)
        if self.emailAccounts.isEmpty && activeSpace.id == "space-work" {
            seedInitialEmailAccounts()
        }
        self.pastMeetings = store.getMeetings()
        if self.pastMeetings.isEmpty {
            seedInitialDemoMeeting()
            self.pastMeetings = store.getMeetings()
        }
        if selectedPastMeeting == nil || !pastMeetings.contains(where: { $0.id == selectedPastMeeting?.id }) {
            if let first = pastMeetings.first {
                selectPastMeeting(first)
            }
        }
        updateAssistantExcerpts()
    }

    public func setActiveSpace(_ space: ContextSpace) {
        guard ContextSpace.isValidSpaceId(space.id) else { return }
        self.activeSpace = space
        UserDefaults.standard.set(space.id, forKey: "selected_space_id")
        self.memoryFacts = store.getMemoryFacts(for: space.id)
        self.emailAccounts = store.getEmailAccounts(for: space.id)
        if self.emailAccounts.isEmpty && space.id == "space-work" {
            seedInitialEmailAccounts()
        }
        assistanceCoordinator?.setRoleToneAndGoals(space.customPrompt)
        updateAssistantExcerpts()
    }

    public func saveContextSpace(_ space: ContextSpace) {
        guard ContextSpace.isValidSpaceId(space.id) else { return }
        store.saveContextSpace(space)
        reloadSpaces()
    }

    public func deleteContextSpace(id: String) {
        guard id != "space-work", ContextSpace.isValidSpaceId(id) else { return }
        store.deleteContextSpace(id: id)
        if activeSpace.id == id {
            if let work = availableSpaces.first(where: { $0.id == "space-work" }) ?? ContextSpace.defaultSpaces.first {
                setActiveSpace(work)
            }
        }
        reloadSpaces()
    }

    public func searchMeetings(query: String, spaceId: String? = nil) -> [Meeting] {
        return store.getMeetings(spaceId: spaceId, query: query)
    }

    public func reloadSpaces() {
        self.availableSpaces = store.getContextSpaces()
        if let current = availableSpaces.first(where: { $0.id == activeSpace.id }) {
            self.activeSpace = current
            assistanceCoordinator?.setRoleToneAndGoals(current.customPrompt)
        }
    }

    private func seedInitialDemoMeeting() {
        let name = currentUserName
        let demoId = "meeting-demo-architecture"
        let startTime = Date().addingTimeInterval(-2700)
        let endTime = Date().addingTimeInterval(-300)

        let demoMeeting = Meeting(
            id: demoId,
            spaceId: "space-work",
            title: "Work Architecture Review: Audio Capture & Realtime Assistance",
            scheduledStartTime: startTime,
            actualStartTime: startTime,
            actualEndTime: endTime,
            state: .completed,
            agenda: "Review ScreenCaptureKit dual-audio pipeline, ElevenLabs Scribe v2 realtime STT with VAD deduplication, and Neon PostgreSQL persistence architecture.",
            sensitivity: "confidential"
        )
        store.saveMeeting(demoMeeting)

        let demoSegments = [
            TranscriptSegment(
                id: "seg-demo-1",
                meetingId: demoId,
                trackId: "track-mic",
                providerSegmentId: "seg-demo-1",
                speakerLabel: "You",
                text: "Welcome everyone to our executive architecture review. Today we're verifying Sidebrief's dual-audio pipeline and real-time copilot integration.",
                startOffsetMs: 0,
                endOffsetMs: 5200
            ),
            TranscriptSegment(
                id: "seg-demo-2",
                meetingId: demoId,
                trackId: "track-sys",
                providerSegmentId: "seg-demo-2",
                speakerLabel: "Alice (Staff Architect)",
                text: "Thanks \(name). I benchmarked ScreenCaptureKit and AVFoundation. Dual-track separation is maintaining sub-15ms latency with zero buffer drops or distortion.",
                startOffsetMs: 5800,
                endOffsetMs: 14200
            ),
            TranscriptSegment(
                id: "seg-demo-3",
                meetingId: demoId,
                trackId: "track-mic",
                providerSegmentId: "seg-demo-3",
                speakerLabel: "You",
                text: "What about the ElevenLabs Scribe v2 realtime streaming transcription adapter? Did the VAD commit strategy resolve the chunk duplicate issues?",
                startOffsetMs: 15000,
                endOffsetMs: 22400
            ),
            TranscriptSegment(
                id: "seg-demo-4",
                meetingId: demoId,
                trackId: "track-sys",
                providerSegmentId: "seg-demo-4",
                speakerLabel: "Bob (Lead Systems)",
                text: "Yes, we implemented persistent utterance tracking and in-place segment replacement. It completely eliminates duplicated sentences and guarantees instant provisional feedback.",
                startOffsetMs: 23100,
                endOffsetMs: 33500
            ),
            TranscriptSegment(
                id: "seg-demo-5",
                meetingId: demoId,
                trackId: "track-mic",
                providerSegmentId: "seg-demo-5",
                speakerLabel: "You",
                text: "Excellent. And on the persistence side, we've validated Neon PostgreSQL with Row-Level Security, pgvector for semantic retrieval, and full-text search across all context spaces.",
                startOffsetMs: 34200,
                endOffsetMs: 44000
            ),
            TranscriptSegment(
                id: "seg-demo-6",
                meetingId: demoId,
                trackId: "track-sys",
                providerSegmentId: "seg-demo-6",
                speakerLabel: "Alice (Staff Architect)",
                text: "Confirmed. All AES-GCM encrypted audio chunks are uploaded directly to our private Cloudflare R2 bucket, with per-session encryption keys kept strictly in macOS Keychain.",
                startOffsetMs: 44800,
                endOffsetMs: 56000
            )
        ]
        store.saveTranscriptSegments(demoSegments)

        let demoSummary = MeetingSummary(
            id: "sum-demo-architecture",
            meetingId: demoId,
            version: 1,
            generatingRevision: 1,
            overview: "Executive architecture review confirming the production-ready state of Sidebrief's dual-stream audio capture, ElevenLabs realtime transcription with VAD deduplication, and Neon PostgreSQL sync architecture.",
            keyPoints: [
                "ScreenCaptureKit and AVFoundation deliver independent mic and system audio tracks with sub-15ms handoff latency.",
                "ElevenLabs Scribe v2 realtime STT operates with VAD commit strategy, eliminating transcript duplicate artifacts.",
                "Structured data synchronizes with Neon PostgreSQL under RLS, while encrypted chunks reside in private R2.",
                "Context spaces (EQTY, TKOResearch, Personal) enforce strict data isolation across email, drive, and meeting transcripts."
            ],
            decisions: [
                DecisionItem(title: "Adopt Scribe v2 Realtime STT", rationale: "Delivers sub-500ms provisional latency with precise speaker turn-taking and zero duplicate bursts.", status: "confirmed"),
                DecisionItem(title: "Keychain Per-Meeting Key Architecture", rationale: "Guarantees zero plaintext temporary audio files touch disk before authenticated 256-bit AES-GCM encryption.", status: "confirmed")
            ],
            actionItems: [
                ActionItem(task: "Deploy production migration to Neon PostgreSQL instance", assignee: name, dueDate: "Today", status: "completed"),
                ActionItem(task: "Verify ScreenCaptureKit audio buffer conversion on macOS 26 Apple Silicon", assignee: "Alice", dueDate: "Tomorrow", status: "completed"),
                ActionItem(task: "Connect secondary Fastmail and Google Workspace email accounts", assignee: name, dueDate: "Sep 18", status: "pending")
            ],
            unresolvedQuestions: [
                "Evaluate whether WebRTC echo cancellation should be supplemented with DSP filter during high-volume speakerphone playback."
            ],
            followUpEmailDraft: """
            Hi Team,

            Thank you for attending today's Executive Architecture Review. We reviewed the dual-audio pipeline and confirmed production readiness for our ElevenLabs realtime streaming STT and Neon PostgreSQL sync engine.

            Key Outcomes:
            - Scribe v2 realtime STT with VAD commit strategy is approved.
            - Zero plaintext audio to disk; Keychain AES-GCM key management active.
            - Neon PostgreSQL RLS and pgvector verified across EQTY, TKOResearch, and Personal spaces.

            Next Steps:
            - \(name): Finalize secondary email accounts configuration.
            - Alice: Monitor ScreenCaptureKit sample rate alignment under high CPU load.

            Best regards,
            \(name)
            """
        )
        store.saveSummary(demoSummary)
    }

    private func bootstrapEnvironmentKeys() {
        let elKey = UserDefaults.standard.string(forKey: "elevenlabs_api_key") ?? ""
        let orKey = UserDefaults.standard.string(forKey: "openrouter_api_key") ?? ""

        if elKey.isEmpty || orKey.isEmpty {
            var loadedEl = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] ?? ""
            var loadedOr = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? ""

            let candidates = [
                URL(fileURLWithPath: "/Users/kevo/Projects/sidebrief/.env"),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/.env"),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects/sidebrief/.env")
            ]

            for url in candidates {
                if (loadedEl.isEmpty || loadedOr.isEmpty), let content = try? String(contentsOf: url, encoding: .utf8) {
                    for line in content.components(separatedBy: .newlines) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("ELEVENLABS_API_KEY=") && loadedEl.isEmpty {
                            loadedEl = String(trimmed.dropFirst("ELEVENLABS_API_KEY=".count)).trimmingCharacters(in: .whitespaces)
                        } else if trimmed.hasPrefix("OPENROUTER_API_KEY=") && loadedOr.isEmpty {
                            loadedOr = String(trimmed.dropFirst("OPENROUTER_API_KEY=".count)).trimmingCharacters(in: .whitespaces)
                        }
                    }
                }
            }

            if elKey.isEmpty && !loadedEl.isEmpty {
                UserDefaults.standard.set(loadedEl, forKey: "elevenlabs_api_key")
            }
            if orKey.isEmpty && !loadedOr.isEmpty {
                UserDefaults.standard.set(loadedOr, forKey: "openrouter_api_key")
            }
        }
    }

    private func seedInitialEmailAccounts() {
        let defaultEmail = EmailAccountConfig(
            id: "email_default_work",
            spaceId: "space-work",
            accountName: "Work Email (Fastmail)",
            emailAddress: "work@company.com",
            imapHost: "imap.fastmail.com",
            imapPort: 993,
            useTls: true,
            authType: "app_password",
            syncFolder: "INBOX",
            isEnabled: true
        )
        store.saveEmailAccount(defaultEmail)
        self.emailAccounts = store.getEmailAccounts(for: activeSpace.id)
    }

    public func saveMemoryFact(_ fact: MemoryFact) {
        store.saveMemoryFact(fact)
        loadLocalData()
        updateAssistantExcerpts()
    }

    public func deleteMemoryFact(id: String) {
        store.deleteMemoryFact(id: id, spaceId: activeSpace.id)
        loadLocalData()
        updateAssistantExcerpts()
    }

    public func importBootstrapMemory(text: String) {
        if let data = text.data(using: .utf8),
           let jsonFacts = try? JSONDecoder().decode([MemoryFact].self, from: data) {
            for var f in jsonFacts {
                f.spaceId = activeSpace.id
                store.saveMemoryFact(f)
            }
        } else {
            let lines = text.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let parts = trimmed.components(separatedBy: ":")
                let key = parts.first?.replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespaces) ?? "Context Fact"
                let val = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                let fact = MemoryFact(
                    spaceId: activeSpace.id,
                    category: "Imported Context",
                    key: key,
                    value: val.isEmpty ? trimmed : val,
                    source: "import",
                    isPinned: false
                )
                store.saveMemoryFact(fact)
            }
        }
        loadLocalData()
        updateAssistantExcerpts()
    }

    private func updateAssistantExcerpts() {
        let strings = memoryFacts.map { "[\($0.category)] \($0.key): \($0.value)" }
        assistanceCoordinator?.setRelevantExcerpts(strings)
    }
}

// MARK: - AssistanceCoordinatorDelegate Conformance

extension AppCoordinator: AssistanceCoordinatorDelegate {
    nonisolated public func assistanceCoordinator(_ coordinator: AssistanceCoordinator, didProduceSuggestion card: SuggestionCard) {
        Task { @MainActor in
            self.currentSuggestion = card
        }
    }

    nonisolated public func assistanceCoordinator(_ coordinator: AssistanceCoordinator, didUpdateState state: SuggestionState, cardId: String) {
        // Updated state if tracking card statuses
    }

    nonisolated public func assistanceCoordinator(_ coordinator: AssistanceCoordinator, didUpdateTokenUsage usage: TokenUsage) {
        Task { @MainActor in
            self.currentMeetingTokenUsage = usage
        }
    }
}

