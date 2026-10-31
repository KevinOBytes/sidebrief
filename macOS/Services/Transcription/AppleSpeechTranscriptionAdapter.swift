import Foundation
import Speech
import AVFoundation

/// High-performance native macOS speech-to-text adapter using Apple's Speech framework (SFSpeechRecognizer).
/// Operates on-device and via Apple Speech Engine with zero external API keys and zero network cost.
/// Maintains independent concurrent recognition sessions per audio track (Microphone & System Audio)
/// with pre-roll buffering, acoustic silence gating, and automatic conversational turn commit.
public final class AppleSpeechTranscriptionAdapter: NSObject, TranscriptionServiceProtocol, @unchecked Sendable {
    private let (stream, continuation) = AsyncStream.makeStream(of: TranscriptionEvent.self)
    public var eventStream: AsyncStream<TranscriptionEvent> { stream }

    private let locale: Locale
    private let queue = DispatchQueue(label: "com.sidebrief.stt.applespeech", qos: .userInitiated)

    // Per-track independent recognition session
    private final class TrackSession: @unchecked Sendable {
        let trackId: String
        let sourceType: AudioSourceType
        let meetingId: String
        let isMic: Bool

        var currentRequest: SFSpeechAudioBufferRecognitionRequest?
        var currentTask: SFSpeechRecognitionTask?
        var currentTaskId: UUID = UUID()
        var currentSegmentId: String = UUID().uuidString
        var segmentStartOffsetMs: Int64 = 0
        var latestOffsetMs: Int64 = 0
        var lastEmittedText: String = ""
        var taskStartTime: Date = Date()
        var lastSpeechDate: Date = Date.distantPast
        var lastErrorTime: Date = Date.distantPast

        // Rolling 250ms circular pre-roll buffer (mono 16-bit 48kHz = 24,000 bytes)
        // Preserves initial consonant phonemes on utterance onset
        var preRollBuffer: Data = Data()
        let maxPreRollBytes: Int = Int(AudioCaptureService.sampleRate) * MemoryLayout<Int16>.size / 4

        // Utterance accumulation for speaker diarization
        var utterancePCMData: Data = Data()
        let maxUtteranceBytes: Int = Int(AudioCaptureService.sampleRate) * MemoryLayout<Int16>.size * 10 // 10 seconds max

        var silenceTimer: Task<Void, Never>?

        init(track: AudioTrack, meetingId: String) {
            self.trackId = track.id
            self.sourceType = track.sourceType
            self.meetingId = meetingId
            self.isMic = (track.sourceType == .microphone)
        }
    }

    private var sessions: [String: TrackSession] = [:]
    private var recognizer: SFSpeechRecognizer?
    private var isClosing: Bool = false

    // Acoustic Gating: realistic noise floor threshold (-64 dBFS)
    private let silenceFloorRMS: Double = 20.0
    // Hangover preserves natural inter-word micro-pauses (e.g. stops before plosives)
    private let speechHangoverSeconds: Double = 1.2
    // Conversational turn commit interval on sustained silence
    private let silenceCommitSeconds: Double = 1.3

