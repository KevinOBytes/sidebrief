import Foundation

// MARK: - Context Space

public struct ContextSpace: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public var name: String
    public var description: String
    public var retentionDays: Int
    public var allowedProviders: [String]
    public var customPrompt: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        retentionDays: Int = 365,
        allowedProviders: [String] = ["elevenlabs", "openrouter", "openai"],
        customPrompt: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.retentionDays = retentionDays
        self.allowedProviders = allowedProviders
        self.customPrompt = customPrompt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func isValidSpaceId(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count >= 2
    }

    public static let defaultSpaces: [ContextSpace] = [
        ContextSpace(
            id: "space-work",
            name: "Work",
            description: "Primary workspace for work meetings, architecture, and team discussions",
            retentionDays: 365,
            allowedProviders: ["elevenlabs", "openrouter", "openai", "anthropic"],
            customPrompt: "You are an executive and technical copilot for Work meetings. Provide crisp, high-conviction answers, structured takeaways, and actionable follow-ups."
        )
    ]
}

// MARK: - Meeting

public enum MeetingState: String, Codable, Sendable {
    case scheduled
    case recording
    case paused
    case completed
    case cancelled
}

public struct Meeting: Identifiable, Codable, Sendable {
    public let id: String
    public var spaceId: String
    public var title: String
    public var scheduledStartTime: Date?
    public var actualStartTime: Date?
    public var actualEndTime: Date?
    public var state: MeetingState
    public var agenda: String
    public var sensitivity: String
    public var version: Int
    public var totalPromptTokens: Int
    public var totalCompletionTokens: Int
    public var estimatedCostUSD: Double
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        spaceId: String,
        title: String,
        scheduledStartTime: Date? = nil,
        actualStartTime: Date? = nil,
        actualEndTime: Date? = nil,
        state: MeetingState = .scheduled,
        agenda: String = "",
        sensitivity: String = "internal",
        version: Int = 1,
        totalPromptTokens: Int = 0,
        totalCompletionTokens: Int = 0,
        estimatedCostUSD: Double = 0.0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.spaceId = spaceId
        self.title = title
        self.scheduledStartTime = scheduledStartTime
        self.actualStartTime = actualStartTime
        self.actualEndTime = actualEndTime
        self.state = state
        self.agenda = agenda
        self.sensitivity = sensitivity
        self.version = version
        self.totalPromptTokens = totalPromptTokens
        self.totalCompletionTokens = totalCompletionTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Audio Track & Chunks

public enum AudioSourceType: String, Codable, Sendable {
    case microphone
    case systemAudio
}

public struct AudioTrack: Identifiable, Codable, Sendable {
    public let id: String
    public let meetingId: String
    public let sourceType: AudioSourceType
    public var deviceName: String
    public var sampleRate: Double
    public var channelCount: Int
    public var format: String
    public var streamEpoch: Int64
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        meetingId: String,
        sourceType: AudioSourceType,
        deviceName: String,
        sampleRate: Double = 48000.0,
        channelCount: Int = 1,
        format: String = "lpcm_16bit",
        streamEpoch: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.sourceType = sourceType
        self.deviceName = deviceName
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.format = format
        self.streamEpoch = streamEpoch
        self.createdAt = createdAt
    }
}

public enum ChunkUploadState: String, Codable, Sendable {
    case localOnly
    case queued
    case uploading
    case uploaded
    case failed
}

public struct AudioChunk: Identifiable, Codable, Sendable {
    public let id: String
    public let trackId: String
    public let meetingId: String
    public let sequenceNumber: Int
    public let streamEpoch: Int64
    public let startOffsetMs: Int64
    public let endOffsetMs: Int64
    public let sampleCount: Int
    public let byteCount: Int
    public let checksumSha256: String
    public var encryptionKeyVersion: Int
    public var encryptionNonceHex: String
    public var localEncryptedFilePath: String
    public var remoteObjectKey: String?
    public var uploadState: ChunkUploadState
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        trackId: String,
        meetingId: String,
        sequenceNumber: Int,
        streamEpoch: Int64,
        startOffsetMs: Int64,
        endOffsetMs: Int64,
        sampleCount: Int,
        byteCount: Int,
        checksumSha256: String,
        encryptionKeyVersion: Int = 1,
        encryptionNonceHex: String,
        localEncryptedFilePath: String,
        remoteObjectKey: String? = nil,
        uploadState: ChunkUploadState = .localOnly,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.trackId = trackId
        self.meetingId = meetingId
        self.sequenceNumber = sequenceNumber
        self.streamEpoch = streamEpoch
        self.startOffsetMs = startOffsetMs
        self.endOffsetMs = endOffsetMs
        self.sampleCount = sampleCount
        self.byteCount = byteCount
        self.checksumSha256 = checksumSha256
        self.encryptionKeyVersion = encryptionKeyVersion
        self.encryptionNonceHex = encryptionNonceHex
        self.localEncryptedFilePath = localEncryptedFilePath
        self.remoteObjectKey = remoteObjectKey
        self.uploadState = uploadState
        self.createdAt = createdAt
    }
}

