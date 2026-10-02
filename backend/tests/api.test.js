// backend/tests/api.test.js
process.env.NODE_ENV = 'test';
import test from 'node:test';
import assert from 'node:assert/strict';
import app from '../dist/index.js';
import { ingestDocument } from '../dist/connectors/Connectors.js';

// Use Neon database connection string if set
const connectionString = process.env.NEON_DATABASE_URL || process.env.DATABASE_URL || '';
process.env.NEON_DATABASE_URL = connectionString;

test('Health check endpoint returns ok', async () => {
  const res = await app.request('/health');
  assert.equal(res.status, 200);
  const data = await res.json();
  assert.equal(data.status, 'ok');
  assert.equal(data.service, 'sidebrief-api');
});

test('Sync endpoint ingest and idempotency', async () => {
  const meetingId = `m_test_${Date.now()}`;
  const trackId = `track_test_${Date.now()}`;
  const chunkId = `chunk_test_${Date.now()}`;

  const payload = {
    spaceId: 'space-eqty',
    meetings: [
      {
        id: meetingId,
        title: 'Backend Integration Review',
        state: 'completed',
        actualStartTime: new Date().toISOString(),
        actualEndTime: new Date().toISOString(),
        agenda: 'Test sync and retrieval',
        version: 1
      }
    ],
    tracks: [
      {
        id: trackId,
        meetingId: meetingId,
        sourceType: 'microphone',
        deviceName: 'MacBook Pro Mic',
        sampleRate: 48000,
        channelCount: 1,
        format: 'lpcm_16bit',
        streamEpoch: Date.now()
      }
    ],
    chunks: [
      {
        id: chunkId,
        trackId: trackId,
        meetingId: meetingId,
        sequenceNumber: 0,
        streamEpoch: Date.now(),
        startOffsetMs: 0,
        endOffsetMs: 2000,
        sampleCount: 96000,
        byteCount: 192044,
        checksumSha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        encryptionNonceHex: '0102030405060708090a0b0c',
        uploadState: 'localOnly'
      }
    ],
    segments: [
      {
        id: `seg_${Date.now()}`,
        meetingId: meetingId,
        trackId: trackId,
        speakerLabel: 'You',
        text: 'We are validating the Neon PostgreSQL synchronization pipeline.',
        startOffsetMs: 100,
        endOffsetMs: 1900,
        isProvisional: false,
        revision: 1
      }
    ],
    summaries: [
      {
        id: `sum_${Date.now()}`,
        meetingId: meetingId,
        overview: 'Successful pipeline verification meeting.',
        keyPoints: ['Postgres sync active', 'Audio encryption verified'],
        decisions: [{ title: 'Proceed to production', rationale: 'All tests passing', status: 'confirmed' }]
      }
    ]
  };

  const res = await app.request('/api/v1/sync', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  });

  assert.equal(res.status, 200);
  const data = await res.json();
  assert.equal(data.success, true);
  assert.equal(data.spaceId, 'space-eqty');
});

test('Document ingestion and Hybrid Lexical Search with Space Isolation', async () => {
  // Ingest document into space-eqty
  await ingestDocument({
    spaceId: 'space-eqty',
    externalId: 'ext_eqty_sec_spec',
    title: 'EQTY Security Architecture Specification',
    sourceUrl: 'https://docs.eqty.internal/security',
    rawContent: 'All audio chunks must use authenticated AES-GCM encryption with per-session keys stored in Keychain.'
  });

  // Ingest document into space-personal
  await ingestDocument({
    spaceId: 'space-personal',
    externalId: 'ext_personal_recipe',
    title: 'Personal Italian Pasta Recipe',
    sourceUrl: 'https://personal.internal/pasta',
    rawContent: 'Add garlic and olive oil to the pan before simmering with San Marzano tomatoes.'
  });

  // Query space-eqty for "Keychain encryption"
  const resEqty = await app.request('/api/v1/search', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      spaceId: 'space-eqty',
      query: 'Keychain encryption'
    })
  });

  assert.equal(resEqty.status, 200);
  const dataEqty = await resEqty.json();
  assert.ok(dataEqty.results.length > 0);
  assert.equal(dataEqty.results[0].spaceId, 'space-eqty');
  assert.ok(dataEqty.results[0].title.includes('EQTY Security'));

  // Strict isolation test: querying space-personal must NOT return EQTY security document
  const resPersonal = await app.request('/api/v1/search', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      spaceId: 'space-personal',
      query: 'Keychain encryption'
    })
  });

  assert.equal(resPersonal.status, 200);
  const dataPersonal = await resPersonal.json();
  const leakedDoc = dataPersonal.results.find(r => r.spaceId === 'space-eqty');
  assert.equal(leakedDoc, undefined, 'Zero cross-space leakage allowed!');
});

