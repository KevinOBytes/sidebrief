import Foundation
import AVFoundation

/// Representation of a speaker cluster detected in the current meeting session.
public struct SessionSpeaker: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public var assignedLabel: String
    public var originalClusterLabel: String
    public var genderEstimate: String
    public var meanPitchHz: Double
    public var voiceprint: Voiceprint?
    public var voiceSampleWavData: Data?
    public var segmentCount: Int
    public var totalDurationSeconds: Double
    public var isEnrolled: Bool

    public init(
        id: String = UUID().uuidString,
        assignedLabel: String,
        originalClusterLabel: String,
        genderEstimate: String,
        meanPitchHz: Double,
        voiceprint: Voiceprint? = nil,
        voiceSampleWavData: Data? = nil,
        segmentCount: Int = 1,
        totalDurationSeconds: Double = 0,
        isEnrolled: Bool = false
    ) {
        self.id = id
        self.assignedLabel = assignedLabel
        self.originalClusterLabel = originalClusterLabel
        self.genderEstimate = genderEstimate
        self.meanPitchHz = meanPitchHz
        self.voiceprint = voiceprint
        self.voiceSampleWavData = voiceSampleWavData
        self.segmentCount = segmentCount
        self.totalDurationSeconds = totalDurationSeconds
        self.isEnrolled = isEnrolled
    }

    /// Descriptive badge for UI display (e.g. "124 Hz • Male" or "215 Hz • Female")
    public var badgeText: String {
        if meanPitchHz > 50 {
            return "\(Int(round(meanPitchHz))) Hz • \(genderEstimate)"
        } else {
            return genderEstimate
        }
    }
}

/// Service that coordinates acoustic speaker diarization, voice identification,
/// cluster attribution, and voice sample management for meetings.
public final class SpeakerDiarizationService: @unchecked Sendable {
    public static let shared = SpeakerDiarizationService()

    private let queue = DispatchQueue(label: "com.sidebrief.audio.diarization", qos: .userInitiated)

    // Meeting ID -> Array of Session Speakers
    private var sessionClusters: [String: [SessionSpeaker]] = [:]

    // Cached known profiles for fast real-time comparison
    private var knownProfiles: [SpeakerProfile] = []

    private init() {
        refreshKnownProfiles()
    }

    /// Refresh enrolled speaker profiles from the local database
    public func refreshKnownProfiles(spaceId: String? = nil) {
        queue.async {
            self.knownProfiles = LocalDatabaseStore.shared.getSpeakerProfiles(spaceId: spaceId)
        }
    }

