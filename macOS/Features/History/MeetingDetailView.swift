import SwiftUI
import AppKit

public struct MeetingDetailView: View {
    @Binding public var meeting: Meeting
    @Binding public var summary: MeetingSummary?
    @Binding public var transcriptSegments: [TranscriptSegment]
    @Binding public var playbackOffsetMs: Int64
    @Binding public var isPlaying: Bool

    public var onPlayPause: () -> Void
    public var onSeek: (Int64) -> Void
    public var onExportMarkdown: () -> Void
    public var onExportJSON: () -> Void
    public var onExportSRT: () -> Void
    public var onDelete: (() -> Void)?

    @State private var selectedTab: Int = 0 // 0 = Summary, 1 = Transcript, 2 = Decisions & Tasks
    @State private var copiedEmailNotice: Bool = false
    @State private var showingDeleteAlert: Bool = false
    @State private var transcriptSearchText: String = ""
    @State private var renamingSpeaker: String? = nil
    @State private var newSpeakerName: String = ""
    @State private var saveToSpeakerDirectory: Bool = true
    @ObservedObject private var syncEngine = SyncEngine.shared
    public var availableSpaces: [ContextSpace] = []

    public init(
        meeting: Binding<Meeting>,
        summary: Binding<MeetingSummary?>,
        transcriptSegments: Binding<[TranscriptSegment]>,
        playbackOffsetMs: Binding<Int64>,
        isPlaying: Binding<Bool>,
        availableSpaces: [ContextSpace] = [],
        onPlayPause: @escaping () -> Void,
        onSeek: @escaping (Int64) -> Void,
        onExportMarkdown: @escaping () -> Void,
        onExportJSON: @escaping () -> Void,
        onExportSRT: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self._meeting = meeting
        self._summary = summary
        self._transcriptSegments = transcriptSegments
        self._playbackOffsetMs = playbackOffsetMs
        self._isPlaying = isPlaying
        self.availableSpaces = availableSpaces
        self.onPlayPause = onPlayPause
        self.onSeek = onSeek
        self.onExportMarkdown = onExportMarkdown
        self.onExportJSON = onExportJSON
        self.onExportSRT = onExportSRT
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            meetingHeaderView

            Divider()

            // Playback Bar
            playbackBarView

            Divider()

            // Tab Selector
            Picker("View", selection: $selectedTab) {
                Text("Summary").tag(0)
                Text("Transcript").tag(1)
                Text("Decisions & Tasks").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Tab Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if selectedTab == 0 {
                        summaryTabView
                    } else if selectedTab == 1 {
                        transcriptTabView
                    } else {
                        decisionsAndTasksTabView
                    }
                }
                .padding(20)
            }
        }
    }

    // MARK: - Header

    private var meetingHeaderView: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(meeting.title)
                    .font(.system(size: 18, weight: .bold))

                HStack(spacing: 8) {
                    // Space Badge
                    Text(spaceDisplayName)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(spaceBadgeColor.opacity(0.15))
                        .foregroundColor(spaceBadgeColor)
                        .clipShape(Capsule())

                    Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Text("•")
                        .foregroundColor(.secondary)

                    // Duration Badge
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                        Text(meetingDurationString)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.secondary)

                    Text("•")
                        .foregroundColor(.secondary)

                    Text(meeting.sensitivity.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06))
                        .foregroundColor(.secondary)
                        .clipShape(Capsule())

                    if meeting.totalPromptTokens > 0 || meeting.estimatedCostUSD > 0 {
                        Text("•")
                            .foregroundColor(.secondary)

                        HStack(spacing: 3) {
                            Image(systemName: "dollarsign.circle.fill")
                                .font(.system(size: 9))
                            Text(String(format: "$%.3f", meeting.estimatedCostUSD))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            Text("(\(meeting.totalPromptTokens + meeting.totalCompletionTokens) tok)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .foregroundColor(.green)
                    }
                }
            }

            Spacer()

            HStack(spacing: 10) {
                // Sync to R2 Button
                Button {
                    Task {
                        await syncEngine.syncPendingAudioChunks(spaceId: meeting.spaceId)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath.icloud")
                        Text("Sync to R2")
                    }
                }
                .buttonStyle(.bordered)
                .help("Upload pending encrypted audio chunks to Cloudflare R2")

                // Export Menu
                Menu {
                    Button("Export as Markdown (.md)", action: onExportMarkdown)
                    Button("Export as JSON (.json)", action: onExportJSON)
                    Button("Export Subtitles (.srt)", action: onExportSRT)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export")
                    }
                }

                // Delete Button
                if let onDelete = onDelete {
                    Button(role: .destructive, action: {
                        showingDeleteAlert = true
                    }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Delete Meeting")
                    .alert("Delete Meeting", isPresented: $showingDeleteAlert) {
                        Button("Delete", role: .destructive) {
                            onDelete()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Are you sure you want to delete \"\(meeting.title)\"? This will permanently remove its transcript, audio references, and summary.")
                    }
                }
            }
        }
        .padding(16)
    }

    // MARK: - Playback Bar

    private var playbackBarView: some View {
        HStack(spacing: 12) {
            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)

            Text(formatOffset(playbackOffsetMs))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)

            // Audio Scrub Slider
            Slider(
                value: Binding(
                    get: { Double(playbackOffsetMs) },
                    set: { onSeek(Int64($0)) }
                ),
                in: 0...max(1.0, Double(transcriptSegments.last?.endOffsetMs ?? 60000))
            )

            Text(formatOffset(transcriptSegments.last?.endOffsetMs ?? 0))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Summary Tab

    private var summaryTabView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let sum = summary {
                // Overview
                VStack(alignment: .leading, spacing: 6) {
                    Text("EXECUTIVE OVERVIEW")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)

                    Text(sum.overview)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                }

                // Key Points
                if !sum.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("KEY DISCUSSION POINTS")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)

                        ForEach(sum.keyPoints, id: \.self) { pt in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                    .foregroundColor(.accentColor)
                                Text(pt)
                                    .font(.system(size: 13))
                            }
                        }
                    }
                }

                // Follow-up Email Draft
                if let draft = sum.followUpEmailDraft, !draft.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("DRAFT FOLLOW-UP EMAIL")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(draft, forType: .string)
                                copiedEmailNotice = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copiedEmailNotice = false
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: copiedEmailNotice ? "checkmark" : "doc.on.doc")
                                    Text(copiedEmailNotice ? "Copied" : "Copy Email")
                                }
                                .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                        }

                        Text(draft)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(12)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            } else {
                Text("Summary is being generated or was not requested.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Transcript Tab

    private var transcriptTabView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Search Bar for Transcript
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                TextField("Search within transcript...", text: $transcriptSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !transcriptSearchText.isEmpty {
                    Button(action: { transcriptSearchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if !transcriptSearchText.isEmpty {
                Text("Showing \(filteredTranscriptSegments.count) of \(transcriptSegments.count) segments")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if filteredTranscriptSegments.isEmpty {
                Text("No transcript lines match \"\(transcriptSearchText)\"")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 10)
            } else {
                ForEach(filteredTranscriptSegments) { seg in
                    HStack(alignment: .top, spacing: 10) {
                        Button(action: { onSeek(seg.startOffsetMs) }) {
                            Image(systemName: "play.circle")
                                .font(.system(size: 12))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(seg.speakerLabel)
                                    .font(.system(size: 11, weight: .bold))

                                Button {
                                    renamingSpeaker = seg.speakerLabel
                                    newSpeakerName = seg.speakerLabel
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Rename speaker in transcript")
                                .popover(isPresented: Binding(
                                    get: { renamingSpeaker == seg.speakerLabel },
                                    set: { if !$0 { renamingSpeaker = nil } }
                                )) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Rename Speaker")
                                            .font(.headline)
                                        Text("Rename '\(seg.speakerLabel)' across this meeting's entire transcript.")
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
                                                    LocalDatabaseStore.shared.renameSpeakerInTranscript(meetingId: meeting.id, oldLabel: seg.speakerLabel, newLabel: trimmed)
                                                    for i in 0..<transcriptSegments.count {
                                                        if transcriptSegments[i].speakerLabel == seg.speakerLabel {
                                                            transcriptSegments[i].speakerLabel = trimmed
                                                        }
                                                    }
                                                    if saveToSpeakerDirectory {
                                                        let existing = LocalDatabaseStore.shared.getSpeakerProfiles(spaceId: meeting.spaceId)
                                                        if !existing.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                                                            let profile = SpeakerProfile(
                                                                spaceId: meeting.spaceId,
                                                                name: trimmed,
                                                                roleOrTitle: "Participant",
                                                                organization: "",
                                                                notesOrContext: "Added from meeting history",
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

                                Text(formatOffset(seg.startOffsetMs))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Text(seg.text)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.02))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: - Decisions & Tasks Tab

    private var decisionsAndTasksTabView: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Decisions
            VStack(alignment: .leading, spacing: 10) {
                Text("CONFIRMED DECISIONS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)

                if let decisions = summary?.decisions, !decisions.isEmpty {
                    ForEach(decisions) { d in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(d.title)
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Text(d.status.uppercased())
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.15))
                                    .foregroundColor(.green)
                                    .clipShape(Capsule())
                            }
                            Text(d.rationale)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                } else {
                    Text("No decisions recorded.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            // Action Items
            VStack(alignment: .leading, spacing: 10) {
                Text("ACTION ITEMS & COMMITMENTS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)

                if let actions = summary?.actionItems, !actions.isEmpty {
                    ForEach(actions) { a in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: a.status == "completed" ? "checkmark.square.fill" : "square")
                                .foregroundColor(a.status == "completed" ? .green : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.task)
                                    .font(.system(size: 13))

                                HStack(spacing: 8) {
                                    if let assignee = a.assignee {
                                        Text("Assignee: \(assignee)")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    if let due = a.dueDate {
                                        Text("Due: \(due)")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            Spacer()
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.02))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                } else {
                    Text("No action items recorded.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func formatOffset(_ ms: Int64) -> String {
        let totalSec = ms / 1000
        let m = totalSec / 60
        let s = totalSec % 60
        return String(format: "%02d:%02d", m, s)
    }

    private var spaceDisplayName: String {
        if let space = availableSpaces.first(where: { $0.id == meeting.spaceId }) {
            return space.name
        }
        if meeting.spaceId == "space-work" { return "Work" }
        return meeting.spaceId
    }

    private var spaceBadgeColor: Color {
        let palette: [Color] = [.blue, .purple, .teal, .indigo, .orange, .cyan, .green]
        if let idx = availableSpaces.firstIndex(where: { $0.id == meeting.spaceId }) {
            return palette[idx % palette.count]
        }
        let hash = abs(meeting.spaceId.hashValue)
        return palette[hash % palette.count]
    }

    private var meetingDurationString: String {
        if let start = meeting.actualStartTime, let end = meeting.actualEndTime {
            let diff = Int(end.timeIntervalSince(start))
            if diff > 0 {
                let m = diff / 60
                let s = diff % 60
                return m > 0 ? "\(m) min" : "\(s) sec"
            }
        }
        if let last = transcriptSegments.last, last.endOffsetMs > 0 {
            let totalSec = Int(last.endOffsetMs / 1000)
            let m = totalSec / 60
            let s = totalSec % 60
            return m > 0 ? "\(m) min" : "\(s) sec"
        }
        return "Recorded"
    }

    private var filteredTranscriptSegments: [TranscriptSegment] {
        let q = transcriptSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return transcriptSegments }
        return transcriptSegments.filter {
            $0.text.localizedCaseInsensitiveContains(q) || $0.speakerLabel.localizedCaseInsensitiveContains(q)
        }
    }
}
