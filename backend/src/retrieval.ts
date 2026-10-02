// backend/src/retrieval.ts
import { query } from './db.js';

export interface SearchItem {
  id: string;
  spaceId: string;
  sourceType: 'meeting' | 'document' | 'email' | 'drive' | 'slack' | 'github';
  title: string;
  snippet: string;
  sourceUrl?: string;
  timestamp?: string;
  score: number;
}

export interface HybridSearchOptions {
  spaceId: string;
  queryText: string;
  queryEmbedding?: number[]; // 1536-dim vector
  additionalAllowedSpaces?: string[];
  limit?: number;
}

export async function hybridSearch(options: HybridSearchOptions): Promise<SearchItem[]> {
  const allowedSpaces = [options.spaceId, ...(options.additionalAllowedSpaces || [])];
  const limit = options.limit || 10;
  const q = options.queryText.trim();

  const resultsMap = new Map<string, SearchItem>();

  // 1. Lexical Full-Text Search on documents and transcript_segments
  if (q.length > 0) {
    const docLexicalSql = `
      SELECT 
        d.id, 
        d.space_id, 
        d.title, 
        ts_headline('english', d.raw_content, plainto_tsquery('english', $1), 'StartSel=<mark>, StopSel=</mark>, MaxWords=35, MinWords=15') as snippet,
        d.source_url, 
        d.synced_at as timestamp,
        ts_rank_cd(d.search_vector, plainto_tsquery('english', $1)) as rank
      FROM documents d
      WHERE d.space_id = ANY($2::text[])
        AND d.search_vector @@ plainto_tsquery('english', $1)
      ORDER BY rank DESC
      LIMIT $3
    `;

    try {
      const docRows = await query(docLexicalSql, [q, allowedSpaces, limit]);
      docRows.forEach((row, index) => {
        const rrfScore = 1.0 / (60 + index + 1);
        resultsMap.set(row.id, {
          id: row.id,
          spaceId: row.space_id,
          sourceType: 'document',
          title: row.title,
          snippet: row.snippet || '',
          sourceUrl: row.source_url,
          timestamp: row.timestamp,
          score: rrfScore,
        });
      });
    } catch (err) {
      console.warn('Lexical doc search error:', err);
    }

    // Transcript segments lexical search
    const segmentLexicalSql = `
      SELECT 
        ts.id,
        m.space_id,
        m.title,
        ts.text as snippet,
        ts.created_at as timestamp,
        ts_rank_cd(ts.search_vector, plainto_tsquery('english', $1)) as rank
      FROM transcript_segments ts
      JOIN meetings m ON ts.meeting_id = m.id
      WHERE m.space_id = ANY($2::text[])
        AND ts.search_vector @@ plainto_tsquery('english', $1)
      ORDER BY rank DESC
      LIMIT $3
    `;

    try {
      const segRows = await query(segmentLexicalSql, [q, allowedSpaces, limit]);
      segRows.forEach((row, index) => {
        const rrfScore = 1.0 / (60 + index + 1);
        const existing = resultsMap.get(row.id);
        if (existing) {
          existing.score += rrfScore;
        } else {
          resultsMap.set(row.id, {
            id: row.id,
            spaceId: row.space_id,
            sourceType: 'meeting',
            title: `Meeting: ${row.title}`,
            snippet: row.snippet,
            timestamp: row.timestamp,
            score: rrfScore,
          });
        }
      });
    } catch (err) {
      console.warn('Lexical segment search error:', err);
    }
  }

  // 2. Vector Semantic Search (if embedding provided)
  if (options.queryEmbedding && options.queryEmbedding.length === 1536) {
    const vectorSql = `
      SELECT 
        dc.id,
        dc.space_id,
        d.title,
        dc.content as snippet,
        d.source_url,
        1 - (dc.embedding <=> $1::vector) as similarity
      FROM document_chunks dc
      JOIN documents d ON dc.document_id = d.id
      WHERE dc.space_id = ANY($2::text[])
      ORDER BY dc.embedding <=> $1::vector ASC
      LIMIT $3
    `;

    try {
      const vectorRows = await query(vectorSql, [JSON.stringify(options.queryEmbedding), allowedSpaces, limit]);
      vectorRows.forEach((row, index) => {
        const rrfScore = 1.0 / (60 + index + 1);
        const existing = resultsMap.get(row.id);
        if (existing) {
          existing.score += rrfScore;
        } else {
          resultsMap.set(row.id, {
            id: row.id,
            spaceId: row.space_id,
            sourceType: 'document',
            title: row.title,
            snippet: row.snippet,
            sourceUrl: row.source_url,
            score: rrfScore,
          });
        }
      });
    } catch (err) {
      console.warn('Vector search error:', err);
    }
  }

  // Sort by merged score descending
  return Array.from(resultsMap.values())
    .sort((a, b) => b.score - a.score)
    .slice(0, limit);
}
