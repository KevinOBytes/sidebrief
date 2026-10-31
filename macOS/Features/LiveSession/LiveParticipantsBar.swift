import SwiftUI

public struct LiveParticipantsBar: View {
    public var meetingId: String
    public var spaceId: String
    public var transcriptSegments: [TranscriptSegment]
    public var onRenameSpeaker: ((_ oldLabel: String, _ newLabel: String) -> Void)?
    public var onOpenManager: () -> Void

    @State private var renamingSpeaker: String? = nil
    @State private var newSpeakerName: String = ""
    @State private var saveToSpeakerDirectory: Bool = true
    @State private var isShowingAddSpeakerPopover: Bool = false
    @State private var newSpeakerInputName: String = ""
    @State private var newSpeakerGender: String = "Speaker"

    public init(
        meetingId: String,
        spaceId: String,
        transcriptSegments: [TranscriptSegment],
        onRenameSpeaker: ((_ oldLabel: String, _ newLabel: String) -> Void)? = nil,
        onOpenManager: @escaping () -> Void
    ) {
        self.meetingId = meetingId
        self.spaceId = spaceId
        self.transcriptSegments = transcriptSegments
        self.onRenameSpeaker = onRenameSpeaker
        self.onOpenManager = onOpenManager
    }

    private var uniqueMeetingSpeakers: [String] {
        var speakers = Set<String>()
        for seg in transcriptSegments {
            speakers.insert(seg.speakerLabel)
        }
        let clusters = SpeakerDiarizationService.shared.getSessionSpeakers(meetingId: meetingId)
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

    public var body: some View {
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

            Button(action: onOpenManager) {
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
        let color = SpeakerColorPalette.color(for: speaker)

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
            .background(color.opacity(0.14))
            .foregroundColor(color)
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

    private var addSpeakerPopoverView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Speaker to Meeting")
                .font(.headline)
            Text("Add a participant by name to identify them during live capture.")
                .font(.caption)
                .foregroundColor(.secondary)

            let spaceProfiles = LocalDatabaseStore.shared.getSpeakerProfiles(spaceId: spaceId)
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
            meetingId: meetingId,
            spaceId: spaceId,
            name: trimmed,
            genderEstimate: newSpeakerGender,
            saveToDirectory: saveToSpeakerDirectory
        )
        isShowingAddSpeakerPopover = false
        newSpeakerInputName = ""
    }
}
