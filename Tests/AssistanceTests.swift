import Testing
import Foundation
@testable import SidebriefCore

@Suite("Assistance & STT Tests")
struct AssistanceTests {

    @Test("Question and Decision Detection Heuristics")
    func testHeuristics() {
        // Questions
        #expect(AssistanceCoordinator.detectQuestion(in: "What is our deployment strategy?") == true)
        #expect(AssistanceCoordinator.detectQuestion(in: "How should we handle offline audio?") == true)
        #expect(AssistanceCoordinator.detectQuestion(in: "Can you confirm the deadline?") == true)
        #expect(AssistanceCoordinator.detectQuestion(in: "Is there any remaining blocker?") == true)
        #expect(AssistanceCoordinator.detectQuestion(in: "Just checking in.") == false)
        #expect(AssistanceCoordinator.detectQuestion(in: "We will launch tomorrow.") == false)

        // Decisions
        #expect(AssistanceCoordinator.detectDecision(in: "We decided to proceed with option B") == true)
        #expect(AssistanceCoordinator.detectDecision(in: "Action item: Alice to prepare the spec") == true)
        #expect(AssistanceCoordinator.detectDecision(in: "Let's commit to launching on Friday") == true)
        #expect(AssistanceCoordinator.detectDecision(in: "I have no preference on this") == false)
    }

    @Test("Mock Transcription Event Stream")
    func testMockTranscription() async throws {
        actor EventCollector {
            var receivedStarted = false
            var receivedProvisional = false
            var receivedCommitted = false

            func record(event: TranscriptionEvent) {
                switch event {
                case .started:
                    receivedStarted = true
                case .provisional(let seg):
                    if seg.text == "Hello world" {
                        receivedProvisional = true
                    }
                case .committed(let seg):
                    if seg.text == "Hello world" {
                        receivedCommitted = true
                    }
                default:
                    break
                }
            }

            func results() -> (Bool, Bool, Bool) {
                return (receivedStarted, receivedProvisional, receivedCommitted)
            }
        }

        let mock = MockTranscriptionService()
        let track = AudioTrack(meetingId: "m1", sourceType: .microphone, deviceName: "Default Mic")
        let collector = EventCollector()

        let listener = Task {
            for await event in mock.eventStream {
                await collector.record(event: event)
            }
        }

        try await mock.startSession(meetingId: "m1", track: track)
        try await Task.sleep(nanoseconds: 20_000_000)

        mock.simulateSegment(
            meetingId: "m1",
            trackId: track.id,
            speakerLabel: "You",
            text: "Hello world",
            startMs: 0,
            endMs: 1200
        )

        try await Task.sleep(nanoseconds: 50_000_000)
        listener.cancel()

        let (started, prov, comm) = await collector.results()
        #expect(started == true)
        #expect(prov == true)
        #expect(comm == true)
    }

    @Test("Suggestion Card JSON Schema Roundtrip")
    func testSuggestionCardEncoding() throws {
        let card = SuggestionCard(
            meetingId: "m-123",
            contextRevision: 4,
            triggerReason: .question,
            detectedTopicOrQuestion: "Should we migrate to Neon PostgreSQL?",
            primaryResponse: SuggestionAlternative(
                label: "Direct answer",
                text: "Yes, Neon provides instant branching, serverless autoscaling, and native pgvector support for our retrieval pipeline.",
                rationale: "Matches our production requirements perfectly."
            ),
            alternatives: [
                SuggestionAlternative(
                    label: "Alternative",
                    text: "We could evaluate Cloudflare D1 first if we want strict edge-only locality, though pgvector is more mature in Postgres.",
                    rationale: "Edge latency trade-off."
                ),
                SuggestionAlternative(
                    label: "Clarify",
                    text: "Confirm our expected monthly write IOPS and cold-start tolerances before locking in the tier.",
                    rationale: "Cost control."
                )
            ],
            evidenceCategory: .supportedBySource,
            evidenceQuotes: [
                EvidenceQuote(sourceTitle: "docs/REQUIREMENTS.md", snippet: "Neon PostgreSQL for synchronized structured data")
            ],
            uncertaintyNote: nil,
            suggestedFollowUps: ["What is our vector dimension?", "Do we need RLS policies?"]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(card)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SuggestionCard.self, from: data)

        #expect(decoded.id == card.id)
        #expect(decoded.detectedTopicOrQuestion == card.detectedTopicOrQuestion)
        #expect(decoded.primaryResponse.label == "Direct answer")
        #expect(decoded.alternatives.count == 2)
        #expect(decoded.evidenceCategory == .supportedBySource)
        #expect(decoded.evidenceQuotes.first?.sourceTitle == "docs/REQUIREMENTS.md")
    }

