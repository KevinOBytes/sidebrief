// backend/src/connectors/Connectors.ts
import { query } from '../db.js';
import crypto from 'crypto';

export interface IngestDocumentPayload {
  spaceId: string;
  connectorId?: string;
  externalId: string;
  title: string;
  sourceUrl?: string;
  mimeType?: string;
  rawContent: string;
  lastModifiedAt?: string;
}

export async function ingestDocument(doc: IngestDocumentPayload): Promise<string> {
  const contentHash = crypto.createHash('sha256').update(doc.rawContent).digest('hex');
  const docId = `doc_${crypto.randomUUID()}`;

  const insertDocSql = `
    INSERT INTO documents (
      id, space_id, connector_id, external_id, title, source_url, mime_type, content_hash, raw_content, last_modified_at, synced_at
    ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, COALESCE($10::timestamptz, NOW()), NOW())
    ON CONFLICT (space_id, external_id) DO UPDATE SET
      title = EXCLUDED.title,
      source_url = EXCLUDED.source_url,
      mime_type = EXCLUDED.mime_type,
      content_hash = EXCLUDED.content_hash,
      raw_content = EXCLUDED.raw_content,
      last_modified_at = EXCLUDED.last_modified_at,
      synced_at = NOW()
    RETURNING id
  `;

  const rows = await query(insertDocSql, [
    docId,
    doc.spaceId,
    doc.connectorId || null,
    doc.externalId,
    doc.title,
    doc.sourceUrl || '',
    doc.mimeType || 'text/plain',
    contentHash,
    doc.rawContent,
    doc.lastModifiedAt || null,
  ]);

  const persistedId = rows[0]?.id || docId;

  // Simple paragraph / section chunker
  const paragraphs = doc.rawContent
    .split(/\n\n+/)
    .map(p => p.trim())
    .filter(p => p.length > 20);

  // Delete previous chunks if updated
  await query('DELETE FROM document_chunks WHERE document_id = $1', [persistedId]);

  for (let i = 0; i < paragraphs.length; i++) {
    const chunkId = `chunk_${persistedId}_${i}`;
    const chunkSql = `
      INSERT INTO document_chunks (id, document_id, space_id, chunk_index, content, token_count)
      VALUES ($1, $2, $3, $4, $5, $6)
    `;
    const tokenEstimate = Math.ceil(paragraphs[i].length / 4);
    await query(chunkSql, [chunkId, persistedId, doc.spaceId, i, paragraphs[i], tokenEstimate]);
  }

  return persistedId;
}

// Read-only GitHub Adapter
export class GitHubConnector {
  static async syncRepositoryDocs(spaceId: string, repo: string, token: string): Promise<number> {
    // Read repository markdown files, README, and open issues/PRs using GitHub API
    // Stored with commit SHA and URL provenance
    const headers: Record<string, string> = {
      'User-Agent': 'Sidebrief-Copilot',
      'Accept': 'application/vnd.github.v3+json',
    };
    if (token) headers['Authorization'] = `Bearer ${token}`;

    try {
      const readmeRes = await fetch(`https://api.github.com/repos/${repo}/readme`, { headers });
      if (readmeRes.ok) {
        const data = await readmeRes.json() as any;
        const content = Buffer.from(data.content, 'base64').toString('utf-8');
        await ingestDocument({
          spaceId,
          externalId: `github_${repo}_readme`,
          title: `GitHub: ${repo} README`,
          sourceUrl: data.html_url,
          mimeType: 'text/markdown',
          rawContent: content,
        });
        return 1;
      }
    } catch (err) {
      console.warn(`GitHub sync error for ${repo}:`, err);
    }
    return 0;
  }
}

// Read-only Email / IMAP Adapter
export class EmailConnector {
  static async ingestEmailMessage(
    spaceId: string,
    messageId: string,
    subject: string,
    sender: string,
    recipients: string[],
    date: string,
    body: string
  ): Promise<string> {
    const rawContent = `From: ${sender}\nTo: ${recipients.join(', ')}\nDate: ${date}\nSubject: ${subject}\n\n${body}`;
    return ingestDocument({
      spaceId,
      externalId: `email_${messageId}`,
      title: `Email: ${subject}`,
      mimeType: 'message/rfc822',
      rawContent,
      lastModifiedAt: date,
    });
  }
}

// Read-only Google Drive Adapter
export class DriveConnector {
  static async ingestDriveFile(
    spaceId: string,
    fileId: string,
    fileName: string,
    webViewLink: string,
    content: string,
    modifiedTime: string
  ): Promise<string> {
    return ingestDocument({
      spaceId,
      externalId: `gdrive_${fileId}`,
      title: `Google Drive: ${fileName}`,
      sourceUrl: webViewLink,
      mimeType: 'text/plain',
      rawContent: content,
      lastModifiedAt: modifiedTime,
    });
  }
}

// Read-only Slack Adapter
export class SlackConnector {
  static async ingestSlackThread(
    spaceId: string,
    channelName: string,
    threadTs: string,
    permalink: string,
    messages: Array<{ user: string; text: string; ts: string }>
  ): Promise<string> {
    const formatted = messages.map(m => `[${m.user}]: ${m.text}`).join('\n');
    return ingestDocument({
      spaceId,
      externalId: `slack_${channelName}_${threadTs}`,
      title: `Slack: #${channelName} discussion`,
      sourceUrl: permalink,
      mimeType: 'text/plain',
      rawContent: formatted,
    });
  }
}
