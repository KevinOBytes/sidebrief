import SwiftUI
import AppKit

public struct LiveSessionView: View {
    @Binding public var meeting: Meeting
    @Binding public var transcriptSegments: [TranscriptSegment]
    @Binding public var micMeter: AudioLevelMeter
    @Binding public var systemMeter: AudioLevelMeter
    @Binding public var captureState: AudioCaptureState
    @Binding public var currentSuggestion: SuggestionCard?
    @Binding public var isPinned: Bool
    public var contextSpaceName: String
    public var sttErrorMessage: String? = nil
    public var lastMicAudioDate: Date = Date.distantPast
    public var lastSystemAudioDate: Date = Date.distantPast

    public var onStartRecording: () -> Void
    public var onPauseRecording: () -> Void
    public var onResumeRecording: () -> Void
    public var onStopRecording: () -> Void
    public var onTriggerHelp: () -> Void
    public var onPinToggled: (Bool) -> Void
    public var tokenUsage: TokenUsage = TokenUsage()
    public var onRenameSpeaker: ((_ oldLabel: String, _ newLabel: String) -> Void)? = nil
    public var onAskChat: (String) -> Void
    public var onToggleHUD: (() -> Void)? = nil

    @ObservedObject private var syncEngine = SyncEngine.shared
    @ObservedObject private var calendarService = CalendarService.shared
    @AppStorage("live_text_scale_preference") private var textScaleRaw: String = TextScalePreference.regular.rawValue
    @State private var isShowingBatchSpeakerRename: Bool = false
    @State private var isShowingDeviceConfigPopover: Bool = false

    private var currentTextScale: TextScalePreference {
        TextScalePreference(rawValue: textScaleRaw) ?? .regular
    }

    public init(
        meeting: Binding<Meeting>,
        transcriptSegments: Binding<[TranscriptSegment]>,
        micMeter: Binding<AudioLevelMeter>,
        systemMeter: Binding<AudioLevelMeter>,
        captureState: Binding<AudioCaptureState>,
        currentSuggestion: Binding<SuggestionCard?>,
        isPinned: Binding<Bool>,
        contextSpaceName: String,
        sttErrorMessage: String? = nil,
        lastMicAudioDate: Date = Date.distantPast,
        lastSystemAudioDate: Date = Date.distantPast,
        tokenUsage: TokenUsage = TokenUsage(),
        onStartRecording: @escaping () -> Void,
        onPauseRecording: @escaping () -> Void,
        onResumeRecording: @escaping () -> Void,
        onStopRecording: @escaping () -> Void,
        onTriggerHelp: @escaping () -> Void,
        onPinToggled: @escaping (Bool) -> Void,
        onRenameSpeaker: ((_ oldLabel: String, _ newLabel: String) -> Void)? = nil,
        onAskChat: @escaping (String) -> Void,
        onToggleHUD: (() -> Void)? = nil
    ) {
        self._meeting = meeting
        self._transcriptSegments = transcriptSegments
        self._micMeter = micMeter
        self._systemMeter = systemMeter
        self._captureState = captureState
        self._currentSuggestion = currentSuggestion
        self._isPinned = isPinned
        self.contextSpaceName = contextSpaceName
        self.sttErrorMessage = sttErrorMessage
        self.lastMicAudioDate = lastMicAudioDate
        self.lastSystemAudioDate = lastSystemAudioDate
        self.tokenUsage = tokenUsage
        self.onStartRecording = onStartRecording
        self.onPauseRecording = onPauseRecording
        self.onResumeRecording = onResumeRecording
        self.onStopRecording = onStopRecording
        self.onTriggerHelp = onTriggerHelp
        self.onPinToggled = onPinToggled
        self.onRenameSpeaker = onRenameSpeaker
        self.onAskChat = onAskChat
        self.onToggleHUD = onToggleHUD
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Controls Bar
            topControlBar

            // Visible STT Error Notification Banner (with 1-click Fix action)
            if let sttError = sttErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundColor(.red)
                    Text("Speech Recognition Issue: \(sttError)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    Button("Open Speech Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.red.opacity(0.12))
            }

