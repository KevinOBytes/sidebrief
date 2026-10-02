-- Sidebrief PostgreSQL Schema
-- Authoritative structured data store with RLS, pgvector, and full-text search

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "vector";

-- Spaces
CREATE TABLE IF NOT EXISTS spaces (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT DEFAULT '',
    retention_days INT DEFAULT 365,
    allowed_providers JSONB DEFAULT '["elevenlabs", "openrouter", "openai"]'::jsonb,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Users
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    email TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Space Members
CREATE TABLE IF NOT EXISTS space_members (
    space_id TEXT REFERENCES spaces(id) ON DELETE CASCADE,
    user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
    role TEXT DEFAULT 'member',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (space_id, user_id)
);

-- Meetings
CREATE TABLE IF NOT EXISTS meetings (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    scheduled_start_time TIMESTAMPTZ,
    actual_start_time TIMESTAMPTZ,
    actual_end_time TIMESTAMPTZ,
    state TEXT NOT NULL DEFAULT 'scheduled',
    agenda TEXT DEFAULT '',
    sensitivity TEXT DEFAULT 'internal',
    version INT DEFAULT 1,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Audio Tracks
CREATE TABLE IF NOT EXISTS audio_tracks (
    id TEXT PRIMARY KEY,
    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    source_type TEXT NOT NULL, -- 'microphone' or 'systemAudio'
    device_name TEXT NOT NULL,
    sample_rate DOUBLE PRECISION DEFAULT 48000.0,
    channel_count INT DEFAULT 1,
    format TEXT DEFAULT 'lpcm_16bit',
    stream_epoch BIGINT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Audio Chunks
CREATE TABLE IF NOT EXISTS audio_chunks (
    id TEXT PRIMARY KEY,
    track_id TEXT NOT NULL REFERENCES audio_tracks(id) ON DELETE CASCADE,
    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    sequence_number INT NOT NULL,
    stream_epoch BIGINT NOT NULL,
    start_offset_ms BIGINT NOT NULL,
    end_offset_ms BIGINT NOT NULL,
    sample_count INT NOT NULL,
    byte_count INT NOT NULL,
    checksum_sha256 TEXT NOT NULL,
    encryption_key_version INT DEFAULT 1,
    encryption_nonce_hex TEXT NOT NULL,
    remote_object_key TEXT,
    upload_state TEXT NOT NULL DEFAULT 'localOnly',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(track_id, sequence_number)
);

-- Transcript Segments
CREATE TABLE IF NOT EXISTS transcript_segments (
    id TEXT PRIMARY KEY,
    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    track_id TEXT NOT NULL REFERENCES audio_tracks(id) ON DELETE CASCADE,
    provider_segment_id TEXT,
    speaker_label TEXT NOT NULL,
    text TEXT NOT NULL,
    start_offset_ms BIGINT NOT NULL,
    end_offset_ms BIGINT NOT NULL,
    is_provisional BOOLEAN DEFAULT FALSE,
    revision INT DEFAULT 1,
    search_vector TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', text)) STORED,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Meeting Summaries
CREATE TABLE IF NOT EXISTS meeting_summaries (
    id TEXT PRIMARY KEY,
    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    version INT DEFAULT 1,
    generating_revision INT DEFAULT 1,
    overview TEXT NOT NULL,
    key_points JSONB DEFAULT '[]'::jsonb,
    decisions JSONB DEFAULT '[]'::jsonb,
    action_items JSONB DEFAULT '[]'::jsonb,
    unresolved_questions JSONB DEFAULT '[]'::jsonb,
    follow_up_email_draft TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Decisions
CREATE TABLE IF NOT EXISTS decisions (
    id TEXT PRIMARY KEY,
    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    rationale TEXT NOT NULL,
    status TEXT DEFAULT 'confirmed',
    evidence_quote TEXT,
    timestamp_ms BIGINT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Action Items
CREATE TABLE IF NOT EXISTS action_items (
    id TEXT PRIMARY KEY,
    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    task TEXT NOT NULL,
    assignee TEXT,
    due_date TEXT,
    status TEXT DEFAULT 'draft',
    evidence_quote TEXT,
    timestamp_ms BIGINT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Suggestions
CREATE TABLE IF NOT EXISTS suggestions (
    id TEXT PRIMARY KEY,
    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    context_revision INT NOT NULL,
    trigger_reason TEXT NOT NULL,
    detected_topic TEXT NOT NULL,
    primary_response JSONB NOT NULL,
    alternatives JSONB DEFAULT '[]'::jsonb,
    evidence_category TEXT NOT NULL,
    evidence_quotes JSONB DEFAULT '[]'::jsonb,
    uncertainty_note TEXT,
    suggested_follow_ups JSONB DEFAULT '[]'::jsonb,
    state TEXT NOT NULL DEFAULT 'current',
    model_id TEXT NOT NULL,
    latency_ms BIGINT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Connectors
CREATE TABLE IF NOT EXISTS connectors (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    type TEXT NOT NULL, -- 'email', 'googleDrive', 'slack', 'github'
    account_identifier TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'connected',
    last_sync_at TIMESTAMPTZ,
    last_error TEXT,
    selected_scopes JSONB DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Connected Documents
CREATE TABLE IF NOT EXISTS documents (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    connector_id TEXT REFERENCES connectors(id) ON DELETE SET NULL,
    external_id TEXT NOT NULL,
    title TEXT NOT NULL,
    source_url TEXT DEFAULT '',
    mime_type TEXT DEFAULT 'text/plain',
    content_hash TEXT NOT NULL,
    raw_content TEXT NOT NULL,
    search_vector TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', title || ' ' || raw_content)) STORED,
    last_modified_at TIMESTAMPTZ DEFAULT NOW(),
    synced_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(space_id, external_id)
);

-- Document Chunks with Vector Embeddings (1536 dim, e.g. text-embedding-3-small or Cloudflare Workers AI)
CREATE TABLE IF NOT EXISTS document_chunks (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    chunk_index INT NOT NULL,
    content TEXT NOT NULL,
    token_count INT DEFAULT 0,
    embedding VECTOR(1536),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Tombstones for Idempotent Sync and Zombie Prevention
CREATE TABLE IF NOT EXISTS tombstones (
    id TEXT PRIMARY KEY,
    entity_type TEXT NOT NULL, -- 'meeting', 'track', 'chunk', 'document'
    space_id TEXT NOT NULL,
    deleted_at TIMESTAMPTZ DEFAULT NOW()
);

-- Audit Events
CREATE TABLE IF NOT EXISTS audit_events (
    id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
    space_id TEXT NOT NULL,
    action TEXT NOT NULL,
    details JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Licenses and Customer Activations
CREATE TABLE IF NOT EXISTS licenses (
    id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
    license_key TEXT UNIQUE NOT NULL,
    email TEXT NOT NULL,
    stripe_session_id TEXT,
    stripe_customer_id TEXT,
    status TEXT NOT NULL DEFAULT 'active', -- 'active', 'revoked', 'expired'
    hardware_uuid TEXT,
    machine_name TEXT,
    last_ip TEXT,
    use_count INT NOT NULL DEFAULT 0,
    activated_at TIMESTAMPTZ,
    last_used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- License Usage and Audit Log (Tracking activations, IP, machine identifier)
CREATE TABLE IF NOT EXISTS license_usage_logs (
    id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
    license_id TEXT REFERENCES licenses(id) ON DELETE CASCADE,
    license_key TEXT NOT NULL,
    hardware_uuid TEXT NOT NULL,
    machine_name TEXT,
    ip_address TEXT,
    user_agent TEXT,
    action TEXT NOT NULL, -- 'activate', 'validate', 'deactivate'
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE licenses ADD COLUMN IF NOT EXISTS machine_name TEXT;
ALTER TABLE licenses ADD COLUMN IF NOT EXISTS last_ip TEXT;
ALTER TABLE licenses ADD COLUMN IF NOT EXISTS use_count INT NOT NULL DEFAULT 0;
ALTER TABLE licenses ADD COLUMN IF NOT EXISTS last_used_at TIMESTAMPTZ;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_meetings_space_id ON meetings(space_id);
CREATE INDEX IF NOT EXISTS idx_audio_tracks_meeting_id ON audio_tracks(meeting_id);
CREATE INDEX IF NOT EXISTS idx_audio_chunks_track_id ON audio_chunks(track_id);
CREATE INDEX IF NOT EXISTS idx_transcript_segments_meeting ON transcript_segments(meeting_id);
CREATE INDEX IF NOT EXISTS idx_transcript_search ON transcript_segments USING GIN(search_vector);
CREATE INDEX IF NOT EXISTS idx_documents_space_id ON documents(space_id);
CREATE INDEX IF NOT EXISTS idx_documents_search ON documents USING GIN(search_vector);
CREATE INDEX IF NOT EXISTS idx_document_chunks_space_id ON document_chunks(space_id);
CREATE INDEX IF NOT EXISTS idx_tombstones_space_id ON tombstones(space_id);
CREATE INDEX IF NOT EXISTS idx_licenses_key ON licenses(license_key);
CREATE INDEX IF NOT EXISTS idx_licenses_email ON licenses(email);
CREATE INDEX IF NOT EXISTS idx_license_usage_key ON license_usage_logs(license_key);
CREATE INDEX IF NOT EXISTS idx_license_usage_hwid ON license_usage_logs(hardware_uuid);

-- Row-Level Security (RLS)
ALTER TABLE spaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE meetings ENABLE ROW LEVEL SECURITY;
ALTER TABLE audio_tracks ENABLE ROW LEVEL SECURITY;
ALTER TABLE audio_chunks ENABLE ROW LEVEL SECURITY;
ALTER TABLE transcript_segments ENABLE ROW LEVEL SECURITY;
ALTER TABLE meeting_summaries ENABLE ROW LEVEL SECURITY;
ALTER TABLE decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE action_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE suggestions ENABLE ROW LEVEL SECURITY;
ALTER TABLE connectors ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE document_chunks ENABLE ROW LEVEL SECURITY;
ALTER TABLE tombstones ENABLE ROW LEVEL SECURITY;

-- Default Context Spaces Seed (Single default "Work" space)
INSERT INTO spaces (id, name, description)
VALUES 
    ('space-work', 'Work', 'Primary workspace for work meetings, planning, and discussions')
ON CONFLICT (id) DO NOTHING;

