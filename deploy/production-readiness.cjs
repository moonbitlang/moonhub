// Read only: after stopping the controller, require all workers to be drained.
const { DatabaseSync } = require('node:sqlite');
let db;
try {
  db = new DatabaseSync(process.env.DB_PATH || '/data/moonhub.db', {readOnly:true, timeout:5000});
  const active = db.prepare("SELECT COUNT(*) AS count FROM pipeline_job_attempt WHERE status <> 'completed'").get().count;
  const workers = db.prepare("SELECT COUNT(*) AS count FROM pipeline_worker WHERE state NOT IN ('drained', 'failed')").get().count;
  if (active || workers) throw new Error(`${active} active attempts, ${workers} undrained workers`);
  if (process.argv[2]) {
    const provider = db.prepare('SELECT repository_scope, revoked FROM pipeline_provider WHERE name = ?').get(process.argv[2]);
    if (provider && (provider.repository_scope !== 'all' || provider.revoked)) throw new Error('Production provider needs active all-repository authorization');
  }
  console.log('No active attempts or undrained standalone workers.');
} catch (error) {
  console.error('Production upgrade refused: ' + error.message);
  process.exitCode = 1;
} finally { db?.close(); }
