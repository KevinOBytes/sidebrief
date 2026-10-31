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
    public var onToggleHUD: (() -> Void)? = nil

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
    @State private var isShowingAddSpeakerPopover: Bool = false
    @State private var newSpeakerInputName: String = ""
    @State private var newSpeakerGender: String = "Speaker"

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

            // Upcoming Calendar Event Banner (Zero-friction meeting prep)
            if (captureState == .idle || captureState == .failed), let next = calendarService.nextMeeting {
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
                    .help("Start meeting titled '\(next.title)' and associate scheduled attendees")
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

            // Concluded Meeting Download Banner (PDF, TXT, JSON)
            if (captureState == .idle || captureState == .failed) && !transcriptSegments.isEmpty {
                concludedMeetingBanner
                Divider()
            }

            // Main Transcript and Live Feed
            HSplitView {
                // Left: Participants Bar + Transcript stream
                VStack(spacing: 0) {
                    participantsBar
                    Divider()
                    transcriptListView
                }
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
        HStack(spacing: 12) {
            // Meeting Status & Title (Left)
            HStack(spacing: 10) {
                // Pulsing Status Dot
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

                        // Space Tag
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

            Spacer(minLength: 10)

            // Sleek Telemetry Capsule (Compact meters + Live Cost + Sync)
            telemetryCapsule
                .layoutPriority(5)

            // Action Buttons Group (Guaranteed full text, never truncated)
            actionButtonsGroup
                .layoutPriority(10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Telemetry Capsule

    private var telemetryCapsule: some View {
        HStack(spacing: 10) {
            // Dual mini VU meters
            HStack(spacing: 8) {
                miniMeter(label: "Mic", level: micMeter.linearLevel)
                miniMeter(label: "Sys", level: systemMeter.linearLevel)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Cost Badge Button
            Button {
                showCostBreakdown.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "dollarsign.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 10))
                    Text(String(format: "$%.3f", tokenUsage.estimatedCostUSD))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                    Text("•")
                        .foregroundColor(.secondary)
                        .font(.system(size: 8))
                    Text("\(tokenUsage.totalTokens)t")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.1))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showCostBreakdown) {
                costBreakdownPopover
            }

            // Sync Status
            syncStatusBadge(syncEngine.syncStatus)
        }
    }

    private func miniMeter(label: String, level: Float) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.primary.opacity(0.1))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(level > 0.8 ? Color.red : (level > 0.6 ? Color.yellow : Color.green))
                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(level))))
                }
            }
            .frame(width: 34, height: 5)
        }
    }

    private var costBreakdownPopover: some View {
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

    // MARK: - Action Buttons Group

    private var actionButtonsGroup: some View {
        HStack(spacing: 8) {
            // 1. Primary Record / Control Button
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

            // 2. Help Me Answer / Copilot Button
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

            // 3. Speakers Directory Button
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

            // 4. Floating HUD Button
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

            // 5. Download & Export Menu (PDF, TXT, JSON)
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
            // Speaker Avatar with Initials
            ZStack {
                Circle()
                    .fill(isYou ? Color.accentColor.opacity(0.18) : Color.purple.opacity(0.18))
                    .frame(width: 28, height: 28)

                Text(speakerInitials(seg.speakerLabel))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(isYou ? .accentColor : .purple)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(seg.speakerLabel)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(isYou ? .accentColor : .purple)
                        .lineLimit(1)

                    // Track origin badge
                    Text(isYou ? "YOU" : "REMOTE")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.06))
                        .foregroundColor(.secondary)
                        .clipShape(Capsule())
                        .lineLimit(1)
                        .fixedSize()

                    Button {
                        renamingSpeaker = seg.speakerLabel
                        newSpeakerName = seg.speakerLabel
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "pencil")
                            Text("Rename")
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
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

    private func speakerInitials(_ label: String) -> String {
        let parts = label.split(separator: " ").map(String.init)
        if parts.count >= 2, let first = parts.first?.first, let second = parts[1].first {
            return "\(first)\(second)".uppercased()
        } else if let first = parts.first?.prefix(2) {
            return String(first).uppercased()
        }
        return "SP"
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
                        .lineLimit(1)
                }

                Spacer()

                Text(contextSpaceName)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundColor(.accentColor)
                    .clipShape(Capsule())
                    .lineLimit(1)
                    .fixedSize()

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
                    .fixedSize(horizontal: true, vertical: false)
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
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)

                Spacer()

                Button(action: {
                    currentSuggestion = nil
                }) {
                    Text("Dismiss")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
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
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)

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
                .help("Download formatted vector PDF with speaker badges")

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
                .help("Download plain text transcript (.txt)")

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
                .help("Download structured JSON transcript (.json)")

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
                .help("Download full meeting audio recording (.wav)")
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

    // MARK: - Participants & Speaker Bar

    private var uniqueMeetingSpeakers: [String] {
        var speakers = Set<String>()
        for seg in transcriptSegments {
            speakers.insert(seg.speakerLabel)
        }
        let clusters = SpeakerDiarizationService.shared.getSessionSpeakers(meetingId: meeting.id)
        for c in clusters {
            speakers.insert(c.assignedLabel)
        }
        if speakers.isEmpty {
            speakers.insert("You")
        }
        return speakers.sorted { a, b in
            if a == "You" { return true }
            if b == "You" { return false }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    private var participantsBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("SPEAKERS:")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(uniqueMeetingSpeakers, id: \.self) { speaker in
                        speakerChip(speaker)
                    }

                    // Add Speaker Button
                    Button(action: {
                        isShowingAddSpeakerPopover = true
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                            Text("Add Speaker")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundColor(.accentColor)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isShowingAddSpeakerPopover) {
                        addSpeakerPopoverView
                    }
                }
            }

            Spacer(minLength: 4)

            Button(action: { isShowingBatchSpeakerRename = true }) {
                HStack(spacing: 3) {
                    Image(systemName: "waveform.and.person.filled")
                        .font(.system(size: 9))
                    Text("Manage")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open Voice Sample & Diarization Manager")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.02))
    }

    private func speakerChip(_ speaker: String) -> some View {
        let isYou = (speaker == "You")
        return Button(action: {
            renamingSpeaker = speaker
            newSpeakerName = speaker
        }) {
            HStack(spacing: 4) {
                Image(systemName: isYou ? "person.crop.circle.fill" : "person.fill")
                    .font(.system(size: 9))
                Text(speaker)
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "pencil")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary.opacity(0.8))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(isYou ? Color.accentColor.opacity(0.15) : Color.purple.opacity(0.12))
            .foregroundColor(isYou ? .accentColor : .purple)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .help("Click to rename '\(speaker)' across this meeting")
        .popover(isPresented: Binding(
            get: { renamingSpeaker == speaker },
            set: { if !$0 { renamingSpeaker = nil } }
        )) {
            renameSpeakerPopover(for: speaker)
        }
    }

    private func renameSpeakerPopover(for speaker: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rename Speaker")
                .font(.headline)
            Text("Rename '\(speaker)' across this meeting.")
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
                        onRenameSpeaker?(speaker, trimmed)
                        if saveToSpeakerDirectory {
                            let existing = LocalDatabaseStore.shared.getSpeakerProfiles(spaceId: meeting.spaceId)
                            if !existing.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                                let profile = SpeakerProfile(
                                    spaceId: meeting.spaceId,
                                    name: trimmed,
                                    roleOrTitle: "Participant",
                                    organization: "",
                                    notesOrContext: "Added from live meeting",
                                    aliases: [speaker]
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

    private var addSpeakerPopoverView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Speaker to Meeting")
                .font(.headline)
            Text("Add a participant by name to identify them during live capture.")
                .font(.caption)
                .foregroundColor(.secondary)

            let spaceProfiles = LocalDatabaseStore.shared.getSpeakerProfiles(spaceId: meeting.spaceId)
            let unadded = spaceProfiles.filter { !uniqueMeetingSpeakers.contains($0.name) }
            if !unadded.isEmpty {
                Text("QUICK SELECT KNOWN SPEAKER:")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(unadded) { p in
                            Button(action: {
                                newSpeakerInputName = p.name
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 8))
                                    Text(p.name)
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(newSpeakerInputName == p.name ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                                .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 260)
            }

            TextField("Speaker Name (e.g. Alex Miller)", text: $newSpeakerInputName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

            Picker("Voice Pitch", selection: $newSpeakerGender) {
                Text("Auto Voice").tag("Speaker")
                Text("Male Pitch").tag("Male")
                Text("Female Pitch").tag("Female")
            }
            .pickerStyle(.menu)

            Toggle("Save to Known Speakers Directory", isOn: $saveToSpeakerDirectory)
                .font(.caption)
                .toggleStyle(.checkbox)

            HStack {
                Button("Cancel") {
                    isShowingAddSpeakerPopover = false
                    newSpeakerInputName = ""
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Add Speaker") {
                    addNewSpeaker()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newSpeakerInputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
    }

    private func addNewSpeaker() {
        let trimmed = newSpeakerInputName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        SpeakerDiarizationService.shared.addNamedSpeaker(
            meetingId: meeting.id,
            spaceId: meeting.spaceId,
            name: trimmed,
            genderEstimate: newSpeakerGender,
            saveToDirectory: saveToSpeakerDirectory
        )
        isShowingAddSpeakerPopover = false
        newSpeakerInputName = ""
    }
}