    /// Identify or attribute a speaker label for an audio segment.
    /// - Parameters:
    ///   - meetingId: The active meeting ID.
    ///   - isMic: True if recorded from local microphone ("You"), false if remote system audio.
    ///   - pcmData: Raw 16-bit PCM audio buffer.
    ///   - sampleRate: Audio sample rate (e.g. 48000 or 16000).
    ///   - segmentDurationSeconds: Optional exact duration of the segment in seconds (used on final commit).
    ///   - isFinal: True if this is a committed transcript segment; false if streaming provisional lookup.
    ///   - spaceId: Optional active context space ID.
    /// - Returns: Attributed speaker label (e.g. "You", "Sarah", "Speaker 1 (Male)", "Speaker 2 (Female)").
    public func attributeSpeaker(
        meetingId: String,
        isMic: Bool,
        pcmData: Data,
        sampleRate: Double = 48000.0,
        segmentDurationSeconds: Double? = nil,
        isFinal: Bool = true,
        spaceId: String? = nil
    ) -> String {
        let userName = UserDefaults.standard.string(forKey: "sidebrief_user_name") ?? "You"
        let finalUserName = userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "You" : userName

        if isMic {
            if !isFinal {
                return finalUserName
            }

            // Finalized local microphone segment
            let segmentDuration = segmentDurationSeconds ?? (Double(pcmData.count / 2) / sampleRate)

            queue.sync {
                var clusters = self.sessionClusters[meetingId] ?? []
                let vp = VoiceprintEngine.extractVoiceprint(from: pcmData, sampleRate: sampleRate)
                let wav = VoiceprintEngine.createVoicedSampleWav(from: pcmData, sourceSampleRate: sampleRate)

                if let idx = clusters.firstIndex(where: { $0.assignedLabel == finalUserName }) {
                    clusters[idx].segmentCount += 1
                    clusters[idx].totalDurationSeconds += max(0.1, segmentDuration)

                    // Upgrade voice sample if new sample is clearer or existing is missing
                    if clusters[idx].voiceSampleWavData == nil && wav != nil {
                        clusters[idx].voiceSampleWavData = wav
                        clusters[idx].voiceprint = vp
                    } else if let newVp = vp, let existingVp = clusters[idx].voiceprint {
                        let existingWavLen = clusters[idx].voiceSampleWavData?.count ?? 0
                        let newWavLen = wav?.count ?? 0
                        if (newVp.pitchConfidence > existingVp.pitchConfidence + 0.08 || (existingWavLen < 48000 * 2 && newWavLen >= 48000 * 2)) && wav != nil {
                            clusters[idx].voiceprint = newVp
                            clusters[idx].voiceSampleWavData = wav
                            if newVp.meanPitchHz > 50 {
                                clusters[idx].meanPitchHz = newVp.meanPitchHz
                                clusters[idx].genderEstimate = newVp.estimatedGender
                            }
                        }
                    }
                } else {
                    let userSpeaker = SessionSpeaker(
                        assignedLabel: finalUserName,
                        originalClusterLabel: finalUserName,
                        genderEstimate: vp?.estimatedGender ?? "Speaker",
                        meanPitchHz: vp?.meanPitchHz ?? 0.0,
                        voiceprint: vp,
                        voiceSampleWavData: wav,
                        segmentCount: 1,
                        totalDurationSeconds: max(0.1, segmentDuration),
                        isEnrolled: true
                    )
                    clusters.insert(userSpeaker, at: 0)
                }
                self.sessionClusters[meetingId] = clusters
            }
            return finalUserName
        }

        // Remote participant speech analysis
        let voiceprint = VoiceprintEngine.extractVoiceprint(from: pcmData, sampleRate: sampleRate)

        // 1. If audio is too short or unvoiced:
        if voiceprint == nil {
            return queue.sync {
                var clusters = self.sessionClusters[meetingId] ?? []
                let firstRemoteIdx = clusters.firstIndex(where: { $0.assignedLabel != finalUserName && $0.assignedLabel != "You" })

                if let idx = firstRemoteIdx {
                    if isFinal {
                        let segmentDuration = segmentDurationSeconds ?? (Double(pcmData.count / 2) / sampleRate)
                        clusters[idx].segmentCount += 1
                        clusters[idx].totalDurationSeconds += max(0.1, segmentDuration)
                        self.sessionClusters[meetingId] = clusters
                    }
                    return clusters[idx].assignedLabel
                } else {
                    let fallbackLabel = "Speaker 1"
                    if isFinal {
                        let segmentDuration = segmentDurationSeconds ?? (Double(pcmData.count / 2) / sampleRate)
                        let newSpeaker = SessionSpeaker(
                            assignedLabel: fallbackLabel,
                            originalClusterLabel: fallbackLabel,
                            genderEstimate: "Speaker",
                            meanPitchHz: 0.0,
                            voiceprint: nil,
                            voiceSampleWavData: nil,
                            segmentCount: 1,
                            totalDurationSeconds: max(0.1, segmentDuration),
                            isEnrolled: false
                        )
                        clusters.append(newSpeaker)
                        self.sessionClusters[meetingId] = clusters
                    }
                    return fallbackLabel
                }
            }
        }

        guard let vp = voiceprint else { return "Speaker 1" }

        // If provisional query (not final), only match candidate label without modifying duration or segment counts!
        if !isFinal {
            return queue.sync {
                let clusters = self.sessionClusters[meetingId] ?? []

                // Check known profiles
                for profile in self.knownProfiles {
                    guard let enrolledVp = profile.voiceprint else { continue }
                    if VoiceprintEngine.similarity(between: vp, and: enrolledVp) >= 0.78 {
                        return profile.name
                    }
                }

                // Check session clusters
                for cluster in clusters where cluster.assignedLabel != finalUserName && cluster.assignedLabel != "You" {
                    guard let clusterVp = cluster.voiceprint else { continue }
                    if VoiceprintEngine.similarity(between: vp, and: clusterVp) >= 0.76 {
                        return cluster.assignedLabel
                    }
                }

                let remoteClusters = clusters.filter { $0.assignedLabel != finalUserName && $0.assignedLabel != "You" }
                let nextIndex = remoteClusters.count + 1
                return vp.estimatedGender == "Speaker" ? "Speaker \(nextIndex)" : "Speaker \(nextIndex) (\(vp.estimatedGender))"
            }
        }

        // Final commit: update segment count, accurate turn duration, and dynamic voice sample quality
        let segmentDuration = segmentDurationSeconds ?? (Double(pcmData.count / 2) / sampleRate)

        return queue.sync {
            var clusters = self.sessionClusters[meetingId] ?? []

            // 1. Check against Enrolled Known Speaker Profiles (Historical Voiceprints)
            var bestProfileMatch: (SpeakerProfile, Double)? = nil
            for profile in self.knownProfiles {
                guard let enrolledVp = profile.voiceprint else { continue }
                let score = VoiceprintEngine.similarity(between: vp, and: enrolledVp)
                if score >= 0.78 {
                    if let currentBest = bestProfileMatch {
                        if score > currentBest.1 {
                            bestProfileMatch = (profile, score)
                        }
                    } else {
                        bestProfileMatch = (profile, score)
                    }
                }
            }

            if let (matchedProfile, _) = bestProfileMatch {
                let wav = VoiceprintEngine.createVoicedSampleWav(from: pcmData, sourceSampleRate: sampleRate)
                if let clusterIndex = clusters.firstIndex(where: { $0.assignedLabel == matchedProfile.name }) {
                    clusters[clusterIndex].segmentCount += 1
                    clusters[clusterIndex].totalDurationSeconds += max(0.1, segmentDuration)

                    // Upgrade voice sample if new sample is clearer or existing is missing
                    if clusters[clusterIndex].voiceSampleWavData == nil && wav != nil {
                        clusters[clusterIndex].voiceSampleWavData = wav
                        clusters[clusterIndex].voiceprint = vp
                    } else if let existingVp = clusters[clusterIndex].voiceprint, let newWav = wav {
                        let existingWavLen = clusters[clusterIndex].voiceSampleWavData?.count ?? 0
                        if (vp.pitchConfidence > existingVp.pitchConfidence + 0.08 || (existingWavLen < 48000 * 2 && newWav.count >= 48000 * 2)) {
                            clusters[clusterIndex].voiceprint = vp
                            clusters[clusterIndex].voiceSampleWavData = newWav
                        }
                    }
                } else {
                    let sampleWav = wav ?? matchedProfile.voiceSampleWavData
                    let enrolledCluster = SessionSpeaker(
                        assignedLabel: matchedProfile.name,
                        originalClusterLabel: matchedProfile.name,
                        genderEstimate: matchedProfile.genderEstimate ?? vp.estimatedGender,
                        meanPitchHz: vp.meanPitchHz > 0 ? vp.meanPitchHz : (matchedProfile.voiceprint?.meanPitchHz ?? 0),
                        voiceprint: vp,
                        voiceSampleWavData: sampleWav,
                        segmentCount: 1,
                        totalDurationSeconds: max(0.1, segmentDuration),
                        isEnrolled: true
                    )
                    clusters.append(enrolledCluster)
                }
                self.sessionClusters[meetingId] = clusters
                return matchedProfile.name
            }

            // 2. Check against Existing Remote Clusters in this Meeting Session
            var bestSessionMatch: (Int, Double)? = nil
            for (idx, cluster) in clusters.enumerated() {
                guard cluster.assignedLabel != finalUserName && cluster.assignedLabel != "You", let clusterVp = cluster.voiceprint else { continue }
                let score = VoiceprintEngine.similarity(between: vp, and: clusterVp)
                if score >= 0.76 {
                    if let currentBest = bestSessionMatch {
                        if score > currentBest.1 {
                            bestSessionMatch = (idx, score)
                        }
                    } else {
                        bestSessionMatch = (idx, score)
                    }
                }
            }

            if let (matchIdx, _) = bestSessionMatch {
                clusters[matchIdx].segmentCount += 1
                clusters[matchIdx].totalDurationSeconds += max(0.1, segmentDuration)

                let wav = VoiceprintEngine.createVoicedSampleWav(from: pcmData, sourceSampleRate: sampleRate)
                if clusters[matchIdx].voiceSampleWavData == nil && wav != nil {
                    clusters[matchIdx].voiceSampleWavData = wav
                    clusters[matchIdx].voiceprint = vp
                } else if let existingVp = clusters[matchIdx].voiceprint, let newWav = wav {
                    let existingWavLen = clusters[matchIdx].voiceSampleWavData?.count ?? 0
                    if (vp.pitchConfidence > existingVp.pitchConfidence + 0.08 || (existingWavLen < 48000 * 2 && newWav.count >= 48000 * 2)) {
                        clusters[matchIdx].voiceprint = vp
                        clusters[matchIdx].voiceSampleWavData = newWav
                        if vp.meanPitchHz > 50 {
                            clusters[matchIdx].meanPitchHz = vp.meanPitchHz
                            clusters[matchIdx].genderEstimate = vp.estimatedGender
                        }
                    }
                }

                self.sessionClusters[meetingId] = clusters
                return clusters[matchIdx].assignedLabel
            }

            // 3. New Distinct Remote Speaker Detected
            let remoteClusters = clusters.filter { $0.assignedLabel != finalUserName && $0.assignedLabel != "You" }
            let nextIndex = remoteClusters.count + 1
            let gender = vp.estimatedGender
            let generatedLabel = (gender == "Speaker") ? "Speaker \(nextIndex)" : "Speaker \(nextIndex) (\(gender))"

            let sampleWav = VoiceprintEngine.createVoicedSampleWav(from: pcmData, sourceSampleRate: sampleRate)
            let newSpeaker = SessionSpeaker(
                assignedLabel: generatedLabel,
                originalClusterLabel: generatedLabel,
                genderEstimate: gender,
                meanPitchHz: vp.meanPitchHz,
                voiceprint: vp,
                voiceSampleWavData: sampleWav,
                segmentCount: 1,
                totalDurationSeconds: max(0.1, segmentDuration),
                isEnrolled: false
            )

            clusters.append(newSpeaker)
            self.sessionClusters[meetingId] = clusters
            return generatedLabel
        }
    }

