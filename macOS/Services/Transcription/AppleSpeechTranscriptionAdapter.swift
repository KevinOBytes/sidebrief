import Foundation
import Speech
import AVFoundation

/// High-performance native macOS speech-to-text adapter using Apple's Speech framework (SFSpeechRecognizer).
/// Operates on-device and via Apple Speech Engine with zero external API keys and zero network cost.
public final class AppleSpeechTranscriptionAdapter: NSObject, TranscriptionServiceProtocol, @unchecked Sendable {
    private let (stream, continuation) = AsyncStream.makeStream(of: TranscriptionEvent.self)
    public var eventStream: AsyncStream<TranscriptionEvent> { stream }

    private let locale: Locale
    private let queue = DispatchQueue(label: "com.sidebrief.stt.applespeech", qos: .userInitiated)

    private struct TrackSession {
        let track: AudioTrack
        let meetingId: String
        var recognizer: SFSpeechRecognizer?
        var currentRequest: SFSpeechAudioBufferRecognitionRequest?
        var currentTask: SFSpeechRecognitionTask?
        var currentTaskId: UUID
        var currentSegmentId: String
        var segmentStartOffsetMs: Int64
        var latestOffsetMs: Int64
        var lastEmittedText: String
        var taskStartTime: Date
        var isClosing: Bool
        var silenceTimer: Task<Void, Never>?
    }

    private var sessions: [String: TrackSession] = [:]
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

    // MARK: - Lifecycle

    public func startSession(meetingId: String, track: AudioTrack) async throws {
        // Check / request authorization
        let authStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard authStatus == .authorized else {
            continuation.yield(.error(trackId: track.id, message: "Apple Speech Recognition permission not granted (status: \(authStatus.rawValue)). Please allow in System Settings > Privacy & Security > Speech Recognition."))
            return
        }

        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let validRecognizer = recognizer, validRecognizer.isAvailable else {
            continuation.yield(.error(trackId: track.id, message: "Speech recognizer unavailable for locale \(locale.identifier)."))
            return
        }

        queue.sync {
            let session = TrackSession(
                track: track,
                meetingId: meetingId,
                recognizer: validRecognizer,
                currentRequest: nil,
                currentTask: nil,
                currentTaskId: UUID(),
                currentSegmentId: UUID().uuidString,
                segmentStartOffsetMs: 0,
                latestOffsetMs: 0,
                lastEmittedText: "",
                taskStartTime: Date(),
                isClosing: false
            )
            self.sessions[track.id] = session
            self.spawnRecognitionTask_locked(trackId: track.id)
        }

        continuation.yield(.started(trackId: track.id))
    }

    public func sendAudioChunk(trackId: String, pcmData: Data, sampleCount: Int, offsetMs: Int64) async throws {
        guard sampleCount > 0, !pcmData.isEmpty else { return }

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

        queue.sync {
            guard var session = sessions[trackId], !session.isClosing else { return }
            session.latestOffsetMs = offsetMs

            // Apple SFSpeechRecognitionTask max recommended duration is ~45-60 seconds.
            // If the current task has been running > 45 seconds, roll over into a fresh task smoothly.
            let taskAge = Date().timeIntervalSince(session.taskStartTime)
            if taskAge > 45.0 && !session.lastEmittedText.isEmpty {
                self.commitAndRollover_locked(trackId: trackId)
                session = self.sessions[trackId] ?? session
            }

            self.sessions[trackId] = session
            session.currentRequest?.append(pcmBuffer)
        }
    }

    public func endSession(trackId: String) async throws {
        queue.sync {
            guard var session = sessions.removeValue(forKey: trackId) else { return }
            session.silenceTimer?.cancel()
            session.silenceTimer = nil
            session.isClosing = true
            session.currentRequest?.endAudio()
            session.currentTask?.finish()

            // If there was any trailing uncommitted text, commit it now
            let text = session.lastEmittedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let speaker = (session.track.sourceType == .microphone) ? "You" : "Remote Speaker"
                let segment = TranscriptSegment(
                    id: session.currentSegmentId,
                    meetingId: session.meetingId,
                    trackId: session.track.id,
                    providerSegmentId: session.currentSegmentId,
                    speakerLabel: speaker,
                    text: text,
                    startOffsetMs: session.segmentStartOffsetMs,
                    endOffsetMs: max(session.segmentStartOffsetMs + 500, session.latestOffsetMs),
                    isProvisional: false
                )
                self.continuation.yield(.committed(segment: segment))
            }
        }

