import Foundation

public final class ElevenLabsStreamingSTTAdapter: TranscriptionServiceProtocol, @unchecked Sendable {
    private let apiKey: String
    private let modelId: String
    private let session = URLSession(configuration: .default)

    private struct TrackSession {
        let track: AudioTrack
        let meetingId: String
        var webSocketTask: URLSessionWebSocketTask?
        var isConnected: Bool = false
        var currentSegmentId: String = UUID().uuidString
        var latestOffsetMs: Int64 = 0
        var segmentStartOffsetMs: Int64 = 0
        var isUtteranceActive: Bool = false
        var lastCommittedText: String = ""
        var pcmBuffer: Data = Data()
        var accumulatedSamples: Int = 0
    }

    private var trackSessions: [String: TrackSession] = [:]
    private let queue = DispatchQueue(label: "com.sidebrief.stt.sessions", qos: .userInitiated)

    private let (stream, continuation) = AsyncStream.makeStream(of: TranscriptionEvent.self)
    public var eventStream: AsyncStream<TranscriptionEvent> { stream }

    public init(apiKey: String, modelId: String = "scribe_v2_realtime") {
        self.apiKey = apiKey
        self.modelId = modelId
    }

    public func startSession(meetingId: String, track: AudioTrack) async throws {
        var urlComponents = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        urlComponents.queryItems = [
            URLQueryItem(name: "model_id", value: modelId),
            URLQueryItem(name: "audio_format", value: "pcm_\(Int(track.sampleRate))"),
            URLQueryItem(name: "commit_strategy", value: "vad")
        ]

        var request = URLRequest(url: urlComponents.url!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let task = session.webSocketTask(with: request)

        queue.sync {
            let trackSession = TrackSession(track: track, meetingId: meetingId, webSocketTask: task, isConnected: true)
            trackSessions[track.id] = trackSession
        }

        task.resume()
        continuation.yield(.started(trackId: track.id))

        listenToWebSocket(task: task, track: track, meetingId: meetingId)
    }

    public func sendAudioChunk(trackId: String, pcmData: Data, sampleCount: Int, offsetMs: Int64) async throws {
        var payloadToSend: Data?
        var taskToSendTo: URLSessionWebSocketTask?

        queue.sync {
            guard var trackSession = trackSessions[trackId], trackSession.isConnected else { return }
            trackSession.latestOffsetMs = offsetMs
            if !trackSession.isUtteranceActive {
                trackSession.segmentStartOffsetMs = offsetMs
            }

            trackSession.pcmBuffer.append(pcmData)
            trackSession.accumulatedSamples += sampleCount

            // Buffer ~200ms before transmitting over WebSocket to prevent network congestion
            let minSamples = Int(trackSession.track.sampleRate * 0.20)
            if trackSession.accumulatedSamples >= minSamples {
                payloadToSend = trackSession.pcmBuffer
                taskToSendTo = trackSession.webSocketTask
                trackSession.pcmBuffer = Data()
                trackSession.accumulatedSamples = 0
            }
            trackSessions[trackId] = trackSession
        }

        guard let task = taskToSendTo, let data = payloadToSend, !data.isEmpty else { return }

        let base64Audio = data.base64EncodedString()
        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": base64Audio
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            let message = URLSessionWebSocketTask.Message.string(jsonString)
            try? await task.send(message)
        }
    }

    public func endSession(trackId: String) async throws {
        let (task, remainingData): (URLSessionWebSocketTask?, Data?) = queue.sync {
            guard var trackSession = trackSessions.removeValue(forKey: trackId) else { return (nil, nil) }
            let remaining = trackSession.pcmBuffer.isEmpty ? nil : trackSession.pcmBuffer
            trackSession.pcmBuffer = Data()
            return (trackSession.webSocketTask, remaining)
        }

        if let task = task, let remaining = remainingData, !remaining.isEmpty {
            let base64Audio = remaining.base64EncodedString()
            let payload: [String: Any] = [
                "message_type": "input_audio_chunk",
                "audio_base_64": base64Audio
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                try? await task.send(URLSessionWebSocketTask.Message.string(jsonString))
            }
        }

        task?.cancel(with: .normalClosure, reason: nil)
        continuation.yield(.closed(trackId: trackId))
    }