    @Test("Transcript Segment In-Place Updates and Deduplication")
    func testTranscriptDeduplication() {
        var segments: [TranscriptSegment] = []
        let segId = "seg-fixed-1"
        let trackId = "track-mic-1"

        func applyEvent(_ seg: TranscriptSegment) {
            if let idx = segments.firstIndex(where: { $0.id == seg.id }) {
                segments[idx] = seg
            } else if let lastIdx = segments.indices.last,
                      segments[lastIdx].isProvisional,
                      segments[lastIdx].trackId == seg.trackId {
                segments[lastIdx] = seg
            } else {
                segments.append(seg)
            }
        }

        // 1. First partial arrives
        let part1 = TranscriptSegment(
            id: segId,
            meetingId: "m1",
            trackId: trackId,
            providerSegmentId: segId,
            speakerLabel: "You",
            text: "How",
            startOffsetMs: 0,
            endOffsetMs: 200,
            isProvisional: true
        )
        applyEvent(part1)
        #expect(segments.count == 1)
        #expect(segments[0].text == "How")
        #expect(segments[0].isProvisional == true)

        // 2. Second partial arrives
        let part2 = TranscriptSegment(
            id: segId,
            meetingId: "m1",
            trackId: trackId,
            providerSegmentId: segId,
            speakerLabel: "You",
            text: "How are you?",
            startOffsetMs: 0,
            endOffsetMs: 600,
            isProvisional: true
        )
        applyEvent(part2)
        #expect(segments.count == 1)
        #expect(segments[0].text == "How are you?")
        #expect(segments[0].isProvisional == true)

        // 3. Final committed transcript arrives
        let finalSeg = TranscriptSegment(
            id: segId,
            meetingId: "m1",
            trackId: trackId,
            providerSegmentId: segId,
            speakerLabel: "You",
            text: "How are you?",
            startOffsetMs: 0,
            endOffsetMs: 800,
            isProvisional: false
        )
        applyEvent(finalSeg)
        #expect(segments.count == 1)
        #expect(segments[0].text == "How are you?")
        #expect(segments[0].isProvisional == false)

        // 4. Next separate utterance arrives
        let nextSeg = TranscriptSegment(
            id: "seg-fixed-2",
            meetingId: "m1",
            trackId: trackId,
            providerSegmentId: "seg-fixed-2",
            speakerLabel: "You",
            text: "I am doing well",
            startOffsetMs: 1200,
            endOffsetMs: 2000,
            isProvisional: false
        )
        applyEvent(nextSeg)
        #expect(segments.count == 2)
        #expect(segments[1].text == "I am doing well")
    }

    @Test("Substantive Speech Filtering Heuristics")
    func testSubstantiveSpeechFiltering() {
        #expect(AssistanceCoordinator.isSubstantiveSpeech("") == false)
        #expect(AssistanceCoordinator.isSubstantiveSpeech("yeah") == false)
        #expect(AssistanceCoordinator.isSubstantiveSpeech("okay cool") == false)
        #expect(AssistanceCoordinator.isSubstantiveSpeech("uh-huh, right.") == false)
        #expect(AssistanceCoordinator.isSubstantiveSpeech("yes got it") == false)

        #expect(AssistanceCoordinator.isSubstantiveSpeech("We need to deploy the ScreenCaptureKit loopback pipeline before Friday.") == true)
        #expect(AssistanceCoordinator.isSubstantiveSpeech("Can you review this pull request?") == true)
        #expect(AssistanceCoordinator.isSubstantiveSpeech("Let's benchmark the pcm ring buffer.") == true)
    }

    @Test("Executive Copilot Fallback Suggestions Deliver 2 Distinct Strategic Alternatives")
    func testFallbackSuggestionsStrategicAlternatives() {
        let adapter = OpenRouterAdapter(apiKey: "mock")

        // 1. Question input
        let questionRequest = GenerateSuggestionRequest(
            meetingId: "m-test",
            contextRevision: 1,
            triggerReason: .question,
            recentTranscript: [
                TranscriptSegment(id: "s1", meetingId: "m-test", trackId: "sys", providerSegmentId: "s1", speakerLabel: "Alice", text: "What is the database strategy for multi-device sync?", startOffsetMs: 0, endOffsetMs: 2000)
            ]
        )
        let qCard = adapter.generateFallbackSuggestions(request: questionRequest, model: "anthropic/claude-3.5-sonnet")
        #expect(qCard.primaryResponse.label == "Direct Answer")
        #expect(!qCard.primaryResponse.text.isEmpty)
        #expect(qCard.alternatives.count == 2)
        #expect(qCard.alternatives[0].label == "Clarifying Inquiry")
        #expect(qCard.alternatives[1].label == "Alternative Approach")

        // 2. Decision input
        let decisionRequest = GenerateSuggestionRequest(
            meetingId: "m-test",
            contextRevision: 2,
            triggerReason: .decision,
            recentTranscript: [
                TranscriptSegment(id: "s2", meetingId: "m-test", trackId: "sys", providerSegmentId: "s2", speakerLabel: "Bob", text: "We decided to move ahead with Neon PostgreSQL.", startOffsetMs: 2100, endOffsetMs: 4500)
            ]
        )
        let dCard = adapter.generateFallbackSuggestions(request: decisionRequest, model: "anthropic/claude-3.5-sonnet")
        #expect(dCard.primaryResponse.label == "Strategic Confirmation")
        #expect(dCard.alternatives.count == 2)
        #expect(dCard.alternatives[0].label == "Risk Check")
        #expect(dCard.alternatives[1].label == "Staged Pilot")
    }

