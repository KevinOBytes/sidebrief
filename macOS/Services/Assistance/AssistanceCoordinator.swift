import Foundation

public protocol AssistanceCoordinatorDelegate: AnyObject, Sendable {
    func assistanceCoordinator(_ coordinator: AssistanceCoordinator, didProduceSuggestion card: SuggestionCard)
    func assistanceCoordinator(_ coordinator: AssistanceCoordinator, didUpdateState state: SuggestionState, cardId: String)
    func assistanceCoordinator(_ coordinator: AssistanceCoordinator, didUpdateTokenUsage usage: TokenUsage)
}

public extension AssistanceCoordinatorDelegate {
    func assistanceCoordinator(_ coordinator: AssistanceCoordinator, didUpdateTokenUsage usage: TokenUsage) {}
}

public final class AssistanceCoordinator: @unchecked Sendable {
    public weak var delegate: AssistanceCoordinatorDelegate?

    private var adapter: OpenRouterAdapter
    private let meetingId: String
    private var contextRevision: Int = 0

    private var recentTranscript: [TranscriptSegment] = []
    private var activeProvisionalSegment: TranscriptSegment?
    private var activeTopic: String = "Meeting In Progress"
    private var roleToneAndGoals: String
    public var userName: String = "User"
    private var customVocabulary: [CustomVocabularyItem] = []
    private var speakerProfiles: [SpeakerProfile] = []
    public private(set) var tokenUsage: TokenUsage = TokenUsage()

    // Cadence & Scheduling
    public var evaluationCadenceSeconds: TimeInterval = 10.0 // 8-12 seconds default
    private var lastEvaluationTime: Date = Date.distantPast
    private var isGenerating = false
    private var hasNewSubstantiveSpeechSinceLastEval = false
    private var currentTask: Task<Void, Never>?

    // Context & History
    private var currentSuggestion: SuggestionCard?
    private var pinnedSuggestionId: String?
    private var relevantExcerpts: [String] = []

    private let queue = DispatchQueue(label: "com.sidebrief.assistance.coordinator", qos: .userInitiated)

    public init(
        meetingId: String,
        adapter: OpenRouterAdapter,
        roleToneAndGoals: String = "You are an executive copilot helping in high-stakes technical meetings. Provide 1 concise direct answer (25-60 words) and up to 2 distinct alternatives. Never fabricate facts.",
        userName: String = "User"
    ) {
        self.meetingId = meetingId
        self.adapter = adapter
        self.roleToneAndGoals = roleToneAndGoals
        self.userName = userName
    }

    public func updateAdapter(_ newAdapter: OpenRouterAdapter) {
        queue.sync {
            self.adapter = newAdapter
        }
    }

    public func setUserName(_ name: String) {
        queue.sync {
            self.userName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "User" : name
        }
    }

    public func setRelevantExcerpts(_ excerpts: [String]) {
        queue.sync {
            self.relevantExcerpts = excerpts
        }
    }

    public func setCustomVocabulary(_ items: [CustomVocabularyItem]) {
        queue.sync {
            self.customVocabulary = items
        }
    }

    public func setSpeakerProfiles(_ profiles: [SpeakerProfile]) {
        queue.sync {
            self.speakerProfiles = profiles
        }
    }

    public func setRoleToneAndGoals(_ goals: String) {
        queue.sync {
            self.roleToneAndGoals = goals
        }
    }

    public func updateAudioDuration(seconds: Double) {
        queue.sync {
            self.tokenUsage.audioDurationSeconds = seconds
            let llmCost = ModelPricingCalculator.shared.calculateLLMCost(
                modelId: adapter.fastModelId,
                promptTokens: tokenUsage.promptTokens,
                completionTokens: tokenUsage.completionTokens
            )
            let sttCost = ModelPricingCalculator.shared.calculateSTTCost(audioDurationSeconds: seconds)
            self.tokenUsage.estimatedCostUSD = llmCost + sttCost
        }
        delegate?.assistanceCoordinator(self, didUpdateTokenUsage: tokenUsage)
    }