test('Storage upload grant generation', async () => {
  const res = await app.request('/api/v1/storage/grant-upload', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      meetingId: 'm-456',
      chunkId: 'ch-789',
      spaceId: 'space-eqty'
    })
  });

  assert.equal(res.status, 200);
  const data = await res.json();
  assert.ok(data.uploadUrl.includes('audio/space-eqty/m-456/ch-789.enc'));
  assert.equal(data.expiresInSeconds, 3600);
});

test('Visible and Editable Memory Facts CRUD and Space Isolation', async () => {
  // 1. Fetch seeded bootstrapped memories
  const listRes = await app.request('/api/v1/memory?spaceId=space-eqty');
  assert.equal(listRes.status, 200);
  const listData = await listRes.json();
  assert.ok(listData.facts.length > 0);
  assert.ok(listData.facts.some(f => f.key === 'Primary Database'));

  // 2. Create new editable memory fact
  const factId = `mem_test_${Date.now()}`;
  const createRes = await app.request('/api/v1/memory', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      id: factId,
      spaceId: 'space-eqty',
      category: 'Key Stakeholders',
      key: 'CTO Decision Preference',
      value: 'Prefers concise recommendations with maximum 2 distinct alternatives.',
      source: 'manual',
      isPinned: true
    })
  });
  assert.equal(createRes.status, 200);
  const createdData = await createRes.json();
  assert.equal(createdData.fact.key, 'CTO Decision Preference');

  // 3. Edit memory fact
  const editRes = await app.request('/api/v1/memory', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      id: factId,
      spaceId: 'space-eqty',
      category: 'Key Stakeholders',
      key: 'CTO Decision Preference',
      value: 'Updated: Prefers concise answers under 50 words with risk analysis.',
      source: 'manual',
      isPinned: true
    })
  });
  assert.equal(editRes.status, 200);
  const editData = await editRes.json();
  assert.ok(editData.fact.value.includes('under 50 words'));

  // 4. Delete memory fact
  const delRes = await app.request(`/api/v1/memory/${factId}`, { method: 'DELETE' });
  assert.equal(delRes.status, 200);
});

test('Multiple Email Accounts Configuration and Sync', async () => {
  // Add Account 1 (Work)
  const acc1Res = await app.request('/api/v1/connectors/email', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      id: `acc_work_${Date.now()}`,
      spaceId: 'space-eqty',
      accountName: 'Work Gmail',
      emailAddress: 'kevin@eqty.internal',
      imapHost: 'imap.gmail.com',
      imapPort: 993,
      selectedScopes: ['INBOX', 'Archived']
    })
  });
  assert.equal(acc1Res.status, 200);

  // Add Account 2 (Personal / Advisory)
  const acc2Res = await app.request('/api/v1/connectors/email', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      id: `acc_advisory_${Date.now()}`,
      spaceId: 'space-eqty',
      accountName: 'Advisory Fastmail',
      emailAddress: 'kevin@tko.internal',
      imapHost: 'imap.fastmail.com',
      imapPort: 993,
      selectedScopes: ['INBOX']
    })
  });
  assert.equal(acc2Res.status, 200);

  // List all email accounts for space-eqty
  const listRes = await app.request('/api/v1/connectors/email?spaceId=space-eqty');
  assert.equal(listRes.status, 200);
  const listData = await listRes.json();
  assert.ok(listData.accounts.length >= 2);
  assert.ok(listData.accounts.some(a => a.account_identifier === 'kevin@eqty.internal'));
  assert.ok(listData.accounts.some(a => a.account_identifier === 'kevin@tko.internal'));
});

test('Checkout session creation and mock license generation ($19.99)', async () => {
  const res = await app.request('/api/v1/checkout/create-session', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      email: 'buyer@example.com',
      successUrl: 'http://localhost:3000/success',
      cancelUrl: 'http://localhost:3000/#pricing'
    })
  });
  assert.equal(res.status, 200);
  const data = await res.json();
  assert.ok(data.url);
  assert.ok(data.sessionId || data.mockKey);
  if (data.mockKey) {
    assert.match(data.mockKey, /^SB-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}$/);
  }
});