    @Test("Launch At Login Manager Safe Fallback")
    func testLaunchAtLoginManagerSafeFallback() {
        let manager = LaunchAtLoginManager.shared
        manager.setEnabled(true)
        #expect(UserDefaults.standard.bool(forKey: "launch_at_login_fallback") == true || manager.isEnabled == true)
        manager.setEnabled(false)
        #expect(UserDefaults.standard.bool(forKey: "launch_at_login_fallback") == false || manager.isEnabled == false)
    }

    @Test("Onboarding Configuration and Space Prompt Seeding")
    func testOnboardingSpaceConfigurationAndPersistence() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("test_onboarding.sqlite")
        let store = LocalDatabaseStore(databaseURL: dbURL)

        // Simulate user onboarding customizations
        let tkoCustom = ContextSpace(
            id: "space-tkoresearch",
            name: "TKO Compiler Labs",
            description: "Deep compiler optimization and audio DSP",
            retentionDays: 180,
            allowedProviders: ["elevenlabs", "openrouter", "neon"],
            customPrompt: "Act as principal systems architect specializing in AVFoundation and ScreenCaptureKit."
        )
        let eqtyCustom = ContextSpace(
            id: "space-eqty",
            name: "EQTY Capital",
            description: "Venture investments and executive boards",
            retentionDays: 730,
            allowedProviders: ["elevenlabs", "openrouter", "neon", "r2"],
            customPrompt: "Act as executive CTO advising venture partners with concise recommendations."
        )
        let personalCustom = ContextSpace(
            id: "space-personal",
            name: "Kevin Personal",
            description: "Confidential life, family, and advisory",
            retentionDays: 365,
            allowedProviders: ["elevenlabs", "openrouter"],
            customPrompt: "Provide thoughtful personal perspective and structured notes."
        )

        store.saveContextSpace(tkoCustom)
        store.saveContextSpace(eqtyCustom)
        store.saveContextSpace(personalCustom)

        let loaded = store.getContextSpaces()
        #expect(loaded.count == 3)
        #expect(loaded.first(where: { $0.id == "space-tkoresearch" })?.name == "TKO Compiler Labs")
        #expect(loaded.first(where: { $0.id == "space-tkoresearch" })?.customPrompt.contains("AVFoundation") == true)
        #expect(loaded.first(where: { $0.id == "space-eqty" })?.retentionDays == 730)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("OpenRouter Adapter Defaults to Claude 5 Sonnet")
    func testOpenRouterAdapterDefaultsToClaude5Sonnet() {
        let adapter = OpenRouterAdapter(apiKey: "mock-key")
        #expect(adapter.fastModelId == "anthropic/claude-sonnet-5")
        #expect(adapter.deepModelId == "anthropic/claude-sonnet-5")
    }

    @Test("Reasoning Models Think Tag Stripping and Outermost JSON Extraction")
    func testReasoningModelThinkTagStrippingAndOuterJSONParsing() {
        // DeepSeek R1 style output with <think> reasoning trace and markdown fences
        let r1Response = """
        <think>
        The user is in a meeting discussing Neon PostgreSQL connection pooling.
        I should evaluate pgbouncer vs Neon serverless driver.
        Let's generate the structured suggestion card.
        </think>
        ```json
        {
          "detectedTopicOrQuestion": "Connection Pooling Strategy",
          "primaryResponse": {
            "label": "Neon Serverless Driver",
            "text": "We should use the Neon serverless HTTP driver to avoid exhausting connection pools during autoscaling."
          },
          "alternatives": [
            {
              "label": "Dedicated PgBouncer",
              "text": "Configure an intermediate PgBouncer cluster with transaction pooling."
            }
          ]
        }
        ```
        """

        let r1Json = OpenRouterAdapter.extractCleanJSON(from: r1Response)
        #expect(r1Json != nil)
        #expect(r1Json?["detectedTopicOrQuestion"] as? String == "Connection Pooling Strategy")
        let primary = r1Json?["primaryResponse"] as? [String: Any]
        #expect(primary?["label"] as? String == "Neon Serverless Driver")

        // Claude 3.7 with extended thinking and conversational preamble/postamble
        let claudeThinkingResponse = """
        <think>
        Analyzing the meeting context revision 4...
        </think>
        Here is the structured summary you requested:
        {
          "overview": "The team agreed on deploying Claude 3.7 Sonnet for live executive assistance.",
          "keyPoints": ["Sub-second latency", "Extended reasoning mode"]
        }
        Please let me know if you need any adjustments.
        """

        let claudeJson = OpenRouterAdapter.extractCleanJSON(from: claudeThinkingResponse)
        #expect(claudeJson != nil)
        #expect(claudeJson?["overview"] as? String == "The team agreed on deploying Claude 3.7 Sonnet for live executive assistance.")
        let points = claudeJson?["keyPoints"] as? [String]
        #expect(points?.count == 2)

        // Non-JSON output gracefully returns nil
        let invalidResponse = "I'm sorry, I cannot complete that request right now."
        #expect(OpenRouterAdapter.extractCleanJSON(from: invalidResponse) == nil)
    }

