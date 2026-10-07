import Foundation
@preconcurrency import AVFoundation
import ScreenCaptureKit
import CoreAudio

public protocol AudioCaptureServiceDelegate: AnyObject, Sendable {
    func audioCaptureService(_ service: AudioCaptureService, didUpdateMicMeter meter: AudioLevelMeter)
    func audioCaptureService(_ service: AudioCaptureService, didUpdateSystemMeter meter: AudioLevelMeter)
    func audioCaptureService(_ service: AudioCaptureService, didFinalizeChunk chunk: AudioChunk)
    func audioCaptureService(_ service: AudioCaptureService, didChangeState state: AudioCaptureState)
}

public final class AudioCaptureService: NSObject, @unchecked Sendable {
    public static let sampleRate: Double = 48000.0
    public static let channelCount: Int = 1

    private let syncQueue = DispatchQueue(label: "com.sidebrief.audio.state", qos: .userInitiated)

    private var _currentState: AudioCaptureState = .idle
    public var currentState: AudioCaptureState {
        syncQueue.sync { _currentState }
    }

    private var _currentMeetingId: String?
    public var currentMeetingId: String? {
        syncQueue.sync { _currentMeetingId }
    }

    private var _micTrack: AudioTrack?
    public var micTrack: AudioTrack? {
        syncQueue.sync { _micTrack }
    }

    private var _systemTrack: AudioTrack?
    public var systemTrack: AudioTrack? {
        syncQueue.sync { _systemTrack }
    }

    public weak var delegate: AudioCaptureServiceDelegate?

    // Audio Callbacks for Streaming STT (16kHz or 48kHz PCM)
    public var onMicPCMData: (@Sendable (Data, Int, Int64) -> Void)?
    public var onSystemPCMData: (@Sendable (Data, Int, Int64) -> Void)?

    // AVFoundation Microphone Engine
    private let audioEngine = AVAudioEngine()
    private var isAudioEngineRunning = false

    // ScreenCaptureKit System Audio
    private var scStream: SCStream?
    private var scFilter: SCContentFilter?
    private var scStreamOutput: SystemAudioOutputHandler?

    // Encrypted Chunk Writers
    private var micChunkWriter: EncryptedChunkWriter?
    private var systemChunkWriter: EncryptedChunkWriter?

    // Monotonic Timeline
    private var meetingStartTimeMs: Int64 = 0
    private var _isPaused = false
    private var isPaused: Bool {
        syncQueue.sync { _isPaused }
    }

    private let processingQueue = DispatchQueue(label: "com.sidebrief.audio.processing", qos: .userInitiated)

    private var hasRequestedScreenCaptureAccess = false

    public override init() {
        super.init()
    }

    // MARK: - Lifecycle

    public func startCapture(
        meetingId: String,
        scope: SystemCaptureScope = .wholeSystem,
        journalDirectory: URL? = nil
    ) async throws {
        let shouldProceed: Bool = syncQueue.sync {
            guard _currentState == .idle || _currentState == .failed else { return false }
            _currentState = .initializing
            _currentMeetingId = meetingId
            _isPaused = false
            return true
        }

        guard shouldProceed else { return }

        // Request Microphone permission if not determined
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }

        meetingStartTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
        let streamEpoch = meetingStartTimeMs

        // Setup Tracks
        let mic = AudioTrack(
            meetingId: meetingId,
            sourceType: .microphone,
            deviceName: "Default Input",
            sampleRate: Self.sampleRate,
            channelCount: Self.channelCount,
            streamEpoch: streamEpoch
        )
        let sys = AudioTrack(
            meetingId: meetingId,
            sourceType: .systemAudio,
            deviceName: "System Output",
            sampleRate: Self.sampleRate,
            channelCount: Self.channelCount,
            streamEpoch: streamEpoch
        )

        syncQueue.sync {
            _micTrack = mic
            _systemTrack = sys
        }

        // Initialize Encrypted Chunk Writers
        self.micChunkWriter = try EncryptedChunkWriter(
            meetingId: meetingId,
            trackId: mic.id,
            journalDirectory: journalDirectory,
            sampleRate: Self.sampleRate,
            channelCount: Self.channelCount,
            chunkDurationSeconds: 2.0,
            streamEpoch: streamEpoch
        )

