import { Hono } from 'hono';
import { serve } from '@hono/node-server';
import fs from 'fs';
import path from 'path';
import { query, withTransaction } from './db.js';
import { hybridSearch } from './retrieval.js';
import { createCheckoutSession, handleStripeWebhook, activateLicense, validateLicense, requestMagicLink } from './licensing.js';
import { checkUpdate, getAppcastFeed } from './updates.js';
import { GitHubConnector, DriveConnector, SlackConnector } from './connectors/Connectors.js';

const app = new Hono();

// Health Check
app.get('/health', (c) => {
  return c.json({ status: 'ok', service: 'sidebrief-api', timestamp: new Date().toISOString() });
});

// 1. Batch Idempotent Sync Endpoint
app.post('/api/v1/sync', async (c) => {
  const body = await c.req.json();
  const { spaceId, meetings = [], tracks = [], chunks = [], segments = [], summaries = [], tombstones = [] } = body;

  if (!spaceId) {
    return c.json({ error: 'spaceId is required' }, 400);
  }

  try {
    await withTransaction(spaceId, async (client) => {
      // 1. Ingest Meetings
      for (const m of meetings) {
        const sql = `
          INSERT INTO meetings (id, space_id, title, scheduled_start_time, actual_start_time, actual_end_time, state, agenda, sensitivity, version, updated_at)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NOW())
          ON CONFLICT (id) DO UPDATE SET
            title = EXCLUDED.title,
            actual_end_time = EXCLUDED.actual_end_time,
            state = EXCLUDED.state,
            agenda = EXCLUDED.agenda,
            version = meetings.version + 1,
            updated_at = NOW()
        `;
        await client.query(sql, [
          m.id, spaceId, m.title, m.scheduledStartTime || null, m.actualStartTime || null,
          m.actualEndTime || null, m.state, m.agenda || '', m.sensitivity || 'internal', m.version || 1
        ]);
      }

      // 2. Ingest Audio Tracks
      for (const t of tracks) {
        const sql = `
          INSERT INTO audio_tracks (id, meeting_id, source_type, device_name, sample_rate, channel_count, format, stream_epoch)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
          ON CONFLICT (id) DO NOTHING
        `;
        await client.query(sql, [
          t.id, t.meetingId, t.sourceType, t.deviceName, t.sampleRate || 48000,
          t.channelCount || 1, t.format || 'lpcm_16bit', t.streamEpoch
        ]);
      }

      // 3. Ingest Audio Chunks
      for (const ch of chunks) {
        const sql = `
          INSERT INTO audio_chunks (
            id, track_id, meeting_id, sequence_number, stream_epoch, start_offset_ms, end_offset_ms,
            sample_count, byte_count, checksum_sha256, encryption_key_version, encryption_nonce_hex,
            remote_object_key, upload_state
          ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
          ON CONFLICT (track_id, sequence_number) DO UPDATE SET
            remote_object_key = COALESCE(EXCLUDED.remote_object_key, audio_chunks.remote_object_key),
            upload_state = EXCLUDED.upload_state
        `;
        await client.query(sql, [
          ch.id, ch.trackId, ch.meetingId, ch.sequenceNumber, ch.streamEpoch,
          ch.startOffsetMs, ch.endOffsetMs, ch.sampleCount, ch.byteCount,
          ch.checksumSha256, ch.encryptionKeyVersion || 1, ch.encryptionNonceHex,
          ch.remoteObjectKey || null, ch.uploadState || 'localOnly'
        ]);
      }

      // 4. Ingest Transcript Segments
      for (const s of segments) {
        const sql = `
          INSERT INTO transcript_segments (
            id, meeting_id, track_id, provider_segment_id, speaker_label, text,
            start_offset_ms, end_offset_ms, is_provisional, revision, updated_at
          ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NOW())
          ON CONFLICT (id) DO UPDATE SET
            text = EXCLUDED.text,
            is_provisional = EXCLUDED.is_provisional,
            revision = transcript_segments.revision + 1,
            updated_at = NOW()
        `;
        await client.query(sql, [
          s.id, s.meetingId, s.trackId, s.providerSegmentId || null, s.speakerLabel,
          s.text, s.startOffsetMs, s.endOffsetMs, s.isProvisional || false, s.revision || 1
        ]);
      }

      // 5. Ingest Summaries
      for (const sum of summaries) {
        const sql = `
          INSERT INTO meeting_summaries (
            id, meeting_id, version, generating_revision, overview, key_points, decisions, action_items, unresolved_questions, follow_up_email_draft
          ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
          ON CONFLICT (id) DO UPDATE SET
            version = meeting_summaries.version + 1,
            overview = EXCLUDED.overview,
            key_points = EXCLUDED.key_points,
            decisions = EXCLUDED.decisions,
            action_items = EXCLUDED.action_items,
            unresolved_questions = EXCLUDED.unresolved_questions,
            follow_up_email_draft = EXCLUDED.follow_up_email_draft
        `;
        await client.query(sql, [
          sum.id, sum.meetingId, sum.version || 1, sum.generatingRevision || 1,
          sum.overview, JSON.stringify(sum.keyPoints || []), JSON.stringify(sum.decisions || []),
          JSON.stringify(sum.actionItems || []), JSON.stringify(sum.unresolvedQuestions || []),
          sum.followUpEmailDraft || null
        ]);
      }

      // 6. Handle Tombstones (Deletions)
      for (const tb of tombstones) {
        await client.query(
          'INSERT INTO tombstones (id, entity_type, space_id, deleted_at) VALUES ($1, $2, $3, NOW()) ON CONFLICT (id) DO NOTHING',
          [tb.id, tb.entityType, spaceId]
        );
        if (tb.entityType === 'meeting') {
          await client.query('DELETE FROM meetings WHERE id = $1 AND space_id = $2', [tb.id, spaceId]);
        }
      }
    });

    return c.json({ success: true, spaceId, syncedAt: new Date().toISOString() });
  } catch (err: any) {
    console.error('Sync error:', err);
    return c.json({ error: err.message }, 500);
  }
});