// MARK: - Transcript

public struct TranscriptSegment: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let meetingId: String
    public let trackId: String
    public let providerSegmentId: String
    public var speakerLabel: String // "You", "Remote Speaker", "Alice", etc.
    public var text: String
    public var startOffsetMs: Int64
    public var endOffsetMs: Int64
    public var isProvisional: Bool
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        meetingId: String,
        trackId: String,
        providerSegmentId: String,
        speakerLabel: String,
        text: String,
        startOffsetMs: Int64,
        endOffsetMs: Int64,
        isProvisional: Bool = false,
        revision: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.trackId = trackId
        self.providerSegmentId = providerSegmentId
        self.speakerLabel = speakerLabel
        self.text = text
        self.startOffsetMs = startOffsetMs
        self.endOffsetMs = endOffsetMs
        self.isProvisional = isProvisional
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TranscriptEdit: Identifiable, Codable, Sendable {
    public let id: String
    public let segmentId: String
    public let meetingId: String
    public let originalText: String
    public let correctedText: String
    public let originalSpeaker: String
    public let correctedSpeaker: String
    public let editedAt: Date

    public init(
        id: String = UUID().uuidString,
        segmentId: String,
        meetingId: String,
        originalText: String,
        correctedText: String,
        originalSpeaker: String,
        correctedSpeaker: String,
        editedAt: Date = Date()
    ) {
        self.id = id
        self.segmentId = segmentId
        self.meetingId = meetingId
        self.originalText = originalText
        self.correctedText = correctedText
        self.originalSpeaker = originalSpeaker
        self.correctedSpeaker = correctedSpeaker
        self.editedAt = editedAt
    }
}

// MARK: - Suggestions & Live Copilot

public enum EvidenceCategory: String, Codable, Sendable {
    case supportedBySource = "Supported by source"
    case basedOnDiscussion = "Based on this discussion"
    case inference = "Inference"
    case needsVerification = "Needs verification"
}

public enum SuggestionState: String, Codable, Sendable {
    case generating
    case current
    case pinned
    case superseded
    case dismissed
    case expired
}

public enum TriggerReason: String, Codable, Sendable {
    case cadence
    case question
    case decision
    case shortcut
    case chat
}

public struct SuggestionAlternative: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public var label: String // "Direct answer", "Clarify", "Alternative", "Risk", etc.
    public var text: String // 25-60 words
    public var rationale: String?

    public init(id: String = UUID().uuidString, label: String, text: String, rationale: String? = nil) {
        self.id = id
        self.label = label
        self.text = text
        self.rationale = rationale
    }
}

public struct EvidenceQuote: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public var sourceTitle: String
    public var snippet: String
    public var sourceUrl: String?
    public var timestampOffsetMs: Int64?

    public init(id: String = UUID().uuidString, sourceTitle: String, snippet: String, sourceUrl: String? = nil, timestampOffsetMs: Int64? = nil) {
        self.id = id
        self.sourceTitle = sourceTitle
        self.snippet = snippet
        self.sourceUrl = sourceUrl
        self.timestampOffsetMs = timestampOffsetMs
    }
}

public struct SuggestionCard: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let meetingId: String
    public var contextRevision: Int
    public var triggerReason: TriggerReason
    public var detectedTopicOrQuestion: String
    public var primaryResponse: SuggestionAlternative
    public var alternatives: [SuggestionAlternative] // Up to 2
    public var evidenceCategory: EvidenceCategory
    public var evidenceQuotes: [EvidenceQuote]
    public var uncertaintyNote: String?
    public var suggestedFollowUps: [String]
    public var state: SuggestionState
    public var modelId: String
    public var latencyMs: Int64
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        meetingId: String,
        contextRevision: Int,
        triggerReason: TriggerReason,
        detectedTopicOrQuestion: String,
        primaryResponse: SuggestionAlternative,
        alternatives: [SuggestionAlternative] = [],
        evidenceCategory: EvidenceCategory = .basedOnDiscussion,
        evidenceQuotes: [EvidenceQuote] = [],
        uncertaintyNote: String? = nil,
        suggestedFollowUps: [String] = [],
        state: SuggestionState = .current,
        modelId: String = "openrouter/fast",
        latencyMs: Int64 = 0,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.contextRevision = contextRevision
        self.triggerReason = triggerReason
        self.detectedTopicOrQuestion = detectedTopicOrQuestion
        self.primaryResponse = primaryResponse
        self.alternatives = alternatives
        self.evidenceCategory = evidenceCategory
        self.evidenceQuotes = evidenceQuotes
        self.uncertaintyNote = uncertaintyNote
        self.suggestedFollowUps = suggestedFollowUps
        self.state = state
        self.modelId = modelId
        self.latencyMs = latencyMs
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.createdAt = createdAt
    }
}

