import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { Pool } from '@neondatabase/serverless';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const databaseUrl = process.env.NEON_DATABASE_URL || process.env.DATABASE_URL || '';
if (!databaseUrl) {
  console.error('Error: NEON_DATABASE_URL is not set.');
  process.exit(1);
}

async function migrate() {
  console.log('Connecting to Neon PostgreSQL for migration...');
  const pool = new Pool({ connectionString: databaseUrl });
  const client = await pool.connect();
  try {
    const schemaPath = path.resolve(__dirname, '../db/schema.sql');
    const schemaSql = fs.readFileSync(schemaPath, 'utf-8');
    console.log('Executing schema.sql...');
    await client.query(schemaSql);
    console.log('Migration successfully completed!');
  } catch (err) {
    console.error('Migration failed:', err);
    process.exit(1);
  } finally {
    client.release();
    await pool.end();
  }
}

migrate();