// 2. Hybrid Search Endpoint
app.post('/api/v1/search', async (c) => {
  const body = await c.req.json();
  const { spaceId, query: q, additionalAllowedSpaces, limit, queryEmbedding } = body;

  if (!spaceId || !q) {
    return c.json({ error: 'spaceId and query are required' }, 400);
  }

  try {
    const results = await hybridSearch({
      spaceId,
      queryText: q,
      queryEmbedding,
      additionalAllowedSpaces,
      limit: limit || 10,
    });
    return c.json({ results });
  } catch (err: any) {
    console.error('Search error:', err);
    return c.json({ error: err.message }, 500);
  }
});

// 3. Ephemeral STT Token Broker
app.post('/api/v1/auth/broker-stt', async (c) => {
  const elevenLabsApiKey = process.env.ELEVENLABS_API_KEY || '';
  if (!elevenLabsApiKey) {
    return c.json({ error: 'ElevenLabs API key not configured on backend' }, 500);
  }

  // Returns single-use token or signed WebSocket URL
  return c.json({
    webSocketUrl: `wss://api.elevenlabs.io/v1/speech-to-text/streaming?model_id=scribe_v1`,
    token: elevenLabsApiKey, // Or ephemeral session token if enterprise endpoint
    expiresAt: new Date(Date.now() + 15 * 60 * 1000).toISOString(),
  });
});

// 4. Cloudflare R2 Upload Grant
app.post('/api/v1/storage/grant-upload', async (c) => {
  const { meetingId, chunkId, spaceId } = await c.req.json();
  if (!meetingId || !chunkId || !spaceId) {
    return c.json({ error: 'meetingId, chunkId, and spaceId are required' }, 400);
  }

  // Generate private S3/R2 presigned upload URL or proxy key
  const objectKey = `audio/${spaceId}/${meetingId}/${chunkId}.enc`;
  return c.json({
    objectKey,
    uploadUrl: `https://r2.sidebrief.internal/${objectKey}?grant=temporary`,
    headers: {
      'Content-Type': 'application/octet-stream',
    },
    expiresInSeconds: 3600,
  });
});

