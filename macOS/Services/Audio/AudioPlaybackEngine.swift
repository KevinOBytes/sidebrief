import Foundation
import AVFoundation
import CryptoKit

public enum PlaybackState: Sendable {
    case stopped
    case playing
    case paused
}

public protocol AudioPlaybackEngineDelegate: AnyObject, Sendable {
    func audioPlaybackEngine(_ engine: AudioPlaybackEngine, didUpdateOffsetMs offsetMs: Int64)
    func audioPlaybackEngine(_ engine: AudioPlaybackEngine, didChangeState state: PlaybackState)
}

public final class AudioPlaybackEngine: @unchecked Sendable {
    public private(set) var state: PlaybackState = .stopped
    public weak var delegate: AudioPlaybackEngineDelegate?

    public var micVolume: Float = 1.0 {
        didSet { micPlayerNode.volume = isMicMuted ? 0.0 : micVolume }
    }
    public var systemVolume: Float = 1.0 {
        didSet { systemPlayerNode.volume = isSystemMuted ? 0.0 : systemVolume }
    }
    public var isMicMuted: Bool = false {
        didSet { micPlayerNode.volume = isMicMuted ? 0.0 : micVolume }
    }
    public var isSystemMuted: Bool = false {
        didSet { systemPlayerNode.volume = isSystemMuted ? 0.0 : systemVolume }
    }

    private let audioEngine = AVAudioEngine()
    private let micPlayerNode = AVAudioPlayerNode()
    private let systemPlayerNode = AVAudioPlayerNode()
    private let mixerNode = AVAudioMixerNode()

    private var meetingId: String?
    private var micChunks: [AudioChunk] = []
    private var systemChunks: [AudioChunk] = []
    private var currentPositionMs: Int64 = 0
    private var totalDurationMs: Int64 = 0

    private var masterAudioFile: AVAudioFile?
    private var masterAudioURL: URL?

    private var timer: Timer?
    private let lock = NSLock()

