// backend/src/db.ts
import { Pool } from '@neondatabase/serverless';

let _pool: Pool | null = null;

export function getPool(): Pool {
  if (!_pool) {
    const databaseUrl = process.env.NEON_DATABASE_URL || process.env.DATABASE_URL || '';
    _pool = new Pool({
      connectionString: databaseUrl,
    });
  }
  return _pool;
}

export async function query<T = any>(text: string, params: any[] = []): Promise<T[]> {
  const pool = getPool();
  const client = await pool.connect();
  try {
    const res = await client.query(text, params);
    return res.rows;
  } finally {
    client.release();
  }
}

export async function withTransaction<T>(
  spaceId: string,
  callback: (client: any) => Promise<T>
): Promise<T> {
  const pool = getPool();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    if (spaceId) {
      await client.query("SELECT set_config('app.current_space_id', $1, true)", [spaceId]);
    }
    const result = await callback(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}
