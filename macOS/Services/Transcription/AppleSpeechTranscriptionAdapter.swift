import Foundation
import Speech
import AVFoundation

/// High-performance native macOS speech-to-text adapter using Apple's Speech framework (SFSpeechRecognizer).
/// Operates on-device and via Apple Speech Engine with zero external API keys and zero network cost.
/// Uses an Active Channel VAD Router & Synchronous Mixer to eliminate dual-track audio interleaving and time dilation.
public final class AppleSpeechTranscriptionAdapter: NSObject, TranscriptionServiceProtocol, @unchecked Sendable {
    private let (stream, continuation) = AsyncStream.makeStream(of: TranscriptionEvent.self)
    public var eventStream: AsyncStream<TranscriptionEvent> { stream }

    private let locale: Locale
    private let queue = DispatchQueue(label: "com.sidebrief.stt.applespeech", qos: .userInitiated)

    private var registeredTracks: [String: AudioTrack] = [:]
    private var currentMeetingId: String = ""

    private var recognizer: SFSpeechRecognizer?
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    private var currentTask: SFSpeechRecognitionTask?
    private var currentTaskId: UUID = UUID()
    private var currentSegmentId: String = UUID().uuidString
    private var segmentStartOffsetMs: Int64 = 0
    private var latestOffsetMs: Int64 = 0
    private var lastEmittedText: String = ""
    private var taskStartTime: Date = Date()
    private var lastErrorTime: Date = Date.distantPast
    private var isClosing: Bool = false
    private var silenceTimer: Task<Void, Never>?

    // VAD & Active Channel Tracking
    private let vadThreshold: Double = 220.0
    private var lastMicSpeechDate: Date = Date.distantPast
    private var lastSysSpeechDate: Date = Date.distantPast
    private var lastRoutedTrackType: AudioSourceType = .microphone
    private var lastSilenceAppendDate: Date = Date.distantPast
    public var contextualStrings: [String] = []

    // Energy tracking for speaker attribution
    private var micEnergyAccumulator: Double = 0
    private var sysEnergyAccumulator: Double = 0
    private var lastAttributedSpeaker: String = "You"
    private var lastAttributedTrackId: String = ""

