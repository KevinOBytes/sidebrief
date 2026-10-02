// contracts/contracts.ts
// Shared typed contracts for Sidebrief macOS client, backend API, and Neon PostgreSQL

export interface ContextSpace {
  id: string;
  name: string;
  description: string;
  retentionDays: number;
  allowedProviders: string[];
  createdAt: string;
  updatedAt: string;
}

export type MeetingState = 'scheduled' | 'recording' | 'paused' | 'completed' | 'cancelled';

export interface Meeting {
  id: string;
  spaceId: string;
  title: string;
  scheduledStartTime?: string;
  actualStartTime?: string;
  actualEndTime?: string;
  state: MeetingState;
  agenda: string;
  sensitivity: string;
  version: number;
  createdAt: string;
  updatedAt: string;
}

export type AudioSourceType = 'microphone' | 'systemAudio';

export interface AudioTrack {
  id: string;
  meetingId: string;
  sourceType: AudioSourceType;
  deviceName: string;
  sampleRate: number;
  channelCount: number;
  format: string;
  streamEpoch: number;
  createdAt: string;
}

export type ChunkUploadState = 'localOnly' | 'queued' | 'uploading' | 'uploaded' | 'failed';

export interface AudioChunkManifest {
  id: string;
  trackId: string;
  meetingId: string;
  sequenceNumber: number;
  streamEpoch: number;
  startOffsetMs: number;
  endOffsetMs: number;
  sampleCount: number;
  byteCount: number;
  checksumSha256: string;
  encryptionKeyVersion: number;
  encryptionNonceHex: string;
  remoteObjectKey?: string;
  uploadState: ChunkUploadState;
  createdAt: string;
}

export interface TranscriptSegment {
  id: string;
  meetingId: string;
  trackId: string;
  providerSegmentId: string;
  speakerLabel: string;
  text: string;
  startOffsetMs: number;
  endOffsetMs: number;
  isProvisional: boolean;
  revision: number;
  createdAt: string;
  updatedAt: string;
}

export interface SuggestionAlternative {
  id: string;
  label: string;
  text: string;
  rationale?: string;
}

export type EvidenceCategory =
  | 'Supported by source'
  | 'Based on this discussion'
  | 'Inference'
  | 'Needs verification';

export interface EvidenceQuote {
  id: string;
  sourceTitle: string;
  snippet: string;
  sourceUrl?: string;
  timestampOffsetMs?: number;
}

export interface SuggestionCard {
  id: string;
  meetingId: string;
  contextRevision: number;
  triggerReason: 'cadence' | 'question' | 'decision' | 'shortcut' | 'chat';
  detectedTopicOrQuestion: string;
  primaryResponse: SuggestionAlternative;
  alternatives: SuggestionAlternative[];
  evidenceCategory: EvidenceCategory;
  evidenceQuotes: EvidenceQuote[];
  uncertaintyNote?: string;
  suggestedFollowUps: string[];
  state: 'generating' | 'current' | 'pinned' | 'superseded' | 'dismissed' | 'expired';
  modelId: string;
  latencyMs: number;
  createdAt: string;
}

export interface MeetingSummary {
  id: string;
  meetingId: string;
  version: number;
  generatingRevision: number;
  overview: string;
  keyPoints: string[];
  decisions: Array<{
    id: string;
    title: string;
    rationale: string;
    status: string;
    evidenceQuote?: string;
    timestampOffsetMs?: number;
  }>;
  actionItems: Array<{
    id: string;
    task: string;
    assignee?: string;
    dueDate?: string;
    status: string;
    evidenceQuote?: string;
    timestampOffsetMs?: number;
  }>;
  unresolvedQuestions: string[];
  followUpEmailDraft?: string;
  createdAt: string;
}

export interface SyncMutationBatch {
  spaceId: string;
  deviceId: string;
  meetings?: Meeting[];
  tracks?: AudioTrack[];
  chunks?: AudioChunkManifest[];
  segments?: TranscriptSegment[];
  summaries?: MeetingSummary[];
  tombstones?: Array<{
    id: string;
    entityType: 'meeting' | 'track' | 'chunk' | 'segment' | 'document';
    deletedAt: string;
  }>;
}

export interface SearchQueryRequest {
  spaceId: string;
  query: string;
  additionalAllowedSpaces?: string[];
  limit?: number;
  filterTypes?: Array<'meeting' | 'email' | 'drive' | 'slack' | 'github'>;
}

export interface SearchResultItem {
  id: string;
  spaceId: string;
  sourceType: 'meeting' | 'email' | 'drive' | 'slack' | 'github';
  title: string;
  snippet: string;
  sourceUrl?: string;
  timestamp?: string;
  score: number;
}