    /// Retrieve all identified speakers and their voice samples for a meeting
    public func getSessionSpeakers(meetingId: String) -> [SessionSpeaker] {
        queue.sync {
            self.sessionClusters[meetingId] ?? []
        }
    }

    /// Register or manually add a named speaker to a meeting session ahead of time or on-the-fly.
    @discardableResult
    public func addNamedSpeaker(
        meetingId: String,
        spaceId: String? = nil,
        name: String,
        genderEstimate: String = "Speaker",
        roleOrTitle: String = "Participant",
        saveToDirectory: Bool = true
    ) -> SessionSpeaker {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return queue.sync {
            var clusters = self.sessionClusters[meetingId] ?? []
            if let existing = clusters.first(where: { $0.assignedLabel.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                return existing
            }

            let newSpeaker = SessionSpeaker(
                assignedLabel: trimmed,
                originalClusterLabel: trimmed,
                genderEstimate: genderEstimate,
                meanPitchHz: genderEstimate == "Female" ? 210.0 : 125.0,
                voiceprint: nil,
                voiceSampleWavData: nil,
                segmentCount: 0,
                totalDurationSeconds: 0,
                isEnrolled: saveToDirectory
            )
            clusters.append(newSpeaker)
            self.sessionClusters[meetingId] = clusters

            if saveToDirectory {
                let existingProfiles = LocalDatabaseStore.shared.getSpeakerProfiles(spaceId: spaceId)
                if !existingProfiles.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                    let profile = SpeakerProfile(
                        spaceId: spaceId,
                        name: trimmed,
                        roleOrTitle: roleOrTitle,
                        organization: "",
                        notesOrContext: "Manually added participant",
                        aliases: [trimmed],
                        genderEstimate: genderEstimate
                    )
                    LocalDatabaseStore.shared.saveSpeakerProfile(profile)
                }
                self.knownProfiles = LocalDatabaseStore.shared.getSpeakerProfiles(spaceId: spaceId)
            }

            return newSpeaker
        }
    }

