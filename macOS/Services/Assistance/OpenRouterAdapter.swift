import Foundation

public struct GenerateSuggestionRequest: Sendable {
    public let meetingId: String
    public let contextRevision: Int
    public let triggerReason: TriggerReason
    public let recentTranscript: [TranscriptSegment]
    public let sessionTopic: String
    public let relevantExcerpts: [String]
    public let roleToneAndGoals: String
    public let userName: String

    public init(
        meetingId: String,
        contextRevision: Int,
        triggerReason: TriggerReason,
        recentTranscript: [TranscriptSegment],
        sessionTopic: String = "",
        relevantExcerpts: [String] = [],
        roleToneAndGoals: String = "You are an executive copilot helping in high-stakes technical meetings. Provide 1 concise direct answer (25-60 words) and up to 2 distinct alternatives. Never fabricate facts.",
        userName: String = "User"
    ) {
        self.meetingId = meetingId
        self.contextRevision = contextRevision
        self.triggerReason = triggerReason
        self.recentTranscript = recentTranscript
        self.sessionTopic = sessionTopic
        self.relevantExcerpts = relevantExcerpts
        self.roleToneAndGoals = roleToneAndGoals
        self.userName = userName
    }
}

public enum LLMProviderType: String, CaseIterable, Identifiable, Codable, Sendable {
    case openrouter = "openrouter"
    case anthropic = "anthropic"
    case openai = "openai"
    case custom = "custom"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openrouter: return "OpenRouter (Recommended)"
        case .anthropic: return "Anthropic Direct"
        case .openai: return "OpenAI Direct"
        case .custom: return "Custom / Local Endpoint"
        }
    }
}

public typealias LLMProviderAdapter = OpenRouterAdapter

public final class OpenRouterAdapter: @unchecked Sendable {
    public let providerType: LLMProviderType
    public let apiKey: String
    public let customEndpoint: String?
    public let fastModelId: String
    public let deepModelId: String
    public private(set) var lastUsage: (promptTokens: Int, completionTokens: Int)?
    private let session = URLSession(configuration: .default)

    public init(
        providerType: LLMProviderType = .openrouter,
        apiKey: String,
        customEndpoint: String? = nil,
        fastModelId: String = "anthropic/claude-sonnet-5",
        deepModelId: String = "anthropic/claude-sonnet-5"
    ) {
        self.providerType = providerType
        self.apiKey = apiKey
        self.customEndpoint = customEndpoint
        self.fastModelId = fastModelId
        self.deepModelId = deepModelId
    }

    public convenience init(
        apiKey: String,
        fastModelId: String = "anthropic/claude-sonnet-5",
        deepModelId: String = "anthropic/claude-sonnet-5"
    ) {
        self.init(
            providerType: .openrouter,
            apiKey: apiKey,
            customEndpoint: nil,
            fastModelId: fastModelId,
            deepModelId: deepModelId
        )
    }