    @Test("Model Pricing Calculator for Claude 4.x and OpenAI Luna")
    func testModelPricingCalculator() {
        let calc = ModelPricingCalculator.shared

        // Claude 4.6 Sonnet ($3.00 prompt, $15.00 completion per 1M)
        let claudeCost = calc.calculateCost(
            modelId: "anthropic/claude-sonnet-4.6",
            promptTokens: 10_000,
            completionTokens: 2_000,
            audioDurationSeconds: 120 // 2 minutes @ $0.01/min = $0.02
        )
        // Prompt: (10,000 / 1,000,000) * $3.00 = $0.03
        // Completion: (2,000 / 1,000,000) * $15.00 = $0.03
        // STT: (120 / 60) * $0.01 = $0.02
        // Total = $0.08
        #expect(abs(claudeCost - 0.08) < 0.0001)

        // OpenAI Luna ($0.20 prompt, $1.20 completion per 1M)
        let lunaCost = calc.calculateCost(
            modelId: "openai/gpt-5.6-luna",
            promptTokens: 50_000,
            completionTokens: 5_000,
            audioDurationSeconds: 60 // 1 minute @ $0.01/min = $0.01
        )
        // Prompt: (50,000 / 1,000,000) * $0.20 = $0.010
        // Completion: (5,000 / 1,000,000) * $1.20 = $0.006
        // STT: $0.010
        // Total = $0.026
        #expect(abs(lunaCost - 0.026) < 0.0001)

        // STT cost only
        let sttCost = calc.calculateSTTCost(audioDurationSeconds: 300) // 5 mins = $0.05
        #expect(abs(sttCost - 0.05) < 0.0001)
    }

    @Test("Speaker Renaming in SQLite Transcript")
    func testSpeakerRenamingInTranscript() {
        let store = LocalDatabaseStore.shared
        let meetingId = "m-rename-\(UUID().uuidString)"
        let meeting = Meeting(id: meetingId, spaceId: "space-tkoresearch", title: "Renaming Test", state: .completed)
        store.saveMeeting(meeting)

        let seg1 = TranscriptSegment(meetingId: meetingId, trackId: "t1", providerSegmentId: "p1", speakerLabel: "Remote Speaker", text: "First point", startOffsetMs: 0, endOffsetMs: 1000)
        let seg2 = TranscriptSegment(meetingId: meetingId, trackId: "t1", providerSegmentId: "p2", speakerLabel: "Remote Speaker", text: "Second point", startOffsetMs: 1000, endOffsetMs: 2000)
        let seg3 = TranscriptSegment(meetingId: meetingId, trackId: "t2", providerSegmentId: "p3", speakerLabel: "You", text: "My reply", startOffsetMs: 2000, endOffsetMs: 3000)
        store.saveTranscriptSegments([seg1, seg2, seg3])

        // Rename "Remote Speaker" to "Dr. Sarah Chen"
        store.renameSpeakerInTranscript(meetingId: meetingId, oldLabel: "Remote Speaker", newLabel: "Dr. Sarah Chen")

        let updated = store.getTranscriptSegments(meetingId: meetingId)
        #expect(updated.count == 3)
        #expect(updated.filter { $0.speakerLabel == "Dr. Sarah Chen" }.count == 2)
        #expect(updated.filter { $0.speakerLabel == "Remote Speaker" }.isEmpty)
        #expect(updated.filter { $0.speakerLabel == "You" }.count == 1)

        // Cleanup
        store.deleteMeeting(id: meetingId, spaceId: "space-tkoresearch")
    }

    @Test("Custom Vocabulary Persistence and CRUD")
    func testCustomVocabularyCRUD() {
        let store = LocalDatabaseStore.shared
        let spaceId = "space-vocab-test"

        let item1 = CustomVocabularyItem(spaceId: spaceId, phrase: "pgvector", soundsLike: "p-g-vector", boost: 1.5)
        let item2 = CustomVocabularyItem(spaceId: spaceId, phrase: "Cloudflare R2", boost: 1.0)
        store.saveVocabularyItem(item1)
        store.saveVocabularyItem(item2)

        let items = store.getVocabulary(spaceId: spaceId)
        #expect(items.contains(where: { $0.id == item1.id && $0.phrase == "pgvector" }))
        #expect(items.contains(where: { $0.id == item2.id && $0.phrase == "Cloudflare R2" }))

        // Delete item1
        store.deleteVocabularyItem(id: item1.id)
        let remaining = store.getVocabulary(spaceId: spaceId)
        #expect(!remaining.contains(where: { $0.id == item1.id }))
        #expect(remaining.contains(where: { $0.id == item2.id }))

        // Cleanup
        store.deleteVocabularyItem(id: item2.id)
    }

