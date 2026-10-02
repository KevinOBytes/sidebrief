import Foundation
import CryptoKit
import AVFoundation

public actor EncryptedChunkWriter {
    public struct ChunkMetadata: Codable, Sendable {
        public let chunkId: String
        public let meetingId: String
        public let trackId: String
        public let sequenceNumber: Int
        public let streamEpoch: Int64
        public let startOffsetMs: Int64
        public let endOffsetMs: Int64
        public let sampleCount: Int
        public let byteCount: Int
        public let checksumSha256: String
        public let nonceHex: String
        public let encryptedFileName: String
        public let timestamp: Date
    }

    private let meetingId: String
    private let trackId: String
    private let journalDirectory: URL
    private let sampleRate: Double
    private let channelCount: Int
    private let chunkDurationSeconds: Double

    private var sequenceNumber: Int = 0
    private var streamEpoch: Int64
    private var currentAccumulator = Data()
    private var currentChunkStartSample: Int64 = 0
    private var totalSamplesRecorded: Int64 = 0
    private var key: SymmetricKey

    private var finalizedChunks: [AudioChunk] = []

    public init(
        meetingId: String,
        trackId: String,
        journalDirectory: URL? = nil,
        sampleRate: Double = 48000.0,
        channelCount: Int = 1,
        chunkDurationSeconds: Double = 2.0,
        streamEpoch: Int64? = nil
    ) throws {
        self.meetingId = meetingId
        self.trackId = trackId
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.chunkDurationSeconds = chunkDurationSeconds
        self.streamEpoch = streamEpoch ?? Int64(Date().timeIntervalSince1970 * 1000)

        let baseDir = journalDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Sidebrief/Journal/\(meetingId)/\(trackId)", isDirectory: true)
        self.journalDirectory = baseDir

        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        self.key = try AudioKeychainManager.shared.getOrCreateKey(for: meetingId)
    }

    /// Appends raw 16-bit PCM mono/stereo audio data from capture callback.
    public func appendAudioData(_ pcmData: Data, sampleCount: Int) throws -> AudioChunk? {
        currentAccumulator.append(pcmData)
        totalSamplesRecorded += Int64(sampleCount)

        let targetSamplesPerChunk = Int(sampleRate * chunkDurationSeconds)
        let bytesPerSample = 2 * channelCount // 16-bit = 2 bytes per channel
        let targetBytesPerChunk = targetSamplesPerChunk * bytesPerSample

        if currentAccumulator.count >= targetBytesPerChunk {
            return try finalizeCurrentChunk()
        }
        return nil
    }

    /// Flushes any remaining audio samples and finalizes the last chunk.
    public func flush() throws -> AudioChunk? {
        guard !currentAccumulator.isEmpty else { return nil }
        return try finalizeCurrentChunk()
    }

    private func finalizeCurrentChunk() throws -> AudioChunk {
        let pcmData = currentAccumulator
        currentAccumulator = Data()

        let bytesPerSample = 2 * channelCount
        let sampleCount = pcmData.count / bytesPerSample
        let startMs = Int64(Double(currentChunkStartSample) / sampleRate * 1000.0)
        let endMs = Int64(Double(currentChunkStartSample + Int64(sampleCount)) / sampleRate * 1000.0)
        currentChunkStartSample += Int64(sampleCount)

        // Prepend valid 44-byte WAV header so each finalized chunk is independently decodable
        let wavData = Self.createWavData(fromPCM: pcmData, sampleRate: Int(sampleRate), channelCount: channelCount)

        // Generate unique AES-GCM nonce (12 bytes)
        let nonce = AES.GCM.Nonce()
        let nonceHex = nonce.withUnsafeBytes { $0.map { String(format: "%02hhx", $0) }.joined() }

        // Encrypt with AES-GCM authenticated encryption
        let sealedBox = try AES.GCM.seal(wavData, using: key, nonce: nonce)
        guard let combinedEncryptedData = sealedBox.combined else {
            throw NSError(domain: "SidebriefAudio", code: 101, userInfo: [NSLocalizedDescriptionKey: "Failed to create AES-GCM sealed box"])
        }

        // Compute SHA-256 checksum
        let sha256Digest = SHA256.hash(data: combinedEncryptedData)
        let checksumHex = sha256Digest.map { String(format: "%02hhx", $0) }.joined()

        let chunkId = UUID().uuidString
        let fileName = String(format: "chunk_%06d_%@.enc", sequenceNumber, chunkId)
        let fileURL = journalDirectory.appendingPathComponent(fileName)

        try combinedEncryptedData.write(to: fileURL, options: .atomic)

        let chunk = AudioChunk(
            id: chunkId,
            trackId: trackId,
            meetingId: meetingId,
            sequenceNumber: sequenceNumber,
            streamEpoch: streamEpoch,
            startOffsetMs: startMs,
            endOffsetMs: endMs,
            sampleCount: sampleCount,
            byteCount: combinedEncryptedData.count,
            checksumSha256: checksumHex,
            encryptionKeyVersion: 1,
            encryptionNonceHex: nonceHex,
            localEncryptedFilePath: fileURL.path,
            remoteObjectKey: nil,
            uploadState: .localOnly,
            createdAt: Date()
        )

        sequenceNumber += 1
        finalizedChunks.append(chunk)
        try updateManifest()

        return chunk
    }

    private func updateManifest() throws {
        let manifestURL = journalDirectory.appendingPathComponent("manifest.json")
        let data = try JSONEncoder().encode(finalizedChunks)
        try data.write(to: manifestURL, options: .atomic)
    }

    public func getFinalizedChunks() -> [AudioChunk] {
        return finalizedChunks
    }

    /// Crash recovery: loads existing manifest and validates files on disk, detecting any sequence gaps.
    public static func recoverChunks(for meetingId: String, trackId: String, journalDirectory: URL) throws -> (recovered: [AudioChunk], gaps: [Int]) {
        let dir = journalDirectory.appendingPathComponent("Sidebrief/Journal/\(meetingId)/\(trackId)")
        let manifestURL = dir.appendingPathComponent("manifest.json")

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return ([], [])
        }

        let data = try Data(contentsOf: manifestURL)
        let chunks = try JSONDecoder().decode([AudioChunk].self, from: data)

        // Validate chunks exist on disk and identify sequence gaps
        var validChunks: [AudioChunk] = []
        var gaps: [Int] = []
        var expectedSeq = 0

        for chunk in chunks.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) {
            while expectedSeq < chunk.sequenceNumber {
                gaps.append(expectedSeq)
                expectedSeq += 1
            }

            if FileManager.default.fileExists(atPath: chunk.localEncryptedFilePath) {
                validChunks.append(chunk)
            } else {
                gaps.append(chunk.sequenceNumber)
            }
            expectedSeq = chunk.sequenceNumber + 1
        }

        return (validChunks, gaps)
    }

    /// Decrypts a chunk file and returns the plaintext WAV audio data.
    public static func decryptChunk(chunk: AudioChunk, key: SymmetricKey) throws -> Data {
        let fileURL = URL(fileURLWithPath: chunk.localEncryptedFilePath)
        let encryptedData = try Data(contentsOf: fileURL)

        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        let decryptedWav = try AES.GCM.open(sealedBox, using: key)
        return decryptedWav
    }

    /// Creates a 44-byte standard RIFF WAV header for 16-bit LPCM.
    public static func createWavData(fromPCM pcmData: Data, sampleRate: Int, channelCount: Int) -> Data {
        var data = Data()
        let totalDataLen = pcmData.count
        let totalAudioLen = totalDataLen + 36
        let byteRate = sampleRate * channelCount * 2
        let blockAlign = channelCount * 2

        // "RIFF" chunk
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        data.append(contentsOf: withUnsafeBytes(of: UInt32(totalAudioLen).littleEndian) { Array($0) })
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // "fmt " chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // Subchunk1Size (16 for PCM)
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // AudioFormat (1 for PCM)
        data.append(contentsOf: withUnsafeBytes(of: UInt16(channelCount).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }) // BitsPerSample (16)

        // "data" chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        data.append(contentsOf: withUnsafeBytes(of: UInt32(totalDataLen).littleEndian) { Array($0) })
        data.append(pcmData)

        return data
    }
}
