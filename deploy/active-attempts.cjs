// Read-only deployment check, compatible with existing Node 24 runtime images.
const { DatabaseSync } = require('node:sqlite');
let db;
try {
  const provider = process.argv[2];
  db = new DatabaseSync(process.env.DB_PATH || '/data/moonhub.db', { readOnly: true, timeout: 5000 });
  const row = provider
    ? db.prepare("SELECT COUNT(*) AS count FROM pipeline_job_attempt a JOIN pipeline_provider p ON p.id = a.provider_id WHERE p.name = ? AND a.status <> 'completed'").get(provider)
    : db.prepare("SELECT COUNT(*) AS count FROM pipeline_job_attempt WHERE status <> 'completed'").get();
  console.log(row.count);
} catch {
  console.error('Cannot determine active Pipeline attempts; refusing deployment.');
  process.exitCode = 1;
} finally { db?.close(); }