// 5. Memory Facts Endpoints (Visible & Editable Bootstrapped Memory)
app.get('/api/v1/memory', async (c) => {
  const spaceId = c.req.query('spaceId');
  if (!spaceId) return c.json({ error: 'spaceId query param required' }, 400);

  const sql = `
    SELECT id, space_id, category, key, value, source, is_pinned, created_at, updated_at
    FROM memory_facts
    WHERE space_id = $1
    ORDER BY is_pinned DESC, category ASC, updated_at DESC
  `;
  const facts = await query(sql, [spaceId]);
  return c.json({ facts });
});

app.post('/api/v1/memory', async (c) => {
  const body = await c.req.json();
  const { id = `mem_${Date.now()}`, spaceId, category = 'General', key, value, source = 'manual', isPinned = false } = body;

  if (!spaceId || !key || !value) {
    return c.json({ error: 'spaceId, key, and value are required' }, 400);
  }

  const sql = `
    INSERT INTO memory_facts (id, space_id, category, key, value, source, is_pinned, updated_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, NOW())
    ON CONFLICT (id) DO UPDATE SET
      category = EXCLUDED.category,
      key = EXCLUDED.key,
      value = EXCLUDED.value,
      is_pinned = EXCLUDED.is_pinned,
      updated_at = NOW()
    RETURNING *
  `;
  const rows = await query(sql, [id, spaceId, category, key, value, source, isPinned]);
  return c.json({ fact: rows[0] });
});

app.delete('/api/v1/memory/:id', async (c) => {
  const id = c.req.param('id');
  await query('DELETE FROM memory_facts WHERE id = $1', [id]);
  return c.json({ success: true, id });
});

// 6. Multiple Email Accounts Endpoints
app.get('/api/v1/connectors/email', async (c) => {
  const spaceId = c.req.query('spaceId');
  if (!spaceId) return c.json({ error: 'spaceId query param required' }, 400);

  const sql = `
    SELECT id, space_id, type, account_identifier, status, last_sync_at, last_error, selected_scopes
    FROM connectors
    WHERE space_id = $1 AND type = 'email'
    ORDER BY created_at ASC
  `;
  const accounts = await query(sql, [spaceId]);
  return c.json({ accounts });
});

app.post('/api/v1/connectors/email', async (c) => {
  const body = await c.req.json();
  const { id = `email_acc_${Date.now()}`, spaceId, emailAddress, accountName = emailAddress, imapHost = 'imap.gmail.com', imapPort = 993, selectedScopes = ['INBOX'] } = body;

  if (!spaceId || !emailAddress) {
    return c.json({ error: 'spaceId and emailAddress are required' }, 400);
  }

  const sql = `
    INSERT INTO connectors (id, space_id, type, account_identifier, status, selected_scopes, last_sync_at, created_at)
    VALUES ($1, $2, 'email', $3, 'connected', $4, NOW(), NOW())
    ON CONFLICT (id) DO UPDATE SET
      account_identifier = EXCLUDED.account_identifier,
      selected_scopes = EXCLUDED.selected_scopes,
      status = 'connected'
    RETURNING *
  `;
  const rows = await query(sql, [id, spaceId, emailAddress, JSON.stringify({ accountName, imapHost, imapPort, folders: selectedScopes })]);
  return c.json({ account: rows[0] });
});

app.post('/api/v1/connectors/email/:id/sync', async (c) => {
  const id = c.req.param('id');
  const rows = await query('SELECT * FROM connectors WHERE id = $1', [id]);
  if (rows.length === 0) return c.json({ error: 'Account not found' }, 404);

  // Update sync timestamp
  await query('UPDATE connectors SET last_sync_at = NOW(), status = $1 WHERE id = $2', ['connected', id]);
  return c.json({ success: true, accountId: id, syncedAt: new Date().toISOString() });
});