            // Upcoming Calendar Event Banner
            if (captureState == .idle || captureState == .failed), let next = calendarService.nextMeeting {
                calendarEventBanner(next)
            }

            // ScreenCaptureKit Degraded Notice
            if captureState == .degraded {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Microphone recording is active. To capture remote participants, toggle Sidebrief ON in System Settings.")
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                    Spacer()
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.12))
            }

            Divider()

            // Concluded Meeting Download Banner (PDF, TXT, JSON, Audio)
            if (captureState == .idle || captureState == .failed) && !transcriptSegments.isEmpty {
                concludedMeetingBanner
                Divider()
            }

            // Main Workspace (Decomposed components)
            HSplitView {
                // Left: Participants Bar + Live Transcript
                VStack(spacing: 0) {
                    LiveParticipantsBar(
                        meetingId: meeting.id,
                        spaceId: meeting.spaceId,
                        transcriptSegments: transcriptSegments,
                        onRenameSpeaker: onRenameSpeaker,
                        onOpenManager: { isShowingBatchSpeakerRename = true }
                    )

                    Divider()

                    LiveTranscriptPane(
                        transcriptSegments: $transcriptSegments,
                        meetingId: meeting.id,
                        spaceId: meeting.spaceId,
                        textScale: currentTextScale,
                        captureState: captureState,
                        onRenameSpeaker: onRenameSpeaker
                    )
                }
                .frame(minWidth: 440, maxWidth: .infinity)

                // Right: Copilot Inspector & Instant Chat
                LiveSuggestionInspector(
                    currentSuggestion: $currentSuggestion,
                    isPinned: $isPinned,
                    contextSpaceName: contextSpaceName,
                    currentTranscriptRevision: transcriptSegments.count,
                    textScale: currentTextScale,
                    onPinToggled: onPinToggled,
                    onTriggerHelp: onTriggerHelp,
                    onAskChat: onAskChat
                )
                .frame(minWidth: 360, idealWidth: 440, maxWidth: 650)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isShowingBatchSpeakerRename) {
            BatchSpeakerRenameSheet(
                meetingId: meeting.id,
                spaceId: meeting.spaceId,
                onDismiss: { isShowingBatchSpeakerRename = false },
                onApply: { renames in
                    for (oldLabel, newLabel) in renames {
                        onRenameSpeaker?(oldLabel, newLabel)
                    }
                }
            )
        }
    }

    // MARK: - Top Controls Bar

    private var topControlBar: some View {
        HStack(spacing: 12) {
            // Meeting Status & Title (Left)
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(stateColor.opacity(0.25))
                        .frame(width: 16, height: 16)
                    Circle()
                        .fill(stateColor)
                        .frame(width: 9, height: 9)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(meeting.title.isEmpty ? "Active Meeting" : meeting.title)
                            .font(.system(size: 14, weight: .bold))
                            .lineLimit(1)

                        Text(contextSpaceName)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundColor(.accentColor)
                            .clipShape(Capsule())
                            .lineLimit(1)
                            .fixedSize()
                    }

                    Text(stateText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            // Live Telemetry Bar Component
            LiveTelemetryBar(
                micMeter: $micMeter,
                systemMeter: $systemMeter,
                captureState: captureState,
                sttErrorMessage: sttErrorMessage,
                lastMicAudioDate: lastMicAudioDate,
                lastSystemAudioDate: lastSystemAudioDate,
                tokenUsage: tokenUsage,
                syncStatus: syncEngine.syncStatus,
                textScale: currentTextScale,
                onSelectTextScale: { scale in
                    textScaleRaw = scale.rawValue
                }
            )
            .layoutPriority(5)

            // Action Buttons Group
            actionButtonsGroup
                .layoutPriority(10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Calendar Event Banner

    private func calendarEventBanner(_ next: CalendarMeetingEvent) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .foregroundColor(.accentColor)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(next.title)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    Text(next.statusBadge)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(next.isHappeningNow ? Color.green.opacity(0.15) : Color.blue.opacity(0.15))
                        .foregroundColor(next.isHappeningNow ? .green : .blue)
                        .clipShape(Capsule())
                        .lineLimit(1)
                        .fixedSize()
                }

                Text("\(next.formattedTimeRange)\(next.attendees.isEmpty ? "" : " • \(next.attendees.count) attendees")\(next.locationOrURL != nil ? " • Link detected" : "")")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 16)

            Button(action: {
                meeting.title = next.title
                onStartRecording()
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "record.circle.fill")
                    Text("Start & Link Calendar")
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.accentColor.opacity(0.2)),
            alignment: .bottom
        )
    }

    // MARK: - Action Buttons Group

    private var actionButtonsGroup: some View {
        HStack(spacing: 8) {
            // 1. Record / Control Button
            if captureState == .idle || captureState == .failed {
                Button(action: onStartRecording) {
                    HStack(spacing: 5) {
                        Image(systemName: "record.circle.fill")
                        Text("Start Meeting")
                            .fontWeight(.semibold)
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .fixedSize(horizontal: true, vertical: false)
                .help("Start New Meeting (⌘N)")
            } else if captureState == .initializing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, 6)

                Button(action: onStopRecording) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                        Text("Cancel")
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)
            } else if captureState == .capturing || captureState == .degraded {
                Button(action: onPauseRecording) {
                    HStack(spacing: 4) {
                        Image(systemName: "pause.fill")
                        Text("Pause")
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)
                .help("Pause Recording")

                Button(action: onStopRecording) {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                        Text("Stop & Finalize")
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .fixedSize(horizontal: true, vertical: false)
                .help("Stop recording & finalize meeting")
            } else if captureState == .paused {
                Button(action: onResumeRecording) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                        Text("Resume")
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .fixedSize(horizontal: true, vertical: false)
                .help("Resume Recording")

                Button(action: onStopRecording) {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                        Text("Stop & Finalize")
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .fixedSize(horizontal: true, vertical: false)
                .help("Stop recording & finalize meeting")
            }

            // 2. Audio Device Test Popover Button
            Button(action: { isShowingDeviceConfigPopover.toggle() }) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .help("Audio routing & input check")
            .popover(isPresented: $isShowingDeviceConfigPopover) {
                audioDeviceConfigPopover
            }

            // 3. Help Me Answer / Copilot Button
            Button(action: onTriggerHelp) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                    Text("Help Me Answer")
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .keyboardShortcut(" ", modifiers: [.control, .option])
            .help("Help me answer (Control-Option-Space)")

            // 4. Speakers Directory Button
            Button(action: { isShowingBatchSpeakerRename = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.waveform.badge.magnifyingglass")
                    Text("Speakers")
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .help("Review speaker voices, listen to audio samples, and batch rename")

            // 5. Floating HUD Button
            if let onToggleHUD = onToggleHUD {
                Button(action: onToggleHUD) {
                    HStack(spacing: 4) {
                        Image(systemName: "pip.and.dock")
                        Text("HUD")
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)
                .help("Toggle floating teleprompter HUD (⌥⌘H)")
            }

            // 6. Download & Export Menu
            if !transcriptSegments.isEmpty {
                Menu {
                    Button(action: downloadPDF) {
                        Label("Download PDF Document (.pdf)", systemImage: "doc.richtext")
                    }
                    Button(action: downloadTXT) {
                        Label("Download Plain Text (.txt)", systemImage: "doc.text")
                    }
                    Button(action: downloadJSON) {
                        Label("Download Structured JSON (.json)", systemImage: "curlybraces")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Export")
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .help("Download transcript in PDF, TXT, or JSON")
            }
        }
    }

    // MARK: - Audio Device Popover

    private var audioDeviceConfigPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Audio Capture Diagnostics")
                .font(.headline)
            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("MICROPHONE TRACK")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(.secondary)
                Text("Device: Default macOS Input (48 kHz mono)")
                    .font(.system(size: 11))
                Text("Level: \(Int(micMeter.linearLevel * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(micMeter.linearLevel > 0.05 ? .green : .secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("SYSTEM AUDIO LOOPBACK")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(.secondary)
                Text("Engine: ScreenCaptureKit System Loopback")
                    .font(.system(size: 11))
                Text("Level: \(Int(systemMeter.linearLevel * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(systemMeter.linearLevel > 0.05 ? .green : .secondary)
            }

            Divider()

            Button("Open macOS Sound Settings...") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
        .padding(14)
        .frame(width: 270)
    }

    // MARK: - Concluded Meeting Download Banner

    private var concludedMeetingBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 18))

            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting Concluded — Transcript Ready")
                    .font(.system(size: 13, weight: .bold))
                Text("\(transcriptSegments.count) spoken segments captured. Download your transcript now in your preferred format:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                Button(action: downloadPDF) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.richtext.fill")
                        Text("Download PDF")
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .fixedSize(horizontal: true, vertical: false)

                Button(action: downloadTXT) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.fill")
                        Text("Download TXT")
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)

                Button(action: downloadJSON) {
                    HStack(spacing: 4) {
                        Image(systemName: "curlybraces")
                        Text("Download JSON")
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)

                Button(action: downloadAudio) {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                        Text("Download Audio")
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.green.opacity(0.1))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.green.opacity(0.25)),
            alignment: .bottom
        )
    }

    private func downloadAudio() {
        Task {
            do {
                let data = try await FullAudioRecordingStore.shared.getFullAudioData(for: meeting.id)
                await MainActor.run {
                    let base = meeting.title.isEmpty ? "Meeting_Audio" : "\(meeting.title)_Audio"
                    MeetingExportService.shared.exportWithSavePanel(
                        filename: base,
                        fileExtension: "wav",
                        data: data
                    )
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Audio Not Available"
                    alert.informativeText = "Could not export audio: \(error.localizedDescription)"
                    alert.runModal()
                }
            }
        }
    }

    private func downloadPDF() {
        guard let pdfData = MeetingExportService.shared.generatePDFData(
            meeting: meeting,
            segments: transcriptSegments,
            summary: nil
        ) else { return }
        MeetingExportService.shared.exportWithSavePanel(
            filename: meeting.title.isEmpty ? "Meeting_Transcript" : meeting.title,
            fileExtension: "pdf",
            data: pdfData
        )
    }

    private func downloadTXT() {
        let txt = MeetingExportService.shared.generatePlainText(
            meeting: meeting,
            segments: transcriptSegments,
            summary: nil
        )
        MeetingExportService.shared.exportWithSavePanel(
            filename: meeting.title.isEmpty ? "Meeting_Transcript" : meeting.title,
            fileExtension: "txt",
            textContent: txt
        )
    }

    private func downloadJSON() {
        if let data = MeetingExportService.shared.generateJSONData(
            meeting: meeting,
            segments: transcriptSegments,
            summary: nil
        ) {
            MeetingExportService.shared.exportWithSavePanel(
                filename: meeting.title.isEmpty ? "Meeting_Transcript" : meeting.title,
                fileExtension: "json",
                data: data
            )
        }
    }

    private var stateColor: Color {
        switch captureState {
        case .capturing: return .green
        case .paused: return .yellow
        case .degraded: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }

    private var stateText: String {
        switch captureState {
        case .capturing: return "Recording Active"
        case .paused: return "Recording Paused"
        case .degraded: return "Degraded Capture"
        case .failed: return "Capture Error"
        case .initializing: return "Initializing..."
        default: return "Ready"
        }
    }
}
