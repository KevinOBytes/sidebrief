import Foundation

public final class MockTranscriptionService: TranscriptionServiceProtocol, @unchecked Sendable {
    private let (stream, continuation) = AsyncStream.makeStream(of: TranscriptionEvent.self)
    public var eventStream: AsyncStream<TranscriptionEvent> { stream }

    private var activeTracks: Set<String> = []
    private let queue = DispatchQueue(label: "com.sidebrief.stt.mock", qos: .userInitiated)

    public init() {}

    public func startSession(meetingId: String, track: AudioTrack) async throws {
        _ = queue.sync {
            activeTracks.insert(track.id)
        }
        continuation.yield(.started(trackId: track.id))
    }

    public func sendAudioChunk(trackId: String, pcmData: Data, sampleCount: Int, offsetMs: Int64) async throws {
        // In mock mode, callers can simulate speech by calling simulateSegment
    }

    public func endSession(trackId: String) async throws {
        _ = queue.sync {
            activeTracks.remove(trackId)
        }
        continuation.yield(.closed(trackId: trackId))
    }

    /// Helper for testing / fixtures: emits provisional and then committed transcript segments.
    public func simulateSegment(
        meetingId: String,
        trackId: String,
        speakerLabel: String,
        text: String,
        startMs: Int64,
        endMs: Int64,
        emitProvisionalFirst: Bool = true
    ) {
        if emitProvisionalFirst {
            let prov = TranscriptSegment(
                meetingId: meetingId,
                trackId: trackId,
                providerSegmentId: UUID().uuidString,
                speakerLabel: speakerLabel,
                text: text,
                startOffsetMs: startMs,
                endOffsetMs: endMs,
                isProvisional: true
            )
            continuation.yield(.provisional(segment: prov))
        }

        let committed = TranscriptSegment(
            meetingId: meetingId,
            trackId: trackId,
            providerSegmentId: UUID().uuidString,
            speakerLabel: speakerLabel,
            text: text,
            startOffsetMs: startMs,
            endOffsetMs: endMs,
            isProvisional: false
        )
        continuation.yield(.committed(segment: committed))
    }
}
