import SwiftUI

public struct LiveTranscriptPane: View {
    @Binding public var transcriptSegments: [TranscriptSegment]
    public var meetingId: String
    public var spaceId: String
    public var textScale: TextScalePreference
    public var captureState: AudioCaptureState
    public var onRenameSpeaker: ((_ oldLabel: String, _ newLabel: String) -> Void)?

    @State private var searchQuery: String = ""
    @State private var isSearchVisible: Bool = false
    @State private var userIsScrolledUp: Bool = false
    @State private var unreadSegmentCount: Int = 0
    @State private var renamingSpeaker: String? = nil
    @State private var newSpeakerName: String = ""
    @State private var saveToSpeakerDirectory: Bool = true

    public init(
        transcriptSegments: Binding<[TranscriptSegment]>,
        meetingId: String,
        spaceId: String,
        textScale: TextScalePreference,
        captureState: AudioCaptureState,
        onRenameSpeaker: ((_ oldLabel: String, _ newLabel: String) -> Void)? = nil
    ) {
        self._transcriptSegments = transcriptSegments
        self.meetingId = meetingId
        self.spaceId = spaceId
        self.textScale = textScale
        self.captureState = captureState
        self.onRenameSpeaker = onRenameSpeaker
    }

    private var filteredSegments: [TranscriptSegment] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return transcriptSegments }
        return transcriptSegments.filter { seg in
            seg.text.lowercased().contains(q) || seg.speakerLabel.lowercased().contains(q)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Optional Search / Filter Header
            if isSearchVisible || !searchQuery.isEmpty {
                searchBarHeader
                Divider()
            }

            ZStack(alignment: .bottom) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if transcriptSegments.isEmpty {
                                emptyStateChecklistView
                            } else {
                                ForEach(filteredSegments) { seg in
                                    transcriptBubble(seg)
                                        .id(seg.id)
                                }
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: transcriptSegments.count) { oldCount, newCount in
                        if userIsScrolledUp {
                            unreadSegmentCount += (newCount - oldCount)
                        } else {
                            if let last = filteredSegments.last {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                    .overlay(alignment: .bottom) {
                        // Floating "↓ N new lines" Pill
                        if userIsScrolledUp && unreadSegmentCount > 0 {
                            Button(action: {
                                userIsScrolledUp = false
                                unreadSegmentCount = 0
                                if let last = filteredSegments.last {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        proxy.scrollTo(last.id, anchor: .bottom)
                                    }
                                }
                            }) {
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.down")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("\(unreadSegmentCount) new \(unreadSegmentCount == 1 ? "line" : "lines")")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                                .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 3)
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Search Bar Header

    private var searchBarHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))

            TextField("Search spoken words or speakers...", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            if !searchQuery.isEmpty {
                Text("\(filteredSegments.count) matches")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)

                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }

            Button(action: {
                isSearchVisible = false
                searchQuery = ""
            }) {
                Text("Done")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Informative Empty State Pipeline Checklist

    private var emptyStateChecklistView: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 40)

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 60, height: 60)
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
            }

            VStack(spacing: 4) {
                Text("Listening to Live Conversation")
                    .font(.system(size: 15, weight: .bold))
                Text("Sidebrief captures both sides of the call and generates real-time suggestions.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Interactive Diagnostics Checklist
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Microphone audio tap: Active & ready")
                        .font(.system(size: 11, weight: .medium))
                }

                HStack(spacing: 8) {
                    Image(systemName: captureState == .degraded ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundColor(captureState == .degraded ? .orange : .green)
                    Text(captureState == .degraded ? "System audio: Screen Recording permission needed" : "System audio: ScreenCaptureKit loopback ready")
                        .font(.system(size: 11, weight: .medium))
                }

                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Apple Neural Engine STT: Initialized (On-Device)")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(14)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Transcript Bubble

    private func transcriptBubble(_ seg: TranscriptSegment) -> some View {
        let isYou = (seg.speakerLabel == "You")
        let color = SpeakerColorPalette.color(for: seg.speakerLabel)
        let bodyFontSize = textScale.transcriptBodySize

        return HStack(alignment: .top, spacing: 10) {
            // Speaker Avatar with Initials
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 30, height: 30)

                Text(speakerInitials(seg.speakerLabel))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(color)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(seg.speakerLabel)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(color)
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
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Rename speaker")
                    .popover(isPresented: Binding(
                        get: { renamingSpeaker == seg.speakerLabel },
                        set: { if !$0 { renamingSpeaker = nil } }
                    )) {
                        renamePopoverContent(for: seg.speakerLabel)
                    }

                    Text(formatOffsetMs(seg.startOffsetMs))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(.secondary)

                    if seg.isProvisional {
                        Text("typing...")
                            .font(.system(size: 9.5, weight: .medium))
                            .italic()
                            .foregroundColor(.orange)
                    }
                }

                Text(seg.text)
                    .font(.system(size: bodyFontSize))
                    .foregroundColor(seg.isProvisional ? .secondary : .primary)
                    .italic(seg.isProvisional)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(10)
        .background(color.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func renamePopoverContent(for speaker: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rename Speaker")
                .font(.headline)
            Text("Change '\(speaker)' across this meeting.")
                .font(.caption)
                .foregroundColor(.secondary)

            let spaceProfiles = LocalDatabaseStore.shared.getSpeakerProfiles(spaceId: spaceId)
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
                            let existing = LocalDatabaseStore.shared.getSpeakerProfiles(spaceId: spaceId)
                            if !existing.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                                let profile = SpeakerProfile(
                                    spaceId: spaceId,
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

    private func speakerInitials(_ label: String) -> String {
        let parts = label.split(separator: " ").map(String.init)
        if parts.count >= 2, let first = parts.first?.first, let second = parts[1].first {
            return "\(first)\(second)".uppercased()
        } else if let first = parts.first?.prefix(2) {
            return String(first).uppercased()
        }
        return "SP"
    }

    private func formatOffsetMs(_ ms: Int64) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