    private let audioFormat: AVAudioFormat

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
        // Audio format matches AudioCaptureService target format: 48kHz mono 16-bit PCM
        self.audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioCaptureService.sampleRate,
            channels: AVAudioChannelCount(AudioCaptureService.channelCount),
            interleaved: true
        ) ?? AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 1)!
        super.init()
    }

    public func setCustomVocabulary(_ words: [String]) {
        queue.sync {
            self.contextualStrings = words
        }
    }

    // MARK: - Lifecycle

    public func startSession(meetingId: String, track: AudioTrack) async throws {
        // Check / request authorization only if not yet determined
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        let authStatus: SFSpeechRecognizerAuthorizationStatus
        if currentStatus == .notDetermined {
            let hasSpeechDesc = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
            if hasSpeechDesc {
                authStatus = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { status in
                        continuation.resume(returning: status)
                    }
                }
            } else {
                authStatus = .denied
            }
        } else {
            authStatus = currentStatus
        }

        guard authStatus == .authorized else {
            continuation.yield(.error(trackId: track.id, message: "Apple Speech Recognition permission not granted (status: \(authStatus.rawValue)). Please allow in System Settings > Privacy & Security > Speech Recognition."))
            return
        }

        let rec = recognizer ?? SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let validRecognizer = rec, validRecognizer.isAvailable else {
            continuation.yield(.error(trackId: track.id, message: "Speech recognizer unavailable for locale \(locale.identifier)."))
            return
        }

        queue.sync {
            self.recognizer = validRecognizer
            self.currentMeetingId = meetingId
            self.registeredTracks[track.id] = track
            if self.lastAttributedTrackId.isEmpty {
                self.lastAttributedTrackId = track.id
            }
            self.isClosing = false
        }

        continuation.yield(.started(trackId: track.id))
    }

    public func sendAudioChunk(trackId: String, pcmData: Data, sampleCount: Int, offsetMs: Int64) async throws {
        guard sampleCount > 0, !pcmData.isEmpty else { return }

        // Compute RMS signal energy for accurate VAD gating
        var sumSquares: Double = 0
        pcmData.withUnsafeBytes { rawPtr in
            if let base = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self) {
                for i in 0..<sampleCount {
                    let s = Double(base[i])
                    sumSquares += s * s
                }
            }
        }
        let chunkRMS = sqrt(sumSquares / Double(sampleCount))

        queue.sync {
            guard !isClosing else { return }
            latestOffsetMs = offsetMs

            let track = registeredTracks[trackId]
            let isMic = (track?.sourceType == .microphone)
            let hasSpeech = (chunkRMS >= vadThreshold)

            if hasSpeech {
                if isMic {
                    lastMicSpeechDate = Date()
                    micEnergyAccumulator += chunkRMS * Double(sampleCount)
                } else {
                    lastSysSpeechDate = Date()
                    sysEnergyAccumulator += chunkRMS * Double(sampleCount)
                }
            }

            // Evaluate active speech with 350ms hangover to preserve natural inter-word micro-pauses
            let now = Date()
            let micActive = (now.timeIntervalSince(lastMicSpeechDate) < 0.35)
            let sysActive = (now.timeIntervalSince(lastSysSpeechDate) < 0.35)

            // Active Channel Selection & Decision:
            // Prevents parallel track serialization (which diced audio into 42ms slices and doubled time)
            let shouldAppendChunk: Bool
            let targetTrackType: AudioSourceType

            if micActive && !sysActive {
                // Local microphone speech exclusively: drop system silence
                shouldAppendChunk = isMic
                targetTrackType = .microphone
            } else if sysActive && !micActive {
                // Remote participant speech exclusively: drop mic room noise
                shouldAppendChunk = !isMic
                targetTrackType = .systemAudio
            } else if micActive && sysActive {
                // Crosstalk: accept chunk from the dominant speaking channel
                let dominantIsMic = (micEnergyAccumulator >= sysEnergyAccumulator)
                shouldAppendChunk = (isMic == dominantIsMic)
                targetTrackType = dominantIsMic ? .microphone : .systemAudio
            } else {
                // Silence on both channels: throttle silence buffers to at most one buffer per 100ms
                // This keeps Apple Speech clock advancing in 1x real-time without 2x time dilation
                targetTrackType = lastRoutedTrackType
                if now.timeIntervalSince(lastSilenceAppendDate) >= 0.10 {
                    lastSilenceAppendDate = now
                    shouldAppendChunk = isMic // Pick one arbitrary channel to deliver real-time silence
                } else {
                    shouldAppendChunk = false
                }
            }

            guard shouldAppendChunk else { return }

            // Conversational Turn Transition Detection:
            // If the active speaking channel switched (e.g. You finished asking a question and Remote Speaker begins answering),
            // commit the prior utterance immediately to pass the prompt to the AI copilot without waiting for timeouts!
            if targetTrackType != lastRoutedTrackType && !lastEmittedText.isEmpty {
                self.commitAndRollover_locked()
            }
            lastRoutedTrackType = targetTrackType

            // Update speaker attribution
            let micTrack = registeredTracks.values.first { $0.sourceType == .microphone }
            let sysTrack = registeredTracks.values.first { $0.sourceType == .systemAudio }
            if targetTrackType == .microphone {
                lastAttributedSpeaker = "You"
                lastAttributedTrackId = micTrack?.id ?? trackId
            } else {
                lastAttributedSpeaker = "Remote Speaker"
                lastAttributedTrackId = sysTrack?.id ?? trackId
            }

            // Apple SFSpeechRecognitionTask max recommended duration is ~45-60 seconds.
            // If the current task has been running > 45 seconds with active text, roll over smoothly.
            let taskAge = now.timeIntervalSince(taskStartTime)
            if taskAge > 45.0 && !lastEmittedText.isEmpty {
                self.commitAndRollover_locked()
            }

            // Lazily spawn recognition task when audio arrives, with backoff throttle to prevent loops
            if currentRequest == nil {
                let timeSinceError = now.timeIntervalSince(lastErrorTime)
                if timeSinceError >= 0.20 {
                    self.spawnRecognitionTask_locked()
                }
            }

            guard let req = currentRequest else { return }

            // Build AVAudioPCMBuffer
            let frameCount = AVAudioFrameCount(sampleCount)
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else {
                return
            }
            pcmBuffer.frameLength = frameCount

            // Safe alignment-independent copy into audio buffer
            pcmData.withUnsafeBytes { rawPtr in
                if let baseAddress = rawPtr.baseAddress, let channelData = pcmBuffer.int16ChannelData {
                    let copyByteCount = min(pcmData.count, Int(frameCount) * MemoryLayout<Int16>.size)
                    memcpy(channelData[0], baseAddress, copyByteCount)
                }
            }

            req.append(pcmBuffer)
        }
    }

    public func endSession(trackId: String) async throws {
        queue.sync {
            _ = registeredTracks.removeValue(forKey: trackId)
            guard registeredTracks.isEmpty else { return }

            silenceTimer?.cancel()
            silenceTimer = nil
            isClosing = true
            currentRequest?.endAudio()
            currentTask?.finish()

            // If there was any trailing uncommitted text, commit it now
            let text = lastEmittedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let isMicDominant = (lastRoutedTrackType == .microphone)
                let micTrack = registeredTracks.values.first { $0.sourceType == .microphone }
                let sysTrack = registeredTracks.values.first { $0.sourceType == .systemAudio }
                let speaker = isMicDominant ? "You" : "Remote Speaker"
                let targetTrackId = isMicDominant ? (micTrack?.id ?? lastAttributedTrackId) : (sysTrack?.id ?? lastAttributedTrackId)
                let resolvedTrackId = targetTrackId.isEmpty ? trackId : targetTrackId

                let segment = TranscriptSegment(
                    id: currentSegmentId,
                    meetingId: currentMeetingId,
                    trackId: resolvedTrackId,
                    providerSegmentId: currentSegmentId,
                    speakerLabel: speaker,
                    text: text,
                    startOffsetMs: segmentStartOffsetMs,
                    endOffsetMs: max(segmentStartOffsetMs + 500, latestOffsetMs),
                    isProvisional: false
                )
                self.continuation.yield(.committed(segment: segment))
            }

            currentRequest = nil
            currentTask = nil
        }

        continuation.yield(.closed(trackId: trackId))
    }

    // MARK: - Private Task Management

    private func spawnRecognitionTask_locked() {
        guard !isClosing, let rec = recognizer, rec.isAvailable else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .unspecified

        // Prioritize on-device Apple Neural Engine recognition to eliminate server latency & timeouts
        if #available(macOS 10.15, *), rec.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        // Inject custom vocabulary if provided
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }

        let taskId = UUID()
        currentTaskId = taskId
        currentRequest = request
        taskStartTime = Date()

        let task = rec.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            self.handleRecognitionCallback(taskId: taskId, result: result, error: error)
        }

        currentTask = task
    }

    private func commitAndRollover_locked() {
        silenceTimer?.cancel()
        silenceTimer = nil

        let text = lastEmittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let isMicDominant = (lastRoutedTrackType == .microphone)
            let micTrack = registeredTracks.values.first { $0.sourceType == .microphone }
            let sysTrack = registeredTracks.values.first { $0.sourceType == .systemAudio }
            let speaker = isMicDominant ? "You" : "Remote Speaker"
            let targetTrackId = isMicDominant ? (micTrack?.id ?? lastAttributedTrackId) : (sysTrack?.id ?? lastAttributedTrackId)
            let resolvedTrackId = targetTrackId.isEmpty ? (registeredTracks.keys.first ?? "audio") : targetTrackId

            let segment = TranscriptSegment(
                id: currentSegmentId,
                meetingId: currentMeetingId,
                trackId: resolvedTrackId,
                providerSegmentId: currentSegmentId,
                speakerLabel: speaker,
                text: text,
                startOffsetMs: segmentStartOffsetMs,
                endOffsetMs: max(segmentStartOffsetMs + 500, latestOffsetMs),
                isProvisional: false
            )
            continuation.yield(.committed(segment: segment))
        }

        // Reset utterance energy
        micEnergyAccumulator = 0
        sysEnergyAccumulator = 0

        // Close old request cleanly
        currentRequest?.endAudio()
        currentTask?.finish()

        // Roll to new utterance segment and invalidate old taskId
        currentSegmentId = UUID().uuidString
        segmentStartOffsetMs = latestOffsetMs
        lastEmittedText = ""
        currentRequest = nil
        currentTask = nil
        currentTaskId = UUID()
    }

    private func handleRecognitionCallback(taskId: UUID, result: SFSpeechRecognitionResult?, error: Error?) {
        var shouldCommit = false
        var segmentToEmit: TranscriptSegment?

        queue.sync {
            // Drop callbacks from superseded tasks so terminating tasks cannot emit duplicate transcripts
            guard !isClosing, currentTaskId == taskId else { return }

            if let result = result {
                let transcription = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !transcription.isEmpty else { return }

                lastEmittedText = transcription
                let speaker = lastAttributedSpeaker
                let resolvedTrackId = lastAttributedTrackId

                if result.isFinal {
                    silenceTimer?.cancel()
                    silenceTimer = nil
                    shouldCommit = true
                    let seg = TranscriptSegment(
                        id: currentSegmentId,
                        meetingId: currentMeetingId,
                        trackId: resolvedTrackId,
                        providerSegmentId: currentSegmentId,
                        speakerLabel: speaker,
                        text: transcription,
                        startOffsetMs: segmentStartOffsetMs,
                        endOffsetMs: max(segmentStartOffsetMs + 500, latestOffsetMs),
                        isProvisional: false
                    )
                    segmentToEmit = seg

                    // Advance segment and cycle task ID
                    currentSegmentId = UUID().uuidString
                    segmentStartOffsetMs = latestOffsetMs
                    lastEmittedText = ""
                    currentTaskId = UUID()
                    currentRequest = nil
                    currentTask = nil
                    micEnergyAccumulator = 0
                    sysEnergyAccumulator = 0
                } else {
                    let seg = TranscriptSegment(
                        id: currentSegmentId,
                        meetingId: currentMeetingId,
                        trackId: resolvedTrackId,
                        providerSegmentId: currentSegmentId,
                        speakerLabel: speaker,
                        text: transcription,
                        startOffsetMs: segmentStartOffsetMs,
                        endOffsetMs: max(segmentStartOffsetMs + 500, latestOffsetMs),
                        isProvisional: true
                    )
                    segmentToEmit = seg

                    // Auto-commit on 1.2s conversational pause/silence so the assistant immediately produces suggestions
                    let currentCapturedText = transcription
                    let capturedTaskId = taskId
                    silenceTimer?.cancel()
                    silenceTimer = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        guard !Task.isCancelled, let self = self else { return }
                        self.queue.sync {
                            guard !self.isClosing,
                                  self.currentTaskId == capturedTaskId,
                                  self.lastEmittedText == currentCapturedText,
                                  !currentCapturedText.isEmpty else { return }
                            self.commitAndRollover_locked()
                        }
                    }
                }
            } else if let error = error as NSError?, !isClosing {
                lastErrorTime = Date()
                if error.code == 209 {
                    // Normal audio buffer completion
                    return
                } else if error.code == 1110 {
                    // No speech detected during interval: clean up request so next incoming speech chunk spawns cleanly
                    currentRequest = nil
                    currentTask = nil
                } else if error.code == 203 || error.code == 216 {
                    // Timeout or cancelled: commit any captured text, or clean up request
                    if !lastEmittedText.isEmpty {
                        self.commitAndRollover_locked()
                    } else {
                        currentRequest = nil
                        currentTask = nil
                    }
                } else {
                    continuation.yield(.error(trackId: lastAttributedTrackId, message: error.localizedDescription))
                }
            }
        }

        if let segment = segmentToEmit {
            if shouldCommit {
                continuation.yield(.committed(segment: segment))
            } else {
                continuation.yield(.provisional(segment: segment))
            }
        }
    }
}
