import SwiftUI
import AppKit

public struct PastMeetingsView: View {
    @Binding public var pastMeetings: [Meeting]
    @Binding public var selectedPastMeeting: Meeting?
    @Binding public var summary: MeetingSummary?
    @Binding public var transcriptSegments: [TranscriptSegment]
    @Binding public var playbackOffsetMs: Int64
    @Binding public var isPlaying: Bool

    public var onSelectMeeting: (Meeting) -> Void
    public var onDeleteMeeting: (String) -> Void
    public var onPlayPause: () -> Void
    public var onSeek: (Int64) -> Void
    public var onExportMarkdown: () -> Void
    public var onExportJSON: () -> Void
    public var onExportSRT: () -> Void
    public var availableSpaces: [ContextSpace] = []
    public var onSearchMeetings: ((String, String?) -> [Meeting])? = nil
    public var onStartNewMeeting: (() -> Void)? = nil

    @State private var searchText: String = ""
    @State private var selectedSpaceFilter: String = "all"

    public init(
        pastMeetings: Binding<[Meeting]>,
        selectedPastMeeting: Binding<Meeting?>,
        summary: Binding<MeetingSummary?>,
        transcriptSegments: Binding<[TranscriptSegment]>,
        playbackOffsetMs: Binding<Int64>,
        isPlaying: Binding<Bool>,
        availableSpaces: [ContextSpace] = [],
        onSelectMeeting: @escaping (Meeting) -> Void,
        onDeleteMeeting: @escaping (String) -> Void,
        onPlayPause: @escaping () -> Void,
        onSeek: @escaping (Int64) -> Void,
        onExportMarkdown: @escaping () -> Void,
        onExportJSON: @escaping () -> Void,
        onExportSRT: @escaping () -> Void,
        onSearchMeetings: ((String, String?) -> [Meeting])? = nil,
        onStartNewMeeting: (() -> Void)? = nil
    ) {
        self._pastMeetings = pastMeetings
        self._selectedPastMeeting = selectedPastMeeting
        self._summary = summary
        self._transcriptSegments = transcriptSegments
        self._playbackOffsetMs = playbackOffsetMs
        self._isPlaying = isPlaying
        self.availableSpaces = availableSpaces
        self.onSelectMeeting = onSelectMeeting
        self.onDeleteMeeting = onDeleteMeeting
        self.onPlayPause = onPlayPause
        self.onSeek = onSeek
        self.onExportMarkdown = onExportMarkdown
        self.onExportJSON = onExportJSON
        self.onExportSRT = onExportSRT
        self.onSearchMeetings = onSearchMeetings
        self.onStartNewMeeting = onStartNewMeeting
    }

