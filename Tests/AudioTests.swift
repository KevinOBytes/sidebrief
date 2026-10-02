import Testing
import Foundation
import CryptoKit
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
}
