import Testing
import Foundation
import CryptoKit
import AVFoundation
@testable import SidebriefCore

@Suite("Audio Engine & Encryption Tests")
struct AudioEngineTests {

    @Test("Keychain Key Creation and Retrieval")
    func testKeychainKey() throws {
        let meetingId = "test-meeting-\(UUID().uuidString)"
        let manager = AudioKeychainManager.shared

        let key1 = try manager.getOrCreateKey(for: meetingId)
        let key2 = try manager.getOrCreateKey(for: meetingId)

        // Same meeting ID must yield the exact same symmetric key
        let data1 = key1.withUnsafeBytes { Data($0) }
        let data2 = key2.withUnsafeBytes { Data($0) }
        #expect(data1 == data2)

        manager.deleteKey(for: meetingId)
    }

    @Test("Encrypted Chunk Writing and Decryption Roundtrip")
    func testEncryptedChunkWriter() async throws {
        let meetingId = "test-meeting-\(UUID().uuidString)"
        let trackId = "track-mic-1"
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        let writer = try EncryptedChunkWriter(
            meetingId: meetingId,
            trackId: trackId,
            journalDirectory: tempDir,
            sampleRate: 48000.0,
            channelCount: 1,
            chunkDurationSeconds: 1.0 // 1 sec chunks for quick test = 48,000 samples
        )

        // Generate 1 second of 48kHz 16-bit PCM audio (48,000 samples = 96,000 bytes)
        var testPCM = Data(count: 96000)
        testPCM.withUnsafeMutableBytes { ptr in
            let samples = ptr.bindMemory(to: Int16.self).baseAddress!
            for i in 0..<48000 {
                // 440Hz sine wave tone
                let t = Double(i) / 48000.0
                samples[i] = Int16(sin(2.0 * .pi * 440.0 * t) * 16000.0)
            }
        }

        let chunk = try await writer.appendAudioData(testPCM, sampleCount: 48000)
        #expect(chunk != nil)
        guard let chunk = chunk else { return }

        #expect(chunk.sequenceNumber == 0)
        #expect(chunk.sampleCount == 48000)
        #expect(FileManager.default.fileExists(atPath: chunk.localEncryptedFilePath))

        // Decrypt the chunk and verify contents
        let key = try AudioKeychainManager.shared.getOrCreateKey(for: meetingId)
        let decryptedWav = try EncryptedChunkWriter.decryptChunk(chunk: chunk, key: key)

        // Decrypted WAV should be 44-byte header + 96,000 bytes PCM = 96,044 bytes
        #expect(decryptedWav.count == 96044)

        // Verify RIFF header
        let riffHeader = String(data: decryptedWav.prefix(4), encoding: .ascii)
        #expect(riffHeader == "RIFF")

        let waveHeader = String(data: decryptedWav.subdata(in: 8..<12), encoding: .ascii)
        #expect(waveHeader == "WAVE")

        // Verify PCM payload matches original
        let payload = decryptedWav.suffix(from: 44)
        #expect(payload == testPCM)

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
        AudioKeychainManager.shared.deleteKey(for: meetingId)
    }

    @Test("Audio Metering Accuracy")
    func testAudioMetering() {
        // Test silence: all zeros
        let silenceData = Data(count: 1000)
        let silenceMeter = AudioCaptureService.computeMeterFromPCM16(data: silenceData)
        #expect(silenceMeter.linearLevel == 0.0)
        #expect(silenceMeter.peakPower <= -60.0)

        // Test high amplitude: full scale square wave
        var loudData = Data(count: 2000)
        loudData.withUnsafeMutableBytes { ptr in
            let samples = ptr.bindMemory(to: Int16.self).baseAddress!
            for i in 0..<1000 {
                samples[i] = (i % 2 == 0) ? 30000 : -30000
            }
        }
        let loudMeter = AudioCaptureService.computeMeterFromPCM16(data: loudData)
        #expect(loudMeter.linearLevel > 0.8)
        #expect(loudMeter.peakPower > -5.0)
    }

