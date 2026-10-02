import Foundation

public enum TranscriptionEvent: Sendable {
    case started(trackId: String)
    case provisional(segment: TranscriptSegment)
    case committed(segment: TranscriptSegment)
    case error(trackId: String, message: String)
    case closed(trackId: String)
}

public enum STTProviderType: String, CaseIterable, Identifiable, Sendable {
    case appleSpeech = "apple_speech"
    case elevenlabs = "elevenlabs"
    case whisper = "whisper"
    case mock = "mock"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleSpeech:
            return "Apple Speech (macOS Native, On-Device, Free)"
        case .elevenlabs:
            return "ElevenLabs Scribe v2 (Realtime Streaming)"
        case .whisper:
            return "OpenAI / Groq Whisper API"
        case .mock:
            return "Mock / Synthetic STT"
        }
    }
}

public protocol TranscriptionServiceProtocol: Sendable {
    func startSession(meetingId: String, track: AudioTrack) async throws
    func sendAudioChunk(trackId: String, pcmData: Data, sampleCount: Int, offsetMs: Int64) async throws
    func endSession(trackId: String) async throws
    var eventStream: AsyncStream<TranscriptionEvent> { get }
}