// MARK: - Chat Message

public enum ChatSender: String, Codable, Sendable {
    case user
    case assistant
}

public struct ChatMessage: Identifiable, Codable, Sendable {
    public let id: String
    public let meetingId: String
    public let sender: ChatSender
    public var text: String
    public var referencedSegmentIds: [String]
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        meetingId: String,
        sender: ChatSender,
        text: String,
        referencedSegmentIds: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.sender = sender
        self.text = text
        self.referencedSegmentIds = referencedSegmentIds
        self.createdAt = createdAt
    }
}

// MARK: - Meeting Summaries, Decisions, Action Items

public struct DecisionItem: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public var title: String
    public var rationale: String
    public var status: String // "proposed", "confirmed", "rejected"
    public var evidenceQuote: String?
    public var timestampOffsetMs: Int64?

    public init(id: String = UUID().uuidString, title: String, rationale: String, status: String = "confirmed", evidenceQuote: String? = nil, timestampOffsetMs: Int64? = nil) {
        self.id = id
        self.title = title
        self.rationale = rationale
        self.status = status
        self.evidenceQuote = evidenceQuote
        self.timestampOffsetMs = timestampOffsetMs
    }
}

public struct ActionItem: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public var task: String
    public var assignee: String?
    public var dueDate: String?
    public var status: String // "draft", "pending", "completed"
    public var evidenceQuote: String?
    public var timestampOffsetMs: Int64?

    public init(id: String = UUID().uuidString, task: String, assignee: String? = nil, dueDate: String? = nil, status: String = "draft", evidenceQuote: String? = nil, timestampOffsetMs: Int64? = nil) {
        self.id = id
        self.task = task
        self.assignee = assignee
        self.dueDate = dueDate
        self.status = status
        self.evidenceQuote = evidenceQuote
        self.timestampOffsetMs = timestampOffsetMs
    }
}

public struct MeetingSummary: Identifiable, Codable, Sendable {
    public let id: String
    public let meetingId: String
    public var version: Int
    public var generatingRevision: Int
    public var overview: String
    public var keyPoints: [String]
    public var decisions: [DecisionItem]
    public var actionItems: [ActionItem]
    public var unresolvedQuestions: [String]
    public var followUpEmailDraft: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        meetingId: String,
        version: Int = 1,
        generatingRevision: Int = 1,
        overview: String = "",
        keyPoints: [String] = [],
        decisions: [DecisionItem] = [],
        actionItems: [ActionItem] = [],
        unresolvedQuestions: [String] = [],
        followUpEmailDraft: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingId = meetingId
        self.version = version
        self.generatingRevision = generatingRevision
        self.overview = overview
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.unresolvedQuestions = unresolvedQuestions
        self.followUpEmailDraft = followUpEmailDraft
        self.createdAt = createdAt
    }
}

// MARK: - Connectors

public enum ConnectorType: String, Codable, Sendable {
    case email
    case googleDrive
    case slack
    case github
}

public enum ConnectorStatus: String, Codable, Sendable {
    case connected
    case syncing
    case error
    case revoked
}

public struct ConnectorAccount: Identifiable, Codable, Sendable {
    public let id: String
    public let spaceId: String
    public let type: ConnectorType
    public var accountIdentifier: String
    public var status: ConnectorStatus
    public var lastSyncAt: Date?
    public var lastError: String?
    public var selectedScopes: [String]
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        spaceId: String,
        type: ConnectorType,
        accountIdentifier: String,
        status: ConnectorStatus = .connected,
        lastSyncAt: Date? = nil,
        lastError: String? = nil,
        selectedScopes: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.spaceId = spaceId
        self.type = type
        self.accountIdentifier = accountIdentifier
        self.status = status
        self.lastSyncAt = lastSyncAt
        self.lastError = lastError
        self.selectedScopes = selectedScopes
        self.createdAt = createdAt
    }
}

