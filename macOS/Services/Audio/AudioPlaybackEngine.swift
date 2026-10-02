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

    public func loadMeeting(
        meetingId: String,
        micChunks: [AudioChunk],
        systemChunks: [AudioChunk]
    ) {
        lock.lock()
        defer { lock.unlock() }

        self.meetingId = meetingId
        self.micChunks = micChunks.sorted(by: { $0.startOffsetMs < $1.startOffsetMs })
        self.systemChunks = systemChunks.sorted(by: { $0.startOffsetMs < $1.startOffsetMs })
        self.currentPositionMs = 0
    }

    /// Plays audio from the current position or resumes if paused.
    public func play() throws {
        lock.lock()
        defer { lock.unlock() }

        guard state != .playing else { return }

        if !audioEngine.isRunning {
            try audioEngine.start()
        }

        micPlayerNode.play()
        systemPlayerNode.play()
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

        currentPositionMs = offsetMs

        // Find relevant chunks around offsetMs and schedule them
        guard let meetingId = meetingId else { return }
        let key = try AudioKeychainManager.shared.getOrCreateKey(for: meetingId)

        // Schedule mic chunks
        for chunk in micChunks where chunk.endOffsetMs > offsetMs {
            if let wavData = try? EncryptedChunkWriter.decryptChunk(chunk: chunk, key: key) {
                scheduleWavData(wavData, on: micPlayerNode)
            }
        }

        // Schedule system chunks
        for chunk in systemChunks where chunk.endOffsetMs > offsetMs {
            if let wavData = try? EncryptedChunkWriter.decryptChunk(chunk: chunk, key: key) {
                scheduleWavData(wavData, on: systemPlayerNode)
            }
        }

        if wasPlaying {
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
            micPlayerNode.play()
            systemPlayerNode.play()
            state = .playing
        }

        DispatchQueue.main.async {
            self.delegate?.audioPlaybackEngine(self, didUpdateOffsetMs: offsetMs)
        }
    }

    private func scheduleWavData(_ data: Data, on node: AVAudioPlayerNode) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try? data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let file = try? AVAudioFile(forReading: tempURL) else { return }
        node.scheduleFile(file, at: nil)
    }

    private func startProgressTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, self.state == .playing else { return }
            self.currentPositionMs += 100
            self.delegate?.audioPlaybackEngine(self, didUpdateOffsetMs: self.currentPositionMs)
        }
    }

    private func stopProgressTimer() {
        timer?.invalidate()
        timer = nil
    }
}