    private func listenToWebSocket(task: URLSessionWebSocketTask, track: AudioTrack, meetingId: String) {
        task.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                self.handleIncomingMessage(message, track: track, meetingId: meetingId)
                self.listenToWebSocket(task: task, track: track, meetingId: meetingId)

            case .failure(let error):
                self.queue.sync {
                    self.trackSessions[track.id]?.isConnected = false
                }
                self.continuation.yield(.error(trackId: track.id, message: error.localizedDescription))
            }
        }
    }

    private func handleIncomingMessage(_ message: URLSessionWebSocketTask.Message, track: AudioTrack, meetingId: String) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let messageType = (json["message_type"] as? String) ?? (json["type"] as? String) ?? ""
        let speaker = (track.sourceType == .microphone) ? "You" : "Remote Speaker"

        if messageType == "error" || json["error"] != nil {
            let errorMsg = json["message"] as? String ?? json["error"] as? String ?? "Unknown ElevenLabs STT error"
            continuation.yield(.error(trackId: track.id, message: errorMsg))
            return
        }

        if messageType == "partial_transcript" || messageType == "provisional" {
            let transcriptText = (json["text"] as? String) ?? (json["transcript"] as? String) ?? ""
            guard !transcriptText.isEmpty else { return }

            var segId = ""
            var startMs: Int64 = 0
            var endMs: Int64 = 0

            queue.sync {
                if var session = self.trackSessions[track.id] {
                    session.isUtteranceActive = true
                    segId = session.currentSegmentId
                    startMs = session.segmentStartOffsetMs
                    endMs = max(startMs + 500, session.latestOffsetMs)
                    self.trackSessions[track.id] = session
                }
            }

            if segId.isEmpty {
                segId = UUID().uuidString
            }

            let segment = TranscriptSegment(
                id: segId,
                meetingId: meetingId,
                trackId: track.id,
                providerSegmentId: segId,
                speakerLabel: speaker,
                text: transcriptText,
                startOffsetMs: startMs,
                endOffsetMs: endMs,
                isProvisional: true
            )
            continuation.yield(.provisional(segment: segment))

        } else if messageType == "committed_transcript" || messageType == "final" {
            let transcriptText = (json["text"] as? String) ?? (json["transcript"] as? String) ?? ""
            guard !transcriptText.isEmpty else { return }

            var cleanText = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
            var segId = ""
            var startMs: Int64 = 0
            var endMs: Int64 = 0

            let shouldEmit: Bool = queue.sync {
                guard var session = self.trackSessions[track.id] else { return false }
                cleanText = Self.deduplicateOverlap(previous: session.lastCommittedText, current: cleanText)
                if cleanText.isEmpty {
                    return false
                }
                session.lastCommittedText = transcriptText
                segId = session.currentSegmentId
                startMs = session.segmentStartOffsetMs
                endMs = max(startMs + 1000, session.latestOffsetMs)
                // Roll to new ID for the subsequent utterance
                session.currentSegmentId = UUID().uuidString
                session.isUtteranceActive = false
                session.segmentStartOffsetMs = session.latestOffsetMs
                self.trackSessions[track.id] = session
                return true
            }

            guard shouldEmit, !cleanText.isEmpty else { return }

            if segId.isEmpty {
                segId = UUID().uuidString
            }

            let segment = TranscriptSegment(
                id: segId,
                meetingId: meetingId,
                trackId: track.id,
                providerSegmentId: segId,
                speakerLabel: speaker,
                text: cleanText,
                startOffsetMs: startMs,
                endOffsetMs: endMs,
                isProvisional: false
            )
            continuation.yield(.committed(segment: segment))
        }
    }

    /// Strips repeated prefix words at consecutive VAD chunk boundaries to eliminate stutter/duplicate words.
    public static func deduplicateOverlap(previous: String, current: String) -> String {
        let prevWords = previous.split(separator: " ").map { String($0) }
        let currWords = current.split(separator: " ").map { String($0) }
        guard !prevWords.isEmpty && !currWords.isEmpty else { return current }

        func normalize(_ word: String) -> String {
            word.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters)
        }

        let maxOverlap = min(8, min(prevWords.count, currWords.count))
        for k in stride(from: maxOverlap, through: 1, by: -1) {
            let prevSuffix = prevWords.suffix(k).map(normalize)
            let currPrefix = currWords.prefix(k).map(normalize)
            if prevSuffix == currPrefix {
                let remainingWords = currWords.dropFirst(k)
                if remainingWords.isEmpty {
                    return ""
                }
                return remainingWords.joined(separator: " ")
            }
        }
        return current
    }
}