public struct ConnectedDocument: Identifiable, Codable, Sendable {
    public let id: String
    public let spaceId: String
    public let connectorId: String
    public let externalId: String
    public var title: String
    public var sourceUrl: String
    public var mimeType: String
    public var contentHash: String
    public var rawContent: String
    public var lastModifiedAt: Date
    public var syncedAt: Date

    public init(
        id: String = UUID().uuidString,
        spaceId: String,
        connectorId: String,
        externalId: String,
        title: String,
        sourceUrl: String,
        mimeType: String,
        contentHash: String,
        rawContent: String,
        lastModifiedAt: Date = Date(),
        syncedAt: Date = Date()
    ) {
        self.id = id
        self.spaceId = spaceId
        self.connectorId = connectorId
        self.externalId = externalId
        self.title = title
        self.sourceUrl = sourceUrl
        self.mimeType = mimeType
        self.contentHash = contentHash
        self.rawContent = rawContent
        self.lastModifiedAt = lastModifiedAt
        self.syncedAt = syncedAt
    }
}

// MARK: - Editable & Bootstrapped Memory

public struct MemoryFact: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public var spaceId: String
    public var category: String // "Architecture", "People", "Decisions", "Preferences", "Key Terminology", "Active Projects"
    public var key: String
    public var value: String
    public var source: String // "bootstrapped", "extracted", "manual"
    public var isPinned: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        spaceId: String,
        category: String = "General",
        key: String,
        value: String,
        source: String = "bootstrapped",
        isPinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.spaceId = spaceId
        self.category = category
        self.key = key
        self.value = value
        self.source = source
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Multiple Email Accounts Configuration

public struct EmailAccountConfig: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public var spaceId: String
    public var accountName: String // e.g. "Work - Kevin", "Personal Fastmail", "Advisory Gmail"
    public var emailAddress: String
    public var imapHost: String
    public var imapPort: Int
    public var useTls: Bool
    public var authType: String // "password", "oauth"
    public var syncFolder: String
    public var isEnabled: Bool
    public var lastSyncAt: Date?
    public var lastError: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        spaceId: String,
        accountName: String,
        emailAddress: String,
        imapHost: String = "imap.gmail.com",
        imapPort: Int = 993,
        useTls: Bool = true,
        authType: String = "password",
        syncFolder: String = "INBOX",
        isEnabled: Bool = true,
        lastSyncAt: Date? = nil,
        lastError: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.spaceId = spaceId
        self.accountName = accountName
        self.emailAddress = emailAddress
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.useTls = useTls
        self.authType = authType
        self.syncFolder = syncFolder
        self.isEnabled = isEnabled
        self.lastSyncAt = lastSyncAt
        self.lastError = lastError
        self.createdAt = createdAt
    }
}

// MARK: - Custom Vocabulary

public struct CustomVocabularyItem: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public var spaceId: String? // nil for global, or space-specific e.g. "space-tkoresearch"
    public var phrase: String
    public var soundsLike: String?
    public var boost: Double
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        spaceId: String? = nil,
        phrase: String,
        soundsLike: String? = nil,
        boost: Double = 2.0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.spaceId = spaceId
        self.phrase = phrase
        self.soundsLike = soundsLike
        self.boost = boost
        self.createdAt = createdAt
    }
}

// MARK: - Live Token & Cost Usage

public struct TokenUsage: Codable, Sendable, Hashable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int
    public var estimatedCostUSD: Double
    public var queryCount: Int
    public var audioDurationSeconds: Double

    public init(
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        totalTokens: Int = 0,
        estimatedCostUSD: Double = 0.0,
        queryCount: Int = 0,
        audioDurationSeconds: Double = 0.0
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.queryCount = queryCount
        self.audioDurationSeconds = audioDurationSeconds
    }
}

// MARK: - Cloud Sync Status

public enum SyncStatus: Equatable, Sendable {
    case idle
    case syncing(chunksRemaining: Int)
    case synced
    case offline(pendingCount: Int)
}

// MARK: - Speaker Profile

public struct SpeakerProfile: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public var spaceId: String?
    public var name: String
    public var roleOrTitle: String?
    public var organization: String?
    public var notesOrContext: String?
    public var aliases: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        spaceId: String? = nil,
        name: String,
        roleOrTitle: String? = nil,
        organization: String? = nil,
        notesOrContext: String? = nil,
        aliases: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.spaceId = spaceId
        self.name = name
        self.roleOrTitle = roleOrTitle
        self.organization = organization
        self.notesOrContext = notesOrContext
        self.aliases = aliases
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