        self.systemChunkWriter = try EncryptedChunkWriter(
            meetingId: meetingId,
            trackId: sys.id,
            journalDirectory: journalDirectory,
            sampleRate: Self.sampleRate,
            channelCount: Self.channelCount,
            chunkDurationSeconds: 2.0,
            streamEpoch: streamEpoch
        )

        // Start Microphone capture
        try setupMicrophoneCapture()

        // Start System Audio capture via ScreenCaptureKit
        try await setupScreenCaptureKitAudio(scope: scope)

        syncQueue.sync {
            if _currentState != .degraded {
                _currentState = .capturing
            }
        }
        let finalState = syncQueue.sync { _currentState }
        delegate?.audioCaptureService(self, didChangeState: finalState)
    }

    public func pauseCapture() {
        let didPause: Bool = syncQueue.sync {
            guard _currentState == .capturing else { return false }
            _isPaused = true
            _currentState = .paused
            return true
        }

        if didPause {
            delegate?.audioCaptureService(self, didChangeState: .paused)
        }
    }

    public func resumeCapture() {
        let didResume: Bool = syncQueue.sync {
            guard _currentState == .paused else { return false }
            _isPaused = false
            _currentState = .capturing
            return true
        }

        if didResume {
            delegate?.audioCaptureService(self, didChangeState: .capturing)
        }
    }

    public func stopCapture() async throws -> [AudioChunk] {
        syncQueue.sync {
            _currentState = .idle
            _isPaused = true
        }

        // Stop Audio Engine
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            isAudioEngineRunning = false
        }

        // Stop SCStream
        if let scStream = scStream {
            try? await scStream.stopCapture()
            self.scStream = nil
        }

        // Flush remaining chunks from writers
        var allChunks: [AudioChunk] = []

        if let micWriter = micChunkWriter {
            if let lastChunk = try? await micWriter.flush() {
                allChunks.append(lastChunk)
                delegate?.audioCaptureService(self, didFinalizeChunk: lastChunk)
            }
            allChunks.append(contentsOf: await micWriter.getFinalizedChunks())
        }

        if let sysWriter = systemChunkWriter {
            if let lastChunk = try? await sysWriter.flush() {
                allChunks.append(lastChunk)
                delegate?.audioCaptureService(self, didFinalizeChunk: lastChunk)
            }
            allChunks.append(contentsOf: await sysWriter.getFinalizedChunks())
        }

        delegate?.audioCaptureService(self, didChangeState: .idle)
        return allChunks
    }

    public func currentOffsetMs() -> Int64 {
        return max(0, Int64(Date().timeIntervalSince1970 * 1000) - meetingStartTimeMs)
    }

    // MARK: - Microphone Capture (AVFoundation)

    private func setupMicrophoneCapture() throws {
        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.inputFormat(forBus: 0)

        // Ensure valid hardware format
        guard nativeFormat.sampleRate > 0 && nativeFormat.channelCount > 0 else {
            return
        }

        // Target format: 48kHz Mono 16-bit Float/PCM
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: AVAudioChannelCount(Self.channelCount),
            interleaved: true
        ) else {
            return
        }

        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            return
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: nativeFormat) { [weak self] buffer, time in
            guard let self = self, !self.isPaused else { return }

            // Meter calculation on raw buffer (non-blocking)
            let meter = Self.computeAudioMeter(from: buffer)
            DispatchQueue.main.async {
                self.delegate?.audioCaptureService(self, didUpdateMicMeter: meter)
            }

            // Convert to 48kHz 16-bit mono
            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / nativeFormat.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(frameCount, 1024)) else {
                return
            }

            final class BufferInputBox: @unchecked Sendable {
                var hasData = false
                let buffer: AVAudioPCMBuffer
                init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
            }
            let box = BufferInputBox(buffer: buffer)
            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                if !box.hasData {
                    box.hasData = true
                    outStatus.pointee = .haveData
                    return box.buffer
                } else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }

            if status != .error, let channelData = convertedBuffer.int16ChannelData {
                let sampleCount = Int(convertedBuffer.frameLength)
                let byteCount = sampleCount * 2
                let data = Data(bytes: channelData[0], count: byteCount)
                let offsetMs = self.currentOffsetMs()

                self.processingQueue.async { [weak self] in
                    guard let self = self else { return }
                    // 1. Immediately forward to streaming STT callback in strict FIFO order
                    self.onMicPCMData?(data, sampleCount, offsetMs)

                    // 2. Off-thread journal encryption & disk chunk writing (does not block or reorder STT)
                    Task {
                        if let chunk = try? await self.micChunkWriter?.appendAudioData(data, sampleCount: sampleCount) {
                            DispatchQueue.main.async {
                                self.delegate?.audioCaptureService(self, didFinalizeChunk: chunk)
                            }
                        }
                    }
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        isAudioEngineRunning = true
    }

    // MARK: - ScreenCaptureKit System Audio

    private func setupScreenCaptureKitAudio(scope: SystemCaptureScope) async throws {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                syncQueue.sync {
                    _currentState = .degraded
                }
                delegate?.audioCaptureService(self, didChangeState: .degraded)
                return
            }

            let filter: SCContentFilter
            switch scope {
            case .wholeSystem:
                filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            case .selectedApplication(let bundleId, _):
                let apps = content.applications.filter { $0.bundleIdentifier == bundleId }
                filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
            }
            self.scFilter = filter

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = Int(Self.sampleRate)
            config.channelCount = Self.channelCount

            let outputHandler = SystemAudioOutputHandler(service: self)
            self.scStreamOutput = outputHandler

            let stream = SCStream(filter: filter, configuration: config, delegate: outputHandler)
            try stream.addStreamOutput(outputHandler, type: .audio, sampleHandlerQueue: processingQueue)
            try await stream.startCapture()
            self.scStream = stream
        } catch {
            syncQueue.sync {
                _currentState = .degraded
            }
            delegate?.audioCaptureService(self, didChangeState: .degraded)
        }
    }

    // MARK: - Internal System Audio Handler

    fileprivate func handleSystemAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard !isPaused else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            return
        }

        var blockBuffer: CMBlockBuffer?
        let channelCount = max(1, Int(asbd.mChannelsPerFrame))
        let ablPointer = AudioBufferList.allocate(maximumBuffers: channelCount)
        defer { free(UnsafeMutableRawPointer(mutating: ablPointer.unsafePointer)) }

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPointer.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channelCount),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let firstBuffer = ablPointer.first, let rawData = firstBuffer.mData else {
            return
        }

        let byteCount = Int(firstBuffer.mDataByteSize)
        guard byteCount > 0 else { return }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bits = asbd.mBitsPerChannel
        let buffers = Array(ablPointer)

        var pcmData = Data()
        var sampleCount = 0

        if isFloat && bits == 32 {
            if isNonInterleaved && buffers.count > 1 {
                // Non-interleaved multi-channel: each buffer contains one channel
                let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float32>.size
                guard frames > 0 else { return }
                pcmData.reserveCapacity(frames * MemoryLayout<Int16>.size)
                let chPointers = buffers.compactMap { $0.mData?.bindMemory(to: Float32.self, capacity: frames) }
                guard chPointers.count == buffers.count else { return }

                for f in 0..<frames {
                    var sum: Float = 0
                    for ch in 0..<buffers.count {
                        sum += chPointers[ch][f]
                    }
                    let avg = sum / Float(buffers.count)
                    var int16Val = Int16(max(-1.0, min(1.0, avg)) * 32767.0)
                    withUnsafeBytes(of: &int16Val) { pcmData.append(contentsOf: $0) }
                }
                sampleCount = frames
            } else {
                // Interleaved multi-channel (e.g. standard stereo) or mono
                let totalFloats = byteCount / MemoryLayout<Float32>.size
                let frames = totalFloats / channelCount
                guard frames > 0 else { return }
                pcmData.reserveCapacity(frames * MemoryLayout<Int16>.size)
                let floatPtr = rawData.bindMemory(to: Float32.self, capacity: totalFloats)

                for f in 0..<frames {
                    var sum: Float = 0
                    let base = f * channelCount
                    for ch in 0..<channelCount {
                        sum += floatPtr[base + ch]
                    }
                    let avg = sum / Float(channelCount)
                    var int16Val = Int16(max(-1.0, min(1.0, avg)) * 32767.0)
                    withUnsafeBytes(of: &int16Val) { pcmData.append(contentsOf: $0) }
                }
                sampleCount = frames
            }
        } else if bits == 16 {
            let totalInt16 = byteCount / MemoryLayout<Int16>.size
            let frames = totalInt16 / channelCount
            guard frames > 0 else { return }
            pcmData.reserveCapacity(frames * MemoryLayout<Int16>.size)
            let int16Ptr = rawData.bindMemory(to: Int16.self, capacity: totalInt16)

            for f in 0..<frames {
                var sum: Int32 = 0
                let base = f * channelCount
                for ch in 0..<channelCount {
                    sum += Int32(int16Ptr[base + ch])
                }
                var int16Val = Int16(sum / Int32(channelCount))
                withUnsafeBytes(of: &int16Val) { pcmData.append(contentsOf: $0) }
            }
            sampleCount = frames
        } else {
            return
        }

        // Resample to exact 48kHz mono if source sample rate differs (e.g. 44.1kHz bluetooth/DAC)
        if asbd.mSampleRate > 0 && abs(asbd.mSampleRate - Self.sampleRate) > 50.0 && sampleCount > 1 {
            let srcRate = asbd.mSampleRate
            let dstRate = Self.sampleRate
            let ratio = dstRate / srcRate
            let outCount = Int(Double(sampleCount) * ratio)
            var resampledData = Data(capacity: outCount * MemoryLayout<Int16>.size)

            pcmData.withUnsafeBytes { rawPtr in
                let inSamples = rawPtr.bindMemory(to: Int16.self)
                for i in 0..<outCount {
                    let srcIndex = Double(i) / ratio
                    let idx0 = Int(srcIndex)
                    let idx1 = min(idx0 + 1, sampleCount - 1)
                    let frac = Float(srcIndex - Double(idx0))
                    let s0 = Float(inSamples[idx0])
                    let s1 = Float(inSamples[idx1])
                    let interpolated = s0 + frac * (s1 - s0)
                    var finalVal = Int16(max(-32768.0, min(32767.0, interpolated)))
                    withUnsafeBytes(of: &finalVal) { resampledData.append(contentsOf: $0) }
                }
            }
            pcmData = resampledData
            sampleCount = outCount
        }

        let offsetMs = currentOffsetMs()

        // Compute meter
        let meter = Self.computeMeterFromPCM16(data: pcmData)
        DispatchQueue.main.async {
            self.delegate?.audioCaptureService(self, didUpdateSystemMeter: meter)
        }

        // 1. Immediately forward to streaming STT callback in strict FIFO order
        self.onSystemPCMData?(pcmData, sampleCount, offsetMs)

        // 2. Off-thread journal encryption & disk chunk writing (does not block or reorder STT)
        Task { [weak self] in
            guard let self = self else { return }
            if let chunk = try? await self.systemChunkWriter?.appendAudioData(pcmData, sampleCount: sampleCount) {
                DispatchQueue.main.async {
                    self.delegate?.audioCaptureService(self, didFinalizeChunk: chunk)
                }
            }
        }
    }

    // MARK: - Meter Helpers

    public static func computeAudioMeter(from buffer: AVAudioPCMBuffer) -> AudioLevelMeter {
        guard let channelData = buffer.floatChannelData else {
            return AudioLevelMeter()
        }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return AudioLevelMeter() }

        var sum: Float = 0.0
        var peak: Float = 0.0

        let channelSamples = channelData[0]
        for i in 0..<frameLength {
            let sample = abs(channelSamples[i])
            if sample > peak { peak = sample }
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameLength))
        return AudioLevelMeter.from(rms: rms, peak: peak)
    }

    public static func computeMeterFromPCM16(data: Data) -> AudioLevelMeter {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return AudioLevelMeter() }

        var sum: Float = 0.0
        var peak: Float = 0.0

        data.withUnsafeBytes { rawBuffer in
            guard let samples = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<sampleCount {
                let sampleFloat = abs(Float(samples[i]) / 32768.0)
                if sampleFloat > peak { peak = sampleFloat }
                sum += sampleFloat * sampleFloat
            }
        }

        let rms = sqrt(sum / Float(sampleCount))
        return AudioLevelMeter.from(rms: rms, peak: peak)
    }
}

// MARK: - SCStreamDelegate & SCStreamOutput

private final class SystemAudioOutputHandler: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    private weak var service: AudioCaptureService?

    init(service: AudioCaptureService) {
        self.service = service
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        service?.handleSystemAudioBuffer(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Capture stopped or interrupted
    }
}