        continuation.yield(.closed(trackId: trackId))
    }

    // MARK: - Private Task Management

    private func spawnRecognitionTask_locked(trackId: String) {
        guard var session = sessions[trackId], let recognizer = session.recognizer else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        // Allow on-device recognition if available, with graceful network fallback
        if #available(macOS 10.15, *) {
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = false
            }
        }

        let taskId = UUID()
        session.currentTaskId = taskId
        session.currentRequest = request
        session.taskStartTime = Date()

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            self.handleRecognitionCallback(trackId: trackId, taskId: taskId, result: result, error: error)
        }

        session.currentTask = task
        self.sessions[trackId] = session
    }

    private func commitAndRollover_locked(trackId: String) {
        guard var session = sessions[trackId] else { return }
        session.silenceTimer?.cancel()
        session.silenceTimer = nil

        let text = session.lastEmittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let speaker = (session.track.sourceType == .microphone) ? "You" : "Remote Speaker"
            let segment = TranscriptSegment(
                id: session.currentSegmentId,
                meetingId: session.meetingId,
                trackId: session.track.id,
                providerSegmentId: session.currentSegmentId,
                speakerLabel: speaker,
                text: text,
                startOffsetMs: session.segmentStartOffsetMs,
                endOffsetMs: max(session.segmentStartOffsetMs + 500, session.latestOffsetMs),
                isProvisional: false
            )
            continuation.yield(.committed(segment: segment))
        }

        // Close old request cleanly
        session.currentRequest?.endAudio()
        session.currentTask?.finish()

        // Roll to new utterance segment and invalidate old taskId
        session.currentSegmentId = UUID().uuidString
        session.segmentStartOffsetMs = session.latestOffsetMs
        session.lastEmittedText = ""
        session.currentRequest = nil
        session.currentTask = nil
        session.currentTaskId = UUID() // Immediately decouples callbacks from the terminating task
        self.sessions[trackId] = session

        // Spawn fresh task
        self.spawnRecognitionTask_locked(trackId: trackId)
    }

    private func handleRecognitionCallback(trackId: String, taskId: UUID, result: SFSpeechRecognitionResult?, error: Error?) {
        var shouldCommit = false
        var segmentToEmit: TranscriptSegment?

        queue.sync {
            // Drop callbacks from superseded tasks so terminating tasks cannot emit duplicate transcripts or replace active tasks
            guard var session = sessions[trackId], !session.isClosing, session.currentTaskId == taskId else { return }

            if let result = result {
                let transcription = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !transcription.isEmpty else { return }

                session.lastEmittedText = transcription
                let speaker = (session.track.sourceType == .microphone) ? "You" : "Remote Speaker"

                if result.isFinal {
                    session.silenceTimer?.cancel()
                    session.silenceTimer = nil
                    shouldCommit = true
                    let seg = TranscriptSegment(
                        id: session.currentSegmentId,
                        meetingId: session.meetingId,
                        trackId: session.track.id,
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
                    self.sessions[trackId] = session

                    // Respawn request for subsequent speech
                    self.spawnRecognitionTask_locked(trackId: trackId)
                } else {
                    let seg = TranscriptSegment(
                        id: session.currentSegmentId,
                        meetingId: session.meetingId,
                        trackId: session.track.id,
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
                    let capturedTrackId = trackId
                    let capturedTaskId = taskId
                    session.silenceTimer?.cancel()
                    session.silenceTimer = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        guard !Task.isCancelled, let self = self else { return }
                        self.queue.sync {
                            guard let s = self.sessions[capturedTrackId],
                                  !s.isClosing,
                                  s.currentTaskId == capturedTaskId,
                                  s.lastEmittedText == currentCapturedText,
                                  !currentCapturedText.isEmpty else { return }
                            self.commitAndRollover_locked(trackId: capturedTrackId)
                        }
                    }

                    self.sessions[trackId] = session
                }
            } else if let error = error as NSError?, !session.isClosing {
                // If error code is 203 (timeout) or 216 (cancelled), respawn task if session is still alive
                if error.domain == "kAFAssistantErrorDomain" || error.code == 203 || error.code == 216 {
                    if !session.lastEmittedText.isEmpty {
                        self.commitAndRollover_locked(trackId: trackId)
                    } else {
                        self.spawnRecognitionTask_locked(trackId: trackId)
                    }
                } else if error.code != 209 { // 209 is endAudio normal closure
                    continuation.yield(.error(trackId: trackId, message: error.localizedDescription))
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