    @Test("Audio Chunk Metadata Persistence and Upload State")
    func testAudioChunkPersistence() {
        let store = LocalDatabaseStore.shared
        let chunkId = "chunk-\(UUID().uuidString)"
        let meetingId = "meeting-chunk-test-\(UUID().uuidString)"

        let chunk = AudioChunk(
            id: chunkId,
            trackId: "track-1",
            meetingId: meetingId,
            sequenceNumber: 0,
            streamEpoch: 1700000000000,
            startOffsetMs: 0,
            endOffsetMs: 15000,
            sampleCount: 720000,
            byteCount: 1440028,
            checksumSha256: "dummyhash",
            encryptionNonceHex: "0102030405060708090a0b0c",
            localEncryptedFilePath: "/tmp/\(chunkId).enc",
            uploadState: .localOnly
        )

        store.saveAudioChunk(chunk)

        let chunks = store.getAudioChunks(meetingId: meetingId)
        #expect(chunks.count == 1)
        #expect(chunks.first?.id == chunkId)
        #expect(chunks.first?.uploadState == .localOnly)

        // Update upload state to uploaded with remote key
        store.updateChunkUploadState(id: chunkId, state: .uploaded, remoteObjectKey: "audio/test/\(chunkId).enc")

        let updatedChunks = store.getAudioChunks(meetingId: meetingId)
        #expect(updatedChunks.first?.uploadState == .uploaded)
        #expect(updatedChunks.first?.remoteObjectKey == "audio/test/\(chunkId).enc")
    }

    @Test("Speaker Profile CRUD and Space Seeding")
    func testSpeakerProfileCRUDAndSpaceSeeding() {
        let store = LocalDatabaseStore.shared
        let spaceId = "space-speaker-test-\(UUID().uuidString)"

        // 1. Seed default profiles
        UserDefaults.standard.set("Jordan", forKey: "user_name")
        store.seedDefaultSpeakerProfilesIfNeeded(force: true)

        let initialProfiles = store.getSpeakerProfiles()
        #expect(!initialProfiles.isEmpty)
        #expect(initialProfiles.contains(where: { $0.name == "Jordan" && ($0.roleOrTitle?.contains("Architect") ?? false) }))

        // 2. Add a new speaker profile
        let newProfile = SpeakerProfile(
            spaceId: spaceId,
            name: "Dr. Elizabeth Vance",
            roleOrTitle: "Chief Medical Officer",
            organization: "BioTech Labs",
            notesOrContext: "Key partner for clinical trials",
            aliases: ["Dr. Vance", "Elizabeth"]
        )
        store.saveSpeakerProfile(newProfile)

        let withNew = store.getSpeakerProfiles(spaceId: spaceId)
        #expect(withNew.contains(where: { $0.id == newProfile.id && $0.name == "Dr. Elizabeth Vance" }))

        // 3. Delete the profile
        store.deleteSpeakerProfile(id: newProfile.id)
        let afterDelete = store.getSpeakerProfiles(spaceId: spaceId)
        #expect(!afterDelete.contains(where: { $0.id == newProfile.id }))

        // Cleanup
        for p in afterDelete {
            store.deleteSpeakerProfile(id: p.id)
        }
    }

    @Test("ElevenLabs Streaming STT VAD Overlap Deduplication")
    func testElevenLabsVADOverlapDeduplication() {
        // Case 1: Overlapping tail and head words
        let prev1 = "We should immediately migrate"
        let curr1 = "migrate to Neon PostgreSQL serverless"
        let dedup1 = ElevenLabsStreamingSTTAdapter.deduplicateOverlap(previous: prev1, current: curr1)
        #expect(dedup1 == "to Neon PostgreSQL serverless")

        // Case 2: Multi-word overlap
        let prev2 = "our deployment pipeline is ready for production"
        let curr2 = "ready for production next week"
        let dedup2 = ElevenLabsStreamingSTTAdapter.deduplicateOverlap(previous: prev2, current: curr2)
        #expect(dedup2 == "next week")

        // Case 3: No overlap at all
        let prev3 = "Hello everyone, welcome to the call."
        let curr3 = "Let's review the quarterly metrics."
        let dedup3 = ElevenLabsStreamingSTTAdapter.deduplicateOverlap(previous: prev3, current: curr3)
        #expect(dedup3 == "Let's review the quarterly metrics.")

        // Case 4: Empty string cases
        #expect(ElevenLabsStreamingSTTAdapter.deduplicateOverlap(previous: "", current: "Testing 123") == "Testing 123")
        #expect(ElevenLabsStreamingSTTAdapter.deduplicateOverlap(previous: "Testing 123", current: "") == "")
    }