    @Test("Crash Recovery and Sequence Gap Detection")
    func testCrashRecovery() async throws {
        let meetingId = "test-recovery-\(UUID().uuidString)"
        let trackId = "track-sys-1"
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        let writer = try EncryptedChunkWriter(
            meetingId: meetingId,
            trackId: trackId,
            journalDirectory: tempDir.appendingPathComponent("Sidebrief/Journal/\(meetingId)/\(trackId)", isDirectory: true),
            sampleRate: 48000.0,
            channelCount: 1,
            chunkDurationSeconds: 0.5
        )

        // Write 3 chunks
        let pcm = Data(count: 48000) // 0.5s = 24000 samples = 48000 bytes
        _ = try await writer.appendAudioData(pcm, sampleCount: 24000)
        _ = try await writer.appendAudioData(pcm, sampleCount: 24000)
        let chunk2 = try await writer.appendAudioData(pcm, sampleCount: 24000)
        #expect(chunk2?.sequenceNumber == 2)

        // Now simulate deleting chunk 1 to create an artificial gap on disk
        let chunks = await writer.getFinalizedChunks()
        #expect(chunks.count == 3)
        try FileManager.default.removeItem(atPath: chunks[1].localEncryptedFilePath)

        // Run recovery
        let (recovered, gaps) = try EncryptedChunkWriter.recoverChunks(
            for: meetingId,
            trackId: trackId,
            journalDirectory: tempDir
        )

        #expect(recovered.count == 2)
        #expect(gaps.contains(1))

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
        AudioKeychainManager.shared.deleteKey(for: meetingId)
    }

    @Test("Voiceprint Pitch Estimation and Gender Classification")
    func testVoiceprintPitchAndGender() {
        let sampleRate: Double = 16000.0
        let duration: Double = 1.0
        let sampleCount = Int(sampleRate * duration)

        // Generate synthetic Male voice (~120 Hz fundamental with harmonics)
        var malePCM = Data(count: sampleCount * 2)
        malePCM.withUnsafeMutableBytes { ptr in
            let samples = ptr.bindMemory(to: Int16.self).baseAddress!
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                let f0 = 120.0
                let s = sin(2.0 * .pi * f0 * t) * 12000.0 + sin(2.0 * .pi * 2.0 * f0 * t) * 6000.0
                samples[i] = Int16(max(-32767.0, min(32767.0, s)))
            }
        }

        let maleVP = VoiceprintEngine.extractVoiceprint(from: malePCM, sampleRate: sampleRate)
        #expect(maleVP != nil)
        if let vp = maleVP {
            #expect(vp.meanPitchHz > 95.0 && vp.meanPitchHz < 155.0)
            #expect(vp.estimatedGender == "Male")
            #expect(vp.pitchConfidence > 0.4)
        }

