import Foundation
import CryptoKit
import AVFoundation

/// Storage manager for full consolidated master meeting audio recordings.
/// Decrypts and stitches together 2-second encrypted capture chunks into a unified,
/// gap-filled, time-aligned stereo master WAV recording file for playback and export.
public final class FullAudioRecordingStore: @unchecked Sendable {
    public static let shared = FullAudioRecordingStore()

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.sidebrief.audio.fullstore", qos: .userInitiated)

    public let recordingsDirectory: URL

    public init(customRecordingsDirectory: URL? = nil) {
        if let custom = customRecordingsDirectory {
            self.recordingsDirectory = custom
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.recordingsDirectory = appSupport.appendingPathComponent("Sidebrief/Recordings", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.recordingsDirectory, withIntermediateDirectories: true)
    }

    /// URL for a meeting's master consolidated audio recording (.wav)
    public func recordingURL(for meetingId: String) -> URL {
        return recordingsDirectory.appendingPathComponent("\(meetingId)_master.wav")
    }

    /// Check if a consolidated master audio recording already exists for this meeting
    public func hasRecording(for meetingId: String) -> Bool {
        let url = recordingURL(for: meetingId)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let attributes = (try? fileManager.attributesOfItem(atPath: url.path)) ?? [:]
        let size = attributes[.size] as? Int64 ?? 0
        return size > 44 // Must have valid WAV header and audio data
    }

    /// Consolidates encrypted microphone and system audio chunks into a single master audio recording.
    /// - Parameters:
    ///   - meetingId: The meeting ID.
    ///   - chunks: Optional array of audio chunks (if omitted, queries LocalDatabaseStore).
    ///   - forceRebuild: If true, re-assembles even if file already exists.
    /// - Returns: URL of the consolidated master WAV file.
    @discardableResult
    public func consolidateRecording(
        for meetingId: String,
        chunks: [AudioChunk]? = nil,
        forceRebuild: Bool = false
    ) async throws -> URL {
        let targetURL = recordingURL(for: meetingId)

        if !forceRebuild && hasRecording(for: meetingId) {
            return targetURL
        }

        let audioChunks = chunks ?? LocalDatabaseStore.shared.getAudioChunks(meetingId: meetingId)
        guard !audioChunks.isEmpty else {
            throw NSError(
                domain: "FullAudioRecordingStore",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No audio chunks available to consolidate for meeting \(meetingId)"]
            )
        }

        let key = try AudioKeychainManager.shared.getOrCreateKey(for: meetingId)

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let url = try self.buildMasterAudioFile(
                        meetingId: meetingId,
                        chunks: audioChunks,
                        key: key,
                        targetURL: targetURL
                    )
                    continuation.resume(returning: url)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Reads and returns the raw WAV data of the consolidated meeting audio.
    public func getFullAudioData(for meetingId: String) async throws -> Data {
        let url = try await consolidateRecording(for: meetingId)
        return try Data(contentsOf: url)
    }

    /// Deletes the master recording from disk when a meeting is deleted
    public func deleteRecording(for meetingId: String) {
        let url = recordingURL(for: meetingId)
        try? fileManager.removeItem(at: url)
    }

    // MARK: - Private Stitching and Audio Mixing Engine

    private func buildMasterAudioFile(
        meetingId: String,
        chunks: [AudioChunk],
        key: SymmetricKey,
        targetURL: URL
    ) throws -> URL {
        let sampleRate = 48000
        let bytesPerSample = 2 // Int16
        let channels = 2 // Stereo output: Left = Mic/User, Right = System/Remote

        // Determine total recording duration from chunks
        let maxEndMs = chunks.map { $0.endOffsetMs }.max() ?? 1000
        let totalFrames = max(sampleRate, Int(Double(maxEndMs) / 1000.0 * Double(sampleRate)))
        let totalBytes = totalFrames * channels * bytesPerSample

        // Allocate zeroed PCM buffer (gap-filled silence)
        var mixedPCM = Data(count: totalBytes)

        // Classify chunks by track (Microphone vs System Audio)
        // Detect mic track by ID or convention
        var micChunks: [AudioChunk] = []
        var sysChunks: [AudioChunk] = []

        for chunk in chunks {
            if chunk.trackId.lowercased().contains("mic") {
                micChunks.append(chunk)
            } else if chunk.trackId.lowercased().contains("sys") {
                sysChunks.append(chunk)
            } else if micChunks.isEmpty {
                micChunks.append(chunk)
            } else {
                sysChunks.append(chunk)
            }
        }

        let hasMic = !micChunks.isEmpty
        let hasSys = !sysChunks.isEmpty

        mixedPCM.withUnsafeMutableBytes { (rawBuffer: UnsafeMutableRawBufferPointer) in
            guard let int16OutPtr = rawBuffer.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }

            // 1. Process Microphone Chunks
            for chunk in micChunks {
                guard let decryptedWav = try? EncryptedChunkWriter.decryptChunk(chunk: chunk, key: key),
                      decryptedWav.count > 44 else { continue }

                let pcmBytes = decryptedWav.subdata(in: 44..<decryptedWav.count)
                let sampleCount = pcmBytes.count / bytesPerSample
                let startFrame = Int(Double(chunk.startOffsetMs) / 1000.0 * Double(sampleRate))

                pcmBytes.withUnsafeBytes { (chunkRaw: UnsafeRawBufferPointer) in
                    guard let chunkPtr = chunkRaw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }

                    for i in 0..<sampleCount {
                        let frame = startFrame + i
                        guard frame < totalFrames else { break }

                        let sample = chunkPtr[i]
                        if !hasSys {
                            // Solo microphone recording: write to both stereo channels (centered)
                            int16OutPtr[frame * 2] = sample
                            int16OutPtr[frame * 2 + 1] = sample
                        } else {
                            // Dual track: write to Left channel (User) + subtle 15% bleed to Right for natural headphone acoustics
                            let leftIndex = frame * 2
                            let rightIndex = frame * 2 + 1
                            int16OutPtr[leftIndex] = sample
                            let existingRight = Int32(int16OutPtr[rightIndex])
                            let bledRight = existingRight + (Int32(sample) * 15 / 100)
                            int16OutPtr[rightIndex] = Int16(clamping: bledRight)
                        }
                    }
                }
            }

            // 2. Process System Audio Chunks
            for chunk in sysChunks {
                guard let decryptedWav = try? EncryptedChunkWriter.decryptChunk(chunk: chunk, key: key),
                      decryptedWav.count > 44 else { continue }

                let pcmBytes = decryptedWav.subdata(in: 44..<decryptedWav.count)
                let sampleCount = pcmBytes.count / bytesPerSample
                let startFrame = Int(Double(chunk.startOffsetMs) / 1000.0 * Double(sampleRate))

                pcmBytes.withUnsafeBytes { (chunkRaw: UnsafeRawBufferPointer) in
                    guard let chunkPtr = chunkRaw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }

                    for i in 0..<sampleCount {
                        let frame = startFrame + i
                        guard frame < totalFrames else { break }

                        let sample = chunkPtr[i]
                        if !hasMic {
                            // Solo system recording: write to both stereo channels (centered)
                            int16OutPtr[frame * 2] = sample
                            int16OutPtr[frame * 2 + 1] = sample
                        } else {
                            // Dual track: write to Right channel (Remote) + subtle 15% bleed to Left for natural headphone acoustics
                            let leftIndex = frame * 2
                            let rightIndex = frame * 2 + 1

                            let existingLeft = Int32(int16OutPtr[leftIndex])
                            let bledLeft = existingLeft + (Int32(sample) * 15 / 100)
                            int16OutPtr[leftIndex] = Int16(clamping: bledLeft)

                            let existingRight = Int32(int16OutPtr[rightIndex])
                            let combinedRight = existingRight + Int32(sample)
                            int16OutPtr[rightIndex] = Int16(clamping: combinedRight)
                        }
                    }
                }
            }
        }

        // 3. Wrap in RIFF WAV Container
        let wavHeaderAndData = EncryptedChunkWriter.createWavData(
            fromPCM: mixedPCM,
            sampleRate: sampleRate,
            channelCount: channels
        )

        try wavHeaderAndData.write(to: targetURL, options: .atomic)
        LocalDatabaseStore.shared.updateMeetingMasterAudioPath(meetingId: meetingId, path: targetURL.path)
        return targetURL
    }
}