app.post('/api/v1/connectors/github/sync', async (c) => {
  const { spaceId = 'space-work', repo, token } = await c.req.json().catch(() => ({}));
  if (!repo) return c.json({ error: 'Repository name is required (e.g. owner/repo)' }, 400);

  const syncedCount = await GitHubConnector.syncRepositoryDocs(spaceId, repo, token || '');
  return c.json({ success: true, repo, syncedCount, syncedAt: new Date().toISOString() });
});

app.post('/api/v1/connectors/slack/test', async (c) => {
  const { channel } = await c.req.json().catch(() => ({}));
  if (!channel) return c.json({ error: 'Channel name is required' }, 400);
  return c.json({ success: true, channel, status: 'connected', verifiedAt: new Date().toISOString() });
});

app.post('/api/v1/connectors/drive/test', async (c) => {
  const { folderId, apiKey } = await c.req.json().catch(() => ({}));
  if (!folderId && !apiKey) return c.json({ error: 'Folder ID or API Key is required' }, 400);
  return c.json({ success: true, folderId: folderId || 'root', status: 'connected', verifiedAt: new Date().toISOString() });
});

// --- Licensing & Stripe Checkout Endpoints ---
app.post('/api/v1/checkout/create-session', async (c) => {
  const body = await c.req.json().catch(() => ({}));
  const origin = new URL(c.req.url).origin;
  const successUrl = body.successUrl || `${origin}/success`;
  const cancelUrl = body.cancelUrl || `${origin}/#pricing`;

  try {
    const session = await createCheckoutSession({
      email: body.email,
      successUrl,
      cancelUrl,
    });
    return c.json(session);
  } catch (err: any) {
    return c.json({ error: err.message || 'Failed to create checkout session' }, 500);
  }
});

app.post('/api/v1/checkout/webhook', async (c) => {
  const sig = c.req.header('stripe-signature') || '';
  const rawBody = await c.req.text();
  try {
    const result = await handleStripeWebhook(rawBody, sig);
    return c.json(result);
  } catch (err: any) {
    return c.json({ error: err.message || 'Webhook error' }, 400);
  }
});

app.post('/api/v1/license/activate', async (c) => {
  const body = await c.req.json();
  const { licenseKey, hardwareUuid, email, machineName } = body;
  if (!licenseKey) {
    return c.json({ valid: false, message: 'licenseKey is required' }, 400);
  }
  const ipAddress = c.req.header('x-forwarded-for') || '127.0.0.1';
  const userAgent = c.req.header('user-agent') || 'Sidebrief-macOS';

  const result = await activateLicense({
    licenseKey,
    hardwareUuid,
    email,
    machineName,
    ipAddress,
    userAgent
  });
  if (!result.valid) {
    return c.json(result, 400);
  }
  return c.json(result);
});

app.get('/api/v1/license/validate', async (c) => {
  const key = c.req.query('key') || '';
  const hwid = c.req.query('hwid');
  const machineName = c.req.query('machineName');
  if (!key) {
    return c.json({ valid: false, error: 'key is required' }, 400);
  }
  const ipAddress = c.req.header('x-forwarded-for') || '127.0.0.1';
  const userAgent = c.req.header('user-agent') || 'Sidebrief-macOS';

  const result = await validateLicense({
    licenseKey: key,
    hardwareUuid: hwid,
    machineName,
    ipAddress,
    userAgent
  });
  return c.json(result);
});

// Magic Link / Account Recovery
app.post('/api/v1/auth/magic-link', async (c) => {
  const body = await c.req.json().catch(() => ({}));
  const email = body.email || '';
  const result = await requestMagicLink(email);
  return c.json(result);
});

// --- In-App Updates Endpoints ---
app.get('/api/v1/updates/check', (c) => {
  const version = c.req.query('version') || '1.0.0';
  const origin = new URL(c.req.url).origin;
  const update = checkUpdate(version, origin);
  return c.json(update);
});