    public var contextualStrings: [String] = []
    private let audioFormat: AVAudioFormat

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
        // Target format matches AudioCaptureService: 48kHz mono 16-bit PCM
        self.audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioCaptureService.sampleRate,
            channels: AVAudioChannelCount(AudioCaptureService.channelCount),
            interleaved: false
        ) ?? AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48000.0,
            channels: 1,
            interleaved: false
        )!
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
            self.isClosing = false
            let session = TrackSession(track: track, meetingId: meetingId)
            self.sessions[track.id] = session
        }

        continuation.yield(.started(trackId: track.id))
    }

    public func sendAudioChunk(trackId: String, pcmData: Data, sampleCount: Int, offsetMs: Int64) async throws {
        guard sampleCount > 0, !pcmData.isEmpty else { return }

        // Compute RMS signal energy for noise floor gating
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
            guard !isClosing, let session = sessions[trackId] else { return }
            session.latestOffsetMs = offsetMs

            let now = Date()
            let isChunkSpeech = (chunkRMS >= silenceFloorRMS)
            if isChunkSpeech {
                session.lastSpeechDate = now
            }
            let isWithinHangover = now.timeIntervalSince(session.lastSpeechDate) < speechHangoverSeconds

            if !isChunkSpeech && !isWithinHangover {
                // True silence on this channel: maintain 250ms pre-roll circular buffer
                session.preRollBuffer.append(pcmData)
                if session.preRollBuffer.count > session.maxPreRollBytes {
                    session.preRollBuffer.removeFirst(session.preRollBuffer.count - session.maxPreRollBytes)
                }

                // If utterance was active and silence has exceeded the commit threshold, commit it
                if session.currentRequest != nil && !session.lastEmittedText.isEmpty {
                    let silenceDuration = now.timeIntervalSince(session.lastSpeechDate)
                    if silenceDuration >= silenceCommitSeconds {
                        self.commitAndRollover_locked(for: session)
                    }
                }
                return
            }

            // Speech is active (or in an inter-word pause within hangover)
            if session.currentRequest == nil {
                let timeSinceError = now.timeIntervalSince(session.lastErrorTime)
                guard timeSinceError >= 0.20 else { return }
                self.spawnRecognitionTask_locked(for: session)

                // Inject pre-roll buffer to preserve leading consonant phonemes on utterance onset
                if let req = session.currentRequest, !session.preRollBuffer.isEmpty {
                    let preRollSamples = session.preRollBuffer.count / MemoryLayout<Int16>.size
                    if preRollSamples > 0 {
                        self.appendPCMData(session.preRollBuffer, sampleCount: preRollSamples, to: req)
                        session.utterancePCMData.append(session.preRollBuffer)
                    }
                    session.preRollBuffer = Data()
                }
            }

            guard let req = session.currentRequest else { return }
            self.appendPCMData(pcmData, sampleCount: sampleCount, to: req)
            if session.utterancePCMData.count < session.maxUtteranceBytes {
                session.utterancePCMData.append(pcmData)
            }

            // Apple SFSpeechRecognitionTask max recommended duration is ~45-60 seconds.
            // If the current task has been running > 45 seconds with active text, roll over smoothly.
            let taskAge = now.timeIntervalSince(session.taskStartTime)
            if taskAge > 45.0 && !session.lastEmittedText.isEmpty {
                self.commitAndRollover_locked(for: session)
            }
        }
    }

    public func endSession(trackId: String) async throws {
        queue.sync {
            guard let session = sessions.removeValue(forKey: trackId) else { return }
            session.silenceTimer?.cancel()
            session.silenceTimer = nil
            session.currentRequest?.endAudio()
            session.currentTask?.finish()

            let text = session.lastEmittedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let durationSec = Double(max(500, session.latestOffsetMs - session.segmentStartOffsetMs)) / 1000.0
                let speaker: String
                if session.isMic {
                    let userName = UserDefaults.standard.string(forKey: "sidebrief_user_name") ?? "You"
                    speaker = userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "You" : userName
                } else {
                    speaker = SpeakerDiarizationService.shared.attributeSpeaker(
                        meetingId: session.meetingId,
                        isMic: false,
                        pcmData: session.utterancePCMData,
                        sampleRate: AudioCaptureService.sampleRate,
                        segmentDurationSeconds: durationSec,
                        isFinal: true
                    )
                }

                let segment = TranscriptSegment(
                    id: session.currentSegmentId,
                    meetingId: session.meetingId,
                    trackId: session.trackId,
                    providerSegmentId: session.currentSegmentId,
                    speakerLabel: speaker,
                    text: text,
                    startOffsetMs: session.segmentStartOffsetMs,
                    endOffsetMs: max(session.segmentStartOffsetMs + 500, session.latestOffsetMs),
                    isProvisional: false
                )
                self.continuation.yield(.committed(segment: segment))
            }

            session.currentRequest = nil
            session.currentTask = nil

            if sessions.isEmpty {
                isClosing = true
            }
        }

        continuation.yield(.closed(trackId: trackId))
    }

    // MARK: - Private Task Management

    private func spawnRecognitionTask_locked(for session: TrackSession) {
        guard !isClosing, let rec = recognizer, rec.isAvailable else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .unspecified

        // Prioritize on-device Apple Neural Engine recognition to eliminate server latency & timeouts
        if #available(macOS 10.15, *), rec.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        // Automatic punctuation & casing dramatically improves LLM comprehension
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        // Inject custom space vocabulary
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }

        let taskId = UUID()
        session.currentTaskId = taskId
        session.currentRequest = request
        session.taskStartTime = Date()
        session.segmentStartOffsetMs = session.latestOffsetMs

        let task = rec.recognitionTask(with: request) { [weak self, weak session] result, error in
            guard let self = self, let session = session else { return }
            self.handleRecognitionCallback(session: session, taskId: taskId, result: result, error: error)
        }

        session.currentTask = task
    }

    private func appendPCMData(_ data: Data, sampleCount: Int, to request: SFSpeechAudioBufferRecognitionRequest) {
        let frameCount = AVAudioFrameCount(sampleCount)
        guard frameCount > 0, let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else {
            return
        }
        pcmBuffer.frameLength = frameCount
        data.withUnsafeBytes { rawPtr in
            if let baseAddress = rawPtr.baseAddress, let channelData = pcmBuffer.int16ChannelData {
                let copyByteCount = min(data.count, Int(frameCount) * MemoryLayout<Int16>.size)
                memcpy(channelData[0], baseAddress, copyByteCount)
            }
        }
        request.append(pcmBuffer)
    }

    private func commitAndRollover_locked(for session: TrackSession) {
        session.silenceTimer?.cancel()
        session.silenceTimer = nil

        let text = session.lastEmittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let durationSec = Double(max(500, session.latestOffsetMs - session.segmentStartOffsetMs)) / 1000.0
            let speaker: String
            if session.isMic {
                let userName = UserDefaults.standard.string(forKey: "sidebrief_user_name") ?? "You"
                speaker = userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "You" : userName
            } else {
                speaker = SpeakerDiarizationService.shared.attributeSpeaker(
                    meetingId: session.meetingId,
                    isMic: false,
                    pcmData: session.utterancePCMData,
                    sampleRate: AudioCaptureService.sampleRate,
                    segmentDurationSeconds: durationSec,
                    isFinal: true
                )
            }

            let segment = TranscriptSegment(
                id: session.currentSegmentId,
                meetingId: session.meetingId,
                trackId: session.trackId,
                providerSegmentId: session.currentSegmentId,
                speakerLabel: speaker,
                text: text,
                startOffsetMs: session.segmentStartOffsetMs,
                endOffsetMs: max(session.segmentStartOffsetMs + 500, session.latestOffsetMs),
                isProvisional: false
            )
            continuation.yield(.committed(segment: segment))
        }

        session.utterancePCMData = Data()
        session.currentRequest?.endAudio()
        session.currentTask?.finish()

        session.currentSegmentId = UUID().uuidString
        session.segmentStartOffsetMs = session.latestOffsetMs
        session.lastEmittedText = ""
        session.currentRequest = nil
        session.currentTask = nil
        session.currentTaskId = UUID()
    }

    private func handleRecognitionCallback(session: TrackSession, taskId: UUID, result: SFSpeechRecognitionResult?, error: Error?) {
        var shouldCommit = false
        var segmentToEmit: TranscriptSegment?

        queue.sync {
            // Drop callbacks from superseded tasks so terminating tasks cannot emit duplicate transcripts
            guard !isClosing, session.currentTaskId == taskId else { return }

            if let result = result {
                let transcription = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !transcription.isEmpty else { return }

                session.lastEmittedText = transcription

                let speaker: String
                if session.isMic {
                    let userName = UserDefaults.standard.string(forKey: "sidebrief_user_name") ?? "You"
                    speaker = userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "You" : userName
                } else {
                    if session.utterancePCMData.count >= 3200 {
                        speaker = SpeakerDiarizationService.shared.attributeSpeaker(
                            meetingId: session.meetingId,
                            isMic: false,
                            pcmData: session.utterancePCMData,
                            sampleRate: AudioCaptureService.sampleRate,
                            isFinal: result.isFinal
                        )
                    } else {
                        speaker = "Speaker 1"
                    }
                }

                if result.isFinal {
                    session.silenceTimer?.cancel()
                    session.silenceTimer = nil
                    shouldCommit = true

                    let seg = TranscriptSegment(
                        id: session.currentSegmentId,
                        meetingId: session.meetingId,
                        trackId: session.trackId,
                        providerSegmentId: session.currentSegmentId,
                        speakerLabel: speaker,
                        text: transcription,
                        startOffsetMs: session.segmentStartOffsetMs,
                        endOffsetMs: max(session.segmentStartOffsetMs + 500, session.latestOffsetMs),
                        isProvisional: false
                    )
                    segmentToEmit = seg

                    // Advance segment and cycle task ID
                    session.currentSegmentId = UUID().uuidString
                    session.segmentStartOffsetMs = session.latestOffsetMs
                    session.lastEmittedText = ""
                    session.currentTaskId = UUID()
                    session.currentRequest = nil
                    session.currentTask = nil
                    session.utterancePCMData = Data()
                } else {
                    let seg = TranscriptSegment(
                        id: session.currentSegmentId,
                        meetingId: session.meetingId,
                        trackId: session.trackId,
                        providerSegmentId: session.currentSegmentId,
                        speakerLabel: speaker,
                        text: transcription,
                        startOffsetMs: session.segmentStartOffsetMs,
                        endOffsetMs: max(session.segmentStartOffsetMs + 500, session.latestOffsetMs),
                        isProvisional: true
                    )
                    segmentToEmit = seg

                    // Auto-commit on 1.2s conversational pause/silence so the assistant immediately produces suggestions
                    let currentCapturedText = transcription
                    let capturedTaskId = taskId
                    session.silenceTimer?.cancel()
                    session.silenceTimer = Task { [weak self, weak session] in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        guard !Task.isCancelled, let self = self, let session = session else { return }
                        self.queue.sync {
                            guard !self.isClosing,
                                  session.currentTaskId == capturedTaskId,
                                  session.lastEmittedText == currentCapturedText,
                                  !currentCapturedText.isEmpty else { return }
                            self.commitAndRollover_locked(for: session)
                        }
                    }
                }
            } else if let error = error as NSError?, !isClosing {
                session.lastErrorTime = Date()
                if error.code == 209 {
                    // Normal audio buffer completion
                    return
                } else if error.code == 1110 {
                    // No speech detected during interval: clean up request so next incoming speech chunk spawns cleanly
                    session.currentRequest = nil
                    session.currentTask = nil
                } else if error.code == 203 || error.code == 216 {
                    // Timeout or cancelled: commit any captured text, or clean up request
                    if !session.lastEmittedText.isEmpty {
                        self.commitAndRollover_locked(for: session)
                    } else {
                        session.currentRequest = nil
                        session.currentTask = nil
                    }
                } else {
                    continuation.yield(.error(trackId: session.trackId, message: error.localizedDescription))
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