    /// Extracts valid JSON from raw LLM output, stripping reasoning blocks (e.g. DeepSeek R1, Claude 3.7 with extended thinking) and markdown code fences.
    public static func extractCleanJSON(from rawText: String) -> [String: Any]? {
        var cleaned = rawText
        if let thinkEnd = cleaned.range(of: "</think>") {
            cleaned = String(cleaned[thinkEnd.upperBound...])
        }
        cleaned = cleaned
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let firstBrace = cleaned.firstIndex(of: "{"),
           let lastBrace = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[firstBrace...lastBrace])
        }

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    /// Generates structured response suggestion card with up to 2 meaningful alternatives.
    public func generateSuggestions(
        request: GenerateSuggestionRequest,
        isDeepAnalysis: Bool = false
    ) async throws -> SuggestionCard {
        let startTime = Date()
        let model = isDeepAnalysis ? deepModelId : fastModelId

        // If recent transcript is empty, return an honest waiting/listening card rather than inventing discussion
        if request.recentTranscript.isEmpty {
            return SuggestionCard(
                meetingId: request.meetingId,
                contextRevision: request.contextRevision,
                triggerReason: request.triggerReason,
                detectedTopicOrQuestion: "Waiting for Discussion",
                primaryResponse: SuggestionAlternative(
                    label: "Listening...",
                    text: "Listening for spoken discussion. As soon as participants begin speaking, I will generate strategic responses, answers to questions, and alternatives.",
                    rationale: "Audio capture is active and waiting for conversational speech."
                ),
                alternatives: [
                    SuggestionAlternative(
                        label: "Manual Help",
                        text: "You can also trigger manual assistance anytime with 'Help Me Answer' (Cmd+Shift+H).",
                        rationale: "Shortcut assistance is always available."
                    )
                ],
                evidenceCategory: .basedOnDiscussion,
                modelId: model
            )
        }

        // If mock or empty key, immediately produce high-quality contextual fallback suggestions
        if apiKey.isEmpty || apiKey == "mock" {
            return generateFallbackSuggestions(request: request, model: model)
        }

        let transcriptText = request.recentTranscript.map { "\($0.speakerLabel): \($0.text)" }.joined(separator: "\n")
        let excerptsText = request.relevantExcerpts.joined(separator: "\n---\n")

        let systemPrompt = """
        \(request.roleToneAndGoals)

        CORE INSTRUCTIONS:
        1. YOU ARE AN EXECUTIVE COPILOT GENERATING WHAT \(request.userName.uppercased()) SHOULD SAY OR CONSIDER IN THIS MEETING.
        2. Speak in first-person natural spoken English ("I", "We", "My recommendation is..."). NEVER refer to \(request.userName) in the third person.
        3. Make the primary response direct, sharp, confident, and immediately speakable (25-50 words). No pleasantries or fluff.
        4. Provide up to 2 genuinely distinct alternatives representing different strategic stances:
           - Alternative 1: A clarifying/probing question to ask the other speaker, or a cautious angle.
           - Alternative 2: A counter-proposal, alternative technical design, or risk/tradeoff consideration.
        5. CONVERSATIONAL TURN INFERENCE:
           - If multiple meeting participants appear under the same label (e.g. speakerphone or room audio bleed), infer speaker transitions from conversational turns, questions, and replies.
           - Focus specifically on what \(request.userName) should say next in response to the other speaker(s) to advance the discussion.
        6. RELEVANCE & GROUNDING:
           - Base your primary response directly on the specific questions, proposals, or statements spoken in the recent transcript. Do not ignore what was said or talk about unrelated topics!
           - Only cite retrieved organizational memory facts if they are directly relevant to the specific topic being discussed. Do not force unrelated infrastructure, database, or security facts into unrelated discussions.
        7. Do not fabricate facts, unverified metrics, or commitments. If uncertain, state what needs to be verified.

        OUTPUT FORMAT:
        Output strict raw JSON conforming to this schema (no markdown, no ```json):
        {
          "detectedTopicOrQuestion": "string (the core topic, proposal, or question currently being discussed)",
          "primaryResponse": {
            "label": "Direct Answer | Recommendation | Strategic Position",
            "text": "string (first-person spoken response, concise, 25-50 words, punchy and actionable)",
            "rationale": "string (brief justification for this response)"
          },
          "alternatives": [
            {
              "label": "Clarifying Question | Alternative Approach | Risk Mitigation",
              "text": "string (first-person spoken alternative, distinct angle, 25-50 words)",
              "rationale": "string (brief rationale)"
            }
          ],
          "evidenceCategory": "Supported by source | Based on this discussion | Inference | Needs verification",
          "evidenceQuotes": [
            {
              "sourceTitle": "string",
              "snippet": "string"
            }
          ],
          "uncertaintyNote": "string or null",
          "suggestedFollowUps": ["short follow-up question 1", "short follow-up question 2"]
        }
        """

        let allYou = !request.recentTranscript.isEmpty && request.recentTranscript.allSatisfy { $0.speakerLabel == "You" }
        let turnGuidance = allYou ? """
        CONVERSATIONAL TURN NOTE: All transcript segments currently appear under the label 'You' because system audio capture is operating in single-track microphone mode (remote participants' voices from speakers bled into the physical microphone). Infer conversational turns, questions, and different speakers from the dialogue context. You are acting as the copilot for \(request.userName). Determine what \(request.userName) should say or reply next in response to what the other speaker(s) said!
        """ : ""

        let userPrompt = """
        Active topic: \(request.sessionTopic)
        Trigger reason: \(request.triggerReason.rawValue)
        \(turnGuidance.isEmpty ? "" : "\n" + turnGuidance + "\n")
        Retrieved organizational facts & context:
        \(excerptsText.isEmpty ? "(No external documents matched)" : excerptsText)

        Recent conversation transcript:
        \(transcriptText.isEmpty ? "(No speech recorded yet)" : transcriptText)

        Provide the recommended response and distinct alternatives for \(request.userName) to say now.
        """

        do {
            let urlRequest = try buildURLRequest(
                model: model,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                temperature: 0.25,
                maxTokens: 1000
            )

            let (data, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                return generateFallbackSuggestions(request: request, model: model)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let errBody = String(data: data, encoding: .utf8) ?? ""
                print("[Sidebrief LLM Error] HTTP \(httpResponse.statusCode) from \(providerType.rawValue): \(errBody)")
                return generateFallbackSuggestions(request: request, model: model)
            }

            let latencyMs = Int64(Date().timeIntervalSince(startTime) * 1000.0)

            // Parse response (OpenAI / OpenRouter / Anthropic)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let contentString = Self.extractContentString(from: json) else {
                print("[Sidebrief LLM Error] Failed to extract content string from JSON response")
                return generateFallbackSuggestions(request: request, model: model)
            }

            guard let cardJson = Self.extractCleanJSON(from: contentString) else {
                print("[Sidebrief LLM Error] Failed to extract clean JSON from content: \(contentString)")
                return generateFallbackSuggestions(request: request, model: model)
            }

            var promptTokens: Int?
            var completionTokens: Int?
            if let (p, c) = Self.extractUsageTokens(from: json) {
                promptTokens = p
                completionTokens = c
                self.lastUsage = (promptTokens: p, completionTokens: c)
            }

            let topic = cardJson["detectedTopicOrQuestion"] as? String ?? "Active Discussion"

            // Primary response
            let primaryJson = cardJson["primaryResponse"] as? [String: Any] ?? [:]
            let primary = SuggestionAlternative(
                label: primaryJson["label"] as? String ?? "Direct Answer",
                text: primaryJson["text"] as? String ?? "",
                rationale: primaryJson["rationale"] as? String
            )

            // Alternatives (up to 2)
            var alts: [SuggestionAlternative] = []
            if let rawAlts = cardJson["alternatives"] as? [[String: Any]] {
                for rawAlt in rawAlts.prefix(2) {
                    let alt = SuggestionAlternative(
                        label: rawAlt["label"] as? String ?? "Alternative",
                        text: rawAlt["text"] as? String ?? "",
                        rationale: rawAlt["rationale"] as? String
                    )
                    alts.append(alt)
                }
            }

            // Evidence category
            let evRaw = cardJson["evidenceCategory"] as? String ?? ""
            let evCategory = EvidenceCategory(rawValue: evRaw) ?? .basedOnDiscussion

            // Evidence quotes
            var quotes: [EvidenceQuote] = []
            if let rawQuotes = cardJson["evidenceQuotes"] as? [[String: Any]] {
                for q in rawQuotes {
                    let quote = EvidenceQuote(
                        sourceTitle: q["sourceTitle"] as? String ?? "Meeting Transcript",
                        snippet: q["snippet"] as? String ?? ""
                    )
                    quotes.append(quote)
                }
            }

            let followUps = cardJson["suggestedFollowUps"] as? [String] ?? []
            let uncertainty = cardJson["uncertaintyNote"] as? String

            return SuggestionCard(
                meetingId: request.meetingId,
                contextRevision: request.contextRevision,
                triggerReason: request.triggerReason,
                detectedTopicOrQuestion: topic,
                primaryResponse: primary,
                alternatives: alts,
                evidenceCategory: evCategory,
                evidenceQuotes: quotes,
                uncertaintyNote: uncertainty,
                suggestedFollowUps: followUps,
                state: .current,
                modelId: model,
                latencyMs: latencyMs,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                createdAt: Date()
            )
        } catch {
            return generateFallbackSuggestions(request: request, model: model)
        }
    }

    /// Generates high-quality contextual fallback suggestions when offline or on provider failure.
    public func generateFallbackSuggestions(
        request: GenerateSuggestionRequest,
        model: String
    ) -> SuggestionCard {
        // Find the most recent substantive segment so brief fillers ("Um...", "Yeah.", "Okay.") don't mask the discussion topic
        let targetSegment = request.recentTranscript.reversed().first { AssistanceCoordinator.isSubstantiveSpeech($0.text) } ?? request.recentTranscript.last
        let lastSpeakerText = targetSegment?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let speaker = targetSegment?.speakerLabel ?? "Speaker"

        let isQuestion = AssistanceCoordinator.detectQuestion(in: lastSpeakerText)
        let isDecision = AssistanceCoordinator.detectDecision(in: lastSpeakerText)

        let topic: String
        let primaryLabel: String
        let primaryText: String
        let primaryRationale: String

        let alt1Label: String
        let alt1Text: String
        let alt1Rationale: String

        let alt2Label: String
        let alt2Text: String
        let alt2Rationale: String

        var quotes: [EvidenceQuote] = []
        if !lastSpeakerText.isEmpty {
            let quoteSnippet = lastSpeakerText.count > 120 ? String(lastSpeakerText.prefix(120)) + "..." : lastSpeakerText
            quotes.append(EvidenceQuote(sourceTitle: "\(speaker)'s Statement", snippet: quoteSnippet))
        }

        if lastSpeakerText.isEmpty {
            topic = request.sessionTopic.isEmpty ? "Meeting Discussion" : request.sessionTopic
            primaryLabel = "Strategic Stance"
            primaryText = "Listening for discussion points. When participants raise questions or propose ideas, I'll recommend concise responses and alternatives."
            primaryRationale = "Ready to assist once conversation begins."

            alt1Label = "Proactive Check-in"
            alt1Text = "Should we confirm the main agenda items or priorities before diving deeper into specific topics?"
            alt1Rationale = "Establishes clear alignment early in the meeting."

            alt2Label = "Open Floor"
            alt2Text = "Does anyone have any urgent updates, blockers, or timeline shifts to cover first?"
            alt2Rationale = "Surfaces critical dependencies before general discussion."
        } else if isQuestion {
            let snippet = lastSpeakerText.count > 60 ? String(lastSpeakerText.prefix(60)) + "..." : lastSpeakerText
            topic = "Inquiry from \(speaker)"
            primaryLabel = "Direct Answer"
            primaryText = "Regarding \"\(snippet)\", address the core question directly with immediate context and state next steps or timeline clearly."
            primaryRationale = "Provides a focused, transparent response to \(speaker)'s inquiry."

            alt1Label = "Clarifying Inquiry"
            alt1Text = "Before committing, can we clarify the key dependencies, scope boundaries, or priorities around this?"
            alt1Rationale = "Probes potential risks or assumptions before taking a firm position."

            alt2Label = "Alternative Approach"
            alt2Text = "An alternative approach is to stage this work incrementally, validating the initial phase before full rollout."
            alt2Rationale = "Reduces execution risk while maintaining forward momentum."
        } else if isDecision {
            let snippet = lastSpeakerText.count > 60 ? String(lastSpeakerText.prefix(60)) + "..." : lastSpeakerText
            topic = "Decision on \(snippet)"
            primaryLabel = "Strategic Confirmation"
            primaryText = "Confirm alignment on this decision, establish clear ownership, and set concrete verification milestones."
            primaryRationale = "Solidifies the decision and prevents ambiguity during execution."

            alt1Label = "Risk Check"
            alt1Text = "Let's ensure we evaluate any compliance, contractual, or client-facing impacts before locking this in."
            alt1Rationale = "Protects against downstream surprises or operational friction."

            alt2Label = "Staged Pilot"
            alt2Text = "Can we pilot or test this with a smaller scope first before fully committing resources?"
            alt2Rationale = "Limits downside exposure while verifying initial outcomes."
        } else {
            let snippet = lastSpeakerText.count > 60 ? String(lastSpeakerText.prefix(60)) + "..." : lastSpeakerText
            topic = request.sessionTopic.isEmpty ? "Discussion on \(snippet)" : request.sessionTopic
            primaryLabel = "Recommendation"
            primaryText = "Acknowledge the point on \"\(snippet)\" and propose concrete next actions or owners to keep momentum."
            primaryRationale = "Directly advances the conversation toward actionable outcomes."

            alt1Label = "Probe Priorities"
            alt1Text = "How does this compare in priority against our primary deliverables for this cycle?"
            alt1Rationale = "Keeps team bandwidth focused on highest-leverage commitments."

            alt2Label = "Alternative Angle"
            alt2Text = "Alternatively, should we delegate this investigation and review findings on our next sync?"
            alt2Rationale = "Avoids consuming meeting time on exploratory details."
        }

        return SuggestionCard(
            meetingId: request.meetingId,
            contextRevision: request.contextRevision,
            triggerReason: request.triggerReason,
            detectedTopicOrQuestion: topic,
            primaryResponse: SuggestionAlternative(label: primaryLabel, text: primaryText, rationale: primaryRationale),
            alternatives: [
                SuggestionAlternative(label: alt1Label, text: alt1Text, rationale: alt1Rationale),
                SuggestionAlternative(label: alt2Label, text: alt2Text, rationale: alt2Rationale)
            ],
            evidenceCategory: quotes.isEmpty ? .basedOnDiscussion : .supportedBySource,
            evidenceQuotes: quotes,
            uncertaintyNote: nil,
            suggestedFollowUps: [
                "What is the expected timeline for this?",
                "Are there any security or compliance dependencies?"
            ],
            state: .current,
            modelId: model,
            latencyMs: 75,
            createdAt: Date()
        )
    }

    /// Generates structured post-meeting summary with decisions and action items.
    public func generateSummary(
        meetingId: String,
        allSegments: [TranscriptSegment],
        agenda: String = ""
    ) async throws -> MeetingSummary {
        let transcriptText = allSegments.map { "\($0.speakerLabel): \($0.text)" }.joined(separator: "\n")

        let prompt = """
        You are an executive assistant summarizing a completed technical meeting.
        Agenda: \(agenda)

        Transcript:
        \(transcriptText)

        Generate a strict JSON summary:
        {
          "overview": "string (executive summary of the meeting, 3-5 sentences)",
          "keyPoints": ["point 1", "point 2"],
          "decisions": [
            {
              "title": "string",
              "rationale": "string",
              "status": "confirmed | proposed | rejected",
              "evidenceQuote": "string"
            }
          ],
          "actionItems": [
            {
              "task": "string",
              "assignee": "string or null",
              "dueDate": "string or null",
              "status": "pending | draft",
              "evidenceQuote": "string"
            }
          ],
          "unresolvedQuestions": ["question 1", "question 2"],
          "followUpEmailDraft": "string (ready-to-send draft email to participants)"
        }
        Output raw JSON only without markdown formatting.
        """

        let urlRequest = try buildURLRequest(
            model: deepModelId,
            systemPrompt: "You extract factual meeting summaries, commitments, and decisions without hallucination.",
            userPrompt: prompt,
            temperature: 0.2,
            maxTokens: 2000
        )

        let (data, _) = try await session.data(for: urlRequest)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentString = Self.extractContentString(from: json) else {
            throw NSError(domain: "SidebriefLLM", code: 503, userInfo: [NSLocalizedDescriptionKey: "Failed to generate summary"])
        }

        if let (p, c) = Self.extractUsageTokens(from: json) {
            self.lastUsage = (promptTokens: p, completionTokens: c)
        }

        guard let dict = Self.extractCleanJSON(from: contentString) else {
            throw NSError(domain: "SidebriefLLM", code: 504, userInfo: [NSLocalizedDescriptionKey: "Failed to parse summary JSON"])
        }

        let overview = dict["overview"] as? String ?? ""
        let keyPoints = dict["keyPoints"] as? [String] ?? []

        var decisions: [DecisionItem] = []
        if let rawDecisions = dict["decisions"] as? [[String: Any]] {
            for d in rawDecisions {
                decisions.append(DecisionItem(
                    title: d["title"] as? String ?? "",
                    rationale: d["rationale"] as? String ?? "",
                    status: d["status"] as? String ?? "confirmed",
                    evidenceQuote: d["evidenceQuote"] as? String
                ))
            }
        }

        var actionItems: [ActionItem] = []
        if let rawActions = dict["actionItems"] as? [[String: Any]] {
            for a in rawActions {
                actionItems.append(ActionItem(
                    task: a["task"] as? String ?? "",
                    assignee: a["assignee"] as? String,
                    dueDate: a["dueDate"] as? String,
                    status: a["status"] as? String ?? "draft",
                    evidenceQuote: a["evidenceQuote"] as? String
                ))
            }
        }

        let unresolved = dict["unresolvedQuestions"] as? [String] ?? []
        let emailDraft = dict["followUpEmailDraft"] as? String

        return MeetingSummary(
            meetingId: meetingId,
            version: 1,
            generatingRevision: allSegments.count,
            overview: overview,
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actionItems,
            unresolvedQuestions: unresolved,
            followUpEmailDraft: emailDraft,
            createdAt: Date()
        )
    }

    /// Free-form chat completion scoped to transcript and context.
    public func chat(
        meetingId: String,
        messages: [ChatMessage],
        transcriptContext: [TranscriptSegment]
    ) async throws -> String {
        let transcriptText = transcriptContext.suffix(20).map { "\($0.speakerLabel): \($0.text)" }.joined(separator: "\n")
        let systemPrompt = "You are Sidebrief copilot answering questions during or after a meeting. Recent transcript:\n\(transcriptText)"

        let urlRequest = try buildChatURLRequest(
            model: fastModelId,
            systemPrompt: systemPrompt,
            chatMessages: messages,
            temperature: 0.4
        )

        let (data, _) = try await session.data(for: urlRequest)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentString = Self.extractContentString(from: json) else {
            throw NSError(domain: "SidebriefLLM", code: 505, userInfo: [NSLocalizedDescriptionKey: "Chat completion failed"])
        }

        if let (p, c) = Self.extractUsageTokens(from: json) {
            self.lastUsage = (promptTokens: p, completionTokens: c)
        }

        return contentString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Multi-Provider Network Helpers

    private func buildURLRequest(
        model: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double,
        maxTokens: Int
    ) throws -> URLRequest {
        switch providerType {
        case .openrouter:
            var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Sidebrief", forHTTPHeaderField: "X-Title")
            let payload: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ],
                "temperature": temperature,
                "max_tokens": maxTokens
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            return request

        case .openai:
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ],
                "temperature": temperature,
                "max_tokens": maxTokens
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            return request

        case .custom:
            let endpoint = (customEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? customEndpoint!
                : "http://localhost:11434/v1/chat/completions"
            guard let url = URL(string: endpoint) else {
                throw NSError(domain: "SidebriefLLM", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid custom LLM endpoint URL"])
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !apiKey.isEmpty && apiKey != "mock" {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            let payload: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ],
                "temperature": temperature,
                "max_tokens": maxTokens
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            return request

        case .anthropic:
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload: [String: Any] = [
                "model": model,
                "system": systemPrompt,
                "messages": [
                    ["role": "user", "content": userPrompt]
                ],
                "temperature": temperature,
                "max_tokens": maxTokens
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            return request
        }
    }

    private func buildChatURLRequest(
        model: String,
        systemPrompt: String,
        chatMessages: [ChatMessage],
        temperature: Double
    ) throws -> URLRequest {
        switch providerType {
        case .openrouter, .openai, .custom:
            let url: URL
            switch providerType {
            case .openrouter:
                url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
            case .openai:
                url = URL(string: "https://api.openai.com/v1/chat/completions")!
            default:
                let endpoint = (customEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    ? customEndpoint!
                    : "http://localhost:11434/v1/chat/completions"
                url = URL(string: endpoint) ?? URL(string: "http://localhost:11434/v1/chat/completions")!
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !apiKey.isEmpty && apiKey != "mock" {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            if providerType == .openrouter {
                request.setValue("Sidebrief", forHTTPHeaderField: "X-Title")
            }
            var apiMessages: [[String: String]] = [
                ["role": "system", "content": systemPrompt]
            ]
            for msg in chatMessages {
                apiMessages.append([
                    "role": msg.sender == .user ? "user" : "assistant",
                    "content": msg.text
                ])
            }
            let payload: [String: Any] = [
                "model": model,
                "messages": apiMessages,
                "temperature": temperature
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            return request

        case .anthropic:
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var apiMessages: [[String: String]] = []
            for msg in chatMessages {
                apiMessages.append([
                    "role": msg.sender == .user ? "user" : "assistant",
                    "content": msg.text
                ])
            }
            if apiMessages.isEmpty {
                apiMessages.append(["role": "user", "content": "Hello"])
            }
            let payload: [String: Any] = [
                "model": model,
                "system": systemPrompt,
                "messages": apiMessages,
                "max_tokens": 1024,
                "temperature": temperature
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            return request
        }
    }

    public static func extractContentString(from json: [String: Any]) -> String? {
        if let choices = json["choices"] as? [[String: Any]],
           let firstChoice = choices.first,
           let message = firstChoice["message"] as? [String: Any],
           let contentString = message["content"] as? String {
            return contentString
        }
        if let contentList = json["content"] as? [[String: Any]],
           let firstItem = contentList.first,
           let text = firstItem["text"] as? String {
            return text
        }
        return nil
    }

    public static func extractUsageTokens(from json: [String: Any]) -> (prompt: Int, completion: Int)? {
        if let usage = json["usage"] as? [String: Any] {
            if let p = usage["prompt_tokens"] as? Int, let c = usage["completion_tokens"] as? Int {
                return (p, c)
            }
            if let input = usage["input_tokens"] as? Int, let output = usage["output_tokens"] as? Int {
                return (input, output)
            }
        }
        return nil
    }
}