        // Generate synthetic Female voice (~220 Hz fundamental with harmonics)
        var femalePCM = Data(count: sampleCount * 2)
        femalePCM.withUnsafeMutableBytes { ptr in
            let samples = ptr.bindMemory(to: Int16.self).baseAddress!
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                let f0 = 220.0
                let s = sin(2.0 * .pi * f0 * t) * 12000.0 + sin(2.0 * .pi * 2.0 * f0 * t) * 6000.0
                samples[i] = Int16(max(-32767.0, min(32767.0, s)))
            }
        }

        let femaleVP = VoiceprintEngine.extractVoiceprint(from: femalePCM, sampleRate: sampleRate)
        #expect(femaleVP != nil)
        if let vp = femaleVP {
            #expect(vp.meanPitchHz > 175.0 && vp.meanPitchHz < 265.0)
            #expect(vp.estimatedGender == "Female")
            #expect(vp.pitchConfidence > 0.4)
        }

        // Similarity test: Male vs Male should be high, Male vs Female should be low
        if let m = maleVP, let f = femaleVP {
            let selfSim = VoiceprintEngine.similarity(between: m, and: m)
            let crossSim = VoiceprintEngine.similarity(between: m, and: f)
            #expect(selfSim > 0.95)
            #expect(crossSim < 0.75)
        }
    }

    @Test("Voiceprint WAV Sample Generation")
    func testVoiceprintWavGeneration() {
        let pcm = Data(count: 32000) // 1 second of 16kHz 16-bit mono
        let wav = VoiceprintEngine.createWavData(fromPCM16: pcm, sampleRate: 16000, channels: 1)
        #expect(wav.count == 32000 + 44)
        let riff = String(data: wav.prefix(4), encoding: .ascii)
        #expect(riff == "RIFF")
        let wave = String(data: wav.subdata(in: 8..<12), encoding: .ascii)
        #expect(wave == "WAVE")
    }

    @Test("Speaker Diarization Session Clustering and Enrolled Profile Matching")
    func testSpeakerDiarizationService() {
        let diarizer = SpeakerDiarizationService.shared
        let meetingId = "diarize-test-\(UUID().uuidString)"

        // Prepare synthetic Male audio (120 Hz)
        let sampleRate: Double = 16000.0
        var malePCM = Data(count: 16000 * 2)
        malePCM.withUnsafeMutableBytes { ptr in
            let samples = ptr.bindMemory(to: Int16.self).baseAddress!
            for i in 0..<16000 {
                let t = Double(i) / sampleRate
                samples[i] = Int16(sin(2.0 * .pi * 120.0 * t) * 12000.0)
            }
        }

        // First utterance: Unenrolled -> should be assigned "Speaker 1 (Male)"
        let label1 = diarizer.attributeSpeaker(meetingId: meetingId, isMic: false, pcmData: malePCM, sampleRate: sampleRate)
        #expect(label1.contains("Speaker 1") || label1.contains("Male"))

        // Second utterance with same voice characteristics -> should reuse same speaker label
        let label2 = diarizer.attributeSpeaker(meetingId: meetingId, isMic: false, pcmData: malePCM, sampleRate: sampleRate)
        #expect(label2 == label1)

        // Session speakers inspect
        let sessionSpeakers = diarizer.getSessionSpeakers(meetingId: meetingId)
        #expect(sessionSpeakers.count >= 1)
        #expect(sessionSpeakers.first?.voiceSampleWavData != nil)

        // Reset meeting
        diarizer.endMeeting(meetingId: meetingId)
    }

    @Test("Batch Renaming and Speaker Profile Voiceprint Storage Roundtrip")
    func testSpeakerProfileVoiceprintAndBatchRename() {
        let store = LocalDatabaseStore.shared
        let spaceId = "test-space-\(UUID().uuidString)"
        let profileId = "prof-\(UUID().uuidString)"

        let sampleVoiceprint = Voiceprint(
            meanPitchHz: 135.5,
            pitchConfidence: 0.85,
            spectralCentroidHz: 1250.0,
            subBandEnergies: [0.3, 0.25, 0.2, 0.15, 0.1],
            zeroCrossingRate: 0.08,
            sampleDurationSeconds: 1.0,
            estimatedGender: "Male"
        )
        let sampleWav = VoiceprintEngine.createWavData(fromPCM16: Data(count: 1000), sampleRate: 16000, channels: 1)

        let profile = SpeakerProfile(
            id: profileId,
            spaceId: spaceId,
            name: "Dr. Gregory House",
            roleOrTitle: "Head of Diagnostic Medicine",
            organization: "Princeton-Plainsboro",
            notesOrContext: "Speaks with a dry tone",
            aliases: ["House", "Greg"],
            voiceprint: sampleVoiceprint,
            genderEstimate: "Male",
            voiceSampleWavData: sampleWav
        )

        store.saveSpeakerProfile(profile)

        // Fetch back and verify round-trip
        let fetched = store.getSpeakerProfiles(spaceId: spaceId)
        let found = fetched.first { $0.id == profileId }
        #expect(found != nil)
        #expect(found?.name == "Dr. Gregory House")
        #expect(found?.genderEstimate == "Male")
        #expect(found?.voiceprint?.meanPitchHz == 135.5)
        #expect(found?.voiceSampleWavData?.count == sampleWav.count)

        // Clean up
        store.deleteSpeakerProfile(id: profileId)
    }

    @Test("Batch Speaker Renaming in Transcripts and Unique Speakers Query")
    func testTranscriptBatchRenaming() {
        let store = LocalDatabaseStore.shared
        let meetingId = "meet-batch-\(UUID().uuidString)"
        let spaceId = "space-batch-\(UUID().uuidString)"

        let meeting = Meeting(
            id: meetingId,
            spaceId: spaceId,
            title: "Batch Rename Test Meeting",
            state: .completed
        )
        store.saveMeeting(meeting)

        let seg1 = TranscriptSegment(
            id: UUID().uuidString,
            meetingId: meetingId,
            trackId: "track-mic",
            providerSegmentId: "prov-1",
            speakerLabel: "Speaker 1 (Male)",
            text: "Hello everyone, let us begin.",
            startOffsetMs: 0,
            endOffsetMs: 2500
        )
        let seg2 = TranscriptSegment(
            id: UUID().uuidString,
            meetingId: meetingId,
            trackId: "track-sys",
            providerSegmentId: "prov-2",
            speakerLabel: "Speaker 2 (Female)",
            text: "I am ready with the presentation.",
            startOffsetMs: 2600,
            endOffsetMs: 5000
        )
        let seg3 = TranscriptSegment(
            id: UUID().uuidString,
            meetingId: meetingId,
            trackId: "track-mic",
            providerSegmentId: "prov-3",
            speakerLabel: "Speaker 1 (Male)",
            text: "Great, please share your screen.",
            startOffsetMs: 5100,
            endOffsetMs: 7000
        )

        store.saveTranscriptSegments([seg1, seg2, seg3])

        let unique = store.getUniqueSpeakersInMeeting(meetingId: meetingId)
        #expect(unique.contains("Speaker 1 (Male)"))
        #expect(unique.contains("Speaker 2 (Female)"))
        #expect(unique.count == 2)

        // Perform batch renaming
        store.batchRenameSpeakersInTranscript(meetingId: meetingId, renames: [
            "Speaker 1 (Male)": "Alex Vance",
            "Speaker 2 (Female)": "Elena Rostova"
        ])

        // Verify segments updated
        let updatedSegments = store.getTranscriptSegments(meetingId: meetingId)
        let alexSegs = updatedSegments.filter { $0.speakerLabel == "Alex Vance" }
        let elenaSegs = updatedSegments.filter { $0.speakerLabel == "Elena Rostova" }
        #expect(alexSegs.count == 2)
        #expect(elenaSegs.count == 1)

        let updatedUnique = store.getUniqueSpeakersInMeeting(meetingId: meetingId)
        #expect(updatedUnique.contains("Alex Vance"))
        #expect(updatedUnique.contains("Elena Rostova"))
        #expect(!updatedUnique.contains("Speaker 1 (Male)"))
    }

    @Test("Speaker Diarization Provisional Attribution Does Not Inflate Total Seconds")
    func testSpeakerDurationAccurateNotInflated() {
        let diarization = SpeakerDiarizationService.shared
        let meetingId = "test-duration-\(UUID().uuidString)"

        // 130 Hz tone (Male pitch) for 0.2 seconds = 9600 samples
        let sampleRate = 48000.0
        let sampleCount = 9600
        var malePCM = Data(count: sampleCount * 2)
        malePCM.withUnsafeMutableBytes { ptr in
            let samples = ptr.bindMemory(to: Int16.self).baseAddress!
            for i in 0..<sampleCount {
                let t = Double(i) / sampleRate
                samples[i] = Int16(sin(2.0 * .pi * 130.0 * t) * 16000.0)
            }
        }

        // Simulate 10 streaming chunk arrivals with isFinal: false
        for _ in 0..<10 {
            let label = diarization.attributeSpeaker(
                meetingId: meetingId,
                isMic: false,
                pcmData: malePCM,
                sampleRate: sampleRate,
                isFinal: false
            )
            #expect(!label.isEmpty)
        }

        // Before any final commit, clusters should not have inflated counts or durations
        let provisionalSpeakers = diarization.getSessionSpeakers(meetingId: meetingId)
        let totalProvisionalDuration = provisionalSpeakers.reduce(0.0) { $0 + $1.totalDurationSeconds }
        let totalProvisionalSegments = provisionalSpeakers.reduce(0) { $0 + $1.segmentCount }
        #expect(totalProvisionalDuration == 0.0)
        #expect(totalProvisionalSegments == 0)

        // Now finalize one segment with exact duration: 3.5 seconds
        let finalLabel = diarization.attributeSpeaker(
            meetingId: meetingId,
            isMic: false,
            pcmData: malePCM,
            sampleRate: sampleRate,
            segmentDurationSeconds: 3.5,
            isFinal: true
        )
        #expect(!finalLabel.isEmpty)

        let committedSpeakers = diarization.getSessionSpeakers(meetingId: meetingId)
        #expect(committedSpeakers.count == 1)
        let speaker = committedSpeakers[0]
        #expect(speaker.segmentCount == 1)
        #expect(abs(speaker.totalDurationSeconds - 3.5) < 0.001)

        // Commit a second segment of 2.2 seconds
        _ = diarization.attributeSpeaker(
            meetingId: meetingId,
            isMic: false,
            pcmData: malePCM,
            sampleRate: sampleRate,
            segmentDurationSeconds: 2.2,
            isFinal: true
        )

        let afterSecondCommit = diarization.getSessionSpeakers(meetingId: meetingId)
        #expect(afterSecondCommit[0].segmentCount == 2)
        #expect(abs(afterSecondCommit[0].totalDurationSeconds - 5.7) < 0.001)

        diarization.endMeeting(meetingId: meetingId)
    }

    @Test("Speaker Voice Sample Quality Upgrade on Clear Voiced Speech")
    func testVoiceSampleQualityUpgrade() {
        let diarization = SpeakerDiarizationService.shared
        let meetingId = "test-sample-upgrade-\(UUID().uuidString)"
        let sampleRate = 48000.0

        // Short, weak signal (0.15 seconds = 7200 samples)
        let shortCount = 7200
        var weakPCM = Data(count: shortCount * 2)
        weakPCM.withUnsafeMutableBytes { ptr in
            let samples = ptr.bindMemory(to: Int16.self).baseAddress!
            for i in 0..<shortCount {
                let t = Double(i) / sampleRate
                samples[i] = Int16(sin(2.0 * .pi * 210.0 * t) * 4000.0) // quiet female tone
            }
        }

        // Commit first weak segment
        _ = diarization.attributeSpeaker(
            meetingId: meetingId,
            isMic: false,
            pcmData: weakPCM,
            sampleRate: sampleRate,
            segmentDurationSeconds: 0.15,
            isFinal: true
        )

        let speakers1 = diarization.getSessionSpeakers(meetingId: meetingId)
        #expect(speakers1.count == 1)
        let initialSampleLength = speakers1[0].voiceSampleWavData?.count ?? 0

        // Now provide high-energy, 2.5-second clear voiced speech (120,000 samples)
        let longCount = 120000
        var clearPCM = Data(count: longCount * 2)
        clearPCM.withUnsafeMutableBytes { ptr in
            let samples = ptr.bindMemory(to: Int16.self).baseAddress!
            for i in 0..<longCount {
                let t = Double(i) / sampleRate
                samples[i] = Int16(sin(2.0 * .pi * 210.0 * t) * 20000.0) // loud clear female tone
            }
        }

        _ = diarization.attributeSpeaker(
            meetingId: meetingId,
            isMic: false,
            pcmData: clearPCM,
            sampleRate: sampleRate,
            segmentDurationSeconds: 2.5,
            isFinal: true
        )

        let speakers2 = diarization.getSessionSpeakers(meetingId: meetingId)
        #expect(speakers2.count == 1)
        let upgradedSample = speakers2[0].voiceSampleWavData
        #expect(upgradedSample != nil)
        let upgradedSampleLength = upgradedSample?.count ?? 0
        // Upgraded sample should be larger, containing full 2.5s voiced audio
        #expect(upgradedSampleLength > initialSampleLength)

        diarization.endMeeting(meetingId: meetingId)
    }

    @Test("FullAudioRecordingStore Consolidates Multi-Track Encrypted Chunks into Master Stereo WAV")
    func testFullAudioRecordingStoreConsolidation() async throws {
        let meetingId = "test-consolidation-\(UUID().uuidString)"
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tempRecordingsDir = tempDir.appendingPathComponent("Recordings", isDirectory: true)

        let store = FullAudioRecordingStore(customRecordingsDirectory: tempRecordingsDir)

        // 1. Create a mic chunk (440Hz tone, 1 sec)
        let micWriter = try EncryptedChunkWriter(
            meetingId: meetingId,
            trackId: "track-mic-1",
            journalDirectory: tempDir,
            sampleRate: 48000.0,
            channelCount: 1,
            chunkDurationSeconds: 1.0
        )
        let sampleRate = 48000.0
        var micPCM = Data(count: 48000 * 2)
        micPCM.withUnsafeMutableBytes { ptr in
            let s = ptr.bindMemory(to: Int16.self).baseAddress!
            for i in 0..<48000 {
                let t = Double(i) / sampleRate
                s[i] = Int16(sin(2.0 * .pi * 440.0 * t) * 16000.0)
            }
        }
        let micChunk = try await micWriter.appendAudioData(micPCM, sampleCount: 48000)!

        // 2. Create a system chunk (880Hz tone, 1 sec starting at offset 1000ms)
        let sysWriter = try EncryptedChunkWriter(
            meetingId: meetingId,
            trackId: "track-sys-1",
            journalDirectory: tempDir,
            sampleRate: 48000.0,
            channelCount: 1,
            chunkDurationSeconds: 1.0,
            streamEpoch: micChunk.streamEpoch + 1000
        )
        var sysPCM = Data(count: 48000 * 2)
        sysPCM.withUnsafeMutableBytes { ptr in
            let s = ptr.bindMemory(to: Int16.self).baseAddress!
            for i in 0..<48000 {
                let t = Double(i) / sampleRate
                s[i] = Int16(sin(2.0 * .pi * 880.0 * t) * 16000.0)
            }
        }
        let sysChunk = try await sysWriter.appendAudioData(sysPCM, sampleCount: 48000)!

        // 3. Consolidate into full master audio recording
        let masterURL = try await store.consolidateRecording(
            for: meetingId,
            chunks: [micChunk, sysChunk]
        )

        #expect(FileManager.default.fileExists(atPath: masterURL.path))
        #expect(store.hasRecording(for: meetingId))

        // 4. Verify decoded audio file properties via AVFoundation
        let audioFile = try AVAudioFile(forReading: masterURL)
        #expect(audioFile.fileFormat.sampleRate == 48000.0)
        #expect(audioFile.fileFormat.channelCount == 2) // Stereo
        #expect(audioFile.length >= 48000)

        // 5. Test getFullAudioData
        let wavData = try await store.getFullAudioData(for: meetingId)
        #expect(wavData.count > 44)
        #expect(String(data: wavData.prefix(4), encoding: .ascii) == "RIFF")

        // 6. Test delete
        store.deleteRecording(for: meetingId)
        #expect(!store.hasRecording(for: meetingId))

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
        AudioKeychainManager.shared.deleteKey(for: meetingId)
    }

    @Test("AudioPlaybackEngine Loads Master Audio and Responds to Seek")
    func testAudioPlaybackEngineMasterAudio() async throws {
        let meetingId = "test-playback-\(UUID().uuidString)"
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tempRecordingsDir = tempDir.appendingPathComponent("Recordings", isDirectory: true)

        let store = FullAudioRecordingStore(customRecordingsDirectory: tempRecordingsDir)

        // Create 2 seconds of audio
        let micWriter = try EncryptedChunkWriter(
            meetingId: meetingId,
            trackId: "track-mic-1",
            journalDirectory: tempDir,
            sampleRate: 48000.0,
            channelCount: 1,
            chunkDurationSeconds: 2.0
        )
        var pcm = Data(count: 96000 * 2)
        pcm.withUnsafeMutableBytes { ptr in
            let s = ptr.bindMemory(to: Int16.self).baseAddress!
            for i in 0..<96000 {
                s[i] = Int16(sin(Double(i) * 0.05) * 10000.0)
            }
        }
        let chunk = try await micWriter.appendAudioData(pcm, sampleCount: 96000)!
        let masterURL = try await store.consolidateRecording(for: meetingId, chunks: [chunk])

        let playbackEngine = AudioPlaybackEngine()
        playbackEngine.loadMeeting(
            meetingId: meetingId,
            micChunks: [chunk],
            systemChunks: [],
            masterAudioURL: masterURL
        )

        #expect(playbackEngine.state == .stopped)

        // Test seek
        try playbackEngine.seek(to: 500)
        #expect(playbackEngine.state == .stopped)

        playbackEngine.stop()

        // Cleanup
        store.deleteRecording(for: meetingId)
        try? FileManager.default.removeItem(at: tempDir)
        AudioKeychainManager.shared.deleteKey(for: meetingId)
    }
}
