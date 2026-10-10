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

    /// Identify or attribute a speaker label for a finalized audio segment.
    /// - Parameters:
    ///   - meetingId: The active meeting ID.
    ///   - isMic: True if recorded from local microphone ("You"), false if remote system audio.
    ///   - pcmData: Raw 16-bit PCM audio buffer.
    ///   - sampleRate: Audio sample rate (e.g. 48000 or 16000).
    ///   - spaceId: Optional active context space ID.
    /// - Returns: Attributed speaker label (e.g. "You", "Sarah", "Speaker 1 (Male)", "Speaker 2 (Female)").
    public func attributeSpeaker(
        meetingId: String,
        isMic: Bool,
        pcmData: Data,
        sampleRate: Double = 48000.0,
        spaceId: String? = nil
    ) -> String {
        if isMic {
            let userName = UserDefaults.standard.string(forKey: "sidebrief_user_name") ?? "You"
            let finalName = userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "You" : userName

            // Extract and register the local user's own voiceprint sample if not yet captured
            queue.sync {
                var clusters = self.sessionClusters[meetingId] ?? []
                if !clusters.contains(where: { $0.assignedLabel == finalName }) {
                    if let vp = VoiceprintEngine.extractVoiceprint(from: pcmData, sampleRate: sampleRate) {
                        let wav = VoiceprintEngine.createVoicedSampleWav(from: pcmData, sourceSampleRate: sampleRate)
                        let userSpeaker = SessionSpeaker(
                            assignedLabel: finalName,
                            originalClusterLabel: finalName,
                            genderEstimate: vp.estimatedGender,
                            meanPitchHz: vp.meanPitchHz,
                            voiceprint: vp,
                            voiceSampleWavData: wav,
                            segmentCount: 1,
                            totalDurationSeconds: vp.sampleDurationSeconds,
                            isEnrolled: true
                        )
                        clusters.insert(userSpeaker, at: 0)
                        self.sessionClusters[meetingId] = clusters
                    }
                }
            }
            return finalName
        }

        // Remote participant speech analysis
        guard let voiceprint = VoiceprintEngine.extractVoiceprint(from: pcmData, sampleRate: sampleRate) else {
            // Audio too short or unvoiced: fallback to generic or last remote speaker
            return queue.sync {
                let clusters = self.sessionClusters[meetingId] ?? []
                let firstRemote = clusters.first(where: { $0.assignedLabel != "You" })
                return firstRemote?.assignedLabel ?? "Speaker 1"
            }
        }

        return queue.sync {
            var clusters = self.sessionClusters[meetingId] ?? []

            // 1. Check against Enrolled Known Speaker Profiles (Historical Voiceprints)
            var bestProfileMatch: (SpeakerProfile, Double)? = nil
            for profile in self.knownProfiles {
                guard let enrolledVp = profile.voiceprint else { continue }
                let score = VoiceprintEngine.similarity(between: voiceprint, and: enrolledVp)
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
                // Matched a known enrolled speaker!
                if let clusterIndex = clusters.firstIndex(where: { $0.assignedLabel == matchedProfile.name }) {
                    clusters[clusterIndex].segmentCount += 1
                    clusters[clusterIndex].totalDurationSeconds += voiceprint.sampleDurationSeconds
                } else {
                    let sampleWav = VoiceprintEngine.createVoicedSampleWav(from: pcmData, sourceSampleRate: sampleRate) ?? matchedProfile.voiceSampleWavData
                    let enrolledCluster = SessionSpeaker(
                        assignedLabel: matchedProfile.name,
                        originalClusterLabel: matchedProfile.name,
                        genderEstimate: matchedProfile.genderEstimate ?? voiceprint.estimatedGender,
                        meanPitchHz: voiceprint.meanPitchHz > 0 ? voiceprint.meanPitchHz : (matchedProfile.voiceprint?.meanPitchHz ?? 0),
                        voiceprint: voiceprint,
                        voiceSampleWavData: sampleWav,
                        segmentCount: 1,
                        totalDurationSeconds: voiceprint.sampleDurationSeconds,
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
                guard cluster.assignedLabel != "You", let clusterVp = cluster.voiceprint else { continue }
                let score = VoiceprintEngine.similarity(between: voiceprint, and: clusterVp)
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
                // Belongs to an existing session speaker
                clusters[matchIdx].segmentCount += 1
                clusters[matchIdx].totalDurationSeconds += voiceprint.sampleDurationSeconds
                if clusters[matchIdx].voiceSampleWavData == nil {
                    clusters[matchIdx].voiceSampleWavData = VoiceprintEngine.createVoicedSampleWav(from: pcmData, sourceSampleRate: sampleRate)
                }
                self.sessionClusters[meetingId] = clusters
                return clusters[matchIdx].assignedLabel
            }

            // 3. New Distinct Remote Speaker Detected
            let remoteClusters = clusters.filter { $0.assignedLabel != "You" }
            let nextIndex = remoteClusters.count + 1
            let gender = voiceprint.estimatedGender

            // Name format: "Speaker 1 (Male)", "Speaker 2 (Female)", etc.
            let generatedLabel: String
            if gender == "Speaker" {
                generatedLabel = "Speaker \(nextIndex)"
            } else {
                generatedLabel = "Speaker \(nextIndex) (\(gender))"
            }

            let sampleWav = VoiceprintEngine.createVoicedSampleWav(from: pcmData, sourceSampleRate: sampleRate)
            let newSpeaker = SessionSpeaker(
                assignedLabel: generatedLabel,
                originalClusterLabel: generatedLabel,
                genderEstimate: gender,
                meanPitchHz: voiceprint.meanPitchHz,
                voiceprint: voiceprint,
                voiceSampleWavData: sampleWav,
                segmentCount: 1,
                totalDurationSeconds: voiceprint.sampleDurationSeconds,
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
