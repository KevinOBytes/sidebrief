import Foundation
@preconcurrency import AVFoundation
import ScreenCaptureKit
import Speech
import AppKit

@MainActor
public final class AudioDiagnosticsService: NSObject, ObservableObject {
    // Permission States
    @Published public var isMicAuthorized: Bool = false
    @Published public var isScreenRecordingAuthorized: Bool = false
    @Published public var isSpeechRecognitionAuthorized: Bool = false

    // Microphone Live Metering
    @Published public var isMicTesting: Bool = false
    @Published public var micLevel: Float = 0.0
    @Published public var micDb: Float = -60.0

    // Microphone 5-second Recording Test
    @Published public var isRecordingMicTest: Bool = false
    @Published public var recordingCountdown: Int = 5
    @Published public var hasRecordedTest: Bool = false
    @Published public var isPlayingRecordedTest: Bool = false

    // Speaker Output Tone
    @Published public var isPlayingTone: Bool = false

    // ScreenCaptureKit System Loopback Test
    @Published public var isLoopbackTesting: Bool = false
    @Published public var loopbackLevel: Float = 0.0
    @Published public var loopbackDb: Float = -60.0
    @Published public var loopbackError: String? = nil

    // Private Audio Resources
    private var testAudioEngine: AVAudioEngine?
    private var testAudioFile: AVAudioFile?
    private var audioPlayer: AVAudioPlayer?
    private var tonePlayer: AVAudioPlayer?
    private var countdownTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var toneTask: Task<Void, Never>?

    // ScreenCaptureKit Resources
    private var scStream: SCStream?
    private var loopbackOutputHandler: LoopbackStreamHandler?

    private let tempMicWavURL: URL = {
        FileManager.default.temporaryDirectory.appendingPathComponent("sidebrief_mic_test.wav")
    }()

    private let tempToneWavURL: URL = {
        FileManager.default.temporaryDirectory.appendingPathComponent("sidebrief_tone_test.wav")
    }()

    public override init() {
        super.init()
        checkPermissions()
    }

    // MARK: - Permission Verification