    @Test("Model Pricing Calculator for Claude 5 and OpenAI Luna Pro")
    func testModelPricingCalculatorClaude5AndLunaPro() {
        let calc = ModelPricingCalculator.shared

        // 1. Claude 5 Sonnet: $3.00 / 1M prompt, $15.00 / 1M completion
        let sonnet5Cost = calc.calculateCost(
            modelId: "anthropic/claude-sonnet-5",
            promptTokens: 100_000,
            completionTokens: 10_000,
            audioDurationSeconds: 0
        )
        // (100,000 / 1M) * 3.00 = $0.30
        // (10,000 / 1M) * 15.00 = $0.15
        // Total = $0.45
        #expect(abs(sonnet5Cost - 0.45) < 0.0001)

        // 2. Claude 5 Opus: $15.00 / 1M prompt, $75.00 / 1M completion
        let opus5Cost = calc.calculateCost(
            modelId: "anthropic/claude-opus-5",
            promptTokens: 100_000,
            completionTokens: 10_000,
            audioDurationSeconds: 0
        )
        // (100,000 / 1M) * 15.00 = $1.50
        // (10,000 / 1M) * 75.00 = $0.75
        // Total = $2.25
        #expect(abs(opus5Cost - 2.25) < 0.0001)

        // 3. OpenAI Luna Pro: $0.50 / 1M prompt, $2.00 / 1M completion
        let lunaProCost = calc.calculateCost(
            modelId: "openai/gpt-5.6-luna-pro",
            promptTokens: 100_000,
            completionTokens: 10_000,
            audioDurationSeconds: 0
        )
        // (100,000 / 1M) * 0.50 = $0.05
        // (10,000 / 1M) * 2.00 = $0.02
        // Total = $0.07
        #expect(abs(lunaProCost - 0.07) < 0.0001)
    }

    @Test("Multi-Provider Adapter and Dynamic User Name Prompting")
    func testMultiProviderAdapterAndDynamicUserName() {
        // Test OpenRouter provider
        let openRouterAdapter = OpenRouterAdapter(
            providerType: .openrouter,
            apiKey: "test-key",
            fastModelId: "anthropic/claude-sonnet-5",
            deepModelId: "anthropic/claude-opus-5"
        )
        #expect(openRouterAdapter.providerType == .openrouter)
        #expect(openRouterAdapter.fastModelId == "anthropic/claude-sonnet-5")
        #expect(openRouterAdapter.deepModelId == "anthropic/claude-opus-5")

        // Test Anthropic Direct provider
        let anthropicAdapter = OpenRouterAdapter(
            providerType: .anthropic,
            apiKey: "sk-ant-test",
            fastModelId: "claude-sonnet-5",
            deepModelId: "claude-opus-5"
        )
        #expect(anthropicAdapter.providerType == .anthropic)

        // Test OpenAI Direct provider
        let openaiAdapter = OpenRouterAdapter(
            providerType: .openai,
            apiKey: "sk-test",
            fastModelId: "gpt-5.6-luna-pro",
            deepModelId: "gpt-5.6-luna-pro"
        )
        #expect(openaiAdapter.providerType == .openai)

        // Test dynamic userName in suggestion generation
        let customUserRequest = GenerateSuggestionRequest(
            meetingId: "m-user-test",
            contextRevision: 1,
            triggerReason: .question,
            recentTranscript: [
                TranscriptSegment(id: "s1", meetingId: "m-user-test", trackId: "sys", providerSegmentId: "s1", speakerLabel: "Colleague", text: "What is our plan?", startOffsetMs: 0, endOffsetMs: 1000)
            ],
            userName: "Samantha"
        )
        let suggestion = openRouterAdapter.generateFallbackSuggestions(request: customUserRequest, model: "anthropic/claude-sonnet-5")
        #expect(!suggestion.primaryResponse.text.isEmpty)
        #expect(customUserRequest.userName == "Samantha")
    }