    private var filteredMeetings: [Meeting] {
        let spaceFilter = (selectedSpaceFilter == "all") ? nil : selectedSpaceFilter
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let onSearch = onSearchMeetings {
            return onSearch(q, spaceFilter)
        }
        return pastMeetings.filter { meeting in
            let matchesSpace = (spaceFilter == nil) || (meeting.spaceId == spaceFilter)
            let matchesQuery = q.isEmpty ||
                meeting.title.localizedCaseInsensitiveContains(q) ||
                meeting.agenda.localizedCaseInsensitiveContains(q)
            return matchesSpace && matchesQuery
        }
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Master Column (Meeting List & Filters)
            masterMeetingListView
                .frame(width: 320)

            Divider()

            // Detail Column (Selected Meeting Detail)
            detailMeetingView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Master Column

    private var masterMeetingListView: some View {
        VStack(spacing: 0) {
            // Header with title, count, and New Meeting button
            HStack(spacing: 8) {
                Text("Past Meetings")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Text("\(filteredMeetings.count)")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())

                if let onNew = onStartNewMeeting {
                    Button(action: onNew) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                            Text("New")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Start New Meeting (⌘N)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Search Bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                TextField("Search meetings or agenda...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
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
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            // Space Filter Picker
            Picker("Filter by Space", selection: $selectedSpaceFilter) {
                Text("All Spaces").tag("all")
                ForEach(availableSpaces) { space in
                    Text(space.name).tag(space.id)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()

            // List of Meeting Cards
            if filteredMeetings.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No meetings found")
                        .font(.system(size: 13, weight: .semibold))
                    Text(searchText.isEmpty ? "No meetings recorded in this space." : "No meetings match \"\(searchText)\".")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)

                    if !searchText.isEmpty || selectedSpaceFilter != "all" {
                        Button("Reset Filters") {
                            searchText = ""
                            selectedSpaceFilter = "all"
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredMeetings) { meeting in
                            meetingCardView(for: meeting)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
    }

    // MARK: - Meeting Card

    private func meetingCardView(for meeting: Meeting) -> some View {
        let isSelected = selectedPastMeeting?.id == meeting.id

        return Button(action: {
            onSelectMeeting(meeting)
        }) {
            VStack(alignment: .leading, spacing: 6) {
                // Title
                HStack(alignment: .top) {
                    Text(meeting.title)
                        .font(.system(size: 13, weight: isSelected ? .bold : .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    Spacer()
                }

                // Metadata Row: Space Badge + Date + Duration
                HStack(spacing: 6) {
                    Text(spaceShortName(for: meeting.spaceId))
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(spaceColor(for: meeting.spaceId).opacity(0.15))
                        .foregroundColor(spaceColor(for: meeting.spaceId))
                        .clipShape(Capsule())

                    Text(meeting.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    Text("•")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    Text(formatMeetingDuration(meeting))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                // Agenda or Preview snippet
                if !meeting.agenda.isEmpty {
                    Text(meeting.agenda)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Select") {
                onSelectMeeting(meeting)
            }
            Button("Delete Meeting", role: .destructive) {
                onDeleteMeeting(meeting.id)
            }
        }
    }

    // MARK: - Detail Column

    @ViewBuilder
    private var detailMeetingView: some View {
        if pastMeetings.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 44))
                    .foregroundColor(.secondary)
                Text("No past meetings yet")
                    .font(.headline)
                Text("Start recording a live meeting to automatically save audio, transcripts, and AI-generated summaries here.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let selected = selectedPastMeeting {
            MeetingDetailView(
                meeting: Binding(
                    get: { selectedPastMeeting ?? selected },
                    set: { selectedPastMeeting = $0 }
                ),
                summary: $summary,
                transcriptSegments: $transcriptSegments,
                playbackOffsetMs: $playbackOffsetMs,
                isPlaying: $isPlaying,
                availableSpaces: availableSpaces,
                onPlayPause: onPlayPause,
                onSeek: onSeek,
                onExportMarkdown: onExportMarkdown,
                onExportJSON: onExportJSON,
                onExportSRT: onExportSRT,
                onDelete: {
                    onDeleteMeeting(selected.id)
                }
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "hand.tap")
                    .font(.system(size: 36))
                    .foregroundColor(.secondary)
                Text("Select a meeting")
                    .font(.headline)
                Text("Choose a meeting from the list on the left to view its transcript, audio, and summary.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    private func spaceShortName(for spaceId: String) -> String {
        if let space = availableSpaces.first(where: { $0.id == spaceId }) {
            return space.name
        }
        if spaceId == "space-work" { return "Work" }
        return spaceId
    }

    private func spaceColor(for spaceId: String) -> Color {
        let palette: [Color] = [.blue, .purple, .teal, .indigo, .orange, .cyan, .green]
        if let idx = availableSpaces.firstIndex(where: { $0.id == spaceId }) {
            return palette[idx % palette.count]
        }
        let hash = abs(spaceId.hashValue)
        return palette[hash % palette.count]
    }

    private func formatMeetingDuration(_ meeting: Meeting) -> String {
        if let start = meeting.actualStartTime, let end = meeting.actualEndTime {
            let diff = Int(end.timeIntervalSince(start))
            if diff > 0 {
                let m = diff / 60
                let s = diff % 60
                return m > 0 ? "\(m)m" : "\(s)s"
            }
        }
        return "40m"
    }
}