    public init() {
        audioEngine.attach(micPlayerNode)
        audioEngine.attach(systemPlayerNode)
        audioEngine.attach(mixerNode)

        let format = AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 2)!
        audioEngine.connect(micPlayerNode, to: mixerNode, format: format)
        audioEngine.connect(systemPlayerNode, to: mixerNode, format: format)
        audioEngine.connect(mixerNode, to: audioEngine.mainMixerNode, format: format)
    }

    /// Load a meeting for playback, configuring master audio or individual chunks.
    public func loadMeeting(
        meetingId: String,
        micChunks: [AudioChunk] = [],
        systemChunks: [AudioChunk] = [],
        masterAudioURL: URL? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }

        self.meetingId = meetingId
        self.micChunks = micChunks.sorted(by: { $0.startOffsetMs < $1.startOffsetMs })
        self.systemChunks = systemChunks.sorted(by: { $0.startOffsetMs < $1.startOffsetMs })
        self.currentPositionMs = 0

        // Reset player nodes
        micPlayerNode.stop()
        systemPlayerNode.stop()
        state = .stopped

        let candidateURL = masterAudioURL ?? FullAudioRecordingStore.shared.recordingURL(for: meetingId)
        if FileManager.default.fileExists(atPath: candidateURL.path),
           let file = try? AVAudioFile(forReading: candidateURL) {
            self.masterAudioURL = candidateURL
            self.masterAudioFile = file
            let durationSeconds = Double(file.length) / file.fileFormat.sampleRate
            self.totalDurationMs = Int64(durationSeconds * 1000.0)
        } else {
            self.masterAudioURL = nil
            self.masterAudioFile = nil
            let all = micChunks + systemChunks
            self.totalDurationMs = all.map { $0.endOffsetMs }.max() ?? 0
        }
    }

    /// Plays audio from the current position or resumes if paused.
    public func play() throws {
        lock.lock()
        defer { lock.unlock() }

        guard state != .playing else { return }

        if !audioEngine.isRunning {
            try audioEngine.start()
        }

        if let audioFile = masterAudioFile {
            if state == .stopped {
                systemPlayerNode.stop()
                systemPlayerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        if self.state == .playing {
                            self.stop()
                        }
                    }
                }
            }
            systemPlayerNode.play()
        } else {
            if state == .stopped {
                scheduleChunksFromOffset(currentPositionMs)
            }
            micPlayerNode.play()
            systemPlayerNode.play()
        }

        state = .playing

        DispatchQueue.main.async {
            self.startProgressTimer()
            self.delegate?.audioPlaybackEngine(self, didChangeState: .playing)
        }
    }

    public func pause() {
        lock.lock()
        defer { lock.unlock() }

        guard state == .playing else { return }

        micPlayerNode.pause()
        systemPlayerNode.pause()
        state = .paused

        DispatchQueue.main.async {
            self.stopProgressTimer()
            self.delegate?.audioPlaybackEngine(self, didChangeState: .paused)
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        micPlayerNode.stop()
        systemPlayerNode.stop()
        state = .stopped
        currentPositionMs = 0

        DispatchQueue.main.async {
            self.stopProgressTimer()
            self.delegate?.audioPlaybackEngine(self, didChangeState: .stopped)
            self.delegate?.audioPlaybackEngine(self, didUpdateOffsetMs: 0)
        }
    }

    /// Seeks playback to a specific offset in milliseconds (e.g. from clicking a transcript segment).
    public func seek(to offsetMs: Int64) throws {
        lock.lock()
        defer { lock.unlock() }

        let wasPlaying = (state == .playing)
        micPlayerNode.stop()
        systemPlayerNode.stop()

        currentPositionMs = max(0, offsetMs)

        if let audioFile = masterAudioFile {
            let sampleRate = audioFile.fileFormat.sampleRate
            let startFrame = AVAudioFramePosition(Double(currentPositionMs) / 1000.0 * sampleRate)
            if startFrame < audioFile.length {
                let frameCount = AVAudioFrameCount(audioFile.length - startFrame)
                systemPlayerNode.scheduleSegment(audioFile, startingFrame: startFrame, frameCount: frameCount, at: nil) { [weak self] in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        if self.state == .playing {
                            self.stop()
                        }
                    }
                }
            }
        } else {
            scheduleChunksFromOffset(currentPositionMs)
        }

        if wasPlaying {
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
            if masterAudioFile != nil {
                systemPlayerNode.play()
            } else {
                micPlayerNode.play()
                systemPlayerNode.play()
            }
            state = .playing
        }

        DispatchQueue.main.async {
            self.delegate?.audioPlaybackEngine(self, didUpdateOffsetMs: self.currentPositionMs)
        }
    }

    // MARK: - Private Helpers

    private func scheduleChunksFromOffset(_ offsetMs: Int64) {
        guard let mId = meetingId, let key = try? AudioKeychainManager.shared.getOrCreateKey(for: mId) else { return }

        // Schedule mic chunks
        for chunk in micChunks where chunk.endOffsetMs > offsetMs {
            if let wavData = try? EncryptedChunkWriter.decryptChunk(chunk: chunk, key: key) {
                scheduleWavDataInMemory(wavData, on: micPlayerNode)
            }
        }

        // Schedule system chunks
        for chunk in systemChunks where chunk.endOffsetMs > offsetMs {
            if let wavData = try? EncryptedChunkWriter.decryptChunk(chunk: chunk, key: key) {
                scheduleWavDataInMemory(wavData, on: systemPlayerNode)
            }
        }
    }

    private func scheduleWavDataInMemory(_ data: Data, on node: AVAudioPlayerNode) {
        guard data.count > 44 else { return }
        let pcmData = data.subdata(in: 44..<data.count)
        let sampleCount = pcmData.count / 2
        guard sampleCount > 0 else { return }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000.0, channels: 1, interleaved: true),
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)

        pcmData.withUnsafeBytes { rawPtr in
            if let base = rawPtr.baseAddress, let channelData = pcmBuffer.int16ChannelData {
                memcpy(channelData[0], base, pcmData.count)
            }
        }

        node.scheduleBuffer(pcmBuffer, at: nil)
    }

    private func startProgressTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, self.state == .playing else { return }
            self.currentPositionMs += 100
            if self.totalDurationMs > 0 && self.currentPositionMs >= self.totalDurationMs {
                self.stop()
            } else {
                self.delegate?.audioPlaybackEngine(self, didUpdateOffsetMs: self.currentPositionMs)
            }
        }
    }

    private func stopProgressTimer() {
        timer?.invalidate()
        timer = nil
    }
}