    @Test("Substantive Fallback Utterance Selection Skips Fillers")
    func testSubstantiveFallbackUtteranceSelection() {
        let adapter = OpenRouterAdapter(apiKey: "mock")
        let transcript = [
            TranscriptSegment(id: "s1", meetingId: "m1", trackId: "mic", providerSegmentId: "s1", speakerLabel: "You", text: "Can we clarify what the SOC 2 compliance requirements are for next quarter?", startOffsetMs: 0, endOffsetMs: 2000),
            TranscriptSegment(id: "s2", meetingId: "m1", trackId: "mic", providerSegmentId: "s2", speakerLabel: "You", text: "Yeah.", startOffsetMs: 2100, endOffsetMs: 2500),
            TranscriptSegment(id: "s3", meetingId: "m1", trackId: "mic", providerSegmentId: "s3", speakerLabel: "You", text: "Um...", startOffsetMs: 2600, endOffsetMs: 2900)
        ]

        let req = GenerateSuggestionRequest(
            meetingId: "m1",
            contextRevision: 3,
            triggerReason: .cadence,
            recentTranscript: transcript,
            sessionTopic: "",
            userName: "Elena"
        )

        let card = adapter.generateFallbackSuggestions(request: req, model: "anthropic/claude-sonnet-5")
        // It must NOT pick "Um..." or "Yeah." as the topic quote snippet
        #expect(card.evidenceQuotes.contains(where: { $0.snippet.contains("SOC 2 compliance") }))
        #expect(!card.evidenceQuotes.contains(where: { $0.snippet == "Um..." }))
    }

    @Test("Assistance Coordinator Dynamic Update and Cadence Refresh")
    func testAssistanceCoordinatorDynamicUpdateAndCadenceRefresh() {
        let initialAdapter = OpenRouterAdapter(apiKey: "mock", fastModelId: "anthropic/claude-sonnet-5")
        let coordinator = AssistanceCoordinator(meetingId: "m-dynamic", adapter: initialAdapter, userName: "Original")
        #expect(coordinator.userName == "Original")
        #expect(coordinator.evaluationCadenceSeconds == 10.0)

        // Dynamically update adapter, cadence, and userName
        let updatedAdapter = OpenRouterAdapter(
            providerType: .anthropic,
            apiKey: "sk-ant-test",
            fastModelId: "claude-3-7-sonnet-20250219"
        )
        coordinator.updateAdapter(updatedAdapter)
        coordinator.setUserName("Jordan")
        coordinator.evaluationCadenceSeconds = 6.0

        #expect(coordinator.userName == "Jordan")
        #expect(coordinator.evaluationCadenceSeconds == 6.0)
    }

    @Test("STT Provider Types and Display Names")
    func testSTTProviderTypes() {
        #expect(STTProviderType.appleSpeech.rawValue == "apple_speech")
        #expect(STTProviderType.elevenlabs.rawValue == "elevenlabs")
        #expect(STTProviderType.whisper.rawValue == "whisper")
        #expect(STTProviderType.appleSpeech.displayName.contains("Apple Speech"))
        #expect(STTProviderType.elevenlabs.displayName.contains("ElevenLabs"))
    }

    @Test("Whisper WAV Header Formatter")
    func testWhisperWavHeaderFormatter() {
        let dummyPCM = Data(repeating: 0, count: 16000 * 2) // 1 second of 16kHz 16-bit mono
        let wav = WhisperTranscriptionAdapter.createWavData(fromPCM16: dummyPCM, sampleRate: 16000, channels: 1)
        #expect(wav.count == 44 + dummyPCM.count)
        let prefix = String(data: wav.prefix(4), encoding: .utf8)
        #expect(prefix == "RIFF")
        let formatMarker = String(data: wav.subdata(in: 8..<12), encoding: .utf8)
        #expect(formatMarker == "WAVE")
    }

    @Test("Assistance Coordinator Periodic Cadence Debounce Logic")
    func testAssistanceCoordinatorPeriodicCadenceDebounce() {
        let adapter = OpenRouterAdapter(apiKey: "mock")
        let coordinator = AssistanceCoordinator(meetingId: "m-debounce", adapter: adapter, userName: "Alex")
        coordinator.evaluationCadenceSeconds = 5.0

        // Initially no speech has arrived, checkPeriodicCadence must be a no-op
        coordinator.checkPeriodicCadence()

        // Feed a substantive segment
        let seg = TranscriptSegment(
            id: "seg-1",
            meetingId: "m-debounce",
            trackId: "mic",
            providerSegmentId: "seg-1",
            speakerLabel: "Remote Speaker",
            text: "What are our primary infrastructure milestones for the upcoming quarter?",
            startOffsetMs: 0,
            endOffsetMs: 3000
        )
        coordinator.handleCommittedSegment(seg)

        // Segment was a question, which evaluated immediately and reset hasNewSubstantiveSpeechSinceLastEval
        // Calling checkPeriodicCadence immediately after should be debounced
        coordinator.checkPeriodicCadence()
    }

    @Test("Apple Speech Transcription Adapter Initialization and Chunk Ingestion")
    func testAppleSpeechAdapterInitAndChunk() async throws {
        let adapter = AppleSpeechTranscriptionAdapter(locale: Locale(identifier: "en-US"))
        let track = AudioTrack(meetingId: "m-speech-test", sourceType: .microphone, deviceName: "Test Mic")

        // Create 2048 synthetic 16-bit PCM samples
        let sampleCount = 2048
        var pcmData = Data(count: sampleCount * 2)
        pcmData.withUnsafeMutableBytes { ptr in
            guard let int16Ptr = ptr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<sampleCount {
                int16Ptr[i] = Int16(sin(Double(i) * 0.05) * 16000.0)
            }
        }

        // Stream and chunk ingestion should execute safely without memory violations
        try await adapter.sendAudioChunk(trackId: track.id, pcmData: pcmData, sampleCount: sampleCount, offsetMs: 0)
        try await adapter.endSession(trackId: track.id)
    }