test('License activation and status validation', async () => {
  // First create checkout session to get license key
  const checkoutRes = await app.request('/api/v1/checkout/create-session', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      email: 'pro_user@example.com'
    })
  });
  const checkoutData = await checkoutRes.json();
  const licenseKey = checkoutData.mockKey || 'SB-TEST-1234-5678-ABCD';
  const hwid = 'TEST-HARDWARE-UUID-MACBOOK-ARM64';

  // Activate license
  const activateRes = await app.request('/api/v1/license/activate', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      licenseKey: licenseKey,
      hardwareUuid: hwid,
      email: 'pro_user@example.com'
    })
  });
  assert.equal(activateRes.status, 200);
  const activateData = await activateRes.json();
  assert.equal(activateData.valid, true);

  // Validate license
  const validateRes = await app.request(`/api/v1/license/validate?key=${encodeURIComponent(licenseKey)}&hwid=${hwid}`);
  assert.equal(validateRes.status, 200);
  const valData = await validateRes.json();
  assert.equal(valData.valid, true);
  assert.equal(valData.status, 'active');
});

test('Update checker detects latest release and returns release notes', async () => {
  const res = await app.request('/api/v1/updates/check?version=1.0.0');
  assert.equal(res.status, 200);
  const data = await res.json();
  assert.equal(data.hasUpdate, true);
  assert.equal(data.latestVersion, '1.0.1');
  assert.ok(data.releaseNotes.includes('Claude 5 Sonnet'));
  assert.ok(data.downloadUrl.includes('/downloads/Sidebrief.dmg'));

  // Test already on latest version
  const currentRes = await app.request('/api/v1/updates/check?version=1.0.1');
  assert.equal(currentRes.status, 200);
  const currentData = await currentRes.json();
  assert.equal(currentData.hasUpdate, false);

  // Test appcast feed
  const feedRes = await app.request('/api/v1/updates/appcast.json');
  assert.equal(feedRes.status, 200);
  const feedData = await feedRes.json();
  assert.ok(feedData.items.length >= 1);
  assert.equal(feedData.items[0].version, '1.0.1');
});

test('Website landing page and style serving', async () => {
  const pageRes = await app.request('/');
  assert.equal(pageRes.status, 200);
  const html = await pageRes.text();
  assert.ok(html.includes('The Native macOS'));
  assert.ok(html.includes('Sidebrief'));
  assert.ok(html.includes('$19.99'));

  const cssRes = await app.request('/style.css');
  assert.equal(cssRes.status, 200);
  assert.equal(cssRes.headers.get('content-type'), 'text/css');

  const successRes = await app.request('/success?key=SB-1234-5678-90AB-CDEF');
  assert.equal(successRes.status, 200);
  const successHtml = await successRes.text();
  assert.ok(successHtml.includes('Payment Successful!'));
  assert.ok(successHtml.includes('sidebrief://activate'));

  const dmgRes = await app.request('/downloads/Sidebrief.dmg');
  assert.equal(dmgRes.status, 200);
  assert.equal(dmgRes.headers.get('content-type'), 'application/octet-stream');
  assert.ok(dmgRes.headers.get('content-disposition').includes('Sidebrief.dmg'));
  const buffer = await dmgRes.arrayBuffer();
  assert.ok(buffer.byteLength > 1000000); // Verify DMG is > 1MB binary

  const docsRes = await app.request('/docs');
  assert.equal(docsRes.status, 200);
});

test('External Workspaces Connectors (GitHub, Slack, Drive)', async () => {
  // Test GitHub sync endpoint
  const ghRes = await app.request('/api/v1/connectors/github/sync', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      spaceId: 'space-work',
      repo: 'sidebrief/sidebrief',
      token: 'ghp_mock_token'
    })
  });
  assert.equal(ghRes.status, 200);
  const ghData = await ghRes.json();
  assert.equal(ghData.success, true);
  assert.equal(ghData.repo, 'sidebrief/sidebrief');

  // Test Slack test connection endpoint
  const slackRes = await app.request('/api/v1/connectors/slack/test', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      channel: '#engineering'
    })
  });
  assert.equal(slackRes.status, 200);
  const slackData = await slackRes.json();
  assert.equal(slackData.status, 'connected');

  // Test Drive test connection endpoint
  const driveRes = await app.request('/api/v1/connectors/drive/test', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      folderId: 'folder_abc123'
    })
  });
  assert.equal(driveRes.status, 200);
  const driveData = await driveRes.json();
  assert.equal(driveData.status, 'connected');
});