    /// Batch rename multiple speakers in a meeting at once and optionally save
    /// their voiceprints and audio samples into the Known Speakers Directory.
    /// - Parameters:
    ///   - meetingId: The meeting ID.
    ///   - spaceId: Optional context space ID.
    ///   - renames: Dictionary mapping [OldLabel: NewLabel].
    ///   - saveToDirectory: Set of labels to save as persistent speaker profiles.
    public func batchRenameSpeakers(
        meetingId: String,
        spaceId: String? = nil,
        renames: [String: String],
        saveToDirectory: Set<String>
    ) {
        queue.sync {
            var clusters = self.sessionClusters[meetingId] ?? []

            // 1. Update SQLite transcript segments atomically
            LocalDatabaseStore.shared.batchRenameSpeakersInTranscript(meetingId: meetingId, renames: renames)

            // 2. Update memory clusters and persist selected profiles
            for (oldLabel, newLabel) in renames {
                let trimmedNew = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedNew.isEmpty else { continue }

                if let idx = clusters.firstIndex(where: { $0.assignedLabel == oldLabel }) {
                    clusters[idx].assignedLabel = trimmedNew

                    if saveToDirectory.contains(oldLabel) || saveToDirectory.contains(trimmedNew) {
                        clusters[idx].isEnrolled = true

                        // Save to persistent database
                        let cluster = clusters[idx]
                        let profile = SpeakerProfile(
                            spaceId: spaceId,
                            name: trimmedNew,
                            roleOrTitle: "Participant",
                            organization: "",
                            notesOrContext: "Enrolled from meeting voice sample (\(cluster.badgeText))",
                            aliases: [oldLabel],
                            voiceprint: cluster.voiceprint,
                            genderEstimate: cluster.genderEstimate,
                            voiceSampleWavData: cluster.voiceSampleWavData
                        )
                        LocalDatabaseStore.shared.saveSpeakerProfile(profile)
                    }
                }
            }

            self.sessionClusters[meetingId] = clusters
            self.knownProfiles = LocalDatabaseStore.shared.getSpeakerProfiles(spaceId: spaceId)
        }
    }

    /// Clear meeting session clusters on meeting close
    public func endMeeting(meetingId: String) {
        queue.async {
            self.sessionClusters.removeValue(forKey: meetingId)
        }
    }
}