    /// Safely builds current transcript snapshot including any uncommitted provisional utterance
    private func currentTranscriptSnapshot_locked() -> [TranscriptSegment] {
        var snapshot = recentTranscript
        if let prov = activeProvisionalSegment, !prov.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            snapshot.append(prov)
        }
        return snapshot
    }

    /// Handles incoming provisional transcript segment so manual help and questions have immediate access to spoken words without waiting for silence timeouts.
    public func handleProvisionalSegment(_ segment: TranscriptSegment) {
        queue.sync {
            self.activeProvisionalSegment = segment
            let isQuestion = Self.detectQuestion(in: segment.text)
            let isDecision = Self.detectDecision(in: segment.text)
            let isSubstantive = Self.isSubstantiveSpeech(segment.text)
            if isSubstantive || isQuestion || isDecision {
                self.hasNewSubstantiveSpeechSinceLastEval = true
            }
        }
    }

    /// Handles incoming committed transcript segments.
    public func handleCommittedSegment(_ segment: TranscriptSegment) {
        struct EvalContext {
            let shouldTrigger: Bool
            let triggerReason: TriggerReason
            let revision: Int
            let transcriptSnapshot: [TranscriptSegment]
            let topic: String
            let excerpts: [String]
            let goals: String
        }

        let ctx: EvalContext? = queue.sync {
            contextRevision += 1
            activeProvisionalSegment = nil
            recentTranscript.append(segment)

            // Keep rolling transcript window (e.g. last 40 segments or ~120 seconds)
            if recentTranscript.count > 40 {
                recentTranscript.removeFirst(recentTranscript.count - 40)
            }

            let isQuestion = Self.detectQuestion(in: segment.text)
            let isDecision = Self.detectDecision(in: segment.text)
            let isSubstantive = Self.isSubstantiveSpeech(segment.text)
            if isSubstantive || isQuestion || isDecision {
                hasNewSubstantiveSpeechSinceLastEval = true
            }
            let now = Date()
            let timeSinceLastEval = now.timeIntervalSince(lastEvaluationTime)

            var trigger: TriggerReason?
            if isQuestion {
                trigger = .question
            } else if isDecision {
                trigger = .decision
            } else if timeSinceLastEval >= evaluationCadenceSeconds && isSubstantive {
                trigger = .cadence
            }

            guard let triggerReason = trigger else {
                return nil
            }

            if isGenerating && (triggerReason == .question || triggerReason == .decision) {
                currentTask?.cancel()
                isGenerating = false
            }

            guard !isGenerating else {
                return nil
            }

            isGenerating = true
            lastEvaluationTime = now
            hasNewSubstantiveSpeechSinceLastEval = false

            let snapshot = currentTranscriptSnapshot_locked()
            return EvalContext(
                shouldTrigger: true,
                triggerReason: triggerReason,
                revision: contextRevision,
                transcriptSnapshot: snapshot,
                topic: activeTopic,
                excerpts: filterRelevantExcerpts(for: snapshot),
                goals: formattedGoalsWithContext(roleToneAndGoals)
            )
        }

        guard let eval = ctx else { return }

        currentTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let req = GenerateSuggestionRequest(
                    meetingId: self.meetingId,
                    contextRevision: eval.revision,
                    triggerReason: eval.triggerReason,
                    recentTranscript: eval.transcriptSnapshot,
                    sessionTopic: eval.topic,
                    relevantExcerpts: eval.excerpts,
                    roleToneAndGoals: eval.goals,
                    userName: self.userName
                )

                let card = try await self.adapter.generateSuggestions(request: req)

                var prevCardIdToSupersede: String?
                self.queue.sync {
                    self.isGenerating = false
                    if let prev = self.currentSuggestion, prev.id != self.pinnedSuggestionId {
                        prevCardIdToSupersede = prev.id
                    }
                    self.currentSuggestion = card
                }

                self.recordUsage(from: card)

                if let prevId = prevCardIdToSupersede {
                    self.delegate?.assistanceCoordinator(self, didUpdateState: .superseded, cardId: prevId)
                }

                self.delegate?.assistanceCoordinator(self, didProduceSuggestion: card)
            } catch {
                self.queue.sync {
                    self.isGenerating = false
                }
            }
        }
    }

    /// Checks whether substantive speech has accumulated and evaluation cadence has passed.
    public func checkPeriodicCadence() {
        struct EvalContext {
            let revision: Int
            let transcriptSnapshot: [TranscriptSegment]
            let topic: String
            let excerpts: [String]
            let goals: String
        }

        let ctx: EvalContext? = queue.sync {
            guard hasNewSubstantiveSpeechSinceLastEval else { return nil }
            let now = Date()
            let timeSinceLastEval = now.timeIntervalSince(lastEvaluationTime)
            guard timeSinceLastEval >= evaluationCadenceSeconds else { return nil }
            guard !isGenerating else { return nil }
            guard !recentTranscript.isEmpty || activeProvisionalSegment != nil else { return nil }

            isGenerating = true
            lastEvaluationTime = now
            hasNewSubstantiveSpeechSinceLastEval = false

            let snapshot = currentTranscriptSnapshot_locked()
            return EvalContext(
                revision: contextRevision,
                transcriptSnapshot: snapshot,
                topic: activeTopic,
                excerpts: filterRelevantExcerpts(for: snapshot),
                goals: formattedGoalsWithContext(roleToneAndGoals)
            )
        }

        guard let eval = ctx else { return }

        currentTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let req = GenerateSuggestionRequest(
                    meetingId: self.meetingId,
                    contextRevision: eval.revision,
                    triggerReason: .cadence,
                    recentTranscript: eval.transcriptSnapshot,
                    sessionTopic: eval.topic,
                    relevantExcerpts: eval.excerpts,
                    roleToneAndGoals: eval.goals,
                    userName: self.userName
                )

                let card = try await self.adapter.generateSuggestions(request: req)

                var prevCardIdToSupersede: String?
                self.queue.sync {
                    self.isGenerating = false
                    if let prev = self.currentSuggestion, prev.id != self.pinnedSuggestionId {
                        prevCardIdToSupersede = prev.id
                    }
                    self.currentSuggestion = card
                }

                self.recordUsage(from: card)

                if let prevId = prevCardIdToSupersede {
                    self.delegate?.assistanceCoordinator(self, didUpdateState: .superseded, cardId: prevId)
                }

                self.delegate?.assistanceCoordinator(self, didProduceSuggestion: card)
            } catch {
                self.queue.sync {
                    self.isGenerating = false
                }
            }
        }
    }

    /// Preempts automatic generation immediately for manual "Help me answer" shortcut.
    public func requestImmediateHelp(passage: String? = nil) {
        struct HelpContext {
            let revision: Int
            let transcriptSnapshot: [TranscriptSegment]
            let topic: String
            let excerpts: [String]
            let goals: String
        }

        let ctx: HelpContext = queue.sync {
            currentTask?.cancel()
            isGenerating = true
            lastEvaluationTime = Date()
            contextRevision += 1

            let snapshot = currentTranscriptSnapshot_locked()
            return HelpContext(
                revision: contextRevision,
                transcriptSnapshot: snapshot,
                topic: passage ?? activeTopic,
                excerpts: filterRelevantExcerpts(for: snapshot),
                goals: formattedGoalsWithContext(roleToneAndGoals)
            )
        }

        currentTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let req = GenerateSuggestionRequest(
                    meetingId: self.meetingId,
                    contextRevision: ctx.revision,
                    triggerReason: .shortcut,
                    recentTranscript: ctx.transcriptSnapshot,
                    sessionTopic: ctx.topic,
                    relevantExcerpts: ctx.excerpts,
                    roleToneAndGoals: ctx.goals,
                    userName: self.userName
                )

                let card = try await self.adapter.generateSuggestions(request: req)

                self.queue.sync {
                    self.isGenerating = false
                    self.currentSuggestion = card
                }

                self.recordUsage(from: card)
                self.delegate?.assistanceCoordinator(self, didProduceSuggestion: card)
            } catch {
                self.queue.sync {
                    self.isGenerating = false
                }
            }
        }
    }

    private func formattedGoalsWithContext(_ baseGoals: String) -> String {
        var contextStr = baseGoals

        let externalProfiles = speakerProfiles.filter { profile in
            profile.name.lowercased() != userName.lowercased() && !profile.aliases.contains("You")
        }
        if !externalProfiles.isEmpty {
            let profilesList = externalProfiles.map { profile in
                var desc = "- \(profile.name)"
                if let role = profile.roleOrTitle, !role.isEmpty {
                    desc += " (\(role)"
                    if let org = profile.organization, !org.isEmpty {
                        desc += ", \(org)"
                    }
                    desc += ")"
                } else if let org = profile.organization, !org.isEmpty {
                    desc += " (\(org))"
                }
                if let notes = profile.notesOrContext, !notes.isEmpty {
                    desc += ": \(notes)"
                }
                return desc
            }.joined(separator: "\n")
            contextStr += "\n\nKNOWN PARTICIPANTS & ROLES:\n\(profilesList)"
        }

        if !customVocabulary.isEmpty {
            let vocabList = customVocabulary.map { item in
                if let sounds = item.soundsLike, !sounds.isEmpty {
                    return "- \(item.phrase) (sounds like: \(sounds))"
                } else {
                    return "- \(item.phrase)"
                }
            }.joined(separator: "\n")
            contextStr += "\n\nCustom Domain Vocabulary & Technical Terms (preserve exact spelling and capitalization):\n\(vocabList)"
        }

        return contextStr
    }

    private func recordUsage(from card: SuggestionCard) {
        if let p = card.promptTokens, let c = card.completionTokens {
            self.queue.sync {
                self.tokenUsage.promptTokens += p
                self.tokenUsage.completionTokens += c
                self.tokenUsage.totalTokens = self.tokenUsage.promptTokens + self.tokenUsage.completionTokens
                self.tokenUsage.queryCount += 1
                let llmCost = ModelPricingCalculator.shared.calculateLLMCost(
                    modelId: card.modelId,
                    promptTokens: self.tokenUsage.promptTokens,
                    completionTokens: self.tokenUsage.completionTokens
                )
                let sttCost = ModelPricingCalculator.shared.calculateSTTCost(audioDurationSeconds: self.tokenUsage.audioDurationSeconds)
                self.tokenUsage.estimatedCostUSD = llmCost + sttCost
            }
            self.delegate?.assistanceCoordinator(self, didUpdateTokenUsage: self.tokenUsage)
        }
    }

    public func pinSuggestion(cardId: String) {
        queue.sync {
            pinnedSuggestionId = cardId
        }
        delegate?.assistanceCoordinator(self, didUpdateState: .pinned, cardId: cardId)
    }

    public func unpinSuggestion(cardId: String) {
        queue.sync {
            if pinnedSuggestionId == cardId {
                pinnedSuggestionId = nil
            }
        }
        delegate?.assistanceCoordinator(self, didUpdateState: .current, cardId: cardId)
    }

    public func dismissSuggestion(cardId: String) {
        queue.sync {
            if currentSuggestion?.id == cardId {
                currentSuggestion = nil
            }
        }
        delegate?.assistanceCoordinator(self, didUpdateState: .dismissed, cardId: cardId)
    }

    /// Dynamically filters retrieved memory excerpts to only include facts that match substantive words in the recent transcript.
    /// This prevents forcing unrelated database, infrastructure, or technical facts into unrelated business, marketing, or general discussions.
    private func filterRelevantExcerpts(for transcript: [TranscriptSegment]) -> [String] {
        guard !relevantExcerpts.isEmpty else { return [] }
        let transcriptText = transcript.map { $0.text.lowercased() }.joined(separator: " ")
        guard !transcriptText.isEmpty else { return [] }

        let stopwords: Set<String> = [
            "the", "and", "that", "this", "with", "from", "have", "what", "were", "been",
            "they", "will", "would", "there", "their", "about", "which", "could", "should",
            "just", "like", "also", "into", "more", "some", "then", "them", "these", "your",
            "yeah", "okay", "sure", "well", "know", "think", "going", "want", "need"
        ]
        let words = Set(
            transcriptText
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 4 && !stopwords.contains($0) }
        )

        guard !words.isEmpty else { return [] }

        var scored: [(excerpt: String, score: Int)] = []
        for excerpt in relevantExcerpts {
            let excerptLower = excerpt.lowercased()
            var score = 0
            for word in words {
                if excerptLower.contains(word) {
                    score += 1
                }
            }
            if score > 0 {
                scored.append((excerpt, score))
            }
        }

        scored.sort { $0.score > $1.score }
        return scored.prefix(3).map { $0.excerpt }
    }

    // MARK: - Trigger Heuristics

    public static func detectQuestion(in text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasSuffix("?") { return true }

        let questionStarters = ["what", "how", "why", "when", "where", "who", "which", "can you", "could you", "should we", "is there", "are we", "do we", "would you"]
        for starter in questionStarters {
            if trimmed.hasPrefix(starter) { return true }
        }
        return false
    }

    public static func detectDecision(in text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let decisionPhrases = ["we decided", "let's agree", "i agree", "we will go with", "action item", "i will handle", "let's commit to", "the plan is"]
        for phrase in decisionPhrases {
            if trimmed.contains(phrase) { return true }
        }
        return false
    }

    public static func isSubstantiveSpeech(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        let words = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if words.count >= 4 { return true }
        let nonSubstantiveWords = ["yeah", "yes", "no", "nah", "okay", "ok", "cool", "right", "uh-huh", "got", "it", "yep", "sure", "thanks", "thank", "you", "hello", "hi", "bye", "um", "uh"]
        if words.allSatisfy({ word in
            let stripped = word.trimmingCharacters(in: CharacterSet.punctuationCharacters)
            return nonSubstantiveWords.contains(stripped)
        }) {
            return false
        }
        return true
    }
}
