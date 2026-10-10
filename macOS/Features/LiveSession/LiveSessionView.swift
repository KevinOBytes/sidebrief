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

    public var onStartRecording: () -> Void
    public var onPauseRecording: () -> Void
    public var onResumeRecording: () -> Void
    public var onStopRecording: () -> Void
    public var onTriggerHelp: () -> Void
    public var onPinToggled: (Bool) -> Void
    public var tokenUsage: TokenUsage = TokenUsage()
    public var onRenameSpeaker: ((_ oldLabel: String, _ newLabel: String) -> Void)? = nil
    public var onAskChat: (String) -> Void

    @ObservedObject private var syncEngine = SyncEngine.shared
    @ObservedObject private var calendarService = CalendarService.shared
    @State private var renamingSpeaker: String? = nil
    @State private var newSpeakerName: String = ""
    @State private var saveToSpeakerDirectory: Bool = true
    @State private var showCostBreakdown: Bool = false
    @State private var selectedAlternativeIndex: Int = 0
    @State private var showEvidence: Bool = false
    @State private var chatInput: String = ""
    @State private var copiedNotice: Bool = false
    @State private var isShowingBatchSpeakerRename: Bool = false

    public init(
        meeting: Binding<Meeting>,
        transcriptSegments: Binding<[TranscriptSegment]>,
        micMeter: Binding<AudioLevelMeter>,
        systemMeter: Binding<AudioLevelMeter>,
        captureState: Binding<AudioCaptureState>,
        currentSuggestion: Binding<SuggestionCard?>,
        isPinned: Binding<Bool>,
        contextSpaceName: String,
        tokenUsage: TokenUsage = TokenUsage(),
        onStartRecording: @escaping () -> Void,
        onPauseRecording: @escaping () -> Void,
        onResumeRecording: @escaping () -> Void,
        onStopRecording: @escaping () -> Void,
        onTriggerHelp: @escaping () -> Void,
        onPinToggled: @escaping (Bool) -> Void,
        onRenameSpeaker: ((_ oldLabel: String, _ newLabel: String) -> Void)? = nil,
        onAskChat: @escaping (String) -> Void
    ) {
        self._meeting = meeting
        self._transcriptSegments = transcriptSegments
        self._micMeter = micMeter
        self._systemMeter = systemMeter
        self._captureState = captureState
        self._currentSuggestion = currentSuggestion
        self._isPinned = isPinned
        self.contextSpaceName = contextSpaceName
        self.tokenUsage = tokenUsage
        self.onStartRecording = onStartRecording
        self.onPauseRecording = onPauseRecording
        self.onResumeRecording = onResumeRecording
        self.onStopRecording = onStopRecording
        self.onTriggerHelp = onTriggerHelp
        self.onPinToggled = onPinToggled
        self.onRenameSpeaker = onRenameSpeaker
        self.onAskChat = onAskChat
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Controls Bar
            topControlBar

            // Upcoming Calendar Event Banner (Zero-friction meeting prep)
            if (captureState == .idle || captureState == .failed), let next = calendarService.nextMeeting {
                HStack(spacing: 12) {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 15))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(next.title)
                                .font(.system(size: 12, weight: .bold))
                            Text(next.statusBadge)
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(next.isHappeningNow ? Color.green.opacity(0.15) : Color.blue.opacity(0.15))
                                .foregroundColor(next.isHappeningNow ? .green : .blue)
                                .clipShape(Capsule())
                        }

                        Text("\(next.formattedTimeRange)\(next.attendees.isEmpty ? "" : " • \(next.attendees.count) attendees")\(next.locationOrURL != nil ? " • Link detected" : "")")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button(action: {
                        meeting.title = next.title
                        onStartRecording()
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "record.circle")
                            Text("Start & Link Calendar")
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help("Start meeting titled '\(next.title)' and associate scheduled attendees")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.08))
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(Color.accentColor.opacity(0.2)),
                    alignment: .bottom
                )
            }

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

            // Main Transcript and Live Feed
            HSplitView {
                // Left: Transcript stream
                transcriptListView
                    .frame(minWidth: 440, maxWidth: .infinity)

                // Right: Live Suggestions & Decisions Inspector
                liveInspectorView
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
        HStack(spacing: 16) {
            // State indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title.isEmpty ? "Active Meeting" : meeting.title)
                        .font(.system(size: 14, weight: .bold))
                    Text(stateText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Dual Meters
            HStack(spacing: 14) {
                meterBar(title: "Mic", level: micMeter.linearLevel, db: micMeter.peakPower)
                meterBar(title: "System", level: systemMeter.linearLevel, db: systemMeter.peakPower)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Live Token & Cost Badge
            Button {
                showCostBreakdown.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "dollarsign.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 11))
                    Text(String(format: "$%.3f", tokenUsage.estimatedCostUSD))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                    Text("•")
                        .foregroundColor(.secondary)
                    Text("\(tokenUsage.totalTokens) tok")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.green.opacity(0.1))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showCostBreakdown) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Session Usage & Cost Breakdown")
                        .font(.headline)
                    Divider()
                    HStack {
                        Text("Prompt Tokens:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(tokenUsage.promptTokens)")
                            .font(.system(.body, design: .monospaced))
                    }
                    HStack {
                        Text("Completion Tokens:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(tokenUsage.completionTokens)")
                            .font(.system(.body, design: .monospaced))
                    }
                    HStack {
                        Text("Total Tokens:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(tokenUsage.totalTokens)")
                            .font(.system(.body, design: .monospaced))
                    }
                    HStack {
                        Text("Audio Duration:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.1f min", tokenUsage.audioDurationSeconds / 60.0))
                            .font(.system(.body, design: .monospaced))
                    }
                    Divider()
                    HStack {
                        Text("Estimated Total Cost:")
                            .fontWeight(.bold)
                        Spacer()
                        Text(String(format: "$%.4f USD", tokenUsage.estimatedCostUSD))
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .padding(14)
                .frame(width: 280)
            }

            // Cloud Sync Badge
            syncStatusBadge(syncEngine.syncStatus)

            // Action Buttons
            HStack(spacing: 8) {
                if captureState == .idle || captureState == .failed {
                    Button(action: onStartRecording) {
                        HStack(spacing: 5) {
                            Image(systemName: "record.circle.fill")
                            Text("Start New Meeting")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help("Start New Meeting (⌘N)")
                } else if captureState == .initializing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Starting...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 6)

                    Button(action: onStopRecording) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                            Text("Cancel")
                        }
                    }
                    .buttonStyle(.bordered)
                } else if captureState == .capturing || captureState == .degraded {
                    Button(action: onPauseRecording) {
                        HStack(spacing: 4) {
                            Image(systemName: "pause.fill")
                            Text("Pause")
                        }
                    }
                    .help("Pause Recording")

                    Button(action: onStopRecording) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                            Text("Stop & Finalize")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help("Stop recording & finalize meeting")
                } else if captureState == .paused {
                    Button(action: onResumeRecording) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                            Text("Resume")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .help("Resume Recording")

                    Button(action: onStopRecording) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                            Text("Stop & Finalize")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help("Stop recording & finalize meeting")
                }

                Button(action: onTriggerHelp) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("Help Me Answer")
                    }
                }
                .keyboardShortcut(" ", modifiers: [.control, .option])
                .help("Help me answer (Control-Option-Space)")

                Button(action: { isShowingBatchSpeakerRename = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.waveform.badge.magnifyingglass")
                        Text("Speakers")
                    }
                }
                .help("Review speaker voices, listen to audio samples, and batch rename")
            }
        }
        .padding(14)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func meterBar(title: String, level: Float, db: Float) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f dB", db))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.1))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(level > 0.8 ? Color.red : (level > 0.6 ? Color.yellow : Color.green))
                        .frame(width: geo.size.width * CGFloat(level))
                }
            }
            .frame(width: 80, height: 6)
        }
    }

    // MARK: - Transcript List

    private var transcriptListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if transcriptSegments.isEmpty {
                        VStack(spacing: 10) {
                            Spacer(minLength: 80)
                            Image(systemName: "text.bubble")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary)
                            Text("No transcript yet")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("Speech from microphone and macOS system audio will appear here in real time.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(transcriptSegments) { seg in
                            transcriptBubble(seg)
                                .id(seg.id)
                        }
                    }
                }
                .padding(16)
            }
            .onChange(of: transcriptSegments.count) { _, _ in
                if let last = transcriptSegments.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func transcriptBubble(_ seg: TranscriptSegment) -> some View {
        let isYou = (seg.speakerLabel == "You")

        return HStack(alignment: .top, spacing: 10) {
            // Speaker Avatar / Badge
            Circle()
                .fill(isYou ? Color.accentColor : Color.purple)
                .frame(width: 24, height: 24)
                .overlay(
                    Text(isYou ? "U" : "R")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(seg.speakerLabel)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(isYou ? .accentColor : .purple)

                    Button {
                        renamingSpeaker = seg.speakerLabel
                        newSpeakerName = seg.speakerLabel
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Rename speaker")
                    .popover(isPresented: Binding(
                        get: { renamingSpeaker == seg.speakerLabel },
                        set: { if !$0 { renamingSpeaker = nil } }
                    )) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Rename Speaker")
                                .font(.headline)
                            Text("Change '\(seg.speakerLabel)' for all current and future speech in this session.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            let spaceProfiles = LocalDatabaseStore.shared.getSpeakerProfiles(spaceId: meeting.spaceId)
                            if !spaceProfiles.isEmpty {
                                Text("KNOWN SPEAKERS IN SPACE:")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.secondary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(spaceProfiles) { p in
                                            Button(action: {
                                                newSpeakerName = p.name
                                            }) {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "person.fill")
                                                        .font(.system(size: 8))
                                                    Text(p.name)
                                                        .font(.system(size: 11, weight: .medium))
                                                }
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .background(newSpeakerName == p.name ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                                                .cornerRadius(10)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .stroke(newSpeakerName == p.name ? Color.accentColor : Color.clear, lineWidth: 1)
                                                )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                                .frame(maxWidth: 240)
                            }

                            TextField("Speaker Name", text: $newSpeakerName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)

                            Toggle("Save to Known Speakers Directory", isOn: $saveToSpeakerDirectory)
                                .font(.caption)
                                .toggleStyle(.checkbox)

                            HStack {
                                Button("Cancel") {
                                    renamingSpeaker = nil
                                }
                                .buttonStyle(.bordered)
                                Spacer()
                                Button("Rename") {
                                    let trimmed = newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmed.isEmpty {
                                        onRenameSpeaker?(seg.speakerLabel, trimmed)
                                        if saveToSpeakerDirectory {
                                            let existing = LocalDatabaseStore.shared.getSpeakerProfiles(spaceId: meeting.spaceId)
                                            if !existing.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                                                let profile = SpeakerProfile(
                                                    spaceId: meeting.spaceId,
                                                    name: trimmed,
                                                    roleOrTitle: "Participant",
                                                    organization: "",
                                                    notesOrContext: "Added from live meeting",
                                                    aliases: [seg.speakerLabel]
                                                )
                                                LocalDatabaseStore.shared.saveSpeakerProfile(profile)
                                            }
                                        }
                                    }
                                    renamingSpeaker = nil
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(12)
                    }

                    Text(formatOffsetMs(seg.startOffsetMs))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)

                    if seg.isProvisional {
                        Text("typing...")
                            .font(.system(size: 9, weight: .medium))
                            .italic()
                            .foregroundColor(.orange)
                    }
                }

                Text(seg.text)
                    .font(.system(size: 13))
                    .foregroundColor(seg.isProvisional ? .secondary : .primary)
                    .italic(seg.isProvisional)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(8)
        .background(isYou ? Color.accentColor.opacity(0.04) : Color.purple.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Live Inspector View

    private var liveInspectorView: some View {
        VStack(spacing: 0) {
            // Inspector Header
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Sidebrief Copilot")
                        .font(.system(size: 12, weight: .bold))
                }

                Spacer()

                Text(contextSpaceName)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundColor(.accentColor)
                    .clipShape(Capsule())

                if currentSuggestion != nil {
                    Button(action: {
                        isPinned.toggle()
                        onPinToggled(isPinned)
                    }) {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 11))
                            .foregroundColor(isPinned ? .orange : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isPinned ? "Unpin suggestion" : "Pin suggestion")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Inspector Content Area
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let card = currentSuggestion {
                        suggestionDetailView(card)
                    } else {
                        idleListeningView
                    }
                }
                .padding(14)
            }

            Divider()

            // Quick Chat Bar
            chatComposerBar
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func suggestionDetailView(_ card: SuggestionCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Topic Header & Trigger Badge
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CURRENT TOPIC / QUESTION")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)

                    Text(card.detectedTopicOrQuestion)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                }
                Spacer()

                Text(card.triggerReason.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // Alternatives Tabs
            let options = currentAlternativesList(for: card)
            if options.count > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<options.count, id: \.self) { idx in
                        Button(action: { selectedAlternativeIndex = idx }) {
                            Text(options[idx].label)
                                .font(.system(size: 10, weight: selectedAlternativeIndex == idx ? .semibold : .regular))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(selectedAlternativeIndex == idx ? Color.accentColor : Color.primary.opacity(0.08))
                                .foregroundColor(selectedAlternativeIndex == idx ? .white : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Selected Response Text
            let selectedAlt = options[min(selectedAlternativeIndex, options.count - 1)]
            VStack(alignment: .leading, spacing: 8) {
                Text(selectedAlt.text)
                    .font(.system(size: 12, weight: .regular))
                    .lineSpacing(3)
                    .foregroundColor(.primary)
                    .textSelection(.enabled)

                if let rationale = selectedAlt.rationale, !rationale.isEmpty {
                    Text("Why: \(rationale)")
                        .font(.system(size: 11, weight: .regular))
                        .italic()
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Evidence Bar
            HStack {
                Text(card.evidenceCategory.rawValue)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(evidenceColor(for: card.evidenceCategory).opacity(0.15))
                    .foregroundColor(evidenceColor(for: card.evidenceCategory))
                    .clipShape(Capsule())

                Spacer()

                if !card.evidenceQuotes.isEmpty {
                    Button(action: { showEvidence.toggle() }) {
                        HStack(spacing: 4) {
                            Text(showEvidence ? "Hide Evidence" : "\(card.evidenceQuotes.count) Sources")
                                .font(.system(size: 10))
                            Image(systemName: showEvidence ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8))
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Expandable Evidence Drawer
            if showEvidence && !card.evidenceQuotes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(card.evidenceQuotes) { quote in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(quote.sourceTitle)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.primary)
                            Text("\"\(quote.snippet)\"")
                                .font(.system(size: 10))
                                .italic()
                                .foregroundColor(.secondary)
                        }
                        .padding(6)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }

            // Uncertainty Note
            if let note = card.uncertaintyNote {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 10))
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            // Action Buttons (Copy & Dismiss)
            HStack(spacing: 12) {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selectedAlt.text, forType: .string)
                    copiedNotice = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedNotice = false
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: copiedNotice ? "checkmark" : "doc.on.doc")
                        Text(copiedNotice ? "Copied!" : "Copy")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: {
                    currentSuggestion = nil
                }) {
                    Text("Dismiss")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var idleListeningView: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 40)
            Image(systemName: "waveform")
                .font(.system(size: 32))
                .foregroundColor(.accentColor)

            Text("Listening to conversation...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)

            Text("Suggestions appear automatically every ~10s or when someone asks a question. You can also press Control-Option-Space anytime.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)

            Button(action: onTriggerHelp) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("Help Me Answer Now")
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var chatComposerBar: some View {
        HStack(spacing: 8) {
            TextField("Ask copilot about the meeting...", text: $chatInput)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onSubmit {
                    submitChat()
                }

            Button(action: submitChat) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(chatInput.trimmingCharacters(in: .whitespaces).isEmpty ? .secondary : .accentColor)
            }
            .buttonStyle(.plain)
            .disabled(chatInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }

    private func submitChat() {
        let text = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chatInput = ""
        onAskChat(text)
    }

    private func currentAlternativesList(for card: SuggestionCard) -> [SuggestionAlternative] {
        var list = [card.primaryResponse]
        list.append(contentsOf: card.alternatives)
        return list
    }

    private func evidenceColor(for category: EvidenceCategory) -> Color {
        switch category {
        case .supportedBySource: return .green
        case .basedOnDiscussion: return .blue
        case .inference: return .purple
        case .needsVerification: return .orange
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

    private func formatOffsetMs(_ ms: Int64) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func syncStatusBadge(_ status: SyncStatus) -> some View {
        HStack(spacing: 4) {
            switch status {
            case .idle:
                Image(systemName: "cloud.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 10))
                Text("Cloud Idle")
                    .foregroundColor(.secondary)
            case .syncing(let remaining):
                ProgressView()
                    .controlSize(.mini)
                Text("Syncing (\(remaining))...")
                    .foregroundColor(.blue)
            case .synced:
                Image(systemName: "checkmark.icloud.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 10))
                Text("R2 Synced")
                    .foregroundColor(.green)
            case .offline(let pending):
                Image(systemName: "icloud.slash")
                    .foregroundColor(.orange)
                    .font(.system(size: 10))
                Text("Offline (\(pending))")
                    .foregroundColor(.orange)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(6)
    }
}