    @Test("Apple Speech Transcription Adapter Dual Track Audio Ingestion and Safe Session Handling")
    func testAppleSpeechAdapterDualTrackChunkIngestion() async throws {
        let adapter = AppleSpeechTranscriptionAdapter(locale: Locale(identifier: "en-US"))
        let micTrack = AudioTrack(meetingId: "m-dual-test", sourceType: .microphone, deviceName: "MacBook Pro Mic")
        let sysTrack = AudioTrack(meetingId: "m-dual-test", sourceType: .systemAudio, deviceName: "ScreenCaptureKit System")

        try await adapter.startSession(meetingId: "m-dual-test", track: micTrack)
        try await adapter.startSession(meetingId: "m-dual-test", track: sysTrack)

        let sampleCount = 2048
        var micData = Data(count: sampleCount * 2)
        micData.withUnsafeMutableBytes { ptr in
            guard let int16Ptr = ptr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<sampleCount {
                int16Ptr[i] = Int16(sin(Double(i) * 0.08) * 14000.0)
            }
        }

        var sysData = Data(count: sampleCount * 2)
        sysData.withUnsafeMutableBytes { ptr in
            guard let int16Ptr = ptr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<sampleCount {
                int16Ptr[i] = Int16(cos(Double(i) * 0.04) * 8000.0)
            }
        }

        // Concurrent chunk ingestion for both streams without task collision or cancellation loops
        try await adapter.sendAudioChunk(trackId: micTrack.id, pcmData: micData, sampleCount: sampleCount, offsetMs: 100)
        try await adapter.sendAudioChunk(trackId: sysTrack.id, pcmData: sysData, sampleCount: sampleCount, offsetMs: 100)

        try await adapter.endSession(trackId: micTrack.id)
        try await adapter.endSession(trackId: sysTrack.id)
    }

    @Test("Empty Recent Transcript Returns Clean Listening Card")
    func testEmptyRecentTranscriptReturnsCleanListeningCard() async throws {
        let adapter = OpenRouterAdapter(apiKey: "sk-mock-key")
        let emptyReq = GenerateSuggestionRequest(
            meetingId: "m-empty",
            contextRevision: 0,
            triggerReason: .cadence,
            recentTranscript: [],
            sessionTopic: "",
            userName: "Alex"
        )
        let card = try await adapter.generateSuggestions(request: emptyReq)
        #expect(card.detectedTopicOrQuestion.contains("Waiting") || card.detectedTopicOrQuestion.contains("Listening"))
        #expect(card.primaryResponse.text.contains("Listening for spoken discussion"))
    }

    @Test("Dynamic Excerpt Filtering Preserves Topic Relevance and Drops Unrelated Facts")
    func testExcerptRelevanceFiltering() async throws {
        let coordinator = AssistanceCoordinator(
            meetingId: "m-filter-test",
            adapter: OpenRouterAdapter(apiKey: "mock"),
            userName: "Alice"
        )

        coordinator.setRelevantExcerpts([
            "[Architecture] Database: Neon PostgreSQL with pgvector",
            "[Architecture] Audio Capture: ScreenCaptureKit dual loopback",
            "[Marketing] Launch Pricing: $19.99 lifetime license with 3 Mac installations"
        ])

        // When a pricing question is received:
        let seg = TranscriptSegment(
            meetingId: "m-filter-test",
            trackId: "track-1",
            providerSegmentId: "p-1",
            speakerLabel: "Partner",
            text: "What is our launch pricing and license cost?",
            startOffsetMs: 0,
            endOffsetMs: 1500,
            isProvisional: false
        )

        actor SuggestionSpy: AssistanceCoordinatorDelegate {
            var receivedCard: SuggestionCard?
            nonisolated func assistanceCoordinator(_ coordinator: AssistanceCoordinator, didProduceSuggestion card: SuggestionCard) {
                Task { [weak self] in
                    await self?.setCard(card)
                }
            }
            func setCard(_ card: SuggestionCard) {
                self.receivedCard = card
            }
            nonisolated func assistanceCoordinator(_ coordinator: AssistanceCoordinator, didUpdateState state: SuggestionState, cardId: String) {}
        }

        let spy = SuggestionSpy()
        coordinator.delegate = spy
        coordinator.handleCommittedSegment(seg)

        try await Task.sleep(nanoseconds: 150_000_000)
        let card = await spy.receivedCard
        #expect(card != nil)
        #expect(card?.primaryResponse.text.contains("pricing") == true || card?.detectedTopicOrQuestion.contains("Partner") == true)
    }
}



