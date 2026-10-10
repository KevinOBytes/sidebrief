import SwiftUI
import AVFoundation

/// Interactive sheet to review all detected speakers in a meeting, listen to their
/// voice samples, batch rename them at once, and save their voiceprints for future recognition.
public struct BatchSpeakerRenameSheet: View {
    let meetingId: String
    let spaceId: String
    let onDismiss: () -> Void
    let onApply: ([String: String]) -> Void

    @State private var sessionSpeakers: [SessionSpeaker] = []
    @State private var editedNames: [String: String] = [:] // OriginalLabel -> NewName
    @State private var saveToDirectory: Set<String> = []  // Labels selected to save
    @State private var knownProfiles: [SpeakerProfile] = []

    // Audio player state for voice sample playback
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playingSpeakerId: String?

    public init(
        meetingId: String,
        spaceId: String,
        onDismiss: @escaping () -> Void,
        onApply: @escaping ([String: String]) -> Void
    ) {
        self.meetingId = meetingId
        self.spaceId = spaceId
        self.onDismiss = onDismiss
        self.onApply = onApply
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "person.2.waveform.badge.magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage & Rename Speakers")
                        .font(.headline)
                    Text("Identify speakers by voice, play audio samples, and rename all at once.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()

                Button("Done") {
                    stopPlayback()
                    onDismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Content
            if sessionSpeakers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No remote speaker voice samples recorded yet.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Start speaking or play remote meeting audio to automatically detect voices.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(sessionSpeakers) { speaker in
                            speakerCard(speaker)
                        }
                    }
                    .padding()
                }
            }

            Divider()

            // Footer / Action Bar
            HStack {
                Text("\(sessionSpeakers.count) speaker\(sessionSpeakers.count == 1 ? "" : "s") in this meeting")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Cancel") {
                    stopPlayback()
                    onDismiss()
                }
                .buttonStyle(.bordered)

                Button("Apply & Rename All") {
                    applyRenames()
                }
                .buttonStyle(.borderedProminent)
                .disabled(sessionSpeakers.isEmpty || !hasChanges)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 580, height: 490)
        .onAppear {
            loadSpeakers()
        }
        .onDisappear {
            stopPlayback()
        }
    }

    // MARK: - Speaker Card

    @ViewBuilder
    private func speakerCard(_ speaker: SessionSpeaker) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                // Speaker Avatar with Gender/Pitch Indicator
                ZStack {
                    Circle()
                        .fill(avatarColor(speaker).opacity(0.15))
                        .frame(width: 44, height: 44)

                    Image(systemName: avatarIcon(speaker))
                        .font(.system(size: 18))
                        .foregroundColor(avatarColor(speaker))
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(speaker.assignedLabel)
                            .font(.system(size: 14, weight: .semibold))

                        Text(speaker.badgeText)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .foregroundColor(.secondary)
                            .cornerRadius(6)

                        if speaker.isEnrolled {
                            HStack(spacing: 3) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 9))
                                Text("ENROLLED")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundColor(.green)
                            .cornerRadius(6)
                        }
                    }

                    Text("\(speaker.segmentCount) segments • \(formatDuration(speaker.totalDurationSeconds))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Voice Sample Playback Button
                if speaker.voiceSampleWavData != nil {
                    Button(action: {
                        togglePlayback(for: speaker)
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: playingSpeakerId == speaker.id ? "stop.fill" : "play.fill")
                                .font(.system(size: 10))
                            Text(playingSpeakerId == speaker.id ? "Stop" : "Listen (2.5s)")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(playingSpeakerId == speaker.id ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.12))
                        .foregroundColor(playingSpeakerId == speaker.id ? .red : .accentColor)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Quick Name Suggestions from Directory
            if !knownProfiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Suggested:")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)

                        ForEach(knownProfiles.prefix(6)) { profile in
                            Button(action: {
                                editedNames[speaker.assignedLabel] = profile.name
                            }) {
                                Text(profile.name)
                                    .font(.system(size: 10))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Rename Input Row
            HStack(spacing: 12) {
                TextField("New Name (e.g. Sarah, Dave)", text: Binding(
                    get: { editedNames[speaker.assignedLabel] ?? speaker.assignedLabel },
                    set: { editedNames[speaker.assignedLabel] = $0 }
                ))
                .textFieldStyle(.roundedBorder)

                // Toggle Save to Directory
                Toggle(isOn: Binding(
                    get: { saveToDirectory.contains(speaker.assignedLabel) || speaker.isEnrolled },
                    set: { checked in
                        if checked {
                            saveToDirectory.insert(speaker.assignedLabel)
                        } else {
                            saveToDirectory.remove(speaker.assignedLabel)
                        }
                    }
                )) {
                    Text("Save voiceprint for future meetings")
                        .font(.caption2)
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(14)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Logic & Actions

    private var hasChanges: Bool {
        for speaker in sessionSpeakers {
            let current = editedNames[speaker.assignedLabel] ?? speaker.assignedLabel
            if current != speaker.assignedLabel && !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            if saveToDirectory.contains(speaker.assignedLabel) && !speaker.isEnrolled {
                return true
            }
        }
        return false
    }

    private func loadSpeakers() {
        self.sessionSpeakers = SpeakerDiarizationService.shared.getSessionSpeakers(meetingId: meetingId)
        self.knownProfiles = LocalDatabaseStore.shared.getSpeakerProfiles(spaceId: spaceId)

        // If session clusters empty, seed from unique transcript speakers in database
        if sessionSpeakers.isEmpty {
            let uniqueLabels = LocalDatabaseStore.shared.getUniqueSpeakersInMeeting(meetingId: meetingId)
            self.sessionSpeakers = uniqueLabels.map { label in
                SessionSpeaker(
                    assignedLabel: label,
                    originalClusterLabel: label,
                    genderEstimate: label.contains("Female") ? "Female" : (label.contains("Male") ? "Male" : "Speaker"),
                    meanPitchHz: label.contains("Female") ? 210 : 125,
                    isEnrolled: knownProfiles.contains(where: { $0.name.caseInsensitiveCompare(label) == .orderedSame })
                )
            }
        }

        for speaker in sessionSpeakers {
            editedNames[speaker.assignedLabel] = speaker.assignedLabel
            // Default to saving if it's a new or numbered speaker
            if speaker.assignedLabel.starts(with: "Speaker ") {
                saveToDirectory.insert(speaker.assignedLabel)
            }
        }
    }

    private func applyRenames() {
        stopPlayback()

        var renamesToApply: [String: String] = [:]
        for speaker in sessionSpeakers {
            let original = speaker.assignedLabel
            let newName = (editedNames[original] ?? original).trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty && newName != original {
                renamesToApply[original] = newName
            }
        }

        // Apply via SpeakerDiarizationService
        SpeakerDiarizationService.shared.batchRenameSpeakers(
            meetingId: meetingId,
            spaceId: spaceId,
            renames: renamesToApply,
            saveToDirectory: saveToDirectory
        )

        onApply(renamesToApply)
        onDismiss()
    }

    private func togglePlayback(for speaker: SessionSpeaker) {
        if playingSpeakerId == speaker.id {
            stopPlayback()
            return
        }

        guard let wavData = speaker.voiceSampleWavData else { return }
        stopPlayback()

        do {
            audioPlayer = try AVAudioPlayer(data: wavData)
            audioPlayer?.play()
            playingSpeakerId = speaker.id

            // Reset playing state when finished
            let duration = audioPlayer?.duration ?? 2.5
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) {
                if self.playingSpeakerId == speaker.id {
                    self.playingSpeakerId = nil
                }
            }
        } catch {
            print("Failed to play audio sample: \(error)")
        }
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingSpeakerId = nil
    }

    private func avatarIcon(_ speaker: SessionSpeaker) -> String {
        if speaker.assignedLabel == "You" {
            return "person.fill"
        } else if speaker.genderEstimate == "Female" {
            return "person.fill"
        } else {
            return "person.fill"
        }
    }

    private func avatarColor(_ speaker: SessionSpeaker) -> Color {
        if speaker.assignedLabel == "You" {
            return .accentColor
        } else if speaker.genderEstimate == "Female" {
            return .pink
        } else {
            return .blue
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        } else {
            return "\(max(1, secs))s"
        }
    }
}
