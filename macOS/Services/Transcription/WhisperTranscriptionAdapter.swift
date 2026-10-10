import Foundation

/// Fast Whisper cloud transcription adapter supporting OpenAI Whisper (`whisper-1`) and Groq Whisper (`whisper-large-v3`).
public final class WhisperTranscriptionAdapter: TranscriptionServiceProtocol, @unchecked Sendable {
    private let apiKey: String
    public let endpoint: String
    public let model: String
    private let session = URLSession(configuration: .default)

    private let (stream, continuation) = AsyncStream.makeStream(of: TranscriptionEvent.self)
    public var eventStream: AsyncStream<TranscriptionEvent> { stream }

    private struct TrackState {
        let track: AudioTrack
        let meetingId: String
        var pcmBuffer: Data
        var sampleCountAccumulated: Int
        var segmentStartOffsetMs: Int64
        var latestOffsetMs: Int64
        var isProcessing: Bool
    }

    private var trackStates: [String: TrackState] = [:]
    private let queue = DispatchQueue(label: "com.sidebrief.stt.whisper", qos: .userInitiated)

    public init(
        apiKey: String,
        endpoint: String? = nil,
        model: String? = nil
    ) {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = cleanKey
        if let customEndpoint = endpoint, !customEndpoint.isEmpty {
            self.endpoint = customEndpoint
            self.model = model ?? (cleanKey.hasPrefix("gsk_") ? "whisper-large-v3-turbo" : "whisper-1")
        } else if cleanKey.hasPrefix("gsk_") {
            // Auto-detect Groq Whisper: 150ms latency, high accuracy, free tier
            self.endpoint = "https://api.groq.com/openai/v1/audio/transcriptions"
            self.model = model ?? "whisper-large-v3-turbo"
        } else {
            self.endpoint = "https://api.openai.com/v1/audio/transcriptions"
            self.model = model ?? "whisper-1"
        }
    }

    public func startSession(meetingId: String, track: AudioTrack) async throws {
        queue.sync {
            trackStates[track.id] = TrackState(
                track: track,
                meetingId: meetingId,
                pcmBuffer: Data(),
                sampleCountAccumulated: 0,
                segmentStartOffsetMs: 0,
                latestOffsetMs: 0,
                isProcessing: false
            )
        }
        continuation.yield(.started(trackId: track.id))
    }

    public func sendAudioChunk(trackId: String, pcmData: Data, sampleCount: Int, offsetMs: Int64) async throws {
        guard sampleCount > 0, !pcmData.isEmpty else { return }

        var audioToTranscribe: (Data, AudioTrack, String, Int64, Int64)?

        queue.sync {
            guard var state = trackStates[trackId] else { return }
            state.pcmBuffer.append(pcmData)
            state.sampleCountAccumulated += sampleCount
            state.latestOffsetMs = offsetMs

            // Buffer 2.0s for Groq (sub-200ms inference) or 3.0s for standard OpenAI Whisper
            let secondsThreshold = self.endpoint.contains("groq.com") ? 2.0 : 3.0
            let thresholdSamples = Int(state.track.sampleRate * secondsThreshold)
            if state.sampleCountAccumulated >= thresholdSamples && !state.isProcessing {
                state.isProcessing = true
                let chunkData = state.pcmBuffer
                let startMs = state.segmentStartOffsetMs
                let endMs = state.latestOffsetMs

                // Reset buffer for next window
                state.pcmBuffer = Data()
                state.sampleCountAccumulated = 0
                state.segmentStartOffsetMs = state.latestOffsetMs

                audioToTranscribe = (chunkData, state.track, state.meetingId, startMs, endMs)
            }
            trackStates[trackId] = state
        }

        if let (data, track, meetingId, startMs, endMs) = audioToTranscribe {
            Task {
                await self.transcribeAudioChunk(track: track, meetingId: meetingId, pcmData: data, startMs: startMs, endMs: endMs)
            }
        }
    }

    public func endSession(trackId: String) async throws {
        var finalChunk: (Data, AudioTrack, String, Int64, Int64)?

        queue.sync {
            guard let state = trackStates.removeValue(forKey: trackId) else { return }
            if !state.pcmBuffer.isEmpty {
                finalChunk = (state.pcmBuffer, state.track, state.meetingId, state.segmentStartOffsetMs, state.latestOffsetMs)
            }
        }

        if let (data, track, meetingId, startMs, endMs) = finalChunk {
            await self.transcribeAudioChunk(track: track, meetingId: meetingId, pcmData: data, startMs: startMs, endMs: endMs)
        }

        continuation.yield(.closed(trackId: trackId))
    }

    private func transcribeAudioChunk(track: AudioTrack, meetingId: String, pcmData: Data, startMs: Int64, endMs: Int64) async {
        defer {
            queue.sync {
                if var state = trackStates[track.id] {
                    state.isProcessing = false
                    trackStates[track.id] = state
                }
            }
        }

        guard !pcmData.isEmpty else { return }

        let wavData = Self.createWavData(fromPCM16: pcmData, sampleRate: Int(track.sampleRate), channels: track.channelCount)

        guard let url = URL(string: endpoint) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // model param
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

        // file param
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return }
            guard (200...299).contains(httpResponse.statusCode) else {
                let errBody = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                continuation.yield(.error(trackId: track.id, message: "Whisper STT error (\(httpResponse.statusCode)): \(errBody)"))
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                return
            }

            let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanText.isEmpty else { return }

            let isMic = (track.sourceType == .microphone)
            let speaker = SpeakerDiarizationService.shared.attributeSpeaker(
                meetingId: meetingId,
                isMic: isMic,
                pcmData: pcmData,
                sampleRate: track.sampleRate
            )
            let segId = UUID().uuidString
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
        } catch {
            continuation.yield(.error(trackId: track.id, message: error.localizedDescription))
        }
    }

    /// Wraps raw 16-bit PCM samples in a standard 44-byte RIFF WAV header
    public static func createWavData(fromPCM16 pcmData: Data, sampleRate: Int, channels: Int) -> Data {
        var wav = Data()
        let byteRate = sampleRate * channels * 2
        let blockAlign = channels * 2
        let subchunk2Size = pcmData.count
        let chunkSize = 36 + subchunk2Size

        // RIFF header
        wav.append("RIFF".data(using: .utf8)!)
        var cSize = UInt32(chunkSize).littleEndian
        wav.append(Data(bytes: &cSize, count: 4))
        wav.append("WAVE".data(using: .utf8)!)

        // fmt chunk
        wav.append("fmt ".data(using: .utf8)!)
        var subchunk1Size = UInt32(16).littleEndian
        wav.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat = UInt16(1).littleEndian // PCM
        wav.append(Data(bytes: &audioFormat, count: 2))
        var numChannels = UInt16(channels).littleEndian
        wav.append(Data(bytes: &numChannels, count: 2))
        var sRate = UInt32(sampleRate).littleEndian
        wav.append(Data(bytes: &sRate, count: 4))
        var bRate = UInt32(byteRate).littleEndian
        wav.append(Data(bytes: &bRate, count: 4))
        var bAlign = UInt16(blockAlign).littleEndian
        wav.append(Data(bytes: &bAlign, count: 2))
        var bitsPerSample = UInt16(16).littleEndian
        wav.append(Data(bytes: &bitsPerSample, count: 2))

        // data chunk
        wav.append("data".data(using: .utf8)!)
        var dataSize = UInt32(subchunk2Size).littleEndian
        wav.append(Data(bytes: &dataSize, count: 4))
        wav.append(pcmData)

        return wav
    }
}