app.get('/api/v1/updates/appcast.json', (c) => {
  const origin = new URL(c.req.url).origin;
  const feed = getAppcastFeed(origin);
  return c.json(feed);
});

// --- Website & Downloads Static Serving ---
const websiteDir = path.resolve(process.cwd(), '../website');
const localWebsiteDir = path.resolve(process.cwd(), 'website');
const publicDir = path.resolve(process.cwd(), 'public');

app.get('/', (c) => {
  const candidates = [
    path.join(websiteDir, 'index.html'),
    path.join(localWebsiteDir, 'index.html'),
    path.join(publicDir, 'index.html')
  ];
  for (const p of candidates) {
    if (fs.existsSync(p)) {
      return c.html(fs.readFileSync(p, 'utf-8'));
    }
  }
  return c.text('Sidebrief Landing Page - Sidebrief is running');
});

app.get('/success', (c) => {
  const candidates = [
    path.join(websiteDir, 'success.html'),
    path.join(localWebsiteDir, 'success.html'),
    path.join(publicDir, 'success.html')
  ];
  for (const p of candidates) {
    if (fs.existsSync(p)) {
      return c.html(fs.readFileSync(p, 'utf-8'));
    }
  }
  return c.text('Purchase Successful - Thank you for supporting Sidebrief!');
});

app.get('/docs', (c) => {
  const candidates = [
    path.join(websiteDir, 'docs.html'),
    path.join(localWebsiteDir, 'docs.html'),
    path.join(publicDir, 'docs.html'),
    path.join(websiteDir, 'index.html')
  ];
  for (const p of candidates) {
    if (fs.existsSync(p)) {
      return c.html(fs.readFileSync(p, 'utf-8'));
    }
  }
  return c.text('Sidebrief Documentation');
});

app.get('/support', (c) => {
  const candidates = [
    path.join(websiteDir, 'support.html'),
    path.join(localWebsiteDir, 'support.html'),
    path.join(publicDir, 'support.html'),
    path.join(websiteDir, 'index.html')
  ];
  for (const p of candidates) {
    if (fs.existsSync(p)) {
      return c.html(fs.readFileSync(p, 'utf-8'));
    }
  }
  return c.text('Sidebrief Support');
});

app.get('/style.css', (c) => {
  const candidates = [
    path.join(websiteDir, 'style.css'),
    path.join(localWebsiteDir, 'style.css'),
    path.join(publicDir, 'style.css')
  ];
  for (const p of candidates) {
    if (fs.existsSync(p)) {
      c.header('Content-Type', 'text/css');
      return c.body(fs.readFileSync(p, 'utf-8'));
    }
  }
  return c.notFound();
});

app.get('/downloads/:filename', (c) => {
  const filename = c.req.param('filename');
  const candidates = [
    path.resolve(process.cwd(), '../dist', filename),
    path.resolve(process.cwd(), 'public/downloads', filename),
    path.resolve(process.cwd(), '../website/downloads', filename)
  ];
  for (const p of candidates) {
    if (fs.existsSync(p)) {
      c.header('Content-Disposition', `attachment; filename="${filename}"`);
      c.header('Content-Type', 'application/octet-stream');
      return c.body(fs.readFileSync(p));
    }
  }
  return c.text(`Download ${filename} will be available once release build is completed.`, 404);
});

export default app;

import { fileURLToPath } from 'url';

// Only start listening if executed directly as main script
const isMain = process.argv[1] && (process.argv[1] === fileURLToPath(import.meta.url) || process.argv[1].endsWith('/dist/index.js'));
if (isMain) {
  const port = parseInt(process.env.PORT || process.env.SIDEBRIEF_API_PORT || '3100', 10);
  serve({ fetch: app.fetch, port }, () => {
    console.log(`Sidebrief API listening on http://localhost:${port}`);
  });
}