    public func checkPermissions() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        self.isMicAuthorized = (micStatus == .authorized)
        self.isScreenRecordingAuthorized = CGPreflightScreenCaptureAccess()
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        self.isSpeechRecognitionAuthorized = (speechStatus == .authorized)
    }

    public func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                self?.isMicAuthorized = granted
                self?.checkPermissions()
            }
        }
    }

    public func requestSpeechRecognitionPermission() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.isSpeechRecognitionAuthorized = (status == .authorized)
                self?.checkPermissions()
            }
        }
    }

    public func requestScreenRecordingPermission() {
        CGRequestScreenCaptureAccess()
        checkPermissions()
    }

    public func openSpeechRecognitionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Live Microphone Metering Test

    public func startMicTest() {
        guard !isMicTesting else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0 && format.channelCount > 0 else {
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let level = Self.calculateRMS(from: buffer)
            let db = 20 * log10(max(level, 1e-5))
            let normalized = max(0.0, min(1.0, (db + 50.0) / 50.0))

            Task { @MainActor [weak self] in
                self?.micLevel = normalized
                self?.micDb = db
            }
        }

        do {
            try engine.start()
            self.testAudioEngine = engine
            self.isMicTesting = true
        } catch {
            inputNode.removeTap(onBus: 0)
            self.isMicTesting = false
        }
    }

    public func stopMicTest() {
        if let engine = testAudioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            testAudioEngine = nil
        }
        isMicTesting = false
        micLevel = 0.0
        micDb = -60.0
    }

    // MARK: - 5-Second Mic Record & Listen Test

    public func start5SecondMicRecordTest() {
        guard !isRecordingMicTest else { return }

        stopMicTest()
        stopPlayingRecordedTest()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0 && format.channelCount > 0 else { return }

        // Remove previous temp file
        try? FileManager.default.removeItem(at: tempMicWavURL)

        guard let audioFile = try? AVAudioFile(
            forWriting: tempMicWavURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        ) else { return }

        self.testAudioFile = audioFile
        self.isRecordingMicTest = true
        self.recordingCountdown = 5
        self.hasRecordedTest = false

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            try? audioFile.write(from: buffer)

            let level = Self.calculateRMS(from: buffer)
            let db = 20 * log10(max(level, 1e-5))
            let normalized = max(0.0, min(1.0, (db + 50.0) / 50.0))

            Task { @MainActor [weak self] in
                self?.micLevel = normalized
                self?.micDb = db
            }
        }

        do {
            try engine.start()
            self.testAudioEngine = engine

            // 5 second countdown task
            self.countdownTask?.cancel()
            self.countdownTask = Task { @MainActor [weak self] in
                for _ in 0..<5 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self = self, self.isRecordingMicTest else { return }
                    if self.recordingCountdown > 1 {
                        self.recordingCountdown -= 1
                    } else {
                        self.finish5SecondMicRecordTest()
                        return
                    }
                }
            }
        } catch {
            inputNode.removeTap(onBus: 0)
            self.isRecordingMicTest = false
        }
    }

    private func finish5SecondMicRecordTest() {
        countdownTask?.cancel()
        countdownTask = nil

        if let engine = testAudioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            testAudioEngine = nil
        }
        testAudioFile = nil
        isRecordingMicTest = false
        hasRecordedTest = FileManager.default.fileExists(atPath: tempMicWavURL.path)
        micLevel = 0.0
        micDb = -60.0
    }

    public func playRecordedTest() {
        guard hasRecordedTest, !isPlayingRecordedTest else { return }
        stopMicTest()

        do {
            let player = try AVAudioPlayer(contentsOf: tempMicWavURL)
            self.audioPlayer = player
            self.isPlayingRecordedTest = true

            player.play()

            // Observe playback completion with task
            self.playbackTask?.cancel()
            self.playbackTask = Task { @MainActor [weak self] in
                while true {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard let self = self, self.isPlayingRecordedTest else { break }
                    if !(self.audioPlayer?.isPlaying ?? false) {
                        self.isPlayingRecordedTest = false
                        break
                    }
                }
            }
        } catch {
            isPlayingRecordedTest = false
        }
    }

    public func stopPlayingRecordedTest() {
        playbackTask?.cancel()
        playbackTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isPlayingRecordedTest = false
    }

    // MARK: - Speaker Test Tone Playback

    public func playSpeakerTestTone() {
        guard !isPlayingTone else { return }

        // Generate synthetic two-tone chime (440 Hz A4 followed by 880 Hz A5)
        if !FileManager.default.fileExists(atPath: tempToneWavURL.path) {
            Self.generateChimeWav(at: tempToneWavURL)
        }

        do {
            let player = try AVAudioPlayer(contentsOf: tempToneWavURL)
            self.tonePlayer = player
            self.isPlayingTone = true
            player.play()

            self.toneTask?.cancel()
            self.toneTask = Task { @MainActor [weak self] in
                while true {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard let self = self, self.isPlayingTone else { break }
                    if !(self.tonePlayer?.isPlaying ?? false) {
                        self.isPlayingTone = false
                        break
                    }
                }
            }
        } catch {
            isPlayingTone = false
        }
    }

    public func stopSpeakerTestTone() {
        toneTask?.cancel()
        toneTask = nil
        tonePlayer?.stop()
        tonePlayer = nil
        isPlayingTone = false
    }

    // MARK: - ScreenCaptureKit System Audio Loopback Test

    public func startLoopbackTest() async {
        guard !isLoopbackTesting else { return }
        loopbackError = nil

        guard CGPreflightScreenCaptureAccess() else {
            loopbackError = "Screen Recording permission is required for system audio capture."
            return
        }

        do {
            let shareable = try await SCShareableContent.current
            guard let display = shareable.displays.first else {
                loopbackError = "No active display found for ScreenCaptureKit."
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 1
            config.excludesCurrentProcessAudio = true

            let handler = LoopbackStreamHandler { [weak self] level, db in
                Task { @MainActor in
                    self?.loopbackLevel = level
                    self?.loopbackDb = db
                }
            }
            self.loopbackOutputHandler = handler

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.sidebrief.test.loopback", qos: .userInitiated))
            try await stream.startCapture()

            self.scStream = stream
            self.isLoopbackTesting = true
        } catch {
            self.loopbackError = "Failed to start loopback capture: \(error.localizedDescription)"
            self.isLoopbackTesting = false
        }
    }

    public func stopLoopbackTest() {
        if let stream = scStream {
            stream.stopCapture { _ in }
            scStream = nil
        }
        loopbackOutputHandler = nil
        isLoopbackTesting = false
        loopbackLevel = 0.0
        loopbackDb = -60.0
    }

    public func stopAllTests() {
        stopMicTest()
        finish5SecondMicRecordTest()
        stopPlayingRecordedTest()
        stopSpeakerTestTone()
        stopLoopbackTest()
    }

    // MARK: - Audio Utilities

    private static func calculateRMS(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0.0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0.0 }

        var sum: Float = 0.0
        for i in 0..<frames {
            let sample = channelData[i]
            sum += sample * sample
        }
        return sqrt(sum / Float(frames))
    }

    private static func generateChimeWav(at url: URL) {
        let sampleRate: Double = 44100.0
        let duration: Double = 0.8
        let totalSamples = Int(sampleRate * duration)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        guard let audioFile = try? AVAudioFile(forWriting: url, settings: settings) else { return }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(totalSamples)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(totalSamples)

        guard let channels = pcmBuffer.floatChannelData else { return }
        let channel = channels[0]

        // 0.0s - 0.35s: 523.25 Hz (C5), 0.35s - 0.8s: 659.25 Hz (E5)
        let f1 = 523.25
        let f2 = 659.25
        let splitSample = Int(sampleRate * 0.35)

        for i in 0..<totalSamples {
            let t = Double(i) / sampleRate
            let freq = (i < splitSample) ? f1 : f2
            let envelope: Double
            if i < splitSample {
                let localT = Double(i) / sampleRate
                envelope = exp(-localT * 4.0)
            } else {
                let localT = Double(i - splitSample) / sampleRate
                envelope = exp(-localT * 3.5)
            }
            channel[i] = Float(sin(2.0 * .pi * freq * t) * envelope * 0.4)
        }

        try? audioFile.write(from: pcmBuffer)
    }
}

// MARK: - ScreenCaptureKit Stream Output Handler

private final class LoopbackStreamHandler: NSObject, SCStreamOutput, @unchecked Sendable {
    private let onMeterUpdate: @Sendable (Float, Float) -> Void

    init(onMeterUpdate: @escaping @Sendable (Float, Float) -> Void) {
        self.onMeterUpdate = onMeterUpdate
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let rawPointer = dataPointer, length > 0 else { return }

        let sampleCount = length / MemoryLayout<Float>.size
        let floatPointer = rawPointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { $0 }

        var sum: Float = 0.0
        for i in 0..<sampleCount {
            let sample = floatPointer[i]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(max(1, sampleCount)))
        let db = 20 * log10(max(rms, 1e-5))
        let normalized = max(0.0, min(1.0, (db + 50.0) / 50.0))

        onMeterUpdate(normalized, db)
    }
}
